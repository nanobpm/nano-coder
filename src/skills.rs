//! Agent skills: folders with a `SKILL.md` that describe how to do one kind
//! of task.
//!
//! Only each skill's name and description go into the system prompt. The
//! model calls `load_skill` to read a skill when a task matches it, so an
//! unused skill costs one line of context.
//!
//! Skills are found, in order of precedence:
//! 1. in the repository: `.agents/skills`, `.github/skills` and `.claude/skills`
//!    under the git root (any depth, so `skills/<group>/<skill>/SKILL.md` works);
//! 2. in `ai.lock` (written by spm, <https://github.com/camunda/spm-cli>): each
//!    locked skill, and the skills bundled in each locked plugin. The pinned
//!    commit is read from the spm store (`~/.spm/store`) when present, or else
//!    fetched into the nano-coder cache. `spm install` is never run, because it
//!    edits the workspace (`.gitignore`, vendor dirs), which would leak into
//!    commits and PRs;
//! 3. in the user's `~/.agents/skills`.
//!
//! A later skill with the same name as an earlier one is ignored.

use std::collections::{BTreeMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::tools::ToolDefinition;

pub const TOOL_NAME: &str = "load_skill";
const SKILL_FILE: &str = "SKILL.md";
const LOCK_FILE: &str = "ai.lock";
const MANIFEST_FILE: &str = "ai.json";
/// Cap on the `SKILL.md` text returned by `load_skill`.
const MAX_SKILL_BYTES: usize = 32 * 1024;
/// Cap on the skill index in the system prompt.
const MAX_INDEX_BYTES: usize = 8 * 1024;
const MAX_DESCRIPTION_CHARS: usize = 400;
const MAX_LISTED_FILES: usize = 50;
/// How deep below a skills directory to look for `SKILL.md`.
const MAX_SCAN_DEPTH: usize = 4;
const FETCH_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SkillsConfig {
    /// Offer skills (index in the system prompt plus the `load_skill` tool).
    pub enabled: bool,
    /// Skill directories relative to the git root.
    pub dirs: Vec<String>,
    /// User skill directories (`~/` is expanded).
    pub user_dirs: Vec<String>,
    /// Load skills pinned in the repository's `ai.lock`.
    pub ai_lock: bool,
    /// Fetch `ai.lock` commits that are not in the spm store or the cache.
    pub fetch: bool,
    /// Git hosts `ai.lock` entries may be fetched from. `"*"` allows any
    /// host; `"file"` allows `file://` URLs.
    pub allowed_hosts: Vec<String>,
}

impl Default for SkillsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            dirs: [".agents/skills", ".github/skills", ".claude/skills"].map(String::from).to_vec(),
            user_dirs: vec!["~/.agents/skills".to_string()],
            ai_lock: true,
            fetch: true,
            allowed_hosts: vec!["github.com".to_string()],
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Workspace,
    User,
    Lock { git: String, commit: String },
}

