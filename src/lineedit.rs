//! Minimal line editor for a terminal stdin. Reading key by key (instead of
//! the kernel's line mode) lets Ctrl-O and Ctrl-C act immediately, and lets
//! text typed during a turn show on the status line instead of mixing with
//! streamed output.
//!
//! The input is a (possibly multi-line) buffer with a cursor: arrow keys,
//! Home/End and Alt/Option word jumps move it, Ctrl-Enter (or Cmd-Enter,
//! via modifyOtherKeys/kitty-style key reporting) inserts a newline at the
//! prompt and queues the line during a turn (where Enter steers), and a
//! bracketed paste keeps its line breaks instead of sending line by line.
//! The mouse is never captured, so the terminal keeps its native wheel
//! scrolling and text selection.

use std::sync::{Arc, Mutex, OnceLock};

use crate::input_history::InputHistory;
use crate::status::StatusLine;

/// Where the line being typed is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditMode {
    /// After the `> ` prompt, inline.
    Prompt,
    /// During a turn: on the status line (inline if there is none).
    Turn,
}

pub struct EditView {
    line: String,
    /// Cursor position as a character index into `line` (0..=chars).
    cursor: usize,
    mode: EditMode,
    status: Option<Arc<StatusLine>>,
    /// Rows below the prompt used by the command menu.
    menu_rows: usize,
    /// Esc hid the menu; it comes back when the line changes.
    menu_hidden: bool,
    /// Draw the command menu (key-by-key terminal input only).
    menu_enabled: bool,
    /// Visible width of the prompt before the line (it starts with a
    /// timestamp when timestamps are on).
    prompt_width: usize,
    /// Messages waiting in the queue (drives the status-line indicator).
    queue_count: usize,
    /// Live configuration, for `/model` argument suggestions. Shared with the
    /// agent loop so a model/provider change is seen on the next keystroke.
    context: Arc<Mutex<EditContext>>,
    /// Rows the last prompt redraw occupies, menu included; the next redraw
    /// clears this many rows below the prompt's first row before reprinting.
    drawn_rows: usize,
    /// Rows the cursor sits below the prompt's first row after the last
    /// redraw. The next redraw climbs back up this many rows to reach the
    /// prompt row before reprinting, so a wrapped/newline row is never
    /// mistaken for the prompt row.
    drawn_cursor_row: usize,
    /// Set in the app-owned frame renderer (`renderer = "frame"`): the editor
    /// no longer writes escape sequences itself. Instead each change calls this
    /// with `(line, cursor)` so the single frame writer redraws the editor row.
    on_edit: Option<EditHook>,
    /// Submitted lines, browsed with Up/Down.
    history: InputHistory,
}

/// What the argument type-ahead needs from the agent loop.
#[derive(Default)]
pub struct EditContext {
    pub config: crate::config::Config,
    pub recents: crate::recents::SharedRecents,
}

pub type SharedView = Arc<Mutex<EditView>>;

/// Hook the app-owned frame renderer installs to receive `(line, cursor,
/// queued)` on every editor change instead of the editor writing escape
/// sequences itself. `queued` is the number of messages waiting behind the
/// current turn, shown as an indicator under the editor.
pub type EditHook = Arc<dyn Fn(&str, usize, usize) + Send + Sync>;

impl EditView {
    pub fn shared(status: Option<Arc<StatusLine>>, context: Arc<Mutex<EditContext>>) -> SharedView {
        Arc::new(Mutex::new(Self {
            line: String::new(),
            cursor: 0,
            mode: EditMode::Prompt,
            status,
            menu_rows: 0,
            menu_hidden: false,
            menu_enabled: false,
            prompt_width: 2,
            queue_count: 0,
            context,
            drawn_rows: 0,
            drawn_cursor_row: 0,
            on_edit: None,
            history: InputHistory::default(),
        }))
    }

    /// Route editor drawing through the app-owned frame renderer: every change
    /// calls `hook(line, cursor)` instead of writing escape sequences, and the
    /// inline command menu (which writes directly) is disabled.
    pub fn set_edit_hook(&mut self, hook: EditHook) {
        self.on_edit = Some(hook);
        self.menu_enabled = false;
    }

    /// The current line and cursor (a character index), for the frame renderer.
    pub fn snapshot(&self) -> (String, usize) {
        (self.line.clone(), self.cursor)
    }

    /// Redraw the editor: through the frame hook when set, else inline / on the
    /// status line as before.
    fn draw_edit(&mut self) {
        if let Some(hook) = self.on_edit.clone() {
            hook(&self.line, self.cursor, self.queue_count);
            return;
        }
        match self.on_status() {
            Some(status) => self.show_on_status(status),
            None => self.redraw(),
        }
    }

    pub fn set_mode(&mut self, mode: EditMode) {
        self.mode = mode;
        if self.on_edit.is_some() {
            // The frame renderer owns the screen: refresh through the hook
            // rather than writing the legacy status row, which would corrupt
            // the frame.
            self.draw_edit();
            return;
        }
        if let Some(status) = &self.status {
            match mode {
                EditMode::Turn => self.show_on_status(status),
                _ => status.set_input(None, 0),
            }
        }
    }

    /// Update the queue indicator on the status line (None hides it).
    pub fn set_queue_count(&mut self, count: Option<usize>) {
        self.queue_count = count.unwrap_or(0);
        if self.on_edit.is_some() {
            // Suppress the legacy status write in frame mode; re-render instead.
            self.draw_edit();
            return;
        }
        if let Some(status) = self.on_status() {
            self.show_on_status(status);
        }
    }

    /// The shared suggestion context, so the agent loop can refresh the
    /// config after a model/provider change.
    pub fn context_handle(&self) -> Arc<Mutex<EditContext>> {
        self.context.clone()
    }

    fn on_status(&self) -> Option<&StatusLine> {
        (self.mode == EditMode::Turn).then_some(self.status.as_deref()).flatten()
    }

    /// Byte offset of `idx` characters into the line.
    fn byte_of(&self, idx: usize) -> usize {
        self.line.char_indices().nth(idx).map(|(i, _)| i).unwrap_or(self.line.len())
    }

    /// Insert `text` at the cursor. Newlines are kept: the input is
    /// multi-line, and only Enter (not part of a paste) sends it.
    fn insert(&mut self, text: &str) {
        let at = self.byte_of(self.cursor);
        self.line.insert_str(at, text);
        self.cursor += text.chars().count();
        self.draw_edit();
        self.line_changed();
    }

    /// The text with the cursor marked plus the queue count, for the status
    /// line. The status line stores it raw and renders (prefix, cursor, queue,
    /// padding) once at draw time. An empty line with messages queued still
    /// shows the queue indicator.
    fn show_on_status(&self, status: &StatusLine) {
        if self.line.is_empty() && self.queue_count == 0 {
            status.set_input(None, 0);
        } else {
            status.set_input(Some((&self.line, self.cursor)), self.queue_count);
        }
    }

    fn line_changed(&mut self) {
        self.menu_hidden = false;
        self.history.edited();
        self.draw_menu();
    }

    fn menu_visible(&self) -> bool {
        self.menu_rows > 0
    }

    /// Redraw the command menu below the prompt for the current line.
    fn draw_menu(&mut self) {
        if !self.menu_enabled || self.mode != EditMode::Prompt {
            return;
        }
        let (rows, cols) = crate::status::terminal_size().unwrap_or((24, 80));
        // Reserve the prompt row, plus the status row only when a status line
        // is present (none under AGENTIC_NO_STATUS or a short terminal).
        let reserved = if self.status.is_some() { 2 } else { 1 };
        let max_rows = (rows as usize).saturating_sub(reserved).min(16);
        let lines = if self.menu_hidden {
            Vec::new()
        } else if crate::commands::has_argument_menu(&self.line) {
            // Past the command name: argument type-ahead for the commands
            // with a known argument set (`/model`, `/mode`, `/verbosity`).
            let context = self.context.lock().unwrap();
            let recents = context.recents.lock().unwrap().models().to_vec();
            let found = crate::commands::suggestions(&context.config, &recents, &self.line);
            crate::commands::suggestion_menu(&found, &self.line, cols as usize, max_rows)
        } else {
            crate::commands::menu(&self.line, cols as usize, max_rows)
        };
        let (seq, used) = menu_sequence(self.menu_rows, &lines, self.status.is_some());
        self.menu_rows = used;
        if !seq.is_empty() {
            write(&seq);
        }
    }

