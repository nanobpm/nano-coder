//! Whether the current model can view images, and the limits it imposes.
//!
//! `read_file` attaches images to its result only when the model can see them;
//! otherwise it keeps the text error (with a hint). Capability comes from a
//! config override (`vision = true|false`, global / `[providers.NAME]` /
//! `[providers.NAME.models."MODEL"]`, like `thinking`), else what the endpoint
//! reports (Copilot `/models`, Ollama `/api/show`, llama.cpp `/props`), else a
//! built-in assumption for the current Anthropic / OpenAI model families.

use crate::attachment::ImageLimits;
use crate::providers::{ProviderConfig, ProviderKind};

/// What a model can see, and the limits a request must respect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vision {
    /// The most images a request may carry; older ones become a placeholder.
    /// `0` means the model cannot see images at all.
    pub max_images: usize,
    /// Byte cap on one encoded image (Copilot `max_prompt_image_size`).
    pub max_image_bytes: usize,
    /// Media types the model accepts; empty means any of ours.
    pub media_types: Vec<String>,
}

impl Vision {
    /// A vision-capable model with no specific limits reported.
    fn capable() -> Self {
        Vision { max_images: 1, max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES, media_types: Vec::new() }
    }

    /// The limits `read_file` prepares an image against.
    pub fn image_limits(&self) -> ImageLimits {
        ImageLimits {
            max_dimension: crate::attachment::MAX_DIMENSION,
            max_bytes: self.max_image_bytes,
            accepted_media_types: self.media_types.clone(),
        }
    }

