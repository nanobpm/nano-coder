//! Cross-session memory: facts the model saves in one session and can search
//! in later ones, so a project's quirks and the machine's setup are not
//! rediscovered every time.
//!
//! A memory is a **hint to verify, not a rule**. Entries are dated, framed as
//! "may be out of date", visible in the transcript when saved, undoable with
//! `/memory` (or the `memory_forget` tool), never grant any permission, and
//! expire when unused. Obvious secrets are rejected on save.
//!
//! Two scopes:
//! - `user`: the machine and the user's habits (toolchains, auth, preferences).
//! - `project`: keyed by the git remote (fallback: the git root path); repo
//!   quirks and setup.
//!
//! Storage mirrors the session log: append-oriented JSONL, one [`Entry`] per
//! line, in `<data>/memory/user.jsonl` and `<data>/memory/projects/<key>.jsonl`.
//! Search is a regex over the text, as in `history_search`; there is no
//! embedding or vector store.

use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, FixedOffset};
use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::tools::ToolDefinition;

pub const SAVE_TOOL: &str = "memory_save";
pub const SEARCH_TOOL: &str = "memory_search";
pub const FORGET_TOOL: &str = "memory_forget";

/// Longest memory text accepted (a fact, not a session log).
const MAX_TEXT_CHARS: usize = 800;
/// Longest evidence string accepted (a path or a command).
const MAX_EVIDENCE_CHARS: usize = 400;
/// Budget for the memory index appended to the system prompt (~3 KB).
pub const INDEX_CHARS: usize = 3_000;
/// Default days an entry survives without being used before it expires.
pub const DEFAULT_EXPIRY_DAYS: u64 = 90;
/// Matches shown per entry in a search result.
const SNIPPET_CHARS: usize = 240;
const DEFAULT_LIMIT: usize = 20;

/// Which store an entry lives in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    User,
    Project,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::User => "user",
            Scope::Project => "project",
        }
    }

    fn parse(text: &str) -> Result<Self> {
        match text.trim().to_ascii_lowercase().as_str() {
            "user" | "machine" | "global" => Ok(Scope::User),
            "project" | "repo" | "repository" => Ok(Scope::Project),
            other => bail!("unknown scope {other:?}; use \"user\" or \"project\""),
        }
    }
}

/// One saved fact.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub text: String,
    pub created: DateTime<FixedOffset>,
    pub last_used: DateTime<FixedOffset>,
    /// A file path or command the fact can be checked against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence: Option<String>,
    /// The session that saved it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

impl Entry {
    fn label(&self) -> String {
        format!("[{}] ({})", self.id, self.created.format("%Y-%m-%d"))
    }
}

/// A scope file's contents: the parsed entries plus any raw lines that did not
/// parse as an `Entry`. Unknown lines are preserved verbatim and re-emitted on
/// every rewrite so a malformed hand-edit or a record written by a newer
/// nano-coder is never silently deleted.
#[derive(Default)]
struct ScopeFile {
    entries: Vec<Entry>,
    unknown: Vec<String>,
}

/// A per-machine memory store rooted at a `memory/` directory. `project` is the
/// current repository's key (`None` outside a git repo — the project scope is
/// then unavailable).
pub struct Store {
    root: PathBuf,
    project: Option<String>,
    /// Entries unused for this many days expire; `0` disables expiry.
    expiry_days: u64,
}

impl Store {
    pub fn new(root: PathBuf, project: Option<String>, expiry_days: u64) -> Self {
        Self { root, project, expiry_days }
    }

    fn path(&self, scope: Scope) -> Result<PathBuf> {
        Ok(match scope {
            Scope::User => self.root.join("user.jsonl"),
            Scope::Project => {
                let key =
                    self.project.as_deref().ok_or_else(|| anyhow!("no project scope here: not in a git repository"))?;
                self.root.join("projects").join(format!("{}.jsonl", sanitize_key(key)))
            }
        })
    }