    /// Hide the menu (Esc) until the line changes.
    fn hide_menu(&mut self) {
        self.menu_hidden = true;
        self.draw_menu();
    }

    /// Tab: complete a `/command` or its first argument (`/model`, `/mode`,
    /// `/verbosity` have a known argument set); elsewhere a space.
    fn tab(&mut self) {
        if !self.line.starts_with('/') {
            self.insert(" ");
            return;
        }
        let completed = {
            let context = self.context.lock().unwrap();
            let recents = context.recents.lock().unwrap().models().to_vec();
            crate::commands::complete_line(&context.config, &recents, &self.line)
        };
        match completed {
            Some(done) => self.replace_line(&done),
            // Restore the documented space fallback for a slash line past its
            // command name (e.g. `/compact focus`, `/model value extra`) that
            // has no completion, while keeping Tab a no-op for a bare ambiguous
            // command (`/s`) and for the known first-argument menus (`/model`,
            // `/mode`, `/verbosity`).
            None if self.line.contains(char::is_whitespace)
                && !crate::commands::has_argument_menu(&self.line) =>
            {
                self.insert(" ");
            }
            None => {}
        }
    }

    /// Replace the whole input with `line`. `complete_line` canonicalizes the
    /// separator, so `done` need not start with the raw text typed (e.g.
    /// `/model  ol` with extra spacing); comparing by characters keeps the
    /// shared leading run — rewriting only what changed — and never slices on a
    /// byte boundary, so irregular spacing can no longer panic.
    fn replace_line(&mut self, line: &str) {
        let shared = self.line.chars().zip(line.chars()).take_while(|(a, b)| a == b).count();
        let extra = self.line.chars().count().saturating_sub(shared);
        // A completion rewrites the whole command line, so work from the end
        // regardless of where the cursor sits; deleting/inserting at a mid-line
        // cursor would corrupt the command.
        self.cursor = self.line.chars().count();
        for _ in 0..extra {
            self.backspace();
        }
        let tail: String = line.chars().skip(shared).collect();
        if !tail.is_empty() {
            self.insert(&tail);
        }
    }

    /// The prompt (`HH:MM:SS > `) followed by the line so far.
    pub fn prompt(&mut self) -> String {
        let stamp = crate::ui::stamp();
        self.prompt_width = crate::ui::visible_width(&stamp) + 2;
        format!("{stamp}> {}", self.line)
    }

    /// Terminal rows the content occupies from the prompt's row, given a
    /// `cols`-wide terminal. Newlines start a new row; a row filled exactly
    /// leaves the cursor on it (pending wrap).
    fn content_rows(&self, cols: usize) -> usize {
        if cols == 0 {
            return 1;
        }
        let (mut row, mut col) = self.prompt_start(cols);
        for c in self.line.chars() {
            if c == '\n' {
                row += 1;
                col = 0;
            } else {
                // Pending wrap, matching `cursor_position`: a row filled
                // exactly leaves the cursor on it, and only the *next*
                // character starts a new row.
                if col == cols {
                    row += 1;
                    col = 0;
                }
                col += 1;
            }
        }
        row + 1
    }

    /// The prompt's end position `(row, col)` from its first row, shared by
    /// every wrap helper so they agree. A prompt that exactly fills one or more
    /// rows is a pending wrap: the cursor rests at column `cols` on the last
    /// filled row and the first input character wraps to the next row. On a
    /// terminal wide enough for the prompt this is simply `(0, prompt_width)`.
    fn prompt_start(&self, cols: usize) -> (usize, usize) {
        let cols = cols.max(1);
        let w = self.prompt_width;
        if w > 0 && w.is_multiple_of(cols) {
            (w / cols - 1, cols)
        } else {
            (w / cols, w % cols)
        }
    }

    /// The cursor's row and column, counted from the prompt's row. The column
    /// is where the *next* character would go, which is how terminals report
    /// the cursor (a row filled exactly is a pending wrap: column `cols`).
    /// The cursor's row and column, counted from the prompt's row. The column
    /// is where the *next* character would go: a row filled exactly leaves the
    /// cursor on it at column `cols` (a pending wrap), and printing one more
    /// character wraps to the next row.
    fn cursor_position(&self, cols: usize) -> (usize, usize) {
        self.position_at(self.cursor, cols)
    }

    /// Row and column after the first `idx` characters of the line, counted
    /// as for [`cursor_position`](Self::cursor_position).
    fn position_at(&self, idx: usize, cols: usize) -> (usize, usize) {
        let cols = cols.max(1);
        let (mut row, mut col) = self.prompt_start(cols);
        for c in self.line.chars().take(idx) {
            if c == '\n' {
                row += 1;
                col = 0;
            } else {
                if col == cols {
                    row += 1;
                    col = 0;
                }
                col += 1;
            }
        }
        (row, col)
    }

    /// Reprint the prompt and the whole input with the cursor where
    /// `self.cursor` is, clearing whatever an earlier redraw (or the menu)
    /// left below. Only meaningful at the prompt; on the status line the
    /// caller updates it instead.
    fn redraw(&mut self) {
        if !self.menu_enabled || self.mode != EditMode::Prompt {
            return;
        }
        let (_rows, cols) = crate::status::terminal_size().unwrap_or((24, 80));
        let seq = self.redraw_sequence((cols as usize).max(1), &crate::ui::stamp());
        write(&seq);
    }

    /// The bytes for [`redraw`](Self::redraw) at a `cols`-wide terminal, and
    /// the bookkeeping update for the next redraw.
    ///
    /// Every cursor movement is relative to where the cursor actually is. In
    /// particular the cursor is not saved and restored (DECSC/DECRC) around the
    /// print: that saves an absolute screen row, and when printing a wrapped
    /// input scrolls the screen the prompt moves up while the saved row does
    /// not, leaving the cursor rows below the prompt. The next redraw then
    /// reprints from the wrong row, stacking a stale copy of the input on
    /// every key press.
    fn redraw_sequence(&mut self, cols: usize, stamp: &str) -> String {
        let content = self.content_rows(cols);
        let (cursor_row, cursor_col) = self.cursor_position(cols);
        let (end_row, _) = self.position_at(self.line.chars().count(), cols);
        let mut seq = String::new();
        // Climb from where the last redraw left the cursor to the prompt row.
        if self.drawn_cursor_row > 0 {
            seq.push_str(&format!("\x1b[{}A", self.drawn_cursor_row));
        }
        seq.push('\r');
        // Blank the rows the last redraw used (menu included), row by row
        // rather than with erase-below, which would also wipe the status line
        // pinned under the scroll region. These rows already exist on screen,
        // so moving down them never scrolls.
        let old = self.drawn_rows.max(1);
        for i in 0..old {
            if i > 0 {
                seq.push_str("\x1b[1B");
            }
            seq.push_str("\x1b[2K");
        }
        if old > 1 {
            seq.push_str(&format!("\x1b[{}A", old - 1));
        }
        // Print. This may scroll the screen; the cursor ends at the end of
        // the input, `end_row` rows below the prompt wherever it now is.
        seq.push_str(&format!("\r{stamp}> {}", self.line));
        // Walk back from the end of the input to the edit cursor.
        if end_row > cursor_row {
            seq.push_str(&format!("\x1b[{}A", end_row - cursor_row));
        }
        seq.push('\r');
        if cursor_col > 0 {
            seq.push_str(&format!("\x1b[{cursor_col}C"));
        }
        // The menu's rows stay reserved (blank) until `draw_menu` refills them.
        self.drawn_rows = content + self.menu_rows;
        self.drawn_cursor_row = cursor_row;
        seq
    }

