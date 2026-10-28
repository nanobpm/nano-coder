//! System reminders: short notes appended to tool results so the model sees
//! harness state at the moment it matters (an idea from grok-build).

use crate::plan::{Plan, Status};
use serde_json::Value;
use sha2::Digest;

/// Remind about a stale plan after this many tool calls without a plan change.
pub const PLAN_STALE_AFTER: usize = 12;
/// Suggest a plan after this many tool calls in one turn without one.
pub const SUGGEST_PLAN_AFTER: usize = 10;
/// Suggest saving a memory after this many tool calls without a save.
pub const SUGGEST_MEMORY_AFTER: usize = 30;
/// Warn after this many consecutive repeats of the same tool call.
pub const REPEAT_WARN_AFTER: usize = 3;
/// How often the repeat warning may fire in one turn before the hard stop.
pub const REPEAT_MAX_WARNINGS: usize = 2;
/// Consecutive repeats of the *current* key required before a hard stop, on top
/// of the spent warning budget. The warning budget (`repeat_warnings`) is
/// turn-global on purpose — a model that ignored two warnings on earlier
/// streaks has shown it is not reading them, so a fresh streak need not re-earn
/// the whole budget. But the budget alone must not hard-stop a *different* key
/// the moment it first reaches `REPEAT_WARN_AFTER`: an `A,A,A` (warn), change,
/// `B,B,B` (warn), change, `C,C,C` sequence would otherwise hard-stop `C` on its
/// third occurrence even though `C` never ignored a warning (the generated
/// summary would also falsely claim this call kept repeating after two
/// warnings). Gating the hard stop on this many *consecutive* matches of the
/// current key means an unrelated retry still cannot trip it prematurely. Set to
/// `REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS` so a single sustained streak still
/// hard-stops on exactly the call after its warnings are spent (issue #65).
pub const REPEAT_HARD_STOP_AFTER: usize = REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS;

/// Tools where repeating the same call is legitimate (waiting on a person):
/// the loop detector never counts them. Only ever-available tools belong here.
/// Plan tools are deliberately **not** listed: when `plan_tools` is enabled the
/// agent already breaks the streak for them via `reset_repeat` (`is_plan_tool`
/// in `agent.rs`), and when it is *disabled* the tool is unregistered, so an
/// exemption would let repeated hallucinated `plan_*` calls (each returning the
/// same `Tool '…' not found` error) loop forever undetected.
const REPEAT_EXEMPT_TOOLS: &[&str] = &["question"];

/// What the loop detector decided about the tool call just recorded.
#[derive(Debug, Default, PartialEq, Eq)]
pub enum RepeatVerdict {
    /// Nothing remarkable.
    #[default]
    None,
    /// The same call repeated `REPEAT_WARN_AFTER` times in a row: warn.
    Warning(String),
    /// Warnings are exhausted and the call repeated again: end the turn.
    HardStop(String),
}

/// Out-of-band content identity for one tool call's result, supplied by the
/// producer rather than parsed out of the rendered text (issue #65).
#[derive(Debug, Default, Clone, Copy)]
pub struct ContentHashes<'a> {
    /// Content hashes of any image attachments on the result: a `read_file` of
    /// a *changing* image returns identical metadata text while the bytes
    /// differ, so the fingerprint must fold these in to tell the calls apart.
    pub attachments: &'a [&'a str],
    /// The bounder-supplied identity of each capture it truncated and spilled
    /// while producing this result (`bash::run_digest`,
    /// `output::bound_and_spill_digest`, `history::read_digest`). Carrying the
    /// digest **and the exact marker path** out of band is what lets the
    /// fingerprint normalise exactly the genuine marker's volatile per-call
    /// path without trusting a digest parsed out of the rendered —
    /// model-influenceable — text, and without touching any other
    /// marker-looking text (a digest-free look-alike in stderr or hook
    /// context).
    pub spills: &'a [&'a crate::output::Spill],
}

/// Wrap reminder text in `<system-reminder>` tags.
pub fn wrap(text: &str) -> String {
    format!("<system-reminder>\n{text}\n</system-reminder>")
}

/// Tool-call counters behind the plan reminders.
#[derive(Debug, Default)]
pub struct Reminders {
    since_plan_change: usize,
    this_turn: usize,
    suggested_plan: bool,
    since_memory_save: usize,
    suggested_memory: bool,
    /// Consecutive repeats of `repeat_key`; 1 while the last call was unique.
    repeat_count: usize,
    /// Fingerprint of the last counted call (see `repeat_key`).
    repeat_key: Option<String>,
    /// The raw `bash` command of the last counted call, if any. Lets the
    /// detector tell an appended/identical read-only diagnostic tail (a real
    /// loop) from a *changed* diagnostic argument that strips to the same base
    /// (`is_diagnostic_extension`), so the latter is not conflated into a false
    /// repeat (issue #65).
    repeat_cmd: Option<String>,
    /// Repeat warnings already fired this turn (capped, so the nudge cannot
    /// become a loop itself).
    repeat_warnings: usize,
    /// Whether the `report_outcome` tool is offered this session. When it is
    /// disabled (`outcome_tool = false` removes it from the model's tool list),
    /// the repeat warning must not point the model at a tool it cannot call —
    /// doing so just provokes "tool not found" calls (issue #65).
    outcome_tool: bool,
}

impl Reminders {
    /// Build knowing whether `report_outcome` is offered this session, so the
    /// repeat warning only names it as an escape hatch when the model can
    /// actually call it.
    pub fn new(outcome_tool: bool) -> Self {
        Self { outcome_tool, ..Self::default() }
    }

    pub fn start_turn(&mut self) {
        self.this_turn = 0;
        self.repeat_count = 0;
        self.repeat_key = None;
        self.repeat_cmd = None;
        self.repeat_warnings = 0;
    }

    pub fn plan_changed(&mut self) {
        self.since_plan_change = 0;
    }

    pub fn memory_saved(&mut self) {
        self.since_memory_save = 0;
        self.suggested_memory = true;
    }

    /// Break the current repeat streak without counting a call. Interleaved
    /// calls the loop detector never counts — exempt tools, and the plan/outcome
    /// calls the caller skips — use this so they are not *transparent* to the
    /// streak: `bash A`, `question`, `bash A`, `question`, `bash A` is three
    /// non-consecutive `bash A` calls, not three in a row, so only genuinely
    /// consecutive calls can warn or hard-stop (issue #65).
    pub fn reset_repeat(&mut self) {
        self.repeat_count = 0;
        self.repeat_key = None;
        self.repeat_cmd = None;
    }

    /// Count a (non-plan) tool call and return any reminders for its result.
    /// `memory_writable`: `memory_save` is offered, so suggesting it is useful.
    pub fn after_tool_call(&mut self, plan: &Plan, memory_writable: bool) -> Vec<String> {
        self.since_plan_change += 1;
        self.this_turn += 1;
        self.since_memory_save += 1;
        let mut notes = Vec::new();
        if memory_writable && !self.suggested_memory && self.since_memory_save >= SUGGEST_MEMORY_AFTER {
            self.suggested_memory = true;
            notes.push(format!(
                "{} tool calls without a memory save. If this work taught you something durable that a future \
                 session would have to rediscover (a correction from the user, a preference, a decision, costly \
                 setup), save it with memory_save. If not, carry on.",
                self.since_memory_save
            ));
        }
        if plan.is_empty() {
            if !self.suggested_plan && self.this_turn >= SUGGEST_PLAN_AFTER {
                self.suggested_plan = true;
                notes.push(format!(
                    "This task has taken {} tool calls so far. If several steps remain, record them with plan_add: \
                     the plan survives when older messages are summarized away.",
                    self.this_turn
                ));
            }
        } else if self.since_plan_change.is_multiple_of(PLAN_STALE_AFTER) {
            let open = |status| plan.items.iter().find(|item| item.status == status);
            let focus = match (open(Status::InProgress), open(Status::Pending)) {
                (Some(item), _) => Some(format!("#{} \"{}\" is still in progress", item.id, item.title)),
                (None, Some(item)) => Some(format!("no item is in progress; next is #{} \"{}\"", item.id, item.title)),
                (None, None) => None,
            };
            if let Some(focus) = focus {
                notes.push(format!(
                    "Your plan has not changed in {} tool calls and {focus}. Use plan_update to mark finished \
                     items done and to note findings you will need later.",
                    self.since_plan_change
                ));
            }
        }
        notes
    }

