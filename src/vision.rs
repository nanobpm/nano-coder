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
/// Anthropic / OpenAI model families. Returns `None` when the model cannot see
/// images.
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
    // providers whose model families we actually know. `ProviderKind::Openai`
    // is shared by every OpenAI-compatible endpoint (Ollama, llama.cpp,
    // OpenRouter, Groq, …); a local model merely *named* `gpt-5` there is not an
    // OpenAI model and must not inherit OpenAI's vision support — especially
    // when its own endpoint probe reported no vision.
    match kind {
        Some(ProviderKind::Anthropic) => Some(Vision::capable()),
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

/// Whether an OpenAI-direct model name is a current vision-capable family.
///
/// Families are matched as whole, delimited name segments rather than bare
/// substrings, so a name that merely *contains* a family token (e.g.
/// `gpt-4o3-custom`, or an `o3` appearing in a fine-tune suffix) is not
/// mistaken for it. A model is a family member when, after stripping an
/// optional `ft:<base>:…` fine-tune wrapper down to its base, the base either
/// equals the family token or continues with a `-` (e.g. `o4-mini`,
/// `gpt-4o-2024-08-06`).
fn assumes_openai_vision(model: &str) -> bool {
    let m = model.to_lowercase();
    // `ft:<base>:<org>::<id>` → `<base>`; a plain name is its own base.
    let base = m.strip_prefix("ft:").map_or(m.as_str(), |rest| rest.split(':').next().unwrap_or(rest));
    const FAMILIES: [&str; 5] = ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4"];
    FAMILIES.iter().any(|family| match base.strip_prefix(family) {
        Some(rest) => rest.is_empty() || rest.starts_with('-'),
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
        // Configured false blinds even an Anthropic model.
        assert_eq!(resolve(Some(false), Some(ProviderKind::Anthropic), &provider, "claude-sonnet-4-5", None), None);
        // Configured true enables a model the endpoint said nothing about.
        assert!(resolve(Some(true), Some(ProviderKind::Openai), &provider, "some-local", None).is_some());
        // No override: Anthropic assumed capable, the OpenAI family on the
        // first-party OpenAI API assumed capable, a non-family OpenAI model not.
        assert!(resolve(None, Some(ProviderKind::Anthropic), &provider, "claude-sonnet-4-5", None).is_some());
        assert!(resolve(None, Some(ProviderKind::Openai), &openai_direct, "gpt-5-mini", None).is_some());
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &openai_direct, "text-embedding-3", None), None);
        assert_eq!(resolve(None, None, &provider, "m", None), None);
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
            "o3-mini",
            "o4-mini",
            "ft:gpt-4o-2024-08-06:org::id",
            "ft:o3-mini:org::id",
        ] {
            assert!(assumes_openai_vision(model), "{model} should be a vision family");
        }
        // Names that merely contain a family token must not be mistaken for it.
        for model in ["gpt-4o3-custom", "text-embedding-3", "o3pro", "whisper-o4", "ft:gpt-3.5-turbo:org::o3"] {
            assert!(!assumes_openai_vision(model), "{model} should not be a vision family");
        }
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