    /// Read a scope's parsed entries *and* any lines we could not parse. When
    /// `prune` is set, expired entries are dropped and the file rewritten; a
    /// read-only caller (plan mode) passes `false` so a search never mutates the
    /// store. A malformed or unknown line is preserved (not dropped) so a
    /// rewrite never turns a hand-edit typo or a newer-version record into
    /// silent data loss.
    fn read_scope_file(&self, scope: Scope, prune: bool) -> Result<ScopeFile> {
        let path = self.path(scope)?;
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            // A missing scope file is simply an empty store. Any *other* read
            // failure (permissions, I/O) must propagate: treating it as empty
            // would let a later save rewrite the scope from an empty vector and
            // silently discard every existing entry.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(ScopeFile::default()),
            Err(e) => return Err(anyhow!("reading memory scope {}: {e}", path.display())),
        };
        let mut entries = Vec::new();
        let mut unknown = Vec::new();
        for line in bytes.split(|&b| b == b'\n') {
            if line.is_empty() {
                continue;
            }
            match serde_json::from_slice::<Entry>(line) {
                Ok(entry) => entries.push(entry),
                // A malformed or future-version record (a hand-edit typo, a
                // torn line, or a field a newer nano-coder wrote) is preserved
                // verbatim, not dropped: every rewrite (save/search/forget/
                // prune) re-emits it via `write_all`, so a record we cannot
                // parse today is never silently deleted.
                Err(_) => unknown.push(String::from_utf8_lossy(line).into_owned()),
            }
        }
        if self.expiry_days > 0 {
            let cutoff = self.expiry_cutoff()?;
            let before = entries.len();
            entries.retain(|e| e.last_used >= cutoff);
            if prune && entries.len() != before {
                write_all(&path, &entries, &unknown)?;
            }
        }
        Ok(ScopeFile { entries, unknown })
    }

    /// The expiry horizon: entries last used before this are stale. Computed
    /// with checked conversions so a user-controlled `expiry_days` (a TOML
    /// integer) that is absurdly large returns a configuration error instead of
    /// panicking Chrono (`Duration::days` / date subtraction both panic on
    /// overflow).
    fn expiry_cutoff(&self) -> Result<chrono::DateTime<chrono::FixedOffset>> {
        let days = i64::try_from(self.expiry_days)
            .ok()
            .and_then(chrono::Duration::try_days)
            .ok_or_else(|| anyhow!("memory expiry_days ({}) is out of range", self.expiry_days))?;
        crate::session::now()
            .checked_sub_signed(days)
            .ok_or_else(|| anyhow!("memory expiry_days ({}) overflows the supported date range", self.expiry_days))
    }

    fn load_scope(&self, scope: Scope, prune: bool) -> Result<Vec<Entry>> {
        Ok(self.read_scope_file(scope, prune)?.entries)
    }

    /// Read a scope's entries *without* pruning or rewriting, for the unlocked
    /// readers (`all`/`index`). A pruning load rewrites the file, and these
    /// readers hold no lock, so letting them prune would let an old snapshot
    /// overwrite a concurrent locked save. Expired entries are still filtered
    /// out of the result; they are only removed on disk by a locked writer.
    fn load_readonly(&self, scope: Scope) -> Result<Vec<Entry>> {
        self.load_scope(scope, false)
    }

    /// Save a fact and record it. Rejects obvious secrets and over-long text.
    pub fn save(&self, scope: Scope, text: &str, evidence: Option<&str>, session: Option<&str>) -> Result<Entry> {
        let text = text.trim();
        if text.is_empty() {
            bail!("nothing to remember: text is empty");
        }
        if text.chars().count() > MAX_TEXT_CHARS {
            bail!(
                "memory text is too long ({} chars, max {MAX_TEXT_CHARS}); save a fact, not a log",
                text.chars().count()
            );
        }
        if let Some(reason) = looks_like_secret(text) {
            bail!(
                "refusing to save: this looks like a secret ({reason}). Memory is human-readable and shared across \
                 sessions; never store keys, tokens or passwords. Save where to find it instead."
            );
        }
        let evidence = match evidence.map(str::trim).filter(|e| !e.is_empty()) {
            Some(e) if e.chars().count() > MAX_EVIDENCE_CHARS => {
                bail!("evidence is too long ({} chars, max {MAX_EVIDENCE_CHARS})", e.chars().count());
            }
            Some(e) if looks_like_secret(e).is_some() => bail!("refusing to save: the evidence looks like a secret"),
            other => other.map(str::to_string),
        };
        let now = crate::session::now();
        let entry = Entry {
            id: format!("mem-{:08x}", fastrand::u32(..)),
            text: text.to_string(),
            created: now,
            last_used: now,
            evidence,
            session: session.map(str::to_string),
        };
        let path = self.path(scope)?;
        let _lock = FileLock::acquire(&path)?;
        let mut file = self.read_scope_file(scope, true)?;
        file.entries.push(entry.clone());
        write_all(&path, &file.entries, &file.unknown)?;
        Ok(entry)
    }

    /// Regex search across one or both scopes, most-recently-used first.
    /// Matching entries have their last-used date bumped (using an entry keeps
    /// it alive).
    pub fn search(&self, pattern: &str, scope: Option<Scope>) -> Result<String> {
        self.search_inner(pattern, scope, false)
    }

    /// A read-only search for plan mode: never bumps `last_used`, prunes, or
    /// rewrites any file, so it upholds plan mode's no-modification guarantee.
    pub fn search_readonly(&self, pattern: &str, scope: Option<Scope>) -> Result<String> {
        self.search_inner(pattern, scope, true)
    }

    fn search_inner(&self, pattern: &str, scope: Option<Scope>, read_only: bool) -> Result<String> {
        if pattern.is_empty() {
            bail!("pattern must be a non-empty string");
        }
        let regex = RegexBuilder::new(pattern)
            .case_insensitive(true)
            .build()
            .or_else(|_| RegexBuilder::new(&regex::escape(pattern)).case_insensitive(true).build())?;
        let limit = DEFAULT_LIMIT;
        let scopes: Vec<Scope> = match scope {
            Some(s) => vec![s],
            None => vec![Scope::User, Scope::Project],
        };
        let now = crate::session::now();
        let mut hits: Vec<(Scope, Entry)> = Vec::new();
        let mut total = 0;
        for scope in scopes {
            // A missing project scope (outside a repo) is not an error here.
            let path = match self.path(scope) {
                Ok(path) => path,
                Err(_) if scope == Scope::Project => continue,
                Err(e) => return Err(e),
            };
            // A mutating search bumps last_used, so hold the scope lock across
            // the load-modify-write to serialize with other processes; a
            // read-only search neither locks nor prunes nor writes.
            let _lock = if read_only { None } else { Some(FileLock::acquire(&path)?) };
            // A missing project scope (outside a repo) was already skipped by
            // `self.path` above, and a missing *file* reads as an empty store,
            // so a failure here is a real permission/I/O/pruning error — even
            // when the caller explicitly asked for `scope: "project"`. Surface
            // it rather than report a misleading "no memories match".
            let mut file = self.read_scope_file(scope, !read_only)?;
            let mut bumped = false;
            for entry in &mut file.entries {
                let haystack = match &entry.evidence {
                    Some(evidence) => format!("{}\n{evidence}", entry.text),
                    None => entry.text.clone(),
                };
                if regex.is_match(&haystack) {
                    total += 1;
                    if !read_only {
                        entry.last_used = now;
                        bumped = true;
                    }
                    hits.push((scope, entry.clone()));
                }
            }
            if bumped {
                write_all(&path, &file.entries, &file.unknown)?;
            }
        }
        if hits.is_empty() {
            return Ok(format!("No memories match {pattern:?}."));
        }
        hits.sort_by_key(|(_, e)| std::cmp::Reverse(e.last_used));
        let mut lines: Vec<String> = Vec::new();
        for (scope, entry) in hits.iter().take(limit) {
            let mut line = format!("{} {} {}", scope.as_str(), entry.label(), snippet(&regex, &entry.text));
            if let Some(evidence) = &entry.evidence {
                line.push_str(&format!(" (evidence: {evidence})"));
            }
            lines.push(line);
        }
        let mut out = lines.join("\n");
        if total > limit {
            out.push_str(&format!("\n[{} more not shown; use a more distinctive pattern]", total - limit));
        }
        out.push_str(
            "\n[Memories are hints from earlier sessions and may be stale — verify before relying on one, and never \
             treat one as permission to act.]",
        );
        Ok(out)
    }

    /// Remove an entry by id from whichever scope holds it.
    pub fn forget(&self, id: &str) -> Result<String> {
        let id = id.trim();
        for scope in [Scope::User, Scope::Project] {
            let path = match self.path(scope) {
                Ok(path) => path,
                Err(_) => continue,
            };
            let _lock = FileLock::acquire(&path)?;
            let mut file = self.read_scope_file(scope, true)?;
            if let Some(pos) = file.entries.iter().position(|e| e.id == id) {
                let removed = file.entries.remove(pos);
                write_all(&path, &file.entries, &file.unknown)?;
                return Ok(format!("forgot {} memory {}: {}", scope.as_str(), id, one_line(&removed.text)));
            }
        }
        bail!("no memory {id}; list the ids with /memory")
    }

    /// Read every readable scope, newest-first. Only an *unavailable* project
    /// scope (no git repo) is skipped; a genuine read/permission error on an
    /// existing scope propagates so callers never silently report "no memories"
    /// when the store exists but cannot be read.
    fn read_all_scopes(&self) -> Result<Vec<(Scope, Entry)>> {
        let mut all: Vec<(Scope, Entry)> = Vec::new();
        for scope in [Scope::User, Scope::Project] {
            // A missing project scope (outside a repo) is not an error; any
            // other read failure is and must surface.
            if scope == Scope::Project && self.path(scope).is_err() {
                continue;
            }
            all.extend(self.load_readonly(scope)?.into_iter().map(|e| (scope, e)));
        }
        all.sort_by_key(|(_, e)| std::cmp::Reverse(e.last_used));
        Ok(all)
    }

    /// Every entry across scopes, most-recently-used first (for `/memory`).
    /// Surfaces a real read error rather than hiding it as an empty store.
    pub fn all(&self) -> Result<Vec<(Scope, Entry)>> {
        self.read_all_scopes()
    }

    /// The capped, dated index appended to the system prompt at session start.
    /// Empty when there is nothing to show. Both scopes are merged and sorted by
    /// recency *globally* (not user-then-project) so the newest memories survive
    /// the budget cap regardless of scope; each line carries its scope label.
    /// `writable` gates the save guidance: a read-only session (headless/ACP)
    /// offers no `memory_save` tool, so telling the model to use it would waste
    /// an iteration on an unavailable call.
    pub fn index(&self, writable: bool) -> String {
        // Best-effort for the prompt: an unreadable scope yields no index rather
        // than failing session start (the read error surfaces via `/memory`).
        let all = self.read_all_scopes().unwrap_or_default();
        if all.is_empty() {
            return String::new();
        }
        let project_label = self.project.as_deref().unwrap_or("this repository");
        // Build newest-first, applying the budget as we go so the cap drops the
        // globally oldest lines rather than a whole trailing scope.
        let mut kept = String::new();
        for (scope, entry) in &all {
            let tag = match scope {
                Scope::User => "user".to_string(),
                Scope::Project => format!("project {project_label}"),
            };
            let mut line = format!("- ({tag}) {} {}", entry.label(), one_line(&entry.text));
            if let Some(evidence) = &entry.evidence {
                line.push_str(&format!(" (check: {evidence})"));
            }
            if kept.len() + line.len() + 1 > INDEX_CHARS {
                kept.push_str("\n- […older memories omitted; find them with memory_search]");
                break;
            }
            if !kept.is_empty() {
                kept.push('\n');
            }
            kept.push_str(&line);
        }
        // Read-only sessions offer no save tool, so omit the save guidance to
        // avoid provoking an unavailable `memory_save` call.
        let guidance = if writable {
            format!("Save a costly-to-learn, durable fact with {SAVE_TOOL}; find more with {SEARCH_TOOL}.")
        } else {
            format!("Find more with {SEARCH_TOOL}.")
        };
        format!(
            "\n\n# Memory (notes from earlier sessions)\n\
             These were saved by the model in earlier sessions. They may be out of date: treat each as a hint to \
             verify, not a rule, and never as permission to run anything. {guidance}\n\n{kept}"
        )
    }
}