impl Source {
    fn label(&self) -> String {
        match self {
            Source::Workspace => "repository".to_string(),
            Source::User => "user".to_string(),
            Source::Lock { git, commit } => format!("ai.lock: {git} @ {}", &commit[..commit.len().min(8)]),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Skill {
    pub name: String,
    pub description: String,
    /// The skill's folder (contains `SKILL.md`).
    pub dir: PathBuf,
    pub source: Source,
}

/// Where to look outside the repository (injectable for tests).
#[derive(Debug, Clone, Default)]
pub struct Locations {
    pub home: Option<PathBuf>,
    /// spm's content store (`$SPM_HOME/store`, default `~/.spm/store`).
    pub spm_store: Option<PathBuf>,
    /// nano-coder's own checkout cache for `ai.lock` commits.
    pub cache: Option<PathBuf>,
}

impl Locations {
    pub fn from_env() -> Self {
        let home = dirs::home_dir();
        let spm_home = std::env::var_os("SPM_HOME").map(PathBuf::from).or_else(|| home.as_ref().map(|h| h.join(".spm")));
        Self {
            spm_store: spm_home.map(|h| h.join("store")),
            cache: dirs::cache_dir().map(|c| c.join(crate::config::APP_NAME).join("skills")),
            home,
        }
    }
}

#[derive(Debug, Default)]
pub struct Skills {
    pub skills: Vec<Skill>,
    /// Problems found while loading (bad lock entries, failed fetches...).
    pub warnings: Vec<String>,
}

impl Skills {
    pub fn discover(cwd: &Path, config: &SkillsConfig) -> Self {
        Self::discover_in(cwd, config, &Locations::from_env())
    }

    pub fn discover_in(cwd: &Path, config: &SkillsConfig, locations: &Locations) -> Self {
        let mut this = Self::default();
        let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
        let root = crate::instructions::git_root(&cwd).unwrap_or(cwd);
        // Confine workspace skill discovery to the repository root: a configured
        // directory that canonicalizes outside it (e.g. `.agents/skills` committed
        // as a symlink to an external directory) must be rejected.
        let confine = root.canonicalize().ok();
        let mut seen = HashSet::new();
        for dir in &config.dirs {
            this.add_dir(&root.join(dir), Source::Workspace, confine.as_deref(), &mut seen);
        }
        if config.ai_lock {
            this.add_lock(&root, config, locations, &mut seen);
        }
        for dir in &config.user_dirs {
            let path = match (dir.strip_prefix("~/"), &locations.home) {
                (Some(rest), Some(home)) => home.join(rest),
                (Some(_), None) => continue,
                (None, _) => PathBuf::from(dir),
            };
            this.add_dir(&path, Source::User, None, &mut seen);
        }
        this
    }

    fn add_dir(&mut self, dir: &Path, source: Source, confine: Option<&Path>, seen: &mut HashSet<String>) {
        // Canonicalize the configured directory and keep discovery inside it, so
        // a `SKILL.md` symlink or a skill-directory symlink cannot pull a file
        // from outside the configured root into the prompt.
        let Ok(root) = dir.canonicalize() else { return };
        // For workspace dirs a confinement boundary (the repository root) is set:
        // reject a configured directory whose canonical target escapes it, so a
        // symlinked skills root cannot bypass repository containment.
        if confine.is_some_and(|c| !root.starts_with(c)) {
            return;
        }
        let mut found = Vec::new();
        scan(&root, &root, 0, &mut found);
        for skill_dir in found {
            if let Some(skill) = read_skill(&skill_dir, None, source.clone()) {
                self.push(skill, seen);
            }
        }
    }

    fn push(&mut self, skill: Skill, seen: &mut HashSet<String>) {
        if seen.insert(skill.name.clone()) {
            self.skills.push(skill);
        }
    }

    fn add_lock(&mut self, root: &Path, config: &SkillsConfig, locations: &Locations, seen: &mut HashSet<String>) {
        let lock_path = root.join(LOCK_FILE);
        if !lock_path.is_file() {
            if root.join(MANIFEST_FILE).is_file() {
                self.warnings.push(format!(
                    "{MANIFEST_FILE} has no {LOCK_FILE} next to it, so its skills are not loaded (run spm to pin them)"
                ));
            }
            return;
        }
        let lock: Lockfile = match std::fs::read_to_string(&lock_path).map_err(anyhow::Error::from).and_then(|t| Ok(serde_json::from_str(&t)?)) {
            Ok(lock) => lock,
            Err(e) => {
                self.warnings.push(format!("{LOCK_FILE}: {e}"));
                return;
            }
        };
        let entries = lock.skills.iter().map(|(n, l)| (n, l, false)).chain(lock.plugins.iter().map(|(n, l)| (n, l, true)));
        for (name, locked, is_plugin) in entries {
            let kind = if is_plugin { "plugin" } else { "skill" };
            match self.load_locked(name, locked, is_plugin, config, locations, seen) {
                Ok(()) => {}
                Err(e) => self.warnings.push(format!("{LOCK_FILE} {kind} `{name}`: {e:#}")),
            }
        }
    }

    fn load_locked(
        &mut self,
        name: &str,
        locked: &Locked,
        is_plugin: bool,
        config: &SkillsConfig,
        locations: &Locations,
        seen: &mut HashSet<String>,
    ) -> Result<()> {
        locked.validate(name)?;
        let checkout = checkout_for(locked, config, locations)?;
        let checkout = checkout.canonicalize()?;
        let content = within(&checkout, &checkout.join(locked.path.as_deref().unwrap_or(".")))
            .with_context(|| format!("path `{}` is missing or outside the checkout", locked.path.as_deref().unwrap_or(".")))?;
        let source = Source::Lock { git: locked.git.clone(), commit: locked.commit.clone() };
        if !is_plugin {
            within(&checkout, &content.join(SKILL_FILE)).with_context(|| format!("no {SKILL_FILE} inside the checkout at the locked path"))?;
            let skill = read_skill(&content, Some(name), source).with_context(|| format!("no {SKILL_FILE} in the locked path"))?;
            self.push(skill, seen);
            return Ok(());
        }
        let skills_rel = plugin_skills_dir(&content)?;
        let Some(skills_dir) = within(&checkout, &content.join(&skills_rel)) else {
            return Ok(());
        };
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(&skills_dir)?.filter_map(|e| e.ok().map(|e| e.path())).collect();
        dirs.sort();
        for dir in dirs {
            let Some(dir) = within(&checkout, &dir).filter(|d| within(&checkout, &d.join(SKILL_FILE)).is_some()) else {
                continue;
            };
            if let Some(skill) = read_skill(&dir, None, source.clone()) {
                self.push(skill, seen);
            }
        }
        Ok(())
    }

    pub fn is_empty(&self) -> bool {
        self.skills.is_empty()
    }

    pub fn names(&self) -> Vec<String> {
        self.skills.iter().map(|s| s.name.clone()).collect()
    }

    /// The skill index appended to the system prompt (empty without skills).
    pub fn render_index(&self) -> String {
        if self.skills.is_empty() {
            return String::new();
        }
        let mut out = format!(
            "\n\n# Skills\n\nSkills are instructions for specific kinds of task. When a task matches a skill below, \
             call `{TOOL_NAME}` with its name and follow what it says before you start. Load only the skills that apply.\n"
        );
        // Account for the heading already in `out` so the whole rendered index
        // (heading + lines + omitted summary) stays within MAX_INDEX_BYTES.
        let mut budget = MAX_INDEX_BYTES.saturating_sub(out.len());
        let mut omitted = Vec::new();
        for skill in &self.skills {
            let line = format!("\n- `{}`: {}", skill.name, skill.description);
            if line.len() > budget {
                omitted.push(format!("`{}`", skill.name));
                continue;
            }
            budget -= line.len();
            out.push_str(&line);
        }
        if !omitted.is_empty() {
            out.push_str(&format!("\n- Also (descriptions omitted for space): {}", omitted.join(", ")));
        }
        // Enforce the hard cap even if the omitted summary overruns the budget.
        if out.len() > MAX_INDEX_BYTES {
            let mut end = MAX_INDEX_BYTES;
            while !out.is_char_boundary(end) {
                end -= 1;
            }
            out.truncate(end);
        }
        out
    }

    /// Run the `load_skill` tool.
    pub fn load(&self, args: &Value) -> Result<String> {
        let parsed;
        let args = match args {
            Value::String(text) => {
                parsed = serde_json::from_str::<Value>(text).unwrap_or(Value::Null);
                &parsed
            }
            other => other,
        };
        let Some(name) = args.get("name").and_then(Value::as_str).map(str::trim) else {
            bail!("{TOOL_NAME} needs `name`");
        };
        let Some(skill) = self.skills.iter().find(|s| s.name == name) else {
            bail!("no skill named {name:?}; available: {}", self.names().join(", "));
        };
        let text = std::fs::read(skill.dir.join(SKILL_FILE)).with_context(|| format!("reading {}", skill.dir.join(SKILL_FILE).display()))?;
        let text = String::from_utf8_lossy(&text);
        let (_, body) = front_matter(&text);
        let body = cap(body.trim(), MAX_SKILL_BYTES);
        let mut out = format!(
            "Skill: {}\nSource: {}\nDirectory: {}\n\n{body}",
            skill.name,
            skill.source.label(),
            skill.dir.display()
        );
        let mut files = Vec::new();
        list_files(&skill.dir, &skill.dir, 0, &mut files);
        files.retain(|f| f != SKILL_FILE);
        if !files.is_empty() {
            out.push_str("\n\nOther files in this skill (paths relative to its directory; read them with read_file when the skill refers to them):");
            let total = files.len();
            for file in files.iter().take(MAX_LISTED_FILES) {
                out.push_str(&format!("\n- {file}"));
            }
            if total > MAX_LISTED_FILES {
                out.push_str(&format!("\n- ... and {} more", total - MAX_LISTED_FILES));
            }
        }
        Ok(out)
    }
}

pub fn definition() -> ToolDefinition {
    ToolDefinition::new(
        TOOL_NAME,
        "Load a skill: step-by-step instructions for a kind of task, listed under \"Skills\" in the system prompt. \
         Call it before starting a task that matches a skill's description, then follow the instructions.",
        json!({
            "type": "object",
            "properties": {
                "name": { "type": "string", "description": "The skill's name, exactly as listed." }
            },
            "required": ["name"]
        }),
    )
}

/// Collect folders containing `SKILL.md` under `dir`. A skill's own
/// subfolders are not searched. `root` (already canonical) bounds discovery:
/// a directory or `SKILL.md` whose real path escapes it (e.g. via a symlink)
/// is skipped, so discovery cannot follow a symlink outside the configured root.
fn scan(root: &Path, dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if within(root, &dir.join(SKILL_FILE)).is_some_and(|p| p.is_file()) {
        out.push(dir.to_path_buf());
        return;
    }
    if depth >= MAX_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .filter_map(|e| within(root, &e.path()))
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    for sub in dirs {
        scan(root, &sub, depth + 1, out);
    }
}

fn read_skill(dir: &Path, name_override: Option<&str>, source: Source) -> Option<Skill> {
    let bytes = std::fs::read(dir.join(SKILL_FILE)).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let (fields, body) = front_matter(&text);
    let field = |key: &str| fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()).filter(|v| !v.is_empty());
    let name = name_override
        .map(str::to_string)
        .or_else(|| field("name"))
        .or_else(|| dir.file_name().map(|n| n.to_string_lossy().into_owned()))?;
    let name = name.trim().to_string();
    if name.is_empty() || name.contains(['/', '\\', '`']) {
        return None;
    }
    let description = field("description")
        .or_else(|| body.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#')).map(str::to_string))
        .unwrap_or_else(|| "(no description)".to_string());
    let description = description.split_whitespace().collect::<Vec<_>>().join(" ");
    let description = if description.chars().count() > MAX_DESCRIPTION_CHARS {
        format!("{}...", description.chars().take(MAX_DESCRIPTION_CHARS).collect::<String>())
    } else {
        description
    };
    Some(Skill { name, description, dir: dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf()), source })
}

/// Split YAML front matter (`---` ... `---`) into top-level `key: value`
/// pairs and the body. Handles quoted values and `>` / `|` blocks, which is
/// all SKILL.md files use.
fn front_matter(text: &str) -> (Vec<(String, String)>, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.split_inclusive('\n');
    let Some(first) = lines.next() else { return (Vec::new(), text) };
    if first.trim_end() != "---" {
        return (Vec::new(), text);
    }
    let mut offset = first.len();
    let mut yaml = Vec::new();
    let mut closed = false;
    for line in lines {
        offset += line.len();
        if line.trim_end() == "---" {
            closed = true;
            break;
        }
        yaml.push(line.trim_end_matches(['\n', '\r']));
    }
    if !closed {
        return (Vec::new(), text);
    }
    let mut fields: Vec<(String, String)> = Vec::new();
    let mut block: Option<(String, bool)> = None;
    for line in yaml {
        let indented = line.starts_with([' ', '\t']);
        if indented {
            if let Some((key, literal)) = &block {
                let entry = fields.iter_mut().find(|(k, _)| k == key).expect("block key");
                if !entry.1.is_empty() {
                    entry.1.push(if *literal { '\n' } else { ' ' });
                }
                entry.1.push_str(line.trim());
            }
            continue;
        }
        block = None;
        let Some((key, value)) = line.split_once(':') else { continue };
        let key = key.trim().to_string();
        let value = value.trim();
        if matches!(value, "" | ">" | ">-" | ">+" | "|" | "|-" | "|+") {
            block = Some((key.clone(), value.starts_with('|')));
            fields.push((key, String::new()));
            continue;
        }
        let unquoted = if value.len() >= 2 && ((value.starts_with('"') && value.ends_with('"')) || (value.starts_with('\'') && value.ends_with('\''))) {
            &value[1..value.len() - 1]
        } else {
            value
        };
        fields.push((key, unquoted.to_string()));
    }
    (fields, &text[offset.min(text.len())..])
}

fn cap(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n\n[... truncated: {end} of {} bytes shown; read the rest with read_file]", &text[..end], text.len())
}

fn list_files(root: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_SCAN_DEPTH || out.len() > MAX_LISTED_FILES * 4 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.path())
        .collect();
    paths.sort();
    for path in paths {
        // Only recurse into / advertise entries whose real target stays inside
        // the skill directory: a sibling symlink pointing outside the (locked)
        // checkout must not be listed and later opened by `read_file`.
        let Some(real) = within(root, &path) else { continue };
        if real.is_dir() {
            list_files(root, &real, depth + 1, out);
        } else if let Ok(rel) = real.strip_prefix(root) {
            out.push(rel.display().to_string());
        }
    }
}

/// `path` canonicalized, if it exists and stays inside `root` (already canonical).
fn within(root: &Path, path: &Path) -> Option<PathBuf> {
    let real = path.canonicalize().ok()?;
    (real.starts_with(root) && !real.components().any(|c| c.as_os_str() == ".git")).then_some(real)
}

#[derive(Debug, Default, Deserialize)]
struct Lockfile {
    #[serde(default)]
    skills: BTreeMap<String, Locked>,
    #[serde(default)]
    plugins: BTreeMap<String, Locked>,
}

#[derive(Debug, Deserialize)]
struct Locked {
    git: String,
    commit: String,
    #[serde(default)]
    path: Option<String>,
    store: String,
}

impl Locked {
    /// `ai.lock` is committed to the repository, so it is untrusted input. The
    /// checks match spm's own (`lockfile.rs`).
    fn validate(&self, name: &str) -> Result<()> {
        if name.is_empty() || name == "." || name == ".." || name.contains(['/', '\\', '\0']) {
            bail!("invalid name");
        }
        if self.commit.len() != 40 || !self.commit.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)) {
            bail!("commit `{}` is not a full 40-character lowercase SHA", self.commit);
        }
        let expected = store_key(&self.git, &self.commit);
        if self.store != expected {
            bail!("store key `{}` does not match `{expected}` derived from git+commit", self.store);
        }
        if let Some(path) = &self.path
            && !relative_inside(path)
        {
            bail!("path `{path}` must be relative and stay inside the repository");
        }
        Ok(())
    }
}

