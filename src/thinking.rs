//! Thinking level: how much the model reasons before it answers. `"default"`
//! sends nothing (the model decides), `"off"` turns thinking off where the
//! model allows it, and a level (`"low"`, `"medium"`, `"high"`, `"xhigh"`,
//! `"max"`, …) asks for that much. Set globally, per provider
//! (`[providers.NAME]`) and per model (`[providers.NAME.models."MODEL"]`); the
//! most specific setting wins, and `/thinking LEVEL` overrides all of them for
//! the session.
//!
//! Only levels the model supports can be sent. They come from a
//! `thinking_levels` list in the config (model, then provider), else a
//! built-in table of well-known model families. A level the model doesn't
//! support is moved to the nearest one it does, with a warning.
//!
//! Each API gets its own request field (see [`Request`]): Chat Completions
//! `reasoning_effort`, Responses `reasoning.effort`, and Anthropic Messages
//! adaptive thinking with `output_config.effort` (or, on older Claude models,
//! a fixed `budget_tokens`).

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::providers::{ProviderConfig, ProviderKind};

/// Named levels from least to most thinking. "Nearest" is measured on this
/// scale; a custom level from `thinking_levels` that isn't on it only matches
/// exactly.
pub const ORDER: [&str; 6] = ["minimal", "low", "medium", "high", "xhigh", "max"];

/// A thinking setting.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Thinking {
    /// Send nothing; the model (or the provider's `extra_body`) decides.
    #[default]
    Default,
    /// Turn thinking off.
    Off,
    /// A named level, stored lower-case.
    Level(String),
}

impl fmt::Display for Thinking {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Thinking::Default => f.write_str("model default"),
            Thinking::Off => f.write_str("off"),
            Thinking::Level(level) => f.write_str(level),
        }
    }
}

impl FromStr for Thinking {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        let s = s.trim().to_ascii_lowercase();
        match s.as_str() {
            "default" | "model default" | "auto" => Ok(Thinking::Default),
            "off" | "none" | "disabled" => Ok(Thinking::Off),
            "" => Err("thinking level is empty; use \"default\", \"off\" or a level such as \"high\"".into()),
            level if level.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') => {
                Ok(Thinking::Level(level.to_string()))
            }
            other => {
                Err(format!("thinking must be \"default\", \"off\" or a level name such as \"high\"; got {other:?}"))
            }
        }
    }
}

impl Serialize for Thinking {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Thinking::Default => serializer.serialize_str("default"),
            other => serializer.serialize_str(&other.to_string()),
        }
    }
}

impl<'de> Deserialize<'de> for Thinking {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?.parse().map_err(serde::de::Error::custom)
    }
}

/// How an Anthropic Messages model takes a thinking level.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnthropicStyle {
    /// `thinking = { type = "adaptive" }` plus `output_config.effort`.
    Adaptive,
    /// `thinking = { type = "enabled", budget_tokens = N }` (Claude 3.7 to 4.5).
    Budget,
}

/// What the request asks for, after resolution. Built by [`Resolved::request`]
/// and turned into fields by each provider's body builder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    /// Turn thinking off.
    Off,
    /// A named effort level (`reasoning_effort`, `reasoning.effort`, or
    /// Anthropic adaptive thinking with `output_config.effort`).
    Effort(String),
    /// Anthropic fixed thinking budget in tokens; the builder caps it below
    /// `max_tokens`.
    Budget(u32),
    /// llama.cpp, chat templates with an on/off switch (Qwen 3 and the
    /// like): `chat_template_kwargs.enable_thinking`.
    TemplateSwitch(bool),
    /// llama.cpp, chat templates that take a level (gpt-oss):
    /// `chat_template_kwargs.reasoning_effort`.
    TemplateEffort(String),
}

/// How a Chat Completions request carries the level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Format {
    /// `reasoning_effort` (OpenAI, Ollama, most OpenAI-compatible servers).
    #[default]
    Effort,
    /// llama.cpp: `chat_template_kwargs.enable_thinking` (on or off only).
    TemplateSwitch,
    /// llama.cpp: `chat_template_kwargs.reasoning_effort`.
    TemplateEffort,
}

/// The level of models that can only switch thinking on or off; any named
/// level selects it.
pub const ON: &str = "on";

/// Anthropic thinking budget for a level on [`AnthropicStyle::Budget`] models.
pub fn budget_tokens(level: &str) -> u32 {
    match level {
        "minimal" => 1024,
        "low" => 2048,
        "medium" => 8192,
        "high" => 16384,
        "xhigh" => 32768,
        _ => 65536,
    }
}

/// Smallest budget Anthropic accepts.
pub const MIN_BUDGET: u32 = 1024;

/// The thinking budget to send under an output cap of `max_tokens`, which the
/// budget must stay below; `None` when the cap leaves no room for the minimum.
pub fn capped_budget(budget: u32, max_tokens: i64) -> Option<u32> {
    let room = max_tokens.saturating_sub(1).clamp(0, u32::MAX as i64) as u32;
    let budget = budget.min(room);
    (budget >= MIN_BUDGET).then_some(budget)
}

/// What a model supports, from the built-in table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    /// Levels it accepts, `"off"` included when thinking can be turned off.
    pub levels: Vec<String>,
    /// How Anthropic Messages takes the level (for Claude models only).
    pub anthropic: Option<AnthropicStyle>,
}

impl Profile {
    fn new(levels: &[&str], anthropic: Option<AnthropicStyle>) -> Self {
        Profile { levels: levels.iter().map(|l| l.to_string()).collect(), anthropic }
    }
}

