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
//! - `--yolo` and `--acp` trust without asking (unconditionally, even for an
//!   empty repository);
//! - a root already recorded in the trusted-projects file is trusted (even
//!   non-interactively, with no question);
//! - a root with nothing to gate is left untrusted but is *not* asked about —
//!   there is no question worth asking, yet no trust is granted either, so a
//!   skill or hook that appears later (a checkout, a tool-created file) is
//!   gated on the next `/restart` or hook reload;
//! - an interactive start asks, defaulting to no; a `yes` is remembered once;
//! - a non-interactive start (piped stdio, `-p`) leaves an untrusted root
//!   unloaded and prints one stderr note.
//!
//! The decision is made once per root per process, so `/restart` and hook
//! reloads do not re-ask.
//!
//! Persistence is a line-based `trusted-projects` file keyed on the exact root
//! path. Because matching an entry authorizes loading that repository's skills
//! and hooks, the key must be lossless: a path that is not valid UTF-8 or that
//! contains a line break has no representable key, so it is never remembered
//! and never matched (it stays gated and is asked about again) rather than
//! sharing a lossy key with a different directory.

use std::collections::HashMap;
use std::io::{BufRead, Read, Write};
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
    /// Whether project hooks can actually load (`!--no-hooks` and not
    /// `disable_project_hooks`). When false, a repo's `.claude` hooks are not a
    /// gated resource — nothing would load — so they do not trigger the prompt.
    pub hooks_enabled: bool,
    /// Whether workspace skills can actually load (`skills.enabled` and the
    /// `NANO_CODER_NO_SKILLS` override is unset). When false, a repo's skill
    /// directories and `ai.lock` are not gated — discovery skips them, so they
    /// must not drive the trust prompt or the non-interactive warning.
    pub skills_enabled: bool,
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
    /// Detect the gated resources under `root`. `skills_enabled` and
    /// `hooks_enabled` reflect whether each resource could actually load; when
    /// either is false, that resource is not counted as gated (nothing would
    /// load), so a repo carrying only disabled resources is treated as empty.
    pub fn detect(root: &Path, skills: &SkillsConfig, skills_enabled: bool, hooks_enabled: bool) -> Self {
        let skills_present = skills_enabled
            && ((skills.ai_lock && root.join(LOCK_FILE).is_file())
                || skills.dirs.iter().any(|dir| dir_has_skill(root, &root.join(dir))));
        let hooks_present = hooks_enabled
            && (root.join(".claude/settings.json").is_file() || root.join(".claude/settings.local.json").is_file());
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
    // `--yolo` / `--acp` trust without asking (and without remembering). These
    // bypasses are unconditional: they hold even for an empty repository, so a
    // caller that explicitly opted out of the gate is never gated.
    if opts.yolo || opts.acp {
        return true;
    }
    // A remembered root is trusted with no question, even non-interactively.
    if is_remembered(root, trust_file) {
        return true;
    }
    let gated = Gated::detect(root, skills, opts.skills_enabled, opts.hooks_enabled);
    // Nothing to gate right now: there is no question worth asking, but an
    // unapproved root stays untrusted rather than being granted trust. A later
    // `/restart` or hook reload re-detects, so a skill or hook that appears
    // after this decision (a checkout, a tool-created file) is gated then
    // instead of riding on a blanket "empty means trusted" grant.
    if gated.is_empty() {
        return false;
    }
    // Non-interactive: do not load, and say so once on stderr.
    if !opts.interactive {
        asker.note(&format!(
            "not loading skills or hooks from untrusted {} (start interactively to trust it, or pass --yolo)",
            root.to_string_lossy().escape_debug()
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
            root.to_string_lossy().escape_debug(),
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

/// Whether `path`'s canonical target is a *file* confined within `boundary` and
/// clear of any `.git` component, mirroring discovery's `skills::within`. A bare
/// `is_file()` follows a symlink out of the tree; this rejects such a target so
/// detection never counts a `SKILL.md` discovery would refuse to load.
fn within(path: &Path, boundary: &Path) -> bool {
    match path.canonicalize() {
        Ok(real) => real.starts_with(boundary) && !real.components().any(|c| c.as_os_str() == ".git") && real.is_file(),
        Err(_) => false,
    }
}

/// Whether `dir` contains a `SKILL.md` within [`MAX_SCAN_DEPTH`], i.e. carries
/// at least one workspace skill.
///
/// Each directory is canonicalized before it is scanned, matching how skill
/// *discovery* resolves paths (`skills::Skills::add_dir`). Scanning the
/// canonical target rather than the symlink prefix keeps detection in lockstep
/// with discovery: a repository cannot hide a skill behind a symlink chain that
/// a prefix-retaining walk would fail to descend (e.g. by exceeding the OS
/// symlink limit) while discovery later resolves and loads it.
///
/// Canonicalizing is not on its own enough to bound the walk: a symlink cycle
/// (e.g. several links back to `.`) resolves to the same canonical directory
/// over and over, and a naive recursion re-expands it at every entry, so the
/// work grows exponentially in the number of links — an untrusted repo could
/// stall startup before the user can even decline. Each canonical directory is
/// therefore recorded with the *shallowest* depth at which it was scanned, and
/// re-scanned only when reached again by a shorter path (strictly more
/// remaining depth budget), which could uncover a skill the deeper visit was
/// cut off from. A revisit at equal-or-greater depth already explored
/// everything this one could, so it is skipped — collapsing cycles and aliases
/// without ever missing a skill reachable through a shorter path.
///
/// The walk is also **confined**, exactly as discovery confines its own scan,
/// at two levels:
///
/// 1. **Repository root** (`skills::add_dir`'s `confine` check): a configured
///    skills directory whose canonical target escapes the repository root is a
///    source discovery rejects outright — e.g. an otherwise empty repo whose
///    `.claude/skills` is a symlink to an external skill tree. Detection must
///    not scan it at all, or the repo prompts for (and traverses) skills it
///    cannot load.
/// 2. **Configured directory** (`skills::scan`/`within`): within an accepted
///    skills root, any subdirectory whose canonical target escapes that root is
///    dropped, so a child symlink cannot pull in an out-of-tree skill.
///
/// As in discovery, a `.git` component and dotfile entries are skipped.
fn dir_has_skill(repo_root: &Path, dir: &Path) -> bool {
    fn scan(dir: &Path, boundary: &Path, depth: usize, visited: &mut HashMap<PathBuf, usize>) -> bool {
        // Resolve this directory to its canonical target before inspecting it,
        // so detection follows the same symlinks discovery does.
        let dir = match dir.canonicalize() {
            Ok(real) => real,
            Err(_) => return false,
        };
        // Confine to the configured skills root: a directory whose canonical
        // target escapes it (or sits under a `.git`) is a source discovery
        // rejects, so it is not scanned here either.
        if !dir.starts_with(boundary) || dir.components().any(|c| c.as_os_str() == ".git") {
            return false;
        }
        // Already scanned this canonical directory with at least as much depth
        // budget: that visit saw everything this one would, so skip it and stop
        // a cycle/alias from re-expanding.
        if visited.get(&dir).is_some_and(|&seen| seen <= depth) {
            return false;
        }
        visited.insert(dir.clone(), depth);
        // Confine the `SKILL.md` *target* itself, not just its parent: a
        // symlinked `SKILL.md` whose canonical target escapes the boundary (or
        // resolves under a `.git`) still satisfies a bare `is_file()`, yet
        // discovery's `within` (`skills::scan`) rejects it, so it cannot load.
        // Detection must apply the same canonical-target check or the repo
        // prompts for (persistent) trust over a source that never loads.
        if within(&dir.join(SKILL_FILE), boundary) {
            return true;
        }
        if depth >= MAX_SCAN_DEPTH {
            return false;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else { return false };
        entries
            .filter_map(|e| e.ok())
            // Skip dotfile entries, matching discovery's scan.
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .any(|e| scan(&e.path(), boundary, depth + 1, visited))
    }
    // The canonical configured directory is the inner confinement boundary: it,
    // and only directories beneath it, are scanned. But first apply discovery's
    // repository-root confinement — reject a configured skills directory whose
    // canonical target escapes the repository, exactly as `skills::add_dir`
    // does, so an external-symlinked skills root is never followed.
    let Ok(repo) = repo_root.canonicalize() else { return false };
    let Ok(boundary) = dir.canonicalize() else { return false };
    if !boundary.starts_with(&repo) {
        return false;
    }
    let mut visited = HashMap::new();
    scan(dir, &boundary, 0, &mut visited)
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

/// The exact text line used to persist and match `root` in the line-based
/// trusted-projects file, or `None` when the path cannot be represented
/// losslessly on a single line.
///
/// Matching the persisted key is a trust-authorization decision, so it must be
/// lossless: a *lossy* key (e.g. `root.display()` / `to_string_lossy`, which
/// replace every non-UTF-8 byte with U+FFFD) collapses distinct directories —
/// `repo\xFF` and `repo\xFE` share one key — so trusting one would authorize
/// the other to load skills and hooks without consent. A path is representable
/// only when it is valid UTF-8 and contains no line break (a `\n`/`\r` would
/// split one entry across lines, letting a crafted path smuggle in or shadow a
/// different one). An unrepresentable root **fails closed**: it is never
/// matched and never remembered, so it simply stays gated and is asked about
/// again rather than ever sharing a key with another directory.
fn trust_key(root: &Path) -> Option<String> {
    let key = root.to_str()?;
    if key.is_empty() || key.contains(['\n', '\r']) {
        return None;
    }
    Some(key.to_string())
}

/// Whether `root` is recorded in the trusted-projects file.
///
/// Only **complete**, newline-terminated records authorize: a failed or
/// interrupted append (or a file-size limit) can leave a partial path as the
/// last line — `/parent/repo\n` cut after `/parent` — and accepting that
/// unterminated remnant would trust a directory the user never approved. Any
/// trailing bytes after the final newline therefore invalidate lookup entirely
/// (fail closed): the root is re-asked rather than matched against a fragment.
fn is_remembered(root: &Path, trust_file: Option<&Path>) -> bool {
    let Some(file) = trust_file else { return false };
    let Some(key) = trust_key(root) else { return false };
    let Ok(text) = std::fs::read_to_string(file) else { return false };
    // Reject a partial trailing record: only newline-terminated entries are
    // complete authorizations. An empty file has no partial record.
    if !text.is_empty() && !text.ends_with('\n') {
        return false;
    }
    // Exact, untrimmed line comparison: trimming would let `/tmp/repo ` in the
    // file authorize `/tmp/repo`, a different directory.
    text.lines().any(|line| line == key)
}

/// Append `root` to the trusted-projects file (idempotently). A root whose
/// path the line-based format cannot represent losslessly is **not** persisted
/// (see [`trust_key`]); it remains trusted only for the current process.
///
/// The whole read → dedupe-check → append runs under an exclusive advisory
/// lock on the trust file itself (`flock` / `LockFileEx`), so concurrent
/// approvals in *separate processes* are serialised: without the lock two
/// processes can both observe the file as well-formed and then interleave
/// their writes, concatenating two approved roots into one line that
/// authorizes neither (and would authorize a directory at the concatenated
/// path). The key and its newline are emitted as **one** `write_all` while the
/// lock is held, so even a writer that ignores the lock cannot splice its
/// bytes between a key and its terminator.
///
/// The append must never splice the new key onto an existing entry: a file
/// whose final entry lacks a trailing newline would otherwise concatenate the
/// two absolute paths into one line, so *neither* approved root matches
/// afterward and a directory at the concatenated path becomes trusted without
/// consent. Appending therefore happens only when the existing content ends
/// with a newline (or is empty); a file that does not is left untouched and
/// the root fails closed — trusted for this process, re-asked next time —
/// rather than risking a corrupted entry. A read that outright *fails* (e.g. a
/// writable-but-unreadable file) is treated the same way: it is never assumed
/// empty, since that would bypass the terminator guard and splice the key.
fn remember(root: &Path, trust_file: Option<&Path>) {
    let Some(file) = trust_file else { return };
    let Some(key) = trust_key(root) else { return };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Open for both read and append. `File::lock` on Windows (`LockFileEx`)
    // needs the handle to carry read or write *data* access; an append-only
    // handle lacks it, so an append-only open would make every accepted trust
    // decision fail to lock here and never persist — re-asking the user on
    // every launch and leaving non-interactive launches gated. Requesting read
    // access makes the lock portable, and it lets the existing contents be read
    // back through this same locked handle (below) instead of reopening the
    // path, keeping read → dedupe → append one critical section.
    let Ok(mut f) = std::fs::OpenOptions::new().read(true).append(true).create(true).open(file) else { return };
    // Held until `f` is dropped at the end of the function, so the read, the
    // checks, and the append are one critical section across processes.
    if f.lock().is_err() {
        return;
    }
    // A failed read must fail closed, not be treated as empty: an existing file
    // that is writable but unreadable (and may lack a trailing newline) would
    // otherwise bypass the terminator guard below and concatenate the new key
    // onto the previous entry. Leave it untouched and trust only this process.
    // Reading through the locked handle (append mode leaves the read cursor at
    // the start; writes still go to the end) keeps the whole sequence atomic.
    let mut existing = String::new();
    if f.read_to_string(&mut existing).is_err() {
        return;
    }
    // Exact, untrimmed line comparison (see `is_remembered`).
    if existing.lines().any(|line| line == key) {
        return;
    }
    if !existing.is_empty() && !existing.ends_with('\n') {
        return;
    }
    let _ = f.write_all(format!("{key}\n").as_bytes());
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
        Options { yolo, acp, interactive, hooks_enabled: true, skills_enabled: true }
    }

    #[test]
    fn no_gated_resources_stays_gated_without_a_question() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let trust = dir.path().join("trusted-projects");
        let mut asker = ScriptedAsker::yes();
        let trusted = decide_root(&root, &skills_cfg(), &opts(true, false, false), Some(&trust), &mut asker);
        assert!(!trusted, "an empty, unapproved root is not granted trust");
        assert!(!asker.asked, "no question when there is nothing to gate");
        assert!(!trust.exists(), "nothing is remembered for an empty root");
    }

    #[cfg(unix)]
    #[test]
    fn non_interactive_note_escapes_control_characters_in_the_path() {
        // A repository path can carry terminal control characters on Unix; they
        // must be escaped before display so a directory name cannot erase or
        // forge the warning (or inject newlines into logs).
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let dir = tempfile::tempdir().unwrap();
        // A subdirectory whose name embeds an ESC and a newline.
        let weird = dir.path().join(OsStr::from_bytes(b"re\x1bpo\nname"));
        std::fs::create_dir_all(weird.join(".claude")).unwrap();
        std::fs::write(
            weird.join(".claude/settings.json"),
            r#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#,
        )
        .unwrap();
        let trust = dir.path().join("trusted-projects");
        let mut asker = ScriptedAsker::yes();
        // Non-interactive so the note path (not the question) runs.
        let trusted = decide_root(&weird, &skills_cfg(), &opts(false, false, false), Some(&trust), &mut asker);
        assert!(!trusted);
        let note = asker.noted.expect("a non-interactive note is emitted for a gated repo");
        assert!(!note.contains('\x1b'), "the ESC control character is escaped: {note:?}");
        assert!(!note.contains('\n'), "an embedded newline is escaped: {note:?}");
        assert!(note.contains("re\\u{1b}po\\nname"), "the path is shown escape_debug-escaped: {note:?}");
    }

    #[test]
    fn yolo_and_acp_trust_even_an_empty_root() {
        // The explicit bypasses are unconditional: they hold even when there is
        // currently nothing to gate.
        for opts in [opts(true, true, false), opts(false, false, true), opts(false, true, true)] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().canonicalize().unwrap();
            let trust = dir.path().join("trusted-projects");
            let mut asker = ScriptedAsker::with(None);
            let trusted = decide_root(&root, &skills_cfg(), &opts, Some(&trust), &mut asker);
            assert!(trusted, "yolo/acp bypass the gate even for an empty root");
            assert!(!asker.asked);
        }
    }

    #[test]
    fn remembered_empty_root_is_trusted() {
        // Explicit consent recorded earlier wins over the empty-root default.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let trust = dir.path().join("trusted-projects");
        std::fs::write(&trust, format!("{}\n", root.display())).unwrap();
        let mut asker = ScriptedAsker::with(None);
        let trusted = decide_root(&root, &skills_cfg(), &opts(false, false, false), Some(&trust), &mut asker);
        assert!(trusted, "a remembered root is trusted even when empty");
        assert!(!asker.asked);
    }

    #[cfg(unix)]
    #[test]
    fn detection_follows_symlinked_skill_dirs() {
        // A skill reachable only through a symlinked directory must still be
        // detected: discovery canonicalizes the directory before descending, so
        // detection must too, or a symlink chain could hide a skill from the
        // gate that discovery later loads.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        // The real skill lives outside the configured `.claude/skills` prefix.
        let real = root.join("real/x");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("SKILL.md"), "# x\n").unwrap();
        // `.claude/skills` is a symlink to the directory holding the skill.
        std::fs::create_dir_all(root.join(".claude")).unwrap();
        symlink(root.join("real"), root.join(".claude/skills")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(gated.skills, "a skill behind a symlinked skills dir is still gated");
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
    fn trailing_whitespace_entry_does_not_authorize_trimmed_root() {
        // A stored entry with trailing whitespace is a *different* directory
        // from the trimmed path; a trimming match would authorize the wrong
        // one. Matching is exact, so it must not match.
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let root = dir.path().join("repo");
        std::fs::write(&trust, format!("{} \n", root.display())).unwrap();
        assert!(!is_remembered(&root, Some(&trust)), "a padded entry must not authorize the trimmed root");
    }

    #[test]
    fn remember_round_trips_an_exact_match() {
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let root = dir.path().join("repo");
        remember(&root, Some(&trust));
        assert!(is_remembered(&root, Some(&trust)), "a remembered root matches itself exactly");
        remember(&root, Some(&trust));
        let recorded = std::fs::read_to_string(&trust).unwrap();
        assert_eq!(recorded.lines().filter(|l| !l.is_empty()).count(), 1, "remembered once");
    }

    #[cfg(unix)]
    #[test]
    fn remember_fails_closed_when_existing_file_is_unreadable() {
        // A writable-but-unreadable trust file must not be treated as empty:
        // doing so would bypass the terminator guard and splice the new key.
        // Even a newline-terminated file (which would normally append) must be
        // left untouched when its contents cannot be read.
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let existing = dir.path().join("existing");
        let fresh = dir.path().join("fresh");
        std::fs::write(&trust, format!("{}\n", existing.display())).unwrap();
        // Read-less open: requesting read access (needed for a portable lock)
        // makes the open itself fail on a write-only file, so `remember` returns
        // before touching it. Either way the file must be left untouched.
        std::fs::set_permissions(&trust, std::fs::Permissions::from_mode(0o200)).unwrap();
        remember(&fresh, Some(&trust));
        // Restore read access to inspect the result.
        std::fs::set_permissions(&trust, std::fs::Permissions::from_mode(0o600)).unwrap();
        let recorded = std::fs::read_to_string(&trust).unwrap();
        assert_eq!(recorded, format!("{}\n", existing.display()), "the unreadable file is left untouched");
        assert!(!is_remembered(&fresh, Some(&trust)), "the new root is not persisted on a failed read");
    }

    #[test]
    fn remember_never_splices_onto_a_newline_less_final_entry() {
        // A trust file whose last entry lacks a trailing newline must not have
        // a new key concatenated onto it: that would corrupt both approved
        // roots into one line and authorize a directory at the concatenated
        // path. `remember` fails closed — the new root stays unpersisted (and
        // re-asked next time) rather than risking the splice.
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        std::fs::write(&trust, format!("{}", first.display())).unwrap(); // no trailing newline
        remember(&second, Some(&trust));
        let recorded = std::fs::read_to_string(&trust).unwrap();
        assert_eq!(recorded, format!("{}", first.display()), "the unterminated entry is left untouched");
        // The unterminated remnant is a partial record, so lookup fails closed:
        // it authorizes nothing (see is_remembered_rejects_an_unterminated_record).
        assert!(
            !is_remembered(&first, Some(&trust)),
            "an unterminated entry is a partial record, not an authorization"
        );
        assert!(!is_remembered(&second, Some(&trust)), "the new root is not spliced on");
        let concatenated = PathBuf::from(format!("{}{}", first.display(), second.display()));
        assert!(!is_remembered(&concatenated, Some(&trust)), "no concatenated path is authorized");

        // A well-formed file (newline-terminated) still appends on a new line.
        std::fs::write(&trust, format!("{}\n", first.display())).unwrap();
        remember(&second, Some(&trust));
        assert!(is_remembered(&first, Some(&trust)));
        assert!(is_remembered(&second, Some(&trust)), "appended as its own line");
        assert!(!is_remembered(&concatenated, Some(&trust)));
    }

    #[test]
    fn is_remembered_rejects_an_unterminated_record() {
        // A failed or interrupted append (or a file-size limit) can cut a record
        // mid-path, leaving a partial path as the last line. Accepting that
        // unterminated remnant would trust a directory the user never approved
        // — e.g. `/parent/repo\n` cut after `/parent` would authorize
        // `/parent`. Lookup must require newline-terminated records and fail
        // closed on any partial trailing record.
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let parent = dir.path().join("parent");
        let repo = parent.join("repo");
        // Simulate the truncated append: the full record was `parent/repo\n`
        // but only `parent` (no newline) survived.
        std::fs::write(&trust, format!("{}", parent.display())).unwrap();
        assert!(!is_remembered(&parent, Some(&trust)), "a truncated record does not authorize its prefix");
        assert!(!is_remembered(&repo, Some(&trust)), "the intended root is not authorized either");

        // Even a complete earlier record is not matched once a partial record
        // follows it: the file is corrupt, so nothing in it is trusted.
        let other = dir.path().join("other");
        std::fs::write(&trust, format!("{}\n{}", other.display(), parent.display())).unwrap();
        assert!(!is_remembered(&other, Some(&trust)), "a partial trailing record invalidates lookup");
        assert!(!is_remembered(&parent, Some(&trust)));

        // A complete, newline-terminated record still matches.
        std::fs::write(&trust, format!("{}\n", repo.display())).unwrap();
        assert!(is_remembered(&repo, Some(&trust)), "a complete record is honored");
        assert!(!is_remembered(&parent, Some(&trust)));
    }

    #[test]
    fn concurrent_remembers_never_splice_or_lose_an_entry() {
        // Concurrent approvals run in *separate processes* (two terminals), so
        // the regression test must too: threads share one advisory lock. Each
        // child re-runs this test binary in a hidden worker mode that performs
        // one `remember` of its own distinct root. Without serialisation the
        // children can interleave their writes and splice two roots into one
        // concatenated line, or overwrite each other and lose an approval.
        if let (Ok(file), Ok(root)) = (std::env::var("TRUST_CHILD_FILE"), std::env::var("TRUST_CHILD_ROOT")) {
            remember(Path::new(&root), Some(Path::new(&file)));
            return;
        }

        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        let roots: Vec<PathBuf> = (0..8).map(|i| dir.path().join(format!("repo-{i}"))).collect();
        let exe = std::env::current_exe().unwrap();
        let children: Vec<_> = roots
            .iter()
            .map(|root| {
                std::process::Command::new(&exe)
                    .arg("--exact")
                    .arg("trust::tests::concurrent_remembers_never_splice_or_lose_an_entry")
                    .arg("--include-ignored")
                    .env("TRUST_CHILD_FILE", &trust)
                    .env("TRUST_CHILD_ROOT", root)
                    .env("RUST_BACKTRACE", "0")
                    .spawn()
                    .unwrap()
            })
            .collect();
        for child in children {
            assert!(child.wait_with_output().unwrap().status.success(), "a child approval failed");
        }

        let recorded =
            std::fs::read_to_string(&trust).unwrap_or_else(|e| panic!("trust file missing after approvals: {e}"));
        // Every line is exactly one approved root: no two roots were spliced
        // into one entry, and no stray partial write survives.
        for line in recorded.lines() {
            assert!(roots.iter().any(|r| r.as_os_str() == line), "unexpected or spliced entry: {line:?}");
        }
        for root in &roots {
            assert!(is_remembered(root, Some(&trust)), "no approval was lost: {root:?}");
        }
        assert_eq!(recorded.lines().count(), roots.len(), "one line per approved root");
    }

    #[test]
    fn newline_bearing_path_is_not_representable() {
        // A path containing a line break cannot be a single line entry; it
        // fails closed rather than smuggling in or shadowing another entry.
        let root = Path::new("/tmp/re\npo");
        assert!(trust_key(root).is_none(), "a newline path has no trust key");
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        remember(root, Some(&trust));
        assert!(!trust.exists() || std::fs::read_to_string(&trust).unwrap().is_empty(), "it is not persisted");
        assert!(!is_remembered(root, Some(&trust)), "and never matches");
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_paths_are_not_conflated() {
        // Two distinct non-UTF-8 directories must never share a (lossy) key: a
        // lossy key would let trusting one authorize the other. They fail
        // closed — no key, never persisted, never matched.
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let a = PathBuf::from(OsStr::from_bytes(b"/tmp/repo\xFF"));
        let b = PathBuf::from(OsStr::from_bytes(b"/tmp/repo\xFE"));
        assert!(trust_key(&a).is_none() && trust_key(&b).is_none(), "non-UTF-8 paths have no key");
        let dir = tempfile::tempdir().unwrap();
        let trust = dir.path().join("trusted-projects");
        remember(&a, Some(&trust));
        assert!(!is_remembered(&a, Some(&trust)), "a is not persisted");
        assert!(!is_remembered(&b, Some(&trust)), "and cannot authorize the sibling b");
    }

    #[test]
    fn disabled_project_hooks_are_not_gated() {
        // A repo carrying only a project hook must not be treated as gated when
        // project hooks cannot load (`--no-hooks` or `disable_project_hooks`),
        // otherwise it prompts for consent that would gate nothing.
        let (_dir, root, _trust) = repo_with_hook();
        let enabled = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(enabled.hooks, "an enabled project hook is gated");
        let disabled = Gated::detect(&root, &skills_cfg(), true, false);
        assert!(!disabled.hooks, "a disabled project hook is not gated");
        assert!(disabled.is_empty(), "nothing is left to gate");
    }

    #[test]
    fn hook_only_repo_stays_ungated_when_hooks_disabled() {
        // End-to-end: with project hooks disabled, a hook-only repo asks no
        // question and is not trusted (nothing gated), rather than prompting.
        let (_dir, root, trust) = repo_with_hook();
        let mut asker = ScriptedAsker::yes();
        let opts = Options { yolo: false, acp: false, interactive: true, hooks_enabled: false, skills_enabled: true };
        let trusted = decide_root(&root, &skills_cfg(), &opts, Some(&trust), &mut asker);
        assert!(!trusted, "a hook-only repo with hooks disabled is not granted trust");
        assert!(!asker.asked, "no trust question is asked when nothing can load");
    }

    #[test]
    fn detects_workspace_skills() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skill = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "# x\n").unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(gated.skills);
        assert!(!gated.hooks);
        assert_eq!(gated.describe(), "skills");
    }

    #[test]
    fn empty_skill_dir_is_not_gated() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".agents/skills")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "an empty skills dir carries no skill");
        assert!(gated.is_empty());
    }

    #[test]
    fn ai_lock_is_gated() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join(LOCK_FILE), "{}").unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(gated.skills, "ai.lock is a gated skill source");
    }

    #[test]
    fn disabled_skills_are_not_gated() {
        // When skills cannot load (`skills.enabled` is false or
        // `NANO_CODER_NO_SKILLS` is set, both collapsed into `skills_enabled`),
        // a repo's skill dirs and `ai.lock` must not be gated: discovery skips
        // them, so prompting for consent would gate nothing and a `yes` would
        // persist a useless trust grant.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skill = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "# x\n").unwrap();
        std::fs::write(root.join(LOCK_FILE), "{}").unwrap();
        let enabled = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(enabled.skills, "a skill is gated when skills can load");
        let disabled = Gated::detect(&root, &skills_cfg(), false, true);
        assert!(!disabled.skills, "skills are not gated when they cannot load");
        assert!(disabled.is_empty(), "a skills-only repo is empty when skills are off");
    }

    #[cfg(unix)]
    #[test]
    fn scan_terminates_on_symlink_cycles() {
        // A symlink cycle (here: many links back to the skills dir itself)
        // resolves to the same canonical directory over and over. Without
        // per-canonical-directory memoisation the walk re-expands the cycle at
        // every entry and the work grows exponentially, letting an untrusted
        // repo stall startup before the user can decline. The scan must collapse
        // the cycle and return promptly.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skills = root.join(".claude/skills");
        std::fs::create_dir_all(&skills).unwrap();
        // Eight self-links: a naive walk would perform thousands of scans.
        for i in 0..8 {
            symlink(&skills, skills.join(format!("loop{i}"))).unwrap();
        }
        let start = std::time::Instant::now();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a cycle with no SKILL.md carries no skill");
        assert!(start.elapsed() < std::time::Duration::from_secs(5), "the cycle must not blow up the scan");
    }

    #[cfg(unix)]
    #[test]
    fn scan_finds_skill_through_shorter_path_despite_cycle() {
        // Memoising visited directories must not hide a skill reachable through a
        // shorter path than a cycle first exposed it at: a canonical directory
        // re-reached with more remaining depth budget is re-scanned.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skills = root.join(".claude/skills");
        std::fs::create_dir_all(&skills).unwrap();
        // A self-link cycle plus a genuine skill one level down.
        symlink(&skills, skills.join("loop")).unwrap();
        let skill = skills.join("real");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "# x\n").unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(gated.skills, "a real skill is found even alongside a cycle");
    }

    #[cfg(unix)]
    #[test]
    fn detection_rejects_a_skills_dir_symlinked_outside_the_repo() {
        // The reviewer's case: an otherwise empty repo whose `.claude/skills`
        // is a symlink to an external skill tree. Discovery rejects that source
        // (the canonical target escapes the repository confinement boundary),
        // so detection must not follow it either — otherwise the repo prompts
        // for, and traverses, skills it cannot load.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        // The skill tree lives entirely outside the repository.
        let external = tempfile::tempdir().unwrap();
        let ext_skill = external.path().join("x");
        std::fs::create_dir_all(&ext_skill).unwrap();
        std::fs::write(ext_skill.join("SKILL.md"), "# x\n").unwrap();
        // `.claude/skills` symlinks to the external tree.
        std::fs::create_dir_all(root.join(".claude")).unwrap();
        symlink(external.path(), root.join(".claude/skills")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a skills dir symlinked outside the repo is not gated");
        assert!(gated.is_empty(), "nothing loadable remains to gate");
    }

    #[cfg(unix)]
    #[test]
    fn detection_rejects_a_subdirectory_symlinked_outside_the_skills_root() {
        // The recursive case: the configured skills dir is real and in-repo,
        // but a *subdirectory* of it symlinks to an external skill tree.
        // Discovery's `within` check drops that entry, so detection must too.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skills = root.join(".claude/skills");
        std::fs::create_dir_all(&skills).unwrap();
        let external = tempfile::tempdir().unwrap();
        let ext_skill = external.path().join("x");
        std::fs::create_dir_all(&ext_skill).unwrap();
        std::fs::write(ext_skill.join("SKILL.md"), "# x\n").unwrap();
        // A child of the skills dir escapes to the external tree.
        symlink(external.path(), skills.join("ext")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a skill reachable only by escaping the skills root is not gated");
    }

    #[cfg(unix)]
    #[test]
    fn detection_rejects_a_skill_file_symlinked_outside_the_skills_root() {
        // The file-level case: the configured skills dir (and the candidate
        // skill subdirectory) are real and in-repo, but the `SKILL.md` itself
        // is a symlink whose target lives outside the skills root. A bare
        // `is_file()` follows that link and would gate it, yet discovery's
        // `within` rejects the file, so it can never load — detection must not
        // prompt for persistent trust over it.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skill_dir = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill_dir).unwrap();
        let external = tempfile::tempdir().unwrap();
        let ext_file = external.path().join("SKILL.md");
        std::fs::write(&ext_file, "# x\n").unwrap();
        // The SKILL.md in an in-repo skill dir points to an external file.
        symlink(&ext_file, skill_dir.join("SKILL.md")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a SKILL.md symlinked outside the skills root is not gated");
    }

    #[cfg(unix)]
    #[test]
    fn detection_skips_a_skill_file_symlinked_through_a_dot_git() {
        // A `SKILL.md` whose canonical target resolves under a `.git` component
        // *inside* the skills root is rejected by discovery's `within` (its
        // `.git` clause, not the boundary clause), so detection must drop it too
        // even though a bare `is_file()` would follow the link.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let skill_dir = root.join(".claude/skills/x");
        std::fs::create_dir_all(&skill_dir).unwrap();
        // A real SKILL.md physically sits under a `.git` directory that is
        // itself within the skills root, so only the `.git` clause excludes it.
        let git_file = root.join(".claude/skills/.git/SKILL.md");
        std::fs::create_dir_all(git_file.parent().unwrap()).unwrap();
        std::fs::write(&git_file, "# x\n").unwrap();
        symlink(&git_file, skill_dir.join("SKILL.md")).unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a SKILL.md resolving under a .git component is not gated");
    }

    #[test]
    fn detection_skips_a_dot_git_entry_inside_the_skills_root() {
        // Discovery never descends into a `.git` component (its scan filters
        // dotfile entries and `within` rejects any `.git` component); a SKILL.md
        // planted under a `.git` directory that is physically inside the real,
        // in-repo skills root must not be detected either.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let git_skill = root.join(".claude/skills/.git/x");
        std::fs::create_dir_all(&git_skill).unwrap();
        std::fs::write(git_skill.join("SKILL.md"), "# x\n").unwrap();
        let gated = Gated::detect(&root, &skills_cfg(), true, true);
        assert!(!gated.skills, "a SKILL.md under a .git component is not gated");
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
