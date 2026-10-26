//! Minimal line editor for a terminal stdin. Reading key by key (instead of
//! the kernel's line mode) lets Ctrl-C and Esc act immediately, and lets text
//! typed during a turn stay in the editor row instead of mixing with streamed
//! output. The editor never writes to the terminal itself: every change goes
//! to the frame renderer's hook (see [`EditHook`]).
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

/// Esc twice within this window acts as one gesture: it clears the idle
/// prompt's input, and (read by the turn loop) cancels a running turn. Defined
/// once so the two paths cannot drift apart.
pub const DOUBLE_ESCAPE_WINDOW: std::time::Duration = std::time::Duration::from_millis(1000);

/// Detects a double Esc press within [`DOUBLE_ESCAPE_WINDOW`]. The window is
/// time-based: a press landing after it starts a fresh pair rather than
/// completing the old one, so an Esc used alone (readline/vi line-editing) does
/// not half-trigger the gesture. Callers decide on the press that *completes*
/// the pair, never on the first one.
///
/// A pair is also scoped to a single uninterrupted idle-prompt session: each
/// armed press records the edit *generation* it was made in (see
/// [`EditView::edit_generation`]), and a later press only completes the pair
/// when the generation still matches. The reader is persistent and a single
/// `read_line` stays outstanding across a Prompt→Turn→Prompt transition (an Esc
/// is forwarded to the turn loop without returning), so a time-only pair could
/// otherwise let one arm made before a turn complete with one Esc at the next
/// prompt. The generation changes on every mode transition, invalidating such a
/// stale arm even though the gesture's own `read_line` never reset it.
#[derive(Default)]
pub struct DoubleEscape {
    last: Option<(std::time::Instant, u64)>,
}

impl DoubleEscape {
    /// Record a press at `now` in edit generation `generation`; true when it
    /// completes a double press. A press completes the pair only when the prior
    /// arm is within [`DOUBLE_ESCAPE_WINDOW`] *and* was made in the same
    /// generation, so a mode transition between the two presses starts a fresh
    /// pair. The pair is consumed, so the next press starts a fresh one.
    pub fn press_in(&mut self, now: std::time::Instant, generation: u64) -> bool {
        match self.last.take() {
            Some((last, armed_gen)) if armed_gen == generation && now.duration_since(last) <= DOUBLE_ESCAPE_WINDOW => {
                true
            }
            _ => {
                self.last = Some((now, generation));
                false
            }
        }
    }

    /// Record a press at `now`; true when it completes a double press. For
    /// detectors that are not scoped to an edit generation (e.g. the turn-loop
    /// cancel, which uses this `DoubleEscape` type), which live for a single
    /// purpose and never cross a prompt/turn boundary. The Ctrl-C exit gesture
    /// is a *separate* `DoublePress` detector in `src/main.rs`, not a user of
    /// this method.
    pub fn press(&mut self, now: std::time::Instant) -> bool {
        self.press_in(now, 0)
    }

    /// Forget any armed press, so the next one starts a fresh pair. Used at a
    /// read/mode boundary: a pair is two presses at the same idle prompt, so a
    /// press recorded before the boundary must never complete one after it.
    pub fn reset(&mut self) {
        self.last = None;
    }
}

/// Where the line being typed is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditMode {
    /// At the idle prompt.
    Prompt,
    /// During a turn (steering input; no command menu).
    Turn,
}

pub struct EditView {
    line: String,
    /// Cursor position as a character index into `line` (0..=chars).
    cursor: usize,
    mode: EditMode,
    /// Bumped on every mode transition. The double-Esc detector records the
    /// generation an Esc armed in, so an arm cannot survive a Prompt↔Turn
    /// transition and complete at the next prompt: a pair must be two presses
    /// at the same uninterrupted idle prompt.
    edit_generation: u64,
    /// Rows of the command menu last handed to the frame (0: none shown).
    menu_rows: usize,
    /// Esc hid the menu; it comes back when the line changes.
    menu_hidden: bool,
    /// Messages waiting in the queue (drives the queue indicator row).
    queue_count: usize,
    /// Live configuration, for `/model` argument suggestions. Shared with the
    /// agent loop so a model/provider change is seen on the next keystroke.
    context: Arc<Mutex<EditContext>>,
    /// The frame renderer's hook: each change calls it so the single frame
    /// writer redraws the editor row. Unset before the renderer is wired up
    /// (and in tests), when changes simply draw nothing.
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
    pub fn shared(context: Arc<Mutex<EditContext>>) -> SharedView {
        Arc::new(Mutex::new(Self {
            line: String::new(),
            cursor: 0,
            mode: EditMode::Prompt,
            edit_generation: 0,
            menu_rows: 0,
            menu_hidden: false,
            queue_count: 0,
            context,
            on_edit: None,
            history: InputHistory::default(),
        }))
    }

