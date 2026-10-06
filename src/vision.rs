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
        let max_images = limits
            .and_then(|v| v.get("max_prompt_images"))
            .and_then(serde_json::Value::as_u64)
            .filter(|&n| n > 0)
            .map(|n| n as usize)
            .unwrap_or(1);
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
    // Anthropic and OpenAI direct: assume current model families see images.
    match kind {
        Some(ProviderKind::Anthropic) => Some(Vision::capable()),
        Some(ProviderKind::Openai) if assumes_openai_vision(model) => Some(Vision::capable()),
        _ => None,
    }
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

        // No vision support, or a zero image count, means blind.
        assert_eq!(Vision::from_model_entry(&json!({ "capabilities": { "supports": {} } })), None);
        assert_eq!(
            Vision::from_model_entry(
                &json!({ "capabilities": { "supports": { "vision": true }, "limits": { "vision": { "max_prompt_images": 0 } } } })
            )
            .unwrap()
            .max_images,
            1
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
        // Configured false blinds even an Anthropic model.
        assert_eq!(resolve(Some(false), Some(ProviderKind::Anthropic), &provider, "claude-sonnet-4-5", None), None);
        // Configured true enables a model the endpoint said nothing about.
        assert!(resolve(Some(true), Some(ProviderKind::Openai), &provider, "some-local", None).is_some());
        // No override: Anthropic assumed capable, unknown OpenAI-compatible not.
        assert!(resolve(None, Some(ProviderKind::Anthropic), &provider, "claude-sonnet-4-5", None).is_some());
        assert!(resolve(None, Some(ProviderKind::Openai), &provider, "gpt-5-mini", None).is_some());
        assert_eq!(resolve(None, Some(ProviderKind::Openai), &provider, "text-embedding-3", None), None);
        assert_eq!(resolve(None, None, &provider, "m", None), None);
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
