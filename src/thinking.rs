//! Thinking level: `"default"` (send nothing), `"off"`, or a level
//! (`"low"`, `"medium"`, `"high"`). Set globally, per provider
//! (`[providers.NAME]`) and per model (`[providers.NAME.models."MODEL"]`);
//! the most specific setting wins. Models that don't support thinking (or
//! providers with `drop_params` for the thinking field) only accept the model
//! default, and a configured level is reported as ignored.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::providers::{ProviderConfig, ProviderKind};

/// A thinking-level setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Thinking {
    /// Send no thinking field; the model uses its own default.
    #[default]
    Default,
    /// Explicitly disable thinking.
    Off,
    Low,
    Medium,
    High,
}

impl Thinking {
    /// Every value, in the order `/thinking` and `/settings` offer them.
    pub const ALL: &[Thinking] = &[Thinking::Default, Thinking::Off, Thinking::Low, Thinking::Medium, Thinking::High];

    pub fn as_str(self) -> &'static str {
        match self {
            Thinking::Default => "default",
            Thinking::Off => "off",
            Thinking::Low => "low",
            Thinking::Medium => "medium",
            Thinking::High => "high",
        }
    }
}

impl fmt::Display for Thinking {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Thinking::Default => f.write_str("model default"),
            other => f.write_str(other.as_str()),
        }
    }
}

impl FromStr for Thinking {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s.trim().to_ascii_lowercase().as_str() {
            "default" | "model default" => Ok(Thinking::Default),
            "off" | "none" | "disabled" => Ok(Thinking::Off),
            "low" | "minimal" => Ok(Thinking::Low),
            "medium" | "med" => Ok(Thinking::Medium),
            "high" => Ok(Thinking::High),
            other => Err(format!("thinking must be one of default, off, low, medium, high; got {other:?}")),
        }
    }
}

impl Serialize for Thinking {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Thinking {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        s.parse().map_err(serde::de::Error::custom)
    }
}

/// Where the thinking level in effect came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `[providers.NAME.models."MODEL"] thinking`.
    Model,
    /// `[providers.NAME] thinking`.
    Provider,
    /// The top-level `thinking`.
    Global,
    /// A thinking field in the provider's `extra_body`, which is merged into
    /// the request after everything else.
    ExtraBody,
    /// The model accepts no thinking setting (see [`Resolved::fixed`]).
    Required,
    /// Set with `/thinking` for this session.
    Session,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Model => "set for this model",
            Source::Provider => "set for this provider",
            Source::Global => "global setting",
            Source::ExtraBody => "from the provider's extra_body",
            Source::Required => "required: the model accepts no thinking setting",
            Source::Session => "set for this session",
        }
    }
}

/// The thinking level a model is sent, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    /// What is sent: `Default` sends no thinking field.
    pub effective: Thinking,
    pub source: Source,
    /// Why the model can only use its default, when it can't take a level.
    pub fixed: Option<String>,
    /// A setting that is ignored or adjusted, worth telling the user about.
    pub warning: Option<String>,
}

impl Resolved {
    /// The thinking level to put in the request, if any.
    pub fn value(&self) -> Option<Thinking> {
        // extra_body already carries the field; sending ours too would conflict.
        (self.effective != Thinking::Default && self.source != Source::ExtraBody).then_some(self.effective)
    }

    /// One line for `/context` and `/settings`, e.g. `high (set for this model)`.
    pub fn describe(&self) -> String {
        format!("{} ({})", self.effective, self.source.label())
    }
}

/// Request-body fields that carry a thinking setting for a provider kind;
/// the first is the one nano-coder sends, the rest are recognised in
/// `extra_body` (Ollama's `think`, the Responses `reasoning` object).
pub fn body_fields(kind: ProviderKind) -> &'static [&'static str] {
    match kind {
        ProviderKind::Openai => &["reasoning_effort", "think", "reasoning"],
        ProviderKind::Anthropic => &["thinking"],
        ProviderKind::GithubCopilot => &["reasoning_effort", "reasoning", "thinking"],
        ProviderKind::Mock => &[],
    }
}

