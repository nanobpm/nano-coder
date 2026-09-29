//! Input history for the prompt's line editor: submitted lines, newest last,
//! with shell-style Up/Down recall.
//!
//! The history is session-scoped (nothing is written to disk) and lives in
//! the [`crate::lineedit::EditView`], so it covers every line read key by
//! key — both prompt submissions and messages typed mid-turn into the queue.

/// Submitted input lines, oldest first.
#[derive(Default)]
pub struct InputHistory {
    lines: Vec<String>,
    /// While browsing: the entry currently shown (None = the draft at the
    /// bottom). Reset by any edit, so after recalling an entry and changing
    /// it the next Up starts again from the newest entry — like readline.
    position: Option<usize>,
    /// The line as it was before the first Up, restored by Down past the
    /// newest entry.
    draft: String,
}

/// Most entries kept; the oldest drop off the front.
const MAX_ENTRIES: usize = 200;

impl InputHistory {
    /// Record a submitted line. Blank lines and exact repeats of the previous
    /// line are not kept (repeats still reset browsing via `edited`, which the
    /// editor calls on the same key press).
    pub fn record(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() || self.lines.last().is_some_and(|last| last == line) {
            return;
        }
        self.lines.push(line.to_string());
        if self.lines.len() > MAX_ENTRIES {
            self.lines.remove(0);
        }
    }

    /// The entry one step older than the one shown, or None at the oldest.
    /// The first call steps back from the draft, which is saved for `down`.
    pub fn up(&mut self, current: &str) -> Option<&str> {
        match self.position {
            None => {
                let newest = self.lines.len().checked_sub(1)?;
                self.draft = current.to_string();
                self.position = Some(newest);
            }
            Some(index) => {
                if index == 0 {
                    return None;
                }
                self.position = Some(index - 1);
            }
        }
        self.position.map(|index| self.lines[index].as_str())
    }

    /// The entry one step newer than the one shown; past the newest, the
    /// saved draft. None when not browsing.
    pub fn down(&mut self) -> Option<&str> {
        let index = self.position?;
        if index + 1 < self.lines.len() {
            self.position = Some(index + 1);
            Some(&self.lines[index + 1])
        } else {
            self.position = None;
            Some(self.draft.as_str())
        }
    }

    /// The line changed by other means (typing, deletion, completion, a
    /// submit): the next Up starts again from the newest entry. Any draft
    /// saved by that Up is the edited line — like readline, where editing a
    /// recalled entry makes it the line Down returns to.
    pub fn edited(&mut self) {
        self.position = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn up_walks_back_then_stops_at_the_oldest() {
        let mut history = InputHistory::default();
        assert_eq!(history.up(""), None, "empty history");
        history.record("first");
        history.record("second");
        assert_eq!(history.up(""), Some("second"));
        assert_eq!(history.up(""), Some("first"));
        assert_eq!(history.up(""), None, "at the oldest: stay");
        assert_eq!(history.down(), Some("second"));
    }

    #[test]
    fn down_returns_to_the_draft() {
        let mut history = InputHistory::default();
        history.record("first");
        history.record("second");
        assert_eq!(history.up("typed so far"), Some("second"));
        assert_eq!(history.up("second"), Some("first"));
        assert_eq!(history.down(), Some("second"));
        assert_eq!(history.down(), Some("typed so far"));
        assert_eq!(history.down(), None, "no longer browsing");
    }

    #[test]
    fn an_edit_resets_browsing_to_the_newest() {
        let mut history = InputHistory::default();
        history.record("first");
        history.record("second");
        assert_eq!(history.up(""), Some("second"));
        history.edited();
        // Starts over from the newest.
        assert_eq!(history.up(""), Some("second"));
        // The edited line is the draft Down returns to (like readline).
        assert_eq!(history.down(), Some(""));
        assert_eq!(history.down(), None, "no longer browsing");
    }

    #[test]
    fn skips_blanks_and_immediate_repeats_and_bounds_the_list() {
        let mut history = InputHistory::default();
        history.record("  ");
        history.record("one");
        history.record("one");
        history.record(" one ");
        assert_eq!(history.lines.len(), 1);
        for i in 0..(MAX_ENTRIES + 10) {
            history.record(&format!("line {i}"));
        }
        assert_eq!(history.lines.len(), MAX_ENTRIES);
        assert_eq!(history.lines[0], "line 10");
    }
}
