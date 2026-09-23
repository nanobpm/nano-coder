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
}

pub type SharedView = Arc<Mutex<EditView>>;

impl EditView {
    pub fn shared(status: Option<Arc<StatusLine>>) -> SharedView {
        Arc::new(Mutex::new(Self { line: String::new(), mode: EditMode::Prompt, status }))
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
        let line = std::mem::take(&mut self.line);
        match self.on_status() {
            Some(status) => status.set_input(None),
            None => write("\r\n"),
        }
        line
    }
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
                b'\t' => view.insert(" "),
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
}