    /// On Enter: rewrite the prompt's timestamp with the time the line was
    /// sent. Same width, so nothing reflows.
    fn restamp_prompt(&self) {
        let stamp = crate::ui::stamp();
        if !self.menu_enabled || self.mode != EditMode::Prompt || stamp.is_empty() || self.prompt_width <= 2 {
            return;
        }
        let cols = crate::status::terminal_size().map(|(_, c)| c as usize).unwrap_or(80);
        let up = self.cursor_position(cols).0;
        let up = if up > 0 { format!("\x1b[{up}A") } else { String::new() };
        write(&format!("\x1b7{up}\r{stamp}\x1b8"));
    }

    /// The prompt and line were printed again (after other output): the old
    /// menu rows scrolled away, so draw it afresh.
    pub fn prompt_redrawn(&mut self) {
        self.menu_rows = 0;
        let content = self.content_rows(crate::status::terminal_size().map(|(_, c)| c as usize).unwrap_or(80));
        self.drawn_rows = content;
        // The prompt and whole line were just printed, so the cursor rests at
        // the end of the input, on its last row.
        self.drawn_cursor_row = content.saturating_sub(1);
        self.draw_menu();
    }

    /// The terminal was resized: the old menu rows may no longer fit under the
    /// new scroll region, so blank the rows we reserved and redraw the menu
    /// sized to the new terminal. Call after the status line re-establishes the
    /// scroll region for the new size.
    pub fn resize(&mut self) {
        if let Some(hook) = self.on_edit.clone() {
            // The frame renderer redraws every row at the new width itself.
            hook(&self.line, self.cursor, self.queue_count);
            return;
        }
        // With a status line, its resize erased everything below the cursor
        // (the menu included) and re-anchored the prompt, so only redraw.
        if self.menu_rows > 0 && self.status.is_none() {
            let (seq, _) = menu_sequence(self.menu_rows, &[], false);
            write(&seq);
        }
        self.menu_rows = 0;
        self.draw_menu();
        // The status resize re-anchored the prompt and the non-status branch
        // above restored the cursor to the prompt row, so it now sits on the
        // prompt's first row.
        self.drawn_cursor_row = 0;
        // Reflow moved the input's rows; reprint it with the cursor back
        // where it belongs.
        self.redraw();
    }

    /// Remove the character before the cursor (Backspace).
    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor -= 1;
        let at = self.byte_of(self.cursor);
        self.line.remove(at);
        self.draw_edit();
        self.line_changed();
    }

    /// Remove the character under the cursor (Delete).
    fn delete(&mut self) {
        if self.cursor >= self.line.chars().count() {
            return;
        }
        let at = self.byte_of(self.cursor);
        self.line.remove(at);
        self.draw_edit();
        self.line_changed();
    }

    /// Remove the word before the cursor, plus any whitespace separating it
    /// from the cursor.
    fn erase_word(&mut self) {
        let before: String = self.line.chars().take(self.cursor).collect();
        let trimmed = before.trim_end();
        let word_start = trimmed
            .char_indices()
            .rev()
            .find(|(_, c)| c.is_whitespace())
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(0);
        let start = before[..word_start].chars().count();
        let from = self.byte_of(start);
        let to = self.byte_of(self.cursor);
        self.line.replace_range(from..to, "");
        self.cursor = start;
        self.draw_edit();
        self.line_changed();
    }

    /// Clear the whole input (Ctrl-U).
    fn clear_line(&mut self) {
        if self.line.is_empty() {
            return;
        }
        self.line.clear();
        self.cursor = 0;
        self.draw_edit();
        self.line_changed();
    }

    /// Move the cursor, updating the status line or the terminal cursor.
    fn move_to(&mut self, idx: usize) {
        let idx = idx.min(self.line.chars().count());
        if idx == self.cursor {
            return;
        }
        self.cursor = idx;
        self.draw_edit();
    }

    fn move_left(&mut self) {
        self.move_to(self.cursor.saturating_sub(1));
    }

    fn move_right(&mut self) {
        self.move_to(self.cursor + 1);
    }

    fn move_home(&mut self) {
        self.move_to(0);
    }

    fn move_end(&mut self) {
        self.move_to(self.line.chars().count());
    }

    /// Word boundaries follow readline: a word ends at whitespace.
    fn move_word_left(&mut self) {
        let before: Vec<char> = self.line.chars().take(self.cursor).collect();
        let mut i = before.len();
        while i > 0 && before[i - 1].is_whitespace() {
            i -= 1;
        }
        while i > 0 && !before[i - 1].is_whitespace() {
            i -= 1;
        }
        self.move_to(i);
    }

    fn move_word_right(&mut self) {
        let chars: Vec<char> = self.line.chars().collect();
        let mut i = self.cursor;
        while i < chars.len() && !chars[i].is_whitespace() {
            i += 1;
        }
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        self.move_to(i);
    }

    /// Up: replace the input with the previous history entry (the first press
    /// saves the line being typed; Down past the newest entry restores it).
    /// At the oldest entry the line stays put.
    fn history_up(&mut self) {
        let Some(entry) = self.history.up(&self.line).map(str::to_string) else { return };
        self.set_line(&entry);
    }

    /// Down: the next-newer history entry, or the saved draft past the newest.
    fn history_down(&mut self) {
        let Some(entry) = self.history.down().map(str::to_string) else { return };
        self.set_line(&entry);
    }

    /// Swap the whole input for a recalled entry, keeping the menu and the
    /// history position in sync without tripping the "line changed" reset.
    fn set_line(&mut self, line: &str) {
        self.line = line.to_string();
        self.cursor = line.chars().count();
        self.menu_hidden = false;
        self.draw_edit();
        self.draw_menu();
    }

    fn take(&mut self) -> String {
        if let Some(hook) = self.on_edit.clone() {
            // The frame renderer owns the screen: no menu teardown or newline;
            // the submitted line becomes a transcript item and the editor row
            // is redrawn empty.
            self.restamp_prompt();
            let line = std::mem::take(&mut self.line);
            self.history.record(&line);
            self.history.edited();
            self.cursor = 0;
            self.drawn_rows = 0;
            self.drawn_cursor_row = 0;
            hook(&self.line, self.cursor, self.queue_count);
            return line;
        }
        if self.menu_visible() {
            let (seq, _) = menu_sequence(self.menu_rows, &[], self.status.is_some());
            write(&seq);
            self.menu_rows = 0;
        }
        self.menu_hidden = false;
        self.restamp_prompt();
        let line = std::mem::take(&mut self.line);
        self.history.record(&line);
        self.history.edited();
        self.cursor = 0;
        self.drawn_rows = 0;
        self.drawn_cursor_row = 0;
        match self.on_status() {
            Some(status) => self.show_on_status(status),
            None => {
                // The input may occupy several rows; the cursor can be on any
                // of them, so clear from here down before the newline.
                write("\x1b[J\r\n");
            }
        }
        line
    }
}

