//! Interactive `/settings`: pick a provider and model, add or edit providers,
//! and save changes to the config file.

use std::collections::BTreeSet;
use std::env;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use dialoguer::{Confirm, Input, Select};

use crate::agent::Agent;
use crate::config::Config;
use crate::providers::{self, ProviderConfig, ProviderKind};

const LIST_MODELS_TIMEOUT: Duration = Duration::from_secs(15);

/// What the user changed this session, so saving touches only those keys.
#[derive(Default)]
struct Changes {
    model: bool,
    temperature: bool,
    max_tokens: bool,
    system_prompt: bool,
    compaction: bool,
    verbosity: bool,
    providers: BTreeSet<String>,
}

impl Changes {
    fn any(&self) -> bool {
        self.model || self.temperature || self.max_tokens || self.system_prompt || self.compaction || self.verbosity || !self.providers.is_empty()
    }
}

/// How a provider's API key is found, for display.
pub fn key_status(provider: &ProviderConfig) -> String {
    let env_var = provider.api_key_env.as_ref().filter(|v| !v.is_empty());
    match (&provider.api_key, env_var, &provider.api_key_command) {
        (Some(_), _, _) => "key set".to_string(),
        (None, Some(var), _) if env::var(var).is_ok_and(|v| !v.is_empty()) => format!("${var} set"),
        (None, _, Some(command)) => format!("key from `{command}`"),
        (None, Some(var), None) if provider.kind == Some(ProviderKind::GithubCopilot) => {
            if providers::github_copilot::load_credentials().is_some() {
                "logged in (unofficial)".to_string()
            } else {
                format!("${var} missing; --login github-copilot")
            }
        }
        (None, Some(var), None) => format!("${var} missing"),
        (None, None, None) => "no key".to_string(),
    }
}

pub async fn run(agent: &mut Agent, config_path: &Path) -> Result<()> {
    let mut changes = Changes::default();
    loop {
        let config = agent.config();
        println!("\nSettings ({}):", config_path.display());
        let items = [
            format!("Model            {} (provider {})", config.model, agent.provider_name()),
            "Add or edit a provider".to_string(),
            format!("Temperature      {}", config.temperature),
            format!("Max tokens       {}", config.max_tokens),
            "System prompt".to_string(),
            format!(
                "Context          {} window, auto-compact {}",
                crate::context::format_tokens(agent.context_window()),
                if config.auto_compact { format!("at {:.0}%", config.auto_compact_threshold * 100.0) } else { "off".into() }
            ),
            format!("Verbosity        {} ({})", config.verbosity, config.verbosity.describe()),
            format!("Save to config file{}", if changes.any() { " (unsaved changes)" } else { "" }),
            "Done".to_string(),
        ];
        let selection = Select::new().with_prompt("Select setting").items(&items).default(0).interact()?;
        match selection {
            0 => {
                if let Some(spec) = pick_model(agent, None).await? {
                    switch_model(agent, &spec, &mut changes).await;
                }
            }
            1 => {
                if let Some(name) = edit_provider(agent)? {
                    changes.providers.insert(name.clone());
                    if Confirm::new().with_prompt(format!("Pick a model from {name} now?")).default(true).interact()?
                        && let Some(spec) = pick_model(agent, Some(&name)).await?
                    {
                        switch_model(agent, &spec, &mut changes).await;
                    }
                }
            }
            2 => {
                let value: f64 = Input::new()
                    .with_prompt("Temperature (0.0-2.0)")
                    .default(agent.config().temperature)
                    .interact_text()?;
                agent.config_mut().temperature = value;
                changes.temperature = true;
            }
            3 => {
                let value: i32 = Input::new().with_prompt("Max tokens").default(agent.config().max_tokens).interact_text()?;
                agent.config_mut().max_tokens = value;
                changes.max_tokens = true;
            }
            4 => {
                let value: String = Input::new()
                    .with_prompt("System prompt")
                    .default(agent.config().system_prompt.clone())
                    .interact_text()?;
                agent.set_system_prompt(&value)?;
                changes.system_prompt = true;
            }
            5 => {
                edit_context(agent)?;
                changes.compaction = true;
            }
            6 => {
                let levels = crate::ui::Verbosity::ALL;
                let labels: Vec<String> = levels.iter().map(|l| format!("{l:<8} {}", l.describe())).collect();
                let current = levels.iter().position(|l| *l == agent.config().verbosity).unwrap_or(1);
                let choice = Select::new().with_prompt("Verbosity").items(&labels).default(current).interact()?;
                agent.config_mut().verbosity = levels[choice];
                crate::ui::set_verbosity(levels[choice]);
                changes.verbosity = true;
            }
            7 => save_and_report(agent.config(), &mut changes, config_path),
            _ => {
                if changes.any()
                    && Confirm::new()
                        .with_prompt(format!("Save changes to {}?", config_path.display()))
                        .default(true)
                        .interact()?
                {
                    save_and_report(agent.config(), &mut changes, config_path);
                }
                return Ok(());
            }
        }
    }
}

