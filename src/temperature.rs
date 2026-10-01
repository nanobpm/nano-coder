//! Sampling temperature: a number, or `"default"` to send none and let the
//! model use its own. Set globally, per provider (`[providers.NAME]`) and per
//! model (`[providers.NAME.models."MODEL"]`); the most specific setting wins.
//! Some models accept no temperature at all (reasoning models, and providers
//! with `drop_params = ["temperature"]`): for them only the model default is
//! possible, and a configured number is reported as ignored.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::providers::{ProviderConfig, ProviderKind};

/// Highest temperature accepted when typed in `/settings` (OpenAI's range).
pub const MAX: f64 = 2.0;

/// A temperature setting.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Temperature {
    /// Send no `temperature`; the model uses its own default.
    Default,
    Value(f64),
}

impl fmt::Display for Temperature {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Temperature::Default => f.write_str("model default"),
            Temperature::Value(v) => write!(f, "{v}"),
        }
    }
}

impl FromStr for Temperature {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        let s = s.trim();
        if s.eq_ignore_ascii_case("default") || s.eq_ignore_ascii_case("model default") {
            return Ok(Temperature::Default);
        }
        match s.parse::<f64>() {
            Ok(v) if (0.0..=MAX).contains(&v) => Ok(Temperature::Value(v)),
            _ => Err(format!("temperature must be a number from 0 to {MAX}, or \"default\"; got {s:?}")),
        }
    }
}

impl Serialize for Temperature {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Temperature::Default => serializer.serialize_str("default"),
            Temperature::Value(v) => serializer.serialize_f64(*v),
        }
    }
}

impl<'de> Deserialize<'de> for Temperature {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Number(f64),
            Int(i64),
            Text(String),
        }
        match Raw::deserialize(deserializer)? {
            // TOML permits `nan`/`inf`, but serde_json emits a non-finite f64
            // as JSON `null` while `/context` and the trajectory report the
            // value as sent — reject them so the two cannot diverge.
            Raw::Number(v) if v.is_finite() => Ok(Temperature::Value(v)),
            Raw::Number(v) => Err(serde::de::Error::custom(format!("temperature must be finite, not {v}"))),
            Raw::Int(v) => Ok(Temperature::Value(v as f64)),
            Raw::Text(s) if s.trim().eq_ignore_ascii_case("default") => Ok(Temperature::Default),
            Raw::Text(s) => {
                Err(serde::de::Error::custom(format!("temperature must be a number or \"default\", not {s:?}")))
            }
        }
    }
}

/// Settings for one model of a provider (`[providers.NAME.models."MODEL"]`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelSettings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<Temperature>,
}

/// Where the temperature in effect came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `[providers.NAME.models."MODEL"] temperature`.
    Model,
    /// `[providers.NAME] temperature`.
    Provider,
    /// The top-level `temperature`.
    Global,
    /// `temperature` in the provider's `extra_body`, which is merged into the
    /// request after everything else.
    ExtraBody,
    /// The model accepts no temperature (see [`Resolved::fixed`]).
    Required,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Model => "set for this model",
            Source::Provider => "set for this provider",
            Source::Global => "global setting",
            Source::ExtraBody => "from the provider's extra_body",
            Source::Required => "required: the model accepts no temperature",
        }
    }
}

/// The temperature a model is sent, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    /// What is sent: `Default` sends no `temperature` field.
    pub effective: Temperature,
    pub source: Source,
    /// Why the model can only use its default, when it can't take a value.
    pub fixed: Option<String>,
    /// A setting that is ignored or adjusted, worth telling the user about.
    pub warning: Option<String>,
}

impl Resolved {
    /// The `temperature` to put in the request, if any.
    pub fn value(&self) -> Option<f64> {
        match self.effective {
            Temperature::Default => None,
            Temperature::Value(v) => Some(v),
        }
    }

    /// One line for `/context` and `/settings`, e.g. `0.3 (set for this model)`.
    pub fn describe(&self) -> String {
        format!("{} ({})", self.effective, self.source.label())
    }
}

/// Why `model` on this provider accepts no temperature, if it doesn't.
/// `kind` is `None` when the client's API is unknown (e.g. a test double), in
/// which case no kind-specific rule applies.
pub fn fixed_reason(kind: Option<ProviderKind>, provider: &ProviderConfig, model: &str) -> Option<String> {
    if provider.drop_params.as_ref().is_some_and(|d| d.iter().any(|p| p == "temperature")) {
        return Some("the provider drops temperature (drop_params)".to_string());
    }
    if kind == Some(ProviderKind::GithubCopilot) && crate::providers::github_copilot::is_reasoning_model(model) {
        return Some(format!("{model} is a reasoning model and rejects a custom temperature"));
    }
    None
}

