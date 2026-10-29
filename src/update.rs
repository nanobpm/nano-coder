//! Background update checks and the `/update` and `/relaunch` commands.
//!
//! nano-coder learns how it was installed once at startup from
//! `std::env::current_exe()` ([`Channel::detect`]): under a
//! `node_modules/@nanobpm/` tree it is the npm package, under
//! `$CARGO_HOME/bin` (default `~/.cargo/bin`) a `cargo install`, and anything
//! else (a standalone tarball, a local `cargo build` in `target/`) is
//! unmanaged. Only managed installs get a background check and a working
//! `/update`; a locally built binary is never overwritten.
//!
//! The background check ([`Checker`]) runs in interactive TTY sessions only —
//! never in `-p`/headless, ACP or CI, where versions are pinned on purpose —
//! once at startup (in a background task, never delaying the first prompt)
//! and then hourly, persisting the last-check time and latest-known version
//! in the data dir so rapid restarts do not re-check inside the hour. It is
//! silent on any failure (short timeout, no retries) and can be turned off
//! with `check_updates = false` in `config.toml` or the
//! `NANO_CODER_NO_UPDATE_CHECK` / `NO_UPDATE_NOTIFIER` environment variables.
//!
//! `/update` runs the channel's installer (`npm install -g
//! @nanobpm/nano-coder@latest` or `cargo install nano-coder`) attached to the
//! terminal so its progress is visible and Ctrl-C cancels it, then verifies
//! the installed binary's `--version`. `/relaunch` re-`exec`s the binary
//! at its launch path (captured at startup, so a just-installed update at
//! that location is picked up even after Linux unlinks the old inode) with the original
//! argv plus `--resume <current session>`, restarting the harness without
//! losing the session.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// How often the background check runs (startup check, then this interval).
pub const CHECK_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// Upper bound for one registry request; the check must fail fast and
/// silently when the network is unavailable, never affecting turn latency.
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);
/// The registry endpoints, overridable in tests.
const NPM_LATEST_URL: &str = "https://registry.npmjs.org/@nanobpm/nano-coder/latest";
const CRATES_URL: &str = "https://crates.io/api/v1/crates/nano-coder";
/// crates.io requires a descriptive User-Agent; npm's registry ignores it.
const USER_AGENT: &str = concat!("nano-coder/", env!("CARGO_PKG_VERSION"), " (https://github.com/nanobpm/nano-coder)");
/// Where `/update` on an unmanaged install points.
const RELEASES_URL: &str = "https://github.com/nanobpm/nano-coder/releases";

/// How this nano-coder binary was installed, and so how it updates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// `npm install -g @nanobpm/nano-coder`: the exe lives under a
    /// `node_modules/@nanobpm/` tree. Both launcher states land here: the
    /// platform-package binary the JS launcher spawns, and the self-replaced
    /// copy in `bin/` (see `npm/nano-coder/bin/nano-coder`).
    Npm,
    /// `cargo install nano-coder`: the exe is in `$CARGO_HOME/bin`
    /// (default `~/.cargo/bin`).
    Cargo,
    /// Anything else: a standalone tarball, a dev build in `target/`, a
    /// distro package. Never self-modified.
    Other,
}

/// The path this binary was launched from, captured once (call
/// [`launch_exe`] early at startup) *before* any `/update` replaces it. On
/// Linux, once an installer replaces the running file, `current_exe()`
/// resolves the old, unlinked inode (`… (deleted)`), which can neither be
/// verified nor exec'd; the launch path names the *installation*, where the
/// replacement now lives.
pub fn launch_exe() -> PathBuf {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| strip_deleted_suffix(std::env::current_exe().unwrap_or_default())).clone()
}

/// Drop Linux's ` (deleted)` marker from a `/proc/self/exe` resolution, so a
/// path read after replacement still names the installed location.
fn strip_deleted_suffix(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|s| s.strip_suffix(" (deleted)")) {
        Some(stripped) => PathBuf::from(stripped),
        None => path,
    }
}

impl Channel {
    /// Detect the channel from the running executable's launch path.
    pub fn detect() -> Self {
        Self::from_exe(&launch_exe(), std::env::var_os("CARGO_HOME").map(PathBuf::from))
    }

    /// The channel for an executable at `exe`, given the `CARGO_HOME`
    /// override (tests pass representative paths here).
    pub fn from_exe(exe: &Path, cargo_home: Option<PathBuf>) -> Self {
        if exe_has_component(exe, &["node_modules", "@nanobpm"]) {
            return Channel::Npm;
        }
        let cargo_bin = cargo_home.or_else(|| dirs::home_dir().map(|h| h.join(".cargo"))).map(|h| h.join("bin"));
        // `current_exe()` resolves symlinks, so also compare against the
        // canonical cargo bin dir (a symlinked `~/.cargo` / `$CARGO_HOME`);
        // the lexical comparison covers paths that do not exist.
        let parent = exe.parent();
        let canonical_parent = parent.and_then(|p| std::fs::canonicalize(p).ok());
        if cargo_bin.is_some_and(|bin| {
            parent == Some(bin.as_path())
                || std::fs::canonicalize(&bin).is_ok_and(|real| {
                    parent == Some(real.as_path()) || canonical_parent.as_deref() == Some(real.as_path())
                })
        }) {
            return Channel::Cargo;
        }
        Channel::Other
    }