/// `(family, major, minor)` of a Claude model id, e.g. `claude-sonnet-4-5-20250929`
/// → `("sonnet", 4, 5)`, `claude-opus-4.7` → `("opus", 4, 7)`,
/// `claude-3-7-sonnet-latest` → `("sonnet", 3, 7)`. The id may carry a vendor
/// prefix (`anthropic/…`, `anthropic.…` on Bedrock).
fn claude_version(id: &str) -> Option<(&'static str, u32, u32)> {
    let rest = &id[id.find("claude-")? + "claude-".len()..];
    // A one- or two-digit number at the start of `s`, and what follows it.
    fn number(s: &str) -> Option<(u32, &str)> {
        let digits = s.chars().take_while(char::is_ascii_digit).count();
        // Two digits at most: a date suffix (`20250929`) is not a version.
        if digits == 0 || digits > 2 {
            return None;
        }
        Some((s[..digits].parse().ok()?, &s[digits..]))
    }
    // `minor` is one digit after `.`/`-`, followed by the end or a non-digit.
    fn minor(s: &str) -> u32 {
        let Some(tail) = s.strip_prefix(['.', '-']) else { return 0 };
        match number(tail) {
            Some((m, after)) if m < 10 && !after.starts_with(|c: char| c.is_ascii_digit()) => m,
            _ => 0,
        }
    }
    for family in ["opus", "sonnet", "haiku", "fable"] {
        // `claude-sonnet-4-5`, `claude-opus-4.7`, `claude-fable-5`.
        if let Some(after) = rest.strip_prefix(family).and_then(|r| r.strip_prefix('-'))
            && let Some((major, tail)) = number(after)
        {
            return Some((family, major, minor(tail)));
        }
    }
    // The older `claude-3-7-sonnet` order.
    let (major, tail) = number(rest)?;
    let minor_value = minor(tail);
    for family in ["opus", "sonnet", "haiku"] {
        if tail.contains(family) {
            return Some((family, major, minor_value));
        }
    }
    None
}

/// The built-in profile for a model id, if its family is known.
pub fn builtin(model: &str) -> Option<Profile> {
    use AnthropicStyle::{Adaptive, Budget};
    let id = model.to_ascii_lowercase();
    if let Some((family, major, minor)) = claude_version(&id) {
        let version = (major, minor);
        return match family {
            // Fable and Opus/Sonnet 5.5 and later always think; effort sets how much.
            "fable" => Some(Profile::new(&["low", "medium", "high", "xhigh", "max"], Some(Adaptive))),
            "opus" | "sonnet" if version >= (5, 5) => {
                Some(Profile::new(&["low", "medium", "high", "xhigh", "max"], Some(Adaptive)))
            }
            "opus" | "sonnet" if version >= (4, 7) => {
                Some(Profile::new(&["off", "low", "medium", "high", "xhigh", "max"], Some(Adaptive)))
            }
            "opus" | "sonnet" if version == (4, 6) => {
                Some(Profile::new(&["off", "low", "medium", "high", "max"], Some(Adaptive)))
            }
            // Extended thinking with a fixed budget: Claude 3.7 Sonnet to 4.5.
            _ if ((3, 7)..(4, 6)).contains(&version) && !(family == "haiku" && version < (4, 5)) => {
                Some(Profile::new(&["off", "low", "medium", "high"], Some(Budget)))
            }
            _ => None,
        };
    }
    // The last path segment: `openai/gpt-5` on OpenRouter is `gpt-5`.
    let id = id.rsplit('/').next().unwrap_or(&id);
    let major = |rest: &str| rest.chars().take_while(char::is_ascii_digit).collect::<String>().parse::<u32>().ok();
    if id.strip_prefix("gpt-").and_then(major).is_some_and(|m| m >= 5) {
        return Some(Profile::new(&["low", "medium", "high"], None));
    }
    if ["o1", "o3", "o4"].iter().any(|p| id == *p || id.starts_with(&format!("{p}-"))) {
        return Some(Profile::new(&["low", "medium", "high"], None));
    }
    None
}

/// Thinking levels an endpoint reports for a model (GitHub Copilot's
/// `/models` lists them as `capabilities.supports.reasoning_effort`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reported {
    /// Levels it accepts; `"off"` when the endpoint lists `"none"`.
    pub levels: Vec<String>,
    /// The endpoint says the model uses adaptive thinking
    /// (`capabilities.supports.adaptive_thinking`).
    pub adaptive: bool,
    /// How the request carries the level for this server.
    pub format: Format,
}

impl Reported {
    /// Read the levels from one `/models` entry; `None` when it lists none.
    pub fn from_model_entry(entry: &serde_json::Value) -> Option<Reported> {
        let supports = entry.pointer("/capabilities/supports")?;
        let levels: Vec<String> = supports
            .get("reasoning_effort")?
            .as_array()?
            .iter()
            .filter_map(serde_json::Value::as_str)
            .map(|level| match level.trim().to_ascii_lowercase().as_str() {
                "none" => "off".to_string(),
                other => other.to_string(),
            })
            .filter(|level| !level.is_empty())
            .collect();
        if levels.is_empty() {
            return None;
        }
        let adaptive = supports.get("adaptive_thinking").and_then(serde_json::Value::as_bool).unwrap_or(false);
        Some(Reported { levels, adaptive, format: Format::Effort })
    }

    /// Ollama `/api/show`: a model with the `thinking` capability takes
    /// `reasoning_effort` (`none` turns it off). Ollama rejects a level for a
    /// model without it, so none is reported then.
    pub fn from_ollama_show(show: &serde_json::Value) -> Option<Reported> {
        let thinks = show.get("capabilities")?.as_array()?.iter().any(|c| c.as_str() == Some("thinking"));
        thinks.then(|| Reported {
            levels: ["off", "low", "medium", "high"].map(String::from).to_vec(),
            adaptive: false,
            format: Format::Effort,
        })
    }