async fn switch_model(agent: &mut Agent, spec: &str, changes: &mut Changes) {
    match agent.set_model(spec).await {
        Ok(()) => {
            changes.model = true;
            println!("Model set to {} (provider {})", agent.model_name(), agent.provider_name());
        }
        Err(e) => println!("Could not switch model: {e:#}"),
    }
}

fn save_and_report(config: &Config, changes: &mut Changes, path: &Path) {
    match save(config, changes, path) {
        Ok(()) => {
            *changes = Changes::default();
            println!("Saved to {}", path.display());
        }
        Err(e) => println!("Could not save: {e:#}"),
    }
}

fn edit_context(agent: &mut Agent) -> Result<()> {
    let config = agent.config().clone();
    let auto = Confirm::new().with_prompt("Auto-compact when the context fills up?").default(config.auto_compact).interact()?;
    let threshold = if auto {
        let percent: f64 = Input::new()
            .with_prompt("Compact at this % of the context window")
            .default((config.auto_compact_threshold * 100.0).round())
            .validate_with(|p: &f64| if (10.0..=99.0).contains(p) { Ok(()) } else { Err("between 10 and 99") })
            .interact_text()?;
        percent / 100.0
    } else {
        config.auto_compact_threshold
    };
    let window: usize = Input::new()
        .with_prompt("Context window in tokens (0 = from provider/model)")
        .default(config.context_window.unwrap_or(0))
        .interact_text()?;
    let config = agent.config_mut();
    config.auto_compact = auto;
    config.auto_compact_threshold = threshold;
    config.context_window = (window > 0).then_some(window);
    agent.refresh_stats();
    Ok(())
}

/// Choose a provider (unless given), then a model from its live model list,
/// falling back to typing a model ID. Returns a `provider/model` spec.
async fn pick_model(agent: &Agent, provider: Option<&str>) -> Result<Option<String>> {
    let (user, default_provider) = agent.config().effective_providers();
    let all = providers::effective_providers(&user);
    let name = match provider {
        Some(name) => name.to_string(),
        None => {
            let names: Vec<&String> = all.keys().collect();
            let labels: Vec<String> = all
                .iter()
                .map(|(name, p)| format!("{name:<14} {}", key_status(p)))
                .chain(["Cancel".to_string()])
                .collect();
            let current = agent.provider_name();
            let default = names.iter().position(|n| n.as_str() == current).unwrap_or(0);
            let choice = Select::new().with_prompt("Provider").items(&labels).default(default).interact()?;
            match names.get(choice) {
                Some(name) => name.to_string(),
                None => return Ok(None),
            }
        }
    };
    let default_model = all.get(&name).and_then(|p| p.default_model.clone()).unwrap_or_default();

    println!("Fetching models from {name}...");
    let models = match providers::build_lister(&name, &user, &default_provider) {
        Ok(client) => match tokio::time::timeout(LIST_MODELS_TIMEOUT, client.list_models()).await {
            Ok(Ok(models)) => models,
            Ok(Err(e)) => {
                println!("Could not list models: {e:#}");
                Vec::new()
            }
            Err(_) => {
                println!("Listing models timed out");
                Vec::new()
            }
        },
        Err(e) => {
            println!("Could not build a client for {name}: {e:#}");
            Vec::new()
        }
    };

    let model = if models.is_empty() {
        let mut input = Input::<String>::new().with_prompt("Model ID").allow_empty(true);
        if !default_model.is_empty() {
            input = input.default(default_model);
        }
        input.interact_text()?
    } else {
        let mut labels = models.clone();
        labels.push("Other (type a model ID)".into());
        labels.push("Cancel".into());
        let default = models.iter().position(|m| *m == default_model).unwrap_or(0);
        let choice = Select::new().with_prompt("Model").items(&labels).default(default).max_length(15).interact()?;
        if choice == models.len() {
            Input::<String>::new().with_prompt("Model ID").interact_text()?
        } else if choice > models.len() {
            return Ok(None);
        } else {
            models[choice].clone()
        }
    };
    let model = model.trim();
    Ok(Some(if model.is_empty() { name } else { format!("{name}/{model}") }))
}