fn relative_inside(path: &str) -> bool {
    let path = Path::new(path);
    !path.as_os_str().is_empty() && path.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}

/// spm's store key: `<repo-name hint>-<FNV-1a 64 of the URL>@<sha>`.
fn store_key(url: &str, sha: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in url.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let hint: String = url
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or(url)
        .trim_end_matches(".git")
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(32)
        .collect();
    format!("{hint}-{h:016x}@{sha}")
}

/// The skills folder a plugin declares in `.claude-plugin/plugin.json`
/// (default `skills`).
fn plugin_skills_dir(plugin: &Path) -> Result<String> {
    #[derive(Deserialize, Default)]
    struct PluginJson {
        #[serde(default)]
        skills: Option<String>,
    }
    let path = plugin.join(".claude-plugin").join("plugin.json");
    let meta: PluginJson = match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?,
        Err(_) => PluginJson::default(),
    };
    let rel = meta.skills.as_deref().unwrap_or("skills").trim_start_matches("./").trim_end_matches('/');
    let rel = if rel.is_empty() { "skills" } else { rel };
    if !relative_inside(rel) {
        bail!("plugin skills dir `{rel}` must stay inside the plugin");
    }
    Ok(rel.to_string())
}

fn head_is(dir: &Path, commit: &str) -> bool {
    std::fs::read_to_string(dir.join(".git").join("HEAD")).is_ok_and(|head| head.trim() == commit)
}