    /// llama.cpp `/props`: what the loaded model's chat template accepts.
    /// llama.cpp ignores `reasoning_effort`; the template's own variables
    /// (`chat_template_kwargs`) control thinking.
    pub fn from_llamacpp_props(props: &serde_json::Value) -> Option<Reported> {
        let template = props.get("chat_template")?.as_str()?;
        let (levels, format): (&[&str], Format) = if template.contains("reasoning_effort") {
            (&["low", "medium", "high"], Format::TemplateEffort)
        } else if template.contains("enable_thinking") {
            (&["off", ON], Format::TemplateSwitch)
        } else {
            return None;
        };
        Some(Reported { levels: levels.iter().map(|l| l.to_string()).collect(), adaptive: false, format })
    }
}

/// Which request format `model` is sent in by a client of `kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wire {
    ChatCompletions,
    Responses,
    AnthropicMessages,
}

pub fn wire(kind: Option<ProviderKind>, model: &str) -> Wire {
    match kind {
        Some(ProviderKind::Anthropic) => Wire::AnthropicMessages,
        Some(ProviderKind::GithubCopilot) => crate::providers::github_copilot::wire_for_model(model),
        _ => Wire::ChatCompletions,
    }
}

/// `extra_body` keys that carry a thinking setting for `wire`; one of these in
/// the provider's `extra_body` is merged in last and wins.
fn extra_body_keys(wire: Wire) -> &'static [&'static str] {
    match wire {
        Wire::ChatCompletions => &["reasoning_effort", "reasoning", "think", "chat_template_kwargs"],
        Wire::Responses => &["reasoning"],
        Wire::AnthropicMessages => &["thinking", "output_config"],
    }
}

/// The top-level request keys a thinking level is sent under for `wire`/`format`
/// — the fields `drop_params` can strip after the body is built.
///
/// Every generated level lives under one top-level key per wire
/// (`reasoning_effort` for Chat Completions effort, `reasoning` for Responses,
/// `thinking` for Anthropic Messages) except an Anthropic *adaptive* effort,
/// which also sets `output_config`. The Chat Completions chat-template formats
/// (`chat_template_kwargs`) and an Anthropic `off` share their wire's single
/// key. Dropping any one key removes the whole level, so these are the keys to
/// check, not every key a variant may set.
fn request_field_keys(wire: Wire, format: Format) -> &'static [&'static str] {
    match wire {
        Wire::ChatCompletions => match format {
            Format::TemplateSwitch | Format::TemplateEffort => &["chat_template_kwargs"],
            Format::Effort => &["reasoning_effort"],
        },
        Wire::Responses => &["reasoning"],
        Wire::AnthropicMessages => &["thinking", "output_config"],
    }
}

/// Where the thinking level in effect came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `/thinking LEVEL` in this session.
    Session,
    /// `[providers.NAME.models."MODEL"] thinking`.
    Model,
    /// `[providers.NAME] thinking`.
    Provider,
    /// The top-level `thinking`.
    Global,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Session => "set for this session",
            Source::Model => "set for this model",
            Source::Provider => "set for this provider",
            Source::Global => "global setting",
        }
    }
}

/// The thinking level a model is sent, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    /// The setting that applied, before fitting it to the model.
    pub requested: Thinking,
    /// What is sent: `Default` sends nothing.
    pub effective: Thinking,
    pub source: Source,
    /// Levels the model supports (`"off"` included when it can be turned
    /// off); empty when nothing is known about the model.
    pub levels: Vec<String>,
    /// How the request carries the level.
    pub wire: Wire,
    /// For Anthropic Messages: adaptive effort or a fixed budget.
    pub anthropic: AnthropicStyle,
    /// For Chat Completions: the field that carries the level.
    pub format: Format,
    /// The `extra_body` key that carries a thinking setting for this wire, when
    /// the provider sets one. It is merged in last and owns the thinking
    /// control, so the generated field is suppressed to avoid sending two
    /// conflicting controls in the same payload.
    pub extra_body_override: Option<String>,
    /// `extra_body_override` suppressed the generated field, so `effective` is
    /// the configured level, not what the wire carries: the override's value
    /// (which may be a switch or a budget, not a level name) is sent instead.
    /// Status, ACP and the trajectory report no generated level then rather
    /// than `effective`, which never reaches the wire.
    pub overridden: bool,
    /// The provider's `drop_params` strips the generated thinking field after
    /// the body is built, so no level reaches the wire. Like `overridden`,
    /// status, ACP and the trajectory report no generated level then rather
    /// than `effective`.
    pub dropped: bool,
    /// A setting that is ignored or adjusted, worth telling the user about.
    pub warning: Option<String>,
}

impl Resolved {
    /// What to put in the request, if anything.
    pub fn request(&self) -> Option<Request> {
        // The provider's `extra_body` already carries a thinking control for
        // this wire and is merged in last, so it is the only field sent;
        // emitting the generated field too would ship two conflicting controls
        // (one of which `finish_body` may not even overwrite, e.g. a Chat
        // Completions `think` alongside the generated `reasoning_effort`, or an
        // Anthropic `thinking` alongside the generated `output_config`).
        if self.extra_body_override.is_some() {
            return None;
        }
        // `drop_params` strips the generated field after the body is built, so
        // emitting it would report a level the wire never carries.
        if self.dropped {
            return None;
        }
        match &self.effective {
            Thinking::Default => None,
            Thinking::Off => Some(match (self.wire, self.format) {
                (Wire::ChatCompletions, Format::TemplateSwitch | Format::TemplateEffort) => {
                    Request::TemplateSwitch(false)
                }
                _ => Request::Off,
            }),
            Thinking::Level(level) => Some(match (self.wire, self.anthropic, self.format) {
                (Wire::AnthropicMessages, AnthropicStyle::Budget, _) => Request::Budget(budget_tokens(level)),
                (Wire::ChatCompletions, _, Format::TemplateSwitch) => Request::TemplateSwitch(true),
                (Wire::ChatCompletions, _, Format::TemplateEffort) => Request::TemplateEffort(level.clone()),
                _ => Request::Effort(level.clone()),
            }),
        }
    }

