//! End-to-end checks of the per-project trust gate: in a repository that ships
//! a workspace skill, an untrusted non-interactive start does not load it (and
//! says so on stderr), while `--yolo` and a remembered root do.
//!
//! These run the real binary with piped stdin (a non-interactive start) and a
//! single `/skills` command, so no provider or TTY is needed: the skill index
//! is built locally and printed by `/skills`.

use std::io::Write;
use std::process::{Command, Stdio};

/// A temp git repo carrying one `.claude/skills/x` skill, plus a (missing)
/// trusted-projects file path.
struct Repo {
    dir: tempfile::TempDir,
    trust_file: std::path::PathBuf,
}

impl Repo {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert!(Command::new("git").arg("init").arg("-q").current_dir(root).status().unwrap().success(), "git init");
        let skill = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "---\nname: x\ndescription: demo skill\n---\n# x\n").unwrap();
        let trust_file = dir.path().join("trusted-projects");
        Repo { dir, trust_file }
    }

    /// The repository's canonical root (what the trust file records).
    fn root(&self) -> std::path::PathBuf {
        self.dir.path().canonicalize().unwrap()
    }

    /// Run `nano-coder <extra_args>` with `/skills` piped in, from the repo.
    fn run_skills(&self, extra_args: &[&str]) -> (String, String) {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nano-coder"));
        cmd.current_dir(self.dir.path())
            .env("NANO_CODER_TRUST_FILE", &self.trust_file)
            .arg("--sandbox")
            .arg("off")
            .args(extra_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().expect("spawn nano-coder");
        child.stdin.take().unwrap().write_all(b"/skills\n").unwrap();
        let out = child.wait_with_output().expect("wait");
        (String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    }
}

#[test]
fn untrusted_non_interactive_does_not_load_skills() {
    let repo = Repo::new();
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
    let repo = Repo::new();
    let (stdout, stderr) = repo.run_skills(&["--yolo"]);
    assert!(stdout.contains("demo skill"), "--yolo loads the workspace skill:\n{stdout}");
    assert!(!stderr.contains("not loading skills or hooks"), "no untrusted note with --yolo:\n{stderr}");
    assert!(!repo.trust_file.exists(), "--yolo does not record trust");
}

#[test]
fn remembered_root_loads_skills() {
    let repo = Repo::new();
    std::fs::write(&repo.trust_file, format!("{}\n", repo.root().display())).unwrap();
    let (stdout, stderr) = repo.run_skills(&[]);
    assert!(stdout.contains("demo skill"), "a remembered root loads its skills:\n{stdout}");
    assert!(!stderr.contains("not loading skills or hooks"), "no note for a remembered root:\n{stderr}");
}

#[test]
fn help_documents_yolo_and_the_trust_question() {
    let out = Command::new(env!("CARGO_BIN_EXE_nano-coder")).arg("--help").output().expect("run --help");
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("--yolo"), "usage mentions --yolo:\n{text}");
    assert!(text.contains("Trust this repo?"), "usage mentions the trust question:\n{text}");
}
