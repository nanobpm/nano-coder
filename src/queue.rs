//! The interactive message queue: messages typed while a turn is running
//! wait here instead of steering, and run as later prompts — one per turn,
//! in the order they were queued.
//!
//! The queue is editable while a turn runs: `/queue` lists the waiting
//! messages, `/queue remove` drops entries, `/queue edit` rewrites one and
//! `/queue clear` empties it. Edits apply between turns, so a removed
//! message is never sent.
//!
//! Steers (plain Enter mid-turn) share the same id space and the same
//! `/queue` surface: until the agent reads a steer at its next step it is
//! listed as `steer`, and `remove`/`edit`/`clear` apply to it too — so a
//! steer the running turn has made stale can be withdrawn or rewritten. A
//! steer the agent has already read is gone from the list.
//!
//! A queued message is never injected while the agent is waiting for input:
//! the drain happens only after the turn future has resolved (a pending
//! `question`/turn-cap picker parks the loop inside the turn), and
//! [`crate::Terminal::next`] re-checks that nothing is pending
//! before handing a queued message over as a prompt.

use std::collections::VecDeque;

/// One queued message, with the stable id `/queue` refers to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuedMessage {
    pub id: usize,
    pub text: String,
}

/// FIFO of messages waiting to run as prompts. Ids are monotonic: removing
/// or clearing entries never renumbers what is left, so an id the user read
/// off `/queue` mid-turn still refers to the same message when it is used.
#[derive(Default)]
pub struct MessageQueue {
    entries: VecDeque<QueuedMessage>,
    next_id: usize,
}

impl MessageQueue {
    /// Add a message; returns its id.
    pub fn push(&mut self, text: impl Into<String>) -> usize {
        let id = self.next_id;
        self.next_id += 1;
        self.entries.push_back(QueuedMessage { id, text: text.into() });
        id
    }

