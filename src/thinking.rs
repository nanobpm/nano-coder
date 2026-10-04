//! Thinking level: how much the model reasons before it answers. `"default"`
//! sends nothing (the model decides), `"off"` turns thinking off where the
//! model allows it, and a level (`"low"`, `"medium"`, `"high"`, `"xhigh"`,
//! `"max"`, …) asks for that much. Set globally, per provider
//! (`[providers.NAME]`) and per model (`[providers.NAME.models."MODEL"]`); the
//! most specific setting wins, and `/thinking LEVEL` overrides all of them for
//! the session.
//!
//! Only levels the model supports can be sent. They come from a
//! `thinking_levels` list in the config (model, then provider), else what the
//! endpoint reports (Copilot, Ollama, and llama.cpp capability data), else a
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
    /// Anthropic adaptive thinking with only its enable half,
    /// `thinking = { type = "adaptive" }` — emitted when the provider's
    /// `extra_body.output_config.effort` overrides the effort value. The
    /// override owns `output_config` (deep-merged in by `finish_body`), but
    /// adaptive thinking still requires the `thinking` control to reach the
    /// wire; emitting the full [`Request::Effort`] would have `request()`
    /// suppress it and drop this required half.
    AdaptiveOn,
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
        "max" => 65536,
        // A custom `thinking_levels` name is not on the standard scale, so it
        // has no meaningful budget mapping. Mapping it to the maximum (65,536)
        // would silently send the largest, most expensive budget for an
        // unrecognized name; use the `high` budget as a conservative ceiling
        // instead. (`resolve_with` fits a requested level to the model's known
        // levels, so an unranked name only reaches here when the user
        // explicitly configured it for a Budget-style model.)
        _ => 16384,
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
    // The raw OpenAI `/v1/models` list reports no `reasoning_effort`
    // capabilities (unlike Copilot/Ollama/llama.cpp, which `Reported` reads
    // live), so this table is the only fallback there. The accepted levels
    // differ by variant: GPT-5 (and `-mini`/`-nano`) take `minimal`; GPT-5.1
    // replaced `minimal` with `none` (sent as `off`). A level the endpoint
    // rejects is refused by the API, so failing closed to the documented set
    // per variant avoids sending an unsupported effort.
    if let Some((major, minor)) = id.strip_prefix("gpt-").and_then(gpt_version) {
        // `gpt-5-chat-latest` is the non-reasoning chat model: it takes no
        // `reasoning_effort` at all, so it has no thinking levels.
        if id.contains("chat") {
            return None;
        }
        if major == 5 && minor == 0 {
            return Some(Profile::new(&["minimal", "low", "medium", "high"], None));
        }
        if major >= 5 {
            // GPT-5.1 and later: `none` (off) in place of `minimal`.
            return Some(Profile::new(&["off", "low", "medium", "high"], None));
        }
    }
    // `o1-mini` (and its snapshots) always reason and reject the
    // `reasoning_effort` parameter, so the broad o1/o3/o4 family fallback must
    // not offer it adjustable levels.
    if id == "o1-mini" || id.starts_with("o1-mini-") {
        return None;
    }
    if ["o1", "o3", "o4"].iter().any(|p| id == *p || id.starts_with(&format!("{p}-"))) {
        return Some(Profile::new(&["low", "medium", "high"], None));
    }
    None
}