    /// Whether Anthropic Messages is asked to think, which rules out a custom
    /// temperature there.
    pub fn anthropic_thinking_on(&self) -> bool {
        // A suppressed level sends no generated thinking control (the
        // `extra_body` override owns it), so our resolution is not what asks
        // Anthropic to think; the user's `extra_body` and temperature settings
        // stand on their own.
        if self.extra_body_override.is_some() || self.dropped || self.wire != Wire::AnthropicMessages {
            return false;
        }
        match &self.effective {
            Thinking::Level(_) => true,
            // A model whose known levels omit `off` always thinks (Fable,
            // Claude 5.5+); `Default` sends nothing, so the model still
            // thinks and a custom temperature is invalid.
            Thinking::Default => !self.levels.is_empty() && !self.levels.iter().any(|l| l == "off"),
            Thinking::Off => false,
        }
    }

    /// Whether the model thinks on Anthropic Messages even when the request
    /// sends no thinking field — the basis for the temperature rule of a
    /// request that omits one (e.g. compaction). Unlike
    /// [`Resolved::anthropic_thinking_on`], which reports what the resolved
    /// setting asks for, this is about the model itself: a configured level
    /// that is not sent does not stop a model that can turn thinking off.
    pub fn always_anthropic_thinking(&self) -> bool {
        if self.extra_body_override.is_some() || self.dropped || self.wire != Wire::AnthropicMessages {
            return false;
        }
        // A model whose known levels omit `off` always thinks (Fable, Claude
        // 5.5+); any other model thinks only when the request asks it to.
        !self.levels.is_empty() && !self.levels.iter().any(|l| l == "off")
    }

    /// One line for `/context`, e.g. `high (set for this model)`. An
    /// `extra_body` override sends its own value instead of `effective`, so
    /// that is reported as overriding the configured level, not as sending it.
    pub fn describe(&self) -> String {
        let mut text = format!("{} ({})", self.effective, self.source.label());
        if self.effective != self.requested {
            text.push_str(&format!(", {} requested", self.requested));
        }
        if self.overridden {
            text.push_str(", overridden by extra_body");
        }
        if self.dropped {
            text.push_str(", dropped by drop_params");
        }
        text
    }

    /// The levels `/thinking` can set for this model, for display.
    pub fn choices(&self) -> String {
        let mut all = vec!["default".to_string()];
        all.extend(self.levels.iter().cloned());
        all.join(", ")
    }
}

/// The level in `levels` nearest to `wanted`: the highest at or below it on
/// [`ORDER`], else the lowest above it. A name not on the scale matches only
/// itself.
fn nearest<'a>(levels: &'a [String], wanted: &str) -> Option<&'a String> {
    if let Some(exact) = levels.iter().find(|l| *l == wanted) {
        return Some(exact);
    }
    let rank = |l: &str| ORDER.iter().position(|o| *o == l);
    let wanted_rank = rank(wanted)?;
    let ranked: Vec<(usize, &String)> = levels.iter().filter_map(|l| rank(l).map(|r| (r, l))).collect();
    // A model that only switches thinking on: any named level turns it on.
    if ranked.is_empty() {
        return levels.iter().find(|l| *l == ON);
    }
    ranked
        .iter()
        .filter(|(r, _)| *r <= wanted_rank)
        .max_by_key(|(r, _)| *r)
        .or_else(|| ranked.iter().filter(|(r, _)| *r > wanted_rank).min_by_key(|(r, _)| *r))
        .map(|(_, l)| *l)
}

/// [`resolve_with`] for a model whose endpoint reports no levels.
#[cfg(test)]
pub fn resolve(
    global: &Thinking,
    session: Option<&Thinking>,
    kind: Option<ProviderKind>,
    provider: &ProviderConfig,
    model: &str,
) -> Resolved {
    resolve_with(global, session, kind, provider, model, None)
}

