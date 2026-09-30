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
use crate::recents;

const LIST_MODELS_TIMEOUT: Duration = Duration::from_secs(15);

/// What the user changed this session, so saving touches only those keys.
#[derive(Default)]
struct Changes {
    model: bool,
    temperature: bool,
    /// Providers whose `temperature` changed.
    provider_temperatures: BTreeSet<String>,
    /// `(provider, model)` pairs whose `temperature` changed.
    model_temperatures: BTreeSet<(String, String)>,
    max_tokens: bool,
    max_iterations: bool,
    system_prompt: bool,
    compaction: bool,
    verbosity: bool,
    renderer: bool,
    providers: BTreeSet<String>,
}

impl Changes {
    fn any(&self) -> bool {
        self.model
            || self.temperature
            || !self.provider_temperatures.is_empty()
            || !self.model_temperatures.is_empty()
            || self.max_tokens
            || self.max_iterations
            || self.system_prompt
            || self.compaction
            || self.verbosity
            || self.renderer
            || !self.providers.is_empty()
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

/// How the turn cap appears in the settings list. A finite cap notes that
/// normal mode asks before stopping; an unbounded cap (0) never reaches that
/// prompt, so the suffix is omitted to avoid contradicting the loop behavior.
fn turn_cap_label(max_iterations: usize) -> String {
    match max_iterations {
        0 => "unbounded".to_string(),
        n => format!("{n} LLM calls per input (normal mode asks before stopping)"),
    }
}

/// The settings dialog. `recents` is the shared most-recently-used model MRU:
/// the model picker reads a fresh snapshot each time it opens, and every switch
/// made here is recorded into it immediately (and persisted to `recents_path`),
/// so multiple switches in one visit all land and reopening the picker sees the
/// latest.
pub async fn run(
    agent: &mut Agent,
    config_path: &Path,
    recents: &recents::SharedRecents,
    recents_path: &Path,
) -> Result<()> {
    let mut changes = Changes::default();
    loop {
        let config = agent.config();
        println!("\nSettings ({}):", config_path.display());
        let items = [
            format!("Model            {} (provider {})", config.model, agent.provider_name()),
            "Add or edit a provider".to_string(),
            format!("Temperature      {}", agent.temperature().describe()),
            format!("Max tokens       {}", config.max_tokens),
            format!("Turn cap         {}", turn_cap_label(config.max_iterations)),
            "System prompt".to_string(),
            format!(
                "Context          {} window, auto-compact {}, {} compaction",
                crate::context::format_tokens(agent.context_window()),
                if config.auto_compact {
                    format!("at {:.0}%", config.auto_compact_threshold * 100.0)
                } else {
                    "off".into()
                },
                config.compaction_mode.as_str()
            ),
            format!("Verbosity        {} ({})", config.verbosity, config.verbosity.describe()),
            format!("Renderer         {} ({})", config.renderer, config.renderer.describe()),
            format!("Save to config file{}", if changes.any() { " (unsaved changes)" } else { "" }),
            "Done".to_string(),
        ];
        let selection = Select::new().with_prompt("Select setting").items(&items).default(0).interact()?;
        match selection {
            0 => {
                let snapshot = recents.lock().unwrap().models().to_vec();
                if let Some(spec) = pick_model_interactive(agent, &snapshot).await? {
                    switch_model(agent, &spec, &mut changes, recents, recents_path).await;
                }
            }
            1 => {
                if let Some(name) = edit_provider(agent).await? {
                    changes.providers.insert(name.clone());
                    if Confirm::new().with_prompt(format!("Pick a model from {name} now?")).default(true).interact()? {
                        let (user, default_provider) = agent.config().effective_providers();
                        let all = providers::effective_providers(&user);
                        if let Step::Done(spec) =
                            pick_model_from_provider(&name, &all, &user, &default_provider).await?
                        {
                            switch_model(agent, &spec, &mut changes, recents, recents_path).await;
                        }
                    }
                }
            }
            2 => edit_temperature(agent, &mut changes)?,
            3 => {
                let value: i32 =
                    Input::new().with_prompt("Max tokens").default(agent.config().max_tokens).interact_text()?;
                agent.config_mut().max_tokens = value;
                changes.max_tokens = true;
            }
            4 => {
                let value: usize = Input::new()
                    .with_prompt("Turn cap in LLM calls per input (0 = unbounded; a positive cap makes normal mode ask before stopping, auto ignores it)")
                    .default(agent.config().max_iterations)
                    .interact_text()?;
                agent.config_mut().max_iterations = value;
                changes.max_iterations = true;
            }
            5 => {
                let value: String = Input::new()
                    .with_prompt("System prompt")
                    .default(agent.config().system_prompt.clone())
                    .interact_text()?;
                agent.set_system_prompt(&value)?;
                changes.system_prompt = true;
            }
            6 => {
                edit_context(agent)?;
                changes.compaction = true;
            }
            7 => {
                let levels = crate::ui::Verbosity::ALL;
                let labels: Vec<String> = levels.iter().map(|l| format!("{l:<8} {}", l.describe())).collect();
                let current = levels.iter().position(|l| *l == agent.config().verbosity).unwrap_or(1);
                let choice = Select::new().with_prompt("Verbosity").items(&labels).default(current).interact()?;
                agent.config_mut().verbosity = levels[choice];
                crate::ui::set_verbosity(levels[choice]);
                changes.verbosity = true;
            }
            8 => {
                let modes = crate::frame::RendererMode::ALL;
                let labels: Vec<String> = modes.iter().map(|m| format!("{m:<7} {}", m.describe())).collect();
                let current = modes.iter().position(|m| *m == agent.config().renderer).unwrap_or(0);
                let choice = Select::new().with_prompt("Renderer").items(&labels).default(current).interact()?;
                let previous = agent.config().renderer;
                agent.config_mut().renderer = modes[choice];
                changes.renderer = true;
                if modes[choice] != previous {
                    // The switch is applied live by `main` (which detects the
                    // changed `renderer` after the dialog returns and flips the
                    // frame renderer, the line editor, and the scroll region).
                    println!("Renderer set to {} — taking effect now.", modes[choice]);
                }
            }
            9 => save_and_report(agent.config(), &mut changes, config_path),
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

async fn switch_model(
    agent: &mut Agent,
    spec: &str,
    changes: &mut Changes,
    recents: &recents::SharedRecents,
    recents_path: &Path,
) {
    let previous = format!("{}/{}", agent.provider_name(), agent.model_name());
    match agent.set_model(spec).await {
        Ok(()) => {
            changes.model = true;
            record_switch(agent, &previous, recents, recents_path);
            println!("Model set to {} (provider {})", agent.model_name(), agent.provider_name());
            if let Some(warning) = agent.temperature().warning {
                println!("Warning: {warning}");
            }
        }
        Err(e) => println!("Could not switch model: {e:#}"),
    }
}

/// Record a switch from `previous` to the agent's now-current model into the
/// recents MRU and persist it. `previous` is the model that was actually in use
/// (the live client's resolved `provider/model`) captured before the switch, so
/// a `/settings` edit to a provider's default in the same visit cannot rewrite
/// which model is recorded as left. Both specs are canonicalized so a
/// slash-bearing default-provider model keeps its real provider. Recording
/// immediately (not deriving one `before -> final` transition when the dialog
/// closes) means every switch made in a single visit lands, in order.
fn record_switch(agent: &Agent, previous: &str, recents: &recents::SharedRecents, recents_path: &Path) {
    let (user, default_provider) = agent.config().effective_providers();
    let all = providers::effective_providers(&user);
    let previous = recents::canonical(previous, &all, &default_provider);
    // The now-current model, read from the live client rather than re-resolving
    // the raw config spec against a possibly just-edited provider table.
    let current =
        recents::canonical(&format!("{}/{}", agent.provider_name(), agent.model_name()), &all, &default_provider);
    let mut guard = recents.lock().unwrap();
    guard.record(&previous);
    guard.record(&current);
    recents::save(recents_path, &guard);
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
    let auto = Confirm::new()
        .with_prompt("Auto-compact when the context fills up?")
        .default(config.auto_compact)
        .interact()?;
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
    let modes = [
        "standard: summary only",
        "smart (experimental): summary cites the session log; history tools recover originals",
    ];
    let current = usize::from(config.compaction_mode == crate::config::CompactionMode::Smart);
    let mode = match Select::new().with_prompt("Compaction mode").items(&modes).default(current).interact()? {
        1 => crate::config::CompactionMode::Smart,
        _ => crate::config::CompactionMode::Standard,
    };
    let window: usize = Input::new()
        .with_prompt("Context window in tokens (0 = from provider/model)")
        .default(config.context_window.unwrap_or(0))
        .interact_text()?;
    let config = agent.config_mut();
    config.auto_compact = auto;
    config.auto_compact_threshold = threshold;
    config.compaction_mode = mode;
    config.context_window = (window > 0).then_some(window);
    agent.refresh_stats();
    Ok(())
}

/// How many recently used models `/model` lists above the providers.
pub const RECENT_MODELS_SHOWN: usize = 4;

/// Interactive `/model`: show the current model, then pick a recently used
/// model or a provider and one of its models. Esc at the model list goes back
/// to the provider list; Esc there leaves the model unchanged. `recents` is
/// the most-recently-used `provider/model` list. Returns the chosen spec.
pub async fn pick_model_interactive(agent: &Agent, recents: &[String]) -> Result<Option<String>> {
    println!("Current model: {} (provider {})", agent.model_name(), agent.provider_name());
    let (user, default_provider) = agent.config().effective_providers();
    let all = providers::effective_providers(&user);
    let recent = recent_models(recents, &all);
    let mut provider = None;
    loop {
        let name = match provider.take() {
            Some(name) => name,
            None => match pick_provider(agent, &all, &recent)? {
                Some(ProviderChoice::Model(spec)) => return Ok(Some(spec)),
                Some(ProviderChoice::Provider(name)) => name,
                None => return Ok(None),
            },
        };
        match pick_model_from_provider(&name, &all, &user, &default_provider).await? {
            Step::Done(spec) => return Ok(Some(spec)),
            Step::Back => continue,
        }
    }
}

/// Where a picker step goes next: a choice was made, or Esc steps back.
#[derive(Debug, PartialEq)]
enum Step {
    Done(String),
    Back,
}

/// What a selection in the model list means: `choice` is the highlighted row
/// (`None` when Esc was pressed) among `models` plus the trailing "Other
/// (type a model ID)" and "Back to providers" rows.
fn model_choice(choice: Option<usize>, models: &[String]) -> Step {
    match choice {
        None => Step::Back,
        Some(i) if i < models.len() => Step::Done(models[i].clone()),
        Some(i) if i == models.len() => Step::Done(String::new()), // "Other": the caller prompts for an ID
        Some(_) => Step::Back,                                     // "Back to providers"
    }
}

/// The `provider/model` spec for a chosen or typed model ID; empty means the
/// user wants to go back to the provider list.
fn model_spec(provider: &str, model: &str) -> Step {
    let model = model.trim();
    if model.is_empty() { Step::Back } else { Step::Done(format!("{provider}/{model}")) }
}

/// The recently used specs to offer, most recent first: at most
/// [`RECENT_MODELS_SHOWN`], skipping any whose provider is no longer
/// configured. Recents are stored canonicalized (see [`recents::canonical`]),
/// so a slash-bearing default-provider model carries its real provider prefix
/// and is kept, while a genuinely removed provider's prefix no longer matches
/// and is skipped.
fn recent_models(recents: &[String], all: &std::collections::BTreeMap<String, ProviderConfig>) -> Vec<String> {
    recents
        .iter()
        .filter(|spec| spec.split_once('/').is_none_or(|(provider, _)| all.contains_key(provider)))
        .take(RECENT_MODELS_SHOWN)
        .cloned()
        .collect()
}

/// What the first `/model` list picked: a recent model outright, or a
/// provider whose models to list next.
#[derive(Debug, PartialEq)]
enum ProviderChoice {
    Model(String),
    Provider(String),
}

/// The rows of the first `/model` list: the recent models (the current one
/// marked), then the providers, then Cancel. Also returns the row to
/// highlight: the most recent model that isn't the current one, so `/model`
/// then Enter flips back to the previous model; without one, the current
/// provider.
fn provider_rows(
    recent: &[String],
    current_spec: &str,
    current_provider: &str,
    all: &std::collections::BTreeMap<String, ProviderConfig>,
) -> (Vec<(String, Option<ProviderChoice>)>, usize) {
    let mut rows: Vec<(String, Option<ProviderChoice>)> = recent
        .iter()
        .map(|spec| {
            let mark = if spec == current_spec { "  (current)" } else { "" };
            (format!("↺ {spec}{mark}"), Some(ProviderChoice::Model(spec.clone())))
        })
        .collect();
    let first_provider = rows.len();
    rows.extend(
        all.iter()
            .map(|(name, p)| (format!("{name:<14} {}", key_status(p)), Some(ProviderChoice::Provider(name.clone())))),
    );
    rows.push(("Cancel".to_string(), None));
    let default = recent
        .iter()
        .position(|spec| spec != current_spec)
        .unwrap_or_else(|| first_provider + all.keys().position(|name| name == current_provider).unwrap_or(0));
    (rows, default)
}

/// Scrollable list of the recently used models and the configured providers,
/// with the previous model (or the current provider) pre-selected. Esc (or
/// the Cancel row) returns `None`.
fn pick_provider(
    agent: &Agent,
    all: &std::collections::BTreeMap<String, ProviderConfig>,
    recent: &[String],
) -> Result<Option<ProviderChoice>> {
    let (_, default_provider) = agent.config().effective_providers();
    // Highlight the model actually in use (the live client's resolved spec),
    // not `config.model` re-resolved against a table a `/settings` visit may
    // have just edited — otherwise a freshly edited provider default would be
    // marked current while the live client is still on its old model.
    let current_spec =
        recents::canonical(&format!("{}/{}", agent.provider_name(), agent.model_name()), all, &default_provider);
    let (mut rows, default) = provider_rows(recent, &current_spec, agent.provider_name(), all);
    let labels: Vec<&str> = rows.iter().map(|(label, _)| label.as_str()).collect();
    let prompt = if recent.is_empty() {
        "Provider (↑/↓ to scroll, Enter to select, Esc to keep the current model)"
    } else {
        "Recent model or provider (↑/↓ to scroll, Enter to select, Esc to keep the current model)"
    };
    let choice = Select::new().with_prompt(prompt).items(&labels).default(default).interact_opt()?;
    Ok(choice.and_then(|i| rows.get_mut(i)).and_then(|(_, choice)| choice.take()))
}

/// Scrollable list of the provider's live models, falling back to typing a
/// model ID when the list cannot be fetched. Esc (or the Back row) returns
/// `Step::Back` so the caller shows the provider list again.
async fn pick_model_from_provider(
    name: &str,
    all: &std::collections::BTreeMap<String, ProviderConfig>,
    user: &std::collections::HashMap<String, ProviderConfig>,
    default_provider: &str,
) -> Result<Step> {
    let default_model = all.get(name).and_then(|p| p.default_model.clone()).unwrap_or_default();

    println!("Fetching models from {name}...");
    let models = match providers::build_lister(name, user, default_provider) {
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
        // No default: pressing Enter on blank input must go back to the
        // provider list, which a dialoguer default would swallow by returning
        // the default model instead of an empty string.
        Input::<String>::new()
            .with_prompt("Model ID (empty to go back to the provider list)")
            .allow_empty(true)
            .interact_text()?
    } else {
        let mut labels = models.clone();
        labels.push("Other (type a model ID)".into());
        labels.push("Back to providers".into());
        let default = models.iter().position(|m| *m == default_model).unwrap_or(0);
        let choice = Select::new()
            .with_prompt(format!("Model from {name} (Esc to go back)"))
            .items(&labels)
            .default(default)
            .max_length(15)
            .interact_opt()?;
        match model_choice(choice, &models) {
            Step::Back => return Ok(Step::Back),
            Step::Done(picked) if picked.is_empty() => Input::<String>::new()
                .with_prompt("Model ID (empty to go back to the provider list)")
                .allow_empty(true)
                .interact_text()?,
            Step::Done(picked) => picked,
        }
    };
    Ok(model_spec(name, &model))
}

/// Add a provider or edit an existing one. Returns its name. When the edited
/// provider is the one serving the current model, the live client is rebuilt
/// so the running session immediately uses the new endpoint / key / model —
/// the conversation is kept.
async fn edit_provider(agent: &mut Agent) -> Result<Option<String>> {
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
    let (name, is_new) = match choice {
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
            (name.trim().to_string(), true)
        }
        i if i < labels.len() - 1 => (labels[i].strip_prefix("✓ ").unwrap_or(&labels[i]).to_string(), false),
        _ => return Ok(None),
    };
    let current = all.get(&name).cloned().unwrap_or_default();

    let kinds = [ProviderKind::Openai, ProviderKind::Anthropic, ProviderKind::GithubCopilot];
    let kind_labels = ["OpenAI-compatible (/chat/completions)", "Anthropic (/messages)", "GitHub Copilot (unofficial)"];
    let kind_default = kinds.iter().position(|k| Some(*k) == current.kind).unwrap_or(0);
    let kind = kinds[Select::new().with_prompt("API kind").items(&kind_labels).default(kind_default).interact()?];

    let mut base_url = Input::<String>::new()
        .with_prompt("Base URL (e.g. http://merlin.local:8000/v1)")
        .allow_empty(kind == ProviderKind::GithubCopilot);
    if let Some(url) = &current.base_url {
        base_url = base_url.default(url.clone());
    } else if kind == ProviderKind::GithubCopilot
        && is_new
        && !all.contains_key(&name)
        && providers::github_copilot::domain() == "github.com"
    {
        base_url = base_url.default(providers::github_copilot::DEFAULT_API_BASE.to_string());
    }
    let base_url = base_url.interact_text()?.trim().trim_end_matches('/').to_string();

    let sources = [
        "Environment variable (recommended)",
        "Shell command (e.g. `op read ...`, `gh auth token`)",
        "Literal key, saved in the config file",
        "No key",
        "Keep current",
    ];
    let source_default =
        if current.api_key_env.is_some() || current.api_key_command.is_some() || current.api_key.is_some() {
            4
        } else {
            0
        };
    let mut updated =
        ProviderConfig { kind: Some(kind), base_url: Some(base_url).filter(|u| !u.is_empty()), ..current.clone() };
    match Select::new()
        .with_prompt(format!("API key ({})", key_status(&current)))
        .items(&sources)
        .default(source_default)
        .interact()?
    {
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
    println!(
        "Provider {name}: {} {}",
        format!("{kind:?}").to_lowercase(),
        updated.base_url.as_deref().unwrap_or("(from session token)")
    );
    if agent.provider_name() == name {
        // The edited provider serves the current model: rebuild the client so
        // the running session uses the new endpoint / key / model at once.
        match agent.refresh_client().await {
            Ok(()) => println!("Rebuilt the session's client for {name}."),
            Err(e) => println!("Provider saved, but could not rebuild the client: {e:#}"),
        }
    }
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

/// Set the temperature for the current model, its provider, or every model.
/// A model that accepts no temperature can only use its default, so there is
/// nothing to edit for it.
fn edit_temperature(agent: &mut Agent, changes: &mut Changes) -> Result<()> {
    use crate::temperature::{MAX, Temperature};
    let current = agent.temperature();
    // Target the live client's provider/model, not `config.model`: after a
    // provider's `default_model` is edited and the user declines to switch,
    // the two diverge, and the menu (via `agent.temperature()`) reports the
    // live model — so the edit must write to that same model, not the newly
    // configured default.
    let provider = agent.provider_name().to_string();
    let model = agent.model_name().to_string();
    if let Some(reason) = &current.fixed {
        println!("{provider}/{model} always uses the model default: {reason}.");
        return Ok(());
    }
    let scopes = [
        format!("This model ({provider}/{model})"),
        format!("All {provider} models"),
        "All models (global)".to_string(),
    ];
    let scope = Select::new().with_prompt("Set the temperature for").items(&scopes).default(0).interact()?;
    let config = agent.config();
    let entry = config.providers.get(&provider);
    let existing = match scope {
        0 => entry.and_then(|p| p.models.get(&model)).and_then(|m| m.temperature),
        1 => entry.and_then(|p| p.temperature),
        _ => Some(config.temperature),
    };
    let unset_hint = if scope < 2 { ", empty to unset" } else { "" };
    let text: String = Input::new()
        .with_prompt(format!("Temperature (0-{MAX}, \"default\" for the model default{unset_hint})"))
        .with_initial_text(existing.map(|t| t.to_string()).unwrap_or_default())
        .allow_empty(scope < 2)
        .validate_with(|s: &String| -> Result<(), String> {
            if s.trim().is_empty() { Ok(()) } else { s.parse::<Temperature>().map(|_| ()) }
        })
        .interact_text()?;
    let value =
        if text.trim().is_empty() { None } else { Some(text.parse::<Temperature>().map_err(anyhow::Error::msg)?) };
    let config = agent.config_mut();
    match scope {
        0 => {
            let entry = config.providers.entry(provider.clone()).or_default();
            match value {
                Some(t) => entry.models.entry(model.clone()).or_default().temperature = Some(t),
                None => {
                    if let Some(settings) = entry.models.get_mut(&model) {
                        settings.temperature = None;
                    }
                    if entry.models.get(&model).is_some_and(|m| *m == Default::default()) {
                        entry.models.remove(&model);
                    }
                }
            }
            changes.model_temperatures.insert((provider, model));
        }
        1 => {
            config.providers.entry(provider.clone()).or_default().temperature = value;
            changes.provider_temperatures.insert(provider);
        }
        _ => {
            if let Some(t) = value {
                config.temperature = t;
                changes.temperature = true;
            }
        }
    }
    let now = agent.temperature();
    println!("Temperature for this model: {}", now.describe());
    if let Some(warning) = now.warning {
        println!("Note: {warning}");
    }
    Ok(())
}

/// A temperature as a TOML value: a number, or the string `"default"`.
fn temperature_item(t: crate::temperature::Temperature) -> toml_edit::Item {
    match t {
        crate::temperature::Temperature::Default => toml_edit::value("default"),
        crate::temperature::Temperature::Value(v) => toml_edit::value(v),
    }
}

/// Set (or with `None`, remove) `key` in the table at `path`, creating the
/// tables on the way as implicit ones (so `[providers.x.models."m"]` doesn't
/// also write empty `[providers]` headers).
fn set_nested(
    doc: &mut toml_edit::DocumentMut,
    path: &[&str],
    key: &str,
    value: Option<crate::temperature::Temperature>,
) {
    let mut table: &mut dyn toml_edit::TableLike = doc.as_table_mut();
    // Inside an inline table (`models = { … }`) new tables must be inline too.
    let mut inline = false;
    for segment in path {
        if table.get(segment).and_then(toml_edit::Item::as_table_like).is_none() {
            if value.is_none() {
                return;
            }
            let new = if inline {
                toml_edit::Item::Value(toml_edit::Value::InlineTable(toml_edit::InlineTable::new()))
            } else {
                let mut new = toml_edit::Table::new();
                new.set_implicit(true);
                toml_edit::Item::Table(new)
            };
            table.insert(segment, new);
        }
        let item = table.get_mut(segment).expect("inserted above");
        inline = item.is_inline_table();
        table = item.as_table_like_mut().expect("checked above");
    }
    match value {
        Some(t) => {
            let mut item = temperature_item(t);
            // `TableLike::insert` replaces the whole item, including its
            // decoration, so editing an existing temperature would drop an
            // attached comment (`temperature = 0.3 # tuned for this model`).
            // Carry the old value's prefix/suffix over to keep it.
            if let Some(toml_edit::Item::Value(old)) = table.get(key)
                && let toml_edit::Item::Value(new) = &mut item
            {
                new.decor_mut().set_prefix(old.decor().prefix().cloned().unwrap_or_default());
                new.decor_mut().set_suffix(old.decor().suffix().cloned().unwrap_or_default());
            }
            table.insert(key, item);
        }
        None => {
            table.remove(key);
        }
    }
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
        // Reuse the decoration-preserving helper so editing the global
        // temperature keeps an attached comment (`temperature = 0.2 # tuned`),
        // matching the provider/model path.
        set_nested(&mut doc, &[], "temperature", Some(config.temperature));
    }
    for name in &changes.provider_temperatures {
        let value = config.providers.get(name).and_then(|p| p.temperature);
        set_nested(&mut doc, &["providers", name], "temperature", value);
    }
    for (name, model) in &changes.model_temperatures {
        let value = config.providers.get(name).and_then(|p| p.models.get(model)).and_then(|m| m.temperature);
        set_nested(&mut doc, &["providers", name, "models", model], "temperature", value);
    }
    if changes.max_tokens {
        doc["max_tokens"] = toml_edit::value(i64::from(config.max_tokens));
    }
    if changes.max_iterations {
        // A `usize` above `i64::MAX` would wrap to a negative TOML integer that
        // cannot be read back as `usize`; clamp instead of casting.
        doc["max_iterations"] = toml_edit::value(i64::try_from(config.max_iterations).unwrap_or(i64::MAX));
    }
    if changes.system_prompt {
        doc["system_prompt"] = toml_edit::value(config.system_prompt.as_str());
    }
    if changes.verbosity {
        doc["verbosity"] = toml_edit::value(config.verbosity.to_string());
    }
    if changes.renderer {
        doc["renderer"] = toml_edit::value(config.renderer.to_string());
    }
    if changes.compaction {
        doc["auto_compact"] = toml_edit::value(config.auto_compact);
        doc["auto_compact_threshold"] = toml_edit::value(config.auto_compact_threshold);
        doc["compaction_mode"] = toml_edit::value(config.compaction_mode.as_str());
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
            // Replacing the whole provider table rebuilds it from scratch and
            // drops every decoration. If this same provider's temperature (or a
            // model's) was also edited in this session, the decoration-
            // preserving `set_nested` edits above (e.g. a `# tuned` comment)
            // would be discarded. Snapshot those temperature items' decorations
            // first and reapply them after the replacement so their comments
            // survive overlapping provider + temperature edits.
            let mut saved: Vec<(Vec<&str>, toml_edit::Decor)> = Vec::new();
            if changes.provider_temperatures.contains(name)
                && let Some(d) = temperature_decor(&doc, &["providers", name])
            {
                saved.push((vec!["providers", name], d));
            }
            for (p, model) in &changes.model_temperatures {
                if p == name
                    && let Some(d) = temperature_decor(&doc, &["providers", name, "models", model])
                {
                    saved.push((vec!["providers", name, "models", model], d));
                }
            }
            doc["providers"][name.as_str()] = toml_edit::Item::Table(provider_table(provider)?);
            for (path, decor) in saved {
                set_temperature_decor(&mut doc, &path, decor);
            }
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

/// The decoration (prefix/suffix, i.e. any attached comment) of the
/// `temperature` value at `path`, if it is present as a plain value.
fn temperature_decor(doc: &toml_edit::DocumentMut, path: &[&str]) -> Option<toml_edit::Decor> {
    let mut table: &dyn toml_edit::TableLike = doc.as_table();
    for segment in path {
        table = table.get(segment)?.as_table_like()?;
    }
    match table.get("temperature")? {
        toml_edit::Item::Value(v) => Some(v.decor().clone()),
        _ => None,
    }
}

/// Reapply a previously captured decoration to the `temperature` value at
/// `path`, so a comment survives a whole-provider table replacement.
fn set_temperature_decor(doc: &mut toml_edit::DocumentMut, path: &[&str], decor: toml_edit::Decor) {
    let mut table: &mut dyn toml_edit::TableLike = doc.as_table_mut();
    for segment in path {
        let Some(next) = table.get_mut(segment).and_then(toml_edit::Item::as_table_like_mut) else {
            return;
        };
        table = next;
    }
    if let Some(toml_edit::Item::Value(v)) = table.get_mut("temperature") {
        *v.decor_mut() = decor;
    }
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

    fn providers(names: &[&str]) -> std::collections::BTreeMap<String, ProviderConfig> {
        names.iter().map(|n| (n.to_string(), ProviderConfig::default())).collect()
    }

    fn specs(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn recent_models_keep_four_with_a_configured_provider() {
        let all = providers(&["anthropic", "openai", "work"]);
        let recents =
            specs(&["work/llama3", "gone/model", "anthropic/claude", "bare-model", "openai/gpt-5", "openai/o3"]);
        // `gone` is no longer configured; a bare spec uses the default provider.
        assert_eq!(
            recent_models(&recents, &all),
            specs(&["work/llama3", "anthropic/claude", "bare-model", "openai/gpt-5"])
        );
        assert!(recent_models(&[], &all).is_empty());
    }

    #[test]
    fn provider_rows_list_recents_first_and_highlight_the_previous_model() {
        let all = providers(&["anthropic", "openai"]);
        let recent = specs(&["openai/gpt-5", "anthropic/claude"]);
        let (rows, default) = provider_rows(&recent, "openai/gpt-5", "openai", &all);
        let labels: Vec<&str> = rows.iter().map(|(label, _)| label.as_str()).collect();
        assert_eq!(labels[0], "↺ openai/gpt-5  (current)");
        assert_eq!(labels[1], "↺ anthropic/claude");
        assert!(labels[2].starts_with("anthropic ") && labels[3].starts_with("openai "), "{labels:?}");
        assert_eq!(labels[4], "Cancel");
        assert_eq!(rows[1].1, Some(ProviderChoice::Model("anthropic/claude".into())));
        assert_eq!(rows[3].1, Some(ProviderChoice::Provider("openai".into())));
        assert_eq!(rows[4].1, None);
        // Enter on the highlighted row switches back to the previous model.
        assert_eq!(default, 1);

        // The current model isn't the most recent (e.g. set from the config):
        // the most recent is highlighted.
        let (_, default) = provider_rows(&recent, "openai/o3", "openai", &all);
        assert_eq!(default, 0);
        // Only the current model is recent: highlight the current provider.
        let (_, default) = provider_rows(&specs(&["openai/gpt-5"]), "openai/gpt-5", "openai", &all);
        assert_eq!(default, 1 + 1);
        // No recents: the plain provider list, as before.
        let (rows, default) = provider_rows(&[], "openai/gpt-5", "openai", &all);
        assert_eq!((rows.len(), default), (3, 1));
    }

    #[test]
    fn turn_cap_label_marks_zero_as_unbounded() {
        assert_eq!(turn_cap_label(0), "unbounded");
        assert_eq!(turn_cap_label(50), "50 LLM calls per input (normal mode asks before stopping)");
    }

    #[test]
    fn model_choice_maps_rows_to_steps() {
        let models = vec!["alpha".to_string(), "beta".to_string()];
        assert_eq!(model_choice(None, &models), Step::Back, "Esc steps back");
        assert_eq!(model_choice(Some(0), &models), Step::Done("alpha".into()));
        assert_eq!(model_choice(Some(1), &models), Step::Done("beta".into()));
        assert_eq!(model_choice(Some(2), &models), Step::Done(String::new()), "Other prompts for an ID");
        assert_eq!(model_choice(Some(3), &models), Step::Back, "Back to providers");
    }

    #[test]
    fn model_spec_builds_provider_slash_model_or_goes_back() {
        assert_eq!(model_spec("work", "llama3"), Step::Done("work/llama3".into()));
        assert_eq!(model_spec("work", "  qwen3  "), Step::Done("work/qwen3".into()), "IDs are trimmed");
        assert_eq!(model_spec("work", ""), Step::Back, "empty ID goes back");
        assert_eq!(model_spec("work", "   "), Step::Back, "blank ID goes back");
    }

    #[test]
    fn save_writes_provider_and_model_temperatures_in_place() {
        use crate::temperature::Temperature;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "temperature = 0.2 # global tune\n\n[providers.groq] # fast\nmax_retries = 2\ntemperature = 0.1 # tuned for this provider\n\n[providers.kimi]\nmodels = { \"k3\" = { temperature = 0.5 } }\n",
        )
        .unwrap();
        let mut config: Config = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        config.temperature = Temperature::Default;
        config.providers.get_mut("groq").unwrap().temperature = Some(Temperature::Value(0.4));
        let anthropic = config.providers.entry("anthropic".into()).or_default();
        anthropic.models.entry("claude".into()).or_default().temperature = Some(Temperature::Value(0.3));
        // Unsetting inside an inline table removes just that key.
        config.providers.get_mut("kimi").unwrap().models.get_mut("k3").unwrap().temperature = None;
        let changes = Changes {
            temperature: true,
            provider_temperatures: ["groq".to_string()].into(),
            model_temperatures: [("anthropic".to_string(), "claude".to_string()), ("kimi".into(), "k3".into())].into(),
            ..Default::default()
        };
        save(&config, &changes, &path).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("temperature = \"default\" # global tune"), "global comment kept: {text}");
        // Replacing an existing value keeps its attached comment.
        assert!(
            text.contains("[providers.groq] # fast\nmax_retries = 2\ntemperature = 0.4 # tuned for this provider"),
            "{text}"
        );
        assert!(text.contains("[providers.anthropic.models.claude]\ntemperature = 0.3"), "{text}");
        assert!(!text.contains("[providers]\n") && !text.contains("[providers.anthropic]\n"), "implicit: {text}");
        assert!(!text.contains("0.5"), "{text}");
        let reloaded: Config = toml::from_str(&text).unwrap();
        assert_eq!(reloaded.temperature, Temperature::Default);
        assert_eq!(reloaded.providers["groq"].temperature, Some(Temperature::Value(0.4)));
        assert_eq!(reloaded.providers["anthropic"].models["claude"].temperature, Some(Temperature::Value(0.3)));
        assert_eq!(reloaded.providers["kimi"].models["k3"].temperature, None);
        assert_eq!(reloaded.providers["groq"].max_retries, Some(2));
    }

    #[test]
    fn save_keeps_temperature_comments_when_the_provider_is_also_edited() {
        use crate::temperature::Temperature;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "[providers.groq]\nmax_retries = 2\ntemperature = 0.1 # tuned\n\n[providers.groq.models.\"k3\"]\ntemperature = 0.5 # per-model\n",
        )
        .unwrap();
        let mut config: Config = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        // Edit the provider wholesale (a non-temperature field) *and* both its
        // provider- and model-level temperatures in the same session.
        config.providers.get_mut("groq").unwrap().max_retries = Some(5);
        config.providers.get_mut("groq").unwrap().temperature = Some(Temperature::Value(0.4));
        config.providers.get_mut("groq").unwrap().models.get_mut("k3").unwrap().temperature =
            Some(Temperature::Value(0.6));
        let changes = Changes {
            providers: ["groq".to_string()].into(),
            provider_temperatures: ["groq".to_string()].into(),
            model_temperatures: [("groq".to_string(), "k3".to_string())].into(),
            ..Default::default()
        };
        save(&config, &changes, &path).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        // The whole-provider replacement must not discard the temperature
        // comments the in-place edits preserved.
        assert!(text.contains("temperature = 0.4 # tuned"), "provider temp comment kept: {text}");
        assert!(text.contains("temperature = 0.6 # per-model"), "model temp comment kept: {text}");
        let reloaded: Config = toml::from_str(&text).unwrap();
        assert_eq!(reloaded.providers["groq"].max_retries, Some(5));
        assert_eq!(reloaded.providers["groq"].temperature, Some(Temperature::Value(0.4)));
        assert_eq!(reloaded.providers["groq"].models["k3"].temperature, Some(Temperature::Value(0.6)));
    }

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
        config.temperature = crate::temperature::Temperature::Value(0.9);
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