/// `(major, minor)` of a `gpt-<major>[.<minor>]` id once the `gpt-` prefix is
/// stripped: `5` → `(5, 0)`, `5.1` → `(5, 1)`, `5-mini` → `(5, 0)`,
/// `5.1-codex` → `(5, 1)`. A `-` separates a variant name, not a version, so
/// only a `.` introduces the minor. `None` when no leading number is present.
fn gpt_version(rest: &str) -> Option<(u32, u32)> {
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let major: u32 = rest[..digits].parse().ok()?;
    let minor = rest[digits..]
        .strip_prefix('.')
        .map(|tail| tail.chars().take_while(char::is_ascii_digit).collect::<String>())
        .and_then(|d| d.parse::<u32>().ok())
        .unwrap_or(0);
    Some((major, minor))
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

/// Whether an Anthropic `extra_body` thinking control (`thinking` or
/// `output_config`) leaves the model thinking. A present control is assumed to
/// think unless it *explicitly* turns thinking off — a `type`/`effort` field
/// (or the value itself) of `disabled`, `none`, `off`, or `false`. Locking the
/// temperature for anything else (an enabled/adaptive control, a raw budget)
/// avoids sending a custom temperature into a thinking request, which Anthropic
/// rejects.
fn anthropic_extra_body_thinks(key: &str, value: &toml::Value) -> Option<bool> {
    fn is_off(s: &str) -> bool {
        matches!(s.trim().to_ascii_lowercase().as_str(), "disabled" | "off" | "none" | "false")
    }
    fn enables(value: &toml::Value) -> bool {
        match value {
            toml::Value::Boolean(b) => *b,
            toml::Value::String(s) => !is_off(s),
            _ => true,
        }
    }
    // `output_config` is an Anthropic thinking control only through its
    // `effort` field; other fields (e.g. `format` for structured outputs) are
    // unrelated and must not affect the thinking/temperature state. `None`
    // here means "not a thinking control", so the caller keeps looking.
    if key == "output_config" {
        return match value {
            toml::Value::Table(t) => t.get("effort").map(enables),
            _ => None,
        };
    }
    // The `thinking` control: a bare boolean/string, or a table whose `type`
    // or `effort` may explicitly disable it.
    Some(match value {
        toml::Value::Table(t) => {
            !["type", "effort"].iter().any(|k| t.get(*k).and_then(|v| v.as_str()).is_some_and(is_off))
        }
        other => enables(other),
    })
}

/// The generated thinking control's `(top-level key, nested field)` for a
/// non-Anthropic wire whose control is written into a *nested* object
/// (`reasoning.effort` on Responses, `chat_template_kwargs`'s `enable_thinking`
/// or `reasoning_effort` on llama.cpp, by format). `None` when the control is a
/// top-level scalar (`reasoning_effort` on Chat Completions), where presence of
/// the key is itself the override. Must track the fields `build_body` emits in
/// each provider so the override check matches what actually reaches the wire.
fn generated_nested_field(wire: Wire, format: Format) -> Option<(&'static str, &'static str)> {
    match (wire, format) {
        (Wire::Responses, _) => Some(("reasoning", "effort")),
        (Wire::ChatCompletions, Format::TemplateSwitch) => Some(("chat_template_kwargs", "enable_thinking")),
        (Wire::ChatCompletions, Format::TemplateEffort) => Some(("chat_template_kwargs", "reasoning_effort")),
        _ => None,
    }
}

/// For a non-Anthropic wire, whether an `extra_body` key actually displaces the
/// generated thinking control, as opposed to an unrelated sibling that
/// `finish_body` merges alongside it. When the generated control lives in a
/// nested object (see [`generated_nested_field`]), an `extra_body` object under
/// that key overrides only if it carries the generated field; an object that
/// sets only other fields coexists with the generated control. A non-object
/// value (it replaces the control wholesale) and any key that is not the
/// generated control's key override on presence, as before.
fn extra_body_overrides_generated(key: &str, wire: Wire, format: Format, value: Option<&toml::Value>) -> bool {
    match generated_nested_field(wire, format) {
        Some((nested_key, field)) if nested_key == key => match value {
            Some(toml::Value::Table(t)) => t.contains_key(field),
            _ => true,
        },
        _ => true,
    }
}

/// The generated thinking control for `effective` on `wire`/`anthropic`/`format`,
/// or `None` when nothing is sent (`Thinking::Default`). This is the single
/// source of truth for which [`Request`] a level maps to; both [`Resolved::request`]
/// (after the override/`drop_params` gates) and the `drop_params` field-key check
/// derive from it, so the keys checked always match the variant actually emitted.
fn generated_request(effective: &Thinking, wire: Wire, anthropic: AnthropicStyle, format: Format) -> Option<Request> {
    match effective {
        Thinking::Default => None,
        Thinking::Off => Some(match (wire, format) {
            (Wire::ChatCompletions, Format::TemplateSwitch) => Request::TemplateSwitch(false),
            // A `reasoning_effort` template was selected because it consumes
            // that variable, so an `enable_thinking` switch would be ignored:
            // turn thinking off the way the template reads it.
            (Wire::ChatCompletions, Format::TemplateEffort) => Request::TemplateEffort("none".into()),
            _ => Request::Off,
        }),
        Thinking::Level(level) => Some(match (wire, anthropic, format) {
            (Wire::AnthropicMessages, AnthropicStyle::Budget, _) => Request::Budget(budget_tokens(level)),
            (Wire::ChatCompletions, _, Format::TemplateSwitch) => Request::TemplateSwitch(true),
            (Wire::ChatCompletions, _, Format::TemplateEffort) => Request::TemplateEffort(level.clone()),
            _ => Request::Effort(level.clone()),
        }),
    }
}

/// The top-level request keys a generated thinking `request` is sent under on
/// `wire` — the fields `drop_params` can strip after the body is built.
///
/// Every generated level lives under one top-level key per wire
/// (`reasoning_effort` for Chat Completions effort/off, `reasoning` for
/// Responses, `thinking` for Anthropic Messages) except an Anthropic *adaptive*
/// effort ([`Request::Effort`] on Anthropic Messages), which also sets
/// `output_config`. A Budget-style level ([`Request::Budget`]) and an Anthropic
/// `off` ([`Request::Off`]) set only `thinking`, so listing `output_config` for
/// them would wrongly report a drop that `finish_body` never makes. The Chat
/// Completions chat-template formats (`chat_template_kwargs`) share their wire's
/// single key. Dropping any one listed key removes the whole level, so these are
/// the keys to check, not every key a variant may set.
fn request_field_keys(wire: Wire, request: &Request) -> &'static [&'static str] {
    match (wire, request) {
        (Wire::ChatCompletions, Request::TemplateSwitch(_) | Request::TemplateEffort(_)) => &["chat_template_kwargs"],
        (Wire::ChatCompletions, _) => &["reasoning_effort"],
        (Wire::Responses, _) => &["reasoning"],
        // Only an Anthropic adaptive effort also emits `output_config`; Budget
        // and `off` emit `thinking` alone.
        (Wire::AnthropicMessages, Request::Effort(_)) => &["thinking", "output_config"],
        (Wire::AnthropicMessages, _) => &["thinking"],
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
    /// For Anthropic Messages, whether an `extra_body` thinking control that
    /// reaches the wire (present and not dropped) leaves the model thinking.
    /// `Some` only when such a control is configured; it decides the
    /// temperature lock on its own — the control's value, not the generated
    /// level, is what the model sees — even when no thinking level is requested.
    pub extra_body_thinking_on: Option<bool>,
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
        // `drop_params` strips the generated thinking field after the body is
        // built, so nothing we emit here reaches the wire — not even the
        // `thinking` half preserved for an `output_config.effort` override
        // below, whose bare effort is no complete control on its own.
        if self.dropped {
            return None;
        }
        // The provider's `extra_body` already carries a thinking control for
        // this wire and is merged in last, so it is the only field sent;
        // emitting the generated field too would ship two conflicting controls
        // (one of which `finish_body` may not even overwrite, e.g. a Chat
        // Completions `think` alongside the generated `reasoning_effort`, or an
        // Anthropic `thinking` alongside the generated `output_config`).
        if let Some(key) = &self.extra_body_override {
            // An `output_config.effort` override on an Anthropic *adaptive*
            // model is only a field-level override: it owns the effort value
            // (deep-merged into `output_config` by `finish_body`) but never the
            // `thinking` half, which is a separate top-level key. Suppressing
            // the whole generated control would drop that required half, so
            // emit it and let the override own only `output_config`:
            // - a requested *level* still needs `thinking = { type = "adaptive"
            //   }` for the override's effort to take effect — but only when the
            //   effort *enables* thinking (`extra_body_thinking_on == Some(true)`).
            //   A *disabling* effort (`effort = "none"`) must not emit it: that
            //   would re-enable thinking the override turned off.
            // - a requested `off` still needs its `thinking = { type =
            //   "disabled" }` disable control, or an enabling effort override
            //   would silently turn thinking on against the explicit `off`.
            // Every other override owns the whole control, so the generated
            // field stays suppressed.
            if key == "output_config"
                && self.wire == Wire::AnthropicMessages
                && self.anthropic == AnthropicStyle::Adaptive
            {
                match &self.effective {
                    Thinking::Level(_) if self.extra_body_thinking_on == Some(true) => {
                        return Some(Request::AdaptiveOn);
                    }
                    Thinking::Off => return Some(Request::Off),
                    _ => {}
                }
            }
            return None;
        }
        generated_request(&self.effective, self.wire, self.anthropic, self.format)
    }

    /// Whether Anthropic Messages is asked to think, which rules out a custom
    /// temperature there.
    pub fn anthropic_thinking_on(&self) -> bool {
        // A model that always thinks (Fable, Claude 5.5+) locks the
        // temperature even when no generated field reaches the wire (it was
        // dropped or overridden): the model still thinks, so a custom
        // temperature is invalid.
        if self.model_always_thinks() {
            return true;
        }
        // An `extra_body` control that enables thinking locks the temperature
        // on its own — its value, not the generated level, is what the model
        // sees — but only when the emitted control actually leaves thinking
        // on: an `output_config.effort` override coexisting with a preserved
        // `thinking = { type = "disabled" }` ([`Request::Off`]) loses to that
        // disable control, so the request does not think and a configured
        // temperature stays valid. The same holds when `drop_params` strips
        // that preserved half (`dropped`): `request()` then emits nothing and
        // only the bare effort reaches the wire, which is no complete control
        // — the requested `off` is not sent, so it cannot lock the
        // temperature either.
        if self.extra_body_enables_thinking() && self.request() != Some(Request::Off) && !self.dropped {
            return true;
        }
        // Otherwise the request thinks only when we actually emit a thinking-on
        // field: a dropped or overridden generated field never reaches the
        // wire, and an off-capable model thinks only when explicitly asked.
        if self.extra_body_override.is_some() || self.dropped || self.wire != Wire::AnthropicMessages {
            return false;
        }
        matches!(&self.effective, Thinking::Level(_))
    }

    /// Whether the model thinks on Anthropic Messages with no generated
    /// thinking field in the request: a model whose known levels omit `off`
    /// (Fable, Claude 5.5+). Empty levels mean nothing is known, so we do not
    /// assume it thinks.
    fn model_always_thinks(&self) -> bool {
        self.wire == Wire::AnthropicMessages && !self.levels.is_empty() && !self.levels.iter().any(|l| l == "off")
    }

    /// Whether an `extra_body` thinking control explicitly enables thinking on
    /// Anthropic Messages. Only such an enabling control locks the temperature;
    /// one that explicitly disables thinking leaves a custom temperature valid.
    fn extra_body_enables_thinking(&self) -> bool {
        self.extra_body_thinking_on == Some(true)
    }

    /// Whether the model thinks on Anthropic Messages even when the request
    /// sends no thinking field — the basis for the temperature rule of a
    /// request that omits one (e.g. compaction). Unlike
    /// [`Resolved::anthropic_thinking_on`], which reports what the resolved
    /// setting asks for, this is about the model itself: a configured level
    /// that is not sent does not stop a model that can turn thinking off.
    pub fn always_anthropic_thinking(&self) -> bool {
        if self.wire != Wire::AnthropicMessages {
            return false;
        }
        // The model's always-thinking property is intrinsic: dropping or
        // overriding the generated field cannot stop a no-`off` model from
        // thinking, and an `extra_body` control that enables thinking (merged
        // into every request, compaction included) keeps it on even when no
        // generated field is sent.
        self.model_always_thinks() || self.extra_body_enables_thinking()
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
    let ranked: Vec<(usize, &String)> = levels.iter().filter_map(|l| rank(l).map(|r| (r, l))).collect();
    // A model that only switches thinking on: any named level turns it on. This
    // must precede the `wanted` rank lookup below — an on/off-only model has no
    // ranked levels, so a custom name outside `ORDER` (e.g. `/thinking deep`)
    // must still turn it on rather than fall through to the model default.
    if ranked.is_empty() {
        return levels.iter().find(|l| *l == ON);
    }
    let wanted_rank = rank(wanted)?;
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
    // Configured `thinking_levels` win over the endpoint and the table, so an
    // entry that can't even parse as a level name (e.g. "very high") would
    // break the `/settings` editor, which parses each offered candidate.
    // Drop invalid names here and say so once, rather than letting an
    // accepted config fail later. Entries keep the spelling the wire expects
    // (GPT-5.1 takes "none", an on/off template takes "on"), but the `off`
    // aliases `Thinking` also accepts ("none", "disabled") are rejected in
    // favor of the internal "off" spelling — as the reported-level path
    // already normalizes — so the `levels.contains("off")` check below agrees
    // with a `thinking = "none"` setting, which parses to `Thinking::Off`.
    let mut invalid_levels: Vec<String> = Vec::new();
    let mut alias_levels: Vec<String> = Vec::new();
    let mut reserved_levels: Vec<String> = Vec::new();
    let levels: Vec<String> = model_settings
        .and_then(|m| m.thinking_levels.clone())
        .or_else(|| provider.thinking_levels.clone())
        .map(|levels| {
            levels
                .iter()
                .map(|l| l.trim().to_ascii_lowercase())
                .filter_map(|l| match l.parse::<Thinking>() {
                    // The same grammar `Thinking` parses: a name that fails it
                    // (e.g. "very high") is no usable level.
                    Ok(Thinking::Off) if l != "off" => {
                        alias_levels.push(l);
                        None
                    }
                    // "default"/"auto"/"model default" all parse to the model
                    // default, which is always offered separately (never a
                    // selectable level). Keeping one yields a nonempty profile
                    // with no `off`, which on Anthropic wrongly locks the
                    // temperature (`model_always_thinks`) and shows a duplicate
                    // default in `/settings` — reject them like the off aliases.
                    Ok(Thinking::Default) => {
                        reserved_levels.push(l);
                        None
                    }
                    Ok(_) => Some(l),
                    Err(_) => {
                        invalid_levels.push(l);
                        None
                    }
                })
                .collect()
        })
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

    let extra_body_override = if requested != Thinking::Default {
        provider
            .extra_body
            .as_ref()
            .and_then(|body| {
                extra_body_keys(wire).iter().find(|k| {
                    // A key `finish_body` strips via `drop_params` never reaches
                    // the wire, so it is no override at all — treating it as one
                    // would claim a control is sent that was removed. Let the
                    // generated-field drop logic below report the real outcome.
                    let present = body.contains_key(**k)
                        && !provider.drop_params.as_ref().is_some_and(|d| d.iter().any(|p| p == **k));
                    // A key overrides the generated thinking control only when
                    // it actually carries one; `finish_body` deep-merges an
                    // unrelated sibling field alongside the generated control, so
                    // an option that does not touch the thinking field must not
                    // suppress it. On Anthropic Messages a format-only
                    // `output_config` (no `effort`) is a structured-output
                    // setting, not a thinking override. On other wires the
                    // generated control for some formats lives in a nested object
                    // (`reasoning.effort` on Responses,
                    // `chat_template_kwargs.enable_thinking`/`reasoning_effort` on
                    // llama.cpp); an `extra_body` object there that sets only
                    // unrelated siblings (e.g. `reasoning = { summary = "auto" }`
                    // or an unrelated template variable) is merged in, not an
                    // override. Every top-level scalar control (and `thinking`) is
                    // an override whenever present.
                    present
                        && if wire == Wire::AnthropicMessages {
                            body.get(**k).and_then(|v| anthropic_extra_body_thinks(k, v)).is_some()
                        } else {
                            extra_body_overrides_generated(k, wire, format, body.get(**k))
                        }
                })
            })
            .map(|key| key.to_string())
    } else {
        None
    };
    if let Some(key) = &extra_body_override {
        // `effective` may have been fitted to `Default` on a model with no
        // matching level, yet the extra_body control still reaches the wire;
        // report the level the user asked for, which it displaces.
        let shown = if effective != Thinking::Default { &effective } else { &requested };
        warning = Some(format!(
            "the provider's extra_body sets {key:?}, which is sent instead of thinking {shown}; \
             remove it from extra_body to use the thinking setting"
        ));
    }
    // For Anthropic Messages, an `extra_body` thinking control that reaches the
    // wire (present and not dropped) decides the temperature lock on its own,
    // independent of whether it also overrides a generated field: its value —
    // not the generated level — is what the model sees, and a control that
    // enables thinking makes a custom temperature invalid even with no thinking
    // level requested.
    let extra_body_thinking_on = if wire == Wire::AnthropicMessages {
        provider.extra_body.as_ref().and_then(|body| {
            extra_body_keys(wire)
                .iter()
                .filter(|k| {
                    body.contains_key(**k) && !provider.drop_params.as_ref().is_some_and(|d| d.iter().any(|p| p == **k))
                })
                .find_map(|k| body.get(*k).and_then(|v| anthropic_extra_body_thinks(k, v)))
        })
    } else {
        None
    };
    let overridden = extra_body_override.is_some();
    // `finish_body` removes the provider's `drop_params` keys after the body is
    // built, so a generated thinking field under one of them never reaches the
    // wire — yet resolution would still report and log `effective` as sent.
    // Detect a dropped thinking field for this wire/format and report the level
    // as unsent instead. A full `extra_body` override suppresses the generated
    // field, so there is nothing left to drop then — but an Anthropic adaptive
    // `output_config.effort` override is only a *field-level* override: it owns
    // the effort value while `request()` deliberately preserves the generated
    // `thinking` half (`AdaptiveOn`/`Off`). That preserved half must be
    // drop-checked too, or dropping `thinking` would leave only the override's
    // `output_config.effort` on the wire — no complete control — while
    // resolution reports neither `dropped` nor a warning. The check probes the
    // request `request()` would emit for the *generated* field (no override),
    // which carries the same `thinking` key the preserved half is emitted
    // under.
    let preserved = overridden
        && extra_body_override.as_deref() == Some("output_config")
        && wire == Wire::AnthropicMessages
        && anthropic == AnthropicStyle::Adaptive;
    let drop_candidate =
        if effective != Thinking::Default && (!overridden || preserved) { Some(effective.clone()) } else { None };
    let dropped_key = drop_candidate.and_then(|effective| {
        let probe = Resolved {
            requested: requested.clone(),
            effective,
            source,
            levels: levels.clone(),
            wire,
            anthropic,
            format,
            // Probe the generated control as it would be emitted without the
            // override: for a field-level `output_config.effort` override the
            // preserved `thinking` half is what `drop_params` can strip, and
            // it sits under the same key the plain generated request uses.
            extra_body_override: None,
            extra_body_thinking_on: None,
            overridden: false,
            dropped: false,
            warning: None,
        };
        probe.request().and_then(|req| {
            provider
                .drop_params
                .as_ref()
                .and_then(|dropped| {
                    request_field_keys(wire, &req).iter().find(|k| dropped.iter().any(|d| d == **k)).copied()
                })
                .map(|key| key.to_string())
        })
    });
    if let Some(key) = &dropped_key {
        warning = Some(format!(
            "the provider drops {key:?} (drop_params), so thinking {effective} is not sent; \
             remove it from drop_params to use the thinking setting"
        ));
    }
    let dropped = dropped_key.is_some();
    let mut notices: Vec<String> = Vec::new();
    if !invalid_levels.is_empty() {
        notices.push(format!(
            "ignoring invalid thinking_levels {} for {model}: a level name is letters, digits, '-' or '_' — \
             fix them in its provider or model settings",
            invalid_levels.iter().map(|l| format!("{l:?}")).collect::<Vec<_>>().join(", ")
        ));
    }
    if !alias_levels.is_empty() {
        notices.push(format!(
            "ignoring thinking_levels {} for {model}: an off alias is not a level — use \"off\"",
            alias_levels.iter().map(|l| format!("{l:?}")).collect::<Vec<_>>().join(", ")
        ));
    }
    if !reserved_levels.is_empty() {
        notices.push(format!(
            "ignoring thinking_levels {} for {model}: the model default is always available and is not a selectable level",
            reserved_levels.iter().map(|l| format!("{l:?}")).collect::<Vec<_>>().join(", ")
        ));
    }
    if !notices.is_empty() {
        let notice = notices.join("; ");
        warning = Some(warning.map_or(notice.clone(), |w| format!("{notice}; {w}")));
    }
    Resolved {
        requested,
        effective,
        source,
        levels,
        wire,
        anthropic,
        format,
        extra_body_override,
        extra_body_thinking_on,
        overridden,
        dropped,
        warning,
    }
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
        // OpenAI reasoning models. GPT-5 takes `minimal`; GPT-5.1+ replaces it
        // with `none` (off). See <https://platform.openai.com/docs/models>.
        assert_eq!(levels("gpt-5").as_deref(), Some("minimal,low,medium,high"));
        assert_eq!(levels("gpt-5-mini").as_deref(), Some("minimal,low,medium,high"));
        assert_eq!(levels("gpt-5-nano").as_deref(), Some("minimal,low,medium,high"));
        assert_eq!(levels("gpt-5.1").as_deref(), Some("off,low,medium,high"));
        assert_eq!(levels("gpt-5.1-codex").as_deref(), Some("off,low,medium,high"));
        assert_eq!(levels("openai/gpt-5.6-sol").as_deref(), Some("off,low,medium,high"));
        // The non-reasoning chat model takes no reasoning_effort.
        assert_eq!(builtin("gpt-5-chat-latest"), None);
        assert_eq!(levels("o4-mini").as_deref(), Some("low,medium,high"));
        // `o1-mini` always reasons and rejects `reasoning_effort`: no levels.
        assert_eq!(builtin("o1-mini"), None);
        assert_eq!(builtin("o1-mini-2024-09-12"), None);
        assert_eq!(levels("o1").as_deref(), Some("low,medium,high"));
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
    fn gpt_5_family_reasoning_levels_split_by_variant() {
        let none = ProviderConfig::default();
        let openai = Some(ProviderKind::Openai);
        // GPT-5 takes `minimal`; it is sent as-is, not fitted up to `low`.
        let r = resolve(&Thinking::Default, Some(&level("minimal")), openai, &none, "gpt-5");
        assert_eq!(r.effective, level("minimal"));
        assert_eq!(r.request(), Some(Request::Effort("minimal".into())));
        assert_eq!(r.warning, None);
        // GPT-5 has no `none`, so `off` falls back to the model default.
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), openai, &none, "gpt-5");
        assert_eq!(r.effective, Thinking::Default);
        assert!(r.warning.unwrap().contains("can't turn thinking off"));
        // GPT-5.1 replaced `minimal` with `none`: `off` is sent, `minimal` fits to `low`.
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), openai, &none, "gpt-5.1");
        assert_eq!(r.request(), Some(Request::Off));
        let r = resolve(&Thinking::Default, Some(&level("minimal")), openai, &none, "gpt-5.1");
        assert_eq!(r.effective, level("low"));
        // `-mini`/`-codex` are GPT-5.0 variants (take `minimal`); the minor
        // version, not the variant suffix, decides.
        assert_eq!(builtin("gpt-5-mini").unwrap().levels, ["minimal", "low", "medium", "high"]);
        assert_eq!(builtin("gpt-5.1-codex").unwrap().levels, ["off", "low", "medium", "high"]);
        // The non-reasoning chat variant is not a reasoning model.
        assert_eq!(builtin("gpt-5-chat-latest"), None);
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
        // A custom name outside `ORDER` still turns an on/off-only model on
        // (regression: the `wanted` rank lookup must not short-circuit the
        // on-only fallback).
        let r = resolve(&Thinking::Default, Some(&level("deep")), kind, &p, "qwen3");
        assert_eq!(r.request(), Some(Request::Effort("on".into())), "a custom name turns an on-only model on");
        // A custom level name matches only itself.
        let p = provider(r#"thinking_levels = ["fast", "deep"]"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), kind, &p, "x");
        assert_eq!(r.effective, Thinking::Default);
        assert!(r.warning.unwrap().contains("it has: fast, deep"));
        let r = resolve(&Thinking::Default, Some(&level("deep")), kind, &p, "x");
        assert_eq!(r.request(), Some(Request::Effort("deep".into())));
    }

    #[test]
    fn invalid_configured_level_names_are_dropped_with_a_warning() {
        // A `thinking_levels` entry outside the `Thinking` name grammar would
        // break the `/settings` editor, which parses each offered candidate:
        // resolution drops it instead and says so. (Regression: "very high"
        // loaded fine, then opening the Thinking editor failed on it.)
        let p = provider(r#"thinking_levels = ["low", "very high", " High "]"#);
        let kind = Some(ProviderKind::Openai);
        let r = resolve(&Thinking::Default, Some(&level("high")), kind, &p, "kimi-k3");
        assert_eq!(r.levels, ["low", "high"], "entries are trimmed, lowercased, and validated");
        assert_eq!(r.request(), Some(Request::Effort("high".into())));
        let warning = r.warning.unwrap();
        assert!(warning.contains("\"very high\""), "{warning}");
        assert!(warning.contains("ignoring invalid thinking_levels"), "{warning}");
        // The notice precedes any other resolution warning.
        let r = resolve(&Thinking::Default, Some(&level("deep")), kind, &p, "kimi-k3");
        let warning = r.warning.unwrap();
        assert!(warning.contains("\"very high\"") && warning.contains("it has: low, high"), "{warning}");
        // A list left with no valid entries counts as unknown levels, so an
        // explicit setting is ignored with the usual guidance.
        let p = provider(r#"thinking_levels = ["very high"]"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), kind, &p, "kimi-k3");
        assert_eq!(r.effective, Thinking::Default);
        assert_eq!(r.levels, Vec::<String>::new());
        let warning = r.warning.unwrap();
        assert!(warning.contains("\"very high\"") && warning.contains("no thinking levels are known"), "{warning}");
        // Endpoint-reported and built-in levels are not filtered, and the
        // built-in table already uses the canonical "off" spelling for
        // GPT-5.1, so a `thinking = "none"` setting (which parses to
        // `Thinking::Off`) turns it off.
        let p = ProviderConfig::default();
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), kind, &p, "gpt-5.1");
        assert_eq!(r.request(), Some(Request::Off));
        assert_eq!(r.warning, None);
    }

    #[test]
    fn off_aliases_in_configured_levels_are_rejected() {
        // `Thinking` accepts "none"/"disabled" as `off` aliases, but a
        // configured list is matched verbatim: `thinking = "none"` parses to
        // `Thinking::Off`, so a list holding the alias would fail the
        // `levels.contains("off")` check and wrongly claim the model cannot
        // turn thinking off. Reject the alias and say which spelling to use.
        let kind = Some(ProviderKind::Openai);
        let p = provider(r#"thinking_levels = ["none", "low"]"#);
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), kind, &p, "x");
        assert_eq!(r.levels, ["low"]);
        assert_eq!(r.effective, Thinking::Default);
        let warning = r.warning.unwrap();
        assert!(warning.contains("an off alias is not a level"), "{warning}");
        assert!(warning.contains("\"none\""), "{warning}");
        assert!(warning.contains("can't turn thinking off"), "{warning}");
        // The canonical spelling passes and turns thinking off.
        let p = provider(r#"thinking_levels = ["off", "low"]"#);
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), kind, &p, "x");
        assert_eq!(r.request(), Some(Request::Off), "warning: {:?}", r.warning);
        assert_eq!(r.warning, None);
        let p = provider(r#"thinking_levels = ["disabled"]"#);
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), kind, &p, "x");
        let warning = r.warning.unwrap();
        assert!(warning.contains("an off alias is not a level"), "{warning}");
        assert!(warning.contains("\"disabled\""), "{warning}");
    }

    #[test]
    fn default_aliases_in_configured_levels_are_rejected() {
        // "default"/"auto"/"model default" all parse to `Thinking::Default`,
        // which is always offered separately and is never a selectable level.
        // A list keeping one would be a nonempty profile with no `off`, which
        // on Anthropic reads as an always-thinking model (and locks a custom
        // temperature) and shows a duplicate default in `/settings`.
        let kind = Some(ProviderKind::Openai);
        for alias in ["default", "auto", "Model Default", " DEFAULT "] {
            let p = provider(&format!(r#"thinking_levels = ["{alias}", "low"]"#));
            let r = resolve(&Thinking::Default, Some(&level("low")), kind, &p, "x");
            assert_eq!(r.levels, ["low"], "{alias}: the reserved alias is dropped");
            let warning = r.warning.unwrap();
            assert!(warning.contains("the model default is always available"), "{alias}: {warning}");
        }
        // A list left with only reserved aliases is empty, so an Anthropic
        // model is not treated as always-thinking and a custom temperature
        // stays valid — the pre-fix nonempty no-`off` profile locked it.
        let p = provider(r#"thinking_levels = ["default"]"#);
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Anthropic), &p, "some-claude");
        assert_eq!(r.levels, Vec::<String>::new());
        assert!(!r.always_anthropic_thinking(), "an empty profile is not always-thinking");
    }

    #[test]
    fn unrelated_output_config_fields_do_not_enable_thinking() {
        // `output_config` is an Anthropic thinking control only through its
        // `effort` field. `output_config = { format = ... }` is structured
        // output configuration, not a thinking control, so it must not lock a
        // custom temperature on an off-capable model.
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider(r#"extra_body = { output_config = { format = "json" } }"#);
        let r = resolve(&Thinking::Default, None, anthropic, &p, "claude-sonnet-4-6");
        assert_eq!(r.extra_body_thinking_on, None, "a format-only output_config is not a thinking control");
        assert!(!r.anthropic_thinking_on(), "it does not lock the temperature");
        assert!(!r.always_anthropic_thinking());
        // An `effort` field still enables or disables thinking as before, even
        // alongside an unrelated `format`.
        let p = provider(r#"extra_body = { output_config = { effort = "high", format = "json" } }"#);
        let r = resolve(&Thinking::Default, None, anthropic, &p, "claude-sonnet-4-6");
        assert_eq!(r.extra_body_thinking_on, Some(true));
        assert!(r.anthropic_thinking_on(), "an effort field still locks the temperature");
        let p = provider(r#"extra_body = { output_config = { effort = "none" } }"#);
        let r = resolve(&Thinking::Default, None, anthropic, &p, "claude-sonnet-4-6");
        assert_eq!(r.extra_body_thinking_on, Some(false), "an off effort disables thinking");
        assert!(!r.anthropic_thinking_on());
        // A `thinking` control is still found past a non-thinking output_config.
        let p = provider(r#"extra_body = { output_config = { format = "json" }, thinking = true }"#);
        let r = resolve(&Thinking::Default, None, anthropic, &p, "claude-sonnet-4-6");
        assert_eq!(r.extra_body_thinking_on, Some(true), "the thinking control still enables thinking");
        assert!(r.anthropic_thinking_on());
    }

    #[test]
    fn format_only_output_config_does_not_override_a_requested_level() {
        // A format-only `output_config` (no `effort`) is a structured-output
        // setting, not a thinking override: it must NOT suppress a requested
        // level. The generated adaptive `output_config.effort` and the
        // `format` coexist (merged by `finish_body`). Regression: the override
        // was classified by key presence alone, so a format-only `output_config`
        // set `overridden`, made `request()` return `None`, and silently dropped
        // the thinking control. (claude-sonnet-4-7 is adaptive and off-capable.)
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider(r#"extra_body = { output_config = { format = "json" } }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert!(!r.overridden, "a format-only output_config is not a thinking override");
        assert_eq!(r.extra_body_override, None);
        assert_eq!(r.request(), Some(Request::Effort("high".into())), "the requested level is still emitted");
        assert_eq!(r.warning, None, "no override warning for a non-thinking output_config");

        // An `effort` field IS a thinking override, but only a *field-level*
        // one: it owns the effort value while the generated `thinking = { type
        // = "adaptive" }` half must still reach the wire (adaptive thinking is
        // incomplete without it). So `request()` emits the enable half
        // (`AdaptiveOn`) and lets `finish_body` merge the override's
        // `output_config.effort` alongside it. Regression: this returned `None`,
        // sending `output_config.effort` with no `thinking` control.
        let p = provider(r#"extra_body = { output_config = { effort = "low", format = "json" } }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert!(r.overridden, "an effort-bearing output_config overrides the generated level");
        assert_eq!(r.extra_body_override.as_deref(), Some("output_config"));
        assert_eq!(
            r.request(),
            Some(Request::AdaptiveOn),
            "the generated thinking half is preserved; the override owns only the effort"
        );
    }

    #[test]
    fn adaptive_output_config_effort_override_keeps_the_thinking_control() {
        // End-to-end at the body builder: with `thinking = "high"` and
        // `extra_body.output_config.effort = "low"`, the wire must carry BOTH
        // the generated `thinking = { type = "adaptive" }` (required for
        // adaptive thinking) AND the override's `output_config.effort = "low"`
        // (deep-merged by `finish_body`, winning the effort field).
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider(r#"extra_body = { output_config = { effort = "low" } }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert_eq!(r.request(), Some(Request::AdaptiveOn));
        // The reported level is the override's, not the requested "high".
        assert!(r.overridden);

        // A Budget-style model has no `output_config` half, so an
        // `output_config.effort` there is a full override that suppresses the
        // generated `thinking` budget (the override owns the whole control).
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-5");
        assert_eq!(r.anthropic, AnthropicStyle::Budget);
        assert!(r.overridden);
        assert_eq!(r.request(), None, "a Budget model has no adaptive half to preserve");
    }

    #[test]
    fn adaptive_off_request_keeps_its_disable_control_under_an_effort_override() {
        // With `thinking = "off"` and an enabling `extra_body.output_config.effort`,
        // the override owns only the effort — NOT the `thinking` half. The
        // generated disable control `thinking = { type = "disabled" }` must still
        // reach the wire, or the effort would silently turn thinking on against
        // the explicit `off`. (claude-sonnet-4-7 is adaptive and off-capable.)
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider(r#"extra_body = { output_config = { effort = "low" } }"#);
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &p, "claude-sonnet-4-7");
        assert_eq!(r.effective, Thinking::Off);
        assert_eq!(r.extra_body_override.as_deref(), Some("output_config"));
        assert_eq!(
            r.request(),
            Some(Request::Off),
            "the generated disable control is preserved; the override owns only the effort"
        );
    }

    #[test]
    fn unrelated_nested_extra_body_options_do_not_suppress_the_generated_control() {
        // The same class as the Anthropic `output_config` fix, on other wires:
        // the generated control for some wires/formats lives in a nested object,
        // and `finish_body` merges an unrelated `extra_body` sibling alongside
        // it. So an `extra_body` object that sets only unrelated fields must NOT
        // be classified as an override — it would wrongly suppress the requested
        // level. An object that DOES carry the generated field still overrides.
        let copilot = Some(ProviderKind::GithubCopilot);

        // Responses: `reasoning.effort` is the generated field. A
        // `reasoning = { summary = "auto" }` sets only `summary`, so the
        // requested effort must still be emitted and coexist (merged).
        let p = provider(r#"extra_body = { reasoning = { summary = "auto" } }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), copilot, &p, "gpt-5.6-sol");
        assert_eq!(r.wire, Wire::Responses);
        assert!(!r.overridden, "a summary-only reasoning option is not a thinking override");
        assert_eq!(r.extra_body_override, None);
        assert_eq!(r.request(), Some(Request::Effort("high".into())), "the requested effort is still emitted");
        assert_eq!(r.warning, None, "no override warning for an unrelated nested option");
        // A `reasoning` that carries `effort` IS an override (it displaces the
        // generated effort), and a non-object value replaces it wholesale.
        let p = provider(r#"extra_body = { reasoning = { effort = "low", summary = "auto" } }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), copilot, &p, "gpt-5.6-sol");
        assert!(r.overridden, "an effort-bearing reasoning overrides the generated effort");
        assert_eq!(r.extra_body_override.as_deref(), Some("reasoning"));
        assert_eq!(r.request(), None, "the generated control is suppressed by the override");
        let p = provider(r#"extra_body = { reasoning = "high" }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), copilot, &p, "gpt-5.6-sol");
        assert!(r.overridden, "a non-object reasoning replaces the control wholesale");

        // llama.cpp switch template: the generated field is
        // `chat_template_kwargs.enable_thinking`. An unrelated template variable
        // there must not suppress the switch; one that sets `enable_thinking`
        // does override.
        let openai = Some(ProviderKind::Openai);
        let switch =
            Reported { levels: vec!["off".into(), ON.into()], adaptive: false, format: Format::TemplateSwitch };
        let p = provider(r#"extra_body = { chat_template_kwargs = { foo = true } }"#);
        let r = resolve_with(&Thinking::Default, Some(&level("high")), openai, &p, "local", Some(&switch));
        assert!(!r.overridden, "an unrelated template variable is not a thinking override");
        assert_eq!(r.request(), Some(Request::TemplateSwitch(true)), "the generated switch is still emitted");
        let p = provider(r#"extra_body = { chat_template_kwargs = { enable_thinking = false } }"#);
        let r = resolve_with(&Thinking::Default, Some(&level("high")), openai, &p, "local", Some(&switch));
        assert!(r.overridden, "setting enable_thinking overrides the generated switch");
        assert_eq!(r.request(), None, "the generated control is suppressed by the override");

        // llama.cpp effort template: the generated field is
        // `chat_template_kwargs.reasoning_effort`.
        let effort =
            Reported { levels: vec!["low".into(), "high".into()], adaptive: false, format: Format::TemplateEffort };
        let p = provider(r#"extra_body = { chat_template_kwargs = { foo = true } }"#);
        let r = resolve_with(&Thinking::Default, Some(&level("high")), openai, &p, "local", Some(&effort));
        assert!(!r.overridden, "an unrelated template variable is not a thinking override");
        assert_eq!(r.request(), Some(Request::TemplateEffort("high".into())), "the generated effort is still emitted");
        let p = provider(r#"extra_body = { chat_template_kwargs = { reasoning_effort = "low" } }"#);
        let r = resolve_with(&Thinking::Default, Some(&level("high")), openai, &p, "local", Some(&effort));
        assert!(r.overridden, "setting reasoning_effort overrides the generated effort");
        assert_eq!(r.request(), None, "the generated control is suppressed by the override");

        // Chat Completions scalar `reasoning_effort`: still an override on
        // presence (no nested field to merge).
        let p = provider(r#"extra_body = { reasoning_effort = "low" }"#);
        let r = resolve(&Thinking::Default, Some(&level("high")), openai, &p, "gpt-5");
        assert!(r.overridden, "a scalar reasoning_effort overrides on presence");
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
        // suppress the generated control entirely. The override owns the
        // thinking decision now, and since it explicitly enables thinking on a
        // model that always thinks, the temperature stays locked.
        let p = provider("extra_body = { thinking = { type = \"enabled\" } }");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-5.5");
        assert!(r.warning.is_some());
        assert_eq!(r.request(), None, "generated thinking/output_config must be suppressed");
        assert!(r.anthropic_thinking_on(), "an enabling extra_body thinking override still locks the temperature");
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
        // either removes the level. On an off-capable model the request then
        // sends no thinking field, so it does not lock the temperature.
        // (claude-sonnet-4-7 is adaptive AND supports `off`.)
        for key in ["thinking", "output_config"] {
            let p = provider(&format!("drop_params = [\"{key}\"]"));
            let r = resolve(
                &Thinking::Default,
                Some(&level("high")),
                Some(ProviderKind::Anthropic),
                &p,
                "claude-sonnet-4-7",
            );
            assert!(r.dropped, "{key}");
            assert_eq!(r.request(), None, "{key}");
            assert!(
                !r.anthropic_thinking_on(),
                "{key}: a dropped level on an off-capable model does not lock the temperature"
            );
        }
        // But a no-`off` model (Claude 5.5+) still thinks by default even when
        // the generated field is dropped, so the temperature stays locked.
        for key in ["thinking", "output_config"] {
            let p = provider(&format!("drop_params = [\"{key}\"]"));
            let r = resolve(
                &Thinking::Default,
                Some(&level("high")),
                Some(ProviderKind::Anthropic),
                &p,
                "claude-sonnet-5.5",
            );
            assert!(r.dropped, "{key}");
            assert_eq!(r.request(), None, "{key}");
            assert!(
                r.anthropic_thinking_on(),
                "{key}: a no-off model still thinks when the generated field is dropped"
            );
            assert!(r.always_anthropic_thinking(), "{key}: a no-off model thinks even with no field sent");
        }

        // A Budget-style model (Claude 3.7–4.5) sends only `thinking`, never
        // `output_config`, so dropping `output_config` is a no-op: the level is
        // still sent and must NOT be reported as dropped.
        let p = provider("drop_params = [\"output_config\"]");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-5");
        assert_eq!(r.anthropic, AnthropicStyle::Budget);
        assert!(!r.dropped, "output_config is never sent for a Budget model");
        assert_eq!(r.request(), Some(Request::Budget(budget_tokens("high"))), "the Budget level is still sent");
        assert!(r.anthropic_thinking_on(), "a still-sent Budget level locks the temperature");
        // Dropping the key a Budget model DOES send (`thinking`) removes it.
        let p = provider("drop_params = [\"thinking\"]");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-5");
        assert!(r.dropped, "thinking is the Budget field and is dropped");
        assert_eq!(r.request(), None);

        // Anthropic `off` sends only `thinking` (`type = disabled`), never
        // `output_config`, so dropping `output_config` is a no-op there too.
        // (claude-sonnet-4-7 is adaptive AND supports `off`.)
        let p = provider("drop_params = [\"output_config\"]");
        let r = resolve(&Thinking::Off, None, Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-7");
        assert_eq!((r.anthropic, &r.effective), (AnthropicStyle::Adaptive, &Thinking::Off));
        assert!(!r.dropped, "output_config is not sent for an off request");
        assert_eq!(r.request(), Some(Request::Off));

        // A drop_params key for another wire does not suppress the field.
        let p = provider("drop_params = [\"reasoning\"]");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-5.5");
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
    fn drop_params_strips_the_preserved_half_of_an_output_config_override() {
        // An adaptive `output_config.effort` override is only a *field-level*
        // override: `request()` preserves the generated `thinking` half
        // (`AdaptiveOn`/`Off`) alongside it. `finish_body` still applies
        // `drop_params` afterwards, so `drop_params = ["thinking"]` strips that
        // preserved half and leaves only the bare `output_config.effort` — no
        // complete thinking control reaches the wire. Resolution must report
        // the level as dropped (and warn), not silently send the effort.
        // (claude-sonnet-4-7 is adaptive and off-capable.)
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider("drop_params = [\"thinking\"]\nextra_body = { output_config = { effort = \"low\" } }");
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert_eq!(r.extra_body_override.as_deref(), Some("output_config"));
        assert!(r.dropped, "the preserved thinking half is dropped");
        assert_eq!(r.request(), None, "a bare output_config.effort without its thinking half is not sent");
        let warning = r.warning.unwrap();
        assert!(warning.contains("\"thinking\"") && warning.contains("drop_params"), "{warning}");

        // The preserved disable control of an `off` request is dropped the same
        // way — and with no thinking control left on the wire, the temperature
        // is not locked either.
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &p, "claude-sonnet-4-7");
        assert!(r.dropped, "the preserved disable control is dropped");
        assert_eq!(r.request(), None);
        assert!(!r.anthropic_thinking_on(), "nothing thinking-related reaches the wire");

        // Dropping the override's own key removes the override itself: the
        // bare `output_config.effort` never reaches the wire, so nothing is
        // classified as overridden. The generated `thinking` half is then the
        // only control that could carry the level — but `drop_params` strips
        // `thinking` too, so it is reported dropped and nothing is sent.
        let p = provider(
            "drop_params = [\"output_config\", \"thinking\"]\nextra_body = { output_config = { effort = \"low\" } }",
        );
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert!(!r.overridden, "a dropped override is no override");
        assert!(r.dropped, "the generated thinking half is dropped");
        assert_eq!(r.request(), None, "no thinking control reaches the wire");

        // A full override (a `thinking` control in extra_body) suppresses the
        // generated field entirely, so there is no preserved half to drop.
        let p = provider("drop_params = [\"thinking\"]\nextra_body = { output_config = { effort = \"low\" } }");
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-5");
        assert_eq!(r.anthropic, AnthropicStyle::Budget, "a Budget model has no adaptive half to preserve");
        assert!(r.overridden);
        assert!(!r.dropped);
        assert_eq!(r.request(), None);
    }

    #[test]
    fn a_preserved_disable_control_unlocks_the_temperature() {
        // With `thinking = "off"` and an *enabling* `extra_body.output_config
        // .effort`, `request()` preserves the generated `thinking = { type =
        // "disabled" }`, which wins the thinking state on the wire. The
        // temperature lock must follow that emitted disable control, not the
        // override's enabling effort: the configured temperature stays valid.
        // (claude-sonnet-4-7 is adaptive and off-capable.)
        let anthropic = Some(ProviderKind::Anthropic);
        let p = provider(r#"extra_body = { output_config = { effort = "low" } }"#);
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &p, "claude-sonnet-4-7");
        assert_eq!(r.request(), Some(Request::Off), "the disable control is preserved");
        assert_eq!(r.extra_body_thinking_on, Some(true), "the effort override enables thinking");
        assert!(!r.anthropic_thinking_on(), "the emitted disabled control wins, so the temperature is not locked");

        // An enabling override whose generated half turns thinking ON still
        // locks it.
        let r = resolve(&Thinking::Default, Some(&level("high")), anthropic, &p, "claude-sonnet-4-7");
        assert_eq!(r.request(), Some(Request::AdaptiveOn));
        assert!(r.anthropic_thinking_on(), "an enabling override with no disable control locks the temperature");

        // And an always-thinking model stays locked even with the preserved
        // disable control: it cannot turn thinking off. (claude-sonnet-5.5 has
        // no `off` level, so `off` fits to the model default.)
        let r = resolve(&Thinking::Default, Some(&Thinking::Off), anthropic, &p, "claude-sonnet-5.5");
        assert!(r.model_always_thinks());
        assert!(r.anthropic_thinking_on(), "an always-thinking model locks the temperature regardless");
    }

    #[test]
    fn budget_tokens_maps_custom_names_to_a_conservative_ceiling() {
        // Every standard level maps to its documented budget, `max` included.
        assert_eq!(budget_tokens("minimal"), 1024);
        assert_eq!(budget_tokens("low"), 2048);
        assert_eq!(budget_tokens("medium"), 8192);
        assert_eq!(budget_tokens("high"), 16384);
        assert_eq!(budget_tokens("xhigh"), 32768);
        assert_eq!(budget_tokens("max"), 65536);
        // A custom `thinking_levels` name is off the standard scale: it must NOT
        // silently request the maximum budget. Regression: the `_` wildcard
        // mapped every unrecognized name to 65,536.
        assert_eq!(budget_tokens("fast"), 16384, "an unrecognized name caps at the high budget, not the max");
        assert_eq!(budget_tokens("deep"), 16384);
    }

    #[test]
    fn dropped_or_overridden_field_still_locks_an_always_thinking_model() {
        // A no-`off` model (Claude 5.5+) thinks by default, so even when the
        // generated thinking field is stripped by `drop_params` (or suppressed
        // by an `extra_body` override) the model still thinks — a custom
        // Anthropic temperature stays invalid. The pre-fix blanket `false`
        // return on `dropped`/`overridden` re-enabled that invalid temperature.
        let p = provider("drop_params = [\"thinking\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-opus-5.5");
        assert!(r.dropped);
        assert_eq!(r.request(), None, "the generated thinking field is dropped");
        assert!(r.anthropic_thinking_on(), "a dropped field does not stop a no-off model thinking");
        assert!(r.always_anthropic_thinking(), "the model still thinks with no field sent");

        // Same for a fully suppressing `extra_body` override on a no-off model.
        // An enabling `output_config.effort` override is only a field-level
        // override on an adaptive model: it owns the effort, but the generated
        // `thinking` enable half still reaches the wire (`AdaptiveOn`).
        let p = provider("extra_body = { output_config = { effort = \"high\" } }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-opus-5.5");
        assert!(r.overridden);
        assert_eq!(
            r.request(),
            Some(Request::AdaptiveOn),
            "the override owns the effort; the thinking half is preserved"
        );
        assert!(r.anthropic_thinking_on(), "an overridden field does not stop a no-off model thinking");
    }

    #[test]
    fn extra_body_thinking_override_locks_only_when_it_enables_thinking() {
        // On an OFF-capable Anthropic model the generated field is suppressed by
        // the override, so the lock depends on the override's own value — the
        // model does not think on its own. claude-sonnet-4-6 can turn off.
        // An explicitly enabling override locks the temperature. A `thinking`
        // control is a full override (suppresses the whole generated field)...
        for body in ["extra_body = { thinking = { type = \"enabled\" } }", "extra_body = { thinking = true }"] {
            let p = provider(body);
            let r = resolve(
                &Thinking::Default,
                Some(&level("high")),
                Some(ProviderKind::Anthropic),
                &p,
                "claude-sonnet-4-6",
            );
            assert!(r.overridden, "{body}");
            assert_eq!(r.request(), None, "{body}: the generated control is suppressed");
            assert!(r.anthropic_thinking_on(), "{body}: an enabling override locks the temperature");
            assert!(r.always_anthropic_thinking(), "{body}: enabling override thinks with no generated field");
        }
        // ...while an enabling `output_config.effort` is only a field-level
        // override: it owns the effort but the generated `thinking` enable half
        // still reaches the wire (`AdaptiveOn`), and the temperature stays
        // locked because the model is asked to think.
        let p = provider("extra_body = { output_config = { effort = \"high\" } }");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-6");
        assert!(r.overridden);
        assert_eq!(r.request(), Some(Request::AdaptiveOn), "the effort override preserves the generated thinking half");
        assert!(r.anthropic_thinking_on(), "an enabling override locks the temperature");
        assert!(r.always_anthropic_thinking(), "enabling override thinks with the thinking half sent");
        // ...but an explicitly disabling override leaves a custom temperature
        // valid on an off-capable model (nothing asks it to think).
        for body in [
            "extra_body = { thinking = { type = \"disabled\" } }",
            "extra_body = { thinking = false }",
            "extra_body = { output_config = { effort = \"none\" } }",
        ] {
            let p = provider(body);
            let r = resolve(
                &Thinking::Default,
                Some(&level("high")),
                Some(ProviderKind::Anthropic),
                &p,
                "claude-sonnet-4-6",
            );
            assert!(r.overridden, "{body}");
            assert!(!r.anthropic_thinking_on(), "{body}: a disabling override does not lock the temperature");
            assert!(!r.always_anthropic_thinking(), "{body}: a disabling override does not think");
        }
        // A disabling `output_config.effort` must NOT emit the adaptive enable
        // half: that would re-enable the thinking the override turned off.
        let p = provider("extra_body = { output_config = { effort = \"none\" } }");
        let r =
            resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-6");
        assert_eq!(r.extra_body_thinking_on, Some(false));
        assert_eq!(r.request(), None, "a disabling effort override emits no thinking control");
        // An enabling extra_body control locks the temperature even with NO
        // thinking level requested (the override gate is not taken, yet the
        // control still reaches the wire and the model thinks).
        let p = provider("extra_body = { thinking = { type = \"enabled\" } }");
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-6");
        assert_eq!(r.effective, Thinking::Default, "no level is requested");
        assert!(!r.overridden, "with no requested setting there is no generated field to override");
        assert!(r.anthropic_thinking_on(), "an enabling extra_body control still locks the temperature");
        assert!(r.always_anthropic_thinking(), "it thinks even with no generated field");
        // A dropped extra_body thinking control reaches the wire no more than
        // the generated field does, so it does not lock the temperature.
        let p = provider("extra_body = { thinking = { type = \"enabled\" } }\ndrop_params = [\"thinking\"]");
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Anthropic), &p, "claude-sonnet-4-6");
        assert!(!r.anthropic_thinking_on(), "a dropped extra_body control does not lock the temperature");
    }

    #[test]
    fn an_extra_body_control_overrides_a_setting_fitted_to_default() {
        // An explicit non-default setting on a model with no known levels is
        // fitted to `Default` (the generated field is nothing), yet the
        // `extra_body` control is still merged into the request and reaches the
        // wire. It must be reported as a sent override, not merely "ignored".
        let p = provider("extra_body = { reasoning_effort = \"low\" }");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "some-unknown-model");
        assert!(r.levels.is_empty(), "nothing is known about the model");
        assert_eq!(r.effective, Thinking::Default, "the requested level is fitted away");
        assert!(r.overridden, "the extra_body control still reaches the wire");
        let warning = r.warning.unwrap();
        assert!(warning.contains("extra_body") && warning.contains("high"), "{warning}");

        // With no extra_body control, the unknown-model setting is just ignored.
        let p = ProviderConfig::default();
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "some-unknown-model");
        assert!(!r.overridden);
        assert!(r.warning.unwrap().contains("no thinking levels are known"));

        // A `Default` request with an extra_body control is not an override:
        // the user asked for nothing, so there is no setting to displace.
        let p = provider("extra_body = { reasoning_effort = \"low\" }");
        let r = resolve(&Thinking::Default, None, Some(ProviderKind::Openai), &p, "some-unknown-model");
        assert!(!r.overridden, "no requested setting means no override");
        assert_eq!(r.warning, None);
    }

    #[test]
    fn a_dropped_extra_body_control_is_not_an_override() {
        // `finish_body` merges `extra_body` then strips `drop_params` keys, so an
        // extra_body key that is also dropped reaches the wire no more than the
        // generated field does. It must not be reported as a sent override; the
        // generated-field drop logic reports the real outcome instead.

        // extra_body + drop_params on the key the generated field also uses: the
        // generated `reasoning_effort` is itself dropped, so report dropped, not
        // overridden.
        let p = provider("extra_body = { reasoning_effort = \"low\" }\ndrop_params = [\"reasoning_effort\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(!r.overridden, "a dropped extra_body key is no override");
        assert!(r.dropped, "the generated reasoning_effort is dropped");
        assert_eq!(r.request(), None, "nothing reaches the wire");
        assert!(r.warning.unwrap().contains("drop_params"));

        // extra_body control dropped, but the generated field uses a DIFFERENT,
        // undropped key: the generated field still reaches the wire, so the
        // level is genuinely sent — neither overridden nor dropped.
        let p = provider("extra_body = { think = true }\ndrop_params = [\"think\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(!r.overridden, "the dropped `think` key is no override");
        assert!(!r.dropped, "the generated reasoning_effort is not dropped");
        assert_eq!(r.request(), Some(Request::Effort("high".into())), "the generated field is still sent");
        assert_eq!(r.warning, None);

        // An undropped extra_body key is still a real override.
        let p = provider("extra_body = { reasoning_effort = \"low\" }\ndrop_params = [\"temperature\"]");
        let r = resolve(&Thinking::Default, Some(&level("high")), Some(ProviderKind::Openai), &p, "gpt-5");
        assert!(r.overridden, "an undropped extra_body key still overrides");
        assert!(!r.dropped);
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
        // A `reasoning_effort` template consumes that variable, so off is
        // encoded as `reasoning_effort = "none"` — an `enable_thinking`
        // switch would be ignored. (Reachable via a `thinking_levels`
        // override adding `off`; the detected list has none.)
        let off_cfg = provider(r#"thinking_levels = ["off", "low", "medium", "high"]"#);
        let r = resolve_with(&Thinking::Default, Some(&Thinking::Off), openai, &off_cfg, "qwen3", Some(&effort));
        assert_eq!(r.request(), Some(Request::TemplateEffort("none".into())));
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
