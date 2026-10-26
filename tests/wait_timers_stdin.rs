//! Regression test (PR #151): a piped `--wait-timers` run must not hang after
//! stdin closes.
//!
//! Piped stdin emits its end-of-input exactly once. The timer wait swallows
//! that EOF so it can keep sleeping for scheduled timers; the bug was that it
//! *discarded* the EOF, so once the timer fired and none remained the normal
//! prompt read blocked forever on a reader that never emits EOF again. The run
//! must instead exit once queued input and scheduled timers are both
//! exhausted.

use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// A hermetic config: own session dir, mock provider, no hooks or instructions.
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

#[test]
fn piped_wait_timers_run_exits_after_stdin_closes_and_the_timer_fires() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    // Pipe stdin (so the run is headless); send output to the null sink so a
    // full pipe buffer can never block the child. We only care that it exits.
    let mut child = Command::new(env!("CARGO_BIN_EXE_nano-coder"))
        .args(["--model", "mock/test", "--config", config.to_str().unwrap(), "--wait-timers"])
        .env("NO_COLOR", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nano-coder");

    // The mock sets a one-minute timer (the minimum) for this prompt. Close
    // stdin immediately by dropping the handle: under `--wait-timers` the run
    // keeps sleeping for the timer despite the closed stdin.
    {
        let mut stdin = child.stdin.take().expect("stdin");
        stdin.write_all(b"set a timer\n").expect("write prompt");
    }

    // The timer fires about a minute out; allow slack for the fire and its
    // follow-up turn, then require a clean exit. A hang (the bug) trips the
    // deadline and fails the test.
    let deadline = Instant::now() + Duration::from_secs(100);
    loop {
        if let Some(status) = child.try_wait().expect("poll child") {
            assert!(status.success(), "run exited unsuccessfully: {status}");
            // A clean exit alone is not enough: an immediate EOF exit (or the
            // timer tools silently going missing) would also exit successfully
            // without ever delivering the timer. Assert the persisted session
            // recorded the timer *firing* so this test fails if `--wait-timers`
            // stops actually waiting for and delivering the timer.
            let logs = session_logs(dir.path());
            assert!(
                logs.contains("fired: check CI"),
                "session must record timer 1 firing before exit; logs:\n{logs}"
            );
            return;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("piped --wait-timers run hung after stdin closed and the timer fired");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Issue #150: the first Ctrl-C exits a headless `--wait-timers` run. With
/// stdin held open there is no EOF to end the run, so only the SIGINT fix lets
/// it exit — well before the one-minute timer would fire.
#[cfg(unix)]
#[test]
fn headless_wait_timers_run_exits_on_the_first_interrupt() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    let mut child = Command::new(env!("CARGO_BIN_EXE_nano-coder"))
        .args(["--model", "mock/test", "--config", config.to_str().unwrap(), "--wait-timers"])
        .env("NO_COLOR", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nano-coder");

    // Set a one-minute timer but KEEP stdin open (the handle is held), so the
    // run cannot exit on EOF — it must exit because of the interrupt.
    let mut stdin = child.stdin.take().expect("stdin");
    stdin.write_all(b"set a timer\n").expect("write prompt");
    stdin.flush().expect("flush prompt");

    // Give the turn time to set the timer and enter the wait loop, then send
    // one SIGINT. The timer (one minute out) is nowhere near due.
    std::thread::sleep(Duration::from_secs(3));
    let pid = child.id() as libc::pid_t;
    assert_eq!(unsafe { libc::kill(pid, libc::SIGINT) }, 0, "deliver SIGINT");

    // The run must exit promptly on that single interrupt — long before the
    // timer's one-minute deadline. Without the fix it only shows the exit hint
    // and keeps waiting, so this deadline trips.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().expect("poll child").is_some() {
            drop(stdin);
            return;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("headless --wait-timers run did not exit on the first Ctrl-C");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Issue #150: a Ctrl-C that lands *during* a headless `--wait-timers` turn
/// exits the run, rather than cancelling only that turn and resuming the wait
/// on the remaining timer. The "set a timer … and wait" prompt makes the mock
/// set a one-minute timer and then run `sleep 75`, so the turn is still in
/// flight (in the tool call) when the SIGINT arrives.
#[cfg(unix)]
#[test]
fn headless_wait_timers_run_exits_on_an_interrupt_during_a_turn() {
    let dir = tempfile::tempdir().unwrap();
    let config = config(dir.path());
    let mut child = Command::new(env!("CARGO_BIN_EXE_nano-coder"))
        .args(["--model", "mock/test", "--config", config.to_str().unwrap(), "--wait-timers"])
        .env("NO_COLOR", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nano-coder");

    // Keep stdin open so there is no EOF to end the run; the only way out is
    // the interrupt. "and wait" makes the mock follow `timer_set` with a
    // 75-second `sleep`, so the turn is mid-tool-call when SIGINT lands.
    let mut stdin = child.stdin.take().expect("stdin");
    stdin.write_all(b"set a timer and wait\n").expect("write prompt");
    stdin.flush().expect("flush prompt");

    // Let the turn reach the long `sleep`, then interrupt it. The one-minute
    // timer is nowhere near due, so only propagating the in-flight interrupt
    // lets the run exit promptly. Five seconds gives a slow CI box time to set
    // the timer and enter the `sleep 75` tool call.
    std::thread::sleep(Duration::from_secs(5));
    let pid = child.id() as libc::pid_t;
    assert_eq!(unsafe { libc::kill(pid, libc::SIGINT) }, 0, "deliver SIGINT");

    // Without the fix the interrupt cancels the turn but the outer loop resumes
    // waiting on the timer, so the run outlives this deadline.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().expect("poll child").is_some() {
            drop(stdin);
            return;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("headless --wait-timers run did not exit on a Ctrl-C during a turn");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
