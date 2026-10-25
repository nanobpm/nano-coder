//! Per-project trust: ask before loading a cloned repository's skills and
//! hooks.
//!
//! A cloned repository can steer the agent before the user has decided to
//! trust it: workspace skills (`.agents/skills`, `.github/skills`,
//! `.claude/skills` and `ai.lock`-pinned skills) go into the system prompt and
//! `load_skill`, and `.claude/settings{,.local}.json` project hooks run shell
//! commands on agent events. This module gates exactly those resources behind a
//! per-project trust decision.
//!
//! The **trust root** is the canonical git root of the cwd (or the cwd when not
//! in a repository). The **gated resources** are the workspace skill
//! directories from `[skills].dirs`, `ai.lock`, and the project
//! `.claude/settings{,.local}.json` hooks. User-level skills and hooks, nano's
//! own `[hooks]`, and instruction files are never gated.
//!
//! The decision:
//! - a root already recorded in the trusted-projects file is trusted (even
//!   non-interactively, with no question);
//! - a root with nothing to gate is trusted (loading is a no-op);
//! - `--yolo` and `--acp` trust without asking;
//! - an interactive start asks, defaulting to no; a `yes` is remembered once;
//! - a non-interactive start (piped stdio, `-p`) leaves an untrusted root
//!   unloaded and prints one stderr note.
//!
//! The decision is made once per root per process, so `/restart` and hook
//! reloads do not re-ask.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use crate::skills::SkillsConfig;

/// Environment variable overriding the trusted-projects file (used by tests).
const TRUST_FILE_ENV: &str = "NANO_CODER_TRUST_FILE";
/// Name of the trusted-projects file under the config directory.
const TRUST_FILE_NAME: &str = "trusted-projects";
const LOCK_FILE: &str = "ai.lock";
const SKILL_FILE: &str = "SKILL.md";
/// How deep below a skills directory to look for a `SKILL.md` when deciding
/// whether a repository actually carries workspace skills.
const MAX_SCAN_DEPTH: usize = 4;

/// Inputs to the trust decision that do not come from the filesystem.
pub struct Options {
    /// `--yolo`: trust without asking (the pre-trust behaviour).
    pub yolo: bool,
    /// `--acp`: the ACP client owns the trust decision, so trust without asking.
    pub acp: bool,
    /// stdin and stdout are both terminals, so a human can answer.
    pub interactive: bool,
}

/// Which gated resources a repository carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Gated {
    /// Workspace skill directories or an `ai.lock` are present.
    pub skills: bool,
    /// A project `.claude/settings{,.local}.json` is present.
    pub hooks: bool,
}

impl Gated {
    /// Detect the gated resources under `root`.
    pub fn detect(root: &Path, skills: &SkillsConfig) -> Self {
        let skills_present = skills.enabled
            && ((skills.ai_lock && root.join(LOCK_FILE).is_file())
                || skills.dirs.iter().any(|dir| dir_has_skill(&root.join(dir))));
        let hooks_present =
            root.join(".claude/settings.json").is_file() || root.join(".claude/settings.local.json").is_file();
        Self { skills: skills_present, hooks: hooks_present }
    }

    /// Whether there is nothing to gate.
    pub fn is_empty(&self) -> bool {
        !self.skills && !self.hooks
    }

    /// The `<resources>` phrase for the trust question.
    fn describe(&self) -> &'static str {
        match (self.skills, self.hooks) {
            (true, true) => "skills and hooks",
            (true, false) => "skills",
            (false, true) => "hooks",
            (false, false) => "nothing",
        }
    }
}

/// The canonical trust root for `cwd`: its git root, or the cwd itself when not
/// inside a repository.
pub fn trust_root(cwd: &Path) -> PathBuf {
    let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
    let root = crate::instructions::git_root(&cwd).unwrap_or(cwd);
    root.canonicalize().unwrap_or(root)
}

/// Decide whether to load `cwd`'s gated skills and hooks, memoised per root for
/// the life of the process so `/restart` and hook reloads do not re-ask.
pub fn decide(cwd: &Path, skills: &SkillsConfig, opts: &Options) -> bool {
    let root = trust_root(cwd);
    static DECISIONS: LazyLock<Mutex<HashMap<PathBuf, bool>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
    if let Ok(cache) = DECISIONS.lock()
        && let Some(&prev) = cache.get(&root)
    {
        return prev;
    }
    let decision = decide_root(&root, skills, opts, trust_file().as_deref(), &mut StdinAsker);
    if let Ok(mut cache) = DECISIONS.lock() {
        cache.insert(root, decision);
    }
    decision
}