/// Why `model` on this provider accepts no thinking setting, if it doesn't.
pub fn fixed_reason(kind: ProviderKind, provider: &ProviderConfig, _model: &str) -> Option<String> {
    let dropped = provider.drop_params.as_deref().unwrap_or_default();
    let field = body_fields(kind).iter().find(|f| dropped.iter().any(|d| d == *f))?;
    Some(format!("the provider drops {field} (drop_params)"))
}

/// The level a thinking value in `extra_body` amounts to.
fn level_of(value: &toml::Value) -> Option<Thinking> {
    match value {
        toml::Value::String(s) => s.parse().ok(),
        toml::Value::Boolean(false) => Some(Thinking::Off),
        toml::Value::Boolean(true) => Some(Thinking::High),
        // `reasoning = { effort = "low" }`, `thinking = { type = "disabled" }`.
        toml::Value::Table(t) => match (t.get("effort"), t.get("type").and_then(|v| v.as_str())) {
            (Some(effort), _) => level_of(effort),
            (None, Some("disabled")) => Some(Thinking::Off),
            (None, Some("enabled")) => Some(match t.get("budget_tokens").and_then(|v| v.as_integer()) {
                Some(b) if b <= budget(Thinking::Low) => Thinking::Low,
                Some(b) if b <= budget(Thinking::Medium) => Thinking::Medium,
                _ => Thinking::High,
            }),
            _ => None,
        },
        _ => None,
    }
}

/// The `reasoning_effort` value for a level (Chat Completions; `"none"`
/// turns reasoning off on OpenAI, Ollama and most compatible servers).
pub fn effort(level: Thinking) -> &'static str {
    match level {
        Thinking::Off => "none",
        other => other.as_str(),
    }
}

/// Anthropic `budget_tokens` for a level.
pub fn budget(level: Thinking) -> i64 {
    match level {
        Thinking::Low => 2048,
        Thinking::Medium => 8192,
        _ => 16384,
    }
}

/// The thinking level for `model` on `provider` (the merged provider entry):
/// the model's setting, else the provider's, else `global`. A thinking field
/// in the provider's `extra_body` is merged into the request after everything
/// else, so it wins — and a warning says so.
pub fn resolve(global: Thinking, kind: ProviderKind, provider: &ProviderConfig, model: &str) -> Resolved {
    let (mut effective, mut source) = if let Some(t) = provider.models.get(model).and_then(|m| m.thinking) {
        (t, Source::Model)
    } else if let Some(t) = provider.thinking {
        (t, Source::Provider)
    } else {
        (global, Source::Global)
    };
    let mut warning = None;
    let extra = provider.extra_body.as_ref();
    if let Some((field, value)) = body_fields(kind).iter().find_map(|f| extra.and_then(|b| b.get(*f)).map(|v| (*f, v)))
    {
        let shown = value.to_string();
        match level_of(value) {
            Some(level) => {
                if effective != Thinking::Default && level != effective {
                    let label = source.label();
                    warning = Some(format!("extra_body {field} = {shown} wins over thinking {effective} ({label})"));
                }
                effective = level;
            }
            None => {
                warning =
                    Some(format!("extra_body {field} = {shown} is sent as is and wins over thinking {effective}"));
            }
        }
        source = Source::ExtraBody;
    }

    if let Some(reason) = fixed_reason(kind, provider, model) {
        // The global setting applies to every model, so a level there is not
        // a mistake for this one; a level set for this provider or model is.
        let warning = match (effective, source) {
            (Thinking::Default, _) => warning,
            (level, Source::Model | Source::Provider | Source::ExtraBody) => {
                Some(format!("thinking {level} ({}) is ignored: {reason}; using the model default", source.label()))
            }
            _ => warning,
        };
        return Resolved { effective: Thinking::Default, source: Source::Required, fixed: Some(reason), warning };
    }

    Resolved { effective, source, fixed: None, warning }
}