/// Terminal output that shows `lines` below the cursor's row (which holds
/// the prompt), given that `old_rows` rows are already in use there, and
/// the number of rows in use afterwards. The cursor ends where it started.
/// Rows are reserved with IND (ESC D), which scrolls at the bottom of the
/// scroll region and keeps the column; the status line below the region is
/// never touched. With `anchor` (a status line is pinned), rows the menu gives
/// up are closed by scrolling the conversation back down, so the prompt stays
/// directly above the status line.
fn menu_sequence(old_rows: usize, lines: &[String], anchor: bool) -> (String, usize) {
    if old_rows == 0 && lines.is_empty() {
        return (String::new(), 0);
    }
    let mut seq = String::new();
    if lines.len() > old_rows {
        seq.push_str(&"\x1bD".repeat(lines.len()));
        seq.push_str(&format!("\x1b[{}A", lines.len()));
    }
    let rows = old_rows.max(lines.len());
    seq.push_str("\x1b7");
    for i in 0..rows {
        seq.push_str("\x1b[1B\r\x1b[2K");
        if let Some(line) = lines.get(i) {
            seq.push_str(line);
        }
    }
    seq.push_str("\x1b8");
    if anchor && lines.len() < old_rows {
        // The released rows scrolled away, so only the drawn lines remain.
        seq.push_str(&crate::status::anchor_sequence((old_rows - lines.len()) as u16));
        return (seq, lines.len());
    }
    (seq, if lines.is_empty() { 0 } else { rows })
}

fn write(text: &str) {
    use std::io::Write;
    crate::status::with_term_lock(|| {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(text.as_bytes());
        let _ = out.flush();
    });
}

/// What a key press produced.
pub enum Key {
    Line(String),
    /// Ctrl- or Cmd-Enter during a turn: queue the line for a later turn
    /// (a plain Enter during a turn steers the running one).
    Queue(String),
    Eof,
    Interrupt,
    ToggleThinking,
    /// A lone Esc press (not part of an escape sequence).
    Escape,
    /// Shift+Tab: cycle the agent mode (normal/plan/auto).
    CycleMode,
}

/// How long to wait after Esc for the rest of an escape sequence. Terminals
/// send sequences in one write, so a lone Esc is one with nothing following.
const ESCAPE_SEQUENCE_WAIT_MS: i32 = 30;

static ORIGINAL: OnceLock<libc::termios> = OnceLock::new();

/// Whether a line reader is in key mode (no echo) and so will read — and
/// forward — a cursor position report the terminal sends back.
static KEY_MODE_ACTIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether key mode's terminal setup was ever applied. Cleanup control bytes
/// are only emitted when it was, so piped/non-TTY sessions (which never enter
/// key mode) keep clean, machine-readable stdout on exit.
static KEY_MODE_ENTERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn key_mode_active() -> bool {
    KEY_MODE_ACTIVE.load(std::sync::atomic::Ordering::SeqCst)
}

fn get_termios() -> Option<libc::termios> {
    let mut termios: libc::termios = unsafe { std::mem::zeroed() };
    (unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut termios) } == 0).then_some(termios)
}

/// Put the terminal back the way it was (on exit or panic).
pub fn restore_terminal() {
    if let Some(original) = ORIGINAL.get() {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
    }
    // Only undo the key-mode escapes if they were ever sent; a piped/non-TTY
    // session never entered key mode, so writing them would corrupt stdout.
    if KEY_MODE_ENTERED.load(std::sync::atomic::Ordering::SeqCst) {
        write("\x1b[?2004l\x1b[<u\x1b[>4;0m");
    }
}

/// Key-by-key input while alive: no echo, no line buffering, and control
/// keys (Ctrl-C, Ctrl-O, which macOS would use to discard output) delivered
/// as bytes. Output processing is left on. While active, the terminal is
/// asked for bracketed paste and modifyOtherKeys/kitty key reporting (so
/// Ctrl/Cmd-Enter is distinguishable from Enter). Mouse tracking is
/// deliberately not enabled, and any mouse-tracking modes left active by a
/// previously crashed TUI are cleared on entry, so the terminal keeps its
/// native wheel scrolling and text selection.
struct KeyMode;

impl KeyMode {
    fn enter() -> Option<Self> {
        let original = get_termios()?;
        let _ = ORIGINAL.set(original);
        let mut raw = *ORIGINAL.get().unwrap();
        raw.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN);
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        let entered = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } == 0;
        KEY_MODE_ACTIVE.store(entered, std::sync::atomic::Ordering::SeqCst);
        if entered {
            KEY_MODE_ENTERED.store(true, std::sync::atomic::Ordering::SeqCst);
            // Clear any mouse-tracking modes (normal/hilite/button/any-event
            // tracking and SGR extended reports) that a previously crashed TUI
            // may have left enabled, so wheel and drag events reach the
            // terminal's native scrollback/selection instead of being routed to
            // us as reports we would only discard. Then enable bracketed paste
            // and modifyOtherKeys/kitty key reporting.
            write("\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004h\x1b[>4;1m\x1b[>1u");
        }
        entered.then_some(Self)
    }
}

impl Drop for KeyMode {
    fn drop(&mut self) {
        KEY_MODE_ACTIVE.store(false, std::sync::atomic::Ordering::SeqCst);
        restore_terminal();
    }
}

/// What an escape sequence (arrow key, function key, modified key, mouse
/// press) means for the editor.
#[derive(Debug)]
enum Esc {
    Left,
    Right,
    /// Up/Down: recall an older/newer input from the history.
    HistoryUp,
    HistoryDown,
    Home,
    End,
    WordLeft,
    WordRight,
    Delete,
    /// Ctrl- or Cmd-Enter: queue the line during a turn; at the prompt,
    /// insert a newline instead of sending.
    Newline,
    /// An unmodified Enter reported as an escape sequence (kitty keyboard
    /// protocol `CSI 13 u`): submit the line, like a bare CR would.
    Submit,
    /// Something else (function keys, releases, motion, mouse events, unknown
    /// sequences).
    Ignored,
}

/// Reads keys, carrying bytes that arrived past the end of a line (pastes)
/// into the next read.
#[derive(Default)]
pub struct LineReader {
    pending: std::collections::VecDeque<u8>,
    utf8: Vec<u8>,
    /// While set, the reader yields stdin instead of consuming it, so a
    /// foreground picker (a `question`/turn-cap prompt) can own the terminal
    /// without racing this reader for keystrokes.
    suspend: Arc<std::sync::atomic::AtomicBool>,
}

/// How long the reader polls stdin (and re-checks `suspend`) per slice, so a
/// suspend request is observed within this many milliseconds.
const SUSPEND_POLL_MS: i32 = 15;

impl LineReader {
    /// A reader that yields stdin whenever `suspend` is set.
    pub fn with_suspend(suspend: Arc<std::sync::atomic::AtomicBool>) -> Self {
        Self { suspend, ..Self::default() }
    }

    /// The byte that begins the next key press. Blocks until one arrives, but
    /// while `suspend` is set it releases stdin (polling in short slices) so a
    /// foreground picker can read it instead. Returns `None` on EOF/error.
    fn first_byte(&mut self) -> Option<u8> {
        loop {
            // Honour suspension before draining any buffered bytes: while a
            // foreground picker owns the terminal, queued/pasted bytes in
            // `pending` must stay put (not be consumed as prompt/steering
            // input) so they cannot race dialoguer.
            if self.suspend.load(std::sync::atomic::Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(SUSPEND_POLL_MS as u64));
                continue;
            }
            if let Some(byte) = self.pending.pop_front() {
                return Some(byte);
            }
            let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
            let ready = unsafe { libc::poll(&mut fd, 1, SUSPEND_POLL_MS) };
            if ready < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return None;
            }
            if ready == 0 {
                continue; // timeout: re-check suspend, then poll again
            }
            // Re-check suspend after poll: a foreground picker may have set it
            // while we were parked in `poll`. If so, do not read — `next_byte`
            // would pull up to 1024 bytes off stdin (including the picker's
            // first keystrokes). Loop back so those bytes stay unread until the
            // picker has consumed them and suspension clears.
            if self.suspend.load(std::sync::atomic::Ordering::SeqCst) {
                continue;
            }
            return self.next_byte();
        }
    }
}

