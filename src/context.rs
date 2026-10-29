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
    /// The timers status segment (`⏰ HH:MM`, `⏰ N next HH:MM`), when timers
    /// are set.
    pub timers: Option<String>,
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

/// A known maximum output-token cap for a model whose endpoint does **not**
/// publish one (issue #114). The automatic `max_tokens` default prefers the
/// endpoint-published limit; when none is published it must not blindly send
/// the large [`DEFAULT_MAX_OUTPUT_TOKENS`](crate::agent) fallback, which exceeds
/// the real output cap of several supported models — native OpenAI `gpt-4o` /
/// `gpt-4o-mini`, for instance, allow 16,384 output tokens but do not expose
/// that through `/models`, so an unset `max_tokens` with a short prompt would
/// otherwise send an over-cap request the API rejects. Only well-established
/// caps are listed; an unknown model still falls back to the large default.
pub fn output_limit_for_model(model: &str) -> Option<usize> {
    let m = model.to_lowercase();
    // Most specific needles first: substring matching must resolve, e.g.,
    // `gpt-4-turbo` before the broader `gpt-4` family would, and never let a
    // narrow cap shadow a larger one by accident.
    let table: &[(&str, usize)] = &[("gpt-4o", 16_384), ("gpt-4-turbo", 4_096), ("gpt-3.5", 4_096)];
    table.iter().find(|(needle, _)| m.contains(needle)).map(|(_, limit)| *limit)
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

/// Does this provider error say the request's `max_tokens` exceeded the model's
/// **output-token** cap (as opposed to the prompt overflowing the context
/// window)? With automatic `max_tokens` the agent falls back to the large
/// `DEFAULT_MAX_OUTPUT_TOKENS` for a model whose endpoint publishes no output
/// limit; a model whose real cap is smaller rejects every request until a
/// background capability probe lands, so this lets the agent learn the cap from
/// the rejection and retry (issue #114). Deliberately narrow — it must not
/// match a context-window overflow, which has its own recovery path.
pub fn is_output_cap_error(error: &str) -> bool {
    let e = error.to_lowercase();
    [
        "maximum allowed number of output tokens",
        "maximum number of output tokens",
        "maximum output tokens",
        "max_output_tokens",
        "completion tokens",
        "max_tokens is too large",
        "max_tokens too large",
        "max_tokens must be less than or equal to",
        "max_tokens: ",
    ]
    .iter()
    .any(|needle| e.contains(needle))
}

/// The output-token cap stated in an output-cap rejection error, if any.
pub fn output_cap_from_error(error: &str) -> Option<usize> {
    let patterns = [
        // Anthropic: "max_tokens: 32768 > 8192, which is the maximum …".
        r"(?i)max_tokens:\s*\d+\s*>\s*(\d+)",
        // OpenAI: "supports at most 16384 completion tokens".
        r"(?i)at most (\d+) completion tokens",
        // "maximum allowed number of output tokens is 8192".
        r"(?i)output tokens(?: for [^ ]+)? is (\d+)",
        r"(?i)maximum output tokens (?:is|of) (\d+)",
        // Azure/Copilot: "max_tokens must be less than or equal to 4096".
        r"(?i)max_tokens must be less than or equal to (\d+)",
        // "max_tokens is too large: 32768. … at most 16384 …" already covered;
        // a bare "maximum of 16384 output tokens".
        r"(?i)maximum of (\d+) (?:completion|output) tokens",
    ];
    patterns.iter().find_map(|p| Regex::new(p).ok()?.captures(error)?.get(1)?.as_str().parse().ok())
}

fn clip(text: &str, max_chars: usize) -> String {
    let total = text.chars().count();
    if total <= max_chars {
        return text.to_string();
    }
    // The omission marker is charged against the character allowance, so the
    // result never exceeds `max_chars`.
    let marker = format!("\n…[{} characters omitted]…\n", total - max_chars);
    let marker_len = marker.chars().count();
    if marker_len >= max_chars {
        // The allowance is smaller than the marker itself (reachable through a
        // nearly-exhausted pin budget): a full marker would exceed it, so fall
        // back to a bare head cut with no marker at all.
        return text.chars().take(max_chars).collect();
    }
    let budget = max_chars - marker_len;
    let head: String = text.chars().take(budget * 2 / 3).collect();
    let tail: String = {
        let chars: Vec<char> = text.chars().collect();
        chars[chars.len() - budget / 3..].iter().collect()
    };
    format!("{head}{marker}{tail}")
}

/// Maximum error lines pinned when clipping a tool result (issue #67).
const CLIP_ERROR_LINES: usize = 20;
/// Context lines kept around each pinned error line.
const CLIP_ERROR_CONTEXT: usize = 1;

/// A line worth pinning when a long tool result is clipped: the lines that
/// matter in build/test output (`error[E0308]`, `panicked at`, `FAILED`,
/// `Traceback`, …) usually sit in the middle, where head+tail clipping drops
/// them. The list stays small and fixed — no per-language logic. `warning:`
/// lines (e.g. `warning: unused`) are noise here and never pinned — even when
/// they name an error (`warning: unused import: std::error::Error`), so a
/// warning-heavy log cannot exhaust the pin allowance ahead of a real error.
fn is_error_line(line: &str) -> bool {
    let lower = line.trim_start().to_lowercase();
    if lower.starts_with("warning:") {
        return false;
    }
    lower.contains("error")
        || lower.contains("panic")
        || lower.contains("failed")
        || lower.contains("traceback")
        || lower.contains("exception")
}

/// Clip a tool result for the compaction transcript, keeping the head and tail
/// as `clip` does but also pinning up to [`CLIP_ERROR_LINES`] error lines from
/// the omitted middle, each with [`CLIP_ERROR_CONTEXT`] lines of context.
///
/// Structurally, the result is a *selection of whole lines* of the original
/// text (in order, each rendered at most once) with every omitted run replaced
/// by a gap marker — so a line can never be duplicated, and coverage is a
/// property of the one selection rather than of separately computed ranges.
/// Every line is admitted through a single charge against one `max_chars`
/// budget (its exact characters, newline/CRLF included, plus any change in the
/// number of gap markers), so the result can never exceed the budget.
/// Admission order: a small head and tail floor, then error lines not already
/// kept (whole; an oversized first one is budget-clipped), then their context,
/// then the remaining allowance grows the head (2/3) and tail (1/3).
fn clip_tool_result(text: &str, max_chars: usize) -> String {
    let total = text.chars().count();
    if total <= max_chars {
        return text.to_string();
    }
    // Newline-inclusive slices: every offset/length is in the original text's
    // own coordinates (a CRLF line is charged both bytes' characters).
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let bare = |i: usize| lines[i].trim_end_matches('\n').trim_end_matches('\r');
    let error_lines: Vec<usize> = (0..lines.len()).filter(|&i| is_error_line(bare(i))).collect();
    let marker = format!("…[{} characters omitted; error lines pinned]…\n", total - max_chars);
    let marker_len = marker.chars().count();
    if error_lines.is_empty() || max_chars < marker_len + 64 {
        return clip(text, max_chars);
    }
    const GAP: usize = 2; // "…\n" for every gap after the first
    let n = lines.len();
    let lens: Vec<usize> = lines.iter().map(|l| l.chars().count()).collect();
    let mut kept = vec![false; n];
    let mut clipped: Vec<Option<String>> = vec![None; n];
    // Nothing kept: one gap, rendered as the full marker.
    let mut used = marker_len;
    // The exact cost of keeping line `i` at `len` characters.
    let cost = |kept: &[bool], i: usize, len: usize| -> isize {
        let left = i > 0 && !kept[i - 1];
        let right = i + 1 < n && !kept[i + 1];
        let gaps_delta = left as isize + right as isize - 1;
        len as isize + gaps_delta * GAP as isize
    };
    let try_keep = |kept: &mut Vec<bool>, used: &mut usize, i: usize| -> bool {
        if kept[i] {
            return true;
        }
        let c = cost(kept, i, lens[i]);
        if (*used as isize + c) as usize > max_chars {
            return false;
        }
        *used = (*used as isize + c) as usize;
        kept[i] = true;
        true
    };
    // 1. Head and tail floors (whole lines), so both ends always show.
    let floor = (max_chars - marker_len) / 6;
    let mut head_end = 0; // first line index not in the head
    while head_end < n && lens[..=head_end].iter().sum::<usize>() <= floor && try_keep(&mut kept, &mut used, head_end) {
        head_end += 1;
    }
    let mut tail_start = n; // first line index of the tail
    while tail_start > head_end
        && lens[tail_start - 1..].iter().sum::<usize>() <= floor
        && try_keep(&mut kept, &mut used, tail_start - 1)
    {
        tail_start -= 1;
    }
    // 1b. An oversized boundary line would leave its end bare: keep a budgeted
    //     excerpt instead (head: prefix; tail: suffix), so the opening command
    //     and the closing exit status survive even when whole lines cannot fit.
    let excerpt = |s: &str, keep: usize, from_end: bool| -> String {
        let cs: Vec<char> = s.chars().collect();
        let k = keep.min(cs.len());
        if from_end {
            format!("…{}", cs[cs.len() - k..].iter().collect::<String>())
        } else {
            format!("{}…", cs[..k].iter().collect::<String>())
        }
    };
    let ends_nl = |i: usize| if lines[i].ends_with('\n') { 1 } else { 0 };
    if head_end == 0 && n > 1 && floor > 8 && !is_error_line(bare(0)) {
        let base = cost(&kept, 0, 0);
        let room = floor.min((max_chars as isize - used as isize - base).max(0) as usize);
        if room > 8 {
            let s = format!("{}{}", excerpt(bare(0), room - 2, false), if ends_nl(0) == 1 { "\n" } else { "" });
            let l = s.chars().count();
            if (used as isize + base + l as isize) as usize <= max_chars {
                used = (used as isize + base + l as isize) as usize;
                kept[0] = true;
                clipped[0] = Some(s);
                head_end = 1;
            }
        }
    }
    if tail_start == n && n > 1 && head_end < n && !kept[n - 1] && floor > 8 && !is_error_line(bare(n - 1)) {
        let i = n - 1;
        let base = cost(&kept, i, 0);
        let room = floor.min((max_chars as isize - used as isize - base).max(0) as usize);
        if room > 8 {
            let nl = ends_nl(i);
            let s = format!("{}{}", excerpt(bare(i), room - 1 - nl, true), if nl == 1 { "\n" } else { "" });
            let l = s.chars().count();
            if (used as isize + base + l as isize) as usize <= max_chars {
                used = (used as isize + base + l as isize) as usize;
                kept[i] = true;
                clipped[i] = Some(s);
                tail_start = i;
            }
        }
    }
    // 2. Pin error lines not already kept, whole while they fit; only the very
    //    first pin may be budget-clipped (keeping the line's head and end).
    let mut pinned: Vec<usize> = Vec::new();
    for &i in &error_lines {
        if kept[i] {
            continue; // already retained: no pin, no duplicate, no allowance spent
        }
        if pinned.len() == CLIP_ERROR_LINES {
            break;
        }
        if try_keep(&mut kept, &mut used, i) {
            pinned.push(i);
            continue;
        }
        if pinned.is_empty() {
            // Charge the clipped rendering (plus its newline) exactly.
            let base = cost(&kept, i, 0);
            let room = (max_chars as isize - used as isize - base - 1).max(0) as usize;
            let c = format!("{}\n", clip(bare(i), room));
            let c_len = c.chars().count();
            if (used as isize + base + c_len as isize) as usize <= max_chars {
                used = (used as isize + base + c_len as isize) as usize;
                kept[i] = true;
                clipped[i] = Some(c);
                pinned.push(i);
            }
        }
        break; // a later error that cannot fit whole stops pinning
    }
    // 3. Context around each pin, whole lines only, while they fit. A context
    //    line that is itself an unpinned error is not admitted.
    for &i in &pinned {
        let lo = i.saturating_sub(CLIP_ERROR_CONTEXT);
        let hi = (i + CLIP_ERROR_CONTEXT).min(n - 1);
        for j in lo..=hi {
            if !kept[j] && !is_error_line(bare(j)) {
                try_keep(&mut kept, &mut used, j);
            }
        }
    }
    // 4. Grow the head (2/3 of what is left) then the tail, then the head again.
    let spare = max_chars - used;
    let head_target = used + spare * 2 / 3;
    while head_end < n && !kept[head_end] {
        if (used as isize + cost(&kept, head_end, lens[head_end])) as usize > head_target {
            break;
        }
        try_keep(&mut kept, &mut used, head_end);
        head_end += 1;
    }
    while head_end < n && kept[head_end] {
        head_end += 1;
    }
    while tail_start > head_end && (kept[tail_start - 1] || try_keep(&mut kept, &mut used, tail_start - 1)) {
        tail_start -= 1;
    }
    while head_end < tail_start && (kept[head_end] || try_keep(&mut kept, &mut used, head_end)) {
        head_end += 1;
    }
    // Render: kept lines in order, the first gap as the full marker.
    let mut out = String::with_capacity(max_chars + 16);
    let mut first_gap = true;
    let mut in_gap = false;
    for i in 0..n {
        if kept[i] {
            in_gap = false;
            match &clipped[i] {
                Some(c) => out.push_str(c),
                None => out.push_str(lines[i]),
            }
        } else if !in_gap {
            in_gap = true;
            if first_gap {
                out.push_str(&marker);
                first_gap = false;
            } else {
                out.push_str("…\n");
            }
        }
    }
    debug_assert!(out.chars().count() <= max_chars, "clip budget exceeded");
    out
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
                let mut block = format!("TOOL {label} ({name}):\n{}", clip_tool_result(&message.content, 2_000));
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
    fn detects_output_cap_errors_and_their_limits() {
        // Real provider shapes for an over-cap `max_tokens` (issue #114).
        let anthropic = "HTTP 400: max_tokens: 32768 > 8192, which is the maximum allowed number of output tokens for claude-3-5-haiku";
        let openai = "HTTP 400: max_tokens is too large: 32768. This model supports at most 16384 completion tokens";
        let azure = "HTTP 400: max_tokens must be less than or equal to 4096";
        for (error, cap) in [(anthropic, 8_192), (openai, 16_384), (azure, 4_096)] {
            assert!(is_output_cap_error(error), "{error}");
            assert_eq!(output_cap_from_error(error), Some(cap), "{error}");
        }
        // A context-window overflow is NOT an output-cap error: it has its own
        // recovery path and must not be misrouted.
        let overflow = "HTTP 400: This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.";
        assert!(!is_output_cap_error(overflow), "{overflow}");
        assert!(!is_output_cap_error("HTTP 401: invalid api key"));
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
    fn clipped_tool_result_pins_an_error_line_from_the_middle() {
        // Issue #67: a 50k-character tool result with one `error:` line in the
        // middle — the clipped transcript must contain that line.
        let mut content = String::new();
        while content.len() < 30_000 {
            content.push_str("   Compiling lease-0.1.0 (/work/lease)\n");
        }
        content.push_str("error[E0599]: no method named `refresh_lease_v42_fast` found for struct `TokenCache`\n");
        while content.len() < 50_000 {
            content.push_str("test lease::tests::case_123 ... ok\n");
        }
        let message = Message::tool_result("call_1", "bash", &content);
        let text = render_transcript(&[message], 100_000, false);
        assert!(
            text.contains("error[E0599]: no method named `refresh_lease_v42_fast` found for struct `TokenCache`"),
            "the middle error line must survive clipping:\n{text}"
        );
        assert!(text.contains("error lines pinned"), "{text}");
    }

    #[test]
    fn clipped_tool_result_without_error_lines_clips_as_before() {
        let content = "x".repeat(50_000);
        let message = Message::tool_result("call_1", "bash", &content);
        let text = render_transcript(&[message], 100_000, false);
        assert!(text.contains("characters omitted"), "{text}");
        assert!(!text.contains("error lines pinned"), "{text}");
        assert_eq!(text, format!("TOOL result (bash):\n{}", clip(&content, 2_000)));
    }

    #[test]
    fn clipped_tool_result_never_exceeds_the_budget() {
        // Many error lines: pins are capped and the total stays within budget.
        let mut content = String::new();
        for i in 0..200 {
            content.push_str(&format!("error: failure number {i} in the middle of the log\n"));
            content.push_str(&"padding line to spread the diagnostics out across the log\n".repeat(20));
        }
        let message = Message::tool_result("call_1", "bash", &content);
        let text = render_transcript(std::slice::from_ref(&message), 1_000_000, false);
        let body = text.strip_prefix("TOOL result (bash):\n").unwrap();
        assert!(body.chars().count() <= 2_000, "budget exceeded: {} chars", body.chars().count());
        // Pins are capped at CLIP_ERROR_LINES error lines (each with context);
        // the head and tail (one padded error each per ~1,200 chars) may
        // naturally hold a couple more.
        assert!(body.matches("error: failure number").count() <= CLIP_ERROR_LINES + 4);
        // Directly: an error line in the omitted middle is pinned within budget.
        let buried = format!(
            "{}\ncompiling crate-a\nerror: boom\nnote: see above\n{}",
            "ordinary build output line\n".repeat(200),
            "test crate::case ... ok\n".repeat(200)
        );
        let clipped = clip_tool_result(&buried, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {} chars", clipped.chars().count());
        assert!(clipped.contains("error: boom"), "{clipped}");
        assert!(clipped.contains("note: see above"), "context line pinned too:\n{clipped}");
    }

    #[test]
    fn clipped_tool_result_pins_respect_cumulative_budget() {
        // Many separated windows, each small: together they must stay within
        // the pin budget, and the tail must survive (no plain-clip fallback).
        let mut content = "head line\n".repeat(300);
        for i in 0..20 {
            content.push_str(&format!("ctx before {i}\nerror: separated failure {i} {}\nctx after {i}\n", "x".repeat(40)));
            content.push_str(&"plain padding\n".repeat(30));
        }
        content.push_str("FINAL TAIL MARKER\n");
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error lines pinned"), "{clipped}");
        assert!(clipped.contains("FINAL TAIL MARKER"), "tail lost:\n{clipped}");
        assert!(clipped.contains("separated failure 0 "), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_shrunk_window_does_not_drop_later_windows() {
        // First window has huge context and shrinks to its error line; the
        // second, small window still fits and must be kept.
        let content = format!(
            "{}\n{}\nerror: first failure\n{}\n{}\nnote: a\nerror: second failure\nnote: b\n{}",
            "head\n".repeat(400),
            "c".repeat(1_200),
            "d".repeat(1_200),
            "pad\n".repeat(50),
            "tail\n".repeat(400)
        );
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: first failure"), "{clipped}");
        assert!(clipped.contains("error: second failure"), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_keeps_context_and_tail() {
        let mut content = String::new();
        for _ in 0..400 {
            content.push_str("ordinary build output line that nobody cares about\n");
        }
        content.push_str("  --> src/lease.rs:41:9\n");
        content.push_str("error[E0308]: mismatched types: expected `Lease`, found `()`\n");
        content.push_str("  = note: this error originates in the macro\n");
        for _ in 0..400 {
            content.push_str("more ordinary output after the failure\n");
        }
        content.push_str("error: could not compile `lease` due to 1 previous error\n");
        content.push_str("exit status: 101\n");
        let clipped = clip_tool_result(&content, 2_000);
        // The error line and one line of context on each side are pinned.
        assert!(clipped.contains("error[E0308]: mismatched types"), "{clipped}");
        assert!(clipped.contains("--> src/lease.rs:41:9"), "{clipped}");
        assert!(clipped.contains("= note: this error originates"), "{clipped}");
        // The tail (exit status) survives.
        assert!(clipped.contains("exit status: 101"), "{clipped}");
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
    }

    #[test]
    fn error_line_detection_is_small_and_fixed() {
        assert!(is_error_line("error[E0308]: mismatched types"));
        assert!(is_error_line("thread 'main' panicked at src/store.rs:10"));
        assert!(is_error_line("test result: FAILED. 3 passed; 2 failed"));
        assert!(is_error_line("Traceback (most recent call last):"));
        assert!(is_error_line("java.lang.IllegalStateException: boom"));
        assert!(!is_error_line("warning: unused variable: `tmp`"));
        assert!(!is_error_line("warning: unused import: std::error::Error"));
        assert!(!is_error_line("  warning: previous error occurred here"));
        assert!(!is_error_line("WARNING: the build failed to cache"));
        assert!(!is_error_line("   Compiling lease-0.1.0 (/work/lease)"));
        assert!(!is_error_line("test lease::tests::case_123 ... ok"));
    }

    #[test]
    fn clipped_tool_result_ignores_warnings_that_name_errors() {
        // A warning-heavy log must not exhaust the pin allowance: twenty
        // warnings containing error keywords precede the real compiler error.
        let mut content = String::new();
        for i in 0..40 {
            content.push_str(&format!("warning: unused import: std::error::Error (number {i})\n"));
        }
        content.push_str("error[E0308]: mismatched types: expected `Lease`, found `()`\n");
        for _ in 0..400 {
            content.push_str("ordinary build output line that nobody cares about\n");
        }
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.contains("error[E0308]: mismatched types"), "{clipped}");
        // The head still shows the log's opening warnings (that is plain
        // head/tail clipping), but the pinned window around the error must
        // hold no warning line.
        let window = clipped
            .lines()
            .skip_while(|l| !l.contains("error[E0308]"))
            .take(3)
            .collect::<Vec<_>>();
        assert!(
            window.iter().all(|l| !l.contains("warning:")),
            "warnings must not be pinned:\n{clipped}"
        );
    }

    #[test]
    fn clipped_tool_result_clips_context_before_the_error_line() {
        // A 56-character error between two 1,200-character context lines: the
        // window cannot fit the pin budget, so the context clips — the error
        // line itself is reserved and must survive whole.
        let pad = "x".repeat(1_200);
        let mut content = "ordinary build output line\n".repeat(200);
        content.push_str(&format!("{pad}\nerror[E0308]: mismatched types: expected `Lease`, found `()`\n{pad}\n"));
        content.push_str(&"more ordinary output after the failure\n".repeat(200));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.contains("error[E0308]: mismatched types: expected `Lease`, found `()`"), "{clipped}");
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
    }

    #[test]
    fn clipped_tool_result_keeps_every_error_of_a_merged_window() {
        // Two errors three lines apart merge into one window whose context
        // cannot fit: both error lines survive even when the context drops.
        let pad = "y".repeat(900);
        let mut content = "ordinary build output line\n".repeat(200);
        content.push_str(&format!(
            "{pad}\nerror[E0308]: first failure here\n{pad}\nerror[E0599]: second failure here\n{pad}\n"
        ));
        content.push_str(&"more ordinary output after the failure\n".repeat(200));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.contains("error[E0308]: first failure here"), "{clipped}");
        assert!(clipped.contains("error[E0599]: second failure here"), "{clipped}");
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
    }

    #[test]
    fn clip_stays_within_budget_marker_included() {
        // The omission marker is charged against the allowance: the result of
        // `clip` never exceeds `max_chars`, even for a single oversized line.
        for max in [40, 100, 2_000] {
            let big = "x".repeat(10_000);
            let clipped = clip(&big, max);
            assert!(clipped.chars().count() <= max, "clip exceeded {max}: {}", clipped.chars().count());
            assert!(clipped.contains("characters omitted"), "{clipped}");
        }
        // A multi-line text clips the same way.
        let text = "line of build output\n".repeat(500);
        assert!(clip(&text, 300).chars().count() <= 300);
    }

    #[test]
    fn clip_stays_within_a_sub_marker_budget() {
        // An allowance smaller than the omission marker itself (reachable
        // through a nearly-exhausted pin budget): the marker must not push
        // the result over the limit — `clip` falls back to a bare head cut.
        let big = "x".repeat(10_000);
        for max in [0, 1, 8, 20, 28] {
            let clipped = clip(&big, max);
            assert!(clipped.chars().count() <= max, "clip exceeded {max}: {}", clipped.chars().count());
        }
        // Just above the marker length the marker fits again.
        let clipped = clip(&big, 40);
        assert!(clipped.contains("characters omitted"), "{clipped}");
        assert!(clipped.chars().count() <= 40);
    }

    #[test]
    fn clipped_tool_result_does_not_pin_errors_the_head_already_retains() {
        // Twenty short errors at the start of the log already fit in the
        // rendered head: pinning them would duplicate them and exhaust the
        // pin allowance, losing the diagnostic buried in the middle.
        let mut content = String::new();
        for i in 0..20 {
            content.push_str(&format!("error: NN {i}\n"));
        }
        content.push_str(&"ordinary build output line that pads the log out\n".repeat(300));
        content.push_str("error: buried middle diagnostic\n");
        content.push_str(&"more ordinary output after the failure\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: buried middle diagnostic"), "middle diagnostic lost:\n{clipped}");
        // The head errors appear once each — pinned copies would double them.
        assert_eq!(clipped.matches("error: NN 0\n").count(), 1, "head error duplicated by a pin:\n{clipped}");
    }

    #[test]
    fn clipped_tool_result_does_not_pin_an_error_the_tail_already_retains() {
        // Errors at the very end of the log are retained by the tail; the
        // buried one must get the pin allowance instead.
        let mut content = "ordinary build output line that pads the log out\n".repeat(300);
        content.push_str("error: buried middle diagnostic\n");
        content.push_str(&"more ordinary output after the failure\n".repeat(300));
        for i in 0..5 {
            content.push_str(&format!("error: final failure {i}\n"));
        }
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: buried middle diagnostic"), "middle diagnostic lost:\n{clipped}");
        assert!(clipped.contains("error: final failure 4"), "tail error lost:\n{clipped}");
        assert_eq!(clipped.matches("error: final failure 4").count(), 1, "tail error duplicated:\n{clipped}");
    }

    #[test]
    fn clipped_tool_result_borrows_head_tail_allowance_for_a_long_error_line() {
        // A buried error line longer than the pin share but shorter than the
        // whole budget: it is kept *complete* — the head and tail lend it
        // their unused allowance — instead of being cut mid-line.
        let diagnostic = "MID-LINE-DIAGNOSTIC-THAT-MUST-SURVIVE";
        let mut content = "ordinary build output line that pads the log out\n".repeat(300);
        content.push_str(&format!("error: {} {diagnostic} {}\n", "x".repeat(600), "y".repeat(600)));
        content.push_str(&"more ordinary output after the failure\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains(diagnostic), "mid-line diagnostic lost:\n{clipped}");
        // Kept whole: no omission marker inside the error line.
        let line = clipped.lines().find(|l| l.contains(diagnostic)).unwrap();
        assert!(!line.contains("characters omitted"), "error line clipped mid-line:\n{line}");
    }

    #[test]
    fn clipped_tool_result_keeps_tail_excerpt_when_all_preceding_lines_fit() {
        let content = format!("cargo test\nerror: boom\n{}exit status: 101", "x".repeat(2500));
        let clipped = clip_tool_result(&content, 2000);
        assert!(clipped.chars().count() <= 2000, "{}", clipped.chars().count());
        assert!(clipped.starts_with("cargo test\n"), "{clipped}");
        assert!(clipped.contains("exit status: 101"), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_keeps_a_budgeted_excerpt_of_a_context_line_at_the_budget_edge() {
        // The original finding's shape: the single context line is at least
        // `context_budget` long, so the excerpt necessarily clips. With the
        // marker charged to the allowance the excerpt fits and is kept.
        // (Small explicit budget: pin_budget = 100. The error is the first
        // line, so the window is exactly [error, oversized-context] and the
        // excerpt lands between the error and the window separator.)
        let error = "error: boom happened here";
        let content = format!(
            "{error}\n{}\n{}",
            "c".repeat(260),
            "tail line of test output\n".repeat(40)
        );
        let clipped = clip_tool_result(&content, 200);
        assert!(clipped.chars().count() <= 200, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains(error), "{clipped}");
        // The pinned window holds the budgeted excerpt (marker and all) —
        // unless the head retained the error line whole, in which case the
        // pin is redundant and the excerpt drops with it.
        if clipped.starts_with(&format!("{error}\n")) {
            // Retained by the head: nothing to pin, no excerpt owed.
            return;
        }
        let pinned = clipped.split_once("error lines pinned]…\n").expect("pin marker").1;
        let window: Vec<&str> = pinned.split_once("\n…\n").map(|(w, _)| w).unwrap_or(pinned).lines().collect();
        assert!(
            window.iter().any(|l| l.contains("characters omitted]…")),
            "context excerpt lost from the pinned window: {window:?}\nfull output:\n{clipped}"
        );
        assert!(window.iter().any(|l| l.contains(error)), "error line lost from the pinned window:\n{clipped}");
    }


    #[test]
    fn clipped_tool_result_drops_multi_context_that_cannot_fit_but_keeps_the_error() {
        // Two oversized context lines around the error: per-line excerpts would
        // cost a marker line each, so the context drops whole — the error line
        // is reserved and must survive, within budget.
        let error = "error[E0308]: mismatched types";
        let pad = "c".repeat(1_500);
        let mut content = "head\n".repeat(600);
        content.push_str(&format!("{pad}\n{error}\n{pad}\n"));
        content.push_str(&"tail\n".repeat(600));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains(error), "{clipped}");
        let window = clipped
            .lines()
            .skip_while(|l| !l.contains("error lines pinned"))
            .skip(1)
            .take(3)
            .collect::<Vec<_>>();
        assert!(window.iter().any(|l| l.contains(error)), "error line lost from the pinned window:\n{clipped}");
    }

    #[test]
    fn clipped_tool_result_window_ends_before_the_first_unselected_error() {
        // A matching line right after the 20th selected error must not ride
        // along inside the last window uncharged: with a huge such line the
        // budget must still hold, and that line must not be rendered.
        let mut content = "head\n".repeat(300);
        for i in 0..CLIP_ERROR_LINES {
            content.push_str(&format!("error: selected failure {i}\n"));
            content.push_str("ctx\n");
        }
        content.push_str(&format!("error: unselected huge {}\n", "u".repeat(5_000)));
        content.push_str(&"tail\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: selected failure 0"), "{clipped}");
        assert!(!clipped.contains("uuuu"), "unselected error leaked into a window:\n{clipped}");
        assert!(clipped.contains("error lines pinned"), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_keeps_complete_diagnostics_before_clipping() {
        // Twenty adjacent 80-character errors form one window whose bare error
        // lines overflow the pin budget: complete lines are kept while they
        // fit instead of every diagnostic being cut to a sliver.
        let mut content = "head\n".repeat(300);
        for i in 0..20 {
            content.push_str(&format!("error: adjacent failure {i:02} {}\n", "e".repeat(50)));
        }
        content.push_str(&"tail\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: adjacent failure 00 "), "{clipped}");
        let kept = (0..20).filter(|i| clipped.contains(&format!("error: adjacent failure {i:02} "))).count();
        assert!(kept >= 10, "complete lines must be kept while they fit, kept {kept}:\n{clipped}");
        // A kept line is complete, not a 49-character sliver.
        assert!(clipped.contains(&format!("error: adjacent failure 00 {}", "e".repeat(50))), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_budget_clip_keeps_the_end_of_an_oversized_error_line() {
        // A single error line longer than the whole pin budget: the budgeted
        // head-and-tail clip keeps a diagnostic near the line's *end*.
        let mut content = "head\n".repeat(300);
        content.push_str(&format!("error: {} TAIL-DIAGNOSTIC-AT-END\n", "x".repeat(3_000)));
        content.push_str(&"tail\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("TAIL-DIAGNOSTIC-AT-END"), "the line's end is lost:\n{clipped}");
    }

    #[test]
    fn clipped_tool_result_long_errors_at_both_ends_stay_within_budget() {
        // Long errors at both boundaries plus a buried pin: head and tail
        // growth share one allowance, so the budget holds.
        let long = |tag: &str| format!("error: {tag} {}\n", "z".repeat(700));
        let mut content = "intro\n".repeat(40);
        content.push_str(&long("HEAD-END"));
        content.push_str(&"pad line\n".repeat(400));
        content.push_str("error: buried pin\n");
        content.push_str(&"pad line\n".repeat(400));
        content.push_str(&long("TAIL-START"));
        content.push_str(&"outro\n".repeat(40));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert!(clipped.contains("error: buried pin"), "{clipped}");
    }

    #[test]
    fn clipped_tool_result_handles_crlf_offsets() {
        // CRLF lines: coverage must use the original coordinates, so a buried
        // error is never mistaken for one the head already retains.
        let mut content = "ordinary build output line\r\n".repeat(300);
        content.push_str("error: crlf buried diagnostic\r\n");
        content.push_str(&"more output after\r\n".repeat(300));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert_eq!(clipped.matches("error: crlf buried diagnostic").count(), 1, "{clipped}");
    }

    #[test]
    fn clipped_tool_result_keeps_head_errors_when_a_long_pin_needs_room() {
        // An early diagnostic retained by the head must not vanish when a long
        // middle error needs room, and no error is ever rendered twice.
        let mut content = "intro\n".repeat(30);
        content.push_str("error: early diagnostic\n");
        content.push_str(&"pad line\n".repeat(400));
        content.push_str(&format!("error: long middle {}\n", "m".repeat(1_300)));
        content.push_str(&"pad line\n".repeat(400));
        let clipped = clip_tool_result(&content, 2_000);
        assert!(clipped.chars().count() <= 2_000, "budget exceeded: {}", clipped.chars().count());
        assert_eq!(clipped.matches("error: early diagnostic").count(), 1, "{clipped}");
        assert_eq!(clipped.matches("error: long middle").count(), 1, "{clipped}");
    }

    #[test]
    fn clipped_tool_result_never_duplicates_a_line_and_holds_the_budget() {
        // Property sweep over adjacent long errors near the head/tail
        // boundaries: every rendered error line is unique and the budget holds.
        for budget in [300, 700, 2_000] {
            for pad in [0, 5, 37, 120] {
                for err_len in [10, 400, 900] {
                    let mut content = "h\n".repeat(pad);
                    for k in 0..4 {
                        content.push_str(&format!("error: E{k} {}\n", "q".repeat(err_len)));
                    }
                    content.push_str(&"m\n".repeat(500));
                    for k in 4..8 {
                        content.push_str(&format!("error: E{k} {}\n", "q".repeat(err_len)));
                    }
                    content.push_str(&"t\n".repeat(pad));
                    let clipped = clip_tool_result(&content, budget);
                    assert!(clipped.chars().count() <= budget, "{budget}/{pad}/{err_len}: {}", clipped.chars().count());
                    for k in 0..8 {
                        assert!(clipped.matches(&format!("error: E{k} ")).count() <= 1, "dup E{k}:\n{clipped}");
                    }
                }
            }
        }
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

    #[test]
    fn model_output_limits() {
        // Known caps for models whose endpoint does not publish one (issue #114).
        assert_eq!(output_limit_for_model("gpt-4o"), Some(16_384));
        assert_eq!(output_limit_for_model("gpt-4o-mini"), Some(16_384));
        assert_eq!(output_limit_for_model("GPT-4O-MINI"), Some(16_384), "case-insensitive");
        assert_eq!(output_limit_for_model("gpt-4-turbo"), Some(4_096));
        assert_eq!(output_limit_for_model("gpt-3.5-turbo"), Some(4_096));
        // Models with large or unknown caps keep the large fallback (None here).
        assert_eq!(output_limit_for_model("gpt-4.1"), None);
        assert_eq!(output_limit_for_model("claude-sonnet-4-5"), None);
        assert_eq!(output_limit_for_model("some-unlisted-model"), None);
    }
}

#[cfg(test)]
mod boundary_excerpt_tests {
    use super::*;

    #[test]
    fn clipped_tool_result_keeps_excerpts_of_oversized_boundary_lines() {
        let first = format!("$ cargo test {}", "a".repeat(2500));
        let last = format!("{} exit status: 101", "b".repeat(2500));
        let text = format!("{first}\nerror: boom\n{last}");
        let out = clip_tool_result(&text, 2000);
        assert!(out.chars().count() <= 2000);
        assert!(out.starts_with("$ cargo test"), "{out}");
        assert!(out.ends_with("exit status: 101"), "{out}");
        assert_eq!(out.matches("error: boom").count(), 1);

        let text = format!("{first}\nerror: boom\n{last}\n");
        let out = clip_tool_result(&text, 2000);
        assert!(out.chars().count() <= 2000);
        assert!(out.starts_with("$ cargo test"));
        assert!(out.ends_with("exit status: 101\n"));
    }
}