    /// The installer program `/update` runs, if this channel has one.
    fn installer(self) -> Option<&'static str> {
        match self {
            Channel::Npm => Some("npm"),
            Channel::Cargo => Some("cargo"),
            Channel::Other => None,
        }
    }

    /// The argv (after the installer program) that installs the latest release.
    fn install_args(self) -> &'static [&'static str] {
        match self {
            Channel::Npm => &["install", "-g", "@nanobpm/nano-coder@latest"],
            Channel::Cargo => &["install", "nano-coder"],
            Channel::Other => &[],
        }
    }

    /// The command line that installs the latest release, for messages.
    fn install_command(self) -> String {
        match self.installer() {
            Some(program) => format!("{} {}", program, self.install_args().join(" ")),
            None => String::new(),
        }
    }

    /// The registry URL reporting the latest release for this channel.
    fn latest_url(self) -> Option<&'static str> {
        match self {
            Channel::Npm => Some(NPM_LATEST_URL),
            Channel::Cargo => Some(CRATES_URL),
            Channel::Other => None,
        }
    }
}

/// True when `path` contains the `components` sequence in order (each a path
/// component). Case-insensitive on Windows, where npm's tree casing is not
/// guaranteed to match.
fn exe_has_component(path: &Path, components: &[&str]) -> bool {
    let mut parts: Vec<String> = path.components().filter_map(|c| c.as_os_str().to_str().map(str::to_string)).collect();
    if cfg!(windows) {
        parts = parts.iter().map(|p| p.to_lowercase()).collect();
    }
    parts.windows(components.len()).any(|w| w.iter().zip(components).all(|(part, want)| part == want))
}

/// Whether the background update check is disabled by the environment:
/// nano-coder's own kill-switch, or the de-facto standard `NO_UPDATE_NOTIFIER`
/// (honoured by the npm update-notifier ecosystem).
pub fn disabled_by_env() -> bool {
    ["NANO_CODER_NO_UPDATE_CHECK", "NO_UPDATE_NOTIFIER"]
        .iter()
        .any(|name| std::env::var_os(name).is_some_and(|v| !v.is_empty()))
}

/// Whether a CI environment marker is set. Automated runners use deliberately
/// pinned versions, so no check (and no hint) runs there.
pub fn is_ci() -> bool {
    std::env::var_os("CI").is_some_and(|v| !v.is_empty())
}

/// What the persisted state file records between restarts.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct State {
    /// When the last check ran (any outcome), RFC 3339. A restart inside the
    /// interval skips its startup check on this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_check: Option<chrono::DateTime<chrono::Utc>>,
    /// The newest version the registry reported, when it is newer than the
    /// binary that saw it. Drives the "once per new version" hint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_known: Option<String>,
    /// The version the hint was already shown for (or dismissed at startup).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hinted: Option<String>,
}

/// The default state file: `<data dir>/nano-coder/update-check.json`.
pub fn default_state_path() -> PathBuf {
    crate::config::app_dir(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)).join("update-check.json")
}

