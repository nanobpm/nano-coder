//! System reminders: short notes appended to tool results so the model sees
//! harness state at the moment it matters (an idea from grok-build).

use crate::plan::{Plan, Status};

/// Remind about a stale plan after this many tool calls without a plan change.
pub const PLAN_STALE_AFTER: usize = 12;
/// Suggest a plan after this many tool calls in one turn without one.
pub const SUGGEST_PLAN_AFTER: usize = 10;

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
}

impl Reminders {
    pub fn start_turn(&mut self) {
        self.this_turn = 0;
    }

    pub fn plan_changed(&mut self) {
        self.since_plan_change = 0;
    }

    /// Count a (non-plan) tool call and return any reminders for its result.
    pub fn after_tool_call(&mut self, plan: &Plan) -> Vec<String> {
        self.since_plan_change += 1;
        self.this_turn += 1;
        let mut notes = Vec::new();
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn suggests_a_plan_once_per_session() {
        let mut reminders = Reminders::default();
        let plan = Plan::default();
        let notes: Vec<_> = (0..SUGGEST_PLAN_AFTER).flat_map(|_| reminders.after_tool_call(&plan)).collect();
        assert_eq!(notes.len(), 1);
        assert!(notes[0].contains("plan_add"));
        reminders.start_turn();
        assert!((0..SUGGEST_PLAN_AFTER * 2).all(|_| reminders.after_tool_call(&plan).is_empty()));
    }

    #[test]
    fn nudges_a_stale_plan_until_it_changes() {
        let mut plan = Plan::default();
        plan.apply("plan_add", &json!({"items": ["read", "fix"]})).unwrap();
        plan.apply("plan_update", &json!({"id": 1, "status": "in_progress"})).unwrap();
        let mut reminders = Reminders::default();
        let fired: Vec<usize> = (1..=PLAN_STALE_AFTER * 2)
            .filter(|_| !reminders.after_tool_call(&plan).is_empty())
            .collect();
        assert_eq!(fired, [PLAN_STALE_AFTER, PLAN_STALE_AFTER * 2]);

        reminders.plan_changed();
        plan.apply("plan_update", &json!({"id": 1, "status": "done"})).unwrap();
        let note = (0..PLAN_STALE_AFTER).flat_map(|_| reminders.after_tool_call(&plan)).next().unwrap();
        assert!(note.contains("next is #2 \"fix\""), "{note}");

        plan.apply("plan_update", &json!({"id": 2, "status": "done"})).unwrap();
        assert!((0..PLAN_STALE_AFTER * 2).all(|_| reminders.after_tool_call(&plan).is_empty()));
    }
}
