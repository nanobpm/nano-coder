//! Context-window accounting and compaction helpers.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};

use regex::Regex;

use crate::llm::{Message, Role};

/// The attachment occurrences that are *sendable as images* — identified by
/// address, exactly as the wire plan ([`crate::llm::ChatRequest::attachment_plan`])
/// keys them — so the token estimate can charge availability the same way the
/// request builder does. Reading the same image twice is two occurrences.
pub type AttachmentAvailability = HashSet<*const crate::llm::Attachment>;

/// Used when neither config nor the model name gives a window.
pub const DEFAULT_CONTEXT_WINDOW: usize = 128_000;

/// Tokens kept verbatim at the end of the conversation when compacting.
pub const KEEP_RECENT_TOKENS: usize = 20_000;

/// Target length of the summary text itself.
pub const SUMMARY_MAX_TOKENS: i64 = 4_096;

/// Extra output room for the summary request on top of `SUMMARY_MAX_TOKENS`.
/// Reasoning models spend output tokens thinking before they write, and those
/// count against `max_tokens`: with only `SUMMARY_MAX_TOKENS` a long transcript
/// can use most of it up thinking, so the summary is cut off or empty and the
/// agent loses the work it was summarizing.
pub const SUMMARY_REASONING_ALLOWANCE: i64 = 8_192;

/// `max_tokens` for a summary request: room for the summary plus reasoning,
/// never above the configured `max_tokens`, and at most a quarter of the
/// window so the transcript still fits. Never below the old cap
/// (`SUMMARY_MAX_TOKENS`, or the configured value when that is smaller).
pub fn summary_output_budget(window: usize, configured: i64) -> i64 {
    let configured = configured.max(1);
    let floor = SUMMARY_MAX_TOKENS.min(configured);
    configured.min(SUMMARY_MAX_TOKENS + SUMMARY_REASONING_ALLOWANCE).min((window / 4) as i64).max(floor)
}

/// Appended to a summary that stopped at the output limit.
pub const SUMMARY_TRUNCATED_NOTE: &str = "\n\n[This summary was cut off at the output limit, so its end is missing. \
Check the current state (files, git, the plan) before redoing any work.]";

pub const SUMMARY_PREFIX: &str = "[Summary of the earlier conversation, written when the context was compacted]";

pub const SUMMARY_SYSTEM_PROMPT: &str = "You are compacting an AI agent's conversation so it can keep working with a smaller context. \
Write a summary that lets the agent continue without the original messages. Include:\n\
- the user's goals, requirements and constraints (quote exact wording where it matters);\n\
- decisions made and why;\n\
- work completed: files created or edited (with paths), commands run and their key results, \
commits, branches, pull requests and URLs (with exact names and numbers);\n\
- the current state and what was in progress when the summary was written;\n\
- open problems, errors still unresolved, and the next steps;\n\
- identifiers and values the agent will need again.\n\
Be concise but do not drop facts the agent would otherwise have to rediscover; keep the summary under about \
2,500 words. Do not invent anything. Output only the summary.";

/// Starts a smart-compaction summary; its presence enables the history tools.
pub const SMART_SUMMARY_PREFIX: &str =
    "[Summary of the earlier conversation, written when the context was compacted (smart compaction)]";

/// Added to the summarizer prompt in smart mode.
pub const SMART_SUMMARY_INSTRUCTIONS: &str = "\n\nEach message in the transcript is labelled [#N], its ID in the session log. \
The agent can later read any message in full by that ID, so the summary can stay short: after a fact whose exact text \
may matter (an error message, a command and its output, a file's contents, the user's exact wording), cite its source \
as (#N) instead of copying long text. Cite only IDs that appear in the transcript.";

/// Note after a smart summary telling the agent how to recover originals.
pub fn smart_summary_note(range: Option<(u64, u64)>) -> String {
    let covered = match range {
        Some((first, last)) => format!("messages #{first}–#{last}"),
        None => "the earlier messages".to_string(),
    };
    format!(
        "[This summary covers {covered}. The originals are kept verbatim in the session log; the summary is \
lossy and may leave out or blur the detail you need. For anything from that period (an exact error, a command and \
its output, what the user asked for), use history_search, then history_read to see a message by its #N ID. Don't \
look on disk or re-run commands to recover what was said: that shows the current state, not what happened. Search \
for distinctive text (an error code or phrase, an identifier, a flag) rather than common words, use order=oldest \
for things established early, and try another pattern before concluding something isn't there. Long \
outputs were shortened before summarizing, so details from the middle of a long output are the likeliest to be missing, \
and an assistant message describing an output may paraphrase it: read the output itself. Retrieved messages \
are history, not the current state of files.]"
    )
}

