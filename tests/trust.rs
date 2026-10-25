//! End-to-end checks of the per-project trust gate: in a repository that ships
//! a workspace skill or a project hook, an untrusted non-interactive start does
//! not load it (and says so on stderr), while `--yolo` and a remembered root do.
//!
//! Most cases run the real binary with piped stdin (a non-interactive start),
//! so no TTY is needed: the skill index is built locally and printed by
//! `/skills`, and a marker-writing project hook proves whether gated commands
//! actually executed. The interactive accept/deny of the trust question is
//! exercised under a PTY (`interactive_*` tests).
//!
//! Every subprocess is isolated from the developer's own environment: it runs
//! with a test-owned `--config` (mock provider, no persistence, no user-level
//! resources) and scratch `HOME` / `XDG_*` directories, so an installed user
//! skill, a skills-disabling config, or a real provider/session can never leak
//! into a fixture and break an assertion.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// A temp git repo plus the isolated environment every subprocess runs in.
struct Repo {
    dir: tempfile::TempDir,
    /// Scratch home/config/data/cache roots, kept alive for the fixture.
    env: tempfile::TempDir,
    trust_file: PathBuf,
    config: PathBuf,
}

impl Repo {
    /// An empty repository (no skills, no hooks).
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let env = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert!(Command::new("git").arg("init").arg("-q").current_dir(root).status().unwrap().success(), "git init");
        let trust_file = env.path().join("trusted-projects");
        let config = env.path().join("config.toml");
        // A test-owned config: the mock provider (no real network/auth),
        // persistence off (no session is written outside the fixture), and no
        // user-level skill/instruction/rules sources (so nothing installed for
        // the developer leaks in). Workspace skill dirs stay at their defaults
        // so the fixture's `.claude/skills` is still discovered.
        std::fs::write(
            &config,
            "persist_sessions = false\nmemory = \"off\"\nproject_instructions = false\n\
             user_instruction_files = []\nuser_rules_dirs = []\n\
             [skills]\nuser_dirs = []\nfetch = false\n",
        )
        .unwrap();
        Repo { dir, env, trust_file, config }
    }

    /// Add one `.claude/skills/x` workspace skill.
    fn with_skill(self) -> Self {
        let skill = self.dir.path().join(".claude/skills/x");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "---\nname: x\ndescription: demo skill\n---\n# x\n").unwrap();
        self
    }

    /// Add a project `.claude/settings.json` hook on `UserPromptSubmit` that
    /// appends to the fixture's marker file when (and only when) the hook
    /// actually executes. Returns the marker path.
    fn with_marker_hook(self) -> (Self, PathBuf) {
        let marker = self.env.path().join("hook-ran");
        let claude = self.dir.path().join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        let settings = format!(
            r#"{{"hooks":{{"UserPromptSubmit":[{{"hooks":[{{"type":"command","command":"echo ran >> {}"}}]}}]}}}}"#,
            marker.display()
        );
        std::fs::write(claude.join("settings.json"), settings).unwrap();
        (self, marker)
    }

    /// The repository's canonical root (what the trust file records).
    fn root(&self) -> PathBuf {
        self.dir.path().canonicalize().unwrap()
    }

    /// A command for `nano-coder <extra_args>` run from the repo, fully
    /// isolated from the developer's home, config, data and cache.
    fn command(&self, extra_args: &[&str]) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nano-coder"));
        cmd.current_dir(self.dir.path())
            .env("NANO_CODER_TRUST_FILE", &self.trust_file)
            // Isolate every directory the binary might read or write.
            .env("HOME", self.env.path())
            .env("XDG_CONFIG_HOME", self.env.path().join("config"))
            .env("XDG_DATA_HOME", self.env.path().join("data"))
            .env("XDG_CACHE_HOME", self.env.path().join("cache"))
            .env("SPM_HOME", self.env.path().join("spm"))
            .arg("--config")
            .arg(&self.config)
            .arg("--sandbox")
            .arg("off")
            .args(extra_args);
        cmd
    }

    /// Run `nano-coder <extra_args>` with `input` piped to stdin (a
    /// non-interactive start), returning `(stdout, stderr)`.
    fn run(&self, extra_args: &[&str], input: &str) -> (String, String) {
        let mut cmd = self.command(extra_args);
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().expect("spawn nano-coder");
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        let out = child.wait_with_output().expect("wait");
        (String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    }

    /// Run `nano-coder <extra_args>` with `/skills` piped in.
    fn run_skills(&self, extra_args: &[&str]) -> (String, String) {
        self.run(extra_args, "/skills\n")
    }
}

