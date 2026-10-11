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

/// Tools where repeating the same call is legitimate (bookkeeping, waiting on
/// a person): the loop detector never counts them.
const REPEAT_EXEMPT_TOOLS: &[&str] = &["plan_add", "plan_update", "plan_show", "question"];

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
    /// Repeat warnings already fired this turn (capped, so the nudge cannot
    /// become a loop itself).
    repeat_warnings: usize,
}

impl Reminders {
    pub fn start_turn(&mut self) {
        self.this_turn = 0;
        self.repeat_count = 0;
        self.repeat_key = None;
        self.repeat_warnings = 0;
    }

    pub fn plan_changed(&mut self) {
        self.since_plan_change = 0;
    }

    pub fn memory_saved(&mut self) {
        self.since_memory_save = 0;
        self.suggested_memory = true;
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
    /// normalised arguments (for `bash`, the first pipeline stage — a loop
    /// that appends `| wc -l`-style stages still matches), the error flag and
    /// a hash of the result, so "same output again" counts even when the
    /// arguments drift. The warning fires at `REPEAT_WARN_AFTER` consecutive
    /// repeats and at most `REPEAT_MAX_WARNINGS` times per turn; once the
    /// warnings are spent, a further repeat is a hard stop.
    pub fn after_repeat_call(&mut self, tool: &str, args: &Value, ok: bool, result: &str) -> RepeatVerdict {
        if REPEAT_EXEMPT_TOOLS.contains(&tool) {
            return RepeatVerdict::None;
        }
        let key = repeat_key(tool, args, ok, result);
        self.repeat_count = if self.repeat_key.as_deref() == Some(key.as_str()) { self.repeat_count + 1 } else { 1 };
        self.repeat_key = Some(key);
        if self.repeat_count < REPEAT_WARN_AFTER {
            return RepeatVerdict::None;
        }
        let times = self.repeat_count;
        let outcome = if ok { "the same result" } else { "the same error" };
        if self.repeat_warnings < REPEAT_MAX_WARNINGS {
            self.repeat_warnings += 1;
            RepeatVerdict::Warning(format!(
                "You have now made this same `{tool}` call {times} times in a row with {outcome}. Repeating it \
                 will not change anything. Change approach: try something different, or call report_outcome with \
                 status \"blocked\" and say what you tried."
            ))
        } else {
            RepeatVerdict::HardStop(format!(
                "the model repeated the same `{tool}` call {times} times in a row with {outcome}, and kept \
                 repeating it after {REPEAT_MAX_WARNINGS} warnings to change approach"
            ))
        }
    }
}

/// Fingerprint one tool call for the loop detector: the tool name, the
/// normalised arguments, whether the call failed, and a hash of the result.
fn repeat_key(tool: &str, args: &Value, ok: bool, result: &str) -> String {
    let args = normalised_args(tool, args);
    let mut result_hash = [0u8; 8];
    result_hash.copy_from_slice(&sha2::Sha256::digest(result.as_bytes())[..8]);
    format!("{tool}|{args}|err={ok:?}|out={:x?}", result_hash)
}

/// The argument text a repeat match is based on. A bash loop often appends
/// pipeline stages on each retry (`… | wc -l | head -1`), so byte-identical
/// matching misses it; the first pipeline stage is the stable intent. Other
/// tools match on their arguments as given.
fn normalised_args(tool: &str, args: &Value) -> String {
    if tool == "bash"
        && let Some(command) = args.get("command").and_then(Value::as_str)
    {
        return command.split('|').next().unwrap_or(command).trim().to_string();
    }
    args.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
        (0..n).map(|_| r.after_repeat_call("bash", &json!({"command": "make test"}), false, "exit 1")).collect()
    }

    #[test]
    fn warns_on_the_third_identical_call_not_before() {
        let mut r = Reminders::default();
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER * 2);
        assert!(verdicts[..REPEAT_WARN_AFTER - 1].iter().all(|v| *v == RepeatVerdict::None));
        assert!(matches!(verdicts[REPEAT_WARN_AFTER - 1], RepeatVerdict::Warning(_)));
    }

    #[test]
    fn different_arguments_or_results_do_not_repeat() {
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER * 2 {
            assert_eq!(
                r.after_repeat_call("bash", &json!({"command": format!("make test {i}")}), false, "x"),
                RepeatVerdict::None
            );
        }
        // Same command, but the result changed: not a repeat.
        let mut r = Reminders::default();
        for i in 0..REPEAT_WARN_AFTER * 2 {
            assert_eq!(
                r.after_repeat_call("bash", &json!({"command": "make test"}), false, &format!("exit {i}")),
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
            r.after_repeat_call("bash", &json!({"command": "make test"}), false, "exit 1"),
            RepeatVerdict::HardStop(_)
        ));
    }

    #[test]
    fn a_bash_loop_that_appends_pipeline_stages_still_counts() {
        let mut r = Reminders::default();
        let verdicts: Vec<_> = (1..=REPEAT_WARN_AFTER)
            .map(|i| {
                let suffix = if i == 1 { String::new() } else { " | wc -l".repeat(i - 1) };
                r.after_repeat_call("bash", &json!({"command": format!("gh pr diff 1{suffix}")}), true, "1")
            })
            .collect();
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)), "{verdicts:?}");
    }

    #[test]
    fn exempt_tools_and_start_turn_reset_the_detector() {
        for tool in REPEAT_EXEMPT_TOOLS {
            let mut r = Reminders::default();
            assert!(
                (0..REPEAT_WARN_AFTER + 1)
                    .all(|_| r.after_repeat_call(tool, &json!({}), true, "ok") == RepeatVerdict::None)
            );
        }
        let mut r = Reminders::default();
        repeats(&mut r, REPEAT_WARN_AFTER + REPEAT_MAX_WARNINGS);
        r.start_turn();
        // After a new turn the count and the warning budget start over.
        let verdicts = repeats(&mut r, REPEAT_WARN_AFTER);
        assert!(verdicts[..REPEAT_WARN_AFTER - 1].iter().all(|v| *v == RepeatVerdict::None));
        assert!(matches!(verdicts.last().unwrap(), RepeatVerdict::Warning(_)));
    }
}
