//! OS sandbox for shell commands: Seatbelt (`sandbox-exec`) on macOS,
//! Landlock on Linux.
//!
//! Commands can read everywhere but write only to the working directory (in
//! `workspace` mode), its git directories, temp directories, package-manager
//! caches and any extra `writable` paths. `read-only` mode allows only temp
//! directories. `network = false` blocks outbound connections (on macOS
//! except to localhost; on Linux all TCP, which needs Linux 6.7+).
//!
//! The sandbox fails closed: if it is enabled but cannot be applied, the
//! command does not run.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SandboxMode {
    #[default]
    Off,
    Workspace,
    ReadOnly,
}

impl SandboxMode {
    pub fn as_str(self) -> &'static str {
        match self {
            SandboxMode::Off => "off",
            SandboxMode::Workspace => "workspace",
            SandboxMode::ReadOnly => "read-only",
        }
    }
}

impl std::str::FromStr for SandboxMode {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "off" | "none" => Ok(SandboxMode::Off),
            "workspace" | "workspace-write" => Ok(SandboxMode::Workspace),
            "read-only" | "readonly" => Ok(SandboxMode::ReadOnly),
            other => Err(format!("unknown sandbox mode {other:?} (expected off, workspace or read-only)")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SandboxConfig {
    pub mode: SandboxMode,
    /// Extra writable paths (`~/` and paths relative to the working directory allowed).
    pub writable: Vec<String>,
    /// Allow outbound network connections.
    pub network: bool,
    /// In `workspace` mode, also allow writes to package-manager caches
    /// (`~/.cargo/registry`, `~/.npm`, `~/.cache`, ...).
    pub tool_caches: bool,
}

impl Default for SandboxConfig {
    fn default() -> Self {
        Self { mode: SandboxMode::Off, writable: Vec::new(), network: true, tool_caches: true }
    }
}

/// Cache directories under `$HOME` that build tools write to.
const TOOL_CACHES: &[&str] = &[
    ".cargo/registry",
    ".cargo/git",
    ".cargo/.package-cache",
    ".cargo/.package-cache-mutate",
    ".cargo/.global-cache",
    ".rustup/tmp",
    ".rustup/downloads",
    ".npm",
    ".cache",
    "Library/Caches",
    ".gradle",
    ".m2/repository",
    "go/pkg/mod",
    ".bun/install/cache",
    ".pnpm-store",
    "Library/pnpm",
    ".local/share/pnpm",
    ".yarn/berry/cache",
    ".deno",
];

const DEVICES: &[&str] = &[
    "/dev/null", "/dev/zero", "/dev/tty", "/dev/stdout", "/dev/stderr", "/dev/ptmx", "/dev/dtracehelper", "/dev/fd",
    "/dev/pts", "/dev/shm",
];

impl SandboxConfig {
    pub fn active(&self) -> bool {
        self.mode != SandboxMode::Off
    }

    /// Canonical paths commands may write to when run in `cwd`.
    pub fn writable_roots(&self, cwd: &Path) -> Vec<PathBuf> {
        let mut roots = Vec::new();
        let home = dirs::home_dir();
        let mut add = |path: PathBuf| {
            if let Ok(real) = path.canonicalize()
                && !roots.contains(&real)
            {
                roots.push(real);
            }
        };
        if self.mode == SandboxMode::Workspace {
            add(cwd.to_path_buf());
            for dir in git_dirs(cwd) {
                add(dir);
            }
            if self.tool_caches
                && let Some(home) = &home
            {
                for cache in TOOL_CACHES {
                    add(home.join(cache));
                }
            }
        }
        let temp = std::env::temp_dir();
        add(temp.clone());
        // macOS per-user temp: $TMPDIR is .../T/; its sibling C/ holds caches.
        if temp.canonicalize().is_ok_and(|t| t.ends_with("T"))
            && let Some(parent) = temp.canonicalize().ok().and_then(|t| t.parent().map(Path::to_path_buf))
        {
            add(parent);
        }
        add(PathBuf::from("/tmp"));
        add(PathBuf::from("/var/tmp"));
        for device in DEVICES {
            add(PathBuf::from(device));
        }
        for extra in &self.writable {
            let path = match (extra.strip_prefix("~/"), &home) {
                (Some(rest), Some(home)) => home.join(rest),
                _ => cwd.join(extra),
            };
            add(path);
        }
        roots
    }

    /// Whether the sandbox would let a command write `path` (for the file tools,
    /// which run in-process).
    pub fn allows_write(&self, path: &Path, cwd: &Path) -> bool {
        if !self.active() {
            return true;
        }
        let path = cwd.join(path);
        // Resolve the deepest existing ancestor, so symlinks cannot escape.
        let mut existing = path.as_path();
        let mut rest = Vec::new();
        let resolved = loop {
            match existing.canonicalize() {
                Ok(real) => break rest.iter().rev().fold(real, |p: PathBuf, part| p.join(part)),
                Err(_) => match (existing.parent(), existing.file_name()) {
                    (Some(parent), Some(name)) => {
                        rest.push(name.to_os_string());
                        existing = parent;
                    }
                    _ => return false,
                },
            }
        };
        self.writable_roots(cwd).iter().any(|root| resolved.starts_with(root))
    }

    /// A short description for messages to the model.
    pub fn describe(&self, cwd: &Path) -> String {
        let roots = self.writable_roots(cwd);
        let shown: Vec<String> = roots
            .iter()
            .filter(|r| !r.starts_with("/dev"))
            .take(6)
            .map(|r| r.display().to_string())
            .collect();
        let more = roots.iter().filter(|r| !r.starts_with("/dev")).count().saturating_sub(shown.len());
        format!(
            "commands run in a {} sandbox: they can write only to {}{}{}",
            self.mode.as_str(),
            shown.join(", "),
            if more > 0 { format!(" and {more} cache directories") } else { String::new() },
            if self.network { "" } else { "; outbound network is blocked" }
        )
    }
}

/// The repository's git directory and, for a worktree, the shared one.
fn git_dirs(cwd: &Path) -> Vec<PathBuf> {
    let Ok(output) = Command::new("git")
        .args(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])
        .current_dir(cwd)
        .stderr(std::process::Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&output.stdout).lines().map(|l| cwd.join(l.trim())).collect()
}

/// A command prepared to run inside the sandbox. Keep it alive until spawned.
pub struct Sandboxed {
    pub command: Command,
    #[cfg(target_os = "linux")]
    _ruleset: std::os::fd::OwnedFd,
}

/// `shell -c script`, sandboxed according to `config`.
pub fn command(config: &SandboxConfig, shell: &str, script: &str, cwd: &Path) -> Result<Sandboxed, String> {
    let roots = config.writable_roots(cwd);
    platform::command(config, &roots, shell, script)
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

    fn quote(path: &Path) -> String {
        let text = path.to_string_lossy();
        format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
    }

    pub fn profile(config: &SandboxConfig, roots: &[PathBuf]) -> String {
        let mut allowed = String::new();
        for root in roots {
            let kind = if root.is_dir() { "subpath" } else { "literal" };
            allowed.push_str(&format!(" ({kind} {})", quote(root)));
        }
        let mut profile = format!(
            "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*{allowed} (regex #\"^/dev/tty\"))\n"
        );
        if !config.network {
            profile.push_str("(deny network-outbound (remote ip))\n(allow network-outbound (remote ip \"localhost:*\"))\n");
        }
        profile
    }

    pub fn command(config: &SandboxConfig, roots: &[PathBuf], shell: &str, script: &str) -> Result<Sandboxed, String> {
        if !Path::new(SANDBOX_EXEC).exists() {
            return Err(format!("sandbox unavailable: {SANDBOX_EXEC} not found"));
        }
        let mut command = Command::new(SANDBOX_EXEC);
        command.arg("-p").arg(profile(config, roots)).arg(shell).arg("-c").arg(script);
        Ok(Sandboxed { command })
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::process::CommandExt;

    const CREATE_RULESET_VERSION: u32 = 1;
    const RULE_PATH_BENEATH: u32 = 1;

    const WRITE_FILE: u64 = 1 << 1;
    const REMOVE_DIR: u64 = 1 << 4;
    const REMOVE_FILE: u64 = 1 << 5;
    const MAKE_CHAR: u64 = 1 << 6;
    const MAKE_DIR: u64 = 1 << 7;
    const MAKE_REG: u64 = 1 << 8;
    const MAKE_SOCK: u64 = 1 << 9;
    const MAKE_FIFO: u64 = 1 << 10;
    const MAKE_BLOCK: u64 = 1 << 11;
    const MAKE_SYM: u64 = 1 << 12;
    const REFER: u64 = 1 << 13;
    const TRUNCATE: u64 = 1 << 14;
    const IOCTL_DEV: u64 = 1 << 15;
    const BIND_TCP: u64 = 1 << 0;
    const CONNECT_TCP: u64 = 1 << 1;

    #[repr(C)]
    struct RulesetAttr {
        handled_access_fs: u64,
        handled_access_net: u64,
    }

    #[repr(C, packed)]
    struct PathBeneathAttr {
        allowed_access: u64,
        parent_fd: i32,
    }

    fn abi() -> i64 {
        // SAFETY: querying the ABI version takes no pointers.
        unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, std::ptr::null::<u8>(), 0usize, CREATE_RULESET_VERSION) }
    }

