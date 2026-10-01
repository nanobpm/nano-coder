use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::providers::ProviderConfig;

/// Agent configuration
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Config {
    /// `provider/model` (e.g. `anthropic/claude-sonnet-4-5`), or a bare model
    /// name on `default_provider`.
    pub model: String,
    /// Provider for model specs without a known provider prefix.
    pub default_provider: String,
    pub temperature: f64,
    pub max_tokens: i32,
    pub system_prompt: String,
    /// Legacy: applied to `default_provider` (which becomes `openai` if it was `mock`).
    pub api_key: Option<String>,
    /// Legacy: applied to `default_provider` (which becomes `openai` if it was `mock`).
    pub base_url: Option<String>,
    /// Maximum LLM calls per user input; 0 means unbounded.
    pub max_iterations: usize,
    /// Persist conversations as JSONL session logs.
    pub persist_sessions: bool,
    /// Session log directory (default: platform data dir/nano-coder/sessions).
    pub session_dir: Option<PathBuf>,
    /// Default timeout for the bash tool, in seconds.
    pub bash_timeout_secs: u64,
    /// Provider definitions; entries named after a built-in preset override it.
    pub providers: HashMap<String, ProviderConfig>,
    /// Context window override in tokens (default: provider `context_window`,
    /// else a per-model estimate).
    pub context_window: Option<usize>,
    /// Summarize older messages when the context passes the threshold.
    pub auto_compact: bool,
    /// Fraction of the context window that triggers auto-compaction.
    pub auto_compact_threshold: f64,
    /// How compaction treats the history it folds away (see `CompactionMode`).
    pub compaction_mode: CompactionMode,
    /// How much the interactive CLI prints (and whether hook events are logged).
    pub verbosity: crate::ui::Verbosity,
    /// Which interactive renderer to use: `frame` (the default; app-owned,
    /// re-renders on a width change) or `legacy` (scroll region).
    pub renderer: crate::frame::RendererMode,
    /// Start each message in the interactive CLI with the local time.
    pub timestamps: bool,
    /// Add AGENTS.md (and the like) from the git root down to the working
    /// directory to the system prompt, and nested ones as files are touched.
    pub project_instructions: bool,
    /// Instruction file names tried in each directory; the first found is used.
    pub project_instruction_files: Vec<String>,
    /// Offer the `plan_*` tools and restate the plan after compaction.
    pub plan_tools: bool,
    /// Offer the `report_outcome` tool (an explicit completed/blocked signal).
    pub outcome_tool: bool,
    /// Append `<system-reminder>` notes to tool results (e.g. a stale plan).
    pub reminders: bool,
    /// Agent skills (`SKILL.md` folders and `ai.lock` entries).
    pub skills: crate::skills::SkillsConfig,
    /// Allow/deny rules and built-in guards checked before each tool call.
    pub permissions: crate::permissions::PermissionsConfig,
    /// OS sandbox for shell commands (off by default).
    pub sandbox: crate::sandbox::SandboxConfig,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            model: "gpt-4o-mini".to_string(),
            default_provider: "mock".to_string(),
            temperature: 0.7,
            max_tokens: 4096,
            system_prompt: "You are a helpful assistant with access to tools.".to_string(),
            api_key: None,
            base_url: None,
            max_iterations: 0,
            persist_sessions: true,
            session_dir: None,
            bash_timeout_secs: crate::bash::DEFAULT_TIMEOUT_SECS,
            providers: HashMap::new(),
            context_window: None,
            auto_compact: true,
            auto_compact_threshold: 0.8,
            compaction_mode: CompactionMode::Standard,
            verbosity: crate::ui::Verbosity::Normal,
            renderer: crate::frame::RendererMode::default(),
            timestamps: true,
            project_instructions: true,
            project_instruction_files: crate::instructions::DEFAULT_FILES.iter().map(|s| s.to_string()).collect(),
            plan_tools: true,
            outcome_tool: true,
            reminders: true,
            skills: crate::skills::SkillsConfig::default(),
            permissions: crate::permissions::PermissionsConfig::default(),
            sandbox: crate::sandbox::SandboxConfig::default(),
        }
    }
}