/// The testable core of [`decide`]: no process memoisation, an injected
/// trusted-projects file, and an injected question source.
fn decide_root(
    root: &Path,
    skills: &SkillsConfig,
    opts: &Options,
    trust_file: Option<&Path>,
    asker: &mut dyn Asker,
) -> bool {
    // A remembered root is trusted with no question, even non-interactively.
    if is_remembered(root, trust_file) {
        return true;
    }
    let gated = Gated::detect(root, skills);
    // Nothing to gate: loading is a no-op, so never ask.
    if gated.is_empty() {
        return true;
    }
    // `--yolo` / `--acp` trust without asking (and without remembering).
    if opts.yolo || opts.acp {
        return true;
    }
    // Non-interactive: do not load, and say so once on stderr.
    if !opts.interactive {
        asker.note(&format!(
            "not loading skills or hooks from untrusted {} (start interactively to trust it, or pass --yolo)",
            root.display()
        ));
        return false;
    }
    // Interactive: ask, defaulting to no. Remember a yes once.
    if asker.confirm(root, &gated) {
        remember(root, trust_file);
        true
    } else {
        false
    }
}

/// The source of the interactive answer and the non-interactive note, so the
/// decision core can be driven in tests.
trait Asker {
    /// Ask the trust question; `true` is a yes.
    fn confirm(&mut self, root: &Path, gated: &Gated) -> bool;
    /// Emit the one-line non-interactive note.
    fn note(&mut self, msg: &str);
}

/// The production [`Asker`]: the question goes to stderr (so it is visible even
/// when stdout is owned by the UI) and the answer is read from stdin.
struct StdinAsker;

impl Asker for StdinAsker {
    fn confirm(&mut self, root: &Path, gated: &Gated) -> bool {
        let mut err = std::io::stderr();
        let _ = writeln!(
            err,
            "Trust this repo? {} has {} that can run commands or steer the agent.",
            root.display(),
            gated.describe()
        );
        let _ = write!(err, "Load its skills and hooks? [y/N] ");
        let _ = err.flush();
        let mut line = String::new();
        match std::io::stdin().lock().read_line(&mut line) {
            Ok(0) | Err(_) => false, // EOF or error → no.
            Ok(_) => is_yes(&line),
        }
    }

    fn note(&mut self, msg: &str) {
        eprintln!("{msg}");
    }
}

/// Whether `answer` is an affirmative (`y`/`yes`, case- and
/// whitespace-insensitive). An empty answer is a no.
fn is_yes(answer: &str) -> bool {
    matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

/// Whether `dir` contains a `SKILL.md` within [`MAX_SCAN_DEPTH`], i.e. carries
/// at least one workspace skill.
fn dir_has_skill(dir: &Path) -> bool {
    fn scan(dir: &Path, depth: usize) -> bool {
        if dir.join(SKILL_FILE).is_file() {
            return true;
        }
        if depth >= MAX_SCAN_DEPTH {
            return false;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return false };
        entries.filter_map(|e| e.ok()).any(|e| e.path().is_dir() && scan(&e.path(), depth + 1))
    }
    dir.is_dir() && scan(dir, 0)
}

/// The trusted-projects file: `NANO_CODER_TRUST_FILE` if set, else
/// `$XDG_CONFIG_HOME/nano-coder/trusted-projects`, else
/// `~/.config/nano-coder/trusted-projects`.
fn trust_file() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(TRUST_FILE_ENV).filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| dirs::home_dir().map(|h| h.join(".config")))?;
    Some(base.join(crate::config::APP_NAME).join(TRUST_FILE_NAME))
}

/// Whether `root` is recorded in the trusted-projects file.
fn is_remembered(root: &Path, trust_file: Option<&Path>) -> bool {
    let Some(file) = trust_file else { return false };
    let Ok(text) = std::fs::read_to_string(file) else { return false };
    let root = root.to_string_lossy();
    text.lines().map(str::trim).any(|line| !line.is_empty() && line == root)
}