    /// Build a ruleset in the parent, so the child only needs two syscalls
    /// (safe between fork and exec).
    fn ruleset(config: &SandboxConfig, roots: &[PathBuf]) -> Result<OwnedFd, String> {
        let abi = abi();
        if abi < 1 {
            return Err("sandbox unavailable: this kernel does not support Landlock (Linux 5.13+ with Landlock enabled)".into());
        }
        let mut fs = WRITE_FILE | REMOVE_DIR | REMOVE_FILE | MAKE_CHAR | MAKE_DIR | MAKE_REG | MAKE_SOCK | MAKE_FIFO | MAKE_BLOCK | MAKE_SYM;
        if abi >= 2 {
            fs |= REFER;
        }
        if abi >= 3 {
            fs |= TRUNCATE;
        }
        if abi >= 5 {
            fs |= IOCTL_DEV;
        }
        let net = if config.network {
            0
        } else if abi >= 4 {
            BIND_TCP | CONNECT_TCP
        } else {
            return Err("sandbox unavailable: blocking the network needs Landlock ABI 4 (Linux 6.7+); set network = true".into());
        };
        let attr = RulesetAttr { handled_access_fs: fs, handled_access_net: net };
        let size = if abi >= 4 { std::mem::size_of::<RulesetAttr>() } else { std::mem::size_of::<u64>() };
        // SAFETY: attr outlives the call and size matches the fields the kernel reads.
        let fd = unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, &attr as *const RulesetAttr, size, 0u32) };
        if fd < 0 {
            return Err(format!("sandbox unavailable: landlock_create_ruleset: {}", std::io::Error::last_os_error()));
        }
        // SAFETY: the kernel returned a new file descriptor that we now own.
        let ruleset = unsafe { OwnedFd::from_raw_fd(fd as i32) };
        for root in roots {
            let Ok(path) = CString::new(root.as_os_str().as_bytes()) else { continue };
            // SAFETY: path is a valid C string.
            let raw = unsafe { libc::open(path.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
            if raw < 0 {
                continue;
            }
            // SAFETY: open returned a new descriptor that we now own.
            let parent = unsafe { OwnedFd::from_raw_fd(raw) };
            let access = if root.is_dir() { fs } else { fs & (WRITE_FILE | TRUNCATE | IOCTL_DEV) };
            let rule = PathBeneathAttr { allowed_access: access, parent_fd: parent.as_raw_fd() };
            // SAFETY: rule outlives the call; both descriptors are open.
            let status = unsafe {
                libc::syscall(libc::SYS_landlock_add_rule, ruleset.as_raw_fd(), RULE_PATH_BENEATH, &rule as *const PathBeneathAttr, 0u32)
            };
            if status < 0 {
                return Err(format!("sandbox: landlock_add_rule {}: {}", root.display(), std::io::Error::last_os_error()));
            }
        }
        Ok(ruleset)
    }

    pub fn command(config: &SandboxConfig, roots: &[PathBuf], shell: &str, script: &str) -> Result<Sandboxed, String> {
        let ruleset = ruleset(config, roots)?;
        let fd = ruleset.as_raw_fd();
        let mut command = Command::new(shell);
        command.arg("-c").arg(script);
        // SAFETY: the closure only makes async-signal-safe syscalls.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::syscall(libc::SYS_landlock_restrict_self, fd, 0u32) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        Ok(Sandboxed { command, _ruleset: ruleset })
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::*;

    pub fn command(_: &SandboxConfig, _: &[PathBuf], _: &str, _: &str) -> Result<Sandboxed, String> {
        Err("sandbox unavailable on this platform".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(config: &SandboxConfig, cwd: &Path, script: &str) -> (bool, String) {
        let mut sandboxed = command(config, "bash", script, cwd).expect("sandbox available");
        let output = sandboxed.command.current_dir(cwd).output().unwrap();
        let text = format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        (output.status.success(), text)
    }

    /// A directory outside the temp dirs (which the sandbox always allows).
    fn outside_dir() -> tempfile::TempDir {
        let base = std::env::current_dir().unwrap().join("target");
        std::fs::create_dir_all(&base).unwrap();
        tempfile::tempdir_in(base).unwrap()
    }

    #[test]
    fn parses_modes() {
        assert_eq!("workspace".parse::<SandboxMode>().unwrap(), SandboxMode::Workspace);
        assert_eq!("read-only".parse::<SandboxMode>().unwrap(), SandboxMode::ReadOnly);
        assert!("nope".parse::<SandboxMode>().is_err());
        let config: SandboxConfig = toml::from_str("mode = \"read-only\"\nnetwork = false").unwrap();
        assert_eq!(config.mode, SandboxMode::ReadOnly);
        assert!(!config.network && config.tool_caches);
    }

    #[test]
    fn workspace_mode_confines_writes() {
        let workspace = outside_dir();
        let other = outside_dir();
        let config = SandboxConfig { mode: SandboxMode::Workspace, tool_caches: false, ..Default::default() };
        let victim = other.path().join("keep.txt");
        std::fs::write(&victim, "data").unwrap();
        let script = format!(
            "echo hi > inside.txt && mkdir -p sub && echo ok > \"${{TMPDIR:-/tmp}}\"/nano-sbx-$$ && rm -f \"${{TMPDIR:-/tmp}}\"/nano-sbx-$$ \
             && echo x > /dev/null && echo wrote-inside; rm -f {v}; echo x > {o}/new.txt; true",
            v = victim.display(),
            o = other.path().display()
        );
        let (_, text) = run(&config, workspace.path(), &script);
        assert!(text.contains("wrote-inside"), "{text}");
        assert!(workspace.path().join("inside.txt").exists());
        assert!(victim.exists(), "sandboxed rm deleted a file outside the workspace: {text}");
        assert!(!other.path().join("new.txt").exists(), "{text}");
        assert!(config.allows_write(Path::new("inside.txt"), workspace.path()));
        assert!(config.allows_write(Path::new("new/dir/file"), workspace.path()));
        assert!(!config.allows_write(&victim, workspace.path()));
        assert!(!config.allows_write(Path::new("../x"), workspace.path()));
    }

    #[test]
    fn read_only_mode_blocks_workspace_writes() {
        let workspace = outside_dir();
        let config = SandboxConfig { mode: SandboxMode::ReadOnly, ..Default::default() };
        let (_, text) = run(&config, workspace.path(), "echo hi > inside.txt; ls >/dev/null && echo listed");
        assert!(text.contains("listed"), "{text}");
        assert!(!workspace.path().join("inside.txt").exists(), "{text}");
        assert!(!config.allows_write(Path::new("inside.txt"), workspace.path()));
    }

    #[test]
    fn extra_writable_paths() {
        let workspace = outside_dir();
        let extra = outside_dir();
        let config = SandboxConfig {
            mode: SandboxMode::ReadOnly,
            writable: vec![extra.path().display().to_string()],
            ..Default::default()
        };
        let (ok, text) = run(&config, workspace.path(), &format!("echo hi > {}/f.txt", extra.path().display()));
        assert!(ok, "{text}");
        assert!(extra.path().join("f.txt").exists());
    }
}
