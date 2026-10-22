//! Herdr integration (<https://herdr.dev/docs/add-herdr-support/>).
//!
//! When nano-coder runs inside a Herdr pane it reports its state (idle,
//! working, blocked), the command that resumes the current session, and a
//! release on exit, by running `"$HERDR_BIN_PATH" pane report-agent …`.
//! Outside Herdr every call here is a no-op.
//!
//! Reports never slow the agent down: they are handed to one background
//! thread that sends only the latest pending report and ignores failures.

use std::process::{Command, Stdio};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SOURCE: &str = "nano-coder";
const AGENT: &str = "nano-coder";
/// How long one report may run before it is abandoned.
const TIMEOUT: Duration = Duration::from_secs(2);
/// Herdr's limits on a resume command.
const MAX_RESUME_ARGS: usize = 64;
const MAX_RESUME_BYTES: usize = 8 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Working,
    Blocked,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Working => "working",
            State::Blocked => "blocked",
        }
    }
}

/// The pane this process reports to, from Herdr's environment.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Pane {
    bin: String,
    id: String,
}

impl Pane {
    fn from_env(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        if get("HERDR_ENV").as_deref() != Some("1") {
            return None;
        }
        let bin = get("HERDR_BIN_PATH").filter(|v| !v.is_empty())?;
        let id = get("HERDR_PANE_ID").filter(|v| !v.is_empty())?;
        Some(Pane { bin, id })
    }
}

/// A session to report alongside a state: its ID and the argv that resumes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Session {
    pub id: String,
    pub resume: Vec<String>,
}

/// Build the resume argv for `session_id`, or `None` when Herdr would reject
/// it (apostrophes or control characters, too many arguments or bytes).
pub fn resume_argv(session_id: &str, model: Option<&str>, extra: &[String]) -> Option<Vec<String>> {
    let mut argv = vec![AGENT.to_string(), "--resume".into(), session_id.to_string()];
    if let Some(model) = model.filter(|m| !m.is_empty()) {
        argv.push("--model".into());
        argv.push(model.to_string());
    }
    argv.extend(extra.iter().cloned());
    let valid = argv.len() <= MAX_RESUME_ARGS
        && argv.iter().map(String::len).sum::<usize>() <= MAX_RESUME_BYTES
        && argv.iter().all(|a| !a.contains('\'') && !a.chars().any(char::is_control));
    valid.then_some(argv)
}

/// The arguments (after the Herdr binary) for one state report.
fn report_args(pane: &str, state: State, seq: u64, message: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> = ["pane", "report-agent", pane, "--source", SOURCE, "--agent", AGENT, "--state"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.push(state.as_str().into());
    args.push("--seq".into());
    args.push(seq.to_string());
    if let Some(message) = message.filter(|m| !m.is_empty()) {
        args.push("--message".into());
        args.push(message.chars().filter(|c| !c.is_control()).take(200).collect());
    }
    args
}

/// The arguments for a session report. Sent separately from the state report
/// because Herdr before 0.9.2 rejects the trailing resume argv: there only
/// this call fails, and state reports keep working.
fn session_args(pane: &str, seq: u64, session: &Session) -> Vec<String> {
    let mut args: Vec<String> = ["pane", "report-agent-session", pane, "--source", SOURCE, "--agent", AGENT, "--seq"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.push(seq.to_string());
    args.push("--agent-session-id".into());
    args.push(session.id.clone());
    args.push("--".into());
    args.extend(session.resume.iter().cloned());
    args
}

fn release_args(pane: &str, seq: u64) -> Vec<String> {
    ["pane", "release-agent", pane, "--source", SOURCE, "--agent", AGENT, "--seq"]
        .iter()
        .map(|s| s.to_string())
        .chain(std::iter::once(seq.to_string()))
        .collect()
}

/// A report waiting to be sent: sequence numbers for the state report and,
/// when the session changed, the session report that follows it.
struct Queued {
    state_seq: u64,
    state: State,
    message: Option<String>,
    session: Option<(u64, Session)>,
}

/// A state and its optional reason.
type StateReport = (State, Option<String>);

struct Reporter {
    pane: Pane,
    /// The newest report not yet sent, with its sequence number; older ones
    /// are overwritten. The number is taken when the report is queued, so a
    /// report still in flight at exit carries a lower one than the release
    /// and Herdr ignores it.
    pending: Mutex<Option<Queued>>,
    wake: Condvar,
    /// The last state and session handed over, so repeats are skipped.
    last: Mutex<(Option<StateReport>, Option<Session>)>,
    /// The last sequence number used; strictly increasing.
    seq: Mutex<u64>,
}

impl Reporter {
    /// A sequence number above every earlier one, including those from
    /// previous runs: microseconds since the epoch, bumped if the clock stalls.
    fn next_seq(&self) -> u64 {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0);
        let mut seq = self.seq.lock().unwrap_or_else(|e| e.into_inner());
        *seq = now.max(*seq + 1);
        *seq
    }

    fn worker(&'static self) {
        loop {
            let queued = {
                let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
                loop {
                    if let Some(next) = pending.take() {
                        break next;
                    }
                    pending = self.wake.wait(pending).unwrap_or_else(|e| e.into_inner());
                }
            };
            run(&self.pane.bin, &report_args(&self.pane.id, queued.state, queued.state_seq, queued.message.as_deref()));
            if let Some((seq, session)) = &queued.session {
                run(&self.pane.bin, &session_args(&self.pane.id, *seq, session));
            }
        }
    }
}

static REPORTER: OnceLock<Option<&'static Reporter>> = OnceLock::new();

fn reporter() -> Option<&'static Reporter> {
    *REPORTER.get_or_init(|| {
        let pane = Pane::from_env(|k| std::env::var(k).ok())?;
        let reporter: &'static Reporter = Box::leak(Box::new(Reporter {
            pane,
            pending: Mutex::new(None),
            wake: Condvar::new(),
            last: Mutex::new((None, None)),
            seq: Mutex::new(0),
        }));
        std::thread::Builder::new().name("herdr".into()).spawn(move || reporter.worker()).ok()?;
        Some(reporter)
    })
}

