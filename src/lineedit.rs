//! Minimal line editor for a terminal stdin. Reading key by key (instead of
//! the kernel's line mode) lets Ctrl-O and Ctrl-C act immediately, and lets
//! text typed during a turn show on the status line instead of mixing with
//! streamed output.

use std::sync::{Arc, Mutex, OnceLock};

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
    mode: EditMode,
    status: Option<Arc<StatusLine>>,
    /// Rows below the prompt used by the command menu.
    menu_rows: usize,
    /// Esc hid the menu; it comes back when the line changes.
    menu_hidden: bool,
    /// Draw the command menu (key-by-key terminal input only).
    menu_enabled: bool,
}

pub type SharedView = Arc<Mutex<EditView>>;

impl EditView {
    pub fn shared(status: Option<Arc<StatusLine>>) -> SharedView {
        Arc::new(Mutex::new(Self {
            line: String::new(),
            mode: EditMode::Prompt,
            status,
            menu_rows: 0,
            menu_hidden: false,
            menu_enabled: false,
        }))
    }

    pub fn line(&self) -> &str {
        &self.line
    }

    pub fn set_mode(&mut self, mode: EditMode) {
        self.mode = mode;
        if let Some(status) = &self.status {
            match mode {
                EditMode::Turn if !self.line.is_empty() => status.set_input(Some(&self.line)),
                _ => status.set_input(None),
            }
        }
    }

    fn on_status(&self) -> Option<&StatusLine> {
        (self.mode == EditMode::Turn).then_some(self.status.as_deref()).flatten()
    }

    fn insert(&mut self, text: &str) {
        self.line.push_str(text);
        match self.on_status() {
            Some(status) => status.set_input(Some(&self.line)),
            None => write(text),
        }
        self.line_changed();
    }

    fn line_changed(&mut self) {
        self.menu_hidden = false;
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
        let lines = if self.menu_hidden { Vec::new() } else { crate::commands::menu(&self.line, cols as usize, max_rows) };
        let (seq, used) = menu_sequence(self.menu_rows, &lines);
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

    /// Tab: complete a `/command`; elsewhere a space.
    fn tab(&mut self) {
        let is_command = self.line.starts_with('/') && !self.line.contains(char::is_whitespace);
        match is_command.then(|| crate::commands::complete(&self.line)).flatten() {
            Some(done) => {
                let rest = done[self.line.len()..].to_string();
                self.insert(&rest);
            }
            None if is_command => {}
            None => self.insert(" "),
        }
    }

    /// The prompt and line were printed again (after other output): the old
    /// menu rows scrolled away, so draw it afresh.
    pub fn prompt_redrawn(&mut self) {
        self.menu_rows = 0;
        self.draw_menu();
    }

    /// The terminal was resized: the old menu rows may no longer fit under the
    /// new scroll region, so blank the rows we reserved and redraw the menu
    /// sized to the new terminal. Call after the status line re-establishes the
    /// scroll region for the new size.
    pub fn resize(&mut self) {
        if self.menu_rows > 0 {
            let (seq, _) = menu_sequence(self.menu_rows, &[]);
            write(&seq);
            self.menu_rows = 0;
        }
        self.draw_menu();
    }

    /// Remove the last `n` characters.
    fn erase(&mut self, n: usize) {
        let mut erased = String::new();
        for _ in 0..n {
            match self.line.pop() {
                Some(c) => erased.push(c),
                None => break,
            }
        }
        match self.on_status() {
            Some(status) => status.set_input((!self.line.is_empty()).then_some(self.line.as_str())),
            None => write(&"\x08 \x08".repeat(erased.chars().count())),
        }
        if !erased.is_empty() {
            self.line_changed();
        }
    }

    fn erase_word(&mut self) {
        let trimmed = self.line.trim_end();
        let word_start = trimmed
            .char_indices()
            .rev()
            .find(|(_, c)| c.is_whitespace())
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(0);
        let n = self.line[word_start..].chars().count();
        self.erase(n);
    }

    fn take(&mut self) -> String {
        if self.menu_visible() {
            let (seq, _) = menu_sequence(self.menu_rows, &[]);
            write(&seq);
            self.menu_rows = 0;
        }
        self.menu_hidden = false;
        let line = std::mem::take(&mut self.line);
        match self.on_status() {
            Some(status) => status.set_input(None),
            None => write("\r\n"),
        }
        line
    }
}

/// Terminal output that shows `lines` below the cursor's row (which holds
/// the prompt), given that `old_rows` rows are already in use there, and
/// the number of rows in use afterwards. The cursor ends where it started.
/// Rows are reserved with IND (ESC D), which scrolls at the bottom of the
/// scroll region and keeps the column; the status line below the region is
/// never touched.
fn menu_sequence(old_rows: usize, lines: &[String]) -> (String, usize) {
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
    (seq, if lines.is_empty() { 0 } else { rows })
}

fn write(text: &str) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(text.as_bytes());
    let _ = out.flush();
}