fn load_state(path: &Path) -> State {
    std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

fn save_state(path: &Path, state: &State) {
    let Some(dir) = path.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let Ok(json) = serde_json::to_string_pretty(state) else { return };
    // Write-then-rename so a crash mid-write cannot leave a torn file that
    // would reset the hourly cache.
    // The temp name is process-unique: concurrent sessions share the state
    // file, and a shared temp path would let one rename another's
    // half-written file into place.
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, format!("{json}\n")).is_ok() {
        if std::fs::rename(&tmp, path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// Compare two dotted-numeric versions (an optional `v` prefix and a
/// `-pre.release` suffix are ignored: any stable release outranks a
/// pre-release of the same number, and a pre-release is never "newer" than
/// the running stable). True when `candidate` is strictly newer.
pub fn is_newer(candidate: &str, running: &str) -> bool {
    fn parse(v: &str) -> (Vec<u64>, bool) {
        let v = v.trim().trim_start_matches(['v', 'V']);
        // Split off a build suffix (`+…`) first, then a pre-release (`-…`).
        let core = v.split('+').next().unwrap_or(v);
        let (core, pre) = core.split_once('-').unwrap_or((core, ""));
        let nums = core.split('.').map(|part| part.parse::<u64>().unwrap_or(0)).collect();
        (nums, !pre.is_empty())
    }
    let (cand, cand_pre) = parse(candidate);
    let (run, run_pre) = parse(running);
    let len = cand.len().max(run.len());
    for i in 0..len {
        let c = cand.get(i).copied().unwrap_or(0);
        let r = run.get(i).copied().unwrap_or(0);
        if c != r {
            return c > r;
        }
    }
    // Same numeric core: a stable candidate beats a running pre-release; a
    // pre-release candidate never beats a running stable.
    run_pre && !cand_pre
}

/// Fetch the latest published version for `channel` from its registry.
/// Any failure (network down, timeout, unexpected payload) is `None`: the
/// check must fail silently and quickly.
async fn fetch_latest(channel: Channel, url: Option<&str>) -> Option<String> {
    let url = url.unwrap_or(channel.latest_url()?);
    let client = reqwest::Client::builder().timeout(HTTP_TIMEOUT).user_agent(USER_AGENT).build().ok()?;
    let body: serde_json::Value = client.get(url).send().await.ok()?.json().await.ok()?;
    let version = match channel {
        Channel::Npm => body.get("version")?.as_str()?,
        Channel::Cargo => body.get("crate")?.get("max_stable_version")?.as_str()?,
        Channel::Other => return None,
    };
    let version = version.trim();
    (!version.is_empty()).then(|| version.to_string())
}

/// One registry probe, factored out of [`Checker::tick`] so tests can drive
/// the decision logic with a fake registry answer.
fn probe_outcome(
    state: &mut State,
    running: &str,
    latest: Option<String>,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<String> {
    state.last_check = Some(now);
    let latest = latest?;
    if is_newer(&latest, running) {
        state.latest_known = Some(latest.clone());
        // A version never hinted at (and not already dismissed) is news.
        if state.hinted.as_deref() != Some(latest.as_str()) {
            return Some(latest);
        }
    }
    None
}

/// The hourly background checker. Owns the persisted state and the "hint
/// once per new version" rule; the REPL polls [`Checker::take_hint`] at idle
/// moments, so a hint never lands mid-stream or mid-tool-call.
pub struct Checker {
    state: Mutex<State>,
    state_path: PathBuf,
    /// Set by the background task when a check found a newer version.
    hint: Mutex<Option<String>>,
    /// Serialises checks: the startup/interval task and a `/update`-forced
    /// check never run concurrently. An async lock, so a waiter yields rather
    /// than spinning while another check is in flight.
    check_lock: tokio::sync::Mutex<()>,
    /// Signalled when a hint becomes ready, so an idle prompt can show it
    /// without waiting for the next input (a stored permit covers a hint
    /// that lands before anyone waits).
    hint_ready: tokio::sync::Notify,
    channel: Channel,
    running: String,
    next_due: Mutex<Instant>,
    /// Registry URL override (tests point this at a local fake).
    url_override: Option<String>,
}

impl Checker {
    /// A checker for `channel` (nothing is spawned for `Channel::Other`),
    /// comparing against the running binary's version.
    pub fn new(channel: Channel, state_path: PathBuf) -> Self {
        Self::with_url(channel, state_path, env!("CARGO_PKG_VERSION").to_string(), None)
    }

    fn with_url(channel: Channel, state_path: PathBuf, running: String, url_override: Option<String>) -> Self {
        let state = load_state(&state_path);
        // A restart inside the interval skips the startup check: the first
        // check is due one interval after the persisted last one.
        let startup_wait = state
            .last_check
            .and_then(|then| {
                let elapsed = (chrono::Utc::now() - then).to_std().unwrap_or(Duration::ZERO);
                CHECK_INTERVAL.checked_sub(elapsed)
            })
            .unwrap_or(Duration::ZERO);
        // A restart between discovering an update and showing its hint must
        // not drop the notification: re-arm it from the persisted state (a
        // newer, not-yet-hinted `latest_known`) and signal readiness, so an
        // idle prompt wakes for it. The hourly cache may delay a *rediscovery*
        // check, but this hint does not wait on one.
        // An unmanaged install (`Channel::Other`) cannot `/update` itself, so
        // it never inherits a hint a managed session cached in shared state.
        let pending = state.latest_known.clone().filter(|v| {
            channel != Channel::Other && is_newer(v, &running) && state.hinted.as_deref() != Some(v.as_str())
        });
        let hint_ready = tokio::sync::Notify::new();
        if pending.is_some() {
            // A stored permit: the waiter may start listening after this.
            hint_ready.notify_one();
        }
        Checker {
            state: Mutex::new(state),
            state_path,
            hint: Mutex::new(pending),
            check_lock: tokio::sync::Mutex::new(()),
            hint_ready,
            channel,
            running,
            next_due: Mutex::new(Instant::now() + startup_wait),
            url_override,
        }
    }

    /// The channel this checker updates through.
    pub fn channel(&self) -> Channel {
        self.channel
    }

    /// The newest known release, when it is newer than the running binary.
    pub fn latest_known(&self) -> Option<String> {
        let state = self.state.lock().unwrap();
        state.latest_known.clone().filter(|v| is_newer(v, &self.running))
    }

    /// The hint line for a newer release, at most once per version per
    /// process. The version is also recorded as hinted in the persisted
    /// state, so a restart does not re-hint it.
    pub fn take_hint(&self) -> Option<String> {
        let version = self.hint.lock().unwrap().take()?;
        {
            let mut state = self.state.lock().unwrap();
            state.hinted = Some(version.clone());
            save_state(&self.state_path, &state);
        }
        Some(format!("nano-coder {version} is available (you have {}) — /update to install it", self.running))
    }

    /// Wait until a hint is ready to show (for the idle prompt's select).
    pub async fn hint_ready(&self) {
        self.hint_ready.notified().await
    }

    /// Run one check now, regardless of the hourly schedule, returning the
    /// version the registry actually reports — newer, equal or older — so
    /// `/update` can tell "up to date" apart from "check failed" (`None`).
    pub async fn force_check(&self) -> Option<String> {
        self.check(true).await
    }

    /// Run a check if one is due (always when `force`). Returns the fetched
    /// version when a check ran, else the cached newer-only version.
    async fn check(&self, force: bool) -> Option<String> {
        // Wait (yielding) for any in-flight check, then re-test the schedule:
        // the other check may just have satisfied it.
        let _guard = self.check_lock.lock().await;
        if !force && Instant::now() < *self.next_due.lock().unwrap() {
            return self.latest_known();
        }
        let latest = fetch_latest(self.channel, self.url_override.as_deref()).await;
        let found = {
            let mut state = self.state.lock().unwrap();
            let found = probe_outcome(&mut state, &self.running, latest.clone(), chrono::Utc::now());
            save_state(&self.state_path, &state);
            found
        };
        *self.next_due.lock().unwrap() = Instant::now() + CHECK_INTERVAL;
        if let Some(version) = found {
            *self.hint.lock().unwrap() = Some(version);
            self.hint_ready.notify_one();
        }
        latest
    }

    /// The background loop: check when due, then hourly. Spawned once at
    /// startup; it never blocks the first prompt and never propagates a
    /// failure.
    pub async fn run(self: std::sync::Arc<Self>) {
        loop {
            let wait = self.next_due.lock().unwrap().saturating_duration_since(Instant::now());
            if !wait.is_zero() {
                tokio::time::sleep(wait).await;
            }
            self.check(false).await;
        }
    }

    /// Start the background task. `None` for an unmanaged install, which
    /// never checks.
    pub fn spawn(self: std::sync::Arc<Self>) -> Option<tokio::task::JoinHandle<()>> {
        (self.channel != Channel::Other).then(|| tokio::spawn(self.run()))
    }
}

/// The outcome of a `/update` attempt, as the message lines to show.
pub enum UpdateOutcome {
    /// This install is not managed by cargo or npm; nothing was changed.
    Unmanaged(String),
    /// The channel's installer is not on `PATH`; the manual command is shown.
    NoInstaller(String),
    /// The installer ran and the new binary verifies.
    Updated(Vec<String>),
    /// The installer ran but failed (or the result did not verify); the
    /// running session is untouched.
    Failed(String),
}

impl UpdateOutcome {
    pub fn lines(self) -> Vec<String> {
        match self {
            UpdateOutcome::Unmanaged(text) | UpdateOutcome::NoInstaller(text) | UpdateOutcome::Failed(text) => {
                vec![text]
            }
            UpdateOutcome::Updated(lines) => lines,
        }
    }
}

/// Run the channel's installer with its stdio attached to the terminal (the
/// caller has already suspended the frame UI and restored terminal modes), so
/// the user sees real progress and Ctrl-C interrupts the install like any
/// long command. `runner` is indirection for tests, which pass a fake
/// installer instead of touching the real network or toolchain.
pub async fn run_installer(
    channel: Channel,
    exe: &Path,
    runner: impl FnOnce(&str, &[&str]) -> Result<std::process::ExitStatus> + Send + 'static,
) -> UpdateOutcome {
    let Some(program) = channel.installer() else {
        return UpdateOutcome::Unmanaged(format!(
            "This nano-coder was not installed with cargo or npm (install channel: other), so it cannot update itself. \
             Download the latest release from {RELEASES_URL} — a locally built binary is never overwritten."
        ));
    };
    if which(program).is_none() {
        return UpdateOutcome::NoInstaller(format!(
            "`{program}` is not on PATH, so nano-coder cannot run the update itself. \
             Install it manually with: {}",
            channel.install_command()
        ));
    }
    let args = channel.install_args();
    let program = program.to_string();
    let status = match tokio::task::spawn_blocking(move || runner(&program, args)).await {
        Ok(Ok(status)) => status,
        Ok(Err(e)) => return UpdateOutcome::Failed(format!("Could not run `{}`: {e:#}", channel.install_command())),
        Err(e) => return UpdateOutcome::Failed(format!("The installer task failed: {e}")),
    };
    if !status.success() {
        return UpdateOutcome::Failed(format!(
            "`{}` exited with {status}; the running session is unchanged. \
             Try it by hand to see the full error: {}",
            channel.install_command(),
            channel.install_command()
        ));
    }
    // Verify by asking the *selected installation's* binary — the path this
    // process was launched from, which the installer has just replaced — for
    // its version. A bare `nano-coder` through PATH could resolve a different
    // install (e.g. an npm one shadowing ~/.cargo/bin) and misreport.
    match installed_version(exe).await {
        Some(version) if version.trim_start_matches(['v', 'V']) != env!("CARGO_PKG_VERSION") => UpdateOutcome::Updated(
            vec![format!("Updated to {version} — /relaunch to restart into it; your session will resume.")],
        ),
        Some(version) => UpdateOutcome::Updated(vec![format!(
            "The installer succeeded but `nano-coder --version` still reports {version} \
             (this process is {}). The new version takes effect on the next start.",
            env!("CARGO_PKG_VERSION")
        )]),
        None => UpdateOutcome::Failed(
            "The installer finished but the installed `nano-coder --version` could not be read; \
             the running session is unchanged."
                .to_string(),
        ),
    }
}

/// The default installer runner: spawn the program attached to the terminal.
pub fn spawn_installer(program: &str, args: &[&str]) -> Result<std::process::ExitStatus> {
    std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .with_context(|| format!("spawn {program}"))
}

/// `<exe> --version`, parsed to the bare version string.
async fn installed_version(exe: &Path) -> Option<String> {
    let out =
        tokio::process::Command::new(exe).arg("--version").stdin(std::process::Stdio::null()).output().await.ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8(out.stdout).ok()?;
    text.trim().strip_prefix("nano-coder ").map(str::to_string)
}

/// Where `program` would be found on PATH (`which` semantics, no dependency).
fn which(program: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&paths) {
        let candidate = dir.join(program);
        if is_executable(&candidate) {
            return Some(candidate);
        }
        #[cfg(windows)]
        {
            let exe = dir.join(format!("{program}.exe"));
            if is_executable(&exe) {
                return Some(exe);
            }
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// The argv `/relaunch` execs into: the original command line with any
/// existing `--resume` / `--continue` (both the separated and `=` forms)
/// replaced by `--resume <session>`. `argv` excludes the program name; the
/// session id is validated by the caller (session ids are filename-safe).
pub fn relaunch_argv(argv: &[String], session: &str) -> Vec<String> {
    let mut out = Vec::with_capacity(argv.len() + 2);
    let mut iter = argv.iter().peekable();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            // `--resume` consumes a following value only when it is not
            // another flag (parse_args' rule); either way the flag is dropped.
            "--resume" | "--continue" => {
                if iter.peek().is_some_and(|next| !next.starts_with('-')) {
                    iter.next();
                }
            }
            _ if arg.starts_with("--resume=") || arg.starts_with("--continue=") => {}
            _ => out.push(arg.clone()),
        }
    }
    // A session id that starts with '-' is only addressable in the attached
    // form: as a separated value it would be parsed as an unknown flag (see
    // `resume_attached_form_names_dash_prefixed_ids`), and the exec replaces
    // this process before the new one reports the error.
    if session.starts_with('-') {
        out.push(format!("--resume={session}"));
    } else {
        out.extend(["--resume".to_string(), session.to_string()]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exe(path: &str) -> PathBuf {
        PathBuf::from(path)
    }

    #[test]
    fn detects_the_npm_channel_in_both_launcher_states() {
        // The platform-package binary the JS launcher spawns...
        assert_eq!(
            Channel::from_exe(&exe("/usr/local/lib/node_modules/@nanobpm/nano-coder/bin/nano-coder"), None),
            Channel::Npm
        );
        // ...and the self-replaced copy in the package's bin/ dir.
        assert_eq!(
            Channel::from_exe(
                &exe("/home/u/.npm-global/lib/node_modules/@nanobpm/nano-coder-linux-x64/bin/nano-coder"),
                None
            ),
            Channel::Npm
        );
        // A scoped path segment must be a whole component, not a substring.
        assert_eq!(Channel::from_exe(&exe("/home/u/node_modules/@nanobpm-tools/nano-coder"), None), Channel::Other);
    }

    #[test]
    fn detects_the_cargo_channel_with_and_without_cargo_home() {
        let home = dirs::home_dir().expect("tests run with a home");
        let default_bin = home.join(".cargo/bin");
        assert_eq!(Channel::from_exe(&default_bin.join("nano-coder"), None), Channel::Cargo);
        // $CARGO_HOME overrides the default.
        let custom = PathBuf::from("/opt/cargo");
        assert_eq!(Channel::from_exe(&exe("/opt/cargo/bin/nano-coder"), Some(custom.clone())), Channel::Cargo);
        // With $CARGO_HOME set, the default location no longer counts.
        assert_eq!(Channel::from_exe(&default_bin.join("nano-coder"), Some(custom)), Channel::Other);
        // A subdirectory of the cargo bin is not the cargo bin.
        assert_eq!(Channel::from_exe(&default_bin.join("nested/nano-coder"), None), Channel::Other);
    }

    #[test]
    fn standalone_and_dev_builds_are_unmanaged() {
        assert_eq!(Channel::from_exe(&exe("/usr/local/bin/nano-coder"), None), Channel::Other);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_cargo_home_is_still_the_cargo_channel() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real-cargo");
        std::fs::create_dir_all(real.join("bin")).unwrap();
        let link = dir.path().join("link-cargo");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        // current_exe() reports the resolved path; CARGO_HOME keeps the symlink.
        let resolved = std::fs::canonicalize(real.join("bin")).unwrap().join("nano-coder");
        assert_eq!(Channel::from_exe(&resolved, Some(link)), Channel::Cargo);
        assert_eq!(Channel::from_exe(&exe("/home/u/nano-coder/target/release/nano-coder"), None), Channel::Other);
        assert_eq!(Channel::from_exe(&exe("/opt/nano-coder/nano-coder"), None), Channel::Other);
    }

    #[test]
    fn version_comparison_orders_dotted_releases() {
        assert!(is_newer("0.43.0", "0.42.1"));
        assert!(is_newer("0.43.0", "0.42.9"));
        assert!(is_newer("1.0.0", "0.99.9"));
        assert!(is_newer("v0.43.0", "0.42.1"), "an optional v prefix is ignored");
        assert!(!is_newer("0.42.1", "0.42.1"), "the running version is not newer");
        assert!(!is_newer("0.42.0", "0.42.1"));
        assert!(!is_newer("0.9.9", "0.42.1"));
        assert!(!is_newer("0.43.0", "0.43"), "missing components are zero: equal, not newer");
        assert!(is_newer("0.43.1", "0.43"), "a real bump past the padding is newer");
        assert!(!is_newer("0.43.0-rc.1", "0.43.0"), "a pre-release never beats its stable");
        assert!(is_newer("0.43.0", "0.43.0-rc.1"), "a stable beats a running pre-release");
    }

    #[test]
    fn probe_hints_only_for_newer_unhinted_versions() {
        let now = chrono::Utc::now();
        let mut state = State::default();
        // A newer version hints and is remembered.
        assert_eq!(probe_outcome(&mut state, "0.42.1", Some("0.43.0".into()), now).as_deref(), Some("0.43.0"));
        assert_eq!(state.latest_known.as_deref(), Some("0.43.0"));
        assert!(state.last_check.is_some());
        // The same version probed again does not re-hint once hinted.
        state.hinted = Some("0.43.0".into());
        assert_eq!(probe_outcome(&mut state, "0.42.1", Some("0.43.0".into()), now), None);
        // A not-newer version never hints and does not replace the known one.
        assert_eq!(probe_outcome(&mut state, "0.42.1", Some("0.42.1".into()), now), None);
        assert_eq!(state.latest_known.as_deref(), Some("0.43.0"));
        // A failed probe keeps the state but still stamps the check time.
        let mut state = State::default();
        assert_eq!(probe_outcome(&mut state, "0.42.1", None, now), None);
        assert!(state.last_check.is_some());
        assert_eq!(state.latest_known, None);
    }

    #[test]
    fn state_round_trips_through_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("update-check.json");
        let state = State {
            last_check: Some(chrono::Utc::now()),
            latest_known: Some("0.43.0".into()),
            hinted: Some("0.43.0".into()),
        };
        save_state(&path, &state);
        let loaded = load_state(&path);
        assert_eq!(loaded.latest_known.as_deref(), Some("0.43.0"));
        assert_eq!(loaded.hinted.as_deref(), Some("0.43.0"));
        assert!(loaded.last_check.is_some());
        // A missing or torn file loads as the default, never an error.
        assert!(load_state(&dir.path().join("missing.json")).latest_known.is_none());
        std::fs::write(&path, "{torn").unwrap();
        assert!(load_state(&path).latest_known.is_none());
    }

    #[test]
    fn a_restart_inside_the_interval_defers_the_startup_check() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        // No state: the first check is due immediately.
        let fresh = Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None);
        assert!(fresh.next_due.lock().unwrap().duration_since(Instant::now()).is_zero());
        // A state checked just now: the next check is a full interval away.
        save_state(&path, &State { last_check: Some(chrono::Utc::now()), ..Default::default() });
        let warm = Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None);
        let wait = warm.next_due.lock().unwrap().duration_since(Instant::now());
        assert!(wait > CHECK_INTERVAL - Duration::from_secs(5), "{wait:?}");
        // A stale state (older than the interval) checks at once.
        save_state(
            &path,
            &State { last_check: Some(chrono::Utc::now() - chrono::Duration::hours(2)), ..Default::default() },
        );
        let stale = Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None);
        assert!(stale.next_due.lock().unwrap().duration_since(Instant::now()).is_zero());
    }

    #[tokio::test]
    async fn check_against_a_fake_registry_hints_once_and_caches() {
        // A fake registry over a loopback TCP listener: one request, one JSON
        // answer — no real network involved.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/latest", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            use std::io::{Read, Write};
            let mut buf = [0u8; 1024];
            let _ = conn.read(&mut buf);
            let body = r#"{"version":"0.43.0"}"#;
            write!(conn, "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}", body.len(), body)
                .unwrap();
        });
        let dir = tempfile::tempdir().unwrap();
        let checker = std::sync::Arc::new(Checker::with_url(
            Channel::Npm,
            dir.path().join("state.json"),
            "0.42.1".into(),
            Some(url),
        ));
        assert_eq!(checker.force_check().await.as_deref(), Some("0.43.0"));
        server.join().unwrap();
        // The hint is delivered exactly once...
        let hint = checker.take_hint().expect("a newer version hints");
        assert!(hint.contains("0.43.0 is available (you have 0.42.1)"), "{hint}");
        assert!(hint.contains("/update"), "{hint}");
        assert_eq!(checker.take_hint(), None);
        // ...and persisted, so a restarted process does not re-hint it.
        let restarted = Checker::with_url(Channel::Npm, dir.path().join("state.json"), "0.42.1".into(), None);
        assert_eq!(restarted.latest_known().as_deref(), Some("0.43.0"));
        assert_eq!(restarted.take_hint(), None, "already hinted before the restart");
    }

    #[tokio::test]
    async fn a_failed_check_is_silent_and_cheap() {
        // Nothing listens on the port: the check fails fast and quietly.
        let dir = tempfile::tempdir().unwrap();
        let checker = std::sync::Arc::new(Checker::with_url(
            Channel::Npm,
            dir.path().join("state.json"),
            "0.42.1".into(),
            Some("http://127.0.0.1:1/".into()),
        ));
        assert_eq!(checker.force_check().await, None);
        assert_eq!(checker.take_hint(), None);
        // The failed check still stamps last_check, so the hourly cadence
        // holds (no retry loop).
        assert!(load_state(&dir.path().join("state.json")).last_check.is_some());
    }

    #[test]
    fn update_outcome_messages_cover_every_path() {
        // Unmanaged: guidance, no self-modification.
        let UpdateOutcome::Unmanaged(text) = UpdateOutcome::Unmanaged(format!("not managed; see {RELEASES_URL}"))
        else {
            unreachable!()
        };
        assert!(text.contains("releases"));
        // The lines() projection keeps the single-line variants intact.
        assert_eq!(UpdateOutcome::Failed("exit 1".into()).lines(), ["exit 1"]);
        assert_eq!(UpdateOutcome::Updated(vec!["a".into(), "b".into()]).lines().len(), 2);
    }

    #[tokio::test]
    async fn a_failing_installer_reports_and_changes_nothing() {
        // The fake installer fails; /update must report the exit status and
        // leave the session untouched (no verification attempt needed).
        let fail: fn(&str, &[&str]) -> Result<std::process::ExitStatus> = |_, _| Ok(exit_status(1));
        let outcome = run_installer(Channel::Cargo, Path::new("/nonexistent/nano-coder"), fail).await;
        // `cargo` may or may not be on PATH in the test environment; both
        // paths are acceptable outcomes here.
        match outcome {
            UpdateOutcome::Failed(text) => assert!(text.contains("cargo install nano-coder"), "{text}"),
            UpdateOutcome::NoInstaller(text) => assert!(text.contains("cargo install nano-coder"), "{text}"),
            other => panic!("unexpected outcome: {}", other.lines().join("\n")),
        }
    }

    /// An exit status for `code`, cross-platform enough for the tests.
    #[cfg(unix)]
    fn exit_status(code: i32) -> std::process::ExitStatus {
        use std::os::unix::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(code << 8)
    }

    #[cfg(windows)]
    fn exit_status(code: i32) -> std::process::ExitStatus {
        use std::os::windows::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(code as u32)
    }

    #[test]
    fn relaunch_argv_replaces_resume_and_continue() {
        let argv: Vec<String> = ["--model", "openai/gpt-4o"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["--model", "openai/gpt-4o", "--resume", "sess-1"]);
        // A separated --resume value is dropped with its flag.
        let argv: Vec<String> = ["--resume", "old-sess", "--model", "m"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["--model", "m", "--resume", "sess-1"]);
        // A bare --resume (picker form, no value) drops only the flag.
        let argv: Vec<String> = ["--resume", "--model", "m"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["--model", "m", "--resume", "sess-1"]);
        // The = forms are dropped whole.
        let argv: Vec<String> =
            ["--resume=old", "--continue=also-old", "-v", "debug"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["-v", "debug", "--resume", "sess-1"]);
        // --continue (separated) goes too.
        let argv: Vec<String> = ["--continue", "old-sess"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["--resume", "sess-1"]);
    }

    #[test]
    fn relaunch_argv_uses_the_attached_form_for_dash_prefixed_ids() {
        // `validate_id` permits a leading '-', but the separated form would
        // leave `-sess` in the stream as an unknown flag — and the exec has
        // already replaced this process when the new one rejects it. The
        // attached `--resume=-sess` form parses (see
        // `resume_attached_form_names_dash_prefixed_ids`).
        let argv: Vec<String> = ["--model", "m"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "-sess"), vec!["--model", "m", "--resume=-sess"]);
        // An existing separated --resume is still dropped first.
        let argv: Vec<String> = ["--resume", "old"].iter().map(|s| s.to_string()).collect();
        assert_eq!(relaunch_argv(&argv, "-sess"), vec!["--resume=-sess"]);
        // A normal id keeps the separated form.
        let argv: Vec<String> = Vec::new();
        assert_eq!(relaunch_argv(&argv, "sess-1"), vec!["--resume", "sess-1"]);
    }

    #[test]
    fn deleted_suffix_is_stripped_from_the_launch_path() {
        assert_eq!(
            strip_deleted_suffix(exe("/home/u/.cargo/bin/nano-coder (deleted)")),
            exe("/home/u/.cargo/bin/nano-coder")
        );
        assert_eq!(strip_deleted_suffix(exe("/home/u/.cargo/bin/nano-coder")), exe("/home/u/.cargo/bin/nano-coder"));
    }

    /// A one-shot fake registry answering `{"version": <version>}`.
    fn fake_registry(version: &'static str) -> (String, std::thread::JoinHandle<()>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/latest", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            use std::io::{Read, Write};
            let mut buf = [0u8; 1024];
            let _ = conn.read(&mut buf);
            let body = format!(r#"{{"version":"{version}"}}"#);
            write!(conn, "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}", body.len(), body)
                .unwrap();
        });
        (url, server)
    }

    #[tokio::test]
    async fn force_check_reports_the_current_version_when_up_to_date() {
        // Equal (and older) versions must come back, so /update can say
        // "up to date" instead of running the installer.
        for reported in ["0.42.1", "0.40.0"] {
            let (url, server) = fake_registry(reported);
            let dir = tempfile::tempdir().unwrap();
            let checker = Checker::with_url(Channel::Npm, dir.path().join("s.json"), "0.42.1".into(), Some(url));
            assert_eq!(checker.force_check().await.as_deref(), Some(reported));
            server.join().unwrap();
            assert_eq!(checker.latest_known(), None, "the hint cache stays newer-only");
            assert_eq!(checker.take_hint(), None);
        }
    }

    #[tokio::test]
    async fn a_restart_re_arms_a_pending_hint_from_the_persisted_state() {
        // The process discovered 0.43.0 and persisted it, then restarted
        // before the hint was shown (`hinted` unset). The new process must
        // still surface the hint — from the persisted state, without waiting
        // for the hourly cache to expire or a fresh check to succeed.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        save_state(
            &path,
            &State { last_check: Some(chrono::Utc::now()), latest_known: Some("0.43.0".into()), hinted: None },
        );
        let checker = Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None);
        let hint = checker.take_hint().expect("the pending hint survives the restart");
        assert!(hint.contains("0.43.0 is available"), "{hint}");
        // …and its readiness is signalled (a stored permit), so an idle prompt
        // that starts waiting now still wakes.
        tokio::time::timeout(Duration::from_secs(1), checker.hint_ready()).await.expect("hint notification");
        // Taking it persists `hinted`, so a second restart does not re-hint.
        let third = Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None);
        assert_eq!(third.take_hint(), None);
        // No pending hint when the persisted version is not newer, or was
        // already hinted.
        save_state(&path, &State { latest_known: Some("0.42.1".into()), hinted: None, ..Default::default() });
        assert_eq!(Checker::with_url(Channel::Npm, path.clone(), "0.42.1".into(), None).take_hint(), None);
        save_state(
            &path,
            &State { latest_known: Some("0.43.0".into()), hinted: Some("0.43.0".into()), ..Default::default() },
        );
        assert_eq!(Checker::with_url(Channel::Npm, path, "0.42.1".into(), None).take_hint(), None);
    }

    #[test]
    fn an_unmanaged_install_never_inherits_a_cached_hint() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        save_state(&path, &State { latest_known: Some("0.43.0".into()), hinted: None, ..Default::default() });
        assert_eq!(Checker::with_url(Channel::Other, path, "0.42.1".into(), None).take_hint(), None);
    }

    #[test]
    fn save_state_leaves_no_temp_file_and_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        save_state(&path, &State { latest_known: Some("0.43.0".into()), ..Default::default() });
        assert_eq!(load_state(&path).latest_known.as_deref(), Some("0.43.0"));
        let names: Vec<_> = std::fs::read_dir(dir.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names, vec![std::ffi::OsString::from("state.json")], "no stray temp file");
    }

    #[tokio::test]
    async fn a_ready_hint_wakes_an_idle_waiter() {
        let (url, server) = fake_registry("0.43.0");
        let dir = tempfile::tempdir().unwrap();
        let checker = Checker::with_url(Channel::Npm, dir.path().join("s.json"), "0.42.1".into(), Some(url));
        checker.force_check().await;
        server.join().unwrap();
        // The stored permit wakes a waiter that starts after the hint landed.
        tokio::time::timeout(Duration::from_secs(1), checker.hint_ready()).await.expect("hint notification");
    }

    #[tokio::test]
    async fn a_due_background_check_waits_for_an_in_flight_one_without_spinning() {
        // Hold the check lock as an in-flight forced check would: a due
        // background check must block (yield) on it, not return at once with
        // the deadline still expired.
        let dir = tempfile::tempdir().unwrap();
        let checker = std::sync::Arc::new(Checker::with_url(
            Channel::Npm,
            dir.path().join("s.json"),
            "0.42.1".into(),
            Some("http://127.0.0.1:1/".into()),
        ));
        let guard = checker.check_lock.lock().await;
        let bg = tokio::spawn({
            let checker = checker.clone();
            async move { checker.check(false).await }
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!bg.is_finished(), "the background check waits on the in-flight one");
        // The in-flight check completes and reschedules; the waiter then sees
        // the fresh deadline and does not re-check.
        *checker.next_due.lock().unwrap() = Instant::now() + CHECK_INTERVAL;
        drop(guard);
        bg.await.unwrap();
        assert!(load_state(&dir.path().join("s.json")).last_check.is_none(), "no redundant check ran");
    }
}