    /// Copilot `/models` entry: `capabilities.supports.vision` plus
    /// `capabilities.limits.vision` (`max_prompt_images`,
    /// `max_prompt_image_size`, `supported_media_types`). `None` when the entry
    /// does not grant vision.
    pub fn from_model_entry(entry: &serde_json::Value) -> Option<Vision> {
        let capabilities = entry.get("capabilities")?;
        let supports = capabilities.get("supports")?;
        if !supports.get("vision").and_then(serde_json::Value::as_bool).unwrap_or(false) {
            return None;
        }
        let limits = capabilities.get("limits").and_then(|l| l.get("vision"));
        // An explicit `max_prompt_images: 0` reports the model as blind even
        // though `supports.vision` is true — honour the stricter limit and
        // grant no vision, distinct from an absent limit (which defaults to 1).
        let reported_max = limits.and_then(|v| v.get("max_prompt_images")).and_then(serde_json::Value::as_u64);
        if reported_max == Some(0) {
            return None;
        }
        let max_images = reported_max.map(|n| n as usize).unwrap_or(1);
        let max_image_bytes = limits
            .and_then(|v| v.get("max_prompt_image_size"))
            .and_then(serde_json::Value::as_u64)
            .filter(|&n| n > 0)
            .map(|n| n as usize)
            .unwrap_or(crate::attachment::DEFAULT_MAX_BYTES);
        let media_types = limits
            .and_then(|v| v.get("supported_media_types"))
            .and_then(serde_json::Value::as_array)
            .map(|types| types.iter().filter_map(serde_json::Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        Some(Vision { max_images, max_image_bytes, media_types })
    }

    /// Ollama `/api/show`: the `vision` capability.
    pub fn from_ollama_show(show: &serde_json::Value) -> Option<Vision> {
        let sees = show.get("capabilities")?.as_array()?.iter().any(|c| c.as_str() == Some("vision"));
        sees.then(Vision::capable)
    }

    /// llama.cpp `/props`: `modalities.vision` (the loaded model's modalities).
    pub fn from_llamacpp_props(props: &serde_json::Value) -> Option<Vision> {
        let sees = props.pointer("/modalities/vision").and_then(serde_json::Value::as_bool).unwrap_or(false);
        sees.then(Vision::capable)
    }
}

/// Where the `vision` setting in effect came from (for the hint and tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Model,
    Provider,
    Global,
    /// No override configured; the endpoint report or built-in assumption.
    Detected,
}

/// A configured `vision = true|false` override, parsed from TOML (a plain
/// boolean). Shared by the global, provider and per-model settings.
pub type Override = bool;

/// Resolve the configured `vision` override for `model` on `provider` (the
/// merged provider entry): the model's setting, else the provider's, else
/// `global`. `None` means no override — the endpoint report / built-in
/// assumption decides.
pub fn configured_override(
    global: Option<Override>,
    provider: &ProviderConfig,
    model: &str,
) -> (Option<Override>, Source) {
    if let Some(v) = provider.models.get(model).and_then(|m| m.vision) {
        (Some(v), Source::Model)
    } else if let Some(v) = provider.vision {
        (Some(v), Source::Provider)
    } else if let Some(v) = global {
        (Some(v), Source::Global)
    } else {
        (None, Source::Detected)
    }
}

/// The vision capability for `model` on a provider of `kind`: a configured
/// override wins (`true` → capable with default limits, `false` → blind); else
/// the endpoint `reported` value; else a built-in assumption for the current
/// first-party Anthropic / OpenAI model families. Returns `None` when the model
/// cannot see images.
pub fn resolve(
    global: Option<Override>,
    kind: Option<ProviderKind>,
    provider: &ProviderConfig,
    model: &str,
    reported: Option<&Vision>,
) -> Option<Vision> {
    let (override_, _source) = configured_override(global, provider, model);
    if let Some(on) = override_ {
        return on.then(Vision::capable);
    }
    if let Some(reported) = reported {
        return Some(reported.clone());
    }
    // Built-in family assumptions apply only to the first-party direct
    // providers whose model families we actually know. Both `ProviderKind`s are
    // shared by every wire-compatible endpoint: `Openai` by Ollama, llama.cpp,
    // OpenRouter, Groq, …; `Anthropic` by any Anthropic-compatible gateway
    // (README documents custom endpoints). A local model merely *named* `gpt-5`
    // or served by a non-vision custom Anthropic gateway is not a first-party
    // model and must not inherit built-in vision support — especially when its
    // own endpoint probe reported no vision. Custom endpoints use the explicit
    // `vision` override instead.
    match kind {
        Some(ProviderKind::Anthropic) if is_anthropic_direct(provider) && assumes_anthropic_vision(model) => {
            Some(Vision::capable())
        }
        Some(ProviderKind::Openai) if is_openai_direct(provider) && assumes_openai_vision(model) => {
            Some(Vision::capable())
        }
        _ => None,
    }
}

/// The host of a provider's `base_url`, lowercased (for first-party endpoint
/// checks). `None` when no base URL is configured or it has no host.
fn base_url_host(provider: &ProviderConfig) -> Option<String> {
    let url = provider.base_url.as_deref()?;
    let after_scheme = url.split("://").nth(1).unwrap_or(url);
    let authority = after_scheme.split(['/', '?', '#']).next().unwrap_or("");
    // Strip any userinfo and port.
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.rsplit(':').next_back().unwrap_or(host);
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

/// Whether this provider is the first-party OpenAI API (`api.openai.com`),
/// rather than some other OpenAI-compatible endpoint sharing the kind.
fn is_openai_direct(provider: &ProviderConfig) -> bool {
    base_url_host(provider).is_some_and(|h| h == "api.openai.com" || h.ends_with(".api.openai.com"))
}

/// Whether this provider is the first-party Anthropic API (`api.anthropic.com`),
/// rather than some other Anthropic-compatible gateway sharing the kind.
fn is_anthropic_direct(provider: &ProviderConfig) -> bool {
    base_url_host(provider).is_some_and(|h| h == "api.anthropic.com" || h.ends_with(".api.anthropic.com"))
}

/// Whether a model served by the first-party Anthropic API is vision-capable.
///
/// The first-party API serves only Claude chat models, and every current Claude
/// family (3, 3.5, 3.7, 4, …) accepts images; only the retired `claude-2` /
/// `claude-instant` families are blind. So assume capable *except* those known
/// legacy families — new Claude families keep working without an allowlist to
/// maintain. Legacy tokens are matched as whole, delimited name segments (after
/// stripping an optional `ft:<base>:…` fine-tune wrapper) so that e.g.
/// `claude-2`, `claude-2.1`, and `claude-instant-1.2` are blind while a
/// `claude-3`/`claude-sonnet-4-5` name is not mistaken for them.
fn assumes_anthropic_vision(model: &str) -> bool {
    let m = model.to_lowercase();
    // `ft:<base>:<org>::<id>` → `<base>`; a plain name is its own base.
    let base = m.strip_prefix("ft:").map_or(m.as_str(), |rest| rest.split(':').next().unwrap_or(rest));
    const BLIND: [&str; 2] = ["claude-2", "claude-instant"];
    !BLIND.iter().any(|family| match base.strip_prefix(family) {
        Some(rest) => rest.is_empty() || rest.starts_with('-') || rest.starts_with('.'),
        None => false,
    })
}

/// Whether an OpenAI-direct model name is a current vision-capable family.
///
/// Families are matched as whole, delimited name segments rather than bare
/// substrings, so a name that merely *contains* a family token (e.g.
/// `gpt-4o3-custom`, or an `o3` appearing in a fine-tune suffix) is not
/// mistaken for it. A model is a family member when, after stripping an
/// optional `ft:<base>:…` fine-tune wrapper down to its base, the base either
/// equals the family token or continues with a `-` or `.` (e.g. `o4-mini`,
/// `gpt-4o-2024-08-06`, `gpt-5.6`). The `.` delimiter admits dotted revisions
/// of a vision family (`gpt-5.1`, `gpt-5.6`) — the direct OpenAI provider
/// returns no endpoint report, so without it they would be misclassified as
/// blind — while a digit continuation (`gpt-50`) stays blind.
///
/// The text-only `o3-mini` subfamily is carved out: the bare `o3` prefix would
/// otherwise classify `o3-mini` (and dated `o3-mini-*` aliases) as
/// vision-capable, but `o3-mini` cannot see images, so on the direct OpenAI
/// provider — where detection returns no report and `resolve` falls back here —
/// it would be sent images the API rejects.
fn assumes_openai_vision(model: &str) -> bool {
    let m = model.to_lowercase();
    // `ft:<base>:<org>::<id>` → `<base>`; a plain name is its own base.
    let base = m.strip_prefix("ft:").map_or(m.as_str(), |rest| rest.split(':').next().unwrap_or(rest));
    // `o3-mini` is text-only; exclude it (and `o3-mini-*` aliases) before the
    // family-prefix match below claims it via `o3`.
    if base == "o3-mini" || base.starts_with("o3-mini-") {
        return false;
    }
    const FAMILIES: [&str; 5] = ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4"];
    FAMILIES.iter().any(|family| match base.strip_prefix(family) {
        Some(rest) => rest.is_empty() || rest.starts_with('-') || rest.starts_with('.'),
        None => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn copilot_entry_reads_vision_and_limits() {
        let entry = json!({ "id": "gpt-5-mini", "capabilities": {
            "supports": { "vision": true },
            "limits": { "vision": {
                "max_prompt_images": 5,
                "max_prompt_image_size": 3145728,
                "supported_media_types": ["image/jpeg", "image/png"]
            } }
        }});
        let vision = Vision::from_model_entry(&entry).unwrap();
        assert_eq!(vision.max_images, 5);
        assert_eq!(vision.max_image_bytes, 3145728);
        assert_eq!(vision.media_types, ["image/jpeg", "image/png"]);

        // Vision supported but no limits block: defaults apply.
        let bare = json!({ "capabilities": { "supports": { "vision": true } } });
        let vision = Vision::from_model_entry(&bare).unwrap();
        assert_eq!(vision.max_images, 1);
        assert_eq!(vision.max_image_bytes, crate::attachment::DEFAULT_MAX_BYTES);
        assert!(vision.media_types.is_empty());

        // No vision support means blind; an explicit zero image count is also
        // blind (distinct from an absent limit, which defaults to 1).
        assert_eq!(Vision::from_model_entry(&json!({ "capabilities": { "supports": {} } })), None);
        assert_eq!(
            Vision::from_model_entry(
                &json!({ "capabilities": { "supports": { "vision": true }, "limits": { "vision": { "max_prompt_images": 0 } } } })
            ),
            None
        );
    }

    #[test]
    fn ollama_and_llamacpp_detection() {
        assert!(Vision::from_ollama_show(&json!({ "capabilities": ["vision", "completion"] })).is_some());
        assert_eq!(Vision::from_ollama_show(&json!({ "capabilities": ["completion"] })), None);
        assert!(Vision::from_llamacpp_props(&json!({ "modalities": { "vision": true } })).is_some());
        assert_eq!(Vision::from_llamacpp_props(&json!({ "modalities": { "vision": false } })), None);
        assert_eq!(Vision::from_llamacpp_props(&json!({})), None);
    }

    #[test]
    fn override_wins_over_detection() {
        let provider = ProviderConfig::default();
        let openai_direct = ProviderConfig { base_url: Some("https://api.openai.com/v1".into()), ..Default::default() };
        let anthropic_direct =
            ProviderConfig { base_url: Some("https://api.anthropic.com/v1".into()), ..Default::default() };
        // Configured false blinds even an Anthropic model.
        assert_eq!(resolve(Some(false), Some(ProviderKind::Anthropic), &provider, "claude-sonnet-4-5", None), None);
        // Configured true enables a model the endpoint said nothing about.
        assert!(resolve(Some(true), Some(ProviderKind::Openai), &provider, "some-local", None).is_some());
        // No override: a first-party Anthropic/OpenAI family model is assumed
        // capable, a non-family OpenAI model is not.
        assert!(resolve(None, Some(ProviderKind::Anthropic), &anthropic_direct, "claude-sonnet-4-5", None).is_some());
        assert!(resolve(None, Some(ProviderKind::Openai), &openai_direct, "gpt-5-mini", None).is_some());
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &openai_direct, "text-embedding-3", None), None);
        assert_eq!(resolve(None, None, &provider, "m", None), None);
    }

    #[test]
    fn built_in_anthropic_assumption_is_scoped_to_the_first_party_api() {
        // `ProviderKind::Anthropic` is shared by every Anthropic-compatible
        // gateway. A non-vision model served by a custom gateway must not
        // inherit vision from the built-in assumption; only the first-party
        // Anthropic API does.
        let gateway =
            ProviderConfig { base_url: Some("https://anthropic.mycorp.internal/v1".into()), ..Default::default() };
        let anthropic = ProviderConfig { base_url: Some("https://api.anthropic.com/v1".into()), ..Default::default() };
        assert_eq!(resolve(None, Some(ProviderKind::Anthropic), &gateway, "claude-sonnet-4-5", None), None);
        assert!(resolve(None, Some(ProviderKind::Anthropic), &anthropic, "claude-sonnet-4-5", None).is_some());
        // Retired non-vision Claude families stay blind even first-party.
        assert_eq!(resolve(None, Some(ProviderKind::Anthropic), &anthropic, "claude-2.1", None), None);
        assert_eq!(resolve(None, Some(ProviderKind::Anthropic), &anthropic, "claude-instant-1.2", None), None);
        // A report (vision true) still wins everywhere, regardless of host.
        assert!(resolve(None, Some(ProviderKind::Anthropic), &gateway, "claude-2", Some(&Vision::capable())).is_some());
    }

    #[test]
    fn anthropic_vision_families_match_whole_segments() {
        // Current vision-capable Claude families, including dated snapshots and
        // fine-tune wrappers, are assumed capable on the first-party host.
        for model in [
            "claude-3-opus-20240229",
            "claude-3-5-sonnet-20241022",
            "claude-3-7-sonnet",
            "claude-sonnet-4-5",
            "claude-opus-4-1",
            "claude-haiku-4-5",
            "ft:claude-3-5-sonnet:org::id",
        ] {
            assert!(assumes_anthropic_vision(model), "{model} should be a vision family");
        }
        // Retired non-vision families are blind; a name that merely contains a
        // legacy token as a longer segment is not mistaken for it.
        for model in ["claude-2", "claude-2.1", "claude-instant", "claude-instant-1.2"] {
            assert!(!assumes_anthropic_vision(model), "{model} should be blind");
        }
        for model in ["claude-20-future", "claude-instantish"] {
            assert!(assumes_anthropic_vision(model), "{model} should not be mistaken for a legacy family");
        }
    }

    #[test]
    fn built_in_openai_assumption_is_scoped_to_the_first_party_api() {
        // `ProviderKind::Openai` is shared by every OpenAI-compatible endpoint.
        // A local Ollama/OpenRouter model merely *named* like an OpenAI family
        // must not inherit OpenAI's vision support from the built-in assumption.
        let ollama = ProviderConfig { base_url: Some("http://localhost:11434/v1".into()), ..Default::default() };
        let openrouter = ProviderConfig { base_url: Some("https://openrouter.ai/api/v1".into()), ..Default::default() };
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &ollama, "gpt-5", None), None);
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &openrouter, "gpt-4o", None), None);
        // A reported negative from the endpoint probe is preserved: no probe
        // result (`None`) on a non-first-party endpoint falls through to blind,
        // never re-enabled by the OpenAI family assumption.
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &ollama, "gpt-4o", None), None);
        // The genuine OpenAI API still gets the assumption.
        let openai = ProviderConfig { base_url: Some("https://api.openai.com/v1".into()), ..Default::default() };
        assert!(resolve(None, Some(ProviderKind::Openai), &openai, "gpt-4o", None).is_some());
        // A report (vision true) still wins everywhere, regardless of host.
        assert!(resolve(None, Some(ProviderKind::Openai), &ollama, "gpt-5", Some(&Vision::capable())).is_some());
    }

    #[test]
    fn openai_vision_families_match_whole_segments() {
        // Current vision families, including fine-tune wrappers and dated snapshots.
        for model in [
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-5",
            "gpt-5-mini",
            "o3",
            "o4-mini",
            "ft:gpt-4o-2024-08-06:org::id",
        ] {
            assert!(assumes_openai_vision(model), "{model} should be a vision family");
        }
        // Names that merely contain a family token must not be mistaken for it.
        for model in ["gpt-4o3-custom", "text-embedding-3", "o3pro", "whisper-o4", "ft:gpt-3.5-turbo:org::o3"] {
            assert!(!assumes_openai_vision(model), "{model} should not be a vision family");
        }
    }

    #[test]
    fn dotted_gpt5_revisions_are_vision_families() {
        // The repository already routes dotted GPT-5 revisions (e.g. `gpt-5.6`
        // in github_copilot.rs); on the direct OpenAI provider — which returns
        // no endpoint report — they must not fall through to blind. `.` is a
        // family delimiter alongside `-`, while a digit continuation is not.
        for model in ["gpt-5.1", "gpt-5.6", "gpt-5.6-sol", "ft:gpt-5.1:org::id"] {
            assert!(assumes_openai_vision(model), "{model} should be a vision family");
        }
        assert!(!assumes_openai_vision("gpt-50"), "a digit continuation is not a revision");
        // The text-only carve-out still wins over the bare `o3` family prefix.
        assert!(!assumes_openai_vision("o3-mini"), "o3-mini stays blind");
    }

    #[test]
    fn o3_mini_is_text_only_not_vision() {
        // `o3-mini` and its dated aliases / fine-tune wrappers are blind even
        // though the bare `o3` family prefix would otherwise claim them; full
        // `o3` stays vision-capable.
        for model in ["o3-mini", "o3-mini-2025-01-31", "ft:o3-mini:org::id"] {
            assert!(!assumes_openai_vision(model), "{model} should be blind");
        }
        assert!(assumes_openai_vision("o3"), "full o3 keeps vision");
    }

    #[test]
    fn per_model_override_is_most_specific() {
        let mut provider = ProviderConfig { vision: Some(false), ..Default::default() };
        provider
            .models
            .insert("m".into(), crate::temperature::ModelSettings { vision: Some(true), ..Default::default() });
        let (override_, source) = configured_override(None, &provider, "m");
        assert_eq!(override_, Some(true));
        assert_eq!(source, Source::Model);
        let (override_, source) = configured_override(None, &provider, "other");
        assert_eq!(override_, Some(false));
        assert_eq!(source, Source::Provider);
        let (override_, source) = configured_override(Some(true), &ProviderConfig::default(), "m");
        assert_eq!(override_, Some(true));
        assert_eq!(source, Source::Global);
    }
}
