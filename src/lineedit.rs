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
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::status::StatusLine;

/// Advance a wrap position by one input grapheme cluster, measured in terminal
/// cells.
///
/// `col` is the column the next cell would be written to (`0..=cols`, where
/// `cols` is a pending wrap left by a row filled exactly). Terminals lay glyphs
/// out by *cluster*, not by scalar: a base letter and its combining marks
/// render in one place, and a ZWJ/emoji sequence renders as one glyph — so the
/// cluster must advance atomically or a trailing combining mark straddling the
/// right edge would spuriously start a new row and an emoji sequence would be
/// split across the boundary. CJK ideographs and most emoji occupy two cells
/// and never straddle the right edge — when the remaining cells cannot hold the
/// cluster the terminal leaves them blank and wraps the glyph whole — while a
/// lone combining mark occupies zero cells and stays on the preceding glyph. A
/// `'\n'` cluster starts a fresh row.
fn advance_cluster(row: usize, col: usize, cols: usize, cluster: &str) -> (usize, usize) {
    if cluster == "\n" {
        return (row + 1, 0);
    }
    let (mut row, mut col) = (row, col);
    let w = UnicodeWidthStr::width(cluster);
    // A zero-width cluster (a lone combining mark) attaches to the cell already
    // written and neither advances the column nor flushes a pending wrap.
    if w == 0 {
        return (row, col);
    }
    // A row filled exactly is a pending wrap: the next cell starts a new row.
    if col >= cols {
        row += 1;
        col = 0;
    }
    // A cluster that cannot fit in the cells left on this row is wrapped whole;
    // the terminal leaves the trailing cells blank rather than splitting it.
    if w > 1 && col + w > cols {
        row += 1;
        col = 0;
    }
    col += w;
    (row, col)
}

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
/// queued, menu)` on every editor change instead of the editor writing escape
/// sequences itself. `queued` is the number of messages waiting behind the
/// current turn, shown as an indicator under the editor; `menu` is the command
/// type-ahead rows to draw under the editor (empty when there is none).
pub type EditHook = Arc<dyn Fn(&str, usize, usize, &[String]) + Send + Sync>;

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
    /// calls the hook instead of writing escape sequences. The inline command
    /// menu (which writes directly) is disabled; the menu rows are handed to
    /// the hook instead, for the frame renderer to draw under the editor.
    pub fn set_edit_hook(&mut self, hook: EditHook) {
        self.on_edit = Some(hook);
        self.menu_enabled = false;
    }

    /// Match the editor's drawing path to the renderer: `true` routes every
    /// change through the frame hook (and disables the inline command menu,
    /// which the frame draws instead); `false` restores the inline editor and
    /// its menu. Used when a live `renderer` switch in `/settings` flips the
    /// app-owned frame renderer on or off.
    pub fn set_frame_mode(&mut self, on: bool, hook: Option<EditHook>) {
        self.on_edit = on.then(|| hook.expect("a hook is required when enabling frame mode"));
        // Only re-enable the inline editor/menu (which writes cursor/erase
        // sequences straight to stdout) when both stdin and stdout are real
        // terminals, matching `Terminal::start`'s `key_mode`. Off a tty the
        // frame is never active, so a configured-renderer switch calls this
        // with `on == false`; without this guard it would turn inline drawing
        // on and the following `resize()` would spew escape sequences into
        // redirected output.
        use std::io::IsTerminal;
        self.menu_enabled = !on && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    }

    /// Forget where the last inline redraw left the prompt: the frame renderer
    /// owned the screen and leaves the cursor on the bottom row, so the
    /// recorded prompt span / cursor offset no longer match anything on
    /// screen. Reset to "one prompt row, cursor on it" (the state the main
    /// loop's next prompt print establishes) so the first inline redraw after
    /// a frame → legacy switch clears and climbs within that row instead of
    /// walking up into the status line or leftover frame content.
    pub fn reset_drawing(&mut self) {
        self.menu_rows = 0;
        self.drawn_rows = 1;
        self.drawn_cursor_row = 0;
    }

    /// Redraw the editor: through the frame hook when set, else inline / on the
    /// status line as before.
    fn draw_edit(&mut self) {
        if let Some(hook) = self.on_edit.clone() {
            let menu = self.frame_menu();
            // Track the frame menu's height so `menu_visible()` reflects the menu
            // the frame path actually draws. `read_line` uses `menu_visible()` to
            // decide whether a bare Esc hides the menu or is emitted as
            // `Key::Escape`; without this the frame menu never reported visible
            // and Esc could not close it.
            self.menu_rows = menu.len();
            hook(&self.line, self.cursor, self.queue_count, &menu);
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
        self.mutated();
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

    /// Redraw after a text mutation. The legacy path needs both renders:
    /// `draw_edit` reprints the input row and `line_changed` -> `draw_menu`
    /// draws the menu below it. The frame path composes the whole frame
    /// (input + menu) in a single hook call, so a leading `draw_edit` here
    /// would only recompose and re-emit the entire transcript an extra time
    /// per keystroke (and, after an Esc, render the hidden then reopened menu
    /// as two frames). `line_changed` already resets `menu_hidden` before the
    /// frame draw, so routing frame-mode mutations through it alone yields a
    /// single, correct O(history) render.
    fn mutated(&mut self) {
        if self.on_edit.is_none() {
            self.draw_edit();
        }
        self.line_changed();
    }

    fn menu_visible(&self) -> bool {
        self.menu_rows > 0
    }

    /// The command menu rows for the current line: argument type-ahead past
    /// the command name, else the matching commands (empty for non-`/` lines
    /// or when hidden with Esc).
    fn menu_lines(&self, cols: usize, max_rows: usize) -> Vec<String> {
        if self.menu_hidden {
            Vec::new()
        } else if crate::commands::has_argument_menu(&self.line) {
            // Past the command name: argument type-ahead for the commands
            // with a known argument set (`/model`, `/mode`, `/verbosity`).
            let context = self.context.lock().unwrap();
            let recents = context.recents.lock().unwrap().models().to_vec();
            let found = crate::commands::suggestions(&context.config, &recents, &self.line);
            crate::commands::suggestion_menu(&found, &self.line, cols, max_rows)
        } else {
            crate::commands::menu(&self.line, cols, max_rows)
        }
    }

    /// The menu rows for the frame renderer: shown at the prompt only (as the
    /// inline menu is), sized so editor + menu + status bar fit the terminal.
    fn frame_menu(&self) -> Vec<String> {
        if self.mode != EditMode::Prompt {
            return Vec::new();
        }
        let (rows, cols) = crate::status::terminal_size().unwrap_or((24, 80));
        let cols = (cols as usize).max(1);
        // Size the menu against the frame editor's *real* rendered height, not
        // the legacy `content_rows`: in frame mode `prompt_width` stays at 2
        // (the legacy `prompt()` is never called) and `content_rows` omits the
        // frame-only queue-indicator row and the reserved cursor cell. Measuring
        // with `frame::editor_lines` (the same helper the frame renderer draws
        // with) and reserving the queue row keeps `editor + queue + menu +
        // status` within the terminal, so a narrow or exactly-full input can no
        // longer make an oversized menu push the prompt off-screen.
        let prompt = format!("{}› ", crate::ui::stamp());
        let editor = crate::frame::editor_lines(&prompt, &self.line, self.cursor, cols).len();
        let queue = (self.queue_count > 0) as usize;
        let max_rows = menu_max_rows(rows as usize, editor + queue, true);
        self.menu_lines(cols, max_rows)
    }

    /// Redraw the command menu below the prompt for the current line.
    fn draw_menu(&mut self) {
        if self.on_edit.is_some() {
            // The frame renderer draws the menu as part of the frame.
            self.draw_edit();
            return;
        }
        if !self.menu_enabled || self.mode != EditMode::Prompt {
            return;
        }
        let (rows, cols) = crate::status::terminal_size().unwrap_or((24, 80));
        // The input may wrap across several rows and the menu is drawn below
        // that whole rendered height, so reserve the *full* content height —
        // plus the status row when one is pinned — not just a single prompt
        // row. Capping the menu to the rows that remain keeps
        // `content + menu (+ status)` within the terminal, so
        // `menu_sequence`'s IND descent never scrolls the prompt (or an
        // earlier edit row) off the top and clamps the save/restore at row 1.
        // When no rows remain the menu is suppressed (`max_rows == 0` yields
        // no entries). For a single-row input this matches the old reserve
        // (`rows - 1`, or `rows - 2` with a status line).
        let content = self.content_rows(cols as usize);
        let max_rows = menu_max_rows(rows as usize, content, self.status.is_some());
        let lines = self.menu_lines(cols as usize, max_rows);
        // The edit cursor was left on its row by the preceding redraw
        // (`drawn_cursor_row`); the input's rendered end row is its last content
        // row. Draw the menu below that end row, not below an earlier edit row,
        // so a wrapped command edited on an earlier row does not have its tail
        // rows painted over by the menu.
        let below = content.saturating_sub(1).saturating_sub(self.drawn_cursor_row);
        // `self.menu_rows` is the *old* menu height. When wrapping grows
        // `content`, `max_rows` can drop below it, so passing the stale larger
        // count would make `menu_sequence` clear `max(old_rows, lines.len())`
        // rows that no longer fit below the taller content: the extra
        // cursor-down clamps at the bottom margin and erases the last freshly
        // drawn entry (e.g. a 5-row terminal with a status line, content 1→2
        // and menu 3→2, leaves only one entry). Cap the reusable old height to
        // the rows that still fit below the new content.
        let old_rows = self.menu_rows.min(max_rows);
        let (seq, used) = menu_sequence(old_rows, &lines, self.status.is_some(), below);
        // Recompute `drawn_rows` (content + menu) from the *current* content
        // height plus the freshly measured menu, rather than adjusting the old
        // total by a `used - menu_rows` delta. The delta is only correct while
        // the `drawn_rows == content + menu_rows` invariant holds, but `resize`
        // zeroes `menu_rows` before calling here while `drawn_rows` still
        // carries the old menu height — so a delta would stack the new menu on
        // top of the stale one (e.g. a resize with a three-row menu recording
        // six), and the next `redraw_sequence` would climb past the real prompt
        // and overwrite transcript rows. Measuring content directly keeps
        // `drawn_rows` honest in every path (line change and resize alike).
        self.drawn_rows = content + used;
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
            None if self.line.contains(char::is_whitespace) && !crate::commands::has_argument_menu(&self.line) => {
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
        for cluster in self.line.graphemes(true) {
            let (r, cc) = advance_cluster(row, col, cols, cluster);
            row = r;
            col = cc;
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
        if w > 0 && w.is_multiple_of(cols) { (w / cols - 1, cols) } else { (w / cols, w % cols) }
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
        let mut seen = 0;
        for cluster in self.line.graphemes(true) {
            if seen >= idx {
                break;
            }
            let len = cluster.chars().count();
            if seen + len <= idx {
                // The whole cluster lies before the cursor: advance it atomically.
                let (r, cc) = advance_cluster(row, col, cols, cluster);
                row = r;
                col = cc;
                seen += len;
            } else {
                // The char-indexed cursor lands inside this cluster (e.g. between
                // a base glyph and its combining mark, or between the scalars of
                // a ZWJ sequence). The terminal renders the whole cluster as one
                // unit on its start row, so an interior index owns no cell of its
                // own; advancing its scalars independently (each as a cell) could
                // wrap the cursor onto a later row than the cluster actually
                // occupies, leaving `cursor_row` below `end_row` so the next
                // redraw climbs above the prompt. Rest at the cluster's start
                // boundary — the rendered position the cursor genuinely shares —
                // rather than descending into it.
                break;
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
        let drawn = content + self.menu_rows;
        // A shorter input (Backspace/Ctrl-U on a wrapped line) uses fewer rows
        // than the last redraw. Blanking the released rows above only leaves
        // them empty, so with a pinned status line the prompt would sit above a
        // blank gap. Collapse those rows the way `menu_sequence` does — scroll
        // the conversation back down so the prompt stays directly above the
        // status line, preserving the bottom-anchor invariant. The anchor saves
        // and restores the cursor and moves it down with the content, so the
        // edit cursor stays on its character.
        if self.status.is_some() && old > drawn {
            seq.push_str(&crate::status::anchor_sequence((old - drawn) as u16));
        }
        self.drawn_rows = drawn;
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
        if self.on_edit.is_some() {
            // The frame renderer redraws every row (menu included) at the new
            // width itself.
            self.draw_edit();
            return;
        }
        let cols = crate::status::terminal_size().map(|(_, c)| c as usize).unwrap_or(80).max(1);
        // With a status line, its resize erased everything below the cursor
        // (the menu included) and re-anchored the prompt, so only redraw needs
        // to run. Without one, blank the old menu rows explicitly. The menu was
        // drawn below the input's END row — which, when a wrapped line is edited
        // on an earlier row, sits `below` rows past the cursor — so the teardown
        // must descend that far first. Passing `below = 0` would instead clear
        // the rows immediately under the cursor (the input tail), leaving the
        // real menu rows stale when the resized menu is shorter or gone. Compute
        // the cursor-to-end distance at the NEW width, matching the reflow the
        // rest of this function assumes and the same descent `draw_menu` uses to
        // place the menu.
        if self.menu_rows > 0 && self.status.is_none() {
            let cursor_row = self.cursor_position(cols).0;
            let below = self.content_rows(cols).saturating_sub(1).saturating_sub(cursor_row);
            let (seq, _) = menu_sequence(self.menu_rows, &[], false, below);
            write(&seq);
        }
        self.menu_rows = 0;
        // Reflow moved the input's rows. `redraw` opens by climbing
        // `drawn_cursor_row` rows from the real cursor to the prompt row, but
        // that value was recorded at the OLD width — after the reflow the
        // cursor sits a different number of rows below the prompt, so retaining
        // it (or resetting it to 0 unconditionally) makes the climb start from
        // the wrong row and reprint over the transcript. Recompute the cursor's
        // prompt-relative row at the NEW width first, so the climb matches where
        // the cursor actually is.
        self.drawn_cursor_row = self.cursor_position(cols).0;
        // `drawn_rows` still carries the OLD-width span (content + menu). With a
        // status line, `StatusLine::resize` just anchored the edit cursor at the
        // bottom margin and erased/scrolled away everything below it, so only
        // the prompt-through-cursor rows survive; without one the input merely
        // reflowed to its new-width height. `redraw` opens by clearing that many
        // rows: walking down clamps at the bottom margin, but the matching climb
        // up is unconditional, so a stale (too-tall) span lands the cursor above
        // the prompt and reprints over the transcript. Reset it to the actual
        // post-resize span first.
        self.drawn_rows = if self.status.is_some() { self.drawn_cursor_row + 1 } else { self.content_rows(cols) };
        // Reprint the input FIRST, while the menu is still released: `redraw`
        // clears only the content rows and places the real cursor on the edit
        // character at the new width, recording that row in `drawn_cursor_row`.
        // Drawing the menu before this redraw would fold the menu rows into
        // `drawn_rows`, so the redraw would erase them again and the menu would
        // vanish on every resize. Input first, then the menu, keeps both honest.
        self.redraw();
        // The input is reprinted and the cursor placed; now refill the menu
        // under it, sized to the new terminal.
        self.draw_menu();
    }

    /// Remove the character before the cursor (Backspace).
    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor -= 1;
        let at = self.byte_of(self.cursor);
        self.line.remove(at);
        self.mutated();
    }

    /// Remove the character under the cursor (Delete).
    fn delete(&mut self) {
        if self.cursor >= self.line.chars().count() {
            return;
        }
        let at = self.byte_of(self.cursor);
        self.line.remove(at);
        self.mutated();
    }

    /// Remove the word before the cursor, plus any whitespace separating it
    /// from the cursor.
    fn erase_word(&mut self) {
        let before: String = self.line.chars().take(self.cursor).collect();
        let trimmed = before.trim_end();
        let word_start =
            trimmed.char_indices().rev().find(|(_, c)| c.is_whitespace()).map(|(i, c)| i + c.len_utf8()).unwrap_or(0);
        let start = before[..word_start].chars().count();
        let from = self.byte_of(start);
        let to = self.byte_of(self.cursor);
        self.line.replace_range(from..to, "");
        self.cursor = start;
        self.mutated();
    }

    /// Clear the whole input (Ctrl-U).
    fn clear_line(&mut self) {
        if self.line.is_empty() {
            return;
        }
        self.line.clear();
        self.cursor = 0;
        self.mutated();
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
        // Like `mutated`: the legacy path needs both renders (`draw_edit`
        // reprints the input row, `draw_menu` draws the menu below it), but the
        // frame path composes input + menu in a single hook call. A leading
        // `draw_edit` here would recompose and re-emit the whole transcript an
        // extra time per history recall, so route frame mode through
        // `draw_menu` alone for a single O(history) render.
        if self.on_edit.is_none() {
            self.draw_edit();
        }
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
            self.menu_hidden = false;
            self.menu_rows = 0;
            hook(&self.line, self.cursor, self.queue_count, &[]);
            return line;
        }
        if self.menu_visible() {
            let (seq, _) = menu_sequence(self.menu_rows, &[], self.status.is_some(), 0);
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

/// The number of command-menu rows that fit below a `content`-row input on a
/// `rows`-high terminal, leaving the status row (`has_status`) intact and never
/// exceeding the menu's own 16-row cap. Reserving the *full* rendered content
/// height — not just a single prompt row — keeps `content + menu (+ status)`
/// within the terminal, so `menu_sequence`'s IND descent never scrolls the
/// input (or the prompt) off the top and clamps the cursor save/restore at the
/// top row. Zero means no room remains, which suppresses the menu. For a
/// single-row input this matches the historical reserve (`rows - 1`, or
/// `rows - 2` with a status line).
fn menu_max_rows(rows: usize, content: usize, has_status: bool) -> usize {
    rows.saturating_sub(content).saturating_sub(has_status as usize).min(16)
}

/// Terminal output that shows `lines` below the cursor's row (which holds
/// the prompt), given that `old_rows` rows are already in use there, and
/// the number of rows in use afterwards. The cursor ends where it started.
/// Rows are reserved with IND (ESC D), which scrolls at the bottom of the
/// scroll region and keeps the column; the status line below the region is
/// never touched. With `anchor` (a status line is pinned), rows the menu gives
/// up are closed by scrolling the conversation back down, so the prompt stays
/// directly above the status line.
fn menu_sequence(old_rows: usize, lines: &[String], anchor: bool, below: usize) -> (String, usize) {
    if old_rows == 0 && lines.is_empty() {
        return (String::new(), 0);
    }
    let mut seq = String::new();
    if !lines.is_empty() {
        // Ensure enough rows exist below the edit cursor for the descent to the
        // input's rendered end row (`below`) plus the menu. `\x1bD` scrolls only
        // at the bottom margin, so feeding this many is a no-op when the rows
        // already exist and scrolls exactly the shortfall when they don't. Run
        // it whenever a non-empty menu is drawn, not just when the menu itself
        // grew: the input can gain a wrapped row (raising `below`) while the
        // menu keeps the same entry count, and that new row must still be
        // reserved or the menu's tail entries overwrite each other.
        seq.push_str(&"\x1bD".repeat(below + lines.len()));
        seq.push_str(&format!("\x1b[{}A", below + lines.len()));
    }
    let rows = old_rows.max(lines.len());
    seq.push_str("\x1b7");
    // Descend from the edit cursor to the input's rendered end row before
    // drawing, so the menu lands below the whole (wrapped) input rather than
    // over its tail rows when the cursor is being edited on an earlier row.
    // The `\x1b8` at the end restores the cursor to the saved edit position.
    if below > 0 {
        seq.push_str(&format!("\x1b[{below}B"));
    }
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
    /// Esc reported as an escape sequence (kitty keyboard protocol
    /// `CSI 27 u`): handled like a lone Esc byte.
    Escape,
    /// Ctrl+letter reported as an escape sequence (kitty `CSI 99;5u`,
    /// modifyOtherKeys `CSI 27;5;99~`): the control byte legacy mode would
    /// have sent (here 0x03, Ctrl-C), to be handled as if it had been typed.
    Control(u8),
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
        {
            // The inline menu writes escape sequences (IND scrolls, cursor
            // save/restore) straight to the terminal. Under the frame renderer
            // (an edit hook is set) those writes scroll the frame behind its
            // back, leaving a stale copy of the editor row on every key press
            // of a `/` line — so only enable it for the inline renderer.
            let mut v = view.lock().unwrap();
            v.menu_enabled = v.on_edit.is_none();
        }
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
                                    Esc::Escape if menu => shared.lock().unwrap().hide_menu(),
                                    Esc::Escape => send(Key::Escape),
                                    // Re-read as the byte legacy mode sends,
                                    // so every control key keeps one handler.
                                    Esc::Control(byte) => self.pending.push_front(byte),
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
        // modifyOtherKeys: CSI 27 ; modifier ; key ~ is a key with a modifier
        // (e.g. Ctrl-Enter `27;5;13~`).
        (b'~', params) if params.starts_with("27;") => {
            let mut parts = params.split(';').skip(1);
            let modifier = parts.next().and_then(|m| m.parse().ok()).unwrap_or(1);
            match parts.next().and_then(|k| k.parse().ok()) {
                Some(key) => modified_key(key, modifier),
                None => Esc::Ignored,
            }
        }
        // kitty keyboard protocol: CSI key[:alternates] ; modifier[:event] u.
        // With "disambiguate escape codes" on, Esc and Ctrl/Alt+key arrive
        // this way instead of as the legacy bytes.
        (b'u', params) => {
            let mut parts = params.split(';');
            let key = parts.next().and_then(|k| k.split(':').next()?.parse().ok());
            let mut modifier = parts.next().unwrap_or("1").split(':');
            let bits = modifier.next().and_then(|m| m.parse().ok()).unwrap_or(1);
            // Event type 3 is a key release (only reported when asked for).
            if modifier.next() == Some("3") {
                return Esc::Ignored;
            }
            match key {
                Some(key) => modified_key(key, bits),
                None => Esc::Ignored,
            }
        }
        _ => Esc::Ignored,
    }
}

/// A key reported with its code and xterm modifier parameter (1 + shift=1,
/// alt=2, ctrl=4, super=8), as the legacy terminal input it stands for.
fn modified_key(key: u32, modifier: u16) -> Esc {
    const SHIFT: u16 = 1;
    const ALT: u16 = 2;
    const CTRL: u16 = 4;
    const SUPER: u16 = 8;
    // Kitty reports Caps Lock (64) and Num Lock (128) as always-present state
    // bits, not held modifiers; mask them off so they don't defeat the exact
    // modifier comparisons below.
    const CAPS_LOCK: u16 = 64;
    const NUM_LOCK: u16 = 128;
    let bits = modifier.saturating_sub(1) & !(CAPS_LOCK | NUM_LOCK);
    match key {
        // Ctrl- or Cmd-Enter: newline (queue during a turn). Unmodified Enter
        // submits, as the CR legacy mode sends would.
        13 if bits & (CTRL | SUPER) != 0 => Esc::Newline,
        13 if bits == 0 => Esc::Submit,
        27 if bits & !SHIFT == 0 => Esc::Escape,
        // Ctrl+letter (Shift ignored, as legacy terminals do): its control
        // byte, e.g. Ctrl-C → 0x03. Accept both ASCII letter cases: Shift is
        // ignored, but modifyOtherKeys reports the shifted character code, so
        // Ctrl+Shift+W arrives as uppercase `W` (`CSI 27;6;87~`). `key & 0x1f`
        // yields the same control byte for either case.
        0x41..=0x5a | 0x61..=0x7a if bits & !SHIFT == CTRL => Esc::Control((key & 0x1f) as u8),
        // Alt-b / Alt-f: readline word jumps.
        0x62 if bits == ALT => Esc::WordLeft,
        0x66 if bits == ALT => Esc::WordRight,
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
    fn reset_drawing_restores_the_single_prompt_row_baseline() {
        // After the frame renderer owned the screen, the editor's drawn state
        // refers to rows it no longer controls: a stale span would make the
        // first inline redraw climb into the status line or leftover frame
        // content. The reset restores the "one prompt row, cursor on it"
        // baseline the next prompt print establishes.
        let mut view = view("/settings");
        view.menu_rows = 3;
        view.drawn_rows = 5;
        view.drawn_cursor_row = 2;
        view.reset_drawing();
        assert_eq!(view.menu_rows, 0);
        assert_eq!(view.drawn_rows, 1);
        assert_eq!(view.drawn_cursor_row, 0);
    }

    #[test]
    fn frame_menu_marks_menu_visible_so_esc_can_hide_it() {
        // In frame mode the editor is drawn through the hook, not inline, so the
        // menu height must still be recorded in `menu_rows`: `read_line` gates a
        // bare Esc on `menu_visible()`, and without this a `/` line's frame menu
        // could never be closed with Esc.
        let mut view = view("/");
        view.mode = EditMode::Prompt;
        view.on_edit = Some(Arc::new(|_: &str, _: usize, _: usize, _: &[String]| {}));
        view.draw_edit();
        assert!(view.menu_visible(), "a `/` line's frame menu reports visible");
        view.hide_menu();
        assert!(!view.menu_visible(), "Esc-hiding the frame menu clears visibility");
    }

    #[test]
    fn frame_mutation_invokes_the_draw_hook_once() {
        // In frame mode a text mutation must recompose the frame exactly once:
        // the hook clones the whole transcript, so the old `draw_edit()` +
        // `line_changed()` pair (two O(history) renders per keystroke) was
        // wasteful, and after an Esc it even drew the hidden then reopened menu
        // as separate frames. `mutated()` routes frame-mode changes through a
        // single hook invocation.
        let calls = Arc::new(Mutex::new(0usize));
        let mut view = view("");
        view.mode = EditMode::Prompt;
        view.menu_enabled = true;
        let counter = calls.clone();
        view.on_edit = Some(Arc::new(move |_: &str, _: usize, _: usize, _: &[String]| {
            *counter.lock().unwrap() += 1;
        }));

        *calls.lock().unwrap() = 0;
        view.insert("/");
        assert_eq!(*calls.lock().unwrap(), 1, "insert renders the frame once");

        *calls.lock().unwrap() = 0;
        view.backspace();
        assert_eq!(*calls.lock().unwrap(), 1, "backspace renders the frame once");

        // After Esc hides the menu, the next mutation reopens it in a single
        // render rather than drawing the hidden then reopened menu separately.
        view.insert("/");
        view.hide_menu();
        *calls.lock().unwrap() = 0;
        view.insert("h");
        assert_eq!(*calls.lock().unwrap(), 1, "post-Esc mutation renders once");
        assert!(view.menu_visible(), "the mutation reopened the menu");
    }

    #[test]
    fn frame_history_recall_invokes_the_draw_hook_once() {
        // History recall (Up/Down -> `set_line`) must recompose the frame
        // exactly once. Like a text mutation, the hook clones the whole
        // transcript, so the old `draw_edit()` + `draw_menu()` pair performed
        // two O(history) renders per recall. Frame mode now routes through the
        // single hook invocation in `draw_menu`.
        let calls = Arc::new(Mutex::new(0usize));
        let mut view = view("");
        view.mode = EditMode::Prompt;
        view.menu_enabled = true;
        let counter = calls.clone();
        view.on_edit = Some(Arc::new(move |_: &str, _: usize, _: usize, _: &[String]| {
            *counter.lock().unwrap() += 1;
        }));

        *calls.lock().unwrap() = 0;
        view.set_line("/model gpt");
        assert_eq!(*calls.lock().unwrap(), 1, "history recall renders the frame once");
    }

    #[test]
    fn menu_rows_are_reserved_drawn_and_cleared() {
        let lines = vec!["a".to_string(), "b".to_string()];
        let (seq, rows) = menu_sequence(0, &lines, false, 0);
        assert_eq!(rows, 2);
        assert_eq!(seq, "\x1bD\x1bD\x1b[2A\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
        // Narrowing reuses the rows and blanks the extra one. The reservation
        // descent still runs (a no-op here since the rows already exist).
        let (seq, rows) = menu_sequence(2, &lines[..1], false, 0);
        assert_eq!((seq.as_str(), rows), ("\x1bD\x1b[1A\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2K\x1b8", 2));
        let (seq, rows) = menu_sequence(2, &[], false, 0);
        assert_eq!((seq.as_str(), rows), ("\x1b7\x1b[1B\r\x1b[2K\x1b[1B\r\x1b[2K\x1b8", 0));
        assert_eq!(menu_sequence(0, &[], false, 0), (String::new(), 0));
    }

    #[test]
    fn menu_is_drawn_below_the_input_end_row_not_the_edit_row() {
        // A wrapped command edited on an earlier row leaves the cursor `below`
        // rows above the input's rendered end row. The menu must descend to the
        // end row before painting so it lands beneath the whole input, not over
        // its tail rows, and must return the cursor to the edit position.
        let lines = vec!["a".to_string(), "b".to_string()];
        let (seq, rows) = menu_sequence(0, &lines, false, 2);
        assert_eq!(rows, 2);
        // Reserve descent+menu rows, then descend two rows to the end row before
        // drawing each menu row, restoring the edit cursor at the end.
        assert_eq!(seq, "\x1bD\x1bD\x1bD\x1bD\x1b[4A\x1b7\x1b[2B\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
        // Reusing already-reserved rows needs no scroll, but the reservation
        // descent still runs (a no-op) and it still descends to the end row.
        let (seq, rows) = menu_sequence(2, &lines[..1], false, 2);
        assert_eq!(
            (seq.as_str(), rows),
            ("\x1bD\x1bD\x1bD\x1b[3A\x1b7\x1b[2B\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2K\x1b8", 2)
        );
    }

    #[test]
    fn menu_reservation_reruns_when_the_input_grows_but_the_menu_does_not() {
        // Regression: the reservation descent used to run only when the menu
        // grew (`lines.len() > old_rows`). When the input instead gained a
        // wrapped row (raising `below`) while the menu kept the same entry
        // count, no rows were reserved for the new content row, so the trailing
        // `\x1b[1B` descent clamped at the bottom margin and the menu's tail
        // entries overwrote each other. Copilot's example: a one-row input with
        // a two-row menu growing to two input rows left only the second menu row
        // visible. The reservation must run for any non-empty menu, scrolling
        // the one-row shortfall.
        let lines = vec!["a".to_string(), "b".to_string()];
        let (seq, rows) = menu_sequence(2, &lines, false, 1);
        assert_eq!(rows, 2);
        assert_eq!(seq, "\x1bD\x1bD\x1bD\x1b[3A\x1b7\x1b[1B\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
    }

    #[test]
    fn stale_menu_height_is_capped_to_the_rows_that_still_fit() {
        // Regression: `draw_menu` passed the *old* `menu_rows` to
        // `menu_sequence`. When wrapping grew the content, `max_rows` dropped
        // below the old menu height, but the stale larger count made
        // `menu_sequence` clear `max(old_rows, lines.len())` rows that no longer
        // fit below the taller content: the extra cursor-down clamped at the
        // bottom margin and erased the last freshly drawn entry.
        //
        // Copilot's example: a five-row terminal with a status line, content
        // 1→2 and menu 3→2, must leave both new entries — not one. `draw_menu`
        // now caps the reusable old height to `max_rows` (the rows that still
        // fit below the new content) before calling `menu_sequence`.
        let lines = vec!["a".to_string(), "b".to_string()];
        let max_rows = menu_max_rows(5, 2, true);
        assert_eq!(max_rows, 2);
        let old_menu_rows = 3;
        // Uncapped, the stale count clears three rows: the third `\x1b[2K`
        // clamps at the bottom margin and erases the last drawn entry.
        let (stale_seq, _) = menu_sequence(old_menu_rows, &lines, true, 1);
        assert_eq!(stale_seq.matches("\x1b[2K").count(), 3);
        // Capped to the rows that still fit, exactly the two entries are drawn
        // — no over-clear, no spurious anchor scroll-back.
        let capped = old_menu_rows.min(max_rows);
        assert_eq!(capped, 2);
        let (seq, rows) = menu_sequence(capped, &lines, true, 1);
        assert_eq!(rows, 2);
        assert_eq!(seq.matches("\x1b[2K").count(), 2);
        assert_eq!(seq, "\x1bD\x1bD\x1bD\x1b[3A\x1b7\x1b[1B\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
    }

    #[test]
    fn menu_height_reserves_the_full_wrapped_content_height() {
        // Regression: `max_rows` reserved only one prompt row, so a wrapped
        // input plus a tall menu could exceed the scroll region. Drawing it then
        // fed IND scrolls that pushed the edit row (and prompt) off the top, and
        // the matching cursor-up clamped at row 1 — saving/restoring the wrong
        // position. The reserve must count the whole rendered content height.
        //
        // Copilot's example: a five-row terminal with a status line and a
        // three-row input must leave at most one menu row (5 - 3 - 1), never
        // three, so `content + menu + status` stays within the terminal.
        assert_eq!(menu_max_rows(5, 3, true), 1);
        // Without a status line one more row is free.
        assert_eq!(menu_max_rows(5, 3, false), 2);
        // When the content already fills the usable rows the menu is suppressed.
        assert_eq!(menu_max_rows(4, 3, true), 0);
        assert_eq!(menu_max_rows(3, 3, false), 0);
        // A single-row input matches the historical reserve (`rows - 1`, or
        // `rows - 2` with a status line), capped at the menu's own 16 rows.
        assert_eq!(menu_max_rows(24, 1, false), 16);
        assert_eq!(menu_max_rows(10, 1, false), 9);
        assert_eq!(menu_max_rows(10, 1, true), 8);
    }

    #[test]
    fn anchored_menu_scrolls_released_rows_back_down() {
        let lines = vec!["a".to_string(), "b".to_string()];
        // Opening is the same as unanchored: rows are reserved with IND.
        assert_eq!(menu_sequence(0, &lines, true, 0), menu_sequence(0, &lines, false, 0));
        // Narrowing blanks the extra row, then scrolls the conversation down
        // one row into it so the prompt stays above the status line.
        let (seq, rows) = menu_sequence(2, &lines[..1], true, 0);
        assert_eq!(rows, 1);
        assert!(seq.ends_with(&format!("\x1b8{}", crate::status::anchor_sequence(1))), "{seq:?}");
        // Closing scrolls down by every row the menu used.
        let (seq, rows) = menu_sequence(2, &[], true, 0);
        assert_eq!(rows, 0);
        assert!(seq.ends_with(&crate::status::anchor_sequence(2)), "{seq:?}");
    }

    #[test]
    fn draw_menu_recomputes_drawn_rows_and_ignores_stale_menu_height() {
        // `resize()` zeroes `menu_rows` before calling `draw_menu` while
        // `drawn_rows` still carries the old menu height. A delta update would
        // add the new menu on top of that stale total; `draw_menu` must instead
        // recompute from the real content height so `drawn_rows` collapses back
        // to `content + menu`.
        let mut v = view("");
        v.menu_enabled = true;
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        // The resize state: menu released to 0 but drawn_rows still stale-large.
        v.menu_rows = 0;
        v.drawn_rows = 6;
        v.draw_menu();
        // An empty line has no command menu, so the new menu is 0 rows and the
        // one-row prompt is the entire content: drawn_rows must be 1, not the
        // stale 6 (delta) nor 6-plus-anything.
        assert_eq!(v.menu_rows, 0);
        assert_eq!(v.drawn_rows, 1, "recomputed from content height, not the stale delta");
    }

    #[test]
    fn draw_menu_keeps_the_menu_rows_it_reserves() {
        // Regression for "resize removes the open command menu": `resize` used
        // to draw the menu and then `redraw`, whose clear of all `drawn_rows`
        // (menu included) erased the menu it had just drawn. Now `resize`
        // redraws the input first and only then draws the menu, so the menu
        // rows stay reserved and visible. Lock the invariant in at the
        // `draw_menu` level: after it runs, `drawn_rows` covers the menu.
        let mut v = view("/");
        v.menu_enabled = true;
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        // As at the end of `resize`'s input-first pass: menu released, only the
        // one-row prompt counted.
        v.menu_rows = 0;
        v.drawn_rows = 1;
        v.draw_menu();
        let content = v.content_rows(80);
        assert!(v.menu_rows > 0, "a bare `/` opens the command menu");
        assert_eq!(v.drawn_rows, content + v.menu_rows, "drawn_rows must keep the freshly drawn menu, not erase it");
    }

    #[test]
    fn redraw_records_the_edit_cursor_row_for_the_next_climb() {
        // Regression for "resize resets the cursor row without moving the
        // cursor": `resize` no longer zeroes `drawn_cursor_row`; it lets the
        // input-first `redraw` record where the edit cursor genuinely rests at
        // the new width, so the next redraw climbs the right amount. A wrapped
        // line with the cursor at its end sits on the last content row.
        let mut v = view("aaaaaaaa"); // 8 chars after "> ": wraps to 3 rows at 4 cols.
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        v.cursor = v.line.chars().count();
        let _ = v.redraw_sequence(4, "");
        assert_eq!(v.drawn_rows, 3, "three content rows at 4 cols");
        assert_eq!(v.drawn_cursor_row, 2, "cursor rests on the last wrapped row, recomputed — not reset to 0");
    }

    #[test]
    fn resize_recomputes_the_cursor_row_at_the_new_width_before_climbing() {
        // Regression for "resize redraws retain a cursor-row offset calculated
        // for the old terminal width": `redraw` opens by climbing
        // `drawn_cursor_row` rows from the real cursor to the prompt. That value
        // was recorded at the OLD width; after a reflow the cursor sits a
        // different number of rows below the prompt, so `resize` must recompute
        // it at the NEW width first. Model the offending case: a line that sat
        // on the prompt row at a wide terminal (drawn_cursor_row == 0) narrows
        // so it now wraps and the cursor rests on the last row.
        let mut v = view("aaaaaaaa"); // 8 chars after "> ": one row at 40 cols, 3 rows at 4.
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        v.cursor = v.line.chars().count();
        // As left by the last redraw at the old wide width: cursor on row 0.
        v.drawn_cursor_row = 0;
        v.drawn_rows = 1;
        assert_eq!(v.cursor_position(40).0, 0, "at 40 cols the cursor sits on the prompt row",);
        // The recompute `resize` performs before `redraw` at the new width.
        let new_cols = 4;
        v.drawn_cursor_row = v.cursor_position(new_cols).0;
        assert_eq!(v.drawn_cursor_row, 2, "at 4 cols the cursor is two rows down");
        let seq = v.redraw_sequence(new_cols, "");
        assert!(
            seq.starts_with("\x1b[2A"),
            "redraw must climb from the recomputed cursor row (2), not the stale 0; got {seq:?}",
        );
    }

    #[test]
    fn resize_resets_drawn_rows_to_the_post_resize_span_before_redraw() {
        // Regression for "resize leaves drawn_rows at the old-width span": a
        // status-anchored `StatusLine::resize` anchors the edit cursor at the
        // bottom margin and erases everything below it, so only the
        // prompt-through-cursor rows survive. If `drawn_rows` still holds the old
        // (taller) content+menu span, `redraw`'s clear loop walks down that many
        // rows — clamping at the bottom margin — but climbs the full span back
        // up, landing above the prompt and reprinting over the transcript. So
        // `resize` resets `drawn_rows` to the surviving span (through the cursor
        // when status-anchored) first. Model a wrapped input whose cursor sits
        // before the end, with a stale tall span left from the old width.
        let mut v = view("aaaaaaaa"); // 3 rows at 4 cols.
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        v.status = Some(Arc::new(crate::status::StatusLine::for_test()));
        v.drawn_rows = 6; // stale old-width span (content + a menu).
        let new_cols = 4;
        v.cursor = 4; // mid-input: the edit cursor rests before the last row.
        v.drawn_cursor_row = v.cursor_position(new_cols).0;
        assert!(
            v.drawn_cursor_row < v.content_rows(new_cols) - 1,
            "the cursor must sit before the input's end row for this case",
        );
        // The reset `resize` performs before `redraw`: through the cursor.
        v.drawn_rows = v.drawn_cursor_row + 1;
        let span = v.drawn_rows;
        assert!(span < 6, "the reset span must be shorter than the stale count");
        let seq = v.redraw_sequence(new_cols, "");
        assert_eq!(
            seq.matches("\x1b[2K").count(),
            span,
            "clear loop must blank exactly the post-resize span, not the stale 6; got {seq:?}",
        );
        if span > 1 {
            assert!(
                seq.contains(&format!("\x1b[{}A", span - 1)),
                "the up-climb must match the rows walked down so the cursor never rises above the prompt; got {seq:?}",
            );
        }
    }

    #[test]
    fn resize_menu_teardown_descends_to_the_input_end_before_clearing() {
        // Regression for "no-status resize teardown erases input-tail rows, not
        // the menu": without a status line `resize` blanks the old menu rows
        // itself via `menu_sequence(menu_rows, &[], false, below)`. The menu
        // sits below the input's END row, so when a wrapped line is edited on an
        // earlier row the teardown must descend `below` rows (cursor-to-end)
        // first. A `below` of 0 would clear the rows just under the cursor — the
        // input tail — leaving the real menu rows stale when the resized menu is
        // shorter or gone. Model a wrapped input with the cursor before its end.
        let mut v = view("aaaaaaaa"); // 3 rows at 4 cols.
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        let cols = 4;
        v.cursor = 4; // mid-input: the edit cursor rests before the last row.
        let cursor_row = v.cursor_position(cols).0;
        let end_row = v.content_rows(cols) - 1;
        assert!(cursor_row < end_row, "the cursor must sit before the input's end row");
        // The distance `resize` now computes for the teardown.
        let below = v.content_rows(cols).saturating_sub(1).saturating_sub(cursor_row);
        assert_eq!(below, end_row - cursor_row, "below is the cursor-to-end distance");
        assert!(below > 0, "a mid-input cursor leaves rows between it and the menu");
        // The teardown descends `below` rows before clearing the two menu rows,
        // so it blanks the menu — not the input-tail rows immediately below the
        // cursor — leaving no stale menu rows behind.
        let menu_rows = 2;
        let (seq, used) = menu_sequence(menu_rows, &[], false, below);
        assert_eq!(used, 0, "the teardown draws no menu");
        assert!(
            seq.contains(&format!("\x1b7\x1b[{below}B")),
            "teardown must descend to the input end before clearing; got {seq:?}",
        );
        assert_eq!(
            seq.matches("\x1b[2K").count(),
            menu_rows,
            "teardown clears exactly the menu rows below the input end; got {seq:?}",
        );
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
    fn wide_glyphs_wrap_by_terminal_cells_not_scalar_count() {
        // Each CJK ideograph occupies two terminal cells, so three of them fill
        // a six-cell content span. On a cols=8 terminal the prompt takes 2 cells
        // ("> "), leaving 6 for the input: the three fill row 0 exactly (pending
        // wrap) and a fourth wraps onto row 1.
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("一二三");
        assert_eq!(view.content_rows(8), 1, "three double-width glyphs fill one 6-cell row");
        assert_eq!(view.cursor_position(8), (0, 8), "row filled exactly: pending wrap at cols");
        view.insert("四");
        assert_eq!(view.content_rows(8), 2, "the fourth wide glyph wraps to a new row");
        assert_eq!(view.cursor_position(8), (1, 2));
    }

    #[test]
    fn wide_glyph_wraps_whole_off_a_lone_trailing_cell() {
        // cols=5 leaves 3 content cells after "> ". One wide glyph takes cols 2-3,
        // leaving a single free cell; the next wide glyph cannot fit there, so the
        // terminal wraps it whole rather than splitting it across the boundary.
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("一二");
        assert_eq!(view.content_rows(5), 2);
        assert_eq!(view.cursor_position(5), (1, 2), "second wide glyph wrapped whole to row 1");
    }

    #[test]
    fn combining_marks_take_no_cells() {
        // A base letter plus a combining acute renders in one cell, so it must
        // not advance the wrap column past its base.
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("e\u{0301}");
        assert_eq!(view.cursor_position(80), (0, 3), "combining mark adds no column");
        assert_eq!(view.content_rows(80), 1);
    }

    #[test]
    fn combining_mark_stays_with_a_base_that_fills_the_last_column() {
        // "> " plus a 2-cell content span on cols=4. "ab" fills the span exactly
        // (pending wrap at col 4), and the combining acute belongs to the base
        // "b" already written in the last cell — it must not take the pending-wrap
        // branch and spill onto a new row. The cluster "b\u{0301}" stays whole.
        let mut view = view("");
        view.prompt_width = 2;
        view.insert("ab\u{0301}");
        assert_eq!(view.content_rows(4), 1, "combining mark stays on the base's row");
        assert_eq!(view.cursor_position(4), (0, 4), "pending wrap, cursor at cols");
    }

    #[test]
    fn zwj_emoji_cluster_wraps_whole_not_scalar_by_scalar() {
        // A ZWJ family emoji is one grapheme cluster. Counted per scalar it would
        // measure six cells (three people at two each) and split across a row
        // boundary; measured as a cluster it is two cells and moves as a unit.
        let mut view = view("");
        view.prompt_width = 0;
        view.insert("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}");
        assert_eq!(view.content_rows(8), 1, "the family emoji is one two-cell glyph");
        assert_eq!(view.cursor_position(8), (0, 2), "two cells, not six");
        // With only one free cell before it on a cols=4 row, the whole cluster
        // wraps rather than splitting its people across the boundary.
        view.replace_line("abc\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}");
        assert_eq!(view.content_rows(4), 2, "the emoji cluster wraps whole to row 1");
        assert_eq!(view.cursor_position(4), (1, 2), "cluster placed atomically on row 1");
    }

    #[test]
    fn cursor_inside_a_cluster_rests_on_the_cluster_start_row() {
        // A char cursor can land between the scalars of a ZWJ family emoji
        // (movement steps by scalar). Measured per scalar the interior index
        // would count six cells and spill onto a second row on a narrow
        // terminal, even though the cluster renders as one two-cell glyph on a
        // single row. `position_at` must snap the interior index to the
        // cluster's rendered start boundary, never a phantom later row, or
        // `redraw_sequence` climbs above the prompt.
        let mut view = view("");
        view.prompt_width = 0;
        view.insert("abc\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"); // wraps whole to row 1 at cols=4
        // Cursor between the man and the first ZWJ: index 4 (a,b,c,man).
        view.cursor = 4;
        assert_eq!(
            view.cursor_position(4),
            (0, 3),
            "interior index rests before the cluster (row 0), not a scalar-counted later row"
        );
        // Past the whole cluster: the end boundary, advanced atomically.
        view.cursor = view.line.chars().count();
        assert_eq!(view.cursor_position(4), (1, 2), "past the cluster: its end boundary on row 1");
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
    fn parses_kitty_and_modify_other_keys_control_keys() {
        // kitty "disambiguate escape codes" reports Esc and Ctrl/Alt+key as CSI u.
        assert!(matches!(parse_escape(b"\x1b[27u"), Esc::Escape), "Esc");
        assert!(matches!(parse_escape(b"\x1b[27;1u"), Esc::Escape), "Esc, explicit no modifier");
        assert!(matches!(parse_escape(b"\x1b[99;5u"), Esc::Control(0x03)), "Ctrl-C");
        assert!(matches!(parse_escape(b"\x1b[99;6u"), Esc::Control(0x03)), "Ctrl-Shift-C");
        assert!(matches!(parse_escape(b"\x1b[111;5u"), Esc::Control(0x0f)), "Ctrl-O");
        assert!(matches!(parse_escape(b"\x1b[97;5u"), Esc::Control(0x01)), "Ctrl-A");
        assert!(matches!(parse_escape(b"\x1b[100;5u"), Esc::Control(0x04)), "Ctrl-D");
        assert!(matches!(parse_escape(b"\x1b[99;5:1u"), Esc::Control(0x03)), "press event");
        assert!(matches!(parse_escape(b"\x1b[99;5:3u"), Esc::Ignored), "release is ignored");
        assert!(matches!(parse_escape(b"\x1b[99:67;5u"), Esc::Control(0x03)), "alternate key codes");
        assert!(matches!(parse_escape(b"\x1b[98;3u"), Esc::WordLeft), "Alt-b");
        assert!(matches!(parse_escape(b"\x1b[102;3u"), Esc::WordRight), "Alt-f");
        assert!(matches!(parse_escape(b"\x1b[99;7u"), Esc::Ignored), "Ctrl-Alt-C is not Ctrl-C");
        assert!(matches!(parse_escape(b"\x1b[99;9u"), Esc::Ignored), "Cmd-C is the terminal's copy");
        // modifyOtherKeys: CSI 27 ; modifier ; key ~
        assert!(matches!(parse_escape(b"\x1b[27;5;99~"), Esc::Control(0x03)), "modifyOtherKeys Ctrl-C");
        // modifyOtherKeys reports the shifted (uppercase) code for Ctrl+Shift+letter.
        assert!(matches!(parse_escape(b"\x1b[27;6;87~"), Esc::Control(0x17)), "modifyOtherKeys Ctrl+Shift+W");
        assert!(matches!(parse_escape(b"\x1b[87;6u"), Esc::Control(0x17)), "kitty Ctrl+Shift+W");
    }

    /// Keys `read_line` sends while reading `bytes`, then its result.
    fn keys_sent(view: &SharedView, bytes: &[u8]) -> Vec<String> {
        let sent = Mutex::new(Vec::new());
        let mut reader = LineReader::default();
        reader.pending.extend(bytes.iter());
        let key = reader.read_line(view, &|key| sent.lock().unwrap().push(key_name(&key)));
        let mut sent = sent.into_inner().unwrap();
        sent.push(format!("-> {}", key_name(&key)));
        sent
    }

    fn key_name(key: &Key) -> String {
        match key {
            Key::Line(line) => format!("line {line:?}"),
            Key::Queue(line) => format!("queue {line:?}"),
            Key::Eof => "eof".into(),
            Key::Interrupt => "interrupt".into(),
            Key::ToggleThinking => "toggle-thinking".into(),
            Key::Escape => "escape".into(),
            Key::CycleMode => "cycle-mode".into(),
        }
    }

    #[test]
    fn kitty_encoded_control_keys_act_like_legacy_bytes() {
        let context = Arc::new(Mutex::new(EditContext::default()));
        let frame = EditView::shared(None, context.clone());
        frame.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
        let legacy = EditView::shared(None, context);
        for view in [&frame, &legacy] {
            view.lock().unwrap().mode = EditMode::Turn;
            // Ctrl-C clears the line and interrupts; Esc and Ctrl-O are sent.
            assert_eq!(
                keys_sent(view, b"abc\x1b[99;5u\x1b[27u\x1b[111;5uok\r"),
                ["interrupt", "escape", "toggle-thinking", "-> line \"ok\\n\""]
            );
            // Ctrl-D on an empty line is end of input, as the legacy byte is.
            assert_eq!(keys_sent(view, b"\x1b[100;5u"), ["-> eof"]);
            // Ctrl-A / Ctrl-U / Ctrl-W edit the line.
            assert_eq!(keys_sent(view, b"one two\x1b[119;5u\x1b[97;5uX\r"), ["-> line \"Xone \\n\""]);
        }
        // At the prompt with the command menu open, Esc closes the menu first.
        frame.lock().unwrap().mode = EditMode::Prompt;
        assert_eq!(keys_sent(&frame, b"/he\x1b[27u\x1b[27u\x1b[117;5u\r"), ["escape", "-> line \"\\n\""]);
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
    fn kitty_lock_state_bits_are_ignored() {
        // Kitty adds Caps Lock (64) and Num Lock (128) as always-present state
        // bits in the modifier field; they must not defeat the modifier
        // comparisons. modifier = 1 + bits, so Caps Lock alone is 65, Num Lock
        // alone is 129, and both together are 193.
        assert!(matches!(parse_escape(b"\x1b[27;65u"), Esc::Escape), "Esc with Caps Lock");
        assert!(matches!(parse_escape(b"\x1b[27;129u"), Esc::Escape), "Esc with Num Lock");
        assert!(matches!(parse_escape(b"\x1b[13;65u"), Esc::Submit), "Enter with Caps Lock submits");
        assert!(matches!(parse_escape(b"\x1b[13;193u"), Esc::Submit), "Enter with both locks submits");
        // Ctrl-C is modifier 5 (1 + ctrl=4); with Caps Lock it is 69, with both
        // locks 197. Held Ctrl must still be honoured.
        assert!(matches!(parse_escape(b"\x1b[99;69u"), Esc::Control(0x03)), "Ctrl-C with Caps Lock");
        assert!(matches!(parse_escape(b"\x1b[99;197u"), Esc::Control(0x03)), "Ctrl-C with both locks");
        // Ctrl-Enter is modifier 5; with Caps Lock 69 it stays a newline.
        assert!(matches!(parse_escape(b"\x1b[13;69u"), Esc::Newline), "Ctrl-Enter with Caps Lock");
        // Alt-b is modifier 3 (1 + alt=2); with Num Lock it is 131.
        assert!(matches!(parse_escape(b"\x1b[98;131u"), Esc::WordLeft), "Alt-b with Num Lock");
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
        view.set_edit_hook(Arc::new(|_, _, _, _| {}));
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

    #[test]
    fn shrinking_wrapped_input_collapses_released_rows_under_the_status_line() {
        // With a pinned status line, a wrapped input that becomes shorter frees
        // rows above the status line. Blanking them alone leaves the prompt
        // above a gap, so the redraw must scroll the conversation back down with
        // the anchor helper (as `menu_sequence` does), keeping the prompt
        // directly above the status line.
        let mut v = view("aaaaaaaa"); // 8 chars after "> ": wraps to 3 rows at 4 cols.
        v.mode = EditMode::Prompt;
        v.status = Some(Arc::new(crate::status::StatusLine::for_test()));
        v.prompt_width = 2;
        v.cursor = v.line.chars().count();
        // First redraw records the 3-row draw.
        let _ = v.redraw_sequence(4, "");
        assert_eq!(v.drawn_rows, 3);
        // Delete back to a single row (Ctrl-U to one char): "a" fits one row.
        v.line = "a".into();
        v.cursor = 1;
        let seq = v.redraw_sequence(4, "");
        assert_eq!(v.drawn_rows, 1, "one content row now");
        // Two rows were released, so the conversation scrolls down two rows.
        assert!(seq.ends_with(&crate::status::anchor_sequence(2)), "{seq:?}");
    }

    #[test]
    fn shrinking_input_without_a_status_line_does_not_anchor() {
        // No status line: there is no bottom-anchor invariant, so a shorter
        // input must not emit the anchor scroll (which would corrupt output).
        let mut v = view("aaaaaaaa");
        v.mode = EditMode::Prompt;
        v.prompt_width = 2;
        v.cursor = v.line.chars().count();
        let _ = v.redraw_sequence(4, "");
        v.line = "a".into();
        v.cursor = 1;
        let seq = v.redraw_sequence(4, "");
        assert!(!seq.contains("\x1b7") && !seq.contains("\x1b8"), "{seq:?}");
    }

    /// A VT emulator with a scroll region above a pinned status row, DECSC/
    /// DECRC, IND and IL: enough for `redraw_sequence` + `menu_sequence`.
    struct Vt {
        grid: Vec<Vec<char>>,
        row: usize,
        col: usize,
        bottom: usize,
        saved: (usize, usize),
    }

    impl Vt {
        fn new(rows: usize, cols: usize, status: bool) -> Self {
            let mut grid = vec![vec![' '; cols]; rows];
            let bottom = if status { rows - 2 } else { rows - 1 };
            if status {
                grid[rows - 1] = "STATUS".chars().chain(std::iter::repeat(' ')).take(cols).collect();
            }
            Vt { grid, row: bottom, col: 0, bottom, saved: (0, 0) }
        }
        fn index(&mut self) {
            if self.row == self.bottom {
                let cols = self.grid[0].len();
                self.grid.remove(0);
                self.grid.insert(self.bottom, vec![' '; cols]);
            } else {
                self.row += 1;
            }
        }
        fn feed(&mut self, seq: &str) {
            let cols = self.grid[0].len();
            let mut it = seq.chars().peekable();
            while let Some(c) = it.next() {
                match c {
                    '\x1b' => match it.next().unwrap() {
                        '7' => self.saved = (self.row, self.col),
                        '8' => (self.row, self.col) = self.saved,
                        'D' => self.index(),
                        '[' => {
                            let mut params = String::new();
                            while let Some(d) = it.next_if(|d| d.is_ascii_digit() || *d == ';') {
                                params.push(d);
                            }
                            let nums: Vec<usize> = params.split(';').map(|n| n.parse().unwrap_or(1)).collect();
                            let n = nums[0];
                            match it.next().unwrap() {
                                'A' => self.row = self.row.saturating_sub(n),
                                'B' => self.row = (self.row + n).min(self.bottom),
                                'C' => self.col = (self.col + n).min(cols - 1),
                                'K' => self.grid[self.row] = vec![' '; cols],
                                'H' => {
                                    self.row = nums[0] - 1;
                                    self.col = nums.get(1).copied().unwrap_or(1) - 1;
                                }
                                'L' => {
                                    for _ in 0..n {
                                        self.grid.remove(self.bottom);
                                        self.grid.insert(self.row, vec![' '; cols]);
                                    }
                                }
                                'm' => {}
                                other => panic!("unexpected CSI {other}"),
                            }
                        }
                        other => panic!("unexpected ESC {other}"),
                    },
                    '\r' => self.col = 0,
                    _ => {
                        if self.col < cols {
                            self.grid[self.row][self.col] = c;
                            self.col += 1;
                        }
                    }
                }
            }
        }
        fn prompts(&self) -> usize {
            self.grid.iter().filter(|r| r.iter().collect::<String>().starts_with("> ")).count()
        }
        fn dump(&self) -> Vec<String> {
            self.grid.iter().map(|r| r.iter().collect::<String>().trim_end().to_string()).collect()
        }
    }

    /// One key press at the prompt as the editor performs it: redraw the
    /// input, then redraw the (type-ahead narrowed) command menu.
    fn press(v: &mut EditView, term: &mut Vt, c: char, rows: usize, cols: usize) {
        v.line.push(c);
        v.cursor += 1;
        term.feed(&v.redraw_sequence(cols, ""));
        let content = v.content_rows(cols);
        let max_rows = menu_max_rows(rows, content, v.status.is_some());
        let lines = crate::commands::menu(&v.line, cols, max_rows);
        let below = content.saturating_sub(1).saturating_sub(v.drawn_cursor_row);
        let old_rows = v.menu_rows.min(max_rows);
        let (seq, used) = menu_sequence(old_rows, &lines, v.status.is_some(), below);
        v.drawn_rows = content + used;
        v.menu_rows = used;
        term.feed(&seq);
    }

    #[test]
    fn narrowing_the_command_menu_does_not_stack_prompts() {
        for (with_status, rows, start, typed) in [
            (false, 30, 0, "/co"),
            (true, 30, 0, "/co"),
            (true, 10, 0, "/co"),
            (true, 10, 0, "/zzz"),
            (true, 30, 10, "/co"),
            (true, 10, 3, "/mo"),
            (false, 10, 3, "/mo"),
        ] {
            let cols = 80;
            let mut term = Vt::new(rows, cols, with_status);
            term.row -= start;
            let mut v = view("");
            v.mode = EditMode::Prompt;
            v.prompt_width = 2;
            if with_status {
                v.status = Some(Arc::new(crate::status::StatusLine::for_test()));
            }
            term.feed("> ");
            v.drawn_rows = 1;
            for c in typed.chars() {
                press(&mut v, &mut term, c, rows, cols);
                assert_eq!(
                    term.prompts(),
                    1,
                    "status={with_status} rows={rows} start={start} {typed} after {c:?}: {:#?}",
                    term.dump()
                );
            }
        }
    }

    #[test]
    fn read_line_keeps_the_inline_menu_off_under_the_frame_renderer() {
        // Regression: `read_line` re-enabled the inline command menu that
        // `set_edit_hook` disabled, so typing `/...` in frame mode wrote raw
        // menu scrolls under the frame and stacked the editor row per key.
        let view = EditView::shared(None, Arc::new(Mutex::new(EditContext::default())));
        view.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
        view.lock().unwrap().mode = EditMode::Prompt;
        let mut reader = LineReader::default();
        reader.pending.extend(b"/he\r".iter());
        let _ = reader.read_line(&view, &|_| {});
        let v = view.lock().unwrap();
        assert!(!v.menu_enabled, "inline menu must stay off with an edit hook");
        assert_eq!(v.menu_rows, 0, "no inline menu rows were drawn");
    }

    #[test]
    fn frame_hook_receives_the_command_menu_at_the_prompt() {
        type Renders = Arc<Mutex<Vec<(String, Vec<String>)>>>;
        let seen: Renders = Arc::default();
        let view = EditView::shared(None, Arc::new(Mutex::new(EditContext::default())));
        {
            let seen = seen.clone();
            view.lock().unwrap().set_edit_hook(Arc::new(move |line, _, _, menu| {
                seen.lock().unwrap().push((line.to_string(), menu.to_vec()));
            }));
        }
        view.lock().unwrap().mode = EditMode::Prompt;
        let last =
            |line: &str| seen.lock().unwrap().iter().rev().find(|(l, _)| l == line).map(|(_, m)| m.clone()).unwrap();
        let plain = |rows: Vec<String>| -> Vec<String> {
            let re = regex::Regex::new("\x1b\\[[0-9;]*m").unwrap();
            rows.iter().map(|r| re.replace_all(r, "").into_owned()).collect()
        };
        let mut reader = LineReader::default();
        reader.pending.extend(b"/he\r".iter());
        let _ = reader.read_line(&view, &|_| {});
        let slash = plain(last("/"));
        assert!(slash.len() > 1, "a bare `/` lists commands: {slash:?}");
        let narrowed = plain(last("/he"));
        assert!(!narrowed.is_empty() && narrowed.iter().all(|r| r.contains("/help")), "{narrowed:?}");
        assert!(narrowed.len() < slash.len(), "typing narrows the menu");
        // After Enter the editor is empty and the menu is gone.
        assert!(last("").is_empty());
        // Plain text never opens a menu; during a turn there is none either.
        let mut reader = LineReader::default();
        reader.pending.extend(b"hi\r".iter());
        let _ = reader.read_line(&view, &|_| {});
        assert!(last("hi").is_empty());
        view.lock().unwrap().mode = EditMode::Turn;
        let mut reader = LineReader::default();
        reader.pending.extend(b"/x\r".iter());
        let _ = reader.read_line(&view, &|_| {});
        assert!(last("/x").is_empty(), "no menu during a turn");
    }
}