/// A checkout of the locked commit: the spm store's if it has one, else the
/// cache's, fetching into the cache when allowed.
fn checkout_for(locked: &Locked, config: &SkillsConfig, locations: &Locations) -> Result<PathBuf> {
    let candidates = [&locations.spm_store, &locations.cache];
    if let Some(dir) = candidates.iter().filter_map(|base| base.as_ref().map(|b| b.join(&locked.store))).find(|d| head_is(d, &locked.commit)) {
        return Ok(dir);
    }
    if !config.fetch {
        bail!("commit is not in the spm store and fetching is off (skills.fetch = false)");
    }
    let host = git_host(&locked.git).unwrap_or_default();
    let allowed = config.allowed_hosts.iter().any(|h| h == "*" || h.eq_ignore_ascii_case(&host));
    if !allowed {
        bail!("host {host:?} is not in skills.allowed_hosts, so {} was not fetched", locked.git);
    }
    let cache = locations.cache.as_ref().context("no cache directory")?;
    std::fs::create_dir_all(cache)?;
    let dest = cache.join(&locked.store);
    let tmp = cache.join(format!(".tmp-{}-{}", std::process::id(), locked.store));
    let _ = std::fs::remove_dir_all(&tmp);
    let fetched = fetch_commit(&locked.git, &locked.commit, &tmp);
    if let Err(e) = fetched {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(e.context(format!("fetching {} @ {}", locked.git, &locked.commit[..8])));
    }
    let _ = std::fs::remove_dir_all(&dest);
    if std::fs::rename(&tmp, &dest).is_err() {
        // Another process may have fetched it at the same time.
        let _ = std::fs::remove_dir_all(&tmp);
    }
    if !head_is(&dest, &locked.commit) {
        bail!("checkout of {} @ {} is not at the locked commit", locked.git, &locked.commit[..8]);
    }
    Ok(dest)
}