/// Whether nano-coder is running inside a Herdr pane.
pub fn active() -> bool {
    reporter().is_some()
}

/// Report `state` (with an optional reason) in the background, plus `session`
/// when it differs from the last one reported.
pub fn report(state: State, message: Option<&str>, session: Option<Session>) {
    let Some(reporter) = reporter() else { return };
    let current = (state, message.map(str::to_string));
    let mut pending = reporter.pending.lock().unwrap_or_else(|e| e.into_inner());
    let new_session = {
        let mut last = reporter.last.lock().unwrap_or_else(|e| e.into_inner());
        let new_session = session.filter(|s| last.1.as_ref() != Some(s));
        if last.0.as_ref() == Some(&current) && new_session.is_none() {
            return;
        }
        last.0 = Some(current.clone());
        if let Some(session) = &new_session {
            last.1 = Some(session.clone());
        }
        new_session
    };
    // A session not yet sent from an overwritten report must not be lost.
    let session = new_session.or_else(|| pending.take().and_then(|q| q.session.map(|(_, s)| s)));
    let state_seq = reporter.next_seq();
    let session = session.map(|s| (reporter.next_seq(), s));
    *pending = Some(Queued { state_seq, state: current.0, message: current.1, session });
    drop(pending);
    reporter.wake.notify_one();
}

/// Release the pane on exit. Runs in the foreground (bounded by a timeout) so
/// it is sent before the process ends; drops any report still pending.
pub fn release() {
    let Some(reporter) = reporter() else { return };
    let mut pending = reporter.pending.lock().unwrap_or_else(|e| e.into_inner());
    pending.take();
    let seq = reporter.next_seq();
    drop(pending);
    run(&reporter.pane.bin, &release_args(&reporter.pane.id, seq));
}

/// Run the Herdr CLI, ignoring its output and any failure, killing it after
/// [`TIMEOUT`].
fn run(bin: &str, args: &[String]) {
    let Ok(mut child) =
        Command::new(bin).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()
    else {
        return;
    };
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let vars: Vec<(String, String)> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |k| vars.iter().find(|(name, _)| name == k).map(|(_, v)| v.clone())
    }

    #[test]
    fn pane_needs_all_herdr_variables() {
        let full = [("HERDR_ENV", "1"), ("HERDR_BIN_PATH", "/bin/herdr"), ("HERDR_PANE_ID", "p1")];
        assert_eq!(Pane::from_env(env(&full)), Some(Pane { bin: "/bin/herdr".into(), id: "p1".into() }));
        assert_eq!(Pane::from_env(env(&full[1..])), None);
        assert_eq!(Pane::from_env(env(&[("HERDR_ENV", "0"), full[1], full[2]])), None);
        assert_eq!(Pane::from_env(env(&[full[0], full[1], ("HERDR_PANE_ID", "")])), None);
        assert_eq!(Pane::from_env(env(&[])), None);
    }

    #[test]
    fn state_report_args() {
        let args = report_args("p1", State::Working, 7, None);
        assert_eq!(
            args,
            [
                "pane",
                "report-agent",
                "p1",
                "--source",
                "nano-coder",
                "--agent",
                "nano-coder",
                "--state",
                "working",
                "--seq",
                "7"
            ]
        );
    }

    #[test]
    fn blocked_report_carries_a_clean_message() {
        let args = report_args("p1", State::Blocked, 1, Some("pick one\x1b[2J"));
        let at = args.iter().position(|a| a == "--message").unwrap();
        assert_eq!(args[at + 1], "pick one[2J");
    }

    #[test]
    fn session_report_puts_resume_argv_after_double_dash() {
        let session = Session { id: "s1".into(), resume: resume_argv("s1", Some("openai/gpt-5"), &[]).unwrap() };
        let args = session_args("p1", 2, &session);
        assert_eq!(&args[..2], ["pane", "report-agent-session"]);
        let dash = args.iter().position(|a| a == "--").unwrap();
        assert_eq!(&args[dash - 4..dash], ["--seq", "2", "--agent-session-id", "s1"]);
        assert_eq!(&args[dash + 1..], ["nano-coder", "--resume", "s1", "--model", "openai/gpt-5"]);
    }

    #[test]
    fn resume_argv_respects_herdr_rules() {
        assert_eq!(resume_argv("s1", None, &[]).unwrap(), ["nano-coder", "--resume", "s1"]);
        let extra = vec!["--config".to_string(), "/tmp/c.toml".to_string()];
        assert_eq!(
            resume_argv("s1", Some(""), &extra).unwrap(),
            ["nano-coder", "--resume", "s1", "--config", "/tmp/c.toml"]
        );
        assert_eq!(resume_argv("s1", Some("it's"), &[]), None);
        assert_eq!(resume_argv("s\n1", None, &[]), None);
        assert_eq!(resume_argv("s1", None, &vec!["x".to_string(); 62]), None);
        assert_eq!(resume_argv("s1", None, &["y".repeat(9000)]), None);
    }

    #[test]
    fn release_args_shape() {
        assert_eq!(
            release_args("p1", 3),
            ["pane", "release-agent", "p1", "--source", "nano-coder", "--agent", "nano-coder", "--seq", "3"]
        );
    }
}