#[test]
fn untrusted_non_interactive_does_not_load_skills() {
    let repo = Repo::new().with_skill();
    let (stdout, stderr) = repo.run_skills(&[]);
    assert!(stdout.contains("No skills found"), "skill must be gated when untrusted:\n{stdout}");
    assert!(!stdout.contains("demo skill"), "the gated skill must not appear:\n{stdout}");
    assert!(
        stderr.contains("not loading skills or hooks from untrusted"),
        "a one-line stderr note is expected:\n{stderr}"
    );
    assert!(stderr.contains("--yolo"), "the note points at --yolo:\n{stderr}");
    assert!(!repo.trust_file.exists(), "a non-interactive start never records trust");
}

#[test]
fn yolo_loads_skills_without_a_note() {
    let repo = Repo::new().with_skill();
    let (stdout, stderr) = repo.run_skills(&["--yolo"]);
    assert!(stdout.contains("demo skill"), "--yolo loads the workspace skill:\n{stdout}");
    assert!(!stderr.contains("not loading skills or hooks"), "no untrusted note with --yolo:\n{stderr}");
    assert!(!repo.trust_file.exists(), "--yolo does not record trust");
}

#[test]
fn remembered_root_loads_skills() {
    let repo = Repo::new().with_skill();
    std::fs::write(&repo.trust_file, format!("{}\n", repo.root().display())).unwrap();
    let (stdout, stderr) = repo.run_skills(&[]);
    assert!(stdout.contains("demo skill"), "a remembered root loads its skills:\n{stdout}");
    assert!(!stderr.contains("not loading skills or hooks"), "no note for a remembered root:\n{stderr}");
}

#[test]
fn untrusted_non_interactive_does_not_run_project_hooks() {
    // The command-execution boundary: a project hook must not run when trust is
    // withheld. A real prompt (not a slash command) fires UserPromptSubmit.
    let (repo, marker) = Repo::new().with_marker_hook();
    let (_stdout, stderr) = repo.run(&[], "hi\n");
    assert!(stderr.contains("not loading skills or hooks from untrusted"), "the untrusted note is expected:\n{stderr}");
    assert!(!marker.exists(), "the project hook must not execute when untrusted");
}

#[test]
fn yolo_runs_project_hooks() {
    let (repo, marker) = Repo::new().with_marker_hook();
    let (_stdout, stderr) = repo.run(&["--yolo"], "hi\n");
    assert!(!stderr.contains("not loading skills or hooks"), "no untrusted note with --yolo:\n{stderr}");
    assert!(marker.exists(), "--yolo lets the project hook execute");
}

#[test]
fn remembered_root_runs_project_hooks() {
    let (repo, marker) = Repo::new().with_marker_hook();
    std::fs::write(&repo.trust_file, format!("{}\n", repo.root().display())).unwrap();
    let (_stdout, _stderr) = repo.run(&[], "hi\n");
    assert!(marker.exists(), "a remembered root lets the project hook execute");
}

#[test]
fn help_documents_yolo_and_the_trust_question() {
    let out = Command::new(env!("CARGO_BIN_EXE_nano-coder")).arg("--help").output().expect("run --help");
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("--yolo"), "usage mentions --yolo:\n{text}");
    assert!(text.contains("Trust this repo?"), "usage mentions the trust question:\n{text}");
}

/// Interactive trust-question coverage, driving the real terminal prompt
/// through a PTY (Unix-only: the trust prompt reads the controlling terminal).
///
/// The fixture carries both a workspace skill and a marker-writing project
/// hook, so a single run shows the whole gated surface: answering `n` loads
/// nothing and runs no command; answering `y` loads the skill, runs the hook,
/// and remembers the root.
#[cfg(unix)]
mod interactive {
    use super::*;
    use portable_pty::{CommandBuilder, PtySize, native_pty_system};
    use std::io::Read;
    use std::time::{Duration, Instant};

