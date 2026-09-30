//! Recently used `provider/model` specs, persisted as JSON in the app data
//! dir. The `/model` type-ahead hoists them to the top of the suggestion
//! list, so the models actually switched to lately are the first completions
//! offered. Best-effort: a corrupt or unreadable file just starts empty.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const MAX_RECENTS: usize = 8;

#[derive(Debug, Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Recents {
    /// Most recently used first.
    models: Vec<String>,
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