/// The thinking levels `model` on `provider` accepts, for `/settings` and
/// `/model` to offer: every level, or only the model default when the model
/// accepts no thinking setting.
pub fn supported_levels(kind: ProviderKind, provider: &ProviderConfig, model: &str) -> &'static [Thinking] {
    if fixed_reason(kind, provider, model).is_some() { &[Thinking::Default] } else { Thinking::ALL }
}

/// The thinking levels the model `config.model` names accepts.
pub fn levels_for(config: &crate::config::Config) -> &'static [Thinking] {
    let (user, default_provider) = config.effective_providers();
    let providers = crate::providers::effective_providers(&user);
    let (name, model) = crate::providers::parse_model_spec(&config.model, &providers, &default_provider);
    let Some(provider) = providers.get(name) else { return Thinking::ALL };
    let model = model.map(str::to_string).or_else(|| provider.default_model.clone()).unwrap_or_default();
    supported_levels(provider.kind.unwrap_or(ProviderKind::Mock), provider, &model)
}

impl Thinking {
    /// A short note for `/thinking` and the type-ahead.
    pub fn describe(self) -> &'static str {
        match self {
            Thinking::Default => "send nothing; the model decides",
            Thinking::Off => "ask the model not to think",
            Thinking::Low => "brief reasoning",
            Thinking::Medium => "moderate reasoning",
            Thinking::High => "extended reasoning",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn provider(toml_text: &str) -> ProviderConfig {
        toml::from_str(toml_text).unwrap()
    }

    #[test]
    fn parses_levels_and_default() {
        let config: Config = toml::from_str("thinking = \"high\"").unwrap();
        assert_eq!(config.thinking, Thinking::High);
        let config: Config = toml::from_str("thinking = \"off\"").unwrap();
        assert_eq!(config.thinking, Thinking::Off);
        let config: Config = toml::from_str("thinking = \"default\"").unwrap();
        assert_eq!(config.thinking, Thinking::Default);
        assert!(toml::from_str::<Config>("thinking = \"warm\"").is_err());

        assert_eq!("default".parse::<Thinking>(), Ok(Thinking::Default));
        assert_eq!(" off ".parse::<Thinking>(), Ok(Thinking::Off));
        assert_eq!("LOW".parse::<Thinking>(), Ok(Thinking::Low));
        assert_eq!("medium".parse::<Thinking>(), Ok(Thinking::Medium));
        assert_eq!("high".parse::<Thinking>(), Ok(Thinking::High));
        assert!("hot".parse::<Thinking>().is_err());
        // Round-trips through the config file.
        let text = toml::to_string(&Config { thinking: Thinking::Off, ..Default::default() }).unwrap();
        assert!(text.contains("thinking = \"off\""), "{text}");
    }

    #[test]
    fn most_specific_setting_wins() {
        let global = Thinking::Low;
        let p = provider("thinking = \"medium\"\n[models.\"big\"]\nthinking = \"off\"\n");
        let r = resolve(global, ProviderKind::Openai, &p, "big");
        assert_eq!((r.effective, r.source, r.value()), (Thinking::Off, Source::Model, Some(Thinking::Off)));
        let r = resolve(global, ProviderKind::Openai, &p, "small");
        assert_eq!((r.value(), r.source), (Some(Thinking::Medium), Source::Provider));
        let r = resolve(global, ProviderKind::Openai, &ProviderConfig::default(), "small");
        assert_eq!((r.value(), r.source), (Some(Thinking::Low), Source::Global));
        assert_eq!(r.describe(), "low (global setting)");
        assert_eq!(r.warning, None);

        // extra_body is merged into the request last, so it is what is sent.
        let p = provider("thinking = \"medium\"\nextra_body = { reasoning_effort = \"low\" }\n");
        let r = resolve(global, ProviderKind::Openai, &p, "m");
        assert_eq!((r.effective, r.source, r.value()), (Thinking::Low, Source::ExtraBody, None));
        let warning = r.warning.unwrap();
        assert!(warning.contains("wins over thinking medium"), "{warning}");
        // Anthropic's thinking object and the Responses reasoning object.
        let p = provider("extra_body = { thinking = { type = \"disabled\" } }\n");
        assert_eq!(resolve(global, ProviderKind::Anthropic, &p, "c").effective, Thinking::Off);
        let p = provider("extra_body = { reasoning = { effort = \"high\" } }\n");
        assert_eq!(resolve(global, ProviderKind::GithubCopilot, &p, "gpt-5").effective, Thinking::High);
    }

    #[test]
    fn extra_body_boolean_and_invalid_values() {
        let global = Thinking::Default;
        // A boolean `think` (Ollama-style) maps to off / high.
        let p = provider("extra_body = { think = false }\n");
        let r = resolve(global, ProviderKind::Openai, &p, "m");
        assert_eq!((r.effective, r.source, r.value()), (Thinking::Off, Source::ExtraBody, None));
        let p = provider("extra_body = { think = true }\n");
        let r = resolve(global, ProviderKind::Openai, &p, "m");
        assert_eq!((r.effective, r.source, r.value()), (Thinking::High, Source::ExtraBody, None));
        // An unrecognised value is still sent as is, with a warning.
        let p = provider("extra_body = { reasoning_effort = \"warm\" }\n");
        let r = resolve(global, ProviderKind::Openai, &p, "m");
        assert_eq!(r.value(), None);
        assert!(r.warning.as_deref().unwrap().contains("reasoning_effort"));
    }

    #[test]
    fn models_without_thinking_only_use_the_default() {
        let global = Thinking::High;
        // The global setting isn't meant for this model: no warning.
        let p = provider("drop_params = [\"reasoning_effort\"]\n");
        let r = resolve(global, ProviderKind::Openai, &p, "m");
        assert_eq!((r.value(), r.source), (None, Source::Required));
        assert!(r.fixed.as_deref().unwrap().contains("drop_params"));
        assert_eq!(r.warning, None);

        // A level set for the model is ignored, with a warning.
        let p = provider("drop_params = [\"reasoning_effort\"]\n[models.\"k3\"]\nthinking = \"high\"\n");
        let r = resolve(global, ProviderKind::Openai, &p, "k3");
        assert_eq!(r.value(), None);
        let warning = r.warning.unwrap();
        assert!(warning.contains("high") && warning.contains("drop_params"), "{warning}");
        // "default" set for it is what it gets anyway: no warning.
        let p = provider("drop_params = [\"reasoning_effort\"]\nthinking = \"default\"\n");
        assert_eq!(resolve(global, ProviderKind::Openai, &p, "k3").warning, None);
    }

    #[test]
    fn supported_levels_follows_fixed_reason() {
        let p = provider("drop_params = [\"reasoning_effort\"]\n");
        assert_eq!(supported_levels(ProviderKind::Openai, &p, "m"), &[Thinking::Default]);
        assert_eq!(supported_levels(ProviderKind::Openai, &ProviderConfig::default(), "m"), Thinking::ALL);
    }

    #[test]
    fn user_model_settings_merge_over_presets() {
        let preset = provider("thinking = \"low\"\n[models.\"a\"]\nthinking = \"off\"\n");
        let user = provider("[models.\"b\"]\nthinking = \"high\"\n");
        let merged = preset.merged_with(&user);
        assert_eq!(merged.thinking, Some(Thinking::Low));
        assert_eq!(merged.models["a"].thinking, Some(Thinking::Off));
        assert_eq!(merged.models["b"].thinking, Some(Thinking::High));
    }
}