/// Append `root` to the trusted-projects file (idempotently).
fn remember(root: &Path, trust_file: Option<&Path>) {
    let Some(file) = trust_file else { return };
    if is_remembered(root, Some(file)) {
        return;
    }
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(file) {
        let _ = writeln!(f, "{}", root.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An [`Asker`] that replays a scripted answer and records whether it was
    /// asked or noted.
    struct ScriptedAsker {
        answer: Option<&'static str>,
        asked: bool,
        noted: Option<String>,
    }

    impl ScriptedAsker {
        fn yes() -> Self {
            Self { answer: Some("y"), asked: false, noted: None }
        }
        fn with(answer: Option<&'static str>) -> Self {
            Self { answer, asked: false, noted: None }
        }
    }

    impl Asker for ScriptedAsker {
        fn confirm(&mut self, _root: &Path, _gated: &Gated) -> bool {
            self.asked = true;
            self.answer.map(is_yes).unwrap_or(false)
        }
        fn note(&mut self, msg: &str) {
            self.noted = Some(msg.to_string());
        }
    }

    fn skills_cfg() -> SkillsConfig {
        SkillsConfig::default()
    }

    /// A temp repo plus a trust-file path (not yet created).
    fn repo_with_hook() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".claude")).unwrap();
        std::fs::write(
            root.join(".claude/settings.json"),
            r#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#,
        )
        .unwrap();
        let trust = dir.path().join("trusted-projects");
        (dir, root, trust)
    }

    fn opts(interactive: bool, yolo: bool, acp: bool) -> Options {
        Options { yolo, acp, interactive }
    }

    #[test]
    fn no_gated_resources_means_no_question() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let trust = dir.path().join("trusted-projects");
        let mut asker = ScriptedAsker::yes();
        let trusted = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker);
        assert!(trusted, "nothing to gate → trusted");
        assert!(!asker.asked, "no question when there is nothing to gate");
    }

    #[test]
    fn yolo_trusts_without_asking() {
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(true, true, false), Some(&trust), &mut asker);
        assert!(trusted);
        assert!(!asker.asked, "--yolo never asks");
        assert!(!trust.exists(), "--yolo does not remember");
    }

    #[test]
    fn acp_trusts_without_asking() {
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(false, false, true), Some(&trust), &mut asker);
        assert!(trusted);
        assert!(!asker.asked, "--acp never asks");
    }

    #[test]
    fn non_interactive_is_untrusted_with_a_note() {
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(false, false, false), Some(&trust), &mut asker);
        assert!(!trusted, "a piped start does not load an untrusted repo");
        assert!(!asker.asked);
        let note = asker.noted.expect("a note is printed");
        assert!(note.contains("not loading skills or hooks from untrusted"), "{note}");
        assert!(note.contains("--yolo"), "the note points at --yolo: {note}");
    }

    #[test]
    fn empty_answer_is_no() {
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::with(Some(""));
        let trusted = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker);
        assert!(!trusted, "an empty answer defaults to no");
        assert!(asker.asked);
        assert!(!trust.exists(), "a no is not remembered");
    }

    #[test]
    fn eof_answer_is_no() {
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker);
        assert!(!trusted, "EOF defaults to no");
    }

    #[test]
    fn yes_variants_trust_and_remember_once() {
        for answer in ["y", "Y", "yes", "  YES  "] {
            let (_dir, root, trust) = repo_with_hook();
            let mut asker = ScriptedAsker::with(Some(Box::leak(answer.to_string().into_boxed_str())));
            let trusted = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker);
            assert!(trusted, "{answer:?} is a yes");
            let recorded = std::fs::read_to_string(&trust).unwrap();
            assert_eq!(recorded.lines().filter(|l| *l == root.to_string_lossy()).count(), 1, "remembered once");

            // A second decision for the same root reads the file: no question.
            let mut asker2 = ScriptedAsker::with(None);
            let again = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker2);
            assert!(again);
            assert!(!asker2.asked, "a remembered root is not asked again");
        }
    }

    #[test]
    fn remembered_root_is_trusted_even_non_interactively() {
        let (_dir, root, trust) = repo_with_hook();
        std::fs::write(&trust, format!("{}\n", root.display())).unwrap();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(false, false, false), Some(&trust), &mut asker);
        assert!(trusted, "a remembered root is trusted even with piped stdio");
        assert!(asker.noted.is_none(), "no note for a remembered root");
    }

    #[test]
    fn detects_workspace_skills() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skill = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "# x\n").unwrap();
        let gated = Gated::detect(&root, &skills_cfg());
        assert!(gated.skills);
        assert!(!gated.hooks);
        assert_eq!(gated.describe(), "skills");
    }

    #[test]
    fn empty_skill_dir_is_not_gated() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".agents/skills")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg());
        assert!(!gated.skills, "an empty skills dir carries no skill");
        assert!(gated.is_empty());
    }

    #[test]
    fn ai_lock_is_gated() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join(LOCK_FILE), "{}").unwrap();
        let gated = Gated::detect(&root, &skills_cfg());
        assert!(gated.skills, "ai.lock is a gated skill source");
    }

    #[test]
    fn describe_covers_both() {
        let gated = Gated { skills: true, hooks: true };
        assert_eq!(gated.describe(), "skills and hooks");
        assert_eq!(Gated { skills: false, hooks: true }.describe(), "hooks");
    }

    #[test]
    fn trust_file_honours_env_override() {
        temp_env("hunter2");
        assert_eq!(trust_file(), Some(PathBuf::from("hunter2")));
        clear_env();
    }

    // The env-var tests mutate process state; keep them serialised by only
    // touching one variable and restoring it.
    fn temp_env(value: &str) {
        unsafe { std::env::set_var(TRUST_FILE_ENV, value) };
    }
    fn clear_env() {
        unsafe { std::env::remove_var(TRUST_FILE_ENV) };
    }
}