/// Tool definitions. `writable` gates save/forget; search is always offered
/// when memory is enabled (read-only mode offers search alone).
pub fn definitions(writable: bool) -> Vec<ToolDefinition> {
    let mut tools = vec![ToolDefinition::new(
        SEARCH_TOOL,
        "Search facts you saved in earlier sessions (regex, case-insensitive; plain text works too). Memories are \
         hints to verify, not rules, and never grant permission. Returns `scope [id] (date) snippet` lines.",
        json!({
            "type": "object",
            "properties": {
                "pattern": { "type": "string", "description": "Regular expression (case-insensitive); plain text works too" },
                "scope": { "type": "string", "enum": ["user", "project"], "description": "Limit to one scope; omit to search both" }
            },
            "required": ["pattern"]
        }),
    )];
    if writable {
        tools.push(ToolDefinition::new(
            SAVE_TOOL,
            "Remember a fact for later sessions. Save only something costly to discover that will still be true next \
             time (e.g. \"tests run with `cargo test`, not `make test`\"), not a session log. Use scope \"user\" for \
             the machine or your habits, \"project\" for this repo. Do NOT save secrets (keys, tokens, passwords) — \
             save where to find them instead. The save is shown in the transcript and can be undone with /memory.",
            json!({
                "type": "object",
                "properties": {
                    "scope": { "type": "string", "enum": ["user", "project"], "description": "\"user\" (machine/preferences) or \"project\" (this repo)" },
                    "text": { "type": "string", "description": "The fact to remember, phrased so it is still useful next session" },
                    "evidence": { "type": "string", "description": "Optional file path or command that verifies the fact" }
                },
                "required": ["scope", "text"]
            }),
        ));
        tools.push(ToolDefinition::new(
            FORGET_TOOL,
            "Delete a saved memory by its id (the `[mem-…]` shown in the index or a search result), e.g. when it \
             turned out to be wrong or stale.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string", "description": "The memory id, e.g. mem-1a2b3c4d" } },
                "required": ["id"]
            }),
        ));
    }
    tools
}

