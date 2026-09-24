//! Project instruction files (AGENTS.md and friends).
//!
//! At session start the files from the git root down to the working
//! directory are added to the system prompt, outermost first, so the model
//! has them before it makes any change. Files in deeper directories are
//! attached to the first file-tool result that touches those directories.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Per-file cap; longer files are truncated with a note.
const MAX_FILE_BYTES: usize = 32 * 1024;
/// Cap on everything added to the system prompt.
const MAX_TOTAL_BYTES: usize = 64 * 1024;

pub const DEFAULT_FILES: [&str; 3] = ["AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"];

#[derive(Debug, Clone, PartialEq)]
pub struct InstructionFile {
    pub path: PathBuf,
    pub text: String,
}

#[derive(Debug, Default)]
pub struct ProjectInstructions {
    /// Git root (or the working directory outside a repository).
    root: PathBuf,
    /// File names tried in each directory; the first that exists is used.
    names: Vec<String>,
    /// Files in the system prompt.
    pub loaded: Vec<InstructionFile>,
    /// Directories already searched (root..=cwd, plus nested ones seen).
    searched: HashSet<PathBuf>,
    /// Directories searched at session start (kept across compaction).
    initial: HashSet<PathBuf>,
}

pub(crate) fn git_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|dir| dir.join(".git").exists()).map(Path::to_path_buf)
}

fn read_capped(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if text.len() <= MAX_FILE_BYTES {
        return Some(text.to_string());
    }
    let mut end = MAX_FILE_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Some(format!("{}\n\n[... truncated: {} of {} bytes shown]", &text[..end], end, text.len()))
}

impl ProjectInstructions {
    /// Find the instruction files that apply to `cwd`.
    pub fn discover(cwd: &Path, names: &[String]) -> Self {
        let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
        let root = git_root(&cwd).unwrap_or_else(|| cwd.clone());
        let mut this = Self { root, names: names.to_vec(), ..Default::default() };
        let mut dirs: Vec<PathBuf> = cwd.ancestors().take_while(|d| d.starts_with(&this.root)).map(Path::to_path_buf).collect();
        dirs.reverse();
        for dir in dirs {
            if let Some(file) = this.search(&dir) {
                this.loaded.push(file);
            }
        }
        this.initial = this.searched.clone();
        this
    }

    fn search(&mut self, dir: &Path) -> Option<InstructionFile> {
        if !self.searched.insert(dir.to_path_buf()) {
            return None;
        }
        self.names.iter().find_map(|name| {
            let path = dir.join(name);
            read_capped(&path).map(|text| InstructionFile { path, text })
        })
    }

    fn display(&self, path: &Path) -> String {
        path.strip_prefix(&self.root).unwrap_or(path).display().to_string()
    }

    /// Text appended to the system prompt (empty when nothing was found).
    pub fn render(&self) -> String {
        if self.loaded.is_empty() {
            return String::new();
        }
        let mut out = String::from(
            "\n\n# Repository instructions\n\nThese instruction files come from the repository you are working in. \
             Read and follow them before and while making changes. Files in deeper directories refine the \
             ones above them.",
        );
        let mut budget = MAX_TOTAL_BYTES;
        for file in &self.loaded {
            let section = format!("\n\n## {}\n\n{}", self.display(&file.path), file.text);
            if section.len() > budget {
                out.push_str(&format!("\n\n## {}\n\n[omitted: instruction size limit reached; read it with read_file]", self.display(&file.path)));
                continue;
            }
            budget -= section.len();
            out.push_str(&section);
        }
        out
    }

    /// Instruction files for directories between `path` and the root that
    /// have not been seen yet, outermost first, rendered for a tool result.
    pub fn nested_for(&mut self, path: &Path) -> Option<String> {
        let absolute = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().ok()?.join(path) };
        let absolute = canonicalize_existing(&absolute);
        let dir = if absolute.is_dir() { absolute.as_path() } else { absolute.parent()? };
        let mut dirs: Vec<PathBuf> = dir.ancestors().take_while(|d| d.starts_with(&self.root)).map(Path::to_path_buf).collect();
        if dirs.is_empty() {
            return None;
        }
        dirs.reverse();
        let files: Vec<InstructionFile> = dirs.iter().filter_map(|d| self.search(d)).collect();
        if files.is_empty() {
            return None;
        }
        let mut out = String::new();
        for file in files {
            let scope = file.path.parent().map(|p| self.display(p)).unwrap_or_default();
            out.push_str(&format!(
                "\n\n[Instructions from {} apply to files under {}/. Follow them for changes there:]\n{}",
                self.display(&file.path),
                if scope.is_empty() { "." } else { &scope },
                file.text
            ));
        }
        Some(out)
    }

    /// After compaction, nested instructions attached to old tool results may
    /// be gone: let them be attached again.
    pub fn forget_nested(&mut self) {
        self.searched = self.initial.clone();
    }

    pub fn loaded_paths(&self) -> Vec<String> {
        self.loaded.iter().map(|f| f.path.display().to_string()).collect()
    }
}

/// Canonicalize the longest existing prefix of `path`, so files that do not
/// exist yet (about to be written) still resolve symlinked roots.
fn canonicalize_existing(path: &Path) -> PathBuf {
    for base in path.ancestors() {
        if let Ok(real) = base.canonicalize() {
            return match path.strip_prefix(base) {
                Ok(rest) if !rest.as_os_str().is_empty() => real.join(rest),
                _ => real,
            };
        }
    }
    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names() -> Vec<String> {
        DEFAULT_FILES.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn loads_root_to_leaf_with_fallbacks_and_nested_files_once() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("app/web/src")).unwrap();
        std::fs::create_dir_all(root.join("lib/core")).unwrap();
        std::fs::create_dir_all(root.join(".github")).unwrap();
        std::fs::write(root.join(".github/copilot-instructions.md"), "root copilot").unwrap();
        std::fs::write(root.join("app/CLAUDE.md"), "app claude").unwrap();
        std::fs::write(root.join("app/AGENTS.md"), "app agents").unwrap();
        std::fs::write(root.join("lib/AGENTS.md"), "lib rules").unwrap();
        std::fs::write(root.join("lib/core/AGENTS.md"), "   ").unwrap();

        let mut instructions = ProjectInstructions::discover(&root.join("app/web"), &names());
        let texts: Vec<&str> = instructions.loaded.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts, ["root copilot", "app agents"]);
        let rendered = instructions.render();
        assert!(rendered.find("root copilot").unwrap() < rendered.find("app agents").unwrap());
        assert!(rendered.contains("## app/AGENTS.md"));

        assert_eq!(instructions.nested_for(&root.join("app/web/src/main.rs")), None);
        let nested = instructions.nested_for(&root.join("lib/core/x.rs")).unwrap();
        assert!(nested.contains("lib/AGENTS.md apply to files under lib/") && nested.contains("lib rules"));
        assert_eq!(instructions.nested_for(&root.join("lib/y.rs")), None);
        instructions.forget_nested();
        assert!(instructions.nested_for(&root.join("lib/y.rs")).is_some());
        assert_eq!(instructions.nested_for(Path::new("/elsewhere/file")), None);
    }

    #[test]
    fn outside_a_repository_only_the_working_directory_counts() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::write(dir.path().join("AGENTS.md"), "parent").unwrap();
        std::fs::write(cwd.join("AGENTS.md"), "x".repeat(MAX_FILE_BYTES + 10)).unwrap();
        let instructions = ProjectInstructions::discover(&cwd, &names());
        assert_eq!(instructions.loaded.len(), 1);
        assert!(instructions.loaded[0].text.contains("[... truncated"));
    }
}