/// What the agent is doing, for the status line.
#[derive(Debug, Clone, Default, PartialEq)]
pub enum Activity {
    #[default]
    Idle,
    Thinking,
    Tool(String),
    Compacting,
}

/// Context and usage figures, shared with the status line.
#[derive(Debug, Clone, Default)]
pub struct ContextStats {
    pub provider: String,
    pub model: String,
    /// Estimated tokens the next request would send.
    pub tokens: usize,
    /// True when `tokens` is anchored to usage reported by the provider.
    pub calibrated: bool,
    pub window: usize,
    /// Where `window` came from (config, the endpoint, a model-name default,
    /// or learned from a context-overflow error), for `/context`. Live, so a
    /// mid-turn context-overflow that lowers the window via `learned_window`
    /// updates this label alongside the number instead of leaving a stale
    /// source frozen at turn start.
    pub window_source: String,
    pub messages: usize,
    pub session_input_tokens: u64,
    pub session_output_tokens: u64,
    /// AI Credits used this session, when the provider reports them (GitHub
    /// Copilot). `None` for providers that do not meter in credits.
    pub session_aic: Option<f64>,
    pub compactions: u32,
    /// `history_search` / `history_read` calls this session.
    pub history_searches: u32,
    pub history_reads: u32,
    /// Whether the history tools are currently offered to the model (a smart
    /// summary is in context and the session is persisted). Live, so a mid-turn
    /// `/tools` reflects history tools a same-turn smart auto-compaction enabled.
    pub history_available: bool,
    /// Auto-compaction threshold as a fraction of the window (None = off).
    pub auto_compact: Option<f64>,
    /// Compactions will be smart (session log plus history tools): the
    /// configured mode is smart and the session is persisted, without which
    /// smart falls back to standard.
    pub smart_compact: bool,
    pub activity: Activity,
    /// Plan progress as (done, total), when there is a plan.
    pub plan: Option<(usize, usize)>,
    /// Working directory shown on the status line.
    pub cwd: String,
    /// Live output rate while generating (completion tokens per second),
    /// `None` when idle or before the first streamed token.
    pub tokens_per_sec: Option<f64>,
    /// The operating mode (normal/plan/auto), shown on the status line.
    pub mode: crate::mode::AgentMode,
    /// The thinking level sent with requests (`high`, `off`, …); `None` when
    /// none is sent and the model decides.
    pub thinking: Option<String>,
}

impl ContextStats {
    pub fn percent(&self) -> f64 {
        if self.window == 0 { 0.0 } else { self.tokens as f64 * 100.0 / self.window as f64 }
    }
}

pub type SharedStats = Arc<Mutex<ContextStats>>;

/// `12.3k`-style token count.
pub fn format_tokens(tokens: usize) -> String {
    match tokens {
        0..=999 => tokens.to_string(),
        1_000..=99_999 => format!("{:.1}k", tokens as f64 / 1_000.0),
        100_000..=999_999 => format!("{}k", tokens / 1_000),
        _ => format!("{:.2}M", tokens as f64 / 1_000_000.0),
    }
}

/// `131 KB`-style byte-size label.
pub fn format_bytes(bytes: usize) -> String {
    match bytes {
        0..=1023 => format!("{bytes} B"),
        1024..=1_048_575 => format!("{:.0} KB", bytes as f64 / 1024.0),
        _ => format!("{:.1} MB", bytes as f64 / 1_048_576.0),
    }
}

/// Rough token count for text (about four characters per token).
pub fn text_tokens(text: &str) -> usize {
    text.len().div_ceil(4)
}

/// `12 tok/s`-style output-rate label.
pub fn format_rate(tokens_per_sec: f64) -> String {
    if tokens_per_sec >= 10.0 { format!("{tokens_per_sec:.0} tok/s") } else { format!("{tokens_per_sec:.1} tok/s") }
}