    /// Loop detector: record one tool call and its result, and decide whether
    /// the model is stuck repeating itself (issue #65). `result` is the text
    /// the model sees; `ok` is whether the call succeeded.
    ///
    /// A call is a repeat when it matches the previous one on the tool, the
    /// normalised arguments (for `bash`, the base command with any trailing run
    /// of read-only diagnostic pipeline stages stripped — a loop that appends
    /// `| wc -l`/`| grep …`-style stages still matches), the error flag and
    /// a hash of the result, so "same output again" counts even when the
    /// arguments drift. For `bash` the match additionally requires the two raw
    /// commands to be a diagnostic *extension* of one another, so a changed
    /// diagnostic argument that strips to the same base (`… | grep alpha` then
    /// `… | grep beta`) is a fresh inspection that breaks the streak rather than
    /// a false repeat. The warning fires at `REPEAT_WARN_AFTER` consecutive
    /// repeats and at most `REPEAT_MAX_WARNINGS` times per turn; once the
    /// warnings are spent, a further repeat is a hard stop.
    /// `raw_args` is an optional override for the fingerprint's argument
    /// component. A call whose argument JSON never decoded carries
    /// `arguments = {}` (see `ToolCall::split_arguments`), so two *distinct*
    /// malformed payloads would otherwise share the same empty object — and the
    /// model-facing error embeds only the first 300 characters of each, so two
    /// payloads that diverge only after that prefix would also produce the same
    /// result hash. Both collapse to one fingerprint and the fifth
    /// genuinely-different malformed call is hard-stopped as an identical repeat
    /// (issue #65). Passing the full raw malformed text as `raw_args` keeps
    /// those argument changes visible in the fingerprint; a well-formed call
    /// passes `None` and fingerprints its decoded `args`.
    /// `hashes` carries the out-of-band content identity for the result (see
    /// [`ContentHashes`]): the content hash of each image attachment, and the
    /// bounder-supplied digest of each spilled capture. Passing the spill digest
    /// out of band is what lets the fingerprint normalise the marker's volatile
    /// per-call path without ever trusting a digest parsed out of the rendered —
    /// model-influenceable — text: an embedded look-alike marker in the output
    /// can no longer hide the genuine marker's digest behind a greedy regex
    /// match (issue #65). Pass `ContentHashes::default()` for a plain text
    /// result with no attachments and no known spill.
    pub fn after_repeat_call(
        &mut self,
        tool: &str,
        args: &Value,
        raw_args: Option<&str>,
        ok: bool,
        result: &str,
        hashes: ContentHashes,
    ) -> RepeatVerdict {
        if REPEAT_EXEMPT_TOOLS.contains(&tool) {
            self.reset_repeat();
            return RepeatVerdict::None;
        }
        let key = repeat_key(tool, args, raw_args, ok, result, hashes);
        let cmd = (tool == "bash").then(|| args.get("command").and_then(Value::as_str)).flatten().map(str::to_string);
        // Same grouping key (tool + stripped base + error + output hash) is
        // necessary but, for a bash command, not sufficient: the stripped base
        // is identical when only a trailing diagnostic *argument* changed, so
        // require the raw commands to be a diagnostic extension of one another
        // before counting a repeat. A non-bash call has no command and matches
        // on the key alone.
        let is_repeat = self.repeat_key.as_deref() == Some(key.as_str())
            && match (&self.repeat_cmd, &cmd) {
                (Some(prev), Some(cur)) => is_diagnostic_extension(prev, cur),
                (None, None) => true,
                // A bash/non-bash transition that still shares a key is not a
                // genuine repeat of the same call.
                _ => false,
            };
        self.repeat_count = if is_repeat { self.repeat_count + 1 } else { 1 };
        self.repeat_key = Some(key);
        self.repeat_cmd = cmd;
        if self.repeat_count < REPEAT_WARN_AFTER {
            return RepeatVerdict::None;
        }
        let times = self.repeat_count;
        let outcome = if ok { "the same result" } else { "the same error" };
        if self.repeat_warnings < REPEAT_MAX_WARNINGS {
            self.repeat_warnings += 1;
            // Only offer `report_outcome` as the escape hatch when it is
            // actually available this session; otherwise keep the nudge
            // actionable without naming a tool the model cannot call.
            let escape = if self.outcome_tool {
                ", or call report_outcome with status \"blocked\" and say what you tried"
            } else {
                ""
            };
            RepeatVerdict::Warning(format!(
                "You have now made this same `{tool}` call {times} times in a row with {outcome}. Repeating it \
                 will not change anything. Change approach: try something different{escape}."
            ))
        } else if self.repeat_count >= REPEAT_HARD_STOP_AFTER {
            RepeatVerdict::HardStop(format!(
                "the model repeated the same `{tool}` call {times} times in a row with {outcome}, and kept \
                 repeating it after {REPEAT_MAX_WARNINGS} warnings already issued this turn to change approach"
            ))
        } else {
            // The turn's global warning budget is spent, but *this* key has not
            // repeated enough on its own to hard-stop yet — it is a different
            // call from the one(s) that earned the warnings, so stay silent
            // until it genuinely loops `REPEAT_HARD_STOP_AFTER` times in a row.
            RepeatVerdict::None
        }
    }
}

/// Fingerprint one tool call for the loop detector: the tool name, the
/// normalised arguments, whether the call failed, and a hash of the result.
/// `raw_args`, when present, replaces the (empty) decoded arguments in the
/// fingerprint — it carries the full malformed argument text so two distinct
/// malformed payloads are not conflated (see `after_repeat_call`).
/// `hashes.spills` carries the bounder-supplied identity (digest + exact
/// marker path) of each spilled capture (see [`ContentHashes`]); when it is
/// non-empty the marker's volatile path is normalised *without* trusting any
/// digest inside the rendered text.
fn repeat_key(
    tool: &str,
    args: &Value,
    raw_args: Option<&str>,
    ok: bool,
    result: &str,
    hashes: ContentHashes,
) -> String {
    let args = match raw_args {
        Some(raw) => raw.to_string(),
        None => normalised_args(tool, args),
    };
    let result = normalise_spill_paths(result, hashes.spills);
    let mut hasher = sha2::Sha256::new();
    hasher.update(result.as_bytes());
    // Fold each attachment's content hash into the result fingerprint, so a
    // changing image (identical metadata text, different bytes) is told apart
    // by what the model actually received (issue #65).
    for sha in hashes.attachments {
        hasher.update(b"\x00img:");
        hasher.update(sha.as_bytes());
    }
    // Fold each bounder-supplied spill digest in too: the digest is the
    // complete capture's identity, so two bounded previews whose head, tail
    // and byte count match but whose truncated-away content differs are told
    // apart without the fingerprint ever parsing the marker's digest out of
    // the rendered (model-influenceable) text (issue #65).
    for spill in hashes.spills {
        hasher.update(b"\x00spill:");
        hasher.update(spill.digest.as_bytes());
    }
    let mut result_hash = [0u8; 8];
    result_hash.copy_from_slice(&hasher.finalize()[..8]);
    format!("{tool}|{args}|err={ok:?}|out={:x?}", result_hash)
}