/// The temperature for `model` on `provider` (the merged provider entry):
/// the model's setting, else the provider's, else `global`.
pub fn resolve(global: Temperature, kind: Option<ProviderKind>, provider: &ProviderConfig, model: &str) -> Resolved {
    let (chosen, mut source) = if let Some(t) = provider.models.get(model).and_then(|m| m.temperature) {
        (t, Source::Model)
    } else if let Some(t) = provider.temperature {
        (t, Source::Provider)
    } else {
        (global, Source::Global)
    };
    let mut effective = chosen;
    if let Some(v) = provider.extra_body.as_ref().and_then(|b| b.get("temperature")).and_then(|v| match v {
        toml::Value::Float(f) => Some(*f),
        toml::Value::Integer(i) => Some(*i as f64),
        _ => None,
    }) {
        effective = Temperature::Value(v);
        source = Source::ExtraBody;
    }

    if let Some(reason) = fixed_reason(kind, provider, model) {
        // The global setting applies to every model, so a number there is not
        // a mistake for this one; a number set for this provider or model is.
        let warning = match (effective, source) {
            (Temperature::Value(v), Source::Model | Source::Provider | Source::ExtraBody) => {
                Some(format!("temperature {v} ({}) is ignored: {reason}; using the model default", source.label()))
            }
            _ => None,
        };
        return Resolved { effective: Temperature::Default, source: Source::Required, fixed: Some(reason), warning };
    }

    let mut warning = None;
    // Anthropic's Messages API takes 0..=1, and `anthropic::build_body` clamps
    // out-of-range values silently. That builder is used for Anthropic
    // providers and for Copilot's Claude 4.x/5.x models (routed to
    // `/v1/messages`), so resolve and report both bounds for exactly those
    // requests — `/context`, ACP and trajectory then show the value actually
    // sent, with a warning.
    let anthropic_messages = kind == Some(ProviderKind::Anthropic)
        || (kind == Some(ProviderKind::GithubCopilot)
            && crate::providers::github_copilot::uses_anthropic_messages(model));
    if anthropic_messages && let Temperature::Value(v) = effective {
        if v > 1.0 {
            warning = Some(format!("temperature {v} is above Anthropic's maximum of 1; sending 1"));
            effective = Temperature::Value(1.0);
        } else if v < 0.0 {
            warning = Some(format!("temperature {v} is below Anthropic's minimum of 0; sending 0"));
            effective = Temperature::Value(0.0);
        }
    }
    Resolved { effective, source, fixed: None, warning }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn provider(toml_text: &str) -> ProviderConfig {
        toml::from_str(toml_text).unwrap()
    }

    #[test]
    fn parses_numbers_and_default() {
        let config: Config = toml::from_str("temperature = 1").unwrap();
        assert_eq!(config.temperature, Temperature::Value(1.0));
        let config: Config = toml::from_str("temperature = 0.2").unwrap();
        assert_eq!(config.temperature, Temperature::Value(0.2));
        let config: Config = toml::from_str("temperature = \"default\"").unwrap();
        assert_eq!(config.temperature, Temperature::Default);
        assert!(toml::from_str::<Config>("temperature = \"warm\"").is_err());

        assert_eq!("default".parse::<Temperature>(), Ok(Temperature::Default));
        assert_eq!(" 0.5 ".parse::<Temperature>(), Ok(Temperature::Value(0.5)));
        assert!("3".parse::<Temperature>().is_err());
        assert!("hot".parse::<Temperature>().is_err());
        // Round-trips through the config file.
        let text = toml::to_string(&Config { temperature: Temperature::Default, ..Default::default() }).unwrap();
        assert!(text.contains("temperature = \"default\""), "{text}");
    }

    #[test]
    fn rejects_non_finite_values() {
        // TOML parses these as f64 nan/inf; serde_json would emit them as JSON
        // `null` while `/context` reports the value as sent, so they are
        // rejected at load.
        for text in ["temperature = nan", "temperature = inf", "temperature = -inf"] {
            let err = toml::from_str::<Config>(text).unwrap_err();
            assert!(err.message().contains("temperature must be finite"), "{text}: {err}");
        }
    }

    #[test]
    fn most_specific_setting_wins() {
        let global = Temperature::Value(0.7);
        let p = provider("temperature = 0.4\n[models.\"big\"]\ntemperature = \"default\"\n");
        let r = resolve(global, Some(ProviderKind::Openai), &p, "big");
        assert_eq!((r.effective, r.source, r.value()), (Temperature::Default, Source::Model, None));
        let r = resolve(global, Some(ProviderKind::Openai), &p, "small");
        assert_eq!((r.value(), r.source), (Some(0.4), Source::Provider));
        let r = resolve(global, Some(ProviderKind::Openai), &ProviderConfig::default(), "small");
        assert_eq!((r.value(), r.source), (Some(0.7), Source::Global));
        assert_eq!(r.describe(), "0.7 (global setting)");
        assert_eq!(r.warning, None);

        // extra_body is merged into the request last, so it is what is sent.
        let p = provider("temperature = 0.4\nextra_body = { temperature = 0.1 }\n");
        let r = resolve(global, Some(ProviderKind::Openai), &p, "m");
        assert_eq!((r.value(), r.source), (Some(0.1), Source::ExtraBody));
    }

    #[test]
    fn models_without_temperature_only_use_the_default() {
        let global = Temperature::Value(0.7);
        // The global setting isn't meant for this model: no warning.
        let r = resolve(global, Some(ProviderKind::GithubCopilot), &ProviderConfig::default(), "gpt-5");
        assert_eq!((r.value(), r.source), (None, Source::Required));
        assert!(r.fixed.as_deref().unwrap().contains("reasoning model"));
        assert_eq!(r.warning, None);
        // A non-reasoning Copilot model takes a temperature.
        let r = resolve(global, Some(ProviderKind::GithubCopilot), &ProviderConfig::default(), "gpt-4.1");
        assert_eq!(r.value(), Some(0.7));

        // A number set for the model is ignored, with a warning.
        let p = provider("drop_params = [\"temperature\"]\n[models.\"k3\"]\ntemperature = 0.3\n");
        let r = resolve(global, Some(ProviderKind::Openai), &p, "k3");
        assert_eq!(r.value(), None);
        let warning = r.warning.unwrap();
        assert!(warning.contains("0.3") && warning.contains("drop_params"), "{warning}");
        // "default" set for it is what it gets anyway: no warning.
        let p = provider("drop_params = [\"temperature\"]\ntemperature = \"default\"\n");
        assert_eq!(resolve(global, Some(ProviderKind::Openai), &p, "k3").warning, None);
    }

    #[test]
    fn anthropic_range_is_checked() {
        let p = provider("temperature = 1.5\n");
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::Anthropic), &p, "claude");
        assert_eq!(r.value(), Some(1.0));
        assert!(r.warning.unwrap().contains("Anthropic's maximum"));
        // Negative values are clamped to 0 with a warning, matching the body
        // builder, rather than being reported as sent.
        let p = provider("temperature = -0.5\n");
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::Anthropic), &p, "claude");
        assert_eq!(r.value(), Some(0.0));
        assert!(r.warning.unwrap().contains("Anthropic's minimum"));
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::Anthropic), &ProviderConfig::default(), "claude");
        assert_eq!((r.value(), r.warning), (Some(0.7), None));
    }

    #[test]
    fn copilot_claude_uses_the_anthropic_range() {
        // Claude 4.x/5.x on GitHub Copilot is served through the Anthropic
        // Messages endpoint, whose body builder clamps to 0..=1 — resolve the
        // same way so the reported value is the one sent.
        let p = provider("temperature = 1.5\n");
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::GithubCopilot), &p, "claude-sonnet-4.5");
        assert_eq!(r.value(), Some(1.0));
        assert!(r.warning.unwrap().contains("Anthropic's maximum"));
        let p = provider("temperature = -0.5\n");
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::GithubCopilot), &p, "claude-opus-5");
        assert_eq!(r.value(), Some(0.0));
        assert!(r.warning.unwrap().contains("Anthropic's minimum"));
        // In-range values pass through untouched …
        let r = resolve(
            Temperature::Value(0.7),
            Some(ProviderKind::GithubCopilot),
            &ProviderConfig::default(),
            "claude-haiku-4.5",
        );
        assert_eq!((r.value(), r.warning), (Some(0.7), None));
        // … and non-Messages Copilot models keep the wider OpenAI range.
        let p = provider("temperature = 1.5\n");
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::GithubCopilot), &p, "gpt-4.1");
        assert_eq!((r.value(), r.warning), (Some(1.5), None));
        let r = resolve(Temperature::Value(0.7), Some(ProviderKind::GithubCopilot), &p, "claude-sonnet-3.5");
        assert_eq!((r.value(), r.warning), (Some(1.5), None));
        // An unknown kind (a test double) applies no provider rules.
        let r = resolve(Temperature::Value(0.7), None, &p, "claude-sonnet-4.5");
        assert_eq!((r.value(), r.warning), (Some(1.5), None));
    }

    #[test]
    fn user_model_settings_merge_over_presets() {
        let preset = provider("temperature = 0.2\n[models.\"a\"]\ntemperature = 0.1\n");
        let user = provider("[models.\"b\"]\ntemperature = \"default\"\n");
        let merged = preset.merged_with(&user);
        assert_eq!(merged.temperature, Some(Temperature::Value(0.2)));
        assert_eq!(merged.models["a"].temperature, Some(Temperature::Value(0.1)));
        assert_eq!(merged.models["b"].temperature, Some(Temperature::Default));
    }
}
