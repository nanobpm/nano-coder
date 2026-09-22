use std::fs;
use std::path::{Path, PathBuf};
use anyhow::{Result, Context};

/// Agent configuration
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Config {
    pub model: String,
    pub temperature: f64,
    pub max_tokens: i32,
    pub system_prompt: String,
    pub api_key: Option<String>,
    pub base_url: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            model: "gpt-4o-mini".to_string(),
            temperature: 0.7,
            max_tokens: 4096,
            system_prompt: "You are a helpful assistant with access to tools.".to_string(),
            api_key: None,
            base_url: None,
        }
    }
}

/// Configuration manager
pub struct ConfigManager {
    config_path: PathBuf,
    config: Config,
}

impl ConfigManager {
    pub fn new() -> Result<Self> {
        let config_path = Self::default_config_path()?;
        let config = if config_path.exists() {
            Self::load_from_file(&config_path)?
        } else {
            Config::default()
        };
        Ok(Self { config_path, config })
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

    pub fn save(&mut self) -> Result<()> {
        let content = toml::to_string_pretty(&self.config).context("Failed to serialize config")?;
        if let Some(parent) = self.config_path.parent() {
            fs::create_dir_all(parent).with_context(|| format!("Failed to create config directory: {}", parent.display()))?;
        }
        fs::write(&self.config_path, content).with_context(|| format!("Failed to write config file: {}", self.config_path.display()))?;
        Ok(())
    }

    pub fn get(&self) -> &Config {
        &self.config
    }

    pub fn set_model(&mut self, model: &str) {
        self.config.model = model.to_string();
    }

    pub fn set_temperature(&mut self, temperature: f64) {
        self.config.temperature = temperature;
    }

    pub fn set_max_tokens(&mut self, max_tokens: i32) {
        self.config.max_tokens = max_tokens;
    }

    pub fn set_system_prompt(&mut self, prompt: &str) {
        self.config.system_prompt = prompt.to_string();
    }

    pub fn config_path(&self) -> &Path {
        &self.config_path
    }
}