/// Strip the per-call spill filename the output bounder injects before the
/// result is hashed. A bounded result embeds a `complete output in <path>…`
/// marker whose path is unique to the call (`bash-<n>.stdout`/`.stderr` from
/// `bash.rs`, `tool-<call-id>-<name>.txt` from `agent.rs`), so two *identical*
/// large outputs would otherwise hash differently on every invocation and the
/// loop detector would never warn or hard-stop — the exact runaway case this
/// feature exists to catch (issue #65). Only the path *inside that marker* is
/// normalised, never arbitrary output: genuine content that merely resembles a
/// spill name (e.g. `created tool-a.txt` vs `created tool-b.txt`) must stay
/// distinct, or a changing result would be conflated into a false repeat.
///
/// `spills` is the bounder-supplied identity (digest + exact marker path) of
/// each capture it spilled while producing this result (see
/// `after_repeat_call`). When it is non-empty the normaliser rewrites **only
/// the marker carrying each supplied path** — the spill's identity rides in
/// `spills`, so nothing here trusts a digest parsed out of the rendered text,
/// and no other marker-looking text (a digest-free look-alike in stderr or
/// hook context) is touched (issue #65). When it is empty (a caller that does
/// not thread the bounder's identity through) the normaliser falls back to the
/// stricter digest-requiring greedy pattern, which still tells two previews
/// apart by the digest inside the marker.
fn normalise_spill_paths<'a>(result: &'a str, spills: &[&'a crate::output::Spill]) -> std::borrow::Cow<'a, str> {
    if !spills.is_empty() {
        return normalise_known_spill_paths(result, spills);
    }
    normalise_rendered_spill_paths(result)
}

/// Normalise the spill markers the bounder identified out of band (`spills`).
/// Each marker is genuine and located by its **exact path** (carried out of
/// band, never parsed from the text), so only its volatile path needs
/// collapsing — its identity (the content digest) rides in `spills`, never in
/// the rendered text. For each spill, one anchored rewrite runs:
///
/// * match the literal `bytes truncated; complete output in <exact path>...`
///   (with an optional `(sha256:<hex>)` before the `;`), the path
///   [`regex::escape`]d so it is matched verbatim;
/// * replace it with `bytes truncated; complete output in <spill>...`,
///   collapsing the per-call path and dropping the in-text digest.
///
/// Rewriting only the producer-identified marker (rather than every
/// marker-looking substring) is what closes the over-matching hole (issue
/// #65): a `bash` result can pair a spilled stdout (the identity carried out
/// of band) with a short stderr — or appended PostToolUse context — whose text
/// merely *resembles* a marker. A global rewrite would erase that untracked
/// text's path and digest, collapsing genuinely different results into one
/// fingerprint and falsely hard-stopping the turn; matching the exact
/// out-of-band path leaves it intact. The match is anchored on the literal
/// path, so it can never span from an embedded look-alike marker across the
/// genuine one (the greedy-match hole), and the optional `(sha256:<hex>)` is
/// consumed only when it sits inside this marker.
fn normalise_known_spill_paths<'a>(result: &'a str, spills: &[&'a crate::output::Spill]) -> std::borrow::Cow<'a, str> {
    use std::borrow::Cow;
    let mut out: Cow<'_, str> = Cow::Borrowed(result);
    for spill in spills {
        let re = regex::Regex::new(&format!(
            r"bytes truncated(?: \(sha256:[0-9a-f]+\))?; complete output in {}(\.\.\.)",
            regex::escape(&spill.path)
        ))
        .expect("known-spill-path regex is valid");
        out = Cow::Owned(re.replace_all(&out, "bytes truncated; complete output in <spill>${1}").into_owned());
    }
    out
}

/// Normalise the spill marker from the rendered text alone, for a caller that
/// does not thread the bounder's digest through. The marker is
/// `...<n> bytes truncated[ (sha256:<hex>)]; complete output in <path>...`,
/// where the path's own `...` is the terminator that precedes the tail. Anchor
/// on the *complete* marker and the generated final path component, not on
/// "the first/last `...`" or "the first extension" — all are wrong:
///
/// * A bare `complete output in <path>...` match (no `bytes truncated` prefix)
///   also fires on *ordinary output* that merely quotes the phrase (`complete
///   output in report-a.txt...`), normalising a result that is not a bounder
///   marker and erasing a genuine change into a false repeat. Require the
///   `bytes truncated` prefix.
/// * A non-greedy `.+?(\.\.\.)` stops at the *first* `...`, so a `session_dir`
///   that itself contains `...` (e.g. `/tmp/cache...v1`) leaves the per-call
///   basename (`bash-3.stdout`) in the hash and the runaway never fires
///   (issue #65).
/// * A non-greedy `.+?\.(?:stdout|stderr|txt)` stops at the *first* extension,
///   so a `session_dir` ending in one (`/tmp/cache.txt...v1`) leaves
///   `bash-3.stdout` in the hash.
/// * A non-greedy `.+?(?:bash|tool|history)-…` still stops at the first
///   *directory segment* that happens to look like a generated spill name — a
///   `session_dir` such as `/tmp/tool-cache.txt...v1` matches
///   `tool-cache.txt...` and leaves the real `bash-3.stdout` in the hash, so
///   identical runaway loops are never detected. A directory segment *can*
///   start `bash-`/`tool-`/`history-`, carry a spill extension, and be
///   followed by `...`, so "a directory never matches the generated pattern"
///   is a false assumption.
///
/// The bounder only ever names the spill `bash-<n>.stdout`/`.stderr`
/// (`bash.rs`), `tool-<id>-<name>.txt` (`agent.rs`) or `history-<id>.txt`
/// (`history.rs`), all sanitised to a single extension dot (`sanitize` in
/// `agent.rs` maps every other character to `_`), and it is always the *final*
/// path component (joined under the spill dir). So match the generated
/// component **greedily, at a path-separator boundary** —
/// `(?:.+[/\\])?(?:bash|tool|history)-[\w-]*\.(?:…)` — which skips every
/// earlier directory segment (even one that resembles a spill name) and
/// anchors on the last `/`-separated component before the terminating `...`.
/// `.` excludes newlines, so the match stays on the marker's own line; the
/// path may contain spaces (a `\S+` match would silently fail on a session_dir
/// with spaces).
///
/// The digest is *required* here: it is what proves the text is a real bounder
/// marker rather than ordinary output that merely quotes `N bytes truncated;
/// complete output in <name>...`. Without it, two such ordinary results whose
/// only difference is the quoted spill-looking name would normalise
/// identically and hard-stop the turn on the fifth call (issue #65).
///
/// This greedy parse is only a fallback: a one-line result that *embeds* a
/// valid-looking marker before the genuine outer marker can still let the
/// greedy middle span both, keeping the embedded digest and erasing the outer
/// one. That is exactly why the primary path (`normalise_known_spill_paths`)
/// takes the spill's identity from the bounder out of band instead of parsing
/// it from untrusted rendered text (issue #65).
fn normalise_rendered_spill_paths(result: &str) -> std::borrow::Cow<'_, str> {
    static SPILL: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = SPILL.get_or_init(|| {
        regex::Regex::new(
            r"(bytes truncated \(sha256:[0-9a-f]+\)); complete output in (?:.+[/\\])?(?:bash|tool|history)-[\w-]*\.(?:stdout|stderr|txt)(\.\.\.)",
        )
        .expect("spill-path regex is valid")
    });
    re.replace_all(result, "${1}<spill>${2}")
}

/// Pipeline stages a retry loop commonly *appends* to the same base command to
/// inspect its output (`… | wc -l`, `… | head`, `… | grep foo`). They only read
/// their stdin and change nothing, so stripping a trailing run of them lets the
/// detector see the stable base. Anything not on this list — notably writers
/// like `tee` — is treated as behaviour changing and stops the stripping.
const DIAGNOSTIC_STAGES: &[&str] = &[
    "wc", "head", "tail", "cat", "tac", "sort", "uniq", "nl", "cut", "tr", "rev", "fold", "column", "less", "more",
    "grep", "egrep", "fgrep",
];

/// The argument text a repeat match is based on. A bash loop often appends
/// read-only diagnostic pipeline stages on each retry (`… | wc -l | head -1`),
/// so byte-identical matching misses it; stripping *those* trailing stages
/// exposes the stable base command. Stages that could change state (`… | tee a`
/// vs `… | tee b`, a redirection, a write option like `sort -o`, `||`, or a
/// shell control construct) stop the stripping so distinct side effects are
/// never conflated into a false loop. Other tools match on their arguments as
/// given. This base is only a *grouping* key: a changed diagnostic argument
/// (`… | grep alpha` vs `… | grep beta`) strips to the same base, so the
/// detector additionally requires consecutive commands to be a diagnostic
/// *extension* of one another (`is_diagnostic_extension`) before counting a
/// repeat, keeping genuinely different inspections distinct (issue #65).
fn normalised_args(tool: &str, args: &Value) -> String {
    if tool == "bash"
        && let Some(command) = args.get("command").and_then(Value::as_str)
    {
        // Normalise only the volatile `command` (stripping its trailing
        // read-only diagnostic pipeline stages) while *retaining* the rest of
        // the argument object. `timeout_seconds` and `max_output_length` change
        // execution, so a retry that adjusts either must not fingerprint the
        // same as the unadjusted call — otherwise a model progressively raising
        // a timeout against an identical result is conflated into a loop and
        // hard-stopped on the fifth attempt (issue #65).
        let mut rest = args.clone();
        if let Some(map) = rest.as_object_mut() {
            map.remove("command");
        }
        return format!("{}|{rest}", pipeline_key(command));
    }
    args.to_string()
}

/// Strip the trailing run of read-only diagnostic pipeline stages from a bash
/// command, keeping the stable base (which may itself contain non-diagnostic
/// stages such as `sed`). `cmd`, `cmd | wc -l`, `cmd | sed … | grep a | grep b`
/// all fingerprint by the same base intent, catching a loop that keeps appending
/// inspection stages — without conflating genuinely distinct side effects, since
/// stripping stops at the first non-diagnostic stage and leaves everything to its
/// left intact. (Distinct *arguments* on a stripped stage are separated by the
/// detector's `is_diagnostic_extension` check, not here.)
fn pipeline_key(command: &str) -> String {
    match split_pipeline(command) {
        Some(stages) if stages.len() > 1 => {
            let mut end = stages.len();
            while end > 1 && is_diagnostic_stage(stages[end - 1]) {
                end -= 1;
            }
            if end == stages.len() {
                command.trim().to_string()
            } else {
                stages[..end].iter().map(|s| s.trim()).collect::<Vec<_>>().join(" | ")
            }
        }
        _ => command.trim().to_string(),
    }
}

/// Whether `b` is the same bash command as `a` with only read-only diagnostic
/// stages appended or repeated — i.e. one stage list is a prefix of the other
/// and every *extra* trailing stage is a diagnostic filter. This is what lets
/// the detector treat an ever-growing inspection tail (`cmd`, `cmd | wc -l`,
/// `cmd | wc -l | head`) as the *same* looping step, while a call that **changes**
/// a diagnostic stage's argument (`… | grep alpha` then `… | grep beta`) is a
/// genuinely different inspection — not a prefix of the previous command — and
/// so breaks the streak instead of being conflated into a false repeat that
/// hard-stops a model still changing its query (issue #65). Commands that cannot
/// be split into a pipeline (`||`, etc.) must match exactly.
fn is_diagnostic_extension(a: &str, b: &str) -> bool {
    let (sa, sb) = match (split_pipeline(a), split_pipeline(b)) {
        (Some(sa), Some(sb)) => (sa, sb),
        _ => return a.trim() == b.trim(),
    };
    let (short, long) = if sa.len() <= sb.len() { (&sa, &sb) } else { (&sb, &sa) };
    // Every shared stage must be byte-identical (modulo surrounding space)...
    if short.iter().zip(long.iter()).any(|(x, y)| x.trim() != y.trim()) {
        return false;
    }
    // ...and every extra trailing stage in the longer command must be a
    // read-only diagnostic, so appending a *writer* or a new base stage is not
    // treated as the same step.
    long[short.len()..].iter().all(|s| is_diagnostic_stage(s))
}

/// A pipeline stage that only reads its stdin and writes stdout, so appending or
/// dropping it cannot change program state. Conservative on purpose — an
/// unrecognised command, a shell control/substitution/redirection construct, or
/// a command-specific *write* option returns `false`, so the caller keeps the
/// full command and never issues a false hard stop.
fn is_diagnostic_stage(stage: &str) -> bool {
    let stage = stage.trim();
    if stage.is_empty() {
        return false;
    }
    // Shell metacharacters that can redirect (`> <`), chain/background (`; &`),
    // or substitute (`` ` ``, `$(`, `${`) a command make the stage potentially
    // side-effecting; we cannot prove it is read-only, so keep the full command.
    if stage.bytes().any(|b| matches!(b, b'>' | b'<' | b';' | b'&' | b'`' | b'\n'))
        || stage.contains("$(")
        || stage.contains("${")
    {
        return false;
    }
    // Tokenise the stage shell-style (quotes stripped, escapes honoured); an
    // unparseable shape (unterminated quote, glob/brace/expansion characters
    // we do not model) fails closed.
    let Some(words) = shell_words(stage) else {
        return false;
    };
    let Some((cmd, args)) = words.split_first() else {
        return false;
    };
    if !DIAGNOSTIC_STAGES.contains(&cmd.as_str()) {
        return false;
    }
    // Some read-only filters still carry a flag or positional that writes a
    // file or runs an arbitrary helper; those forms are not side-effect-free.
    !stage_has_side_effect(cmd, args)
}

/// Option grammar of one diagnostic command, enough to tell a *writer* option
/// from an argument value. Commands absent from `option_spec` have no
/// file-writing or program-executing options, so any invocation is read-only.
struct OptionSpec {
    /// Short options that consume an argument — the rest of the cluster, or the
    /// next word when the option ends the cluster (`-k2o` is `-k` with value
    /// `2o`, *not* `-k2` plus `-o`).
    short_with_arg: &'static str,
    /// Short options that write a file / run a program.
    short_writers: &'static str,
    /// Long options that consume an argument when not given as `--opt=VALUE`.
    long_with_arg: &'static [&'static str],
    /// Long options that write a file / run a program. GNU getopt accepts any
    /// unambiguous prefix, so a long option that is a prefix of one of these
    /// counts as a writer (over-matching is the safe direction).
    long_writers: &'static [&'static str],
    /// Maximum number of positional operands before one becomes an output file
    /// (`uniq IN OUT`); `None` means positionals are all inputs.
    max_read_positionals: Option<usize>,
}

