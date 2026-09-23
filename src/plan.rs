//! A task plan the agent keeps outside the conversation, so long-range work
//! survives compaction and resume. The agent edits it with the `plan_*`
//! tools; the harness records every change in the session log and restates
//! the plan after compaction.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::tools::ToolDefinition;

const MAX_ITEMS: usize = 200;
const MAX_TITLE_CHARS: usize = 200;
const MAX_NOTE_CHARS: usize = 1_000;
const MAX_GOAL_CHARS: usize = 2_000;
/// Largest item id accepted from a client-supplied plan.
const MAX_ID: u32 = 1_000_000;
/// Budget for the plan restated after compaction.
pub const CONTEXT_CHARS: usize = 8_000;

pub const TOOL_NAMES: [&str; 3] = ["plan_add", "plan_update", "plan_show"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pending,
    InProgress,
    Done,
    Blocked,
    Dropped,
}

impl Status {
    fn parse(text: &str) -> Result<Self> {
        Ok(match text.trim().to_ascii_lowercase().replace(['-', ' '], "_").as_str() {
            "pending" | "todo" => Status::Pending,
            "in_progress" | "active" | "doing" | "started" => Status::InProgress,
            "done" | "completed" | "complete" => Status::Done,
            "blocked" => Status::Blocked,
            "dropped" | "cancelled" | "canceled" | "skipped" => Status::Dropped,
            other => bail!("unknown status {other:?}; use pending, in_progress, done, blocked or dropped"),
        })
    }

