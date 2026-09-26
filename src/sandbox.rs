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

/// Individual device *nodes* commands routinely need for I/O. Granting one adds
/// only that single node (a file, not a subtree), so they are safe in every mode.
const DEVICE_NODES: &[&str] =
    &["/dev/null", "/dev/zero", "/dev/tty", "/dev/stdout", "/dev/stderr", "/dev/ptmx", "/dev/dtracehelper"];

/// Device *directory* granted as a whole subtree. Only `/dev/fd` qualifies:
/// its entries are symlinks to the process's *own* already-open file
/// descriptors, so `> /dev/fd/N` writes to an existing fd and cannot create new
/// host files. `/dev/pts` (other sessions' terminals) and `/dev/shm` (a
/// host-shared tmpfs any process can read and write) are deliberately excluded:
/// they are shared/device-backed trees outside the workspace, so a recursive
/// grant would let even a workspace-mode sandbox write far past its boundary. A
/// caller that genuinely needs one can grant it explicitly via `writable`.
const DEVICE_DIRS: &[&str] = &["/dev/fd"];

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
            // A `cwd` of `/` would grant the entire host filesystem as a writable
            // subtree; refuse to treat the filesystem root as a workspace write root
            // and fail closed (the temp roots below remain available).
            if cwd != Path::new("/") {
                add(cwd.to_path_buf());
            }
            let cwd_real = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
            let dirs = git_dirs(cwd);
            // A linked worktree's `--git-dir` (`<common>/worktrees/<name>`) and
            // `--git-common-dir` (the *main* checkout's git dir) live under the main
            // repository, which is normally a *sibling* of this worktree — so neither
            // `within` nor `ancestor_repo` holds and a naive check drops them, which
            // then makes a workspace sandbox reject the `git commit` that must update
            // the worktree's metadata and shared refs. Accept them when git ties the
            // worktree back to `cwd`: the per-worktree git dir carries a `gitdir`
            // back-pointer resolving into `cwd`.
            let is_worktree_of_cwd =
                dirs.iter().filter_map(|d| d.canonicalize().ok()).any(|real| worktree_backpointer_within(&real, &cwd_real));
            for dir in dirs {
                // `git rev-parse` output is influenced by a `.git` *file* in the
                // workspace: a poisoned worktree pointer can name a git directory
                // belonging to an unrelated repository outside `cwd`. Only grant a git
                // dir whose real path is inside the workspace, whose repository root
                // (its parent) contains the workspace (a normal repo entered from a
                // subdirectory), or that git has tied back to this worktree above. A
                // poisoned pointer to an external repo satisfies none of these and is
                // dropped rather than handed write access.
                let Ok(real) = dir.canonicalize() else { continue };
                let within = real.starts_with(&cwd_real);
                let ancestor_repo = real.parent().is_some_and(|repo| cwd_real.starts_with(repo));
                if within || ancestor_repo || is_worktree_of_cwd {
                    add(dir);
                }
            }
            if self.tool_caches
                && let Some(home) = &home
            {
                let home_real = home.canonicalize().ok();
                for cache in TOOL_CACHES {
                    // A tool cache is an explicit grant when `tool_caches` is set, but
                    // in a clean home the directory may not exist yet; create it so
                    // `canonicalize()` succeeds and the package manager can populate it,
                    // rather than silently dropping the grant.
                    let path = home.join(cache);
                    if !path.exists() {
                        let _ = std::fs::create_dir_all(&path);
                    }
                    // A cache parent that is a symlink escaping home (e.g. `~/.cache`
                    // -> `/`) would canonicalize to a root outside home and grant far
                    // more than the intended cache subtree — in the worst case the
                    // entire filesystem. Only grant the cache when its real path stays
                    // under the real home directory and is not the filesystem root
                    // itself; fail closed otherwise.
                    if let Ok(real) = path.canonicalize()
                        && real != Path::new("/")
                        && home_real.as_ref().is_some_and(|h| real.starts_with(h))
                    {
                        add(real);
                    }
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
        for device in DEVICE_NODES {
            add(PathBuf::from(device));
        }
        // Directory devices grant write access to their whole subtree, so only
        // expose them when the sandbox already allows workspace writes.
        if self.mode == SandboxMode::Workspace {
            for device in DEVICE_DIRS {
                add(PathBuf::from(device));
            }
        }
        for extra in &self.writable {
            // A `~/`-prefixed or absolute extra is a deliberate operator choice to
            // grant a specific out-of-workspace path. A *relative* extra, however, is
            // meant to name a subdirectory of the workspace, so a symlink in its path
            // (e.g. `writable = ["build"]` with `build` -> `/`) that escapes `cwd` must
            // not silently widen the grant to the whole filesystem.
            let relative = extra.strip_prefix("~/").is_none() && !Path::new(extra).is_absolute();
            let path = match (extra.strip_prefix("~/"), &home) {
                (Some(rest), Some(home)) => home.join(rest),
                _ => cwd.join(extra),
            };
            // A configured writable path is an explicit grant, so create it when it does
            // not exist yet; otherwise `canonicalize()` fails and the grant is dropped.
            if !path.exists() {
                let _ = std::fs::create_dir_all(&path);
            }
            if relative {
                // Only grant a relative extra when its real path stays inside the
                // workspace and is not the filesystem root itself; fail closed otherwise.
                let cwd_real = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
                if let Ok(real) = path.canonicalize()
                    && real != Path::new("/")
                    && real.starts_with(&cwd_real)
                {
                    add(real);
                }
            } else {
                add(path);
            }
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

/// Whether `git_dir` is the per-worktree git directory of the worktree rooted at
/// `cwd_real`. A linked worktree's `<common>/worktrees/<name>` directory holds a
/// `gitdir` file naming that worktree's own `.git` link; its parent is the
/// worktree root. Confirming the back-pointer resolves to `cwd` proves the git dir
/// genuinely belongs to this worktree, rather than being a poisoned `.git` pointer
/// aimed at an unrelated repository.
fn worktree_backpointer_within(git_dir: &Path, cwd_real: &Path) -> bool {
    let Ok(content) = std::fs::read_to_string(git_dir.join("gitdir")) else {
        return false;
    };
    Path::new(content.trim())
        .parent()
        .and_then(|root| root.canonicalize().ok())
        .is_some_and(|root| root == cwd_real)
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
            // Writable roots are listed literally in `{allowed}` (which already
            // includes the `/dev/tty` device node); do not add a broad `^/dev/tty`
            // regex, which would also grant serial/USB nodes like `/dev/ttyS0`.
            "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*{allowed})\n"
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
        // Without `REFER` (Landlock ABI 2, Linux 5.19+) cross-directory rename/link
        // operations are not confined, and without `TRUNCATE` (Landlock ABI 3, Linux
        // 6.2+) a truncate can still shrink/clobber files outside the allowed roots.
        // Either hole lets a workspace-sandboxed command escape the write boundary,
        // so require ABI 3 and fail closed on older kernels rather than leave it open.
        if abi < 3 {
            return Err("sandbox unavailable: enforcing the write boundary needs Landlock ABI 3 (Linux 6.2+); on older kernels cross-directory renames and file truncation cannot be confined".into());
        }
        let mut fs = WRITE_FILE | REMOVE_DIR | REMOVE_FILE | MAKE_CHAR | MAKE_DIR | MAKE_REG | MAKE_SOCK | MAKE_FIFO | MAKE_BLOCK | MAKE_SYM;
        if abi >= 2 {
            fs |= REFER;
        }
        if abi >= 3 {
            fs |= TRUNCATE;
        }
        // `IOCTL_DEV` (Landlock ABI 5, Linux 6.10+) is the only right that confines
        // device ioctls. On ABI 3/4 it does not exist, so device ioctls are *not*
        // mediated by Landlock at all: a command may open a device and issue a
        // mutating ioctl regardless of the write roots. We deliberately do not raise
        // the minimum ABI to 5 (that would drop the sandbox on Linux 6.2–6.9);
        // instead we handle `IOCTL_DEV` when the kernel offers it, and rely on the
        // lexical `dd`/device-write guards in `permissions.rs` as the compensating
        // control on older kernels. The OS sandbox is therefore not, by itself, a
        // complete device-write boundary below ABI 5.
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
        // Device-node creation (`MAKE_CHAR`/`MAKE_BLOCK`) is *handled* by the
        // ruleset above but granted on *no* root, so `mknod` fails closed
        // everywhere inside the sandbox. Below ABI 5 `IOCTL_DEV` does not exist, so
        // a char/block node created with `mknod ./sda` in a writable workspace dir
        // could be driven with `dd of=./sda` to reach the underlying raw device —
        // escaping the write boundary, since the lexical device guard only
        // recognizes `/dev/...`. Keeping these rights handled-but-ungranted denies
        // device-node creation without leaving the operation entirely unmediated
        // (which is what dropping them from `fs` would do).
        let granted = fs & !(MAKE_CHAR | MAKE_BLOCK);
        for root in roots {
            let Ok(path) = CString::new(root.as_os_str().as_bytes()) else { continue };
            // SAFETY: path is a valid C string.
            let raw = unsafe { libc::open(path.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
            if raw < 0 {
                continue;
            }
            // SAFETY: open returned a new descriptor that we now own.
            let parent = unsafe { OwnedFd::from_raw_fd(raw) };
            let access = if root.is_dir() { granted } else { granted & (WRITE_FILE | TRUNCATE | IOCTL_DEV) };
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

    #[test]
    fn read_only_mode_does_not_grant_device_directories() {
        // Directory devices grant their whole subtree; read-only mode must not
        // expose them (its boundary is temp dirs only), while the individual
        // device nodes it needs for I/O stay writable.
        let workspace = outside_dir();
        let ro = SandboxConfig { mode: SandboxMode::ReadOnly, ..Default::default() };
        let roots = ro.writable_roots(workspace.path());
        for dir in super::DEVICE_DIRS {
            assert!(!roots.iter().any(|r| r == Path::new(dir)), "read-only granted directory device {dir}: {roots:?}");
        }
        assert!(!ro.allows_write(Path::new("/dev/shm/x"), workspace.path()));
        // Node devices remain available so `> /dev/null` still works.
        assert!(ro.allows_write(Path::new("/dev/null"), workspace.path()));

        // Workspace mode may still grant the safe fd subtree…
        let ws = SandboxConfig { mode: SandboxMode::Workspace, tool_caches: false, ..Default::default() };
        let ws_roots = ws.writable_roots(workspace.path());
        if Path::new("/dev/fd").exists() {
            assert!(ws_roots.iter().any(|r| r == Path::new("/dev/fd")), "workspace mode dropped /dev/fd: {ws_roots:?}");
        }
        // …but never the host-shared `/dev/shm` / `/dev/pts` trees, in any mode.
        assert!(!ws_roots.iter().any(|r| r == Path::new("/dev/shm")), "workspace mode granted shared /dev/shm: {ws_roots:?}");
        assert!(!ws_roots.iter().any(|r| r == Path::new("/dev/pts")), "workspace mode granted shared /dev/pts: {ws_roots:?}");
        assert!(!ws.allows_write(Path::new("/dev/shm/x"), workspace.path()));
    }

    #[test]
    fn external_git_dir_is_not_granted() {
        // A `.git` pointer that resolves to an unrelated repository outside the
        // workspace must not be handed a writable root.
        let workspace = outside_dir();
        let outsider = outside_dir();
        let fake_git = outsider.path().join(".git");
        std::fs::create_dir_all(&fake_git).unwrap();
        std::fs::write(workspace.path().join(".git"), format!("gitdir: {}\n", fake_git.display())).unwrap();
        let config = SandboxConfig { mode: SandboxMode::Workspace, tool_caches: false, ..Default::default() };
        let roots = config.writable_roots(workspace.path());
        let fake_real = fake_git.canonicalize().unwrap_or(fake_git);
        assert!(!roots.iter().any(|r| r.starts_with(&fake_real)), "external git dir was granted: {roots:?}");
    }

    #[test]
    fn linked_worktree_git_dirs_are_granted() {
        // A linked worktree lives beside its main checkout; `git commit` there must
        // reach the shared common dir under the main repo. Those git dirs are
        // neither inside the worktree nor an ancestor of it, so they are granted only
        // because git ties them back to this worktree via the `gitdir` back-pointer.
        let base = outside_dir();
        let main = base.path().join("main");
        let wt = base.path().join("wt");
        std::fs::create_dir_all(&main).unwrap();
        let git = |args: &[&str], dir: &Path| {
            let ok = Command::new("git")
                .args(["-c", "user.email=t@t", "-c", "user.name=t"])
                .args(args)
                .current_dir(dir)
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            assert!(ok, "git {args:?} failed");
        };
        git(&["init", "-q", "-b", "main"], &main);
        std::fs::write(main.join("seed"), "x").unwrap();
        git(&["add", "-A"], &main);
        git(&["commit", "-qm", "seed"], &main);
        git(&["worktree", "add", "-q", wt.to_str().unwrap()], &main);

        let config = SandboxConfig { mode: SandboxMode::Workspace, tool_caches: false, ..Default::default() };
        let roots = config.writable_roots(&wt);
        let common = main.join(".git").canonicalize().unwrap();
        assert!(
            roots.iter().any(|r| r.starts_with(&common)),
            "linked worktree's shared git common dir was not granted: {roots:?}"
        );
    }

    #[test]
    fn root_cwd_is_not_a_writable_root() {
        // An ACP session whose `cwd` is `/` must not grant the whole host
        // filesystem as a writable subtree; only the temp roots remain.
        let config = SandboxConfig { mode: SandboxMode::Workspace, tool_caches: false, ..Default::default() };
        let roots = config.writable_roots(Path::new("/"));
        assert!(!roots.iter().any(|r| r == Path::new("/")), "root cwd was granted as a writable root: {roots:?}");
        assert!(!config.allows_write(Path::new("/etc/hosts"), Path::new("/")));
    }
}