/// Add a provider or edit an existing one. Returns its name.
fn edit_provider(agent: &mut Agent) -> Result<Option<String>> {
    let (user, _) = agent.config().effective_providers();
    let all = providers::effective_providers(&user);
    let mut labels: Vec<String> = vec!["New provider".into()];
    for name in all.keys() {
        if user.contains_key(name) {
            labels.push(format!("✓ {name}"));
        } else {
            labels.push(name.clone());
        }
    }
    labels.push("Cancel".into());
    let choice = Select::new().with_prompt("Provider to add or edit").items(&labels).default(0).interact()?;
    let name = match choice {
        0 => {
            let name: String = Input::new()
                .with_prompt("Name (used as the model prefix, e.g. work in work/llama3)")
                .validate_with(|n: &String| {
                    let n = n.trim();
                    if n.is_empty() || n.contains('/') || n.contains(char::is_whitespace) {
                        Err("use a non-empty name without '/' or spaces")
                    } else {
                        Ok(())
                    }
                })
                .interact_text()?;
            name.trim().to_string()
        }
        i if i < labels.len() - 1 => labels[i].trim_start_matches("✓ ").to_string(),
        _ => return Ok(None),
    };
    let current = all.get(&name).cloned().unwrap_or_default();

    let kinds = [ProviderKind::Openai, ProviderKind::Anthropic, ProviderKind::GithubCopilot];
    let kind_labels = ["OpenAI-compatible (/chat/completions)", "Anthropic (/messages)", "GitHub Copilot (unofficial)"];
    let kind_default = kinds.iter().position(|k| Some(*k) == current.kind).unwrap_or(0);
    let kind = kinds[Select::new().with_prompt("API kind").items(&kind_labels).default(kind_default).interact()?];

    let mut base_url = Input::<String>::new().with_prompt("Base URL (e.g. http://merlin.local:8000/v1)").allow_empty(kind == ProviderKind::GithubCopilot);
    if let Some(url) = &current.base_url {
        base_url = base_url.default(url.clone());
    }
    let base_url = base_url.interact_text()?.trim().trim_end_matches('/').to_string();

    let sources = [
        "Environment variable (recommended)",
        "Shell command (e.g. `op read ...`, `gh auth token`)",
        "Literal key, saved in the config file",
        "No key",
        "Keep current",
    ];
    let source_default = if current.api_key_env.is_some() || current.api_key_command.is_some() || current.api_key.is_some() { 4 } else { 0 };
    let mut updated = ProviderConfig {
        kind: Some(kind),
        base_url: Some(base_url).filter(|u| !u.is_empty()),
        ..current.clone()
    };
    match Select::new().with_prompt(format!("API key ({})", key_status(&current))).items(&sources).default(source_default).interact()? {
        0 => {
            let mut input = Input::<String>::new().with_prompt("Variable name");
            let suggested = current
                .api_key_env
                .clone()
                .unwrap_or_else(|| format!("{}_API_KEY", name.to_uppercase().replace('-', "_")));
            input = input.default(suggested);
            updated.api_key_env = Some(input.interact_text()?.trim().to_string());
            updated.api_key_command = None;
            updated.api_key = None;
        }
        1 => {
            let mut input = Input::<String>::new().with_prompt("Command");
            if let Some(command) = &current.api_key_command {
                input = input.default(command.clone());
            }
            updated.api_key_command = Some(input.interact_text()?.trim().to_string());
            updated.api_key = None;
            updated.api_key_env = None;
        }
        2 => {
            let key = dialoguer::Password::new().with_prompt("API key").interact()?;
            updated.api_key = Some(key.trim().to_string());
            updated.api_key_env = None;
            updated.api_key_command = None;
        }
        3 => {
            updated.api_key = None;
            updated.api_key_env = None;
            updated.api_key_command = None;
        }
        _ => {}
    }

    let mut default_model = Input::<String>::new().with_prompt("Default model (optional)").allow_empty(true);
    if let Some(model) = &current.default_model {
        default_model = default_model.default(model.clone());
    }
    updated.default_model = Some(default_model.interact_text()?.trim().to_string()).filter(|m| !m.is_empty());

    // Store only what differs from the built-in preset, so preset updates
    // still apply to fields the user never touched.
    let preset = providers::presets().remove(&name).unwrap_or_default();
    let existing = user.get(&name).cloned().unwrap_or_default();
    let entry = diff_from(&preset, &existing, &updated);
    let config = agent.config_mut();
    config.providers.insert(name.clone(), entry);
    println!("Provider {name}: {} {}", format!("{kind:?}").to_lowercase(), updated.base_url.as_deref().unwrap_or("(from session token)"));
    Ok(Some(name))
}