/// Tokens for everything in a message *except* its image attachments: the
/// content text, each tool call, and the per-message framing overhead. Split
/// out so [`messages_tokens_with_vision`] can charge attachments against the
/// wire plan (image vs. placeholder) without re-deriving this.
fn message_text_tokens(message: &Message) -> usize {
    let calls: usize =
        message.tool_calls.iter().map(|c| text_tokens(&c.name) + text_tokens(&c.arguments.to_string()) + 4).sum();
    text_tokens(&message.content) + calls + 4
}

/// Token cost estimate for one image, from its pixel dimensions (Anthropic's
/// ~`w*h/750`). `read_file` downscales each dimension to at most
/// [`crate::attachment::MAX_DIMENSION`], so the largest image that can be sent
/// is a `MAX_DIMENSION`×`MAX_DIMENSION` square — the estimate is capped at that
/// maximum rather than the historical ~1,600, which undercounted a full square
/// (1,568×1,568 ⇒ 3,279 tokens) and could delay auto-compaction past the window.
pub fn image_tokens(attachment: &crate::llm::Attachment) -> usize {
    let estimate = (attachment.width as usize * attachment.height as usize).div_ceil(750);
    let max = (crate::attachment::MAX_DIMENSION as usize * crate::attachment::MAX_DIMENSION as usize).div_ceil(750);
    estimate.clamp(1, max)
}

/// The attachment occurrences in `messages` whose stored bytes are still intact
/// on disk — the same availability gate the wire plan
/// ([`crate::llm::ChatRequest::attachment_plan`]) applies before sending an
/// image (present *and* hash-matching, so availability can never diverge from
/// what the payload actually sends). Occurrences are keyed by address, not
/// content hash, exactly as the wire plan keys them, so the same image read
/// twice counts as two occurrences.
///
/// Build it **once** over a conversation and reuse it across every sub-slice
/// (e.g. each candidate compaction tail, or the calibrated suffix) so the
/// stored set is hashed once, not once per slice — rehashing per slice would be
/// O(N²) file I/O, the same trap [`crate::llm::ChatRequest::attachment_plan`]
/// avoids. With no attachments directory nothing is available, matching a
/// request that can send no image.
pub fn available_attachments(messages: &[Message], attachments_dir: Option<&Path>) -> AttachmentAvailability {
    let Some(dir) = attachments_dir else {
        return HashSet::new();
    };
    messages
        .iter()
        .flat_map(|m| m.attachments.iter())
        .filter(|a| crate::attachment::exists(dir, a))
        .map(|a| a as *const crate::llm::Attachment)
        .collect()
}

/// Token estimate for `messages` that mirrors the vision wire plan: request
/// builders send only the newest `max_images` *available* image attachments as
/// images and serialize every other attachment as its short text placeholder
/// ([`crate::llm::ChatRequest::attachment_plan`]). Charging full image tokens
/// for *every* historical attachment instead overcounts an image-heavy
/// conversation by thousands of tokens, so the status estimate and the
/// compaction kept-tail budget would trip auto-compaction (and fold recent
/// history) before the window is actually full. Charging only the newest
/// `max_images` available ones as images (and the rest as placeholder text)
/// keeps the estimate tracking what is really sent.
///
/// "Newest" is by occurrence across `messages` in order — the same identity the
/// wire plan uses — restricted to the occurrences in `available` (built with
/// [`available_attachments`]). An unavailable reference (missing or tampered on
/// resume) is **excluded from the image quota**, exactly as the wire plan
/// excludes it: it does not consume a slot an older available image could fill,
/// so it is charged as a placeholder while the backfilled older image is
/// charged in full. Treating a missing newest reference as an image slot would
/// undercount by the whole backfilled image (thousands of tokens) and delay
/// compaction past the real context limit. `max_images == 0` (no vision), or an
/// empty `available` set, charges every attachment as a placeholder — matching a
/// request that sends none.
pub fn messages_tokens_with_vision(
    messages: &[Message],
    max_images: usize,
    available: &AttachmentAvailability,
) -> usize {
    let is_available = |a: &crate::llm::Attachment| available.contains(&(a as *const crate::llm::Attachment));
    // Only *available* occurrences can be sent as images, so only they count
    // toward the quota. The oldest `omitted` available occurrences serialize as
    // placeholders; the newest `max_images` available ones are sent as images.
    // Every unavailable occurrence is always a placeholder.
    let available_total = messages.iter().flat_map(|m| m.attachments.iter()).filter(|a| is_available(a)).count();
    let omitted = available_total.saturating_sub(max_images);
    let mut seen_available = 0usize;
    let mut total = 0usize;
    for message in messages {
        total += message_text_tokens(message);
        for attachment in &message.attachments {
            let available_here = is_available(attachment);
            let sendable = available_here && seen_available >= omitted;
            total += if sendable { image_tokens(attachment) } else { text_tokens(&attachment.placeholder()) };
            if available_here {
                seen_available += 1;
            }
        }
    }
    total
}

