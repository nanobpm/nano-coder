//! The interactive message queue: messages typed while a turn is running
//! wait here instead of steering, and run as later prompts — one per turn,
//! in the order they were queued.
//!
//! The queue is editable while a turn runs: `/queue` lists the waiting
//! messages, `/queue remove` drops entries, `/queue edit` rewrites one and
//! `/queue clear` empties it. Edits apply between turns, so a removed
//! message is never sent.
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
}

const USAGE: &str = "usage: /queue [list] | /queue remove N... | /queue edit N text | /queue clear";

/// Parse the arguments after `/queue` (empty means list).
pub fn parse(args: &str) -> Result<QueueOp, String> {
    let args = args.trim();
    if args.is_empty() || args == "list" || args == "ls" {
        return Ok(QueueOp::List);
    }
    let (sub, rest) = args.split_once(char::is_whitespace).unwrap_or((args, ""));
    let rest = rest.trim();
    match sub {
        "remove" | "rm" | "delete" => {
            let mut ids = Vec::new();
            for word in rest.split_whitespace() {
                let id = word
                    .parse::<usize>()
                    .map_err(|_| format!("{word:?} is not a queue id — {USAGE}"))?;
                ids.push(id);
            }
            if ids.is_empty() {
                return Err(USAGE.to_string());
            }
            Ok(QueueOp::Remove(ids))
        }
        "edit" => {
            let (id, text) = rest
                .split_once(char::is_whitespace)
                .ok_or_else(|| USAGE.to_string())?;
            let id = id
                .trim()
                .parse::<usize>()
                .map_err(|_| format!("{id:?} is not a queue id — {USAGE}"))?;
            let text = text.trim();
            if text.is_empty() {
                return Err(USAGE.to_string());
            }
            Ok(QueueOp::Edit { id, text: text.to_string() })
        }
        "clear" => Ok(QueueOp::Clear),
        _ => Err(USAGE.to_string()),
    }
}

/// Apply a parsed edit to the queue; the string says what happened.
pub fn apply(queue: &mut MessageQueue, op: &QueueOp) -> String {
    match op {
        QueueOp::List => describe(queue),
        QueueOp::Remove(ids) => {
            let removed = queue.remove(ids);
            if removed == 0 {
                format!("No queued message with {} ({})", ids_text(ids), queue_summary(queue))
            } else {
                format!("Removed {removed} queued message{} ({})", plural(removed), queue_summary(queue))
            }
        }
        QueueOp::Edit { id, text } => {
            if queue.edit(*id, text.clone()) {
                format!("Queue #{id} updated: {}", preview(text, 60))
            } else {
                format!("No queued message with id {id} ({})", queue_summary(queue))
            }
        }
        QueueOp::Clear => {
            let n = queue.clear();
            format!("Cleared {n} queued message{}", plural(n))
        }
    }
}

/// One line per waiting message, oldest first.
pub fn describe(queue: &MessageQueue) -> String {
    if queue.is_empty() {
        return "Queue is empty. Type a message while a turn runs to queue it.".to_string();
    }
    let mut out = format!("Queued ({}):", queue.len());
    for entry in queue.list() {
        out.push_str(&format!("\n  {:>3}  {}", entry.id, preview(&entry.text, 80)));
    }
    out
}

/// `N queued message[s]` / "queue is empty", for trailing summaries.
fn queue_summary(queue: &MessageQueue) -> String {
    match queue.len() {
        0 => "queue is empty".to_string(),
        n => format!("{n} queued"),
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

        let listed = apply(&mut queue, &QueueOp::List);
        assert!(listed.contains("Queued (3):"), "{listed}");
        assert!(listed.contains("  0  alpha") && listed.contains("  2  gamma"), "{listed}");

        let removed = apply(&mut queue, &QueueOp::Remove(vec![1, 9]));
        assert!(removed.contains("Removed 1 queued message"), "{removed}");
        assert!(removed.contains("(2 queued)"), "{removed}");

        let edited = apply(&mut queue, &QueueOp::Edit { id: 2, text: "GAMMA".into() });
        assert!(edited.contains("#2"), "{edited}");
        assert_eq!(queue.list()[1].text, "GAMMA");

        let missing = apply(&mut queue, &QueueOp::Remove(vec![7]));
        assert!(missing.contains("No queued message with id 7"), "{missing}");

        assert!(apply(&mut queue, &QueueOp::Clear).contains("Cleared 2"));
        assert_eq!(apply(&mut queue, &QueueOp::List), "Queue is empty. Type a message while a turn runs to queue it.");
    }

    #[test]
    fn preview_flattens_and_truncates() {
        assert_eq!(preview("hello\n  world", 80), "hello world");
        let long = "x".repeat(100);
        let shown = preview(&long, 10);
        assert_eq!(shown.chars().count(), 10);
        assert!(shown.ends_with('…'));
    }
}