/// Host of a git URL (`https://host/...`, `ssh://user@host:port/...`,
/// `user@host:path`), or `file` for `file://` URLs.
fn git_host(url: &str) -> Option<String> {
    if url.starts_with("file://") {
        return Some("file".to_string());
    }
    let authority = if let Some((_, rest)) = url.split_once("://") {
        rest.split('/').next()?
    } else {
        url.split_once(':')?.0
    };
    let host = authority.rsplit('@').next()?;
    let host = host.split(':').next()?;
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

fn fetch_commit(url: &str, sha: &str, dest: &Path) -> Result<()> {
    std::fs::create_dir_all(dest)?;
    git(dest, &["init", "-q"])?;
    git(dest, &["remote", "add", "origin", url])?;
    if git(dest, &["fetch", "-q", "--depth", "1", "origin", sha]).is_err() {
        git(dest, &["fetch", "-q", "origin"])?;
    }
    git(dest, &["-c", "advice.detachedHead=false", "checkout", "-q", "--detach", sha])
}

fn git(dir: &Path, args: &[&str]) -> Result<()> {
    let mut child = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("running git")?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            if status.success() {
                return Ok(());
            }
            let mut stderr = String::new();
            if let Some(mut pipe) = child.stderr.take() {
                use std::io::Read;
                let _ = pipe.read_to_string(&mut stderr);
            }
            bail!("git {}: {}", args.join(" "), stderr.trim());
        }
        if started.elapsed() > FETCH_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            bail!("git {} timed out", args.join(" "));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn skill_md(name: &str, description: &str) -> String {
        format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\nDo the {name} thing.\n")
    }

    fn run_git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .args(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// A git repo with one commit; returns its HEAD.
    fn make_repo(dir: &Path, files: &[(&str, String)]) -> String {
        for (path, text) in files {
            write(&dir.join(path), text);
        }
        run_git(dir, &["init", "-q"]);
        run_git(dir, &["add", "-A"]);
        run_git(dir, &["commit", "-qm", "init"]);
        run_git(dir, &["rev-parse", "HEAD"])
    }

    fn locations(base: &Path) -> Locations {
        Locations { home: Some(base.join("home")), spm_store: Some(base.join("spm/store")), cache: Some(base.join("cache")) }
    }

    fn config() -> SkillsConfig {
        SkillsConfig { allowed_hosts: vec!["file".into()], ..Default::default() }
    }

    #[test]
    fn parses_front_matter_blocks_and_quotes() {
        let (fields, body) = front_matter("---\nname: \"pdf\"\ndescription: >\n  Fill PDF forms\n  and merge files.\nlicense: MIT\n---\nBody\n");
        assert_eq!(fields[0], ("name".into(), "pdf".into()));
        assert_eq!(fields[1], ("description".into(), "Fill PDF forms and merge files.".into()));
        assert_eq!(fields[2], ("license".into(), "MIT".into()));
        assert_eq!(body, "Body\n");
        let (fields, body) = front_matter("# No front matter\n");
        assert!(fields.is_empty());
        assert_eq!(body, "# No front matter\n");
    }

    #[test]
    fn discovers_repository_and_user_skills_with_precedence() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        write(&repo.join(".agents/skills/review/SKILL.md"), &skill_md("review", "Review a PR."));
        write(&repo.join(".claude/skills/group/deploy/SKILL.md"), &skill_md("deploy", "Deploy it."));
        write(&repo.join(".agents/skills/review/scripts/check.sh"), "echo ok");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        let home = dir.path().join("home");
        write(&home.join(".agents/skills/review/SKILL.md"), &skill_md("review", "User review (shadowed)."));
        write(&home.join(".agents/skills/notes/SKILL.md"), "# Notes\n\nKeep notes tidy.\n");

        let skills = Skills::discover_in(&repo.join("sub"), &config(), &locations(dir.path()));
        assert_eq!(skills.names(), ["review", "deploy", "notes"]);
        assert_eq!(skills.skills[0].source, Source::Workspace);
        assert_eq!(skills.skills[2].source, Source::User);
        assert_eq!(skills.skills[2].description, "Keep notes tidy.");
        assert!(skills.warnings.is_empty());

        let index = skills.render_index();
        assert!(index.contains("# Skills") && index.contains("- `review`: Review a PR.") && !index.contains("shadowed"));

        let loaded = skills.load(&json!({ "name": "review" })).unwrap();
        assert!(loaded.contains("Do the review thing.") && !loaded.contains("description:"));
        assert!(loaded.contains("- scripts/check.sh"), "{loaded}");
        assert!(skills.load(&json!({ "name": "nope" })).unwrap_err().to_string().contains("available: review, deploy, notes"));
    }

    #[test]
    fn no_skills_means_no_index() {
        let dir = tempfile::tempdir().unwrap();
        let skills = Skills::discover_in(dir.path(), &config(), &locations(dir.path()));
        assert!(skills.is_empty() && skills.render_index().is_empty());
    }

    #[test]
    fn loads_ai_lock_skills_and_plugin_skills_by_fetching_into_the_cache() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        let sha = make_repo(
            &src,
            &[
                ("skills/lint/SKILL.md", skill_md("lint-upstream-name", "Lint the code.")),
                ("plugin/.claude-plugin/plugin.json", r#"{"name":"p","skills":"./bundled"}"#.to_string()),
                ("plugin/bundled/triage/SKILL.md", skill_md("triage", "Triage issues.")),
            ],
        );
        let url = format!("file://{}", src.display());
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let entry = |path: &str| json!({ "git": url, "reference": "branch:main", "commit": sha, "path": path, "store": store_key(&url, &sha) });
        write(&repo.join("ai.lock"), &json!({ "skills": { "lint": entry("skills/lint") }, "plugins": { "p": entry("plugin") } }).to_string());

        let skills = Skills::discover_in(&repo, &config(), &locations(dir.path()));
        assert!(skills.warnings.is_empty(), "{:?}", skills.warnings);
        assert_eq!(skills.names(), ["lint", "triage"]);
        assert!(matches!(&skills.skills[0].source, Source::Lock { commit, .. } if *commit == sha));
        assert!(head_is(&dir.path().join("cache").join(store_key(&url, &sha)), &sha));
        // The workspace is left alone.
        assert_eq!(std::fs::read_dir(&repo).unwrap().count(), 2);

        // Second run reads the cache; fetching is not needed.
        let offline = SkillsConfig { fetch: false, ..config() };
        assert_eq!(Skills::discover_in(&repo, &offline, &locations(dir.path())).names(), ["lint", "triage"]);
    }

    #[test]
    fn prefers_the_spm_store_and_guards_untrusted_lock_entries() {
        let dir = tempfile::tempdir().unwrap();
        let url = "https://github.com/acme/skills.git";
        let sha = "a".repeat(40);
        let store = dir.path().join("spm/store").join(store_key(url, &sha));
        write(&store.join(".git/HEAD"), &format!("{sha}\n"));
        write(&store.join("fmt/SKILL.md"), &skill_md("fmt", "Format files."));
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let good = json!({ "git": url, "reference": "tag:v1", "commit": sha, "path": "fmt", "store": store_key(url, &sha) });
        let escape = json!({ "git": url, "reference": "tag:v1", "commit": sha, "path": "../../etc", "store": store_key(url, &sha) });
        let forged = json!({ "git": url, "reference": "tag:v1", "commit": sha, "path": "fmt", "store": "other@x" });
        write(&dir.path().join("secret/SKILL.md"), "---\nname: secret\ndescription: TOP SECRET\n---\n");
        std::fs::create_dir_all(store.join("leak")).unwrap();
        std::os::unix::fs::symlink(dir.path().join("secret/SKILL.md"), store.join("leak/SKILL.md")).unwrap();
        let leak = json!({ "git": url, "reference": "tag:v1", "commit": sha, "path": "leak", "store": store_key(url, &sha) });
        let short = json!({ "git": url, "reference": "tag:v1", "commit": "abc", "store": "x" });
        let other_host = json!({ "git": "https://evil.example/x.git", "reference": "tag:v1", "commit": "b".repeat(40), "store": store_key("https://evil.example/x.git", &"b".repeat(40)) });
        write(
            &repo.join("ai.lock"),
            &json!({ "skills": { "fmt": good, "escape": escape, "forged": forged, "leak": leak, "short": short, "other": other_host } }).to_string(),
        );

        let skills = Skills::discover_in(&repo, &SkillsConfig::default(), &locations(dir.path()));
        assert_eq!(skills.names(), ["fmt"]);
        let warnings = skills.warnings.join("\n");
        assert!(warnings.contains("`escape`: path `../../etc` must be relative"), "{warnings}");
        assert!(warnings.contains("`forged`: store key"), "{warnings}");
        assert!(warnings.contains("`short`: commit"), "{warnings}");
        assert!(warnings.contains("`leak`: no SKILL.md inside the checkout"), "{warnings}");
        assert!(warnings.contains("`other`: host \"evil.example\" is not in skills.allowed_hosts"), "{warnings}");
    }

    #[test]
    fn warns_about_ai_json_without_a_lock() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        write(&dir.path().join("ai.json"), "{}");
        let skills = Skills::discover_in(dir.path(), &config(), &locations(dir.path()));
        assert!(skills.warnings[0].contains("ai.json has no ai.lock"));
    }

    #[test]
    fn parses_git_hosts() {
        assert_eq!(git_host("https://github.com/a/b.git").as_deref(), Some("github.com"));
        assert_eq!(git_host("ssh://git@GitHub.com:22/a/b").as_deref(), Some("github.com"));
        assert_eq!(git_host("git@github.com:a/b.git").as_deref(), Some("github.com"));
        assert_eq!(git_host("file:///tmp/x").as_deref(), Some("file"));
    }

    #[test]
    fn store_key_matches_spm() {
        // Golden value of spm's `store_key` (lockfile.rs) for this URL and commit.
        assert_eq!(
            store_key("https://github.com/camunda/skills.git", &"0".repeat(40)),
            format!("skills-f3b38a5efdfe31f3@{}", "0".repeat(40))
        );
    }
}