    fn mark(self) -> &'static str {
        match self {
            Status::Pending => "[ ]",
            Status::InProgress => "[>]",
            Status::Done => "[x]",
            Status::Blocked => "[!]",
            Status::Dropped => "[-]",
        }
    }

    fn closed(self) -> bool {
        matches!(self, Status::Done | Status::Dropped)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanItem {
    pub id: u32,
    pub title: String,
    pub status: Status,
    /// Findings and decisions, oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    /// Items that must be done (or dropped) before this one is ready.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub after: Vec<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub goal: String,
    #[serde(default)]
    pub items: Vec<PlanItem>,
}

/// What a plan tool call did.
#[derive(Debug)]
pub struct Outcome {
    pub text: String,
    pub changed: bool,
}

impl Plan {
    pub fn is_empty(&self) -> bool {
        self.goal.is_empty() && self.items.is_empty()
    }

    /// (done, total), not counting dropped items.
    pub fn progress(&self) -> (usize, usize) {
        let live = self.items.iter().filter(|i| i.status != Status::Dropped);
        let total = live.clone().count();
        (live.filter(|i| i.status == Status::Done).count(), total)
    }

    fn item_mut(&mut self, id: u32) -> Result<&mut PlanItem> {
        let ids: Vec<String> = self.items.iter().map(|i| i.id.to_string()).collect();
        match self.items.iter_mut().find(|i| i.id == id) {
            Some(item) => Ok(item),
            None if ids.is_empty() => bail!("no item {id}: the plan is empty; add items with plan_add"),
            None => bail!("no item {id}; items are {}", ids.join(", ")),
        }
    }

    fn is_ready(&self, item: &PlanItem) -> bool {
        item.status == Status::Pending
            && item.after.iter().all(|dep| self.items.iter().find(|i| i.id == *dep).is_none_or(|i| i.status.closed()))
    }

    /// Items to work on next: those in progress, else the first ready one.
    fn next(&self) -> Vec<&PlanItem> {
        let active: Vec<&PlanItem> = self.items.iter().filter(|i| i.status == Status::InProgress).collect();
        if !active.is_empty() {
            return active;
        }
        self.items.iter().find(|i| self.is_ready(i)).into_iter().collect()
    }

    /// Run a plan tool.
    pub fn apply(&mut self, tool: &str, args: &Value) -> Result<Outcome> {
        match tool {
            "plan_add" => self.add(args),
            "plan_update" => self.update(args),
            "plan_show" => Ok(Outcome { text: self.render(true, usize::MAX), changed: false }),
            other => bail!("unknown plan tool {other}"),
        }
    }

    fn add(&mut self, args: &Value) -> Result<Outcome> {
        let mut plan = self.clone();
        let mut summary = Vec::new();
        if let Some(goal) = args.get("goal").and_then(Value::as_str).map(str::trim).filter(|g| !g.is_empty()) {
            plan.goal = clip(goal, MAX_GOAL_CHARS);
            summary.push("set the goal".to_string());
        }
        let items: Vec<Value> = match args.get("items").map(decoded).transpose()? {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items,
            Some(other) => vec![other],
        };
        if items.is_empty() && summary.is_empty() {
            bail!("plan_add needs `items` (a list of step titles or {{title, after}} objects) or a `goal`");
        }
        let first_id = plan.items.iter().map(|i| i.id).max().unwrap_or(0) + 1;
        if items.len() > MAX_ITEMS || plan.items.len() + items.len() > MAX_ITEMS {
            bail!("a plan holds at most {MAX_ITEMS} items; drop or merge some first");
        }
        let mut added = Vec::new();
        for (offset, item) in items.iter().enumerate() {
            let id = first_id + offset as u32;
            let (title, after, note) = match item {
                Value::String(title) => (title.as_str(), Vec::new(), None),
                Value::Object(fields) => {
                    let title = fields.get("title").and_then(Value::as_str).unwrap_or_default();
                    let after = fields.get("after").map(ids_of).transpose()?.unwrap_or_default();
                    (title, after, fields.get("note").and_then(Value::as_str))
                }
                _ => bail!("each item must be a title string or an object with a `title`"),
            };
            let title = title.trim();
            if title.is_empty() {
                bail!("item {} has an empty title", offset + 1);
            }
            for dep in &after {
                if *dep >= id || !plan.items.iter().any(|i| i.id == *dep) {
                    bail!("item {:?}: `after` must name earlier items, not {dep}", title);
                }
            }
            plan.items.push(PlanItem {
                id,
                title: clip(title, MAX_TITLE_CHARS),
                status: Status::Pending,
                notes: note.map(str::trim).filter(|n| !n.is_empty()).map(|n| clip(n, MAX_NOTE_CHARS)).into_iter().collect(),
                after,
            });
            added.push(id);
        }
        match added.as_slice() {
            [] => {}
            [id] => summary.push(format!("added item {id}")),
            [first, .., last] => summary.push(format!("added items {first}-{last}")),
        }
        *self = plan;
        Ok(self.outcome(&summary.join(", ")))
    }

    fn update(&mut self, args: &Value) -> Result<Outcome> {
        let updates: Vec<Value> = match args.get("updates").map(decoded).transpose()? {
            Some(Value::Array(list)) => list,
            Some(Value::Null) | None => vec![args.clone()],
            Some(other) => vec![other],
        };
        let mut plan = self.clone();
        let mut summary = Vec::new();
        for update in &updates {
            let Some(id) = update.get("id").and_then(id_of) else {
                bail!("plan_update needs the item `id`");
            };
            let item = plan.item_mut(id)?;
            let mut did = Vec::new();
            if let Some(status) = update.get("status").and_then(Value::as_str) {
                item.status = Status::parse(status)?;
                did.push(serde_json::to_value(item.status)?.as_str().unwrap_or_default().to_string());
            }
            if let Some(title) = update.get("title").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()) {
                item.title = clip(title, MAX_TITLE_CHARS);
                did.push("renamed".into());
            }
            if let Some(note) = update.get("note").and_then(Value::as_str).map(str::trim).filter(|n| !n.is_empty()) {
                item.notes.push(clip(note, MAX_NOTE_CHARS));
                did.push("noted".into());
            }
            if did.is_empty() {
                bail!("item {id}: give a `status`, `note` or `title` to change");
            }
            summary.push(format!("{id} {}", did.join(" + ")));
        }
        *self = plan;
        Ok(self.outcome(&format!("updated {}", summary.join(", "))))
    }

    fn outcome(&self, summary: &str) -> Outcome {
        let mut text = capitalize(summary);
        text.push_str(".\n");
        text.push_str(&self.render(false, usize::MAX));
        Outcome { text, changed: true }
    }

    /// The plan as a checklist. `notes` includes each item's notes; output
    /// over `budget` characters drops the notes of finished items, then all
    /// notes.
    pub fn render(&self, notes: bool, budget: usize) -> String {
        if self.is_empty() {
            return "The plan is empty.".to_string();
        }
        let modes: &[(bool, bool)] = if notes { &[(true, true), (true, false), (false, false)] } else { &[(false, false)] };
        let mut text = String::new();
        for &(open_notes, closed_notes) in modes {
            text = self.render_with(open_notes, closed_notes);
            if text.len() <= budget {
                break;
            }
        }
        text
    }

    fn render_with(&self, open_notes: bool, closed_notes: bool) -> String {
        let mut out = String::new();
        if !self.goal.is_empty() {
            out.push_str(&format!("Goal: {}\n", self.goal));
        }
        let (done, total) = self.progress();
        out.push_str(&format!("Plan ({done}/{total} done):\n"));
        for item in &self.items {
            let after = match item.after.as_slice() {
                [] => String::new(),
                ids => format!(" (after {})", ids.iter().map(u32::to_string).collect::<Vec<_>>().join(", ")),
            };
            out.push_str(&format!("{} {}. {}{after}\n", item.status.mark(), item.id, item.title));
            let show = if item.status.closed() { closed_notes } else { open_notes };
            if show {
                for note in &item.notes {
                    out.push_str(&format!("      - {}\n", note.replace('\n', "\n        ")));
                }
            } else if !item.notes.is_empty() {
                out.push_str(&format!("      ({} note{})\n", item.notes.len(), if item.notes.len() == 1 { "" } else { "s" }));
            }
        }
        let next = self.next();
        match next.as_slice() {
            [] if total > 0 && done == total => out.push_str("All items are done.\n"),
            [] => out.push_str("Nothing is ready: unblock or re-plan the remaining items.\n"),
            items => {
                let list: Vec<String> = items.iter().map(|i| format!("{}. {}", i.id, i.title)).collect();
                let label = if items[0].status == Status::InProgress { "In progress" } else { "Next" };
                out.push_str(&format!("{label}: {}\n", list.join("; ")));
            }
        }
        out
    }

    /// The plan restated for the model after its context was compacted.
    pub fn context_note(&self) -> String {
        format!(
            "[Your plan, kept by the harness. Earlier conversation may be summarized, but the plan and its notes are \
             complete. Continue from it and keep it current with plan_update.]\n{}",
            self.render(true, CONTEXT_CHARS)
        )
    }

    /// The plan handed to a new session that continues an earlier run.
    pub fn carried_over_note(&self) -> String {
        format!(
            "[A plan carried over from an earlier, interrupted run of this task, kept by the harness. Work already \
             marked done may be committed or pushed: check the current state before redoing it. Continue from the \
             plan and keep it current with plan_update.]\n{}",
            self.render(true, CONTEXT_CHARS)
        )
    }

    /// ACP `plan` entries (dropped items omitted).
    pub fn acp_entries(&self) -> Value {
        let entries: Vec<Value> = self
            .items
            .iter()
            .filter(|i| i.status != Status::Dropped)
            .map(|i| {
                let status = match i.status {
                    Status::Done => "completed",
                    Status::InProgress => "in_progress",
                    _ => "pending",
                };
                json!({ "content": i.title, "priority": "medium", "status": status })
            })
            .collect();
        Value::Array(entries)
    }

    /// Accept a plan from a client: this harness's own shape (`{goal, items}`
    /// as sent in `_meta.plan` of `plan` updates) or bare ACP entries.
    pub fn from_value(value: &Value) -> Result<Self> {
        if value.get("items").is_some() {
            let plan: Plan = serde_json::from_value(value.clone()).context("plan must be {goal, items: [{id, title, status}]}")?;
            plan.validate()?;
            return Ok(plan);
        }
        let entries = value.get("entries").unwrap_or(value).as_array().ok_or_else(|| anyhow::anyhow!("plan must be {{goal, items}} or a list of ACP plan entries"))?;
        let mut plan = Plan::default();
        for (index, entry) in entries.iter().enumerate() {
            let title = entry.get("content").or_else(|| entry.get("title")).and_then(Value::as_str).unwrap_or_default().trim();
            if title.is_empty() {
                continue;
            }
            let status = entry.get("status").and_then(Value::as_str).map(Status::parse).transpose()?.unwrap_or(Status::Pending);
            plan.items.push(PlanItem {
                id: index as u32 + 1,
                title: clip(title, MAX_TITLE_CHARS),
                status,
                notes: Vec::new(),
                after: Vec::new(),
            });
        }
        Ok(plan)
    }
}