impl LineReader {
    fn next_byte(&mut self) -> Option<u8> {
        if let Some(byte) = self.pending.pop_front() {
            return Some(byte);
        }
        let mut buf = [0u8; 1024];
        loop {
            let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
            if n > 0 {
                self.pending.extend(&buf[..n as usize]);
                return self.pending.pop_front();
            }
            if n == 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return None;
            }
        }
    }

    /// The next byte if one arrives within `ms` milliseconds.
    fn byte_within(&mut self, ms: i32) -> Option<u8> {
        if self.pending.is_empty() {
            // Honour suspension in the escape-sequence path too: a real
            // sequence (arrow key, Shift+Tab) arrives atomically, so its
            // continuation is already buffered in `pending` and read below.
            // But if nothing is buffered and a foreground picker has taken the
            // terminal, the next bytes belong to the picker — do not poll or
            // read stdin for them. Report "no continuation" so the ESC we
            // already consumed resolves as a bare Escape and the picker keeps
            // its own keystrokes (including its `ESC [ Z`).
            if self.suspend.load(std::sync::atomic::Ordering::SeqCst) {
                return None;
            }
            let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
            if unsafe { libc::poll(&mut fd, 1, ms) } <= 0 {
                return None;
            }
        }
        self.next_byte()
    }

    /// Read one line. Ctrl-C, Ctrl-O and Esc go to `send` straight away; the
    /// return value is a `Key::Line` or `Key::Eof`.
    pub fn read_line(&mut self, view: &SharedView, send: &dyn Fn(Key)) -> Key {
        let _mode = KeyMode::enter();
        view.lock().unwrap().menu_enabled = true;
        let shared = view;
        loop {
            let Some(byte) = self.first_byte() else { return Key::Eof };
            let mut view = view.lock().unwrap();
            match byte {
                b'\r' | b'\n' => {
                    // Treat CR LF as one line end.
                    if byte == b'\r' && self.pending.front() == Some(&b'\n') {
                        self.pending.pop_front();
                    }
                    return Key::Line(view.take() + "\n");
                }
                0x01 => view.move_home(),
                0x03 => {
                    view.clear_line();
                    drop(view);
                    send(Key::Interrupt);
                }
                0x04 if view.line.is_empty() => return Key::Eof,
                0x05 => view.move_end(),
                0x0f => {
                    drop(view);
                    send(Key::ToggleThinking);
                }
                0x7f | 0x08 => view.backspace(),
                0x15 => view.clear_line(),
                0x17 => view.erase_word(),
                0x1b => {
                    let menu = view.menu_visible();
                    drop(view);
                    match self.byte_within(ESCAPE_SEQUENCE_WAIT_MS) {
                        Some(intro @ (b'[' | b'O')) => {
                            let mut seq = vec![0x1b, intro];
                            while let Some(b) = self.next_byte() {
                                seq.push(b);
                                if (0x40..=0x7e).contains(&b) {
                                    break;
                                }
                            }
                            // Legacy X10/normal mouse reports are ESC [ M then
                            // three raw coordinate bytes. The CSI reader stops
                            // at M, so consume those three bytes here to keep
                            // them from leaking into the input as text (mouse
                            // modes are cleared on entry, but a report buffered
                            // before then could still arrive).
                            if seq == [0x1b, b'[', b'M'] {
                                // A genuine report's three coordinate bytes
                                // arrive atomically with the prefix, so only
                                // consume them if they are already available.
                                // Use bounded (non-blocking) reads so a bare or
                                // partial `ESC [ M` typed/pasted as ordinary
                                // input cannot make the prompt block waiting for
                                // bytes that never come; push back anything we
                                // read that does not complete the report so it
                                // is processed as input rather than silently
                                // swallowed.
                                let mut coords = Vec::with_capacity(3);
                                for _ in 0..3 {
                                    match self.byte_within(0) {
                                        Some(b) => coords.push(b),
                                        None => break,
                                    }
                                }
                                if coords.len() < 3 {
                                    for b in coords.into_iter().rev() {
                                        self.pending.push_front(b);
                                    }
                                }
                            }
                            // Shift+Tab is ESC [ Z (backtab); everything else is
                            // skipped, with a cursor position report forwarded to
                            // the status line when it is waiting for one.
                            if seq == [0x1b, b'[', b'Z'] {
                                send(Key::CycleMode);
                            } else if let Some(row) = crate::status::cursor_report_row(&seq) {
                                crate::status::cursor_reported(row);
                            } else if seq == b"\x1b[200~" {
                                // Bracketed paste: keep line breaks instead
                                // of sending line by line.
                                let text = read_paste(self);
                                if !text.is_empty() {
                                    shared.lock().unwrap().insert(&text);
                                }
                            } else {
                                match parse_escape(&seq) {
                                    Esc::Left => shared.lock().unwrap().move_left(),
                                    Esc::Right => shared.lock().unwrap().move_right(),
                                    Esc::HistoryUp => shared.lock().unwrap().history_up(),
                                    Esc::HistoryDown => shared.lock().unwrap().history_down(),
                                    Esc::Home => shared.lock().unwrap().move_home(),
                                    Esc::End => shared.lock().unwrap().move_end(),
                                    Esc::WordLeft => shared.lock().unwrap().move_word_left(),
                                    Esc::WordRight => shared.lock().unwrap().move_word_right(),
                                    Esc::Delete => shared.lock().unwrap().delete(),
                                    Esc::Newline => {
                                        let mut view = shared.lock().unwrap();
                                        if view.mode == EditMode::Turn {
                                            return Key::Queue(view.take() + "\n");
                                        }
                                        view.insert("\n");
                                    }
                                    Esc::Submit => return Key::Line(shared.lock().unwrap().take() + "\n"),
                                    Esc::Ignored => {}
                                }
                            }
                        }
                        None if menu => shared.lock().unwrap().hide_menu(),
                        None => send(Key::Escape),
                        // Esc Esc typed faster than the wait: two presses.
                        Some(0x1b) => {
                            self.pending.push_front(0x1b);
                            send(Key::Escape);
                        }
                        // Alt-b / Alt-f: readline word jumps arrive as ESC b /
                        // ESC f, which never enter the CSI parser above.
                        Some(b'b') => shared.lock().unwrap().move_word_left(),
                        Some(b'f') => shared.lock().unwrap().move_word_right(),
                        // Alt+key: ignored.
                        Some(_) => {}
                    }
                }
                b'\t' => view.tab(),
                byte if byte < 0x20 => {}
                byte => {
                    self.utf8.push(byte);
                    match std::str::from_utf8(&self.utf8) {
                        Ok(text) => {
                            let text = text.to_string();
                            self.utf8.clear();
                            view.insert(&text);
                        }
                        Err(e) if e.error_len().is_some() => self.utf8.clear(),
                        Err(_) => {}
                    }
                }
            }
        }
    }
}

