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