/// The thinking level for `model` on `provider` (the merged provider entry):
/// the session override, else the model's setting, else the provider's, else
/// `global`, fitted to the levels the model supports. Those come from
/// `thinking_levels` in the config, else what the endpoint `reported`, else
/// the built-in table.
pub fn resolve_with(
    global: &Thinking,
    session: Option<&Thinking>,
    kind: Option<ProviderKind>,
    provider: &ProviderConfig,
    model: &str,
    reported: Option<&Reported>,
) -> Resolved {
    let model_settings = provider.models.get(model);
    let (requested, source) = if let Some(t) = session {
        (t.clone(), Source::Session)
    } else if let Some(t) = model_settings.and_then(|m| m.thinking.clone()) {
        (t, Source::Model)
    } else if let Some(t) = provider.thinking.clone() {
        (t, Source::Provider)
    } else {
        (global.clone(), Source::Global)
    };
    let profile = builtin(model);
    let levels: Vec<String> = model_settings
        .and_then(|m| m.thinking_levels.clone())
        .or_else(|| provider.thinking_levels.clone())
        .map(|levels| levels.iter().map(|l| l.trim().to_ascii_lowercase()).collect())
        .or_else(|| reported.map(|r| r.levels.clone()))
        .or_else(|| profile.as_ref().map(|p| p.levels.clone()))
        .unwrap_or_default();
    let wire = wire(kind, model);
    // A Claude model the table doesn't know: assume the current (adaptive) API.
    // The endpoint saying "adaptive" wins over the table.
    let anthropic = if reported.is_some_and(|r| r.adaptive) {
        AnthropicStyle::Adaptive
    } else {
        profile.and_then(|p| p.anthropic).unwrap_or(AnthropicStyle::Adaptive)
    };
    let format = reported.map(|r| r.format).unwrap_or_default();
    // The global setting applies to every model, so a level that one model
    // can't take is not worth a warning; one set for it (or the session) is.
    let explicit = source != Source::Global;

    let (effective, mut warning) = match &requested {
        Thinking::Default => (Thinking::Default, None),
        _ if levels.is_empty() => (
            Thinking::Default,
            explicit.then(|| {
                format!(
                    "thinking {requested} ({}) is ignored: no thinking levels are known for {model}; \
                     list them with thinking_levels in its provider or model settings",
                    source.label()
                )
            }),
        ),
        Thinking::Off if levels.iter().any(|l| l == "off") => (Thinking::Off, None),
        Thinking::Off => {
            (Thinking::Default, explicit.then(|| format!("{model} can't turn thinking off; using the model default")))
        }
        Thinking::Level(level) => {
            let on: Vec<String> = levels.iter().filter(|l| *l != "off").cloned().collect();
            match nearest(&on, level) {
                Some(found) if found == level => (Thinking::Level(found.clone()), None),
                Some(found) if found == ON => (
                    Thinking::Level(found.clone()),
                    explicit.then(|| format!("{model} only switches thinking on or off; {level:?} turns it on")),
                ),
                Some(found) => (
                    Thinking::Level(found.clone()),
                    explicit.then(|| format!("{model} has no thinking level {level:?}; using {found:?}")),
                ),
                None => (
                    Thinking::Default,
                    explicit.then(|| {
                        format!(
                            "{model} has no thinking level {level:?} (it has: {}); using the model default",
                            levels.join(", ")
                        )
                    }),
                ),
            }
        }
    };

    let extra_body_override = if effective != Thinking::Default {
        provider
            .extra_body
            .as_ref()
            .and_then(|body| extra_body_keys(wire).iter().find(|k| body.contains_key(**k)))
            .map(|key| key.to_string())
    } else {
        None
    };
    if let Some(key) = &extra_body_override {
        warning = Some(format!(
            "the provider's extra_body sets {key:?}, which is sent instead of thinking {effective}; \
             remove it from extra_body to use the thinking setting"
        ));
    }
    let overridden = extra_body_override.is_some();
    // `finish_body` removes the provider's `drop_params` keys after the body is
    // built, so a generated thinking field under one of them never reaches the
    // wire — yet resolution would still report and log `effective` as sent.
    // Detect a dropped thinking field for this wire/format and report the level
    // as unsent instead. (The `extra_body` override already suppresses the
    // generated field, so there is nothing left to drop then.)
    let dropped_key = if effective != Thinking::Default && !overridden {
        provider
            .drop_params
            .as_ref()
            .and_then(|dropped| {
                request_field_keys(wire, format).iter().find(|k| dropped.iter().any(|d| d == **k))
            })
            .map(|key| key.to_string())
    } else {
        None
    };
    if let Some(key) = &dropped_key {
        warning = Some(format!(
            "the provider drops {key:?} (drop_params), so thinking {effective} is not sent; \
             remove it from drop_params to use the thinking setting"
        ));
    }
    let dropped = dropped_key.is_some();
    Resolved { requested, effective, source, levels, wire, anthropic, format, extra_body_override, overridden, dropped, warning }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn provider(toml_text: &str) -> ProviderConfig {
        toml::from_str(toml_text).unwrap()
    }

    fn level(l: &str) -> Thinking {
        Thinking::Level(l.into())
    }

    #[test]
    fn parses_and_round_trips() {
        assert_eq!("default".parse::<Thinking>(), Ok(Thinking::Default));
        assert_eq!(" Off ".parse::<Thinking>(), Ok(Thinking::Off));
        assert_eq!("HIGH".parse::<Thinking>(), Ok(level("high")));
        assert!("".parse::<Thinking>().is_err());
        assert!("very high!".parse::<Thinking>().is_err());

        let config: Config = toml::from_str("thinking = \"high\"").unwrap();
        assert_eq!(config.thinking, level("high"));
        assert_eq!(Config::default().thinking, Thinking::Default);
        assert!(toml::from_str::<Config>("thinking = 3").is_err());
        let text = toml::to_string(&Config { thinking: Thinking::Off, ..Default::default() }).unwrap();
        assert!(text.contains("thinking = \"off\""), "{text}");
    }

    #[test]
    fn knows_model_families() {
        let levels = |m: &str| builtin(m).map(|p| p.levels.join(","));
        let style = |m: &str| builtin(m).and_then(|p| p.anthropic);
        // Adaptive models, with and without an off switch.
        assert_eq!(levels("claude-fable-5-1").as_deref(), Some("low,medium,high,xhigh,max"));
        assert_eq!(levels("claude-opus-5-5").as_deref(), Some("low,medium,high,xhigh,max"));
        assert_eq!(levels("claude-sonnet-5").as_deref(), Some("off,low,medium,high,xhigh,max"));
        assert_eq!(levels("claude-opus-4.7").as_deref(), Some("off,low,medium,high,xhigh,max"));
        assert_eq!(levels("claude-sonnet-4-6").as_deref(), Some("off,low,medium,high,max"));
        assert_eq!(style("claude-sonnet-4-6"), Some(AnthropicStyle::Adaptive));
        // Fixed-budget models, including dated, dotted and vendor-prefixed ids.
        for m in [
            "claude-sonnet-4-5-20250929",
            "claude-sonnet-4.5",
            "anthropic/claude-opus-4.1",
            "anthropic.claude-sonnet-4-20250514-v1:0",
            "claude-haiku-4-5",
            "claude-3-7-sonnet-latest",
        ] {
            assert_eq!(style(m), Some(AnthropicStyle::Budget), "{m}");
            assert_eq!(levels(m).as_deref(), Some("off,low,medium,high"), "{m}");
        }
        // No extended thinking.
        assert_eq!(builtin("claude-3-5-sonnet-latest"), None);
        assert_eq!(builtin("claude-3-5-haiku"), None);
        // OpenAI reasoning models.
        assert_eq!(levels("gpt-5").as_deref(), Some("low,medium,high"));
        assert_eq!(levels("openai/gpt-5.6-sol").as_deref(), Some("low,medium,high"));
        assert_eq!(levels("o4-mini").as_deref(), Some("low,medium,high"));
        assert_eq!(builtin("gpt-4.1"), None);
        assert_eq!(builtin("llama3.3"), None);
        assert_eq!(builtin("omni-moderation"), None);
    }

    #[test]
    fn most_specific_setting_wins() {
        let p = provider(
            r#"
            kind = "openai"
            thinking = "low"
            [models."gpt-5"]
            thinking = "high"
            "#,
        );
        let kind = Some(ProviderKind::Openai);
        let global = level("medium");
        let r = resolve(&global, None, kind, &p, "gpt-5");
        assert_eq!((r.effective.clone(), r.source), (level("high"), Source::Model));
        assert_eq!(r.request(), Some(Request::Effort("high".into())));
        let r = resolve(&global, None, kind, &p, "gpt-5.1");
        assert_eq!((r.effective, r.source), (level("low"), Source::Provider));
        let r = resolve(&global, None, kind, &ProviderConfig::default(), "gpt-5");
        assert_eq!((r.effective, r.source), (level("medium"), Source::Global));
        // The session override beats everything.
        let r = resolve(&global, Some(&Thinking::Default), kind, &p, "gpt-5");
        assert_eq!((r.effective.clone(), r.source), (Thinking::Default, Source::Session));
        assert_eq!(r.request(), None);
    }

    #[test]
    fn fits_the_level_to_the_model() {
        let none = ProviderConfig::default();
        let anthropic = Some(ProviderKind::Anthropic);
        // xhigh on Sonnet 4.6 (no xhigh) runs as high, with a warning.
        let r = resolve(&Thinking::Default, Some(&level("xhigh")), anthropic, &none, "claude-sonnet-4-6");
        assert_eq!(r.effective, level("high"));
        assert!(r.warning.as_deref().unwrap().contains("using \"high\""), "{:?}", r.warning);
        assert!(r.describe().contains("xhigh requested"), "{}", r.describe());
        // Below the lowest level: the lowest one.
        let r = resolve(&Thinking::Default, Some(&level("minimal")), anthropic, &none, "claude-opus-5-5");
        assert_eq!(r.effective, level("low"));
        // Off where the model can't: the model default.
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &none, "claude-fable-5-1");
        assert_eq!(r.effective, Thinking::Default);
        assert!(r.warning.unwrap().contains("can't turn thinking off"));
        // Off where it can.
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &none, "claude-sonnet-4-5");
        assert_eq!(r.request(), Some(Request::Off));
        // A model with no known levels sends nothing; only an explicit
        // setting warns, not the global one.
        let r = resolve(&level("high"), None, Some(ProviderKind::Openai), &none, "llama3.3");
        assert_eq!((r.effective, r.warning), (Thinking::Default, None));
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &none, "llama3.3");
        assert_eq!(r.effective, Thinking::Default);
        assert!(r.warning.unwrap().contains("thinking_levels"));
        // A global level a model lacks is fitted silently.
        let r = resolve(&level("max"), None, Some(ProviderKind::Openai), &none, "gpt-5");
        assert_eq!((r.effective, r.warning), (level("high"), None));
    }

    #[test]
    fn config_levels_override_the_table() {
        let p = provider(
            r#"
            thinking_levels = ["low", "high"]
            [models."qwen3"]
            thinking_levels = ["off", "on"]
            "#,
        );
        let kind = Some(ProviderKind::Openai);
        let r = resolve(&Thinking::Default, Some(&level("medium")), kind, &p, "kimi-k3");
        assert_eq!(r.effective, level("low"));
        assert_eq!(r.choices(), "default, low, high");
        // `on` (an on/off-only model) is chosen by any named level.
        let r = resolve(&Thinking::Default, Some(&level("on")), kind, &p, "qwen3");
        assert_eq!(r.request(), Some(Request::Effort("on".into())));
        let r = resolve(&Thinking::Default, Some(&level("high")), kind, &p, "qwen3");
        assert_eq!(r.effective, level("on"));
        // A custom level name matches only itself.
        let p = provider(r#"thinking_levels = ["fast", "deep"]"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), kind, &p, "x");
        assert_eq!(r.effective, Thinking::Default);
        assert!(r.warning.unwrap().contains("it has: fast, deep"));
        let r = resolve(&Thinking::Default, Some(&level("deep")), kind, &p, "x");
        assert_eq!(r.request(), Some(Request::Effort("deep".into())));
    }

    #[test]
    fn picks_the_request_form_for_the_api() {
        let none = ProviderConfig::default();
        let high = level("high");
        let anthropic = Some(ProviderKind::Anthropic);
        let copilot = Some(ProviderKind::GithubCopilot);
        // Anthropic: adaptive effort on new models, a budget on older ones.
        let r = resolve(&Thinking::Default, Some(&high), anthropic, &none, "claude-opus-4-7");
        assert_eq!(r.request(), Some(Request::Effort("high".into())));
        assert!(r.anthropic_thinking_on());
        let r = resolve(&Thinking::Default, Some(&high), anthropic, &none, "claude-sonnet-4-5");
        assert_eq!(r.request(), Some(Request::Budget(16384)));
        // Copilot routes by model: Claude 4.x to Messages, GPT-5 to Responses.
        let r = resolve(&Thinking::Default, Some(&high), copilot, &none, "claude-sonnet-4.5");
        assert_eq!((r.wire, r.request()), (Wire::AnthropicMessages, Some(Request::Budget(16384))));
        let r = resolve(&Thinking::Default, Some(&high), copilot, &none, "gpt-5.6-sol");
        assert_eq!((r.wire, r.request()), (Wire::Responses, Some(Request::Effort("high".into()))));
        assert!(!r.anthropic_thinking_on());
        // A Claude model on an OpenAI-compatible endpoint takes an effort name.
        let r =
            resolve(&Thinking::Default, Some(&high), Some(ProviderKind::Openai), &none, "anthropic/claude-sonnet-4.5");
        assert_eq!((r.wire, r.request()), (Wire::ChatCompletions, Some(Request::Effort("high".into()))));
    }

    #[test]
    fn warns_when_extra_body_sets_the_same_field() {
        let p = provider("extra_body = { reasoning_effort = \"low\" }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.warning.unwrap().contains("\"reasoning_effort\""));
        // An extra_body field for another API is not a conflict.
        let p = provider("extra_body = { thinking = { type = \"enabled\" } }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert_eq!(r.warning, None);
        // Nor is anything when no level is sent.
        let p = provider("extra_body = { reasoning_effort = \"low\" }");
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Openai), &p, "gpt-5");
        assert_eq!(r.warning, None);
    }

    #[test]
    fn extra_body_override_suppresses_the_generated_field() {
        // Chat Completions emits `reasoning_effort`, but the override carries
        // `think`, which `finish_body` would NOT overwrite — so the generated
        // field must be suppressed to avoid shipping both controls at once.
        let p = provider("extra_body = { think = true }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.warning.is_some());
        assert_eq!(r.request(), None, "generated reasoning_effort must be suppressed");
        assert_eq!(r.extra_body_override.as_deref(), Some("think"));

        // Anthropic effort emits both `thinking` and `output_config`; an
        // override on `thinking` alone would leave `output_config` behind, so
        // suppress the generated control entirely and drop the thinking-on
        // temperature lock (the override owns the thinking decision now).
        let p = provider("extra_body = { thinking = { type = \"enabled\" } }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-5.5");
        assert!(r.warning.is_some());
        assert_eq!(r.request(), None, "generated thinking/output_config must be suppressed");
        assert!(!r.anthropic_thinking_on(), "a suppressed level does not lock Anthropic temperature");
    }

    #[test]
    fn drop_params_suppresses_the_generated_field() {
        // `finish_body` removes `drop_params` keys after the body is built, so a
        // generated thinking field under one of them never reaches the wire.
        // Resolution must report it as dropped, not sent.
        // Chat Completions effort: `reasoning_effort`.
        let p = provider("drop_params = [\"reasoning_effort\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.dropped);
        assert_eq!(r.request(), None, "a dropped reasoning_effort is not emitted");
        assert!(r.describe().contains("dropped by drop_params"), "{}", r.describe());
        let warning = r.warning.unwrap();
        assert!(warning.contains("reasoning_effort") && warning.contains("drop_params"), "{warning}");

        // Responses: `reasoning`.
        let p = provider("drop_params = [\"reasoning\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::GithubCopilot), &p, "gpt-5.6-sol");
        assert_eq!(r.wire, Wire::Responses);
        assert!(r.dropped);
        assert_eq!(r.request(), None);

        // Anthropic adaptive effort sets `thinking` + `output_config`; dropping
        // either removes the level, and a dropped level does not lock the
        // temperature (the request sends no thinking field).
        for key in ["thinking", "output_config"] {
            let p = provider(&format!("drop_params = [\"{key}\"]"));
            let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-5.5");
            assert!(r.dropped, "{key}");
            assert_eq!(r.request(), None, "{key}");
            assert!(!r.anthropic_thinking_on(), "{key}: a dropped level does not lock the temperature");
        }

        // A drop_params key for another wire does not suppress the field.
        let p = provider("drop_params = [\"reasoning\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-5.5");
        assert!(!r.dropped);
        assert!(r.request().is_some(), "reasoning is not an Anthropic Messages field");

        // Nothing is sent for `Default`, so there is no field to drop.
        let p = provider("drop_params = [\"reasoning_effort\"]");
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(!r.dropped);
        assert_eq!(r.warning, None);

        // An extra_body override already suppresses the generated field, so
        // drop_params has nothing to drop and the override warning stands.
        let p = provider("drop_params = [\"reasoning_effort\"]\nextra_body = { think = true }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.overridden);
        assert!(!r.dropped);
        assert!(r.warning.unwrap().contains("extra_body"));
    }

    #[test]
    fn default_on_an_always_thinking_model_still_locks_the_temperature() {
        let none = ProviderConfig::default();
        let anthropic = Some(ProviderKind::Anthropic);
        // Models whose known levels omit `off` always think (Fable, Claude
        // 5.5+): `Default` sends nothing, so the model still thinks and a
        // custom temperature is invalid.
        for model in ["claude-fable-5", "claude-sonnet-5.5", "claude-opus-5.5"] {
            let r = resolve(&Thinking::Default, None, anthropic, &none, model);
            assert_eq!(r.effective, Thinking::Default, "{model}");
            assert!(r.anthropic_thinking_on(), "{model} with the default setting still thinks");
        }
        // A model that can turn thinking off does not lock on `Default`.
        let r = resolve(&Thinking::Default, None, anthropic, &none, "claude-sonnet-4-6");
        assert!(!r.anthropic_thinking_on(), "a model with an off level thinks only when asked");
        // Nothing known about the model: `Default` is not treated as thinking.
        let r = resolve(&Thinking::Default, None, anthropic, &none, "some-unknown-model");
        assert!(r.levels.is_empty());
        assert!(!r.anthropic_thinking_on());
        // An explicit level still locks, `off` still cannot be sent to an
        // always-thinking model (it has no `off` level, so it falls back to
        // the default — which thinks).
        let r = resolve(&Thinking::Default, Some(&level("low")), anthropic, &none, "claude-fable-5");
        assert!(r.anthropic_thinking_on());
        let r = resolve(&Thinking::Off, None, anthropic, &none, "claude-fable-5");
        assert_eq!(r.effective, Thinking::Default, "off is not in the profile, so it falls back to default");
        assert!(r.anthropic_thinking_on(), "an unsendable off still leaves the model thinking");
    }

    #[test]
    fn extra_body_override_is_reported_as_overriding_not_sent() {
        // The configured level never reaches the wire (the override owns the
        // thinking control), so it is flagged as overridden and reported as
        // such, not as the level sent.
        let p = provider("extra_body = { reasoning_effort = \"low\" }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.overridden, "extra_body override must flag the resolution");
        assert_eq!(r.effective, level("high"), "the configured level is unchanged");
        assert_eq!(r.request(), None, "no generated field is sent");
        assert!(r.describe().contains("overridden by extra_body"), "{}", r.describe());

        // No override: the level is sent and reported normally.
        let none = ProviderConfig::default();
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &none, "gpt-5");
        assert!(!r.overridden);
        assert!(!r.describe().contains("overridden"), "{}", r.describe());
    }

    #[test]
    fn reads_levels_from_a_model_list_entry() {
        let entry = serde_json::json!({ "id": "gpt-5.4", "capabilities": { "supports": {
            "reasoning_effort": ["none", "low", "medium", "high", "xhigh"], "tool_calls": true } } });
        let reported = Reported::from_model_entry(&entry).unwrap();
        assert_eq!(reported.levels, ["off", "low", "medium", "high", "xhigh"]);
        assert!(!reported.adaptive);
        let none = serde_json::json!({ "id": "gpt-4o", "capabilities": { "supports": { "tool_calls": true } } });
        assert_eq!(Reported::from_model_entry(&none), None);
        let empty = serde_json::json!({ "capabilities": { "supports": { "reasoning_effort": [] } } });
        assert_eq!(Reported::from_model_entry(&empty), None);

        // Reported levels beat the table (gpt-5 has no xhigh there) …
        let copilot = Some(ProviderKind::GithubCopilot);
        let none_cfg = ProviderConfig::default();
        let r = resolve_with(&Thinking::Default, Some(&level("xhigh")), copilot, &none_cfg, "gpt-5.4", Some(&reported));
        assert_eq!((r.effective, r.warning), (level("xhigh"), None));
        let r = resolve_with(&Thinking::Default, Some(&Thinking::Off), copilot, &none_cfg, "gpt-5.4", Some(&reported));
        assert_eq!(r.request(), Some(Request::Off));
        // … and cover models the table doesn't know.
        let kimi = Reported {
            levels: vec!["low".into(), "high".into(), "max".into()],
            adaptive: false,
            format: Format::Effort,
        };
        let r = resolve_with(&Thinking::Default, Some(&level("medium")), copilot, &none_cfg, "kimi-k3", Some(&kimi));
        assert_eq!(r.effective, level("low"));
        // Config levels still win.
        let p = provider("thinking_levels = [\"high\"]");
        let r = resolve_with(&Thinking::Default, Some(&level("low")), copilot, &p, "gpt-5.4", Some(&reported));
        assert_eq!(r.effective, level("high"));
        // An adaptive report switches an old-table Claude to effort.
        let adaptive = Reported { levels: vec!["low".into(), "high".into()], adaptive: true, format: Format::Effort };
        let r = resolve_with(
            &Thinking::Default,
            Some(&level("high")),
            copilot,
            &none_cfg,
            "claude-sonnet-4.5",
            Some(&adaptive),
        );
        assert_eq!(r.request(), Some(Request::Effort("high".into())));
    }

    #[test]
    fn reads_levels_from_ollama_and_llama_cpp() {
        let show = serde_json::json!({ "capabilities": ["completion", "tools", "thinking"] });
        let ollama = Reported::from_ollama_show(&show).unwrap();
        assert_eq!(ollama.levels, ["off", "low", "medium", "high"]);
        assert_eq!(ollama.format, Format::Effort);
        // Ollama rejects a level for a model that can't think: report none.
        assert_eq!(Reported::from_ollama_show(&serde_json::json!({ "capabilities": ["completion"] })), None);

        let qwen =
            serde_json::json!({ "chat_template": "{%- if enable_thinking is defined and enable_thinking is false %}" });
        let switch = Reported::from_llamacpp_props(&qwen).unwrap();
        assert_eq!(switch.levels, ["off", "on"]);
        assert_eq!(switch.format, Format::TemplateSwitch);
        let oss = serde_json::json!({ "chat_template": "Reasoning: {{ reasoning_effort }}" });
        let effort = Reported::from_llamacpp_props(&oss).unwrap();
        assert_eq!(effort.levels, ["low", "medium", "high"]);
        assert_eq!(effort.format, Format::TemplateEffort);
        assert_eq!(Reported::from_llamacpp_props(&serde_json::json!({ "chat_template": "{{ messages }}" })), None);

        let openai = Some(ProviderKind::Openai);
        let none_cfg = ProviderConfig::default();
        let resolve = |level: &Thinking, reported: &Reported| {
            resolve_with(&Thinking::Default, Some(level), openai, &none_cfg, "qwen3", Some(reported))
        };
        // On/off templates: off switches it off, any named level turns it on.
        assert_eq!(resolve(&Thinking::Off, &switch).request(), Some(Request::TemplateSwitch(false)));
        let r = resolve(&level("high"), &switch);
        assert_eq!((r.effective.clone(), r.request()), (level(ON), Some(Request::TemplateSwitch(true))));
        assert_eq!(r.warning.as_deref(), Some("qwen3 only switches thinking on or off; \"high\" turns it on"));
        assert_eq!(resolve(&level(ON), &switch).warning, None);
        assert_eq!(resolve(&Thinking::Default, &switch).request(), None);
        // Level templates get the level as a template variable.
        assert_eq!(resolve(&level("medium"), &effort).request(), Some(Request::TemplateEffort("medium".into())));
        // Ollama: plain `reasoning_effort`.
        assert_eq!(resolve(&Thinking::Off, &ollama).request(), Some(Request::Off));
        assert_eq!(resolve(&level("low"), &ollama).request(), Some(Request::Effort("low".into())));
    }

    #[test]
    fn caps_budgets_below_max_tokens() {
        assert_eq!(capped_budget(16384, 32000), Some(16384));
        assert_eq!(capped_budget(16384, 4096), Some(4095));
        assert_eq!(capped_budget(2048, 1024), None);
    }
}