    /// Take an id without queueing anything (for a steer, so steers and
    /// queued messages never share an id).
    pub fn reserve_id(&mut self) -> usize {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Queue a message under an id taken earlier with [`Self::reserve_id`]
    /// (a steer the turn ended before reading keeps its id).
    pub fn push_with_id(&mut self, id: usize, text: impl Into<String>) {
        self.entries.push_back(QueuedMessage { id, text: text.into() });
    }

    /// The next message to run, if any.
    pub fn pop(&mut self) -> Option<QueuedMessage> {
        self.entries.pop_front()
    }

    /// The waiting messages, oldest first.
    pub fn list(&self) -> Vec<&QueuedMessage> {
        self.entries.iter().collect()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Drop the entries with these ids; returns how many were removed.
    pub fn remove(&mut self, ids: &[usize]) -> usize {
        let before = self.entries.len();
        self.entries.retain(|entry| !ids.contains(&entry.id));
        before - self.entries.len()
    }

    /// Replace one entry's text; false when no entry has that id.
    pub fn edit(&mut self, id: usize, text: impl Into<String>) -> bool {
        match self.entries.iter_mut().find(|entry| entry.id == id) {
            Some(entry) => {
                entry.text = text.into();
                true
            }
            None => false,
        }
    }

    /// Drop everything waiting; returns how many were removed.
    pub fn clear(&mut self) -> usize {
        let n = self.entries.len();
        self.entries.clear();
        n
    }
}

/// Steers sent to the running turn that the agent has not read yet. The
/// queue edits apply to them as well as to queued messages.
pub trait PendingSteers {
    fn pending(&self) -> Vec<(usize, String)>;
    fn remove(&self, ids: &[usize]) -> usize;
    fn edit(&self, id: usize, text: &str) -> bool;
    fn clear(&self) -> usize;
}

impl PendingSteers for crate::agent::TurnControl {
    fn pending(&self) -> Vec<(usize, String)> {
        self.pending_steers()
    }
    fn remove(&self, ids: &[usize]) -> usize {
        self.remove_steers(ids)
    }
    fn edit(&self, id: usize, text: &str) -> bool {
        self.edit_steer(id, text)
    }
    fn clear(&self) -> usize {
        self.clear_steers()
    }
}

/// One queue edit, parsed from a `/queue ...` command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueOp {
    /// Show the queue (`/queue`, `/queue list`).
    List,
    /// Drop entries by id (`/queue remove 2 4`, also `/queue rm`/`delete`).
    Remove(Vec<usize>),
    /// Rewrite one entry (`/queue edit 2 new text`).
    Edit { id: usize, text: String },
    /// Empty the queue (`/queue clear`).
    Clear,
    /// Queue a message (`/queue add text`), for terminals where Ctrl-Enter
    /// can't be told apart from Enter.
    Add(String),
}

const USAGE: &str = "usage: /queue [list] | /queue add text | /queue remove N... | /queue edit N text | /queue clear";

/// Parse the arguments after `/queue` (empty means list).
pub fn parse(args: &str) -> Result<QueueOp, String> {
    let args = args.trim();
    if args.is_empty() || args == "list" || args == "ls" {
        return Ok(QueueOp::List);
    }
    let (sub, rest) = args.split_once(char::is_whitespace).unwrap_or((args, ""));
    let rest = rest.trim();
    match sub {
        "add" if rest.is_empty() => Err(USAGE.to_string()),
        "add" => Ok(QueueOp::Add(rest.to_string())),
        "remove" | "rm" | "delete" => {
            let mut ids = Vec::new();
            for word in rest.split_whitespace() {
                let id = word.parse::<usize>().map_err(|_| format!("{word:?} is not a queue id — {USAGE}"))?;
                ids.push(id);
            }
            if ids.is_empty() {
                return Err(USAGE.to_string());
            }
            Ok(QueueOp::Remove(ids))
        }
        "edit" => {
            let (id, text) = rest.split_once(char::is_whitespace).ok_or_else(|| USAGE.to_string())?;
            let id = id.trim().parse::<usize>().map_err(|_| format!("{id:?} is not a queue id — {USAGE}"))?;
            let text = text.trim();
            if text.is_empty() {
                return Err(USAGE.to_string());
            }
            Ok(QueueOp::Edit { id, text: text.to_string() })
        }
        "clear" => {
            if !rest.is_empty() {
                return Err(USAGE.to_string());
            }
            Ok(QueueOp::Clear)
        }
        _ => Err(USAGE.to_string()),
    }
}

/// Apply a parsed edit to the queue and any unread steers; the string says
/// what happened.
pub fn apply(queue: &mut MessageQueue, steers: Option<&dyn PendingSteers>, op: &QueueOp) -> String {
    match op {
        QueueOp::List => describe(queue, steers),
        QueueOp::Remove(ids) => {
            let withdrawn = steers.map_or(0, |s| s.remove(ids));
            let removed = queue.remove(ids);
            match (withdrawn, removed) {
                (0, 0) => format!("No pending message with {} ({})", ids_text(ids), summary(queue, steers)),
                (0, n) => format!("Removed {n} queued message{} ({})", plural(n), summary(queue, steers)),
                (w, 0) => format!("Withdrew {w} steer{} ({})", plural(w), summary(queue, steers)),
                (w, n) => format!(
                    "Withdrew {w} steer{} and removed {n} queued message{} ({})",
                    plural(w),
                    plural(n),
                    summary(queue, steers)
                ),
            }
        }
        QueueOp::Edit { id, text } => {
            if steers.is_some_and(|s| s.edit(*id, text)) {
                format!("Steer #{id} updated: {}", preview(text, 60))
            } else if queue.edit(*id, text.clone()) {
                format!("Queue #{id} updated: {}", preview(text, 60))
            } else {
                format!("No pending message with id {id} ({})", summary(queue, steers))
            }
        }
        QueueOp::Add(text) => {
            let id = queue.push(text.clone());
            format!("↧ queued #{id} ({}) — /queue remove {id} to drop", summary(queue, steers))
        }
        QueueOp::Clear => {
            let w = steers.map_or(0, |s| s.clear());
            let n = queue.clear();
            if w == 0 {
                format!("Cleared {n} queued message{}", plural(n))
            } else {
                format!("Cleared {n} queued message{} and withdrew {w} steer{}", plural(n), plural(w))
            }
        }
    }
}

const EMPTY: &str =
    "Queue is empty. Enter while a turn runs steers it; Ctrl-Enter (or /queue add) queues a message for after it.";

/// One line per pending message: unread steers first (the agent reads them
/// at its next step), then queued messages, oldest first.
pub fn describe(queue: &MessageQueue, steers: Option<&dyn PendingSteers>) -> String {
    let pending = steers.map(|s| s.pending()).unwrap_or_default();
    if queue.is_empty() && pending.is_empty() {
        return EMPTY.to_string();
    }
    let mut out = format!("Pending ({}):", queue.len() + pending.len());
    for (id, text) in &pending {
        out.push_str(&format!("\n  {id:>3}  steer   {}", preview(text, 80)));
    }
    for entry in queue.list() {
        out.push_str(&format!("\n  {:>3}  queued  {}", entry.id, preview(&entry.text, 80)));
    }
    if !pending.is_empty() {
        out.push_str("\nSteers go to the agent at its next step; /queue remove or edit them before then.");
    }
    out
}

/// "2 steers, 1 queued" / "queue is empty", for trailing summaries.
fn summary(queue: &MessageQueue, steers: Option<&dyn PendingSteers>) -> String {
    let w = steers.map_or(0, |s| s.pending().len());
    match (w, queue.len()) {
        (0, 0) => "queue is empty".to_string(),
        (0, n) => format!("{n} queued"),
        (w, 0) => format!("{w} steer{} pending", plural(w)),
        (w, n) => format!("{w} steer{} pending, {n} queued", plural(w)),
    }
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

fn ids_text(ids: &[usize]) -> String {
    match ids {
        [id] => format!("id {id}"),
        ids => format!("ids {}", ids.iter().map(usize::to_string).collect::<Vec<_>>().join(", ")),
    }
}

/// The text on one line, cut to `max` characters with an ellipsis.
fn preview(text: &str, max: usize) -> String {
    let one_line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let count = one_line.chars().count();
    if count <= max {
        one_line
    } else {
        format!("{}…", one_line.chars().take(max.saturating_sub(1)).collect::<String>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_assigns_monotonic_ids_that_survive_removal_and_clear() {
        let mut queue = MessageQueue::default();
        let a = queue.push("first");
        let b = queue.push("second");
        let c = queue.push("third");
        assert_eq!((a, b, c), (0, 1, 2));

        assert_eq!(queue.remove(&[b]), 1);
        let remaining: Vec<usize> = queue.list().iter().map(|m| m.id).collect();
        assert_eq!(remaining, [0, 2], "ids are not renumbered");

        assert_eq!(queue.clear(), 2);
        assert!(queue.is_empty());
        let d = queue.push("fourth");
        assert_eq!(d, 3, "ids keep climbing after a clear");
    }

    #[test]
    fn pop_is_fifo_and_edit_rewrites_in_place() {
        let mut queue = MessageQueue::default();
        queue.push("one");
        queue.push("two");
        assert!(queue.edit(1, "TWO"));
        assert!(!queue.edit(9, "nope"), "unknown id rejected");
        assert_eq!(queue.pop().unwrap().text, "one");
        assert_eq!(queue.pop().unwrap().text, "TWO");
        assert!(queue.pop().is_none());
    }

    #[test]
    fn parse_covers_the_subcommands() {
        assert_eq!(parse(""), Ok(QueueOp::List));
        assert_eq!(parse("  "), Ok(QueueOp::List));
        assert_eq!(parse("list"), Ok(QueueOp::List));
        assert_eq!(parse("ls"), Ok(QueueOp::List));
        assert_eq!(parse("remove 2"), Ok(QueueOp::Remove(vec![2])));
        assert_eq!(parse("rm 2 4"), Ok(QueueOp::Remove(vec![2, 4])));
        assert_eq!(parse("delete 3"), Ok(QueueOp::Remove(vec![3])));
        assert_eq!(parse("edit 2 try this instead"), Ok(QueueOp::Edit { id: 2, text: "try this instead".into() }));
        assert_eq!(parse("clear"), Ok(QueueOp::Clear));

        assert!(parse("clear keep-this").is_err(), "clear rejects trailing arguments");
        assert!(parse("remove").is_err(), "remove needs an id");
        assert!(parse("remove x").is_err(), "ids are numbers");
        assert!(parse("edit 2").is_err(), "edit needs replacement text");
        assert!(parse("edit 2   ").is_err(), "blank replacement rejected");
        assert!(parse("edit x hi").is_err());
        assert!(parse("frob").is_err(), "unknown subcommand shows usage");
    }

    #[test]
    fn apply_reports_what_happened() {
        let mut queue = MessageQueue::default();
        queue.push("alpha");
        queue.push("beta");
        queue.push("gamma");

        let listed = apply(&mut queue, None, &QueueOp::List);
        assert!(listed.contains("Pending (3):"), "{listed}");
        assert!(listed.contains("  0  queued  alpha") && listed.contains("  2  queued  gamma"), "{listed}");

        let removed = apply(&mut queue, None, &QueueOp::Remove(vec![1, 9]));
        assert!(removed.contains("Removed 1 queued message"), "{removed}");
        assert!(removed.contains("(2 queued)"), "{removed}");

        let edited = apply(&mut queue, None, &QueueOp::Edit { id: 2, text: "GAMMA".into() });
        assert!(edited.contains("#2"), "{edited}");
        assert_eq!(queue.list()[1].text, "GAMMA");

        let missing = apply(&mut queue, None, &QueueOp::Remove(vec![7]));
        assert!(missing.contains("No pending message with id 7"), "{missing}");

        assert!(apply(&mut queue, None, &QueueOp::Clear).contains("Cleared 2"));
        assert_eq!(apply(&mut queue, None, &QueueOp::List), EMPTY);
    }

    #[test]
    fn preview_flattens_and_truncates() {
        assert_eq!(preview("hello\n  world", 80), "hello world");
        let long = "x".repeat(100);
        let shown = preview(&long, 10);
        assert_eq!(shown.chars().count(), 10);
        assert!(shown.ends_with('…'));
    }

    #[test]
    fn add_queues_a_message() {
        assert_eq!(parse("add fix the build").unwrap(), QueueOp::Add("fix the build".into()));
        assert!(parse("add").is_err());
        assert!(parse("add   ").is_err());
        let mut queue = MessageQueue::default();
        let note = apply(&mut queue, None, &QueueOp::Add("later".into()));
        assert!(note.starts_with("↧ queued #") && note.contains("/queue remove"), "{note}");
        assert_eq!(queue.len(), 1);
    }

    #[test]
    fn edits_reach_unread_steers_and_share_ids_with_the_queue() {
        let control = crate::agent::TurnControl::default();
        let mut queue = MessageQueue::default();
        let s0 = queue.reserve_id();
        control.steer_with_id("use the old api", s0);
        let q1 = queue.push("then write docs");
        let s2 = queue.reserve_id();
        control.steer_with_id("skip the tests", s2);
        control.steer("acp steer, not listed", None);
        assert_eq!((s0, q1, s2), (0, 1, 2));
        let steers: Option<&dyn PendingSteers> = Some(&control);

        let listed = apply(&mut queue, steers, &QueueOp::List);
        assert!(listed.starts_with("Pending (3):"), "{listed}");
        assert!(listed.contains("  0  steer   use the old api"), "{listed}");
        assert!(listed.contains("  1  queued  then write docs"), "{listed}");
        assert!(!listed.contains("acp steer"), "{listed}");

        let edited = apply(&mut queue, steers, &QueueOp::Edit { id: 0, text: "use the new api".into() });
        assert!(edited.starts_with("Steer #0 updated"), "{edited}");
        assert_eq!(control.pending_steers()[0].1, "use the new api");

        let removed = apply(&mut queue, steers, &QueueOp::Remove(vec![2, 1]));
        assert!(removed.contains("Withdrew 1 steer and removed 1 queued message"), "{removed}");
        assert!(removed.contains("(1 steer pending)"), "{removed}");

        // Once the agent reads a steer it is no longer editable.
        let read = control.take_pending();
        assert_eq!(read.len(), 2, "the edited steer and the untracked one are delivered");
        assert_eq!(read[0].text, "use the new api");
        let late = apply(&mut queue, steers, &QueueOp::Edit { id: 0, text: "too late".into() });
        assert!(late.starts_with("No pending message with id 0"), "{late}");

        let s3 = queue.reserve_id();
        control.steer_with_id("one more", s3);
        control.steer("untracked", None);
        let cleared = apply(&mut queue, steers, &QueueOp::Clear);
        assert!(cleared.contains("withdrew 1 steer"), "{cleared}");
        assert_eq!(control.take_pending().len(), 1, "clear leaves untracked (ACP) steers alone");
    }
}