fn option_spec(cmd: &str) -> Option<OptionSpec> {
    Some(match cmd {
        // `sort -o FILE` / `--output=FILE` writes a file; `--compress-program`
        // executes an arbitrary helper when temporary files are spilled.
        "sort" => OptionSpec {
            short_with_arg: "kotST",
            short_writers: "o",
            long_with_arg: &[
                "--key",
                "--field-separator",
                "--buffer-size",
                "--temporary-directory",
                "--parallel",
                "--batch-size",
                "--files0-from",
                "--sort",
                "--random-source",
            ],
            long_writers: &["--output", "--compress-program"],
            max_read_positionals: None,
        },
        // `less -o FILE` / `-O FILE` / `--log-file` / `--LOG-FILE` logs its input.
        "less" => OptionSpec {
            short_with_arg: "bhjkoOpPtTxyz#",
            short_writers: "oO",
            long_with_arg: &[],
            long_writers: &["--log-file", "--LOG-FILE"],
            max_read_positionals: None,
        },
        // `uniq [INPUT [OUTPUT]]`: a second positional is an output file.
        // `--all-repeated` and `--group` take *optional* values, accepted only
        // in the `--opt=VALUE` form — they never consume the next word, so they
        // must not be in `long_with_arg` (otherwise `uniq --group - /tmp/out`
        // would skip `-` and miscount the output operand as an input).
        "uniq" => OptionSpec {
            short_with_arg: "fsw",
            short_writers: "",
            long_with_arg: &["--skip-fields", "--skip-chars", "--check-chars"],
            long_writers: &[],
            max_read_positionals: Some(1),
        },
        _ => return None,
    })
}

/// Whether an otherwise-diagnostic command invocation has a side effect — it
/// writes to a file, or executes an arbitrary helper program — through a
/// command-specific option or positional (so collapsing two such calls would
/// hide distinct side effects, e.g. `sort -o /tmp/a` vs `sort -o /tmp/b`).
/// Parses options getopt-style against `option_spec`, so a writer letter that is
/// really part of another option's value (`sort -k2o`) is not misread, while a
/// writer buried in a cluster (`sort -ro/tmp/a`) still is.
fn stage_has_side_effect(cmd: &str, args: &[String]) -> bool {
    let Some(spec) = option_spec(cmd) else {
        return false;
    };
    let mut positionals = 0usize;
    let mut i = 0;
    let mut options_done = false;
    while i < args.len() {
        let a = args[i].as_str();
        i += 1;
        if options_done || a == "-" || !a.starts_with('-') {
            positionals += 1;
            continue;
        }
        if a == "--" {
            options_done = true;
            continue;
        }
        if let Some(long) = a.strip_prefix("--") {
            let (name, has_value) = match long.split_once('=') {
                Some((n, _)) => (n, true),
                None => (long, false),
            };
            let name = format!("--{name}");
            if spec.long_writers.iter().any(|w| w.starts_with(name.as_str())) {
                return true;
            }
            if !has_value && spec.long_with_arg.iter().any(|w| w.starts_with(name.as_str())) {
                i += 1;
            }
            continue;
        }
        // Short-option cluster: walk it until an argument-taking option
        // consumes the remainder (or the next word).
        for (pos, c) in a[1..].char_indices() {
            if spec.short_writers.contains(c) {
                return true;
            }
            if spec.short_with_arg.contains(c) {
                if pos + c.len_utf8() == a.len() - 1 {
                    i += 1;
                }
                break;
            }
        }
    }
    spec.max_read_positionals.is_some_and(|max| positionals > max)
}

/// Split one pipeline stage into shell words: separated on shell whitespace
/// (space, tab, newline only — the default IFS; *not* CR, form feed or the wider Unicode whitespace
/// set, which the shell treats as ordinary word characters), with
/// single/double quotes removed and backslash escapes honoured. Returns `None`
/// (fail closed) for shapes this helper does not model — an unterminated quote
/// or trailing backslash, or any expansion/glob/grouping character outside
/// single quotes (`$`, `` ` ``, `*`, `?`, `[`, `{`, `(`, `)`, `~`, `!`), whose
/// runtime value could turn a word into a writer option.
fn shell_words(stage: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut chars = stage.chars();
    while let Some(c) = chars.next() {
        match c {
            // Split only on characters the shell treats as word separators —
            // not every `char::is_whitespace()`: a literal CR, form feed,
            // vertical tab (or NEL, NBSP, …) is *not* IFS whitespace, so the shell keeps it
            // inside the word (`sort -t<VT>` passes the VT as `-t`'s value).
            // Dropping it here would merge `-t<VT>` into `-t`, making the
            // option parser consume the next word as the separator value.
            ' ' | '\t' | '\n' => {
                if in_word {
                    words.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            '\\' => {
                cur.push(chars.next()?);
                in_word = true;
            }
            '\'' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        c => cur.push(c),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '$' | '`' => return None,
                        '\\' => {
                            let n = chars.next()?;
                            if !matches!(n, '"' | '\\' | '$' | '`') {
                                cur.push('\\');
                            }
                            cur.push(n);
                        }
                        c => cur.push(c),
                    }
                }
            }
            '$' | '`' | '*' | '?' | '[' | '{' | '(' | ')' | '~' | '!' | '<' | '>' | ';' | '&' | '|' => return None,
            c => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(cur);
    }
    Some(words)
}