/// Interpret a complete escape sequence. `ESC [ ...` sequences are CSI;
/// `ESC O x` are SS3 (application cursor keys).
fn parse_escape(seq: &[u8]) -> Esc {
    match seq {
        // SS3 application cursor keys and Home/End.
        [0x1b, b'O', b'D'] => return Esc::Left,
        [0x1b, b'O', b'C'] => return Esc::Right,
        [0x1b, b'O', b'A'] => return Esc::HistoryUp,
        [0x1b, b'O', b'B'] => return Esc::HistoryDown,
        [0x1b, b'O', b'H'] => return Esc::Home,
        [0x1b, b'O', b'F'] => return Esc::End,
        // Alt-b / Alt-f (readline word jumps), sent as ESC b / ESC f.
        [0x1b, b'b'] => return Esc::WordLeft,
        [0x1b, b'f'] => return Esc::WordRight,
        _ => {}
    }
    let [0x1b, b'[', body @ .., final_byte] = seq else {
        return Esc::Ignored;
    };
    let body = std::str::from_utf8(body).unwrap_or("");
    // SGR mouse reports (CSI < … M/m). The mouse is no longer captured, so
    // any that still arrive (e.g. left over from another program) are ignored.
    if body.starts_with('<') {
        return Esc::Ignored;
    }
    // Bracketed paste markers are handled by the caller before this.
    match (*final_byte, body) {
        (b'D', "") => Esc::Left,
        (b'C', "") => Esc::Right,
        (b'A', "") => Esc::HistoryUp,
        (b'B', "") => Esc::HistoryDown,
        (b'H', "") => Esc::Home,
        (b'F', "") => Esc::End,
        (b'Z', "") => Esc::Ignored, // Shift-Tab
        (b'~', "3") => Esc::Delete,
        (b'~', "1" | "7") => Esc::Home,
        (b'~', "4" | "8") => Esc::End,
        // CSI 1 ; modifier {A,B,C,D,H,F} and CSI modifier {A,B,C,D,H,F}:
        // xterm modifier encoding is 1 + (shift=1, alt=2, ctrl=4).
        (dir @ (b'A' | b'B' | b'C' | b'D' | b'H' | b'F'), params) => {
            let encoded: u16 = params.rsplit(';').next().and_then(|m| m.parse().ok()).unwrap_or(1);
            let bits = encoded.saturating_sub(1);
            // Shift alone selects text in a GUI editor; here it is a plain
            // move (or history recall for Up/Down). Alt (bit 1) or Ctrl
            // (bit 2) jump by word on Left/Right.
            let word = bits & 0b110 != 0;
            match (dir, word) {
                (b'C', true) => Esc::WordRight,
                (b'D', true) => Esc::WordLeft,
                (b'C', false) => Esc::Right,
                (b'D', false) => Esc::Left,
                (b'A', _) => Esc::HistoryUp,
                (b'B', _) => Esc::HistoryDown,
                (b'H', _) => Esc::Home,
                (b'F', _) => Esc::End,
                _ => Esc::Ignored,
            }
        }
        // modifyOtherKeys / kitty: CSI 27 ; modifier ; 13 ~ is Enter with a
        // modifier. Ctrl (5) and Cmd/Super (9) insert a newline.
        (b'~', params) if params.starts_with("27;") => {
            let mut parts = params.split(';');
            let (_, modifier, key) = (parts.next(), parts.next(), parts.next());
            match (modifier.and_then(|m| m.parse::<u16>().ok()), key) {
                (Some(5 | 9), Some("13")) => Esc::Newline,
                _ => Esc::Ignored,
            }
        }
        // kitty keyboard protocol: CSI 13 ; modifier u.
        (b'u', params) => {
            let mut parts = params.split(';');
            match (parts.next().and_then(|k| k.parse::<u16>().ok()), parts.next().and_then(|m| m.parse::<u16>().ok())) {
                (Some(13), Some(m)) if m & 0b100 != 0 || m & 0b1000 != 0 => Esc::Newline,
                // Unmodified Enter (modifier absent or the bare `1`): legacy
                // mode would deliver a CR, so submit rather than ignore it.
                (Some(13), None | Some(1)) => Esc::Submit,
                _ => Esc::Ignored,
            }
        }
        _ => Esc::Ignored,
    }
}