impl Plan {
    /// Check a plan from outside (ids unique and in range, dependencies known).
    fn validate(&self) -> Result<()> {
        if self.items.len() > MAX_ITEMS {
            bail!("a plan holds at most {MAX_ITEMS} items");
        }
        let mut seen = std::collections::HashSet::new();
        for item in &self.items {
            if item.id == 0 || item.id > MAX_ID {
                bail!("plan item id {} is out of range 1-{MAX_ID}", item.id);
            }
            if !seen.insert(item.id) {
                bail!("plan item id {} is used twice", item.id);
            }
        }
        if let Some((item, dep)) = self.items.iter().find_map(|i| i.after.iter().find(|d| !seen.contains(d)).map(|d| (i.id, d))) {
            bail!("plan item {item} is after unknown item {dep}");
        }
        Ok(())
    }
}

/// Models sometimes send a nested list as a JSON string; decode it.
fn decoded(value: &Value) -> Result<Value> {
    match value {
        Value::String(text) if text.trim_start().starts_with(['[', '{']) => {
            serde_json::from_str(text).map_err(|e| anyhow::anyhow!("could not parse {text:?} as JSON: {e}; pass a list, not a string"))
        }
        other => Ok(other.clone()),
    }
}

pub fn is_plan_tool(name: &str) -> bool {
    TOOL_NAMES.contains(&name)
}