    /// Route editor drawing through the frame renderer: every change calls the
    /// hook with the line, cursor, queue count and command menu rows.
    pub fn set_edit_hook(&mut self, hook: EditHook) {
        self.on_edit = Some(hook);
    }

    /// Whether the editor holds a half-typed line. An idle timer waits for the
    /// draft to be sent or cleared rather than firing into it.
    pub fn has_draft(&self) -> bool {
        !self.line.is_empty()
    }

    /// Hand the editor (and its command menu) to the frame hook.
    fn draw_edit(&mut self) {
        let Some(hook) = self.on_edit.clone() else { return };
        let menu = self.frame_menu();
        // Track the menu's height so `menu_visible()` reflects the menu the
        // frame actually draws: `read_line` uses it to decide whether a bare
        // Esc hides the menu or is emitted as `Key::Escape`.
        self.menu_rows = menu.len();
        hook(&self.line, self.cursor, self.queue_count, &menu);
    }

    pub fn set_mode(&mut self, mode: EditMode) {
        if mode != self.mode {
            // A pair of Esc presses is scoped to one uninterrupted idle prompt;
            // bumping the generation on every transition invalidates any arm
            // made before this change so it cannot complete after it.
            self.edit_generation = self.edit_generation.wrapping_add(1);
        }
        self.mode = mode;
        self.draw_edit();
    }

    /// Update the queue indicator (None hides it).
    pub fn set_queue_count(&mut self, count: Option<usize>) {
        self.queue_count = count.unwrap_or(0);
        self.draw_edit();
    }