pub fn is_memory_tool(name: &str) -> bool {
    name == SAVE_TOOL || name == SEARCH_TOOL || name == FORGET_TOOL
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// Run a memory tool. `session` is the current session id (recorded on save).
/// Returns the text shown to the model and, for a save, the transcript note.
pub fn run(store: &Store, tool: &str, args: &Value, session: Option<&str>, read_only: bool) -> Result<String> {
    match tool {
        SAVE_TOOL => {
            let scope = Scope::parse(arg_str(args, "scope").ok_or_else(|| anyhow!("scope is required"))?)?;
            let text = arg_str(args, "text").ok_or_else(|| anyhow!("text is required"))?;
            let entry = store.save(scope, text, arg_str(args, "evidence"), session)?;
            Ok(format!("remembered ({}, {}): {}", scope.as_str(), entry.id, one_line(&entry.text)))
        }
        SEARCH_TOOL => {
            let pattern = arg_str(args, "pattern").ok_or_else(|| anyhow!("pattern must be a non-empty string"))?;
            let scope = match arg_str(args, "scope") {
                Some(s) => Some(Scope::parse(s)?),
                None => None,
            };
            if read_only { store.search_readonly(pattern, scope) } else { store.search(pattern, scope) }
        }
        FORGET_TOOL => {
            let id = arg_str(args, "id").ok_or_else(|| anyhow!("id is required"))?;
            store.forget(id)
        }
        other => bail!("unknown memory tool {other}"),
    }
}

/// Rewrite a scope file atomically: write a sibling temp file, then rename.
/// The temp name is unique per process + call so concurrent writers never
/// share (and clobber) one temp file or make each other's rename fail. Any
/// `unknown` lines (records we could not parse on load) are re-emitted verbatim
/// so a rewrite never deletes a malformed hand-edit or a newer-version record.
fn write_all(path: &Path, entries: &[Entry], unknown: &[String]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut body = String::new();
    for entry in entries {
        body.push_str(&serde_json::to_string(entry)?);
        body.push('\n');
    }
    for line in unknown {
        body.push_str(line);
        body.push('\n');
    }
    let tmp = path.with_extension(format!("jsonl.tmp.{}.{:08x}", std::process::id(), fastrand::u32(..)));
    std::fs::write(&tmp, body)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    Ok(())
}

/// A best-effort advisory lock on a scope, held for the duration of a
/// read-modify-write transaction so two nano-coder processes sharing the memory
/// directory serialize instead of losing each other's entries. Released on
/// drop. If the lock is still held after the wait budget the acquire fails
/// rather than breaking it: the timeout measures how long *this* waiter has
/// waited, not how old the lock is, so a live holder mid-transaction (a large
/// store, a scheduling pause) must never have its lock deleted out from under
/// it — that would admit an overlapping writer and let the original holder
/// delete the replacement's lock on drop.
struct FileLock(PathBuf);

impl FileLock {
    fn acquire(path: &Path) -> Result<Self> {
        let lock = path.with_extension("jsonl.lock");
        if let Some(parent) = lock.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match std::fs::OpenOptions::new().write(true).create_new(true).open(&lock) {
                Ok(_) => return Ok(FileLock(lock)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    if std::time::Instant::now() >= deadline {
                        // Still held after the wait budget. It may be a live
                        // holder or a crashed one; we cannot prove which, so we
                        // fail instead of deleting a lock that could be live.
                        // A genuinely abandoned lock is cleared by removing the
                        // stale `*.jsonl.lock` file.
                        bail!("memory scope is locked by another process (timed out acquiring {})", lock.display());
                    }
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                Err(e) => return Err(e.into()),
            }
        }
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// The memory root for a config, defaulting to `<data>/memory` next to
/// `sessions/`.
pub fn default_dir() -> PathBuf {
    crate::config::app_dir(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)).join("memory")
}

/// The project scope key for a working directory: its git remote (normalised),
/// falling back to the git root path. `None` when not in a git repository.
pub fn project_key(cwd: &Path) -> Option<String> {
    if let Some(url) = git_output(cwd, &["config", "--get", "remote.origin.url"]) {
        let url = url.trim();
        if !url.is_empty() {
            return Some(normalize_remote(url));
        }
    }
    git_output(cwd, &["rev-parse", "--show-toplevel"]).map(|root| root.trim().to_string()).filter(|r| !r.is_empty())
}

fn git_output(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new("git").arg("-C").arg(cwd).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

/// A git remote URL reduced to a stable `host/path` label, dropping the scheme,
/// any credentials and a trailing `.git`.
fn normalize_remote(url: &str) -> String {
    let mut s = url.trim();
    for prefix in ["https://", "http://", "ssh://", "git://"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
            break;
        }
    }
    // `git@host:owner/repo` → `host/owner/repo`.
    let s = s.strip_prefix("git@").unwrap_or(s);
    // Drop any remaining `user:pass@` credentials.
    let s = s.rsplit_once('@').map_or(s, |(_, rest)| rest);
    let s = s.replacen(':', "/", 1);
    s.trim_end_matches('/').strip_suffix(".git").unwrap_or(s.trim_end_matches('/')).to_string()
}

/// A filesystem-safe file stem for a project key. Distinct keys always map to
/// distinct files: a hash of the *full original* key is appended unconditionally
/// (the cleaned head alone is not injective — replacing every separator with `-`
/// collapses e.g. `…/a-b/c` and `…/a/b-c` onto one name).
fn sanitize_key(key: &str) -> String {
    let cleaned: String =
        key.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '-' }).collect();
    let cleaned = cleaned.trim_matches('-');
    // FNV-1a over the raw key, so collisions between two different keys are
    // vanishingly unlikely regardless of how cleaning mangled them.
    let mut hash: u64 = 1469598103934665603;
    for b in key.bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(1099511628211);
    }
    // Bound the length but keep a readable head plus the disambiguating hash.
    let head: String = cleaned.chars().take(80).collect();
    if head.is_empty() { format!("{hash:016x}") } else { format!("{head}-{hash:016x}") }
}