/// What a key press produced.
pub enum Key {
    Line(String),
    Eof,
    Interrupt,
    ToggleThinking,
    /// A lone Esc press (not part of an escape sequence).
    Escape,
}

/// How long to wait after Esc for the rest of an escape sequence. Terminals
/// send sequences in one write, so a lone Esc is one with nothing following.
const ESCAPE_SEQUENCE_WAIT_MS: i32 = 30;

static ORIGINAL: OnceLock<libc::termios> = OnceLock::new();

fn get_termios() -> Option<libc::termios> {
    let mut termios: libc::termios = unsafe { std::mem::zeroed() };
    (unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut termios) } == 0).then_some(termios)
}

/// Put the terminal back the way it was (on exit or panic).
pub fn restore_terminal() {
    if let Some(original) = ORIGINAL.get() {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
    }
}

/// Key-by-key input while alive: no echo, no line buffering, and control
/// keys (Ctrl-C, Ctrl-O, which macOS would use to discard output) delivered
/// as bytes. Output processing is left on.
struct KeyMode;

impl KeyMode {
    fn enter() -> Option<Self> {
        let original = get_termios()?;
        let _ = ORIGINAL.set(original);
        let mut raw = *ORIGINAL.get().unwrap();
        raw.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN);
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        (unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } == 0).then_some(Self)
    }
}

impl Drop for KeyMode {
    fn drop(&mut self) {
        restore_terminal();
    }
}

/// Reads keys, carrying bytes that arrived past the end of a line (pastes)
/// into the next read.
#[derive(Default)]
pub struct LineReader {
    pending: std::collections::VecDeque<u8>,
    utf8: Vec<u8>,
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
            let Some(byte) = self.next_byte() else { return Key::Eof };
            let mut view = view.lock().unwrap();
            match byte {
                b'\r' | b'\n' => {
                    // Treat CR LF as one line end.
                    if byte == b'\r' && self.pending.front() == Some(&b'\n') {
                        self.pending.pop_front();
                    }
                    return Key::Line(view.take() + "\n");
                }
                0x03 => {
                    let n = view.line.chars().count();
                    view.erase(n);
                    drop(view);
                    send(Key::Interrupt);
                }
                0x04 if view.line.is_empty() => return Key::Eof,
                0x0f => {
                    drop(view);
                    send(Key::ToggleThinking);
                }
                0x7f | 0x08 => view.erase(1),
                0x15 => {
                    let n = view.line.chars().count();
                    view.erase(n);
                }
                0x17 => view.erase_word(),
                0x1b => {
                    let menu = view.menu_visible();
                    drop(view);
                    match self.byte_within(ESCAPE_SEQUENCE_WAIT_MS) {
                        // Skip escape sequences (arrow keys and the like).
                        Some(b'[' | b'O') => {
                            while let Some(b) = self.next_byte() {
                                if (0x40..=0x7e).contains(&b) {
                                    break;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn erase_word_handles_multibyte_spaces() {
        let view = EditView::shared(None);
        let mut view = view.lock().unwrap();
        view.mode = EditMode::Turn; // no status line: echoes, but must not panic
        view.line = "run a\u{a0}bé  ".into();
        view.erase_word();
        assert_eq!(view.line, "run a\u{a0}");
        view.erase_word();
        assert_eq!(view.line, "run ");
    }

    #[test]
    fn menu_rows_are_reserved_drawn_and_cleared() {
        let lines = vec!["a".to_string(), "b".to_string()];
        let (seq, rows) = menu_sequence(0, &lines);
        assert_eq!(rows, 2);
        assert_eq!(seq, "\x1bD\x1bD\x1b[2A\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2Kb\x1b8");
        // Narrowing reuses the rows and blanks the extra one.
        let (seq, rows) = menu_sequence(2, &lines[..1]);
        assert_eq!((seq.as_str(), rows), ("\x1b7\x1b[1B\r\x1b[2Ka\x1b[1B\r\x1b[2K\x1b8", 2));
        let (seq, rows) = menu_sequence(2, &[]);
        assert_eq!((seq.as_str(), rows), ("\x1b7\x1b[1B\r\x1b[2K\x1b[1B\r\x1b[2K\x1b8", 0));
        assert_eq!(menu_sequence(0, &[]), (String::new(), 0));
    }

    #[test]
    fn tab_completes_commands_and_is_a_space_elsewhere() {
        let view = EditView::shared(None);
        let mut view = view.lock().unwrap();
        view.mode = EditMode::Turn; // not drawn: no terminal in tests
        view.line = "/comp".into();
        view.tab();
        assert_eq!(view.line, "/compact ");
        view.line = "/s".into();
        view.tab();
        assert_eq!(view.line, "/s", "ambiguous: unchanged");
        view.line = "fix it".into();
        view.tab();
        assert_eq!(view.line, "fix it ");
    }
}