/// The user entry to store for an edited provider: the existing entry with
/// the edited fields set, keeping only values that differ from the preset so
/// preset updates still apply to fields the user never touched.
fn diff_from(preset: &ProviderConfig, existing: &ProviderConfig, updated: &ProviderConfig) -> ProviderConfig {
    fn keep<T: PartialEq + Clone>(preset: &Option<T>, updated: &Option<T>) -> Option<T> {
        if preset == updated { None } else { updated.clone() }
    }
    let mut entry = existing.clone();
    entry.kind = keep(&preset.kind, &updated.kind);
    entry.base_url = keep(&preset.base_url, &updated.base_url);
    entry.default_model = keep(&preset.default_model, &updated.default_model);
    entry.api_key = updated.api_key.clone();
    entry.api_key_command = updated.api_key_command.clone();
    entry.api_key_env = keep(&preset.api_key_env, &updated.api_key_env);
    // An empty name overrides the preset's variable when switching away from it.
    if preset.api_key_env.is_some() && updated.api_key_env.is_none() {
        entry.api_key_env = Some(String::new());
    }
    entry
}

/// Write the changed keys into the config file, preserving its comments and
/// anything else the user put there.
fn save(config: &Config, changes: &Changes, path: &Path) -> Result<()> {
    let existing = if path.exists() {
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?
    } else {
        String::new()
    };
    let mut doc: toml_edit::DocumentMut = existing.parse().with_context(|| format!("parsing {}", path.display()))?;
    if changes.model {
        doc["model"] = toml_edit::value(config.model.as_str());
    }
    if changes.temperature {
        doc["temperature"] = toml_edit::value(config.temperature);
    }
    if changes.max_tokens {
        doc["max_tokens"] = toml_edit::value(i64::from(config.max_tokens));
    }
    if changes.system_prompt {
        doc["system_prompt"] = toml_edit::value(config.system_prompt.as_str());
    }
    if changes.verbosity {
        doc["verbosity"] = toml_edit::value(config.verbosity.to_string());
    }
    if changes.compaction {
        doc["auto_compact"] = toml_edit::value(config.auto_compact);
        doc["auto_compact_threshold"] = toml_edit::value(config.auto_compact_threshold);
        match config.context_window {
            Some(window) => doc["context_window"] = toml_edit::value(window as i64),
            None => {
                doc.remove("context_window");
            }
        }
    }
    let mut has_secret = config.api_key.is_some();
    if !changes.providers.is_empty() {
        if !doc.contains_table("providers") {
            let mut table = toml_edit::Table::new();
            table.set_implicit(true);
            doc["providers"] = toml_edit::Item::Table(table);
        }
        for name in &changes.providers {
            let Some(provider) = config.providers.get(name) else { continue };
            doc["providers"][name.as_str()] = toml_edit::Item::Table(provider_table(provider)?);
        }
    }
    has_secret |= config.providers.values().any(|p| p.api_key.is_some());

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, doc.to_string()).with_context(|| format!("writing {}", tmp.display()))?;
    #[cfg(unix)]
    if has_secret {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

fn provider_table(provider: &ProviderConfig) -> Result<toml_edit::Table> {
    let text = toml::to_string(provider).context("serializing provider")?;
    let doc: toml_edit::DocumentMut = text.parse().context("re-parsing provider")?;
    let mut table = doc.as_table().clone();
    table.retain(|_, item| !item.as_table_like().is_some_and(|t| t.is_empty()));
    table.set_implicit(false);
    table.set_position(usize::MAX);
    Ok(table)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_updates_only_changed_keys_and_keeps_comments() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "# my config\nmodel = \"mock\"\ntemperature = 0.2 # keep me\n\n[providers.anthropic]\nmax_retries = 2\n",
        )
        .unwrap();
        let mut config: Config = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        config.model = "work/llama3".into();
        config.temperature = 0.9;
        config.providers.insert(
            "work".into(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some("http://merlin.local:8000/v1".into()),
                api_key_env: Some("WORK_KEY".into()),
                ..Default::default()
            },
        );
        let changes = Changes { model: true, providers: ["work".to_string()].into(), ..Default::default() };
        save(&config, &changes, &path).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# my config"), "{text}");
        assert!(text.contains("temperature = 0.2 # keep me"), "unchanged key untouched: {text}");
        assert!(text.contains("max_retries = 2"), "{text}");
        let reloaded: Config = toml::from_str(&text).unwrap();
        assert_eq!(reloaded.model, "work/llama3");
        let work = &reloaded.providers["work"];
        assert_eq!(work.base_url.as_deref(), Some("http://merlin.local:8000/v1"));
        assert_eq!(work.api_key_env.as_deref(), Some("WORK_KEY"));
        assert!(!text.contains("headers"), "empty tables omitted: {text}");

        let (user, default) = reloaded.effective_providers();
        let resolved = providers::resolve(&reloaded.model, &user, &default).unwrap();
        assert_eq!(resolved.base_url, "http://merlin.local:8000/v1");
        assert_eq!(resolved.model, "llama3");
    }

    #[test]
    fn save_creates_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/config.toml");
        let config = Config { model: "ollama/qwen3".into(), ..Config::default() };
        save(&config, &Changes { model: true, ..Default::default() }, &path).unwrap();
        let reloaded: Config = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(reloaded.model, "ollama/qwen3");
    }

    #[test]
    fn editing_a_preset_stores_only_the_overrides() {
        let preset = providers::presets().remove("ollama").unwrap();
        let updated = ProviderConfig { base_url: Some("http://merlin.local:11434/v1".into()), ..preset.clone() };
        let entry = diff_from(&preset, &ProviderConfig::default(), &updated);
        assert_eq!(entry.kind, None);
        assert_eq!(entry.api_key_env, None);
        assert_eq!(entry.base_url.as_deref(), Some("http://merlin.local:11434/v1"));
        let merged = preset.clone().merged_with(&entry);
        assert_eq!(merged.base_url.as_deref(), Some("http://merlin.local:11434/v1"));
    }

    #[test]
    fn switching_a_preset_to_a_key_command_overrides_its_env_var() {
        let preset = providers::presets().remove("openai").unwrap();
        let existing = ProviderConfig { max_retries: Some(1), ..Default::default() };
        let updated = ProviderConfig { api_key_env: None, api_key_command: Some("echo k".into()), ..preset.clone() };
        let entry = diff_from(&preset, &existing, &updated);
        assert_eq!(entry.max_retries, Some(1), "untouched user fields kept");
        let merged = preset.merged_with(&entry);
        let resolved = providers::resolve("openai/gpt", &[("openai".to_string(), entry)].into(), "openai").unwrap();
        assert_eq!(merged.api_key_env.as_deref(), Some(""));
        assert_eq!(resolved.api_key.as_deref(), Some("k"));
    }
}
