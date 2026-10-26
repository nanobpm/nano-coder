//! PTY smoke test for the session timers (issue #150): drive the real binary
//! on a pseudo-terminal and check that a timer the mock agent sets appears in
//! `/timers` and the status line, that a half-typed draft holds it back, and
//! that it fires once the draft is cleared.
//!
//! Needs a Unix PTY (`libc::openpty`); skipped elsewhere.

#![cfg(unix)]

use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A running nano-coder on a PTY, with everything it has printed so far.
struct Pty {
    master: OwnedFd,
    child: Child,
    out: Arc<Mutex<Vec<u8>>>,
}

impl Pty {
    fn spawn(args: &[&str]) -> Self {
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        let mut termios: libc::termios = unsafe { std::mem::zeroed() };
        unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut termios) };
        // A sane fallback when the test itself runs off a terminal.
        if termios.c_iflag == 0 {
            termios = unsafe { std::mem::zeroed() };
            termios.c_iflag = libc::ICRNL | libc::IXON;
            termios.c_oflag = libc::OPOST | libc::ONLCR;
            termios.c_cflag = libc::CS8 | libc::CREAD;
            termios.c_lflag = libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN;
            termios.c_cc[libc::VMIN] = 1;
            termios.c_cc[libc::VTIME] = 0;
        }
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        size.ws_row = 24;
        size.ws_col = 100;
        if unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), &termios, &size) } != 0 {
            panic!("openpty failed");
        }
        let master_fd = unsafe { OwnedFd::from_raw_fd(master) };

        // Each stdio slot needs its own descriptor: dup the slave twice so
        // stdin/stdout/stderr each own one, and the original slave closes on
        // spawn.
        let slave_out = unsafe { libc::dup(slave) };
        let slave_err = unsafe { libc::dup(slave) };
        assert!(slave_out >= 0 && slave_err >= 0, "dup the slave fd");
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nano-coder"));
        cmd.args(args)
            .env("TERM", "xterm-256color")
            .env("NO_COLOR", "1")
            .stdin(unsafe { Stdio::from_raw_fd(slave) })
            .stdout(unsafe { Stdio::from_raw_fd(slave_out) })
            .stderr(unsafe { Stdio::from_raw_fd(slave_err) });
        let child = cmd.spawn().expect("spawn nano-coder");

        // Drain the master in the background so the child never blocks on a
        // full PTY buffer. The thread owns a *dup* of the master; `Pty` keeps
        // the original for writes.
        let out = Arc::new(Mutex::new(Vec::new()));
        let sink = out.clone();
        let reader = unsafe { libc::dup(master_fd.as_raw_fd()) };
        assert!(reader >= 0, "dup the master fd");
        std::thread::spawn(move || {
            let mut file = unsafe { std::fs::File::from_raw_fd(reader) };
            let mut buf = [0u8; 4096];
            loop {
                match file.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => sink.lock().unwrap().extend_from_slice(&buf[..n]),
                }
            }
        });
        Self { master: master_fd, child, out }
    }

    fn send(&self, text: &str) {
        // Borrow the master fd without taking ownership (it stays open).
        let mut file = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(self.master.as_raw_fd()) });
        file.write_all(text.as_bytes()).expect("write to PTY");
        file.flush().expect("flush PTY");
    }

    fn screen(&self) -> String {
        let bytes = self.out.lock().unwrap().clone();
        let mut parser = vt100::Parser::new(200, 100, 0);
        parser.process(&bytes);
        parser.screen().contents()
    }

    /// Wait until the screen contains `needle` (or fail after `timeout`).
    fn wait_for(&self, needle: &str, timeout: Duration) -> String {
        let start = Instant::now();
        loop {
            let screen = self.screen();
            if screen.contains(needle) {
                return screen;
            }
            if start.elapsed() > timeout {
                panic!("timed out waiting for {needle:?}; screen so far:\n{screen}");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A config that keeps the smoke test hermetic: its own session dir, the mock
/// provider, no hooks or instructions.
fn config(dir: &std::path::Path) -> std::path::PathBuf {
    let path = dir.join("config.toml");
    std::fs::write(
        &path,
        format!(
            r#"
model = "mock/test"
session_dir = "{}"
project_instructions = false
persist_sessions = true
disable_hooks = true
timestamps = false
"#,
            dir.join("sessions").display()
        ),
    )
    .unwrap();
    path
}

#[test]
fn a_timer_appears_in_timers_and_the_status_line_and_fires_mid_turn() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    let pty = Pty::spawn(&["--model", "mock/test", "--config", config.to_str().unwrap()]);

    // The prompt is up (frame renderer draws the status bar).
    pty.wait_for("mock/test", Duration::from_secs(15));

    // The mock agent sets a one-minute timer and then sleeps 75s, so the turn
    // is still running when the timer comes due.
    pty.send("set a timer to check CI and wait\n");
    let screen = pty.wait_for("set for", Duration::from_secs(20));
    assert!(screen.contains("Timer 1 set for"), "{screen}");

    // `/timers` (available mid-turn) lists it, and the status line shows ⏰.
    pty.send("/timers\n");
    let screen = pty.wait_for("1. ", Duration::from_secs(10));
    assert!(screen.contains("check CI"), "{screen}");
    assert!(screen.contains("⏰"), "status line shows the timer: {screen}");

    // The turn is still working (the mock's sleep) when the timer comes due
    // at the 1-minute mark: it fires mid-turn, its note shown with ⏰.
    let screen = pty.wait_for("⏰ timer 1: check CI", Duration::from_secs(75));
    assert!(screen.contains("fired: check CI") || screen.contains("⏰ timer 1: check CI"), "{screen}");
}

/// Concatenated contents of every persisted session log under `dir/sessions`.
fn session_logs(dir: &std::path::Path) -> String {
    let sessions = dir.join("sessions");
    let mut all = String::new();
    if let Ok(entries) = std::fs::read_dir(&sessions) {
        for entry in entries.flatten() {
            if entry.path().extension().is_some_and(|e| e == "jsonl")
                && let Ok(body) = std::fs::read_to_string(entry.path())
            {
                all.push_str(&body);
            }
        }
    }
    all
}

/// Every persisted session record (one parsed JSONL line) under `dir/sessions`.
fn session_records(dir: &std::path::Path) -> Vec<serde_json::Value> {
    session_logs(dir)
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .collect()
}

/// How many *user-message* records carry `needle` — the authoritative
/// per-delivery firing count. A single idle delivery also writes the firing
/// into the `Record::Input` echo (and the UI note prints it before either),
/// so a raw substring count over-counts; only the parsed user `Record::Message`
/// is one-per-delivery.
fn user_message_firings(records: &[serde_json::Value], needle: &str) -> usize {
    records
        .iter()
        .filter(|r| r["type"] == "message" && r["data"]["role"] == "user")
        .filter(|r| r["data"].to_string().contains(needle))
        .count()
}

/// Whether the firing's automatic turn has fully ended: a `turn_end` record
/// appears *after* the user-message firing. Delivery writes `Input`, then the
/// user `Message`, then `TurnEnd`, so this guarantees every record of that turn
/// is on disk before the count is read (the UI note races ahead of all three).
fn fired_turn_complete(records: &[serde_json::Value], needle: &str) -> bool {
    let Some(fired_at) = records.iter().position(|r| {
        r["type"] == "message" && r["data"]["role"] == "user" && r["data"].to_string().contains(needle)
    }) else {
        return false;
    };
    records[fired_at + 1..].iter().any(|r| r["type"] == "turn_end")
}

#[test]
fn a_half_typed_draft_holds_an_idle_timer_back_until_it_is_cleared() {
    // Draft protection (issue #150): unlike the mid-turn scenario above, this
    // leaves the prompt idle with a half-typed draft across the deadline, so a
    // regression that fired into a half-typed line — or skipped idle delivery
    // entirely — would be caught here.
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    let pty = Pty::spawn(&["--model", "mock/test", "--config", config.to_str().unwrap()]);

    pty.wait_for("mock/test", Duration::from_secs(15));

    // Set a one-minute timer WITHOUT the mock's wait, so the turn ends and the
    // prompt goes idle well before the deadline.
    pty.send("set a timer\n");
    let screen = pty.wait_for("Timer 1 set for", Duration::from_secs(20));
    assert!(screen.contains("Timer 1 set for"), "{screen}");

    // Leave a half-typed draft (no Enter). An idle timer coming due must be
    // held back while a draft is in the editor, never firing into it.
    pty.send("a half-typed note");
    // Wait past the one-minute deadline; the timer must NOT fire while held.
    std::thread::sleep(Duration::from_secs(70));
    let screen = pty.screen();
    assert!(
        !screen.contains("⏰ timer 1") && !screen.contains("fired: check CI"),
        "a held draft must hold the timer back: {screen}"
    );
    assert!(
        !session_logs(dir.path()).contains("fired: check CI"),
        "no firing was persisted while the draft was held"
    );

    // Clear the draft (Ctrl-U, 0x15). The now-overdue timer fires.
    pty.send("\u{15}");
    let screen = pty.wait_for("⏰ timer 1: check CI", Duration::from_secs(15));
    assert!(screen.contains("fired: check CI") || screen.contains("⏰ timer 1: check CI"), "{screen}");

    // The UI note above is printed *before* the delivery's records are written,
    // so counting immediately races. Wait for the automatic turn to fully end —
    // its `TurnEnd` persisted after the firing — before reading the count.
    let deadline = Instant::now() + Duration::from_secs(15);
    while !fired_turn_complete(&session_records(dir.path()), "fired: check CI") {
        assert!(
            Instant::now() < deadline,
            "the timer firing's automatic turn never completed in the session log:\n{}",
            session_logs(dir.path())
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // Exactly once: a single *user-message* firing is persisted, so clearing the
    // draft neither double-delivers nor re-arms the timer. (The firing text also
    // lands in the `Input` echo and the UI note, so only the parsed user message
    // is a sound per-delivery count.)
    let fires = user_message_firings(&session_records(dir.path()), "fired: check CI");
    assert_eq!(fires, 1, "the held timer fires exactly once after the draft clears");
}

#[test]
fn a_stale_ctrl_c_exit_hint_clears_itself_while_a_timer_is_pending() {
    // Regression (issue #150): after the first Ctrl-C with an active timer,
    // control returns to the pre-prompt timer wait. That wait must bound itself
    // by the Ctrl-C exit window and clear the hint when it lapses — not sleep
    // until the (up to a minute away) timer, leaving "(Ctrl-C again to exit)"
    // stranded on the status bar long after a second press would only re-arm.
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    let pty = Pty::spawn(&["--model", "mock/test", "--config", config.to_str().unwrap()]);

    pty.wait_for("mock/test", Duration::from_secs(15));

    // Set a one-minute timer WITHOUT the mock's wait, so the turn ends and the
    // prompt idles in the pre-prompt timer wait with a pending timer.
    pty.send("set a timer\n");
    let screen = pty.wait_for("Timer 1 set for", Duration::from_secs(20));
    assert!(screen.contains("Timer 1 set for"), "{screen}");

    // One Ctrl-C (0x03) on the empty prompt arms the exit hint rather than
    // exiting (the double-press-to-exit gesture).
    pty.send("\u{3}");
    pty.wait_for("Ctrl-C again to exit", Duration::from_secs(10));

    // The exit window is 2s; well past it (and well short of the timer) the hint
    // must be gone. Without the bound the pre-prompt wait would sleep ~a minute
    // and the hint would linger here.
    std::thread::sleep(Duration::from_secs(5));
    let screen = pty.screen();
    assert!(
        !screen.contains("Ctrl-C again to exit"),
        "the stale exit hint must clear once the window lapses, not linger until the timer: {screen}"
    );
    // The timer is still pending and never fired — only the hint cleared.
    assert!(
        !session_logs(dir.path()).contains("fired: check CI"),
        "the pending timer must not have fired while we only waited out the exit window"
    );
}