/// Read a bracketed paste (`ESC [ 200 ~` already consumed) up to
/// `ESC [ 201 ~` and return its text with line endings normalized to `\n`.
fn read_paste(reader: &mut LineReader) -> String {
    const END: &[u8] = b"\x1b[201~";
    let mut bytes = Vec::new();
    while let Some(byte) = reader.next_byte() {
        bytes.push(byte);
        if bytes.ends_with(END) {
            bytes.truncate(bytes.len() - END.len());
            break;
        }
    }
    let text = String::from_utf8_lossy(&bytes);
    // CRLF and lone CR both become \n inside the input.
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push('\n');
            }
            '\n' => out.push('\n'),
            // Drop other control bytes (ESC, etc.) so pasted ANSI escapes
            // cannot execute terminal control sequences when the buffer is
            // later interpolated into prompt/status output.
            c if c.is_control() => {}
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A standalone view holding `line`, with no status line and drawing
    /// disabled (no terminal in tests).
    fn view(line: &str) -> EditView {
        let mut view = EditView {
            line: line.into(),
            cursor: line.chars().count(),
            mode: EditMode::Turn,
            status: None,
            menu_rows: 0,
            menu_hidden: false,
            menu_enabled: false,
            prompt_width: 2,
            queue_count: 0,
            context: Arc::new(Mutex::new(EditContext::default())),
            drawn_rows: 0,
            drawn_cursor_row: 0,
            on_edit: None,
            history: InputHistory::default(),
        };
        view.mode = EditMode::Turn;
        view
    }

    #[test]
    fn erase_word_handles_multibyte_spaces() {
        let mut view = view("run a\u{a0}bé  ");
        view.erase_word();
        assert_eq!(view.line, "run a\u{a0}");
        view.erase_word();
        assert_eq!(view.line, "run ");
    }

    #[test]
    fn menu_rows_are_reserved_drawn_and_cleared() {
        let lines = vec!["a".to_string(), "b".to_string()];
        let (seq, rows) = menu_sequence(0, &lines, false);
        assert_eq!(rows, 2);
        assert_eq!(seq, "\x1bD\x1bD\x1b[2A\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
        // Narrowing reuses the rows and blanks the extra one.
        let (seq, rows) = menu_sequence(2, &lines[..1], false);
        assert_eq!((seq.as_str(), rows), ("\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2K\x1b8", 2));
        let (seq, rows) = menu_sequence(2, &[], false);
        assert_eq!((seq.as_str(), rows), ("\x1b7\x1b[1B\r\x1b[2K\x1b[1B\r\x1b[2K\x1b8", 0));
        assert_eq!(menu_sequence(0, &[], false), (String::new(), 0));
    }

    #[test]
    fn anchored_menu_scrolls_released_rows_back_down() {
        let lines = vec!["a".to_string(), "b".to_string()];
        // Opening is the same as unanchored: rows are reserved with IND.
        assert_eq!(menu_sequence(0, &lines, true), menu_sequence(0, &lines, false));
        // Narrowing blanks the extra row, then scrolls the conversation down
        // one row into it so the prompt stays above the status line.
        let (seq, rows) = menu_sequence(2, &lines[..1], true);
        assert_eq!(rows, 1);
        assert!(seq.ends_with(&format!("\x1b8{}", crate::status::anchor_sequence(1))), "{seq:?}");
        // Closing scrolls down by every row the menu used.
        let (seq, rows) = menu_sequence(2, &[], true);
        assert_eq!(rows, 0);
        assert!(seq.ends_with(&crate::status::anchor_sequence(2)), "{seq:?}");
    }

    #[test]
    fn tab_completes_commands_and_is_a_space_elsewhere() {
        let mut v = view("/comp");
        v.tab();
        assert_eq!(v.line, "/compact ");
        let mut v = view("/s");
        v.tab();
        assert_eq!(v.line, "/s", "ambiguous: unchanged");
        let mut v = view("fix it");
        v.tab();
        assert_eq!(v.line, "fix it ");
    }

    #[test]
    fn inserts_and_deletes_at_the_cursor() {
        let mut view = view("helo");
        view.move_left();
        view.move_left();
        view.insert("l");
        assert_eq!(view.line, "hello");
        assert_eq!(view.cursor, 3);
        view.backspace();
        assert_eq!(view.line, "helo");
        assert_eq!(view.cursor, 2);
        view.delete();
        assert_eq!(view.line, "heo");
        view.move_home();
        view.insert(">> ");
        assert_eq!(view.line, ">> heo");
        view.move_end();
        view.insert("!");
        assert_eq!(view.line, ">> heo!");
    }

    #[test]
    fn movement_clamps_at_the_ends() {
        let mut view = view("ab");
        view.move_left();
        view.move_left();
        view.move_left();
        assert_eq!(view.cursor, 0);
        view.move_right();
        view.move_right();
        view.move_right();
        assert_eq!(view.cursor, 2);
    }

    #[test]
    fn word_jumps_skip_whitespace() {
        let mut view = view("foo bar  baz");
        view.move_word_left();
        assert_eq!(view.cursor, 9);
        view.move_word_left();
        assert_eq!(view.cursor, 4);
        view.move_word_left();
        assert_eq!(view.cursor, 0);
        view.move_word_right();
        assert_eq!(view.cursor, 4);
        view.move_word_right();
        assert_eq!(view.cursor, 9);
    }

    #[test]
    fn erase_word_from_the_middle_keeps_the_tail() {
        let mut view = view("foo bar baz");
        view.move_to(8); // after "foo bar "
        view.erase_word();
        assert_eq!(view.line, "foo baz");
        assert_eq!(view.cursor, 4);
    }

    #[test]
    fn newlines_make_multiple_rows() {
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("one\ntwo\nthree");
        assert_eq!(view.content_rows(80), 3);
        view.move_to(4); // on "two"
        assert_eq!(view.cursor_position(80), (1, 0));
        view.move_to(0);
        assert_eq!(view.cursor_position(80), (0, 2));
    }

    #[test]
    fn wraps_long_lines_onto_more_rows() {
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("abcdef");
        assert_eq!(view.content_rows(4), 2); // "> ab", "cdef": pending wrap after "f"
        assert_eq!(view.cursor_position(4), (1, 4), "the last char fills the row: pending wrap");
        view.move_to(2);
        assert_eq!(view.cursor_position(4), (0, 4), "pending wrap stays on the row");
    }

    #[test]
    fn parses_cursor_and_function_keys() {
        assert!(matches!(parse_escape(b"\x1b[D"), Esc::Left));
        assert!(matches!(parse_escape(b"\x1b[C"), Esc::Right));
        assert!(matches!(parse_escape(b"\x1b[H"), Esc::Home));
        assert!(matches!(parse_escape(b"\x1b[F"), Esc::End));
        assert!(matches!(parse_escape(b"\x1bOD"), Esc::Left));
        assert!(matches!(parse_escape(b"\x1bOC"), Esc::Right));
        assert!(matches!(parse_escape(b"\x1bOH"), Esc::Home));
        assert!(matches!(parse_escape(b"\x1bOF"), Esc::End));
        assert!(matches!(parse_escape(b"\x1b[3~"), Esc::Delete));
        assert!(matches!(parse_escape(b"\x1b[1~"), Esc::Home));
        assert!(matches!(parse_escape(b"\x1b[4~"), Esc::End));
        // Up/down recall input history.
        assert!(matches!(parse_escape(b"\x1b[A"), Esc::HistoryUp));
        assert!(matches!(parse_escape(b"\x1b[B"), Esc::HistoryDown));
        assert!(matches!(parse_escape(b"\x1bOA"), Esc::HistoryUp));
        assert!(matches!(parse_escape(b"\x1bOB"), Esc::HistoryDown));
        // Modified up/down (Ctrl/Shift/Alt) still recall history.
        assert!(matches!(parse_escape(b"\x1b[1;5A"), Esc::HistoryUp));
        assert!(matches!(parse_escape(b"\x1b[1;2B"), Esc::HistoryDown));
    }

    #[test]
    fn parses_modified_cursor_keys() {
        // Ctrl-Left / Ctrl-Right and Alt-Left / Alt-Right are word jumps.
        assert!(matches!(parse_escape(b"\x1b[1;5D"), Esc::WordLeft));
        assert!(matches!(parse_escape(b"\x1b[1;5C"), Esc::WordRight));
        assert!(matches!(parse_escape(b"\x1b[1;3D"), Esc::WordLeft));
        assert!(matches!(parse_escape(b"\x1b[1;3C"), Esc::WordRight));
        // Alt-b / Alt-f.
        assert!(matches!(parse_escape(b"\x1bb"), Esc::WordLeft));
        assert!(matches!(parse_escape(b"\x1bf"), Esc::WordRight));
        // Shift+arrows and Ctrl+Shift+arrows are not word jumps.
        assert!(matches!(parse_escape(b"\x1b[1;2D"), Esc::Left));
        assert!(matches!(parse_escape(b"\x1b[1;6D"), Esc::WordLeft));
    }

    #[test]
    fn parses_ctrl_and_cmd_enter_as_a_newline() {
        // modifyOtherKeys: ESC [ 27 ; modifier ; 13 ~
        assert!(matches!(parse_escape(b"\x1b[27;5;13~"), Esc::Newline), "Ctrl-Enter");
        assert!(matches!(parse_escape(b"\x1b[27;9;13~"), Esc::Newline), "Cmd-Enter");
        assert!(matches!(parse_escape(b"\x1b[27;2;13~"), Esc::Ignored), "Shift-Enter is left alone");
        // kitty keyboard protocol: CSI 13 ; modifier u
        assert!(matches!(parse_escape(b"\x1b[13;5u"), Esc::Newline), "kitty Ctrl-Enter");
        assert!(matches!(parse_escape(b"\x1b[13;9u"), Esc::Newline), "kitty Cmd-Enter");
        // Unmodified kitty Enter submits rather than being ignored.
        assert!(matches!(parse_escape(b"\x1b[13u"), Esc::Submit), "kitty Enter (no modifier) submits");
        assert!(matches!(parse_escape(b"\x1b[13;1u"), Esc::Submit), "kitty Enter (modifier 1) submits");
    }

    #[test]
    fn ignores_sgr_mouse_reports() {
        // The mouse is no longer captured; any SGR mouse report that still
        // arrives (press, release or wheel) is parsed and safely ignored.
        assert!(matches!(parse_escape(b"\x1b[<0;10;5M"), Esc::Ignored));
        assert!(matches!(parse_escape(b"\x1b[<0;10;5m"), Esc::Ignored));
        assert!(matches!(parse_escape(b"\x1b[<64;10;5M"), Esc::Ignored));
        assert!(matches!(parse_escape(b"\x1b[<65;10;5M"), Esc::Ignored));
    }

    #[test]
    fn paste_normalizes_line_endings() {
        // CRLF, lone CR and LF all become \n.
        let mut reader = LineReader::default();
        reader.pending.extend(b"one\r\ntwo\rthree\nfour\x1b[201~".iter());
        assert_eq!(read_paste(&mut reader), "one\ntwo\nthree\nfour");
    }

    #[test]
    fn up_down_recalls_submitted_lines_and_the_draft() {
        let mut view = view("");
        view.line = "first".into();
        view.take();
        view.line = "second".into();
        view.take();
        // A draft in progress is saved by the first Up and restored by Down.
        view.insert("draft");
        view.history_up();
        assert_eq!(view.line, "second");
        assert_eq!(view.cursor, view.line.chars().count(), "cursor at the end");
        view.history_up();
        assert_eq!(view.line, "first");
        view.history_up();
        assert_eq!(view.line, "first", "at the oldest: unchanged");
        view.history_down();
        assert_eq!(view.line, "second");
        view.history_down();
        assert_eq!(view.line, "draft");
        view.history_down();
        assert_eq!(view.line, "draft", "not browsing: unchanged");
    }

    #[test]
    fn editing_a_recalled_line_restarts_browsing_from_the_newest() {
        let mut view = view("");
        view.line = "first".into();
        view.take();
        view.line = "second".into();
        view.take();
        view.history_up();
        assert_eq!(view.line, "second");
        view.insert("!");
        view.history_up();
        assert_eq!(view.line, "second", "the edit reset browsing to the newest");
        // Down from the newest entry restores the edited line: like readline,
        // editing a recalled entry makes it the draft Down returns to.
        view.history_down();
        assert_eq!(view.line, "second!");
    }

    #[test]
    fn take_skips_repeats_but_history_up_still_works() {
        let mut view = view("");
        view.line = "same".into();
        view.take();
        view.line = "same".into();
        view.take();
        view.history_up();
        assert_eq!(view.line, "same");
        view.history_up();
        assert_eq!(view.line, "same", "one entry only: still the oldest");
    }

    #[test]
    fn frame_mode_submission_records_history() {
        // With an edit hook installed (renderer = "frame"), `take` returns from
        // the hook branch — but it must still record and reset history so
        // Up/Down recall works in that render path too.
        let mut view = view("");
        view.set_edit_hook(Arc::new(|_, _, _| {}));
        view.line = "first".into();
        view.take();
        view.line = "second".into();
        view.take();
        view.history_up();
        assert_eq!(view.line, "second");
        view.history_up();
        assert_eq!(view.line, "first");
    }

    #[test]
    fn take_returns_the_multiline_input() {
        let mut view = view("one\ntwo");
        assert_eq!(view.take(), "one\ntwo");
        assert!(view.line.is_empty());
        assert_eq!(view.cursor, 0);
    }

    #[test]
    fn tab_completes_model_arguments_from_context() {
        let context = Arc::new(Mutex::new(EditContext {
            config: toml::from_str(r#"model = "openai/gpt-4o""#).unwrap(),
            recents: crate::recents::SharedRecents::default(),
        }));
        context.lock().unwrap().recents.lock().unwrap().record("ollama/qwen3:8b");
        let view = EditView::shared(None, context);
        let mut view = view.lock().unwrap();
        view.mode = EditMode::Turn;
        view.line = "/model ol".into();
        view.tab();
        assert_eq!(view.line, "/model ollama", "common prefix first");
        view.tab();
        assert_eq!(view.line, "/model ollama/qwen3:8b", "then descend to the recent spec");
        view.line = "/mode a".into();
        view.tab();
        assert_eq!(view.line, "/mode auto");
        view.line = "/model zz".into();
        view.tab();
        assert_eq!(view.line, "/model zz", "no match: unchanged");
        view.line = "/model  ol".into();
        view.tab();
        assert_eq!(view.line, "/model ollama", "irregular spacing canonicalizes without panicking");
    }

    /// Read one key from `bytes` with the editor in `mode`.
    fn read_key(mode: EditMode, bytes: &[u8]) -> Key {
        let view = EditView::shared(None, Arc::new(Mutex::new(EditContext::default())));
        view.lock().unwrap().mode = mode;
        let mut reader = LineReader::default();
        reader.pending.extend(bytes.iter());
        reader.read_line(&view, &|_| {})
    }

    #[test]
    fn enter_steers_and_ctrl_enter_queues_during_a_turn() {
        assert!(matches!(read_key(EditMode::Turn, b"go left\r"), Key::Line(l) if l == "go left\n"));
        // modifyOtherKeys and kitty Ctrl-Enter, and Cmd-Enter.
        for seq in [&b"\x1b[27;5;13~"[..], b"\x1b[13;5u", b"\x1b[27;9;13~"] {
            let bytes = [&b"later"[..], seq].concat();
            assert!(matches!(read_key(EditMode::Turn, &bytes), Key::Queue(l) if l == "later\n"), "{seq:?}");
        }
    }

    /// A minimal terminal: printing with auto-wrap (pending wrap at the last
    /// column) and scrolling at the bottom, CR, LF, and the CSI moves and
    /// erases `redraw_sequence` emits.
    struct Term {
        grid: Vec<Vec<char>>,
        row: usize,
        col: usize,
        pending: bool,
    }

    impl Term {
        fn new(rows: usize, cols: usize) -> Self {
            Term { grid: vec![vec![' '; cols]; rows], row: rows - 1, col: 0, pending: false }
        }
        fn scroll(&mut self) {
            let cols = self.grid[0].len();
            self.grid.remove(0);
            self.grid.push(vec![' '; cols]);
        }
        fn newline(&mut self) {
            if self.row + 1 == self.grid.len() {
                self.scroll();
            } else {
                self.row += 1;
            }
        }
        fn feed(&mut self, seq: &str) {
            let cols = self.grid[0].len();
            let mut chars = seq.chars().peekable();
            while let Some(c) = chars.next() {
                match c {
                    '\x1b' => {
                        assert_eq!(chars.next(), Some('['), "only CSI expected in {seq:?}");
                        let mut n = String::new();
                        while let Some(d) = chars.next_if(|d| d.is_ascii_digit()) {
                            n.push(d);
                        }
                        let n: usize = n.parse().unwrap_or(1);
                        self.pending = false;
                        match chars.next().unwrap() {
                            'A' => self.row = self.row.saturating_sub(n),
                            'B' => self.row = (self.row + n).min(self.grid.len() - 1),
                            'C' => self.col = (self.col + n).min(cols - 1),
                            'K' => self.grid[self.row] = vec![' '; cols],
                            'm' => {}
                            other => panic!("unexpected CSI {other}"),
                        }
                    }
                    '\r' => {
                        self.col = 0;
                        self.pending = false;
                    }
                    '\n' => {
                        // OPOST/ONLCR: a newline is CRLF.
                        self.col = 0;
                        self.pending = false;
                        self.newline();
                    }
                    _ => {
                        if self.pending {
                            self.col = 0;
                            self.pending = false;
                            self.newline();
                        }
                        self.grid[self.row][self.col] = c;
                        if self.col + 1 == cols {
                            self.pending = true;
                        } else {
                            self.col += 1;
                        }
                    }
                }
            }
        }
        fn lines(&self) -> Vec<String> {
            self.grid.iter().map(|r| r.iter().collect::<String>().trim_end().to_string()).collect()
        }
    }

    #[test]
    fn redraw_that_scrolls_keeps_the_prompt_in_place() {
        // A 10-wide, 4-row screen with the prompt on the bottom row. Editing
        // at the start of the line while the input wraps scrolls the screen on
        // each growth; the input must be reprinted over itself, not stacked.
        let (cols, rows) = (10, 4);
        let mut term = Term::new(rows, cols);
        let mut v = view("");
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        for c in "xxxxxxx".chars() {
            v.line.push(c);
            v.cursor += 1;
            term.feed(&v.redraw_sequence(cols, ""));
        }
        v.cursor = 0;
        term.feed(&v.redraw_sequence(cols, ""));
        for c in "abcdefghijklm".chars() {
            v.line.insert(v.byte_of(v.cursor), c);
            v.cursor += 1;
            term.feed(&v.redraw_sequence(cols, ""));
            // Exactly one prompt on screen, and the cursor where the model says.
            let prompts = term.lines().iter().filter(|l| l.starts_with("> ")).count();
            assert_eq!(prompts, 1, "stacked copies after {c:?}: {:#?}", term.lines());
            let (row, col) = v.cursor_position(cols);
            let content = v.content_rows(cols);
            assert_eq!(term.row, rows - content + row, "cursor row after {c:?}");
            assert_eq!(term.col, col.min(cols - 1), "cursor column after {c:?}");
        }
        assert_eq!(term.lines()[1..], ["> abcdefgh", "ijklmxxxxx", "xx"]);
    }

    #[test]
    fn redraw_leaves_rows_below_the_input_alone() {
        // No erase-below: the status line under the input must survive.
        let mut v = view("hello");
        v.mode = EditMode::Prompt;
        let seq = v.redraw_sequence(80, "");
        assert!(!seq.contains("\x1b[J"), "{seq:?}");
        assert!(!seq.contains("\x1b7") && !seq.contains("\x1b8"), "{seq:?}");
    }
}