    /// The shared suggestion context, so the agent loop can refresh the
    /// config after a model/provider change.
    pub fn context_handle(&self) -> Arc<Mutex<EditContext>> {
        self.context.clone()
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

    /// Redraw after a text mutation: one hook call composes the input and
    /// the (re-shown) menu together.
    fn mutated(&mut self) {
        self.menu_hidden = false;
        self.history.edited();
        self.draw_edit();
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

    /// The menu rows for the frame renderer: shown at the prompt only, sized
    /// so editor + menu + status bar fit the terminal.
    fn frame_menu(&self) -> Vec<String> {
        if self.mode != EditMode::Prompt {
            return Vec::new();
        }
        let (rows, cols) = crate::status::terminal_size().unwrap_or((24, 80));
        let cols = (cols as usize).max(1);
        // Size the menu against the editor's real rendered height, measured
        // with `frame::editor_lines` (the helper the frame renderer draws with),
        // and reserve the queue row, so `editor + queue + menu + status` fits
        // the terminal and an oversized menu cannot push the prompt off-screen.
        let prompt = format!("{}› ", crate::ui::stamp());
        let editor = crate::frame::editor_lines(&prompt, &self.line, self.cursor, cols).len();
        let queue = (self.queue_count > 0) as usize;
        let max_rows = menu_max_rows(rows as usize, editor + queue);
        self.menu_lines(cols, max_rows)
    }

    /// Hide the menu (Esc) until the line changes.
    fn hide_menu(&mut self) {
        self.menu_hidden = true;
        self.draw_edit();
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

    /// Recompose the editor through the frame hook: at a fresh prompt, or
    /// after a resize (the menu is re-sized to fit the new height).
    pub fn redraw(&mut self) {
        self.draw_edit();
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

    /// Clear the input when it holds text, reporting whether it did. The idle
    /// prompt's "Esc Esc clears the input" gesture goes through here rather than
    /// `clear_line` so an empty buffer is a true no-op — no redraw and no
    /// `history.edited()` — and the caller can tell it cleared nothing.
    pub fn clear_input_if_any(&mut self) -> bool {
        if self.line.is_empty() {
            return false;
        }
        self.clear_line();
        true
    }

    /// Move the cursor and redraw the editor.
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
    }

    /// Submit the line: record it in history and redraw the editor empty (the
    /// caller adds the submitted line to the transcript).
    fn take(&mut self) -> String {
        let line = std::mem::take(&mut self.line);
        self.history.record(&line);
        self.history.edited();
        self.cursor = 0;
        self.menu_hidden = false;
        self.menu_rows = 0;
        if let Some(hook) = self.on_edit.clone() {
            hook(&self.line, self.cursor, self.queue_count, &[]);
        }
        line
    }
}

/// The number of command-menu rows that fit below a `content`-row editor on a
/// `rows`-high terminal, leaving the status row intact and never exceeding the
/// menu's own 16-row cap. Zero means no room remains, which suppresses the
/// menu.
fn menu_max_rows(rows: usize, content: usize) -> usize {
    rows.saturating_sub(content).saturating_sub(1).min(16)
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
    /// A lone Esc press (not part of an escape sequence).
    Escape,
    /// Shift+Tab: cycle the agent mode (normal/plan/auto).
    CycleMode,
    /// Enter on an unknown `/command`: the line stays in the editor, unsent;
    /// this is why (see `commands::rejection`).
    Rejected(String),
}

/// How long to wait after Esc for the rest of an escape sequence. Terminals
/// send sequences in one write, so a lone Esc is one with nothing following.
const ESCAPE_SEQUENCE_WAIT_MS: i32 = 30;

static ORIGINAL: OnceLock<libc::termios> = OnceLock::new();

/// Whether key mode's terminal setup was ever applied. Cleanup control bytes
/// are only emitted when it was, so piped/non-TTY sessions (which never enter
/// key mode) keep clean, machine-readable stdout on exit.
static KEY_MODE_ENTERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

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
/// keys (Ctrl-C, and Ctrl-O, which macOS would use to discard output) delivered
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

/// Marks the view as a non-idle (`EditMode::Turn`) phase for the guard's
/// lifetime, restoring `EditMode::Prompt` when it is dropped. Compaction runs
/// on the still-outstanding prompt read (a `/compact` deferred from a turn
/// executes after the turn loop already restored `Prompt`), so without this the
/// idle "Esc Esc clears the input" gesture would erase a partially typed next
/// message with the same presses that cancel the compaction. Bracketing the
/// phase with a guard — rather than a hand-placed `set_mode(Turn)` / trailing
/// `set_mode(Prompt)` pair — restores the idle prompt on *every* exit path
/// (including a future early `return`, `?`, or panic that unwinds the loop),
/// not just the single explicit one, and makes the transition directly
/// testable without driving a whole async compaction.
#[must_use = "dropping the guard immediately restores EditMode::Prompt"]
pub struct NonIdlePhase {
    view: SharedView,
}

impl NonIdlePhase {
    /// Enter the non-idle phase: mark the view `Turn` now, restore `Prompt` on
    /// drop. Each transition bumps the view's edit generation (see
    /// [`EditView::set_mode`]), so a double-Esc arm made before the phase cannot
    /// complete with a single press after it.
    pub fn enter(view: &SharedView) -> Self {
        view.lock().unwrap().set_mode(EditMode::Turn);
        Self { view: view.clone() }
    }
}

impl Drop for NonIdlePhase {
    fn drop(&mut self) {
        self.view.lock().unwrap().set_mode(EditMode::Prompt);
    }
}

/// Reads keys, carrying bytes that arrived past the end of a line (pastes)
/// into the next read.
#[derive(Default)]
pub struct LineReader {
    pending: std::collections::VecDeque<u8>,
    utf8: Vec<u8>,
    /// The idle prompt's "Esc Esc clears the input" gesture: the paired-press
    /// detector. Lives here because `read_line` is the only place that sees
    /// every Esc, and it must be per-reader so a held detector cannot leak
    /// across readers.
    escape: DoubleEscape,
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

    /// Record an Esc press at `now` for the idle prompt's "Esc Esc clears the
    /// input" gesture at `view`; true only when the press completes the double
    /// press *and* that completed gesture cleared non-empty input. A completed
    /// pair on an empty prompt still consumes the pair but returns `false`
    /// (there is nothing to clear), so `false` does not by itself mean the pair
    /// went uncompleted. A lone press (or a second one after
    /// [`DOUBLE_ESCAPE_WINDOW`] has lapsed) arms the detector and leaves the
    /// text alone, so an Esc used alone for line editing does not discard the
    /// buffer.
    ///
    /// The gesture is scoped to the idle prompt (`EditMode::Prompt`) in both
    /// directions: during a turn the input is the *next* message, and an Esc
    /// there cancels or steers — so a Turn-mode press must neither clear the
    /// text nor *arm* the detector. Arming on a
    /// turn-time press would let one Esc at the next idle prompt complete the
    /// pair and clear the buffer, when the gesture requires two presses there.
    ///
    /// The pair is also scoped to one *uninterrupted* idle prompt: the reader
    /// is persistent and a single `read_line` stays outstanding across a
    /// Prompt→Turn→Prompt transition (an Esc is forwarded without returning),
    /// so the arm is tagged with the view's edit generation and only completes
    /// while that generation is unchanged. An intervening turn bumps it, so an
    /// arm made before the turn cannot complete with one Esc at the next prompt.
    pub fn escape_press(&mut self, view: &SharedView, now: std::time::Instant) -> bool {
        let mut view = view.lock().unwrap();
        if view.mode != EditMode::Prompt {
            return false;
        }
        if !self.escape.press_in(now, view.edit_generation) {
            return false;
        }
        view.clear_input_if_any()
    }

    /// Read one line. Ctrl-C and Esc go to `send` straight away; the
    /// return value is a `Key::Line` or `Key::Eof`.
    pub fn read_line(&mut self, view: &SharedView, send: &dyn Fn(Key)) -> Key {
        let _mode = KeyMode::enter();
        // A double press is two Esc presses at the same idle prompt, so the
        // detector must not carry an arm across a read boundary: this reader
        // is persistent, and without the reset an Esc pressed in a previous
        // read (e.g. mid-turn) could pair with a single Esc here and clear
        // the buffer.
        self.escape.reset();
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
                    if let Some(note) = crate::commands::rejection(&view.line) {
                        drop(view);
                        send(Key::Rejected(note));
                        continue;
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
                            // skipped.
                            if seq == [0x1b, b'[', b'Z'] {
                                send(Key::CycleMode);
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
                                            if let Some(note) = crate::commands::rejection(&view.line) {
                                                drop(view);
                                                send(Key::Rejected(note));
                                                continue;
                                            }
                                            return Key::Queue(view.take() + "\n");
                                        }
                                        view.insert("\n");
                                    }
                                    Esc::Submit => {
                                        let mut view = shared.lock().unwrap();
                                        match crate::commands::rejection(&view.line) {
                                            Some(note) => {
                                                drop(view);
                                                send(Key::Rejected(note));
                                            }
                                            None => return Key::Line(view.take() + "\n"),
                                        }
                                    }
                                    Esc::Escape if menu => {
                                        // Closing the menu is the first Esc of
                                        // the idle clear gesture: record it
                                        // before hiding the menu so a `/` line
                                        // clears in two presses, not three
                                        // (hide, then arm, then clear).
                                        self.escape_press(shared, std::time::Instant::now());
                                        shared.lock().unwrap().hide_menu();
                                    }
                                    Esc::Escape => {
                                        // With the command menu already closed
                                        // (above), Esc is the idle prompt's
                                        // clear gesture (a no-op during a turn).
                                        self.escape_press(shared, std::time::Instant::now());
                                        send(Key::Escape);
                                    }
                                    // Re-read as the byte legacy mode sends,
                                    // so every control key keeps one handler.
                                    Esc::Control(byte) => self.pending.push_front(byte),
                                    Esc::Ignored => {}
                                }
                            }
                        }
                        None if menu => {
                            // Same as the kitty Esc above: the menu-closing
                            // press is the first half of the clear gesture,
                            // not a wasted press.
                            self.escape_press(shared, std::time::Instant::now());
                            shared.lock().unwrap().hide_menu();
                        }
                        None => {
                            // A lone Esc (no continuation): the idle clear
                            // gesture, and the turn loop's cancel.
                            self.escape_press(shared, std::time::Instant::now());
                            send(Key::Escape);
                        }
                        // Esc Esc typed faster than the wait: two presses.
                        Some(0x1b) => {
                            self.pending.push_front(0x1b);
                            self.escape_press(shared, std::time::Instant::now());
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

    /// A standalone view holding `line`, with no frame hook (nothing is
    /// drawn).
    fn view(line: &str) -> EditView {
        let mut view = EditView {
            line: line.into(),
            cursor: line.chars().count(),
            mode: EditMode::Turn,
            edit_generation: 0,
            menu_rows: 0,
            menu_hidden: false,
            queue_count: 0,
            context: Arc::new(Mutex::new(EditContext::default())),
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
        let counter = calls.clone();
        view.on_edit = Some(Arc::new(move |_: &str, _: usize, _: usize, _: &[String]| {
            *counter.lock().unwrap() += 1;
        }));

        *calls.lock().unwrap() = 0;
        view.set_line("/model gpt");
        assert_eq!(*calls.lock().unwrap(), 1, "history recall renders the frame once");
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
            Key::Escape => "escape".into(),
            Key::CycleMode => "cycle-mode".into(),
            Key::Rejected(note) => format!("rejected {note:?}"),
        }
    }

    #[test]
    fn kitty_encoded_control_keys_act_like_legacy_bytes() {
        let context = Arc::new(Mutex::new(EditContext::default()));
        let frame = EditView::shared(context);
        frame.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
        {
            let view = &frame;
            view.lock().unwrap().mode = EditMode::Turn;
            // Ctrl-C clears the line and interrupts; Esc is sent; an unbound
            // control key (Ctrl-O) is ignored.
            assert_eq!(
                keys_sent(view, b"abc\x1b[99;5u\x1b[27u\x1b[111;5uok\r"),
                ["interrupt", "escape", "-> line \"ok\\n\""]
            );
            // Ctrl-D on an empty line is end of input, as the legacy byte is.
            assert_eq!(keys_sent(view, b"\x1b[100;5u"), ["-> eof"]);
            // Ctrl-A / Ctrl-U / Ctrl-W edit the line.
            assert_eq!(keys_sent(view, b"one two\x1b[119;5u\x1b[97;5uX\r"), ["-> line \"Xone \\n\""]);
        }
        // At the prompt with the command menu open, Esc closes the menu and
        // counts as the first half of the clear gesture, so the second Esc
        // clears the line (Ctrl-U here is then a no-op).
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
        // With an edit hook installed, `take` redraws through the hook — but it
        // must still record and reset history so Up/Down recall works.
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
    fn clear_input_if_any_empties_a_non_empty_line() {
        // The idle-prompt "Esc Esc clears the input" gesture clears through this
        // helper. A non-empty buffer becomes empty with the cursor at home, in
        // both render paths (the turn used the frame hook).
        let mut plain = view("hello");
        assert!(plain.clear_input_if_any(), "a non-empty line is cleared");
        assert!(plain.line.is_empty());
        assert_eq!(plain.cursor, 0);
        // A multiline buffer (Ctrl-Enter newlines) clears whole.
        let mut multiline = view("one\ntwo");
        assert!(multiline.clear_input_if_any());
        assert!(multiline.line.is_empty());
        // Frame path: the clear still lands in the buffer.
        let mut frame = view("hello");
        frame.set_edit_hook(Arc::new(|_, _, _, _| {}));
        assert!(frame.clear_input_if_any());
        assert!(frame.line.is_empty());
    }

    #[test]
    fn clear_input_if_any_is_an_inert_no_op_on_an_empty_line() {
        // "only when there is text": an empty buffer must not be redrawn (or
        // trip history), so the second Esc on an empty prompt does nothing.
        // Pin both halves of "inert": the edit hook must not fire (no redraw)
        // and a browsing history position must survive (no `history.edited()`).
        let calls = Arc::new(Mutex::new(0usize));
        let mut view = view("");
        let counter = calls.clone();
        view.on_edit = Some(Arc::new(move |_: &str, _: usize, _: usize, _: &[String]| {
            *counter.lock().unwrap() += 1;
        }));
        // Enter a browsing state directly (keeping the buffer empty, the case
        // under test): a stray `history.edited()` on the empty path would reset
        // `position`, changing what the next Down returns.
        view.history.record("earlier");
        assert_eq!(view.history.up(""), Some("earlier"), "recall entered the browsing state");

        *calls.lock().unwrap() = 0;
        assert!(!view.clear_input_if_any(), "nothing to clear");
        assert!(view.line.is_empty());
        assert_eq!(view.cursor, 0);
        assert_eq!(*calls.lock().unwrap(), 0, "the empty path triggers no redraw");
        // Browsing position survived: Down past the newest entry still returns
        // to the saved (empty) draft, which a `history.edited()` would have lost.
        assert_eq!(view.history.down(), Some(""), "the browsing position was not reset by the no-op");
    }

    /// A prompt-mode reader with `line` in its buffer, drawing disabled.
    fn prompt_reader(line: &str) -> (LineReader, SharedView) {
        let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
        view.lock().unwrap().mode = EditMode::Prompt;
        view.lock().unwrap().insert(line);
        (LineReader::default(), view)
    }

    #[test]
    fn double_escape_press_clears_a_non_empty_idle_input() {
        // The idle prompt's gesture: with text in the buffer, a second Esc
        // within the window clears it. A lone Esc (or a second one after the
        // window has lapsed) leaves the text alone.
        let (mut reader, view) = prompt_reader("half-typed prompt");
        let t = std::time::Instant::now();
        assert!(!reader.escape_press(&view, t), "the first Esc only arms the detector");
        assert_eq!(view.lock().unwrap().line, "half-typed prompt", "one Esc keeps the text");
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(400)), "the second completes it");
        assert!(view.lock().unwrap().line.is_empty(), "the completing press clears the buffer");
        // The paired press consumed the arm, so the next one starts over and
        // does not clear the text typed since.
        view.lock().unwrap().insert("again");
        assert!(!reader.escape_press(&view, t + std::time::Duration::from_millis(500)));
        assert_eq!(view.lock().unwrap().line, "again");
        // Outside the window: the second press re-arms instead of completing.
        assert!(!reader.escape_press(&view, t + std::time::Duration::from_millis(1600)));
        assert_eq!(view.lock().unwrap().line, "again", "a slow second Esc does not clear");
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(1700)));
    }

    #[test]
    fn escape_clears_through_the_reader_and_only_when_there_is_text() {
        // End to end through the key path at the prompt: two Esc bytes clear a
        // non-empty buffer (in both render paths), while two Esc on an empty
        // buffer leave it empty without error. Each Esc still reaches the turn
        // loop as `Key::Escape`.
        for frame in [false, true] {
            let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
            if frame {
                view.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
            }
            view.lock().unwrap().mode = EditMode::Prompt;
            view.lock().unwrap().line = "draft".into();
            view.lock().unwrap().cursor = 5;
            let sent = Mutex::new(Vec::new());
            let mut reader = LineReader::default();
            reader.pending.extend(b"\x1b\x1b".iter());
            let key = reader.read_line(&view, &|key| sent.lock().unwrap().push(key_name(&key)));
            assert_eq!(sent.into_inner().unwrap(), ["escape", "escape"], "frame={frame}");
            assert!(matches!(key, Key::Eof), "the pending buffer ends");
            assert!(view.lock().unwrap().line.is_empty(), "two Esc cleared the input (frame={frame})");
        }
        // A lone Esc on an empty line leaves it empty (nothing to clear).
        let (mut reader, view) = prompt_reader("");
        assert!(!reader.escape_press(&view, std::time::Instant::now()));
        assert!(view.lock().unwrap().line.is_empty());
    }

    #[test]
    fn escape_does_not_clear_the_input_during_a_turn() {
        // The gesture is the idle prompt's: during a turn the typed text is the
        // next message (steered with Enter), so Esc must not discard it.
        let (mut reader, view) = prompt_reader("steer this");
        view.lock().unwrap().mode = EditMode::Turn;
        let t = std::time::Instant::now();
        assert!(!reader.escape_press(&view, t));
        assert!(!reader.escape_press(&view, t + std::time::Duration::from_millis(100)));
        assert_eq!(view.lock().unwrap().line, "steer this", "Esc during a turn keeps the next message");
    }

    #[test]
    fn escape_during_a_turn_does_not_arm_the_prompt_clear() {
        // The reader is persistent, so a Turn-mode Esc must not arm the
        // detector: otherwise one Esc at the next idle prompt would complete
        // the pair and clear the buffer, when the gesture requires two
        // presses at that prompt.
        let (mut reader, view) = prompt_reader("next message");
        let t = std::time::Instant::now();
        view.lock().unwrap().mode = EditMode::Turn;
        assert!(!reader.escape_press(&view, t), "a turn-time Esc is not the gesture's");
        view.lock().unwrap().mode = EditMode::Prompt;
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(100)),
            "the first Esc at the idle prompt only arms; the turn-time press must not count"
        );
        assert_eq!(view.lock().unwrap().line, "next message", "one idle Esc keeps the text");
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(200)), "two idle Esc presses clear");
        assert!(view.lock().unwrap().line.is_empty());
    }

    #[test]
    fn an_arm_does_not_survive_an_intervening_turn() {
        // The reader is persistent and a single `read_line` stays outstanding
        // across a Prompt→Turn→Prompt transition (an Esc is forwarded to the
        // turn loop without returning), so `read_line`'s own reset never runs.
        // An Esc armed at the idle prompt must not pair with one Esc at the
        // *next* prompt after a turn ran in between: `set_mode` bumps the edit
        // generation, invalidating the stale arm.
        let (mut reader, view) = prompt_reader("draft");
        let t = std::time::Instant::now();
        // Arm at the idle prompt.
        assert!(!reader.escape_press(&view, t), "the first Esc only arms");
        // A queued turn runs on the same outstanding read, then we return to
        // the prompt — within the double-Esc window.
        view.lock().unwrap().set_mode(EditMode::Turn);
        view.lock().unwrap().set_mode(EditMode::Prompt);
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(100)),
            "one Esc after the turn must not complete the pre-turn arm"
        );
        assert_eq!(view.lock().unwrap().line, "draft", "the draft survives one post-turn Esc");
        // Two fresh presses at the same prompt still clear.
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(200)), "two presses clear");
        assert!(view.lock().unwrap().line.is_empty());
    }

    #[test]
    fn escape_during_compaction_neither_clears_nor_arms() {
        // A `/compact` deferred from a turn runs after the turn loop already
        // restored `EditMode::Prompt`, on the same outstanding read. The
        // compaction marks itself a non-idle (`Turn`) phase, so while a partial
        // next message sits in the buffer an Esc pressed to cancel the
        // compaction must neither clear that text nor arm the clear gesture —
        // and the Prompt→Turn→Prompt transitions bump the edit generation, so
        // an arm made before the compaction cannot complete with one Esc after.
        let (mut reader, view) = prompt_reader("next message");
        let t = std::time::Instant::now();
        // Arm the gesture at the idle prompt before the turn/compaction.
        assert!(!reader.escape_press(&view, t), "the first Esc only arms");
        // Turn runs and ends (Prompt restored), then the deferred compaction
        // marks itself Turn. Both transitions invalidate the pre-existing arm.
        view.lock().unwrap().set_mode(EditMode::Turn);
        view.lock().unwrap().set_mode(EditMode::Prompt);
        view.lock().unwrap().set_mode(EditMode::Turn); // compaction runs
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(100)),
            "a compaction-time Esc is not the gesture's and does not complete the stale arm"
        );
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(200)),
            "a second compaction-time Esc still does not clear"
        );
        assert_eq!(view.lock().unwrap().line, "next message", "the partial input survives compaction");
        // Compaction finishes, restoring the idle prompt: the gesture is live
        // again, but needs two fresh presses (the compaction-time ones did not arm it).
        view.lock().unwrap().set_mode(EditMode::Prompt);
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(300)),
            "the first idle Esc after compaction only re-arms"
        );
        assert_eq!(view.lock().unwrap().line, "next message", "one post-compaction Esc keeps the text");
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(400)), "two idle presses clear");
        assert!(view.lock().unwrap().line.is_empty());
    }

    #[test]
    fn non_idle_phase_marks_turn_and_restores_prompt_on_drop() {
        // The guard that brackets a compaction (`run_compaction`) must mark the
        // view `Turn` for its lifetime and restore `Prompt` when it drops — and
        // it must bump the edit generation on *both* transitions so a double-Esc
        // arm made before the phase cannot complete with one press after it.
        let (mut reader, view) = prompt_reader("draft");
        assert_eq!(view.lock().unwrap().mode, EditMode::Prompt);
        let gen_before = view.lock().unwrap().edit_generation;
        // Arm the idle gesture, then enter the non-idle phase.
        let t = std::time::Instant::now();
        assert!(!reader.escape_press(&view, t), "the first idle Esc only arms");
        {
            let _phase = NonIdlePhase::enter(&view);
            assert_eq!(view.lock().unwrap().mode, EditMode::Turn, "the phase marks Turn");
            assert_ne!(
                view.lock().unwrap().edit_generation,
                gen_before,
                "entering the phase bumps the edit generation"
            );
            // A press during the phase neither clears nor arms (Turn-mode early
            // return), and the pre-phase arm is now stale.
            assert!(
                !reader.escape_press(&view, t + std::time::Duration::from_millis(50)),
                "a phase-time Esc neither clears nor completes the stale arm"
            );
            assert_eq!(view.lock().unwrap().line, "draft", "the draft survives the phase");
        }
        // Dropping the guard restores the idle prompt, bumping the generation
        // again so the stale arm still cannot complete.
        assert_eq!(view.lock().unwrap().mode, EditMode::Prompt, "drop restores Prompt");
        assert!(
            !reader.escape_press(&view, t + std::time::Duration::from_millis(100)),
            "the first idle Esc after the phase only re-arms; the pre-phase arm did not survive"
        );
        assert_eq!(view.lock().unwrap().line, "draft", "one post-phase Esc keeps the text");
        assert!(reader.escape_press(&view, t + std::time::Duration::from_millis(150)), "two fresh idle presses clear");
        assert!(view.lock().unwrap().line.is_empty());
    }

    #[test]
    fn a_new_read_starts_a_fresh_escape_pair() {
        // `read_line` resets the detector, so an Esc that ended one read
        // cannot pair with the first Esc of the next: two Esc bytes split
        // across reads leave the buffer alone, while two inside one read
        // clear it.
        let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
        view.lock().unwrap().mode = EditMode::Prompt;
        view.lock().unwrap().line = "draft".into();
        view.lock().unwrap().cursor = 5;
        let sent = Mutex::new(Vec::new());
        let send = |key: Key| sent.lock().unwrap().push(key_name(&key));
        let mut reader = LineReader::default();
        reader.pending.extend(b"\x1b".iter());
        assert!(matches!(reader.read_line(&view, &send), Key::Eof), "the pending buffer ends");
        view.lock().unwrap().line = "draft".into();
        reader.pending.extend(b"\x1b".iter());
        assert!(matches!(reader.read_line(&view, &send), Key::Eof));
        assert_eq!(view.lock().unwrap().line, "draft", "Esc presses split across reads never pair");
        reader.pending.extend(b"\x1b\x1b".iter());
        assert!(matches!(reader.read_line(&view, &send), Key::Eof));
        assert!(view.lock().unwrap().line.is_empty(), "two Esc in one read clear the input");
        assert_eq!(sent.into_inner().unwrap(), ["escape", "escape", "escape", "escape"]);
    }

    #[test]
    fn double_escape_clears_a_command_menu_line_in_two_presses() {
        // The menu-closing Esc is the first half of the idle clear gesture, so
        // a `/command` line (menu open) clears in two Esc presses, not three.
        // This holds for the kitty-encoded Esc (`Esc::Escape if menu`) and the
        // legacy bare Esc (`None if menu`) alike.
        let context = Arc::new(Mutex::new(EditContext::default()));
        // Kitty Esc: two `CSI 27 u` close the menu then clear the line.
        let view = EditView::shared(context.clone());
        view.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
        view.lock().unwrap().mode = EditMode::Prompt;
        assert_eq!(
            keys_sent(&view, b"/he\x1b[27u\x1b[27u\r"),
            ["escape", "-> line \"\\n\""],
            "kitty Esc Esc clears the `/` line"
        );
        assert!(view.lock().unwrap().line.is_empty(), "kitty clear");

        // Legacy bare Esc bytes: the same gesture via the `None if menu`
        // path (the trailing Esc is lone, so it reaches that branch).
        let view = EditView::shared(context);
        view.lock().unwrap().set_edit_hook(Arc::new(|_, _, _, _| {}));
        view.lock().unwrap().mode = EditMode::Prompt;
        keys_sent(&view, b"/he\x1b\x1b");
        assert!(view.lock().unwrap().line.is_empty(), "legacy clear");
    }

    #[test]
    fn tab_completes_model_arguments_from_context() {
        let context = Arc::new(Mutex::new(EditContext {
            config: toml::from_str(r#"model = "openai/gpt-4o""#).unwrap(),
            recents: crate::recents::SharedRecents::default(),
        }));
        context.lock().unwrap().recents.lock().unwrap().record("ollama/qwen3:8b");
        let view = EditView::shared(context);
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
        let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
        view.lock().unwrap().mode = mode;
        let mut reader = LineReader::default();
        reader.pending.extend(bytes.iter());
        reader.read_line(&view, &|_| {})
    }

    #[test]
    fn enter_on_an_unknown_command_keeps_the_line_unsent() {
        // Enter on `/exin` is refused (with a reason), the text stays in the
        // editor, and the fixed line is what gets submitted.
        for (mode, submit) in [
            (EditMode::Prompt, &b"\r"[..]),
            (EditMode::Turn, b"\r"),
            (EditMode::Turn, b"\x1b[13;5u"),
            (EditMode::Prompt, b"\x1b[13;1u"),
        ] {
            let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
            view.lock().unwrap().mode = mode;
            let mut reader = LineReader::default();
            // Type `/exin`, submit (refused), fix to `/exit`, submit.
            let bytes = [&b"/exin"[..], submit, b"\x7ft", submit].concat();
            reader.pending.extend(bytes.iter());
            let notes = Mutex::new(Vec::new());
            let key = reader.read_line(&view, &|key| {
                if let Key::Rejected(note) = key {
                    notes.lock().unwrap().push(note);
                }
            });
            let notes = notes.into_inner().unwrap();
            assert_eq!(notes.len(), 1, "{mode:?} {submit:?}: {notes:?}");
            assert!(notes[0].contains("Did you mean /exit?"), "{notes:?}");
            assert!(
                matches!(&key, Key::Line(l) | Key::Queue(l) if l == "/exit\n"),
                "{mode:?} {submit:?}: only the fixed line is submitted"
            );
        }
        // `//` sends a line starting with `/`; known commands and prose pass.
        assert!(matches!(read_key(EditMode::Prompt, b"//usr/lib is big\r"), Key::Line(l) if l == "//usr/lib is big\n"));
        assert!(matches!(read_key(EditMode::Prompt, b"/help\r"), Key::Line(l) if l == "/help\n"));
        assert!(matches!(read_key(EditMode::Turn, b"hi /exin\r"), Key::Line(l) if l == "hi /exin\n"));
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

    #[test]
    fn frame_hook_receives_the_command_menu_at_the_prompt() {
        type Renders = Arc<Mutex<Vec<(String, Vec<String>)>>>;
        let seen: Renders = Arc::default();
        let view = EditView::shared(Arc::new(Mutex::new(EditContext::default())));
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
        reader.pending.extend(b"/help\r".iter());
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
