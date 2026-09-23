use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use anyhow::{Result, Context};

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
    /// Maximum LLM calls per user input.
    pub max_iterations: usize,
    /// Persist conversations as JSONL session logs.
    pub persist_sessions: bool,
    /// Session log directory (default: platform data dir/agentic-harness/sessions).
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
    /// How much the interactive CLI prints (and whether hook events are logged).
    pub verbosity: crate::ui::Verbosity,
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
            max_iterations: 50,
            persist_sessions: true,
            session_dir: None,
            bash_timeout_secs: crate::bash::DEFAULT_TIMEOUT_SECS,
            providers: HashMap::new(),
            context_window: None,
            auto_compact: true,
            auto_compact_threshold: 0.8,
            verbosity: crate::ui::Verbosity::Normal,
            project_instructions: true,
            project_instruction_files: crate::instructions::DEFAULT_FILES.iter().map(|s| s.to_string()).collect(),
            plan_tools: true,
            outcome_tool: true,
            reminders: true,
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
            let legacy = ProviderConfig {
                api_key: self.api_key.clone(),
                base_url: self.base_url.clone(),
                ..Default::default()
            };
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

/// Configuration manager
pub struct ConfigManager {
    config_path: PathBuf,
    config: Config,
}

impl ConfigManager {
    pub fn new() -> Result<Self> {
        Self::from_path(Self::default_config_path()?)
    }

    fn default_config_path() -> Result<PathBuf> {
        let home = dirs::home_dir().context("Could not determine home directory")?;
        Ok(home.join(".config").join("agentic-harness").join("config.toml"))
    }

    pub fn load_from_file(path: &Path) -> Result<Config> {
        let content = fs::read_to_string(path).with_context(|| format!("Failed to read config file: {}", path.display()))?;
        let config: Config = toml::from_str(&content).with_context(|| format!("Failed to parse config file: {}", path.display()))?;
        Ok(config)
    }

    pub fn from_path(config_path: PathBuf) -> Result<Self> {
        let config = if config_path.exists() {
            Self::load_from_file(&config_path)?
        } else {
            Config::default()
        };
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
    use super::*;

    #[test]
    fn parses_partial_config_with_providers() {
        let config: Config = toml::from_str(r#"
            model = "work/gpt-oss-120b"

            [providers.work]
            kind = "openai"
            base_url = "http://merlin.local:8000/v1"
            api_key_env = "WORK_KEY"
            headers = { "X-Team" = "nwf" }

            [providers.anthropic]
            max_retries = 2
        "#).unwrap();
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
        let config: Config = toml::from_str(r#"
            model = "llama3"
            base_url = "http://localhost:8080/v1"
        "#).unwrap();
        let (providers, default) = config.effective_providers();
        let resolved = crate::providers::resolve(&config.model, &providers, &default).unwrap();
        assert_eq!(resolved.name, "openai");
        assert_eq!(resolved.base_url, "http://localhost:8080/v1");
        assert_eq!(resolved.model, "llama3");
    }
}