/// Context window by model family, for models whose provider config has none.
pub fn window_for_model(model: &str) -> Option<usize> {
    let m = model.to_lowercase();
    let table: &[(&str, usize)] = &[
        ("claude", 200_000),
        ("gpt-4.1", 1_047_576),
        ("gpt-5", 400_000),
        ("gpt-4o", 128_000),
        ("o4-mini", 200_000),
        ("o3", 200_000),
        ("o1", 200_000),
        ("gemini", 1_048_576),
        ("deepseek", 128_000),
        ("grok", 256_000),
        ("mistral-large", 128_000),
        ("codestral", 256_000),
        ("kimi-k3", 1_000_000),
        ("kimi", 256_000),
        ("gpt-oss", 131_072),
        ("mock", 16_000),
    ];
    table.iter().find(|(needle, _)| m.contains(needle)).map(|(_, window)| *window)
}

/// Does this provider error say the request did not fit the context window?
pub fn is_context_overflow(error: &str) -> bool {
    let e = error.to_lowercase();
    [
        "context_length_exceeded",
        "maximum context length",
        "context length",
        "context window",
        "context size",
        "prompt is too long",
        "input is too long",
        "too many tokens",
        "reduce the length",
        "exceeds the available context",
    ]
    .iter()
    .any(|needle| e.contains(needle))
}

/// The window size stated in a context-overflow error, if any.
pub fn limit_from_error(error: &str) -> Option<usize> {
    let patterns = [
        r"(?i)maximum context length is (\d+)",
        r"(?i)context size \((\d+) tokens\)",
        r"(?i)> ?(\d+) maximum",
        r"(?i)context window (?:of|is) (\d+)",
        r"(?i)limit of (\d+) tokens",
    ];
    patterns.iter().find_map(|p| Regex::new(p).ok()?.captures(error)?.get(1)?.as_str().parse().ok())
}

fn clip(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let head: String = text.chars().take(max_chars * 2 / 3).collect();
    let tail: String = {
        let chars: Vec<char> = text.chars().collect();
        chars[chars.len() - max_chars / 3..].iter().collect()
    };
    format!("{head}\n…[{} characters omitted]…\n{tail}", text.chars().count() - max_chars)
}

/// Shorten an oversized message in place (tool output kept head and tail).
pub fn clip_message(message: &mut Message, max_tokens: usize) -> bool {
    if text_tokens(&message.content) <= max_tokens {
        return false;
    }
    message.content = clip(&message.content, max_tokens * 4);
    true
}