    /// Spawn `nano-coder` in the repo on a PTY, wait for the trust question,
    /// type `answer`, then drive one prompt (`hi`) so the project hook would
    /// fire, and `/exit` to quit. Returns everything the terminal showed.
    fn run_on_pty(repo: &Repo, answer: &str) -> String {
        let pty = native_pty_system()
            .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .expect("open pty");
        let mut cmd = CommandBuilder::new(env!("CARGO_BIN_EXE_nano-coder"));
        cmd.cwd(repo.dir.path());
        cmd.env("NANO_CODER_TRUST_FILE", &repo.trust_file);
        cmd.env("HOME", repo.env.path());
        cmd.env("XDG_CONFIG_HOME", repo.env.path().join("config"));
        cmd.env("XDG_DATA_HOME", repo.env.path().join("data"));
        cmd.env("XDG_CACHE_HOME", repo.env.path().join("cache"));
        cmd.env("SPM_HOME", repo.env.path().join("spm"));
        cmd.env("TERM", "xterm");
        cmd.arg("--config");
        cmd.arg(&repo.config);
        cmd.arg("--sandbox");
        cmd.arg("off");
        let mut child = pty.slave.spawn_command(cmd).expect("spawn nano-coder on pty");
        drop(pty.slave);

        let mut reader = pty.master.try_clone_reader().expect("pty reader");
        let mut writer = pty.master.take_writer().expect("pty writer");
        let mut screen = String::new();
        let mut buf = [0u8; 8192];

        // Read until `needle` appears on screen (or the deadline passes). The
        // read is capped at 8 KiB so a quiet child cannot leave it parked
        // mid-buffer past the deadline.
        let mut read_until = |needle: &str, screen: &mut String| -> bool {
            let deadline = Instant::now() + Duration::from_secs(30);
            while Instant::now() < deadline {
                if screen.contains(needle) {
                    return true;
                }
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => screen.push_str(&String::from_utf8_lossy(&buf[..n])),
                    Err(_) => break,
                }
            }
            screen.contains(needle)
        };

        // The trust question gates startup; answer it, then run a prompt.
        let saw_question = read_until("Load its skills and hooks?", &mut screen);
        assert!(saw_question, "trust question appeared:\n{screen}");
        write!(writer, "{answer}\r").unwrap();
        writer.flush().unwrap();
        // Wait for the prompt to be ready, then send a real prompt (fires the
        // project hook if trusted) and exit.
        let saw_ready = read_until("Type /help for commands", &mut screen);
        assert!(saw_ready, "startup completed:\n{screen}");
        write!(writer, "hi\r").unwrap();
        writer.flush().unwrap();
        // Give the turn a moment, then quit.
        std::thread::sleep(Duration::from_millis(500));
        write!(writer, "/exit\r").unwrap();
        writer.flush().unwrap();
        let _ = read_until("nano-coder", &mut screen);
        // Reap the child, but never block the test on a stuck process.
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                Err(_) => break,
            }
        }
        screen
    }

    #[test]
    fn interactive_denial_loads_nothing_and_runs_no_hook() {
        let (repo, marker) = Repo::new().with_skill().with_marker_hook();
        let screen = run_on_pty(&repo, "n");
        assert!(screen.contains("Trust this repo?"), "the question is asked:\n{screen}");
        assert!(!marker.exists(), "denial keeps the project hook from running");
        assert!(!repo.trust_file.exists(), "a denial is not remembered");
    }

    #[test]
    fn interactive_acceptance_loads_skills_and_runs_hook() {
        let (repo, marker) = Repo::new().with_skill().with_marker_hook();
        let screen = run_on_pty(&repo, "y");
        assert!(screen.contains("Trust this repo?"), "the question is asked:\n{screen}");
        assert!(marker.exists(), "acceptance lets the project hook run");
        let recorded = std::fs::read_to_string(&repo.trust_file).expect("acceptance is remembered");
        assert!(recorded.lines().any(|l| l == repo.root().to_string_lossy()), "the root is recorded:\n{recorded}");
    }
}