pub fn definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition::new(
            "plan_add",
            "Add steps to your task plan (and optionally set its overall goal). For work with more than a few steps, \
             make a plan first. The plan is kept outside the conversation: it survives when older messages are \
             summarized away, so it is where you track progress on long tasks. Items get numeric ids.",
            json!({
                "type": "object",
                "properties": {
                    "goal": { "type": "string", "description": "The overall objective, in one or two sentences" },
                    "items": {
                        "type": "array",
                        "description": "Steps in order: title strings, or {title, after, note} objects",
                        "items": {
                            "anyOf": [
                                { "type": "string" },
                                {
                                    "type": "object",
                                    "properties": {
                                        "title": { "type": "string" },
                                        "after": { "type": "array", "items": { "type": "integer" }, "description": "Ids of items that must be done first" },
                                        "note": { "type": "string" }
                                    },
                                    "required": ["title"]
                                }
                            ]
                        }
                    }
                }
            }),
        ),
        ToolDefinition::new(
            "plan_update",
            "Change a plan item: set its status (pending, in_progress, done, blocked, dropped), rename it, or add a \
             note. Mark an item in_progress when you start it and done when it is finished. Put findings you will \
             need later (file paths, decisions, commands, PR URLs) in a note: notes are kept even when the \
             conversation is summarized. Use `updates` to change several items at once.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "integer" },
                    "status": { "type": "string", "enum": ["pending", "in_progress", "done", "blocked", "dropped"] },
                    "note": { "type": "string" },
                    "title": { "type": "string" },
                    "updates": {
                        "type": "array",
                        "description": "Several updates, each {id, status?, note?, title?}",
                        "items": { "type": "object" }
                    }
                }
            }),
        ),
        ToolDefinition::new(
            "plan_show",
            "Show the whole plan with all notes.",
            json!({ "type": "object", "properties": {} }),
        ),
    ]
}

fn id_of(value: &Value) -> Option<u32> {
    match value {
        Value::Number(n) => n.as_u64().and_then(|n| u32::try_from(n).ok()),
        Value::String(s) => s.trim().trim_start_matches('#').parse().ok(),
        _ => None,
    }
}