impl Config {
    /// Provider table and default provider after applying legacy
    /// top-level `api_key` / `base_url`.
    pub fn effective_providers(&self) -> (HashMap<String, ProviderConfig>, String) {
        let mut providers = self.providers.clone();
        let mut default_provider = self.default_provider.clone();
        if self.api_key.is_some() || self.base_url.is_some() {
            if default_provider == "mock" {
                default_provider = "openai".to_string();
            }
            let legacy =
                ProviderConfig { api_key: self.api_key.clone(), base_url: self.base_url.clone(), ..Default::default() };
            let entry = providers.remove(&default_provider).unwrap_or_default();
            // Explicit [providers.*] settings win over the legacy fields.
            providers.insert(default_provider.clone(), legacy.merged_with(&entry));
        }
        (providers, default_provider)
    }

    pub fn session_dir(&self) -> PathBuf {
        self.session_dir.clone().unwrap_or_else(crate::session::default_dir)
    }
}

/// What compaction leaves the agent of the messages it folds away.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionMode {
    /// A summary only.
    #[default]
    Standard,
    /// A summary citing `#N` log lines, plus `history_search` / `history_read`
    /// to recover the original messages from the session log.
    Smart,
}

impl CompactionMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Smart => "smart",
        }
    }
}

/// Configuration manager
pub struct ConfigManager {
    config_path: PathBuf,
    config: Config,
}

pub const APP_NAME: &str = "nano-coder";
/// Directory name used before the rename to nano-coder; still read when present.
const LEGACY_APP_NAME: &str = "agentic-harness";

/// `<base>/nano-coder`, or the pre-rename `<base>/agentic-harness` when only that exists.
pub fn app_dir(base: &Path) -> PathBuf {
    let current = base.join(APP_NAME);
    let legacy = base.join(LEGACY_APP_NAME);
    if !current.exists() && legacy.exists() { legacy } else { current }
}

/// Outcome of attempting to migrate one legacy directory.
#[derive(Debug, PartialEq, Eq)]
pub enum Migration {
    /// Nothing to do: no legacy directory to move, or the move already happened
    /// and the compatibility link is in place.
    None,
    /// Moved `from` to `to`, and the compatibility symlink at `from` is in place.
    Moved { from: PathBuf, to: PathBuf },
    /// The data lives at `to` (moved just now, or by an earlier run) but the
    /// compatibility symlink at `from` could not be (re)created, so an older
    /// nano-coder still pointed at `from` can no longer reach the moved data.
    /// This is retried on every later start until the link is restored.
    LinkFailed { from: PathBuf, to: PathBuf, err: String },
}

/// True when `from` is already the compatibility symlink we would create, i.e. a
/// symlink whose target is the relative [`APP_NAME`]. Used to treat a racing
/// `AlreadyExists` as success rather than a spurious failure.
fn compat_link_is_valid(from: &Path) -> bool {
    fs::read_link(from).is_ok_and(|target| target == Path::new(APP_NAME))
}