/// Split a shell command into top-level pipeline stages, quote- and
/// escape-aware. A naive `split('|')` also splits `|` inside quotes and the
/// `||` operator. Returns `None` when the command contains `||` (logical OR,
/// not a pipeline) so the caller keeps the whole command rather than cutting it
/// at a meaningless boundary.
fn split_pipeline(command: &str) -> Option<Vec<&str>> {
    let bytes = command.as_bytes();
    let mut stages = Vec::new();
    let mut start = 0;
    let mut i = 0;
    let mut in_single = false;
    let mut in_double = false;
    while i < bytes.len() {
        match bytes[i] {
            // A backslash escapes the next byte unless we are inside single
            // quotes (where it is literal); skip the escaped byte so an escaped
            // `\|` is never mistaken for a pipe operator.
            b'\\' if !in_single => {
                i += 2;
                continue;
            }
            b'\'' if !in_double => in_single = !in_single,
            b'"' if !in_single => in_double = !in_double,
            // Command substitution (`$( … )`, backticks) can hide a `|` that
            // belongs to the inner command, and a here-doc body / newline can
            // carry further commands: shapes we do not model, so refuse to
            // split (fail closed — the caller keeps the whole command).
            b'`' if !in_single => return None,
            b'$' if !in_single && bytes.get(i + 1) == Some(&b'(') => return None,
            b'<' if !in_single && !in_double && bytes.get(i + 1) == Some(&b'<') => return None,
            b'\n' if !in_single && !in_double => return None,
            b'|' if !in_single && !in_double => {
                // `||` is logical OR and `|&` also pipes stderr: refuse to split.
                if matches!(bytes.get(i + 1), Some(b'|' | b'&')) {
                    return None;
                }
                stages.push(&command[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    if in_single || in_double {
        return None;
    }
    stages.push(&command[start..]);
    Some(stages)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Build a `Spill` whose marker path is the given text, for tests that
    /// thread a spill's identity out of band.
    fn spill_at(digest: &str, path: &str) -> crate::output::Spill {
        crate::output::Spill { digest: digest.to_string(), path: path.to_string() }
    }

    #[test]
    fn suggests_a_plan_once_per_session() {
        let mut reminders = Reminders::default();
        let plan = Plan::default();
        let notes: Vec<_> = (0..SUGGEST_PLAN_AFTER).flat_map(|_| reminders.after_tool_call(&plan, false)).collect();
        assert_eq!(notes.len(), 1);
        assert!(notes[0].contains("plan_add"));
        reminders.start_turn();
        assert!((0..SUGGEST_PLAN_AFTER * 2).all(|_| reminders.after_tool_call(&plan, false).is_empty()));
    }

    #[test]
    fn suggests_saving_a_memory_once_unless_one_was_saved() {
        let plan = Plan::default();
        let memory_notes = |r: &mut Reminders, writable| {
            (0..SUGGEST_MEMORY_AFTER * 2)
                .flat_map(|_| r.after_tool_call(&plan, writable))
                .filter(|n| n.contains("memory_save"))
                .count()
        };
        assert_eq!(memory_notes(&mut Reminders::default(), true), 1);
        assert_eq!(memory_notes(&mut Reminders::default(), false), 0);
        let mut saved = Reminders::default();
        saved.memory_saved();
        assert_eq!(memory_notes(&mut saved, true), 0);
    }

    #[test]
    fn nudges_a_stale_plan_until_it_changes() {
        let mut plan = Plan::default();
        plan.apply("plan_add", &json!({"items": ["read", "fix"]})).unwrap();
        plan.apply("plan_update", &json!({"id": 1, "status": "in_progress"})).unwrap();
        let mut reminders = Reminders::default();
        let fired: Vec<usize> =
            (1..=PLAN_STALE_AFTER * 2).filter(|_| !reminders.after_tool_call(&plan, false).is_empty()).collect();
        assert_eq!(fired, [PLAN_STALE_AFTER, PLAN_STALE_AFTER * 2]);

        reminders.plan_changed();
        plan.apply("plan_update", &json!({"id": 1, "status": "done"})).unwrap();
        let note = (0..PLAN_STALE_AFTER).flat_map(|_| reminders.after_tool_call(&plan, false)).next().unwrap();
        assert!(note.contains("next is #2 \"fix\""), "{note}");

        plan.apply("plan_update", &json!({"id": 2, "status": "done"})).unwrap();
        assert!((0..PLAN_STALE_AFTER * 2).all(|_| reminders.after_tool_call(&plan, false).is_empty()));
    }

    fn repeats(r: &mut Reminders, n: usize) -> Vec<RepeatVerdict> {
        (0..n)
            .map(|_| {
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test"}),
                    None,
                    false,
                    "exit 1",
                    ContentHashes::default(),
                )
            })
            .collect()
    }

    fn repeats_call(r: &mut Reminders, tool: &str, n: usize, ok: bool, result: &str) -> Vec<RepeatVerdict> {
        (0..n).map(|_| r.after_repeat_call(tool, &json!({}), None, ok, result, ContentHashes::default())).collect()
    }

    #[test]
    fn warns_on_the_third_identical_call_not_before() {
        let mut r = Reminders::default();
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER * 2);
        assert!(verdicts[..REPEAT_WARN_AFTER - 1].iter().all(|v| *v == RepeatVerdict::None));
        assert!(matches!(verdicts[REPEAT_WARN_AFTER - 1], RepeatVerdict::Warning(_)));
    }

    #[test]
    fn a_one_time_hint_on_the_first_failure_keeps_it_out_of_the_identical_streak() {
        // The agent appends the one-time "look in history" hint to only the
        // first failed call and fingerprints the result *after* that append
        // (issue #65). A hint-bearing result is therefore genuinely different —
        // to the model — from the later hint-free failures, so it must not be
        // counted in the identical-result streak: the warning has to fire one
        // call later than the plain all-identical case, at the documented
        // threshold, rather than one call early.
        let hint = crate::history::FAILED_TOOL_HINT;
        let first = format!("exit 1\n\n{hint}");
        let mut r = Reminders::default();
        let args = json!({"command": "make test"});
        let mut verdicts = vec![r.after_repeat_call("bash", &args, None, false, &first, ContentHashes::default())];
        for _ in 0..REPEAT_WARN_AFTER {
            verdicts.push(r.after_repeat_call("bash", &args, None, false, "exit 1", ContentHashes::default()));
        }
        // call 1 carries the hint (distinct key); the identical streak starts at
        // call 2, so the warning lands on call `1 + REPEAT_WARN_AFTER`, not
        // `REPEAT_WARN_AFTER`.
        assert!(
            verdicts[..REPEAT_WARN_AFTER].iter().all(|v| *v == RepeatVerdict::None),
            "the hint-bearing first call must not shorten the streak: {verdicts:?}"
        );
        assert!(
            matches!(verdicts[REPEAT_WARN_AFTER], RepeatVerdict::Warning(_)),
            "warning must fire one call later: {verdicts:?}"
        );
    }

    #[test]
    fn repeat_warning_only_names_report_outcome_when_it_is_offered() {
        // With the outcome tool enabled the warning points at it as the escape
        // hatch; with it disabled the warning must stay actionable without
        // naming a tool the model cannot call (issue #65).
        let warning = |outcome_tool: bool| {
            let mut r = Reminders::new(outcome_tool);
            match repeats(&mut r, REPEAT_WARN_AFTER).pop().unwrap() {
                RepeatVerdict::Warning(w) => w,
                other => panic!("expected a warning, got {other:?}"),
            }
        };
        let enabled = warning(true);
        assert!(enabled.contains("report_outcome"), "{enabled}");
        assert!(enabled.contains("try something different"), "{enabled}");
        let disabled = warning(false);
        assert!(!disabled.contains("report_outcome"), "{disabled}");
        assert!(disabled.contains("try something different"), "{disabled}");
    }

    #[test]
    fn different_arguments_or_results_do_not_repeat() {
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER * 2 {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("make test {i}")}),
                    None,
                    false,
                    "x",
                    ContentHashes::default()
                ),
                RepeatVerdict::None
            );
        }
        // Same command, but the result changed: not a repeat.
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER * 2 {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test"}),
                    None,
                    false,
                    &format!("exit {i}"),
                    ContentHashes::default()
                ),
                RepeatVerdict::None
            );
        }
    }

    #[test]
    fn caps_the_warning_then_hard_stops() {
        let mut r = Reminders::default();
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 2);
        let warnings = verdicts.iter().filter(|v| matches!(v, RepeatVerdict::Warning(_))).count();
        assert_eq!(warnings, REPEAT_MAX_WARNINGS);
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::HardStop(_)));
        // …and the hard stop keeps firing while the loop continues.
        assert!(matches!(
            r.after_repeat_call(
                "bash",
                &json!({"command": "make test"}),
                None,
                false,
                "exit 1",
                ContentHashes::default()
            ),
            RepeatVerdict::HardStop(_)
        ));
    }

    #[test]
    fn a_fresh_streak_does_not_hard_stop_before_its_own_warnings() {
        // The warning budget is turn-global, but a *different* key that reaches
        // `REPEAT_WARN_AFTER` after the budget is spent must not hard-stop on its
        // third occurrence — it never ignored a warning of its own (issue #65).
        // `A,A,A` (warn), `B,B,B` (warn) spends the budget; `C,C,…` must stay
        // silent until it genuinely loops `REPEAT_HARD_STOP_AFTER` times in a row.
        let mut r = Reminders::default();
        let warn = |r: &mut Reminders, cmd: &str| {
            let mut last = RepeatVerdict::None;
            for _ in 0..REPEAT_WARN_AFTER {
                last = r.after_repeat_call(
                    "bash",
                    &json!({"command": cmd}),
                    None,
                    false,
                    "exit 1",
                    ContentHashes::default(),
                );
            }
            last
        };
        assert!(matches!(warn(&mut r, "cmd a"), RepeatVerdict::Warning(_)));
        assert!(matches!(warn(&mut r, "cmd b"), RepeatVerdict::Warning(_)), "budget must be spent");
        // Fresh key C: its first `REPEAT_HARD_STOP_AFTER - 1` consecutive repeats
        // neither warn (budget spent) nor hard-stop (not enough of *this* key).
        let mut verdicts = Vec::new();
        for _ in 0..REPEAT_HARD_STOP_AFTER - 1 {
            verdicts.push(r.after_repeat_call(
                "bash",
                &json!({"command": "cmd c"}),
                None,
                false,
                "exit 1",
                ContentHashes::default(),
            ));
        }
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "fresh key must not hard-stop early: {verdicts:?}");
        // Only the `REPEAT_HARD_STOP_AFTER`-th consecutive C hard-stops.
        assert!(matches!(
            r.after_repeat_call("bash", &json!({"command": "cmd c"}), None, false, "exit 1", ContentHashes::default()),
            RepeatVerdict::HardStop(_)
        ));
    }

    #[test]
    fn a_bash_loop_that_appends_pipeline_stages_still_counts() {
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|i| {
                let suffix = if i == 1 { String::new() } else { " | wc -l".repeat(i - 1) };
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("gh pr diff 1{suffix}")}),
                    None,
                    true,
                    "1",
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn changing_a_diagnostic_stages_query_is_not_a_repeat() {
        // A model iterating *different* inspections of the same file — `cat log |
        // grep alpha`, `… | grep beta`, … — is exploring, not looping, even when
        // every grep finds nothing and the bounded output is identically empty.
        // Stripping the grep stage would conflate them all to `cat log` and hard
        // stop the turn on the fifth call (issue #65); the content argument keeps
        // them distinct.
        let mut r = Reminders::default();
        for q in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta"] {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("cat log | grep {q}")}),
                    None,
                    true,
                    "",
                    ContentHashes::default()
                ),
                RepeatVerdict::None,
                "query {q} must not count as a repeat",
            );
        }
    }

    #[test]
    fn changing_execution_arguments_is_not_a_repeat() {
        // The bash fingerprint normalises only the volatile `command`; the rest
        // of the argument object is retained. A model progressively raising
        // `timeout_seconds` (or `max_output_length`) against an identical result
        // is adjusting execution, not looping — dropping those arguments would
        // conflate every retry into the same fingerprint and hard-stop it on the
        // fifth call (issue #65).
        let mut r = Reminders::default();
        for t in [10, 20, 40, 80, 160, 320, 640] {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test", "timeout_seconds": t}),
                    None,
                    true,
                    "ok",
                    ContentHashes::default()
                ),
                RepeatVerdict::None,
                "timeout {t} must not count as a repeat",
            );
        }
        let mut r = Reminders::default();
        for m in [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000] {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test", "max_output_length": m}),
                    None,
                    true,
                    "ok",
                    ContentHashes::default()
                ),
                RepeatVerdict::None,
                "max_output_length {m} must not count as a repeat",
            );
        }
        // …but the *same* execution arguments retried verbatim are still a loop.
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (0..REPEAT_WARN_AFTER)
            .map(|_| {
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test", "timeout_seconds": 30}),
                    None,
                    true,
                    "ok",
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn distinct_malformed_payloads_sharing_a_prefix_are_not_a_repeat() {
        // A malformed call carries `arguments = {}`, and the model-facing error
        // embeds only the first 300 characters of the raw payload. Two malformed
        // payloads that diverge only past that prefix would otherwise share both
        // the empty object and the result hash, so the fifth genuinely-different
        // retry is hard-stopped as an identical repeat (issue #65). Passing the
        // full raw text as the fingerprint's argument component keeps them
        // distinct.
        let mut r = Reminders::default();
        let prefix = "x".repeat(400);
        for i in 0..REPEAT_WARN_AFTER + 2 {
            // Same 400-char prefix, divergent suffix → identical `{}` args and
            // identical 300-char error preview, but a distinct raw payload.
            let raw = format!("{prefix}payload-{i}");
            assert_eq!(
                r.after_repeat_call("bash", &json!({}), Some(&raw), false, "malformed JSON", ContentHashes::default()),
                RepeatVerdict::None,
                "payload {i} must not count as a repeat",
            );
        }
        // …but the *same* malformed payload retried verbatim is still a loop.
        let mut r = Reminders::default();
        let raw = format!("{prefix}same");
        let verdicts: Vec<_> = (0..REPEAT_WARN_AFTER)
            .map(|_| {
                r.after_repeat_call("bash", &json!({}), Some(&raw), false, "malformed JSON", ContentHashes::default())
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn exempt_tools_and_start_turn_reset_the_detector() {
        for tool in REPEAT_EXEMPT_TOOLS {
            let mut r = Reminders::default();
            assert!((0..REPEAT_WARN_AFTER + 1).all(|_| r.after_repeat_call(
                tool,
                &json!({}),
                None,
                true,
                "ok",
                ContentHashes::default()
            ) == RepeatVerdict::None));
        }
        let mut r = Reminders::default();
        repeats(&mut r, REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS);
        r.start_turn();
        // After a new turn the count and the warning budget start over.
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER);
        assert!(verdicts[..REPEAT_WARN_AFTER - 1].iter().all(|v| *v == RepeatVerdict::None));
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)));
    }

    #[test]
    fn an_interleaved_exempt_call_breaks_the_streak() {
        // `bash A`, `question`, `bash A`, `question`, `bash A`, … — many `bash A`
        // calls, but an exempt call sits between every pair, so none are
        // consecutive and the detector must never warn or hard-stop (issue #65).
        let mut r = Reminders::default();
        for _ in 0..REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 2 {
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "make test"}),
                    None,
                    false,
                    "exit 1",
                    ContentHashes::default()
                ),
                RepeatVerdict::None
            );
            assert_eq!(
                r.after_repeat_call("question", &json!({}), None, true, "ok", ContentHashes::default()),
                RepeatVerdict::None
            );
        }
    }

    #[test]
    fn reset_repeat_breaks_a_building_streak() {
        // A plan/outcome call the caller skips routes through `reset_repeat`;
        // it must restart the streak just like an interleaved exempt call.
        let mut r = Reminders::default();
        repeats(&mut r, REPEAT_WARN_AFTER - 1);
        r.reset_repeat();
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER - 1);
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "{verdicts:?}");
    }

    #[test]
    fn identical_large_output_with_per_call_spill_paths_still_counts() {
        // A runaway command that produces identical large output spills to a
        // fresh `bash-<n>.stdout` file each call. The varying spill name must
        // not change the fingerprint, or the detector would never fire on the
        // exact runaway case it exists to catch (issue #65).
        let mut r = Reminders::default();
        let result = |n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in /tmp/nano-coder-9/bash-{n}.stdout...TAIL"
            )
        };
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(n),
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn distinct_full_content_with_matching_bounded_preview_does_not_repeat() {
        // The bounded preview keeps only the head, tail and byte count, so two
        // *distinct* full outputs that differ only in the truncated middle
        // (e.g. a changing fixed-size log) share that preview. The bounder
        // embeds a sha256 of the complete output in the marker, so the
        // fingerprint must still tell them apart and never warn or hard-stop
        // active work that is actually progressing (issue #65).
        let mut r = Reminders::default();
        let result = |digest: &str, n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:{digest}); complete output in /tmp/nano-coder-9/bash-{n}.stdout...TAIL"
            )
        };
        // Each call returns different full content (different digest) even
        // though head, tail, byte count and the normalised spill path all match.
        let digests = [
            "aa11aa11aa11aa11",
            "bb22bb22bb22bb22",
            "cc33cc33cc33cc33",
            "dd44dd44dd44dd44",
            "ee55ee55ee55ee55",
            "ff66ff66ff66ff66",
        ];
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER + 1)
            .map(|n| {
                let digest = digests[n % digests.len()];
                let path = format!("/tmp/nano-coder-9/bash-{n}.stdout");
                let spill = spill_at(digest, &path);
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(digest, n),
                    ContentHashes { spills: &[&spill], ..Default::default() },
                )
            })
            .collect();
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "{verdicts:?}");
        // And identical digests (genuinely identical full output) still repeat.
        let mut r2 = Reminders::default();
        let verdicts2: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r2.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result("aa11aa11aa11aa11", n),
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts2.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts2:?}");
    }

    #[test]
    fn an_embedded_marker_cannot_hide_the_outer_spill_digest() {
        // The finding this closes (issue #65): a one-line result that *embeds*
        // a valid-looking marker before the genuine outer spill marker. With
        // the digest carried out of band (`spills`), the fingerprint must key
        // on that real digest — never on a digest the greedy regex would have
        // parsed out of the rendered text — so two outputs with *different*
        // genuine outer digests are told apart even when their embedded text
        // (and so the old greedy match) is identical.
        // The embedded look-alike uses a path (`bash-embedded.stdout`) that
        // never collides with the genuine per-call `bash-{n}.stdout`, so only
        // the genuine marker is ever rewritten out of band.
        let embedded = "note 9 bytes truncated (sha256:eeeeeeeeeeeeeeee); complete output in /tmp/nano-coder-9/bash-embedded.stdout...";
        let result = |outer: &str, n: usize| {
            format!(
                "{embedded}...40 bytes truncated (sha256:{outer}); complete output in /tmp/nano-coder-9/bash-{n}.stdout...TAIL"
            )
        };
        // Two genuinely different outputs (different real outer digests) whose
        // embedded text is identical must NOT be conflated into a repeat. The
        // outer digests stay distinct from the embedded `eeee…` one.
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER + 1)
            .map(|n| {
                let outer = format!("{n:04x}{n:04x}{n:04x}{n:04x}");
                let spill = spill_at(&outer, &format!("/tmp/nano-coder-9/bash-{n}.stdout"));
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(&outer, n),
                    ContentHashes { spills: &[&spill], ..Default::default() },
                )
            })
            .collect();
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "{verdicts:?}");
        // And a genuinely identical output (same real outer digest each call,
        // only the per-call spill filename varies) still repeats.
        let mut r2 = Reminders::default();
        let verdicts2: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                let spill = spill_at("ffffffffffffffff", &format!("/tmp/nano-coder-9/bash-{n}.stdout"));
                r2.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result("ffffffffffffffff", n),
                    ContentHashes { spills: &[&spill], ..Default::default() },
                )
            })
            .collect();
        assert!(matches!(verdicts2.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts2:?}");
    }

    #[test]
    fn a_known_spill_marker_is_normalised_without_its_digest() {
        // With the spill's identity supplied out of band, the marker's volatile
        // path is collapsed by matching its exact path: the digest is stripped
        // from the text (its identity rides in `spills`), and the per-call
        // filename no longer reaches the hash.
        let sa = spill_at("aaaaaaaaaaaaaaaa", "/t/bash-1.stdout");
        let sb = spill_at("aaaaaaaaaaaaaaaa", "/t/bash-9.stdout");
        let a = normalise_spill_paths(
            "h...3 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in /t/bash-1.stdout...t",
            &[&sa],
        );
        let b = normalise_spill_paths(
            "h...3 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in /t/bash-9.stdout...t",
            &[&sb],
        );
        assert_eq!(a, b);
        // The genuine marker's path is collapsed to `<spill>` and its digest
        // stripped.
        assert!(a.contains("<spill>"), "{a}");
        assert!(!a.contains("aaaaaaaaaaaaaaaa"), "{a}");
        assert!(!a.contains("bash-1.stdout"), "{a}");
    }

    #[test]
    fn a_known_spill_rewrite_leaves_an_untracked_lookalike_marker_intact() {
        // The finding this closes (issue #65): a `bash` result can pair a
        // spilled stdout (the identity carried out of band) with a short
        // stderr — or appended PostToolUse context — whose text merely
        // *resembles* a marker. A global rewrite would erase that untracked
        // text's path/digest, collapsing genuinely different results into one
        // fingerprint and falsely hard-stopping the turn. Rewriting only the
        // producer-identified marker (by its exact out-of-band path) leaves the
        // look-alike intact, so two results that differ only in it stay
        // distinct.
        let genuine = |n: usize| format!("/tmp/nano-coder-9/bash-{n}.stdout");
        let result = |lookalike: &str, n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in {}...TAIL\nStderr:\nnote {lookalike}",
                genuine(n)
            )
        };
        let lookalike_a = "3 bytes truncated; complete output in /tmp/nano-coder-9/tool-aaa-read_file.txt...";
        let lookalike_b = "3 bytes truncated; complete output in /tmp/nano-coder-9/tool-bbb-read_file.txt...";
        // Two results whose only difference is the untracked look-alike marker
        // must NOT be conflated into a repeat.
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER + 1)
            .map(|n| {
                let lookalike = if n % 2 == 0 { lookalike_a } else { lookalike_b };
                let spill = spill_at("aaaaaaaaaaaaaaaa", &genuine(n));
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(lookalike, n),
                    ContentHashes { spills: &[&spill], ..Default::default() },
                )
            })
            .collect();
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "{verdicts:?}");
        // And the genuine marker is still normalised (its per-call path
        // collapsed) while the look-alike is preserved verbatim.
        let spill = spill_at("aaaaaaaaaaaaaaaa", &genuine(1));
        let rendered = result(lookalike_a, 1);
        let out = normalise_spill_paths(&rendered, &[&spill]);
        assert!(out.contains("<spill>"), "{out}");
        assert!(!out.contains("bash-1.stdout"), "{out}");
        assert!(out.contains("tool-aaa-read_file.txt"), "{out}");
    }

    #[test]
    fn changing_image_attachment_does_not_repeat() {
        // A `read_file` of a *changing* image returns identical metadata text
        // (same MIME type, dimensions, encoded size) on every call while the
        // attached bytes differ. The fingerprint must fold in each attachment's
        // content hash, or the fifth changing image is hard-stopped as an
        // identical result (issue #65).
        let mut r = Reminders::default();
        let text = "image/png 800x600, 12345 bytes";
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER + 1)
            .map(|n| {
                r.after_repeat_call(
                    "read_file",
                    &json!({"path": "pic.png"}),
                    None,
                    true,
                    text,
                    ContentHashes { attachments: &[&format!("sha{n:064}")], ..Default::default() },
                )
            })
            .collect();
        assert!(verdicts.iter().all(|v| *v == RepeatVerdict::None), "{verdicts:?}");
        // An identical attachment (same bytes) on the identical text still repeats.
        let mut r2 = Reminders::default();
        let sha = format!("{:064}", 7);
        let verdicts2: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|_| {
                r2.after_repeat_call(
                    "read_file",
                    &json!({"path": "pic.png"}),
                    None,
                    true,
                    text,
                    ContentHashes { attachments: &[&sha], ..Default::default() },
                )
            })
            .collect();
        assert!(matches!(verdicts2.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts2:?}");
    }

    #[test]
    fn identical_large_history_read_with_per_call_spill_paths_still_counts() {
        // A repeated large `history_read` spills to `history-<id>.txt`, then
        // `history-<id>-2.txt`, `-3.txt`, … on each repeat. The varying spill
        // name must not change the fingerprint, or the runaway never warns or
        // hard-stops (issue #65).
        let mut r = Reminders::default();
        let result = |n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:bbbbbbbbbbbbbbbb); complete output in /tmp/nano-coder-9/history-3{suffix}.txt...TAIL",
                suffix = if n == 1 { String::new() } else { format!("-{n}") }
            )
        };
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r.after_repeat_call("history_read", &json!({"id": 3}), None, true, &result(n), ContentHashes::default())
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn spill_path_normalisation_collapses_per_call_names() {
        // bash stdout/stderr spills and tool-<id>-<name>.txt spills (including a
        // collision `-N` suffix) all normalise to the same placeholder *inside
        // the marker*.
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in /t/bash-3.stdout...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:aaaaaaaaaaaaaaaa); complete output in /t/bash-99-2.stdout...y",
                &[]
            ),
        );
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:bbbbbbbbbbbbbbbb); complete output in /t/bash-1.stderr...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:bbbbbbbbbbbbbbbb); complete output in /t/bash-7.stderr...y",
                &[]
            ),
        );
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:cccccccccccccccc); complete output in /t/tool-abc123-read_file.txt...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:cccccccccccccccc); complete output in /t/tool-zz99-read_file.txt...y",
                &[]
            ),
        );
        // history_read spills as `history-<id>.txt`, with a collision `-N`
        // suffix on a repeat; those per-call names must also collapse (issue #65).
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:dddddddddddddddd); complete output in /t/history-7.txt...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:dddddddddddddddd); complete output in /t/history-7-2.txt...y",
                &[]
            ),
        );
        // Genuinely different content is still distinguished.
        assert_ne!(normalise_spill_paths("alpha", &[]), normalise_spill_paths("beta", &[]));
    }

    #[test]
    fn spill_normalisation_only_touches_the_marker_not_arbitrary_output() {
        // Output that merely *looks* like a spill name but is not the bounder's
        // `...N bytes truncated; complete output in …` marker must stay
        // distinct, or a changing result is conflated into a false repeat and
        // hard-stops the turn (issue #65).
        assert_ne!(normalise_spill_paths("created tool-a.txt", &[]), normalise_spill_paths("created tool-b.txt", &[]));
        assert_ne!(
            normalise_spill_paths("wrote bash-1.stdout", &[]),
            normalise_spill_paths("wrote bash-2.stdout", &[])
        );
        // Ordinary output that quotes `complete output in <name>.txt...` without
        // the `bytes truncated;` prefix is not a bounder marker and must not be
        // normalised, or a genuine change is erased into a false repeat.
        assert_ne!(
            normalise_spill_paths("see complete output in report-a.txt... done", &[]),
            normalise_spill_paths("see complete output in report-b.txt... done", &[]),
        );
        // The tail after the marker is preserved, so differing tails stay distinct.
        assert_ne!(
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:eeeeeeeeeeeeeeee); complete output in /t/bash-1.stdout...tailA",
                &[]
            ),
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:eeeeeeeeeeeeeeee); complete output in /t/bash-2.stdout...tailB",
                &[]
            ),
        );
        // A digest-less `N bytes truncated; complete output in <name>...` is NOT
        // a bounder marker — every real path-bearing marker carries its
        // `(sha256:…)` digest — so ordinary output that merely quotes the phrase
        // is left untouched and stays distinct, never conflated into a false
        // repeat that hard-stops the turn (issue #65).
        assert_ne!(
            normalise_spill_paths("wrote 3 bytes truncated; complete output in /tmp/bash-1.stdout...", &[]),
            normalise_spill_paths("wrote 3 bytes truncated; complete output in /tmp/bash-2.stdout...", &[]),
        );
    }

    #[test]
    fn spill_normalisation_handles_paths_with_spaces() {
        // A spill lives under the configurable `session_dir`, which may contain
        // spaces. The marker must still normalise, or each per-call filename
        // survives in the hash and the runaway never warns or hard-stops (the
        // `\S+`-based match silently failed here; issue #65).
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:1111111111111111); complete output in /my dir/bash-3.stdout...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:1111111111111111); complete output in /my dir/bash-9.stdout...y",
                &[]
            ),
        );
        let mut r = Reminders::default();
        let result = |n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:1111111111111111); complete output in /a b/nano-coder/bash-{n}.stdout...TAIL"
            )
        };
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(n),
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn spill_normalisation_handles_ellipsis_in_directory() {
        // The configurable `session_dir` may itself contain `...` (e.g.
        // `/tmp/cache...v1`). The terminator is the spill's own `...`, found by
        // anchoring on the generated `bash-<n>.stdout` final component at a
        // path-separator boundary — not the first `...` (which a non-greedy
        // match would wrongly take at the directory's dots, leaving each
        // per-call basename in the hash so the runaway never fired — issue #65).
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:2222222222222222); complete output in /tmp/cache...v1/bash-3.stdout...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:2222222222222222); complete output in /tmp/cache...v1/bash-4.stdout...y",
                &[]
            ),
        );
        // A session_dir whose segment ends in a spill *extension* (e.g.
        // `/tmp/cache.txt...v1`) must not stop the match at the directory's
        // `.txt...` either — only the generated `bash-`/`tool-` final component
        // terminates the path.
        assert_eq!(
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:3333333333333333); complete output in /tmp/cache.txt...v1/bash-3.stdout...y",
                &[]
            ),
            normalise_spill_paths(
                "x...3 bytes truncated (sha256:3333333333333333); complete output in /tmp/cache.txt...v1/bash-4.stdout...y",
                &[]
            ),
        );
        // A session_dir whose segment *is itself* a generated-looking spill name
        // — `/tmp/tool-cache.txt...v1` or `/tmp/history-x.txt...v1` — must not be
        // mistaken for the final component: a non-greedy match stopped at that
        // directory's `tool-cache.txt...` and left the real per-call basename in
        // the hash, so the runaway never fired. The greedy, separator-anchored
        // match skips it (the finding this test pins).
        for dirseg in ["tool-cache.txt", "history-x.txt", "bash-0.stdout"] {
            assert_eq!(
                normalise_spill_paths(
                    &format!(
                        "x...3 bytes truncated (sha256:4444444444444444); complete output in /tmp/{dirseg}...v1/bash-3.stdout...y"
                    ),
                    &[]
                ),
                normalise_spill_paths(
                    &format!(
                        "x...3 bytes truncated (sha256:4444444444444444); complete output in /tmp/{dirseg}...v1/bash-4.stdout...y"
                    ),
                    &[]
                ),
                "directory segment {dirseg} must not be taken as the spill basename",
            );
        }
        let mut r = Reminders::default();
        let result = |n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:2222222222222222); complete output in /tmp/cache...v1/bash-{n}.stdout...TAIL"
            )
        };
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result(n),
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
        // A generated-looking directory segment is likewise collapsed end-to-end,
        // so an identical runaway under such a session_dir still warns.
        let mut r_dir = Reminders::default();
        let result_dir = |n: usize| {
            format!(
                "HEAD...40 bytes truncated (sha256:7777777777777777); complete output in /tmp/tool-cache.txt...v1/bash-{n}.stdout...TAIL"
            )
        };
        let verdicts_dir: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|n| {
                r_dir.after_repeat_call(
                    "bash",
                    &json!({"command": "cat big.log"}),
                    None,
                    true,
                    &result_dir(n),
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts_dir.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts_dir:?}");
        // The terminator stops at the spill basename's own `...`; the tail after
        // it is preserved, so differing tails still distinguish the results. The
        // greedy match anchors on the generated `bash-<n>.stdout` component (and
        // the marker's complete-output digest already tells genuinely different
        // outputs apart), so a `...` in the tail does not erase a real change.
        assert_ne!(
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:5555555555555555); complete output in /t/bash-1.stdout...tailA",
                &[]
            ),
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:5555555555555555); complete output in /t/bash-1.stdout...tailB",
                &[]
            ),
        );
        // Even when the tail itself contains `...`, the extension anchor keeps the
        // match on the spill basename, so distinct tails stay distinct.
        assert_ne!(
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:6666666666666666); complete output in /t/bash-1.stdout...a...tailA",
                &[]
            ),
            normalise_spill_paths(
                "h...3 bytes truncated (sha256:6666666666666666); complete output in /t/bash-1.stdout...b...tailB",
                &[]
            ),
        );
    }

    #[test]
    fn less_logfile_option_is_not_diagnostic() {
        // `less -o FILE` / `-O FILE` / `--log-file=FILE` writes its input to a
        // file, so it must stop the trailing-strip: two commands targeting
        // different log files are genuinely distinct side effects and must never
        // collapse into a false loop (and hard-stop before later writes run).
        assert_ne!(pipeline_key("printf x | less -o /tmp/a"), pipeline_key("printf x | less -o /tmp/b"));
        assert_ne!(pipeline_key("printf x | less -O /tmp/a"), pipeline_key("printf x | less -O /tmp/b"));
        assert_ne!(
            pipeline_key("printf x | less --log-file=/tmp/a"),
            pipeline_key("printf x | less --log-file=/tmp/b")
        );
        // Plain `less` (no logfile option) is still a read-only pager and strips.
        assert_eq!(pipeline_key("printf x | less"), "printf x");
    }

    #[test]
    fn disabled_plan_tool_repeats_are_still_detected() {
        // When `plan_tools` is disabled the plan tools are unregistered, so the
        // model's hallucinated `plan_add` calls reach the detector (the enabled
        // case is handled earlier via `reset_repeat`). They must *not* be exempt,
        // or an identical `Tool 'plan_add' not found` error loops forever.
        let mut r = Reminders::default();
        let verdicts =
            repeats_call(&mut r, "plan_add", REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 1, false, "not found");
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::HardStop(_)), "{verdicts:?}");
    }

    #[test]
    fn a_quoted_pipe_is_not_a_pipeline_boundary() {
        // `printf 'same|one' >/tmp/a` and `printf 'same|two' >/tmp/b` are
        // distinct side-effecting commands; a naive split('|') would normalise
        // both to `printf 'same` and, with identical empty output, falsely flag
        // a loop and hard-stop the turn (issue #65).
        assert_eq!(pipeline_key("printf 'same|one' >/tmp/a"), "printf 'same|one' >/tmp/a");
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 1 {
            let letter = (b'a' + i as u8) as char;
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("printf 'same|{letter}' >/tmp/{letter}")}),
                    None,
                    true,
                    "",
                    ContentHashes::default(),
                ),
                RepeatVerdict::None,
            );
        }
    }

    #[test]
    fn pipeline_key_only_collapses_read_only_diagnostic_stages() {
        // Appended read-only filters strip to the base command (a retry loop).
        assert_eq!(pipeline_key("gh pr diff | wc -l"), "gh pr diff");
        assert_eq!(pipeline_key("cat big.log | head | tail -3"), "cat big.log");
        assert_eq!(pipeline_key("cat big.log | grep foo | grep bar"), "cat big.log");
        // Only the *trailing* diagnostic run is stripped: a non-diagnostic stage
        // (here `sed`) and everything to its left stay in the base, so the loop
        // the PR exists to stop — a base with `sed`/`grep` that keeps appending
        // `| grep …` — still fingerprints stably (issue #65).
        assert_eq!(pipeline_key("cmd | sed s/x/y/ | grep foo | grep bar"), pipeline_key("cmd | sed s/x/y/ | grep foo"),);
        assert_eq!(pipeline_key("cmd | sed s/x/y/ | grep foo"), "cmd | sed s/x/y/");
        // `||`, quoted pipes and escaped pipes never split.
        assert_eq!(pipeline_key("make test || true"), "make test || true");
        assert_eq!(pipeline_key("grep '|' file"), "grep '|' file");
        assert_eq!(pipeline_key(r"echo a \| b"), r"echo a \| b");
        // A downstream stage with side effects keeps the whole command: `tee`
        // and redirections write distinct state, so the commands are not repeats.
        assert_eq!(pipeline_key("printf x | tee /tmp/a"), "printf x | tee /tmp/a");
        assert_eq!(pipeline_key("printf x | tee /tmp/b"), "printf x | tee /tmp/b");
        assert_eq!(pipeline_key("cat f | wc -l > /tmp/a"), "cat f | wc -l > /tmp/a");
        // An unrecognised downstream command is treated as behaviour changing.
        assert_eq!(pipeline_key("cat f | my-writer"), "cat f | my-writer");
    }

    #[test]
    fn pipeline_key_keeps_stages_that_write_through_options_or_shell_control() {
        // A first command word plus the absence of `>` is *not* enough to prove a
        // stage is read-only: `sort -o FILE` writes a file, and a `;`-chained
        // `touch` has a side effect. Collapsing these would let distinct
        // side-effecting calls hard-stop each other and skip later writes.
        assert_eq!(pipeline_key("printf x | sort -o /tmp/a"), "printf x | sort -o /tmp/a");
        assert_eq!(pipeline_key("printf x | sort --output=/tmp/a"), "printf x | sort --output=/tmp/a");
        // `-o` buried in a short-option cluster still writes a file: `sort
        // -ro/tmp/a` is `-r` + `-o/tmp/a`, so distinct targets stay distinct.
        assert_ne!(pipeline_key("printf x | sort -ro/tmp/a"), pipeline_key("printf x | sort -ro/tmp/b"));
        assert_ne!(pipeline_key("printf x | less -No/tmp/a"), pipeline_key("printf x | less -NO/tmp/b"));
        // `sort --compress-program=PROG` runs an arbitrary helper on spilled
        // temp files, so a changed helper is new side-effecting work even when
        // the sorted output is identical — keep the full command (both the
        // `=`-joined and space-separated forms) and never conflate helpers.
        assert_eq!(
            pipeline_key("printf x | sort --compress-program=/tmp/a"),
            "printf x | sort --compress-program=/tmp/a"
        );
        assert_eq!(
            pipeline_key("printf x | sort --compress-program /tmp/a"),
            "printf x | sort --compress-program /tmp/a"
        );
        assert_ne!(
            pipeline_key("printf x | sort --compress-program=/tmp/a"),
            pipeline_key("printf x | sort --compress-program=/tmp/b"),
        );
        assert_eq!(pipeline_key("printf x | uniq /in /out"), "printf x | uniq /in /out");
        assert_eq!(pipeline_key("foo | cat ; touch /tmp/a"), "foo | cat ; touch /tmp/a");
        assert_eq!(pipeline_key("foo | cat $(touch /tmp/a)"), "foo | cat $(touch /tmp/a)");
        assert_eq!(pipeline_key("foo | cat > /tmp/a"), "foo | cat > /tmp/a");
        // Distinct `sort -o` targets must never be conflated into a repeat.
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 1 {
            let letter = (b'a' + i as u8) as char;
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("printf x | sort -o /tmp/{letter}")}),
                    None,
                    true,
                    "",
                    ContentHashes::default(),
                ),
                RepeatVerdict::None,
            );
        }
        // Likewise, an ever-growing pipeline that keeps identical sorted output
        // but swaps in a different `--compress-program` helper each round is
        // doing new side-effecting work and must never be hard-stopped.
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 1 {
            let letter = (b'a' + i as u8) as char;
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("printf x | sort -S1K --compress-program=/tmp/{letter}")}),
                    None,
                    true,
                    "",
                    ContentHashes::default(),
                ),
                RepeatVerdict::None,
            );
        }
    }

    #[test]
    fn an_appended_diagnostic_suffix_loop_is_detected() {
        // The runaway this PR targets: the same base command with an ever-growing
        // tail of read-only inspection stages and an identical result each time.
        // Stripping the trailing diagnostic run makes the keys equal, so the
        // detector fires (issue #65).
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (0..REPEAT_WARN_AFTER)
            .map(|n| {
                let tail = " | grep foo".repeat(n + 1);
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("cat log | sed s/a/b/{tail}")}),
                    None,
                    true,
                    "same",
                    ContentHashes::default(),
                )
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn distinct_side_effecting_pipelines_do_not_hard_stop() {
        // Five `… | tee <different file>` calls are genuinely distinct (each
        // writes a different file); they must not be conflated into a repeat.
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS + 1 {
            let letter = (b'a' + i as u8) as char;
            assert_eq!(
                r.after_repeat_call(
                    "bash",
                    &json!({"command": format!("printf x | tee /tmp/{letter}")}),
                    None,
                    true,
                    "",
                    ContentHashes::default(),
                ),
                RepeatVerdict::None,
            );
        }
    }

    #[test]
    fn option_values_are_not_misread_as_writer_flags() {
        // `-k2o`: the `o` is part of `-k`'s value, not a separate `-o`.
        assert_eq!(pipeline_key("cat f | sort -k2o"), "cat f");
        assert_eq!(pipeline_key("cat f | sort -t o"), "cat f");
        assert_eq!(pipeline_key("cat f | sort -k 2 -o /tmp/a"), "cat f | sort -k 2 -o /tmp/a");
        // A writer after a cluster ending in an argument-taking flag still counts.
        assert_ne!(pipeline_key("cat f | sort -rk2 -o/tmp/a"), pipeline_key("cat f | sort -rk2 -o/tmp/b"));
        // Unambiguous long-option prefixes are writers too.
        assert_eq!(pipeline_key("cat f | sort --out=/tmp/a"), "cat f | sort --out=/tmp/a");
        assert_eq!(pipeline_key("cat f | less --log=/tmp/a"), "cat f | less --log=/tmp/a");
        // `uniq` options with values do not count as positionals.
        assert_eq!(pipeline_key("cat f | uniq -f 2"), "cat f");
        assert_eq!(pipeline_key("cat f | uniq -f 2 - /tmp/out"), "cat f | uniq -f 2 - /tmp/out");
        assert_eq!(pipeline_key("cat f | uniq -- -in -out"), "cat f | uniq -- -in -out");
        // `uniq --all-repeated` / `--group` take optional values only as
        // `--opt=VALUE`; bare, they must NOT swallow the next word — otherwise
        // `uniq --group - /tmp/out` would miscount the output operand.
        assert_eq!(pipeline_key("cat f | uniq --group - /tmp/out"), "cat f | uniq --group - /tmp/out");
        assert_eq!(pipeline_key("cat f | uniq --all-repeated - /tmp/out"), "cat f | uniq --all-repeated - /tmp/out");
        // The `=`-joined optional-value forms are still pure filters.
        assert_eq!(pipeline_key("cat f | uniq --group=prepend"), "cat f");
        assert_eq!(pipeline_key("cat f | uniq --all-repeated=separate"), "cat f");
        // A literal vertical tab is not shell whitespace: the shell keeps it
        // inside `-t<VT>` as the separator value, so `-o` must still be seen
        // as the writer option it is.
        assert_eq!(pipeline_key("cat f | sort -t\u{b} -o /tmp/out"), "cat f | sort -t\u{b} -o /tmp/out");
        // Likewise CR and form feed are not default-IFS characters.
        assert_eq!(pipeline_key("cat f | sort -t\r -o /tmp/out"), "cat f | sort -t\r -o /tmp/out");
        assert_eq!(pipeline_key("cat f | sort -t\u{c} -o /tmp/out"), "cat f | sort -t\u{c} -o /tmp/out");
        // Quoted writer flags are still writer flags.
        assert_eq!(pipeline_key("cat f | sort '-o' /tmp/a"), "cat f | sort '-o' /tmp/a");
        assert_eq!(pipeline_key("cat f | 'tee' /tmp/a"), "cat f | 'tee' /tmp/a");
    }

    #[test]
    fn unmodelled_shell_shapes_fail_closed() {
        // Command substitution hiding a pipe never splits.
        assert_eq!(pipeline_key("echo $(cat a | wc -l)"), "echo $(cat a | wc -l)");
        assert_eq!(pipeline_key("echo `cat a | wc -l`"), "echo `cat a | wc -l`");
        // `|&`, here-docs, newlines and unterminated quotes never split.
        assert_eq!(pipeline_key("make |& tee log"), "make |& tee log");
        assert_eq!(pipeline_key("cat <<EOF | wc\nx\nEOF"), "cat <<EOF | wc\nx\nEOF");
        assert_eq!(pipeline_key("cmd | grep 'x"), "cmd | grep 'x");
        // Globs / expansions in a stage are not provably read-only.
        assert_eq!(pipeline_key("cmd | sort $OPT"), "cmd | sort $OPT");
        assert_eq!(pipeline_key("cmd | sort -*"), "cmd | sort -*");
        // Writers that are not diagnostic tools keep the command.
        for w in ["tee -a /tmp/a", "cp a b", "mv a b", "rsync a b", "xargs rm"] {
            let c = format!("cmd | {w}");
            assert_eq!(pipeline_key(&c), c);
        }
        // Plain quoted grep patterns are still diagnostic.
        assert_eq!(pipeline_key("cmd | grep 'a b' | head -n 3"), "cmd");
    }
}
