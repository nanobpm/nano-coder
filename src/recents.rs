//! Recently used `provider/model` specs, persisted as JSON in the app data
//! dir. The `/model` type-ahead hoists them to the top of the suggestion
//! list, so the models actually switched to lately are the first completions
//! offered. Best-effort: a corrupt or unreadable file just starts empty.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::providers::{self, ProviderConfig};

pub const MAX_RECENTS: usize = 8;

/// The on-disk format version stamped into `recent-models.json`. Bumped when
/// the stored representation changes so a one-time migration can run exactly
/// once. Version 1 stores every entry in canonical `provider/model` form.
pub const FORMAT_VERSION: u32 = 1;

/// The version assumed for a file that predates the marker (a legacy file
/// written before `version` existed): serde fills a missing `version` with
/// this, marking it as needing the one-time canonicalization migration.
fn legacy_version() -> u32 {
    0
}

/// Canonicalize `spec` to `provider/model` (or a bare `provider`) with the
/// same rules the rest of the app parses model specs by, so a slash-containing
/// default-provider model ID (`meta-llama/llama-4` on `together`) is stored
/// with its real provider prefix (`together/meta-llama/llama-4`) instead of
/// being mistaken for a `meta-llama` provider. Recording the canonical spec is
/// what lets a later provider removal be told apart from a model ID that merely
/// contains a slash: a genuinely removed provider's prefix no longer resolves,
/// while a default-provider model keeps a configured prefix.
pub fn canonical(spec: &str, all: &BTreeMap<String, ProviderConfig>, default_provider: &str) -> String {
    let (provider, model) = providers::parse_model_spec(spec, all, default_provider);
    // A provider-only spec (`work`) is resolved to that provider's configured
    // default model (`work/foo`) while the provider metadata is still
    // available. Storing the slash form lets a later removal of `work` be told
    // apart from a bare model literally named `work`: the `work/` prefix stops
    // resolving so the entry is skipped, instead of being offered as a model on
    // the default provider. A provider with no default model stays bare.
    let model = model
        .map(str::to_string)
        .or_else(|| all.get(provider).and_then(|p| p.default_model.clone()).filter(|m| !m.is_empty()));
    match model {
        Some(model) => format!("{provider}/{model}"),
        None => provider.to_string(),
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Recents {
    /// On-disk format version (see [`FORMAT_VERSION`]). A file missing this
    /// field is a legacy file (`legacy_version`), triggering the one-time
    /// canonicalization migration.
    #[serde(default = "legacy_version")]
    version: u32,
    /// Most recently used first.
    models: Vec<String>,
}

impl Default for Recents {
    fn default() -> Self {
        // A freshly created (in-memory) list is already in the current format,
        // so it never triggers the legacy migration.
        Self { version: FORMAT_VERSION, models: Vec::new() }
    }
}

pub type SharedRecents = Arc<Mutex<Recents>>;

impl Recents {
    pub fn models(&self) -> &[String] {
        &self.models
    }

    /// Record a successful switch to `spec`: it becomes the most recent, and
    /// any older copy moves with it (no duplicates).
    pub fn record(&mut self, spec: &str) {
        let spec = spec.trim();
        if spec.is_empty() {
            return;
        }
        self.models.retain(|m| m != spec);
        self.models.insert(0, spec.to_string());
        self.models.truncate(MAX_RECENTS);
    }

    /// Migrate a legacy file's entries to canonical `provider/model` form (see
    /// [`canonical`]), exactly once. A `recent-models.json` written by a
    /// released version recorded the raw model spec, so a default-provider
    /// entry like `meta-llama/llama-4` would be mistaken for a `meta-llama`
    /// provider and hidden by the picker's filter after upgrade. Rewriting the
    /// loaded list once — de-duplicating any entries that now collapse to the
    /// same spec, most-recent-first — preserves the existing MRU this feature
    /// reuses.
    ///
    /// Gated on the persisted [`FORMAT_VERSION`] marker so it runs only on a
    /// legacy file, **not** on every load: re-canonicalizing an
    /// already-canonical entry is lossy, because a stored `work/foo` whose
    /// `work` provider was later removed is indistinguishable from a bare model
    /// literally named `work/foo` and would be reinterpreted onto the default
    /// provider (offered instead of skipped). Returns `true` when it migrated,
    /// so the caller can persist the upgraded representation and its marker.
    pub fn canonicalize(&mut self, all: &BTreeMap<String, ProviderConfig>, default_provider: &str) -> bool {
        if self.version >= FORMAT_VERSION {
            return false;
        }
        let mut seen = std::collections::HashSet::new();
        self.models = std::mem::take(&mut self.models)
            .into_iter()
            .map(|spec| canonical(&spec, all, default_provider))
            .filter(|spec| !spec.is_empty() && seen.insert(spec.clone()))
            .collect();
        self.models.truncate(MAX_RECENTS);
        self.version = FORMAT_VERSION;
        true
    }
}

pub fn default_path() -> PathBuf {
    crate::config::app_dir(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)).join("recent-models.json")
}

pub fn load(path: &Path) -> Recents {
    let Ok(bytes) = std::fs::read(path) else { return Recents::default() };
    let mut recents: Recents = serde_json::from_slice(&bytes).unwrap_or_default();
    recents.models.truncate(MAX_RECENTS);
    recents
}

/// Write the list, creating the parent directory. Errors are swallowed: a
/// lost recents file is a minor convenience, not a failure.
pub fn save(path: &Path, recents: &Recents) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(recents) {
        let _ = std::fs::write(path, bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_prefixes_the_real_provider() {
        let all: BTreeMap<String, ProviderConfig> =
            ["openai", "together", "ollama"].iter().map(|n| (n.to_string(), ProviderConfig::default())).collect();
        // A slash-containing bare model on the default provider keeps that
        // provider, rather than being read as a `meta-llama` provider.
        assert_eq!(canonical("meta-llama/llama-4", &all, "together"), "together/meta-llama/llama-4");
        // A bare model gains its default provider; an explicit spec is unchanged.
        assert_eq!(canonical("gpt-4o", &all, "openai"), "openai/gpt-4o");
        assert_eq!(canonical("openai/gpt-4o", &all, "openai"), "openai/gpt-4o");
        // A bare provider name stays as-is (it means "the provider's default model").
        assert_eq!(canonical("ollama", &all, "openai"), "ollama");
    }

    #[test]
    fn canonical_expands_a_provider_only_spec_to_its_default_model() {
        let mut all: BTreeMap<String, ProviderConfig> = BTreeMap::new();
        all.insert("openai".to_string(), ProviderConfig::default());
        all.insert(
            "work".to_string(),
            ProviderConfig { default_model: Some("foo".to_string()), ..ProviderConfig::default() },
        );
        // A provider with a default model is expanded, so a later removal of
        // `work` is skipped by the filter instead of switching to a `work` model.
        assert_eq!(canonical("work", &all, "openai"), "work/foo");
        // A provider without a default model stays bare.
        assert_eq!(canonical("openai", &all, "work"), "openai");
    }

    #[test]
    fn canonicalize_migrates_a_legacy_raw_list() {
        let all: BTreeMap<String, ProviderConfig> =
            ["openai", "together"].iter().map(|n| (n.to_string(), ProviderConfig::default())).collect();
        let mut recents = Recents { version: 0, models: vec!["meta-llama/llama-4".to_string(), "gpt-4o".to_string()] };
        recents.canonicalize(&all, "together");
        // The default-provider slash spec gains its real prefix (so it is no
        // longer hidden); the bare model gains its default provider.
        assert_eq!(recents.models(), &["together/meta-llama/llama-4", "together/gpt-4o"]);
    }

    #[test]
    fn canonicalize_dedupes_collapsed_entries_keeping_order() {
        let all: BTreeMap<String, ProviderConfig> =
            ["openai"].iter().map(|n| (n.to_string(), ProviderConfig::default())).collect();
        // `gpt-4o` and `openai/gpt-4o` both canonicalize to `openai/gpt-4o`.
        let mut recents = Recents { version: 0, models: vec!["gpt-4o".to_string(), "openai/gpt-4o".to_string()] };
        recents.canonicalize(&all, "openai");
        assert_eq!(recents.models(), &["openai/gpt-4o"]);
    }

    #[test]
    fn canonicalize_runs_once_and_leaves_canonical_files_untouched() {
        // A file already at the current format is never re-canonicalized. This
        // matters once a provider is removed: a stored `work/foo` (canonical,
        // provider `work` now gone) must be left verbatim for the picker's
        // filter to skip, not reinterpreted as a bare model on the default
        // provider (`openai/work/foo`) and offered.
        let all: BTreeMap<String, ProviderConfig> =
            ["openai"].iter().map(|n| (n.to_string(), ProviderConfig::default())).collect();
        let mut recents = Recents { version: FORMAT_VERSION, models: vec!["work/foo".to_string()] };
        assert!(!recents.canonicalize(&all, "openai"), "an up-to-date file is not migrated");
        assert_eq!(recents.models(), &["work/foo"], "the removed-provider entry is preserved verbatim");

        // A legacy file is migrated exactly once: the second pass is a no-op
        // because the first stamped the current version marker.
        let mut legacy = Recents { version: 0, models: vec!["gpt-4o".to_string()] };
        assert!(legacy.canonicalize(&all, "openai"), "a legacy file migrates");
        assert_eq!(legacy.models(), &["openai/gpt-4o"]);
        assert!(!legacy.canonicalize(&all, "openai"), "already migrated, so the second pass is a no-op");
    }

    #[test]
    fn record_moves_to_front_without_duplicates_and_caps() {
        let mut recents = Recents::default();
        recents.record("openai/gpt-4o");
        recents.record("ollama/qwen3");
        recents.record("openai/gpt-4o");
        assert_eq!(recents.models(), &["openai/gpt-4o", "ollama/qwen3"]);
        for i in 0..20 {
            recents.record(&format!("p/m{i}"));
        }
        assert_eq!(recents.models().len(), MAX_RECENTS);
        assert_eq!(recents.models()[0], "p/m19");
        assert!(!recents.models().contains(&"openai/gpt-4o".to_string()));
    }

    #[test]
    fn switching_records_the_previous_model_just_behind_the_new_one() {
        // How `/model` records a switch from `previous` to `spec`.
        let mut recents = Recents::default();
        let switch = |recents: &mut Recents, previous: &str, spec: &str| {
            recents.record(previous);
            recents.record(spec);
        };
        switch(&mut recents, "start/model", "a/one");
        assert_eq!(recents.models(), ["a/one", "start/model"], "the startup model is offered too");
        switch(&mut recents, "a/one", "b/two");
        switch(&mut recents, "b/two", "start/model");
        assert_eq!(recents.models(), ["start/model", "b/two", "a/one"], "no duplicates; previous is second");
    }

    #[test]
    fn record_ignores_blank_and_trims() {
        let mut recents = Recents::default();
        recents.record("   ");
        recents.record("  ollama/qwen3  ");
        assert_eq!(recents.models(), &["ollama/qwen3"]);
    }

    #[test]
    fn load_tolerates_missing_and_corrupt_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/recent-models.json");
        assert_eq!(load(&path), Recents::default(), "missing file starts empty");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"not json").unwrap();
        assert_eq!(load(&path), Recents::default(), "corrupt file starts empty");
    }

    #[test]
    fn save_then_load_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/recent-models.json");
        let mut recents = Recents::default();
        recents.record("openai/gpt-4o");
        recents.record("ollama/qwen3");
        save(&path, &recents);
        assert_eq!(load(&path), recents);
    }
}