/// Create the compatibility symlink `from -> APP_NAME` so an older nano-coder
/// still pointed at the legacy path keeps finding its files. On Windows a
/// directory symlink is attempted (so the `Moved` contract — a working link at
/// `from` — still holds); its failure is propagated rather than silently
/// swallowed. Platforms with no symlink support propagate an error too, so a
/// move is never reported as `Moved` when no compatibility path was created.
/// Creation is race-idempotent: if a concurrent start installed the exact link
/// first, the resulting `AlreadyExists` is treated as success.
fn create_compat_link(from: &Path) -> std::result::Result<(), String> {
    #[cfg(unix)]
    let res = std::os::unix::fs::symlink(APP_NAME, from);
    #[cfg(windows)]
    let res = std::os::windows::fs::symlink_dir(APP_NAME, from);
    #[cfg(not(any(unix, windows)))]
    let res: std::io::Result<()> = Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "compatibility symlinks are not supported on this platform",
    ));

    match res {
        Ok(()) => Ok(()),
        // A concurrent start may have installed the exact link between the
        // caller's existence check (or our winning the rename) and this call;
        // if the required link is now in place, that is a success, not a failure.
        Err(_) if compat_link_is_valid(from) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// Recreate the compatibility link at `from` if it is missing. Called when the
/// data already lives at `to`, so the move itself is safe but an earlier run may
/// have failed to leave the link.
///
/// The one occupant that is *not* a failure is the exact compatibility link we
/// would create (a racing start may have installed it). Anything else at `from`
/// — typically a real directory recreated by an older running process in the
/// rename/link window — is reported as [`Migration::LinkFailed`] on every start
/// until it is resolved: the data lives at `to` while that process keeps writing
/// to `from`, so the trees are split and the warning must not go silent.
fn ensure_compat_link(from: &Path, to: &Path) -> Migration {
    if compat_link_is_valid(from) {
        return Migration::None;
    }
    if let Err(_metadata_err) = fs::symlink_metadata(from) {
        // Nothing at `from`: the common case — (re)create the link.
        return match create_compat_link(from) {
            Ok(()) => Migration::None,
            Err(err) => Migration::LinkFailed { from: from.to_path_buf(), to: to.to_path_buf(), err },
        };
    }
    // `from` is occupied by something other than the expected link. Do not
    // clobber it, but keep reporting the partial migration instead of treating
    // any entry as success.
    Migration::LinkFailed {
        from: from.to_path_buf(),
        to: to.to_path_buf(),
        err: format!(
            "{} is occupied and is not the expected compatibility link; \
             the data lives at {} — remove the stray entry (after merging anything \
             an older process wrote there) so the link can be restored",
            from.display(),
            to.display(),
        ),
    }
}

/// Move `<base>/agentic-harness` to `<base>/nano-coder` when only the old
/// one exists, leaving a symlink at the old path so an older nano-coder that
/// is still running (or installed elsewhere) keeps finding its files.
/// Already-open files are unaffected by the rename. When the move already
/// happened but its compatibility link is missing (e.g. an earlier run failed
/// to create it), the link is recreated here so the failure self-heals on a
/// later start. A move that could not leave its link is reported as
/// [`Migration::LinkFailed`], never silently as a success.
pub fn migrate_legacy_dir(base: &Path) -> Result<Migration> {
    let current = base.join(APP_NAME);
    let legacy = base.join(LEGACY_APP_NAME);
    let legacy_is_dir = fs::symlink_metadata(&legacy).is_ok_and(|m| m.is_dir());
    if current.exists() {
        // The move already happened; retry the compatibility link if it is gone.
        return Ok(ensure_compat_link(&legacy, &current));
    }
    if !legacy_is_dir {
        return Ok(Migration::None);
    }
    if let Err(err) = fs::rename(&legacy, &current) {
        // Another nano-coder may have moved it first.
        if current.exists() {
            return Ok(ensure_compat_link(&legacy, &current));
        }
        return Err(err).with_context(|| format!("move {} to {}", legacy.display(), current.display()));
    }
    Ok(match create_compat_link(&legacy) {
        Ok(()) => Migration::Moved { from: legacy, to: current },
        Err(err) => Migration::LinkFailed { from: legacy, to: current, err },
    })
}

/// [`migrate_legacy_dir`] for the config and data directories, with a note on
/// stderr for each move, for a move whose compatibility link could not be
/// created, or for a failed move (the old directory is then still used).
pub fn migrate_legacy_dirs() {
    let bases = [dirs::home_dir().map(|h| h.join(".config")), dirs::data_local_dir()];
    for base in bases.into_iter().flatten() {
        match migrate_legacy_dir(&base) {
            Ok(Migration::Moved { from, to }) => eprintln!("Moved {} to {}", from.display(), to.display()),
            Ok(Migration::LinkFailed { from, to, err }) => eprintln!(
                "warning: could not create the compatibility symlink at {} -> {} ({}); \
                 the two directories may now hold split data — older nano-coder builds pointed at \
                 the old path can miss anything written to the other tree (will retry on the next start)",
                from.display(),
                to.display(),
                err,
            ),
            Ok(Migration::None) => {}
            Err(err) => eprintln!("warning: {err:#} (still using the old directory)"),
        }
    }
}

impl ConfigManager {
    pub fn new() -> Result<Self> {
        Self::from_path(Self::default_config_path()?)
    }

    fn default_config_path() -> Result<PathBuf> {
        let home = dirs::home_dir().context("Could not determine home directory")?;
        Ok(app_dir(&home.join(".config")).join("config.toml"))
    }

    pub fn load_from_file(path: &Path) -> Result<Config> {
        let content =
            fs::read_to_string(path).with_context(|| format!("Failed to read config file: {}", path.display()))?;
        let config: Config =
            toml::from_str(&content).with_context(|| format!("Failed to parse config file: {}", path.display()))?;
        Ok(config)
    }

    pub fn from_path(config_path: PathBuf) -> Result<Self> {
        let config = if config_path.exists() { Self::load_from_file(&config_path)? } else { Config::default() };
        Ok(Self { config_path, config })
    }

    pub fn get(&self) -> &Config {
        &self.config
    }

    pub fn config_path(&self) -> &Path {
        &self.config_path
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn app_dir_prefers_current_and_falls_back_to_legacy() {
        let base = tempfile::tempdir().unwrap();
        assert_eq!(super::app_dir(base.path()), base.path().join("nano-coder"));
        std::fs::create_dir(base.path().join("agentic-harness")).unwrap();
        assert_eq!(super::app_dir(base.path()), base.path().join("agentic-harness"));
        std::fs::create_dir(base.path().join("nano-coder")).unwrap();
        assert_eq!(super::app_dir(base.path()), base.path().join("nano-coder"));
    }

    use super::*;

    #[test]
    fn migrates_legacy_dir_once_and_leaves_a_link() {
        let base = tempfile::tempdir().unwrap();
        assert_eq!(migrate_legacy_dir(base.path()).unwrap(), Migration::None, "nothing to move");
        let legacy = base.path().join("agentic-harness");
        fs::create_dir_all(legacy.join("sessions")).unwrap();
        fs::write(legacy.join("sessions/s.jsonl"), "x\n").unwrap();

        let moved = migrate_legacy_dir(base.path()).unwrap();
        let current = base.path().join("nano-coder");
        assert_eq!(moved, Migration::Moved { from: legacy.clone(), to: current.clone() });
        assert_eq!(fs::read_to_string(current.join("sessions/s.jsonl")).unwrap(), "x\n");
        assert_eq!(app_dir(base.path()), current);
        #[cfg(unix)]
        {
            assert!(fs::symlink_metadata(&legacy).unwrap().file_type().is_symlink());
            assert_eq!(fs::read_to_string(legacy.join("sessions/s.jsonl")).unwrap(), "x\n", "old path still works");
        }
        assert_eq!(migrate_legacy_dir(base.path()).unwrap(), Migration::None, "the link is not moved again");
    }

    #[cfg(unix)]
    #[test]
    fn recreates_a_missing_compatibility_link_on_a_later_start() {
        let base = tempfile::tempdir().unwrap();
        let legacy = base.path().join("agentic-harness");
        fs::create_dir_all(&legacy).unwrap();
        assert!(matches!(migrate_legacy_dir(base.path()).unwrap(), Migration::Moved { .. }));
        // Simulate an earlier run that moved the data but failed to leave a link.
        fs::remove_file(&legacy).unwrap();
        assert!(fs::symlink_metadata(&legacy).is_err(), "link is gone");

        assert_eq!(migrate_legacy_dir(base.path()).unwrap(), Migration::None, "link recreated, no new move");
        assert!(
            fs::symlink_metadata(&legacy).unwrap().file_type().is_symlink(),
            "the compatibility link is restored on a later start"
        );
    }

    #[cfg(unix)]
    #[test]
    fn create_compat_link_is_race_idempotent() {
        let base = tempfile::tempdir().unwrap();
        let from = base.path().join("agentic-harness");
        // A concurrent start already installed the exact compatibility link.
        std::os::unix::fs::symlink(APP_NAME, &from).unwrap();
        // Creating it again must report success, not a spurious AlreadyExists failure.
        assert!(create_compat_link(&from).is_ok(), "existing valid link is treated as success");
        // A pre-existing symlink to something else is still reported as a failure.
        let other = base.path().join("other");
        std::os::unix::fs::symlink("somewhere-else", &other).unwrap();
        assert!(create_compat_link(&other).is_err(), "a wrong-target link is a real failure");
    }

    #[test]
    fn reports_link_failure_when_current_exists_and_legacy_is_occupied() {
        // Both real directories coexist: either the user has two independent
        // trees, or (far more likely) an older agentic-harness build recreated
        // its directory after the move. Either way the legacy data is a split
        // tree unreachable from the moved location, so surface it rather than
        // silently succeeding — and never clobber the existing directory.
        let base = tempfile::tempdir().unwrap();
        fs::create_dir(base.path().join("agentic-harness")).unwrap();
        fs::create_dir(base.path().join("nano-coder")).unwrap();
        assert!(matches!(
            migrate_legacy_dir(base.path()).unwrap(),
            Migration::LinkFailed { .. }
        ));
        assert!(base.path().join("agentic-harness").is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn keeps_reporting_link_failure_while_legacy_path_stays_occupied() {
        let base = tempfile::tempdir().unwrap();
        let legacy = base.path().join("agentic-harness");
        let current = base.path().join("nano-coder");
        fs::create_dir(&legacy).unwrap();
        assert!(matches!(migrate_legacy_dir(base.path()).unwrap(), Migration::Moved { .. }));
        // An older process still running in the rename/link window recreates the
        // legacy directory (e.g. SessionLog::create -> create_dir_all).
        fs::remove_file(&legacy).unwrap();
        fs::create_dir(&legacy).unwrap();

        let migration = migrate_legacy_dir(base.path()).unwrap();
        let Migration::LinkFailed { from, to, .. } = &migration else {
            panic!("an occupied legacy path must keep reporting LinkFailed, got {migration:?}");
        };
        assert_eq!((from.as_path(), to.as_path()), (legacy.as_path(), current.as_path()), "still points at the split trees");
        // It is reported on every later start, not silently abandoned ...
        assert!(matches!(migrate_legacy_dir(base.path()).unwrap(), Migration::LinkFailed { .. }));
        // ... and the stray directory is never clobbered.
        assert!(fs::symlink_metadata(&legacy).unwrap().is_dir());

        // Once the stray directory is removed, the next start self-heals.
        fs::remove_dir(&legacy).unwrap();
        assert_eq!(migrate_legacy_dir(base.path()).unwrap(), Migration::None, "link restored");
        assert!(fs::symlink_metadata(&legacy).unwrap().file_type().is_symlink());
        assert_eq!(migrate_legacy_dir(base.path()).unwrap(), Migration::None, "link in place, quiet again");
    }

    #[test]
    fn parses_partial_config_with_providers() {
        let config: Config = toml::from_str(
            r#"
            model = "work/gpt-oss-120b"

            [providers.work]
            kind = "openai"
            base_url = "http://merlin.local:8000/v1"
            api_key_env = "WORK_KEY"
            headers = { "X-Team" = "nwf" }

            [providers.anthropic]
            max_retries = 2
        "#,
        )
        .unwrap();
        assert_eq!(config.max_tokens, 4096);
        assert_eq!(config.providers["work"].headers["X-Team"], "nwf");
        let (providers, default) = config.effective_providers();
        assert_eq!(default, "mock");
        let resolved = crate::providers::resolve(&config.model, &providers, &default).unwrap();
        assert_eq!(resolved.name, "work");
        assert_eq!(resolved.model, "gpt-oss-120b");
        let anthropic = crate::providers::resolve("anthropic/claude", &providers, &default).unwrap();
        assert_eq!(anthropic.retry.max_retries, 2);
        assert_eq!(anthropic.base_url, "https://api.anthropic.com/v1");
    }

    #[test]
    fn legacy_base_url_targets_an_openai_compatible_default() {
        let config: Config = toml::from_str(
            r#"
            model = "llama3"
            base_url = "http://localhost:8080/v1"
        "#,
        )
        .unwrap();
        let (providers, default) = config.effective_providers();
        let resolved = crate::providers::resolve(&config.model, &providers, &default).unwrap();
        assert_eq!(resolved.name, "openai");
        assert_eq!(resolved.base_url, "http://localhost:8080/v1");
        assert_eq!(resolved.model, "llama3");
    }

    #[test]
    fn defaults_to_the_frame_renderer_and_parses_legacy() {
        let default: Config = toml::from_str("model = \"work/x\"").unwrap();
        assert_eq!(default.renderer, crate::frame::RendererMode::Frame);
        let legacy: Config = toml::from_str("model = \"work/x\"\nrenderer = \"legacy\"").unwrap();
        assert_eq!(legacy.renderer, crate::frame::RendererMode::Legacy);
    }
}