fn ids_of(value: &Value) -> Result<Vec<u32>> {
    let list = match value {
        Value::Array(list) => list.clone(),
        Value::Null => Vec::new(),
        other => vec![other.clone()],
    };
    list.iter().map(|v| id_of(v).ok_or_else(|| anyhow::anyhow!("`after` must list item ids, got {v}"))).collect()
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max - 1).collect();
    out.push('…');
    out
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_updates_and_tracks_what_is_next() {
        let mut plan = Plan::default();
        let out = plan
            .apply("plan_add", &json!({"goal": "Ship it", "items": ["Read code", {"title": "Write fix", "after": [1]}, "Open PR"]}))
            .unwrap();
        assert!(out.changed);
        assert!(out.text.starts_with("Set the goal, added items 1-3.\n"), "{}", out.text);
        assert!(out.text.contains("[ ] 2. Write fix (after 1)"));
        assert!(out.text.contains("Next: 1. Read code"));

        let out = plan.apply("plan_update", &json!({"updates": [{"id": 1, "status": "done", "note": "bug in parser.rs:40"}, {"id": "2", "status": "in-progress"}]})).unwrap();
        assert!(out.text.starts_with("Updated 1 done + noted, 2 in_progress."), "{}", out.text);
        assert!(out.text.contains("[x] 1. Read code\n      (1 note)"));
        assert!(out.text.contains("In progress: 2. Write fix"));
        assert_eq!(plan.progress(), (1, 3));

        let full = plan.apply("plan_show", &json!({})).unwrap();
        assert!(!full.changed && full.text.contains("- bug in parser.rs:40"));
        plan.apply("plan_update", &json!({"id": 3, "status": "dropped"})).unwrap();
        plan.apply("plan_update", &json!({"id": 2, "status": "done"})).unwrap();
        assert!(plan.render(false, usize::MAX).ends_with("All items are done.\n"));
    }

    #[test]
    fn rejects_bad_calls_without_changing_the_plan() {
        let mut plan = Plan::default();
        plan.apply("plan_add", &json!({"items": ["a"]})).unwrap();
        let before = plan.clone();
        assert!(plan.apply("plan_update", &json!({"id": 9, "status": "done"})).unwrap_err().to_string().contains("items are 1"));
        assert!(plan.apply("plan_update", &json!({"updates": [{"id": 1, "status": "done"}, {"id": 1, "status": "nope"}]})).is_err());
        assert!(plan.apply("plan_add", &json!({"items": [{"title": "b", "after": [5]}]})).is_err());
        assert!(plan.apply("plan_add", &json!({})).is_err());
        assert!(plan.apply("plan_add", &json!({"items": "[\"unclosed"})).is_err());
        assert_eq!(plan, before);

        plan.apply("plan_add", &json!({"items": "[\"b\", {\"title\": \"c\", \"after\": [2]}]"})).unwrap();
        plan.apply("plan_update", &json!({"updates": "[{\"id\": 2, \"status\": \"done\"}]"})).unwrap();
        assert_eq!(plan.items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert_eq!(plan.items[1].status, Status::Done);

        for bad in [
            json!({"items": [{"id": 4294967295u32, "title": "x", "status": "pending"}]}),
            json!({"items": [{"id": 1, "title": "x", "status": "pending"}, {"id": 1, "title": "y", "status": "done"}]}),
            json!({"items": [{"id": 1, "title": "x", "status": "pending", "after": [3]}]}),
        ] {
            assert!(Plan::from_value(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn context_note_drops_finished_notes_first_and_round_trips_through_acp() {
        let mut plan = Plan::default();
        plan.apply("plan_add", &json!({"items": ["a", "b"]})).unwrap();
        plan.apply("plan_update", &json!({"id": 1, "status": "done", "note": "x".repeat(900)})).unwrap();
        plan.apply("plan_update", &json!({"id": 2, "note": "keep me"})).unwrap();
        let tight = plan.render(true, 300);
        assert!(tight.contains("- keep me") && tight.contains("(1 note)"), "{tight}");

        let meta = serde_json::to_value(&plan).unwrap();
        assert_eq!(Plan::from_value(&meta).unwrap(), plan);
        let entries = plan.acp_entries();
        assert_eq!(entries[0]["status"], "completed");
        let seeded = Plan::from_value(&entries).unwrap();
        assert_eq!(seeded.items[1].title, "b");
        assert_eq!(seeded.items[0].status, Status::Done);
    }
}