/// Render messages as a plain transcript for the summarizer, newest content
/// kept when it exceeds `max_chars`. With `ids`, each block is labelled with
/// the message's `[#N]` log line.
pub fn render_transcript(messages: &[Message], max_chars: usize, ids: bool) -> String {
    let mut blocks: Vec<String> = Vec::new();
    for message in messages {
        let block = match message.role {
            Role::System => continue,
            Role::User => format!("USER:\n{}", clip(&message.content, 6_000)),
            Role::Assistant => {
                let mut block = String::from("ASSISTANT:");
                if !message.content.trim().is_empty() {
                    block.push('\n');
                    block.push_str(&clip(&message.content, 6_000));
                }
                for call in &message.tool_calls {
                    block.push_str(&format!("\n[called {}({})]", call.name, clip(&call.arguments.to_string(), 1_500)));
                }
                block
            }
            Role::Tool => {
                let name = message.name.as_deref().unwrap_or("tool");
                let label = if message.is_error { "failed" } else { "result" };
                let mut block = format!("TOOL {label} ({name}):\n{}", clip(&message.content, 2_000));
                // The summary request never includes images; render each as a
                // placeholder so the transcript still notes it was seen.
                for attachment in &message.attachments {
                    block.push_str(&format!("\n{}", attachment.placeholder()));
                }
                block
            }
        };
        let block = match (ids, message.log_line) {
            (true, Some(line)) => format!("[#{line}] {block}"),
            (true, None)
                if message.role == Role::User
                    && (message.content.starts_with(SUMMARY_PREFIX)
                        || message.content.starts_with(SMART_SUMMARY_PREFIX)) =>
            {
                format!("[earlier summary] {block}")
            }
            _ => block,
        };
        blocks.push(block);
    }
    let mut kept: Vec<String> = Vec::new();
    let mut total = 0;
    for block in blocks.into_iter().rev() {
        if total + block.len() > max_chars {
            kept.push("…[earlier messages omitted]…".to_string());
            break;
        }
        total += block.len() + 2;
        kept.push(block);
    }
    kept.reverse();
    kept.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_budget_leaves_room_for_reasoning() {
        // Configured 16K on a 64K window: summary + reasoning allowance.
        assert_eq!(summary_output_budget(65_536, 16_384), 12_288);
        // Never above the configured max_tokens.
        assert_eq!(summary_output_budget(200_000, 8_000), 8_000);
        // A small window caps it at a quarter so the transcript still fits...
        assert_eq!(summary_output_budget(32_000, 16_384), 8_000);
        // ...but never below the previous cap.
        assert_eq!(summary_output_budget(8_000, 16_384), SUMMARY_MAX_TOKENS);
        assert_eq!(summary_output_budget(8_000, 1_000), 1_000);
    }

    #[test]
    fn image_tokens_counts_a_max_dimension_square_fully() {
        let attachment = |w, h| crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("x.png"),
            sha256: String::new(),
            width: w,
            height: h,
            bytes: 0,
            extension: "png".into(),
        };
        // A full MAX_DIMENSION square is the largest image `read_file` can send;
        // it must be charged its real w*h/750 cost (3,279), not clamped to the
        // historical 1,600 cap that undercounted it.
        let max = crate::attachment::MAX_DIMENSION;
        assert_eq!(image_tokens(&attachment(max, max)), 3_279);
        // Smaller images keep the plain w*h/750 estimate (floored at 1).
        assert_eq!(image_tokens(&attachment(100, 100)), 14);
        assert_eq!(image_tokens(&attachment(1, 1)), 1);
    }

    #[test]
    fn messages_tokens_with_vision_honors_the_newest_n_plan() {
        let img = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("x.png"),
            sha256: String::new(),
            width: 1000,
            height: 1000,
            bytes: 0,
            extension: "png".into(),
        };
        // Three image occurrences across two messages.
        let m0 = Message::user("first").with_attachments(vec![img.clone()]);
        let m1 = Message::user("second").with_attachments(vec![img.clone(), img.clone()]);
        let convo = [m0, m1];
        // Every occurrence is intact on disk (available), so the newest-N plan
        // alone decides image vs. placeholder.
        let all: AttachmentAvailability =
            convo.iter().flat_map(|m| m.attachments.iter()).map(|a| a as *const crate::llm::Attachment).collect();
        // The naive all-images sum: text/framing plus full image cost for every
        // attachment (what the wire does *not* send past the newest-N quota).
        let naive: usize =
            convo.iter().map(|m| message_text_tokens(m) + m.attachments.iter().map(image_tokens).sum::<usize>()).sum();
        let img_cost = image_tokens(&img);
        let ph_cost = text_tokens(&img.placeholder());
        assert!(img_cost > ph_cost, "a big image must cost more than its placeholder");

        // max_images = 1: only the newest occurrence is sent as an image; the
        // two older ones become placeholders. The saving over the naive
        // all-images sum is exactly two image→placeholder swaps.
        assert_eq!(naive - messages_tokens_with_vision(&convo, 1, &all), 2 * (img_cost - ph_cost));
        // max_images = 0 (no vision): every attachment becomes a placeholder.
        assert_eq!(naive - messages_tokens_with_vision(&convo, 0, &all), 3 * (img_cost - ph_cost));
        // max_images >= total attachments: identical to the all-images sum.
        assert_eq!(messages_tokens_with_vision(&convo, 3, &all), naive);
        assert_eq!(messages_tokens_with_vision(&convo, 99, &all), naive);
    }

    #[test]
    fn messages_tokens_charge_the_backfilled_image_when_the_newest_is_unavailable() {
        // The finding's exact shape: an older, available large image and a
        // newer, *missing* (tampered/deleted on resume) small image, under a
        // one-image quota. The wire plan excludes the unavailable newest from
        // the quota and backfills the slot with the available older image —
        // sending it in full — so the token estimate must do the same.
        let attachment = |w, h| crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("x.png"),
            sha256: String::new(),
            width: w,
            height: h,
            bytes: 0,
            extension: "png".into(),
        };
        let max = crate::attachment::MAX_DIMENSION;
        let big = attachment(max, max); // older, available
        let tiny = attachment(1, 1); // newer, unavailable on resume
        let convo = [Message::user("look").with_attachments(vec![big.clone(), tiny.clone()])];
        // Only the older `big` is intact on disk; `tiny`'s file is gone.
        let available: AttachmentAvailability =
            [&convo[0].attachments[0] as *const crate::llm::Attachment].into_iter().collect();

        // Availability-aware: `big` is charged in full (backfilled image), `tiny`
        // as a placeholder.
        let got = messages_tokens_with_vision(&convo, 1, &available);
        let want = message_text_tokens(&convo[0]) + image_tokens(&big) + text_tokens(&tiny.placeholder());
        assert_eq!(got, want, "the backfilled older image is charged in full");

        // The old occurrence-order estimate (availability-blind) would have
        // charged the newest `tiny` as the one image (1 token) and `big`, over
        // quota, as a placeholder — undercounting by nearly the whole image and
        // delaying compaction past the real limit.
        let buggy = message_text_tokens(&convo[0]) + text_tokens(&big.placeholder()) + image_tokens(&tiny);
        assert!(got > buggy + 3_000, "availability-aware estimate avoids the undercount: {got} vs {buggy}");
    }

    #[test]
    fn detects_overflow_errors_and_limits() {
        let openai = "HTTP 400: This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.";
        let anthropic = "HTTP 400: prompt is too long: 210000 tokens > 200000 maximum";
        let llamacpp = "HTTP 400: the request exceeds the available context size (8192 tokens), try increasing it";
        for (error, limit) in [(openai, 128_000), (anthropic, 200_000), (llamacpp, 8_192)] {
            assert!(is_context_overflow(error), "{error}");
            assert_eq!(limit_from_error(error), Some(limit), "{error}");
        }
        assert!(!is_context_overflow("HTTP 401: invalid api key"));
    }

    #[test]
    fn transcript_keeps_the_newest_messages() {
        let messages: Vec<Message> =
            (0..50).map(|i| Message::user(&format!("message {i} {}", "x".repeat(100)))).collect();
        let text = render_transcript(&messages, 1_000, false);
        assert!(text.starts_with("…[earlier messages omitted]…"));
        assert!(text.contains("message 49"));
        assert!(!text.contains("message 0 "));
    }

    #[test]
    fn transcript_labels_log_lines_when_asked() {
        let mut first = Message::user("find the bug");
        first.log_line = Some(7);
        let summary = Message::user(&format!("{SUMMARY_PREFIX} ..."));
        let text = render_transcript(&[summary.clone(), first.clone()], 10_000, true);
        assert!(text.starts_with("[earlier summary] USER:"), "{text}");
        assert!(text.contains("[#7] USER:\nfind the bug"), "{text}");
        assert!(!render_transcript(&[first], 10_000, false).contains("#7"));
        // A normal prompt that merely starts with '[' is not a summary.
        let mut bracketed = Message::user("[constraint] use port 8080");
        bracketed.log_line = None;
        assert!(!render_transcript(&[bracketed], 10_000, true).contains("[earlier summary]"));
        assert!(smart_summary_note(Some((2, 40))).contains("#2–#40"));
    }

    #[test]
    fn model_windows() {
        assert_eq!(window_for_model("claude-sonnet-4-5"), Some(200_000));
        assert_eq!(window_for_model("gpt-4.1-mini"), Some(1_047_576));
        assert_eq!(window_for_model("llama3"), None);
    }
}