/// First line of a fact, clipped for one-line contexts (index, transcript).
fn one_line(text: &str) -> String {
    let first = text.lines().next().unwrap_or("").trim();
    if first.chars().count() > 200 {
        let clipped: String = first.chars().take(200).collect();
        format!("{clipped}…")
    } else {
        first.to_string()
    }
}

/// A snippet of `text` around the first regex match (or its head).
fn snippet(regex: &regex::Regex, text: &str) -> String {
    let (start, end) = regex.find(text).map_or((0, 0), |m| (m.start(), m.end()));
    let lead = SNIPPET_CHARS / 3;
    let from = text[..start].char_indices().rev().nth(lead.saturating_sub(1)).map_or(0, |(i, _)| i);
    let room = SNIPPET_CHARS.saturating_sub(text[from..start].chars().count());
    let to = text[end..].char_indices().nth(room).map_or(text.len(), |(i, _)| end + i);
    let mut out: String = text[from..to].split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 {
        out.insert(0, '…');
    }
    if to < text.len() {
        out.push('…');
    }
    out
}

/// If `text` looks like it contains a secret, a short reason; else `None`.
/// Deliberately conservative — a false negative merely saves a fact the model
/// should not have, which `/memory` can undo, while a false positive blocks a
/// legitimate save.
pub fn looks_like_secret(text: &str) -> Option<&'static str> {
    if text.contains("PRIVATE KEY-----") || text.contains("BEGIN OPENSSH PRIVATE KEY") {
        return Some("private key block");
    }
    // Known token shapes.
    let patterns: &[(&str, &str)] = &[
        (r"\b(gh[pousr])_[A-Za-z0-9]{20,}", "GitHub token"),
        (r"\bgithub_pat_[A-Za-z0-9_]{20,}", "GitHub PAT"),
        (r"\bAKIA[0-9A-Z]{16}\b", "AWS access key id"),
        (r"\bxox[baprs]-[A-Za-z0-9-]{10,}", "Slack token"),
        (r"\bsk-[A-Za-z0-9]{20,}", "API secret key"),
        // Modern prefixed keys keep internal hyphens (e.g. `sk-proj-…`,
        // `sk-ant-…`); allow them so the match does not stop at the first `-`.
        (r"\bsk-[A-Za-z0-9]+-[A-Za-z0-9-]{20,}", "API secret key"),
        (r"\bAIza[0-9A-Za-z_\-]{35}\b", "Google API key"),
        (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", "JWT"),
        // Credentials embedded in a URL authority: `scheme://user:pass@host`.
        // The assignment rule only fires on variable *names* like `password`/
        // `token`, so `DATABASE_URL=postgres://admin:s3cr3t@db/app` slips past
        // every other pattern; catch the `user:pass@` shape directly.
        (r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/:]+:[^\s/@]+@", "credential in URL authority"),
        // `SOMETHING_TOKEN=<value>` / `password: <value>` style assignments.
        (
            r"(?i)\b\w*(secret|password|passwd|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)\w*\s*[:=]\s*[^\s]{8,}",
            "credential assignment",
        ),
    ];
    for (pattern, reason) in patterns {
        if RegexBuilder::new(pattern).build().is_ok_and(|re| re.is_match(text)) {
            return Some(reason);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(dir: &Path) -> Store {
        Store::new(dir.join("memory"), Some("github.com/nanobpm/nano-coder".to_string()), DEFAULT_EXPIRY_DAYS)
    }

    #[test]
    fn saves_searches_and_forgets_across_scopes() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let user = store.save(Scope::User, "python comes from uv, not the system", None, Some("sess-1")).unwrap();
        store.save(Scope::Project, "tests run with `cargo test`, not make", Some("Cargo.toml"), None).unwrap();

        let out = store.search("cargo test", None).unwrap();
        assert!(out.contains("project"), "{out}");
        assert!(out.contains("cargo test"), "{out}");
        assert!(out.contains("evidence: Cargo.toml"), "{out}");

        let scoped = store.search("uv", Some(Scope::User)).unwrap();
        assert!(scoped.contains("python comes from uv"), "{scoped}");
        assert!(store.search("uv", Some(Scope::Project)).unwrap().starts_with("No memories match"));

        let msg = store.forget(&user.id).unwrap();
        assert!(msg.contains("forgot user memory"), "{msg}");
        assert!(store.search("uv", None).unwrap().starts_with("No memories match"));
        assert!(store.forget(&user.id).is_err(), "forgetting a gone id errors");
    }

    #[test]
    fn rejects_secrets_and_overlong_text() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        for secret in [
            "the token is ghp_0123456789abcdef0123456789abcdefABCD",
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIabcdefghijklmnop1234567890",
            "password: hunter2hunter2",
            "aws id AKIAIOSFODNN7EXAMPLE",
            // Modern prefixed OpenAI key: the hyphen after `proj` must not stop
            // detection short of 20 chars (Copilot finding, src/memory.rs).
            "key is sk-proj-abcdef1234567890ABCDEFghijklmnop",
            // A password embedded in a URL authority (`user:pass@host`), which
            // no variable-name rule catches (Copilot finding, src/memory.rs).
            "DATABASE_URL=postgres://admin:s3cr3tPassw0rd@db.example/app",
        ] {
            assert!(store.save(Scope::User, secret, None, None).is_err(), "should reject: {secret}");
        }
        // A pointer to where a secret lives is fine.
        assert!(store.save(Scope::User, "the API key lives in ~/.config/app/creds", None, None).is_ok());
        // A credential-free URL is fine (no `user:pass@`).
        assert!(store.save(Scope::User, "the repo is at https://github.com/nanobpm/nano-coder", None, None).is_ok());
        assert!(store.save(Scope::User, &"x".repeat(MAX_TEXT_CHARS + 1), None, None).is_err());
    }

    #[test]
    fn expires_unused_entries_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("memory"), None, 30);
        let entry = store.save(Scope::User, "an old fact", None, None).unwrap();
        // Backdate it beyond the expiry window directly in the file.
        let path = store.path(Scope::User).unwrap();
        let mut stale = entry.clone();
        stale.last_used = crate::session::now() - chrono::Duration::days(31);
        write_all(&path, &[stale], &[]).unwrap();
        // A read-only reader (`all`) filters the stale entry out of its result
        // but does NOT rewrite the file: it holds no lock, so pruning here could
        // overwrite a concurrent locked save (Copilot finding, src/memory.rs).
        assert_eq!(store.all().unwrap().len(), 0, "stale entry filtered from the result");
        assert!(
            path.exists() && !std::fs::read_to_string(&path).unwrap().trim().is_empty(),
            "unlocked reader leaves the file on disk"
        );
        // A locked mutating op (search bumps last_used) prunes it from disk.
        let _ = store.search("nothing matches this", None).unwrap();
        assert!(
            !path.exists() || std::fs::read_to_string(&path).unwrap().trim().is_empty(),
            "locked writer prunes the stale entry"
        );
    }

    #[test]
    fn search_bumps_last_used() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("memory"), None, 0);
        let entry = store.save(Scope::User, "a fact to keep", None, None).unwrap();
        let path = store.path(Scope::User).unwrap();
        let mut old = entry.clone();
        old.last_used = crate::session::now() - chrono::Duration::days(10);
        write_all(&path, &[old], &[]).unwrap();
        store.search("fact", None).unwrap();
        let reloaded = store.all().unwrap();
        assert_eq!(reloaded.len(), 1);
        assert!(reloaded[0].1.last_used > crate::session::now() - chrono::Duration::minutes(1), "last_used bumped");
    }

    #[test]
    fn index_is_dated_framed_and_capped() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        assert!(store.index(true).is_empty(), "empty store has no index");
        store.save(Scope::User, "python comes from uv", None, None).unwrap();
        store.save(Scope::Project, "tests use cargo test", Some("Cargo.toml"), None).unwrap();
        let index = store.index(true);
        assert!(index.contains("Memory (notes from earlier sessions)"), "{index}");
        assert!(index.contains("verify, not a rule"), "{index}");
        assert!(index.contains("python comes from uv"), "{index}");
        assert!(index.contains("check: Cargo.toml"), "{index}");
        assert!(index.contains(&crate::session::now().format("%Y-%m-%d").to_string()), "dated: {index}");
    }

    #[test]
    fn read_only_index_omits_save_guidance() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        store.save(Scope::User, "a durable fact", None, None).unwrap();
        let writable = store.index(true);
        assert!(writable.contains(SAVE_TOOL), "writable index offers the save tool: {writable}");
        let read_only = store.index(false);
        assert!(!read_only.contains(SAVE_TOOL), "read-only index omits the unavailable save tool: {read_only}");
        assert!(read_only.contains(SEARCH_TOOL), "read-only index still offers search: {read_only}");
    }

    #[test]
    fn preserves_unknown_records_across_rewrites() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("memory"), None, 0);
        let keep = store.save(Scope::User, "a real fact", None, None).unwrap();
        // A hand-edit appends a record the current parser cannot read (a typo
        // and a future-version record).
        let path = store.path(Scope::User).unwrap();
        let mut raw = std::fs::read_to_string(&path).unwrap();
        raw.push_str("not even json\n");
        raw.push_str("{\"unknown_future_field\":true}\n");
        std::fs::write(&path, &raw).unwrap();
        // A mutating op rewrites the scope; the unparsed lines must survive.
        store.save(Scope::User, "another fact", None, None).unwrap();
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(after.contains("not even json"), "malformed record preserved: {after}");
        assert!(after.contains("unknown_future_field"), "future-version record preserved: {after}");
        // The parseable entries are intact.
        let ids: Vec<_> = store.all().unwrap().into_iter().map(|(_, e)| e.id).collect();
        assert!(ids.contains(&keep.id), "existing entry kept: {ids:?}");
    }

    #[test]
    fn absurd_expiry_days_errors_instead_of_panicking() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("memory"), None, u64::MAX);
        let path = store.path(Scope::User).unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        // A present scope file forces the expiry-cutoff computation; an
        // out-of-range `expiry_days` must return an error, never panic Chrono.
        std::fs::write(&path, "").unwrap();
        let err = store.all().unwrap_err();
        assert!(err.to_string().contains("expiry_days"), "config error surfaced: {err}");
    }

    #[test]
    fn project_scope_needs_a_repo_key() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("memory"), None, 0);
        assert!(store.save(Scope::Project, "x", None, None).is_err(), "no project key → error");
        assert!(store.search("x", Some(Scope::Project)).unwrap().starts_with("No memories match"));
        // Search without a scope tolerates the missing project scope.
        store.save(Scope::User, "a user fact", None, None).unwrap();
        assert!(store.search("user fact", None).unwrap().contains("a user fact"));
    }

    #[test]
    fn normalizes_remotes_to_a_stable_key() {
        assert_eq!(normalize_remote("git@github.com:nanobpm/nano-coder.git"), "github.com/nanobpm/nano-coder");
        assert_eq!(normalize_remote("https://github.com/nanobpm/nano-coder.git"), "github.com/nanobpm/nano-coder");
        assert_eq!(normalize_remote("https://user:pass@example.com/a/b"), "example.com/a/b");
        // A readable head is kept, but a disambiguating hash is always appended.
        assert!(sanitize_key("github.com/nanobpm/nano-coder").starts_with("github.com-nanobpm-nano-coder-"));
        assert!(sanitize_key(&"a/".repeat(100)).len() <= 80 + 17);
    }

    #[test]
    fn sanitize_key_is_collision_resistant() {
        // Distinct keys that clean to the same head must not share a file.
        let a = sanitize_key("github.com/acme/a-b/c");
        let b = sanitize_key("github.com/acme/a/b-c");
        assert_ne!(a, b, "keys colliding under naive cleaning must map to distinct files");
        // Stable for a given key.
        assert_eq!(sanitize_key("github.com/acme/a-b/c"), a);
    }

    #[test]
    fn tool_set_depends_on_writability() {
        let read_only: Vec<String> = definitions(false).iter().map(|d| d.name.clone()).collect();
        assert_eq!(read_only, vec![SEARCH_TOOL.to_string()]);
        let writable: Vec<String> = definitions(true).iter().map(|d| d.name.clone()).collect();
        assert!(writable.contains(&SAVE_TOOL.to_string()) && writable.contains(&FORGET_TOOL.to_string()));
    }

    #[test]
    fn run_dispatches_and_reports_saves() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let saved =
            run(&store, SAVE_TOOL, &json!({"scope": "user", "text": "uv provides python"}), Some("s1"), false).unwrap();
        assert!(saved.starts_with("remembered (user"), "{saved}");
        let found = run(&store, SEARCH_TOOL, &json!({"pattern": "python"}), None, false).unwrap();
        assert!(found.contains("uv provides python"), "{found}");
    }
}
