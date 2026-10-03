//! Claude Code-compatible user hooks.
//!
//! nano reads the `hooks` key from Claude Code's settings files (and nano's own
//! `[hooks]` config) and runs external `command` hooks on the agent lifecycle.
//! The protocol — input JSON on stdin, exit codes, JSON output — is Claude
//! Code's, so existing hook scripts work unchanged (see
//! <https://code.claude.com/docs/en/hooks>). From Pi it takes **fail-safe
//! blocking**: a `PreToolUse` hook that crashes, times out or exits with an
//! unexpected code blocks the tool call rather than silently letting it through.
//!
//! This is distinct from the internal, observe-only Rust registry in
//! `hooks.rs`, which nano keeps for its own debug logging and tests.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::permissions;
use crate::sandbox::{self, SandboxConfig};

/// Per-field cap on hook output, matching Claude Code.
const FIELD_CAP: usize = 10_000;
/// Default per-hook timeout when none is given, in seconds (Claude's default).
const DEFAULT_TIMEOUT_SECS: u64 = 60;
/// Blocking `Stop` hooks are capped per turn to avoid loops.
pub const MAX_STOP_BLOCKS: u32 = 3;

/// The lifecycle events nano runs hooks on in phase 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    Stop,
}

impl Event {
    /// Claude Code's event name, as written in settings files.
    pub fn claude_name(self) -> &'static str {
        match self {
            Event::SessionStart => "SessionStart",
            Event::UserPromptSubmit => "UserPromptSubmit",
            Event::PreToolUse => "PreToolUse",
            Event::PostToolUse => "PostToolUse",
            Event::Stop => "Stop",
        }
    }

    fn from_name(name: &str) -> Option<Event> {
        Some(match name {
            "SessionStart" => Event::SessionStart,
            "UserPromptSubmit" => Event::UserPromptSubmit,
            "PreToolUse" => Event::PreToolUse,
            "PostToolUse" => Event::PostToolUse,
            "Stop" => Event::Stop,
            _ => return None,
        })
    }
}

/// Where a hook came from, for display and (later) trust decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `.claude/settings.json` at the repository root (committed, shared).
    Project,
    /// `.claude/settings.local.json` (not committed).
    ProjectLocal,
    /// `~/.claude/settings.json`.
    UserClaude,
    /// nano's own `[hooks]` in `config.toml`.
    UserNano,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Project => "project",
            Source::ProjectLocal => "local",
            Source::UserClaude => "user",
            Source::UserNano => "user",
        }
    }

    /// Project hooks run inside the sandbox when one is active; user hooks run
    /// outside it (they are the user's own and may need the real environment).
    fn is_project(self) -> bool {
        matches!(self, Source::Project | Source::ProjectLocal)
    }
}

// ---------------------------------------------------------------------------
// Settings-file shapes (Claude's JSON and nano's TOML both deserialize here).
// ---------------------------------------------------------------------------

/// A group of hooks sharing a `matcher`, as stored under an event name.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HookGroup {
    #[serde(default)]
    pub matcher: Option<String>,
    #[serde(default)]
    pub hooks: Vec<HookEntry>,
}

/// One hook handler within a group.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HookEntry {
    #[serde(default, rename = "type")]
    pub kind: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Option<Vec<String>>,
    #[serde(default, rename = "if")]
    pub if_rule: Option<String>,
    #[serde(default)]
    pub timeout: Option<u64>,
    #[serde(default, rename = "statusMessage")]
    pub status_message: Option<String>,
}

/// The subset of a Claude settings file nano reads: `hooks` and
/// `disableAllHooks`. nano never reads permissions, env or model settings from
/// these files, and never writes to them.
#[derive(Debug, Clone, Default, Deserialize)]
struct SettingsFile {
    #[serde(default)]
    hooks: BTreeMap<String, Vec<HookGroup>>,
    #[serde(default, rename = "disableAllHooks")]
    disable_all_hooks: bool,
}

/// The `[hooks]` table from nano's own config: event name -> groups.
pub type NanoHooks = BTreeMap<String, Vec<HookGroup>>;

// ---------------------------------------------------------------------------
// Loaded hooks.
// ---------------------------------------------------------------------------

/// A supported, runnable hook.
#[derive(Debug, Clone)]
pub struct Hook {
    pub event: Event,
    pub matcher: Option<String>,
    pub if_rule: Option<String>,
    pub command: String,
    pub args: Option<Vec<String>>,
    pub timeout: Duration,
    pub source: Source,
}

/// A hook nano could not run, and why (reported, never silently dropped).
#[derive(Debug, Clone)]
pub struct Skipped {
    pub event_name: String,
    pub reason: String,
    pub source: Source,
}

/// A settings file that was read, with a content hash for the audit log.
#[derive(Debug, Clone)]
pub struct LoadedFile {
    pub path: PathBuf,
    pub source: Source,
    pub hash: String,
}

/// Config inputs for loading hooks (a slice of `Config`).
pub struct LoadOptions<'a> {
    pub disable_hooks: bool,
    pub disable_project_hooks: bool,
    pub claude_user_hooks: bool,
    pub nano_hooks: &'a NanoHooks,
    pub sandbox: SandboxConfig,
}

/// The loaded hook set plus the runtime context for executing them.
pub struct HookManager {
    hooks: Vec<Hook>,
    pub skipped: Vec<Skipped>,
    pub files: Vec<LoadedFile>,
    sandbox: SandboxConfig,
    project_dir: PathBuf,
    /// Set once the session's identity is known (`set_session`).
    session_id: String,
    transcript_path: String,
    permission_mode: String,
}

impl HookManager {
    /// Load hooks from every source: project `.claude/settings.json` and
    /// `.claude/settings.local.json` (at the repository root), the user's
    /// `~/.claude/settings.json`, and nano's own `[hooks]`. Hooks from all
    /// sources run together; a duplicate handler (same event, matcher and
    /// command) is kept once.
    pub fn load(opts: &LoadOptions, cwd: &Path) -> HookManager {
        let project_dir = crate::instructions::git_root(cwd).unwrap_or_else(|| cwd.to_path_buf());
        let mut manager = HookManager {
            hooks: Vec::new(),
            skipped: Vec::new(),
            files: Vec::new(),
            sandbox: opts.sandbox.clone(),
            project_dir: project_dir.clone(),
            session_id: String::new(),
            transcript_path: String::new(),
            permission_mode: "default".to_string(),
        };
        if opts.disable_hooks {
            return manager;
        }

        // User, nano (`[hooks]` in config.toml).
        manager.ingest_groups(&groups_from_map(opts.nano_hooks), Source::UserNano);

        // User, Claude (`~/.claude/settings.json`).
        if opts.claude_user_hooks
            && let Some(home) = dirs::home_dir()
        {
            manager.ingest_file(&home.join(".claude/settings.json"), Source::UserClaude);
        }

        // Project (committed and local), at the repository root.
        if !opts.disable_project_hooks {
            manager.ingest_file(&project_dir.join(".claude/settings.json"), Source::Project);
            manager.ingest_file(&project_dir.join(".claude/settings.local.json"), Source::ProjectLocal);
        }

        manager.dedup();
        manager
    }

    fn ingest_file(&mut self, path: &Path, source: Source) {
        let Ok(text) = std::fs::read_to_string(path) else { return };
        let hash = content_hash(&text);
        let settings: SettingsFile = match serde_json::from_str(&text) {
            Ok(settings) => settings,
            Err(e) => {
                self.skipped.push(Skipped {
                    event_name: path.display().to_string(),
                    reason: format!("could not parse settings file: {e}"),
                    source,
                });
                return;
            }
        };
        self.files.push(LoadedFile { path: path.to_path_buf(), source, hash });
        // `disableAllHooks` in a file turns off that file's hooks.
        if settings.disable_all_hooks {
            return;
        }
        self.ingest_groups(&settings.hooks, source);
    }

    fn ingest_groups(&mut self, groups: &BTreeMap<String, Vec<HookGroup>>, source: Source) {
        for (event_name, group_list) in groups {
            let event = Event::from_name(event_name);
            for group in group_list {
                for entry in &group.hooks {
                    let Some(event) = event else {
                        self.skipped.push(Skipped {
                            event_name: event_name.clone(),
                            reason: format!("event `{event_name}` not supported"),
                            source,
                        });
                        continue;
                    };
                    let kind = entry.kind.as_deref().unwrap_or("command");
                    if kind != "command" {
                        self.skipped.push(Skipped {
                            event_name: event_name.clone(),
                            reason: format!("handler type `{kind}` not supported"),
                            source,
                        });
                        continue;
                    }
                    let Some(command) = entry.command.clone().filter(|c| !c.trim().is_empty()) else {
                        self.skipped.push(Skipped {
                            event_name: event_name.clone(),
                            reason: "command hook has no `command`".to_string(),
                            source,
                        });
                        continue;
                    };
                    self.hooks.push(Hook {
                        event,
                        matcher: group.matcher.clone().filter(|m| !m.is_empty()),
                        if_rule: entry.if_rule.clone(),
                        command,
                        args: entry.args.clone(),
                        timeout: Duration::from_secs(entry.timeout.unwrap_or(DEFAULT_TIMEOUT_SECS)),
                        source,
                    });
                }
            }
        }
    }

    /// Drop duplicate handlers (same event, matcher and command/args), keeping
    /// the first — as Claude Code does.
    fn dedup(&mut self) {
        let mut seen = std::collections::HashSet::new();
        self.hooks.retain(|hook| {
            let key = (
                hook.event.claude_name(),
                hook.matcher.clone().unwrap_or_default(),
                hook.command.clone(),
                hook.args.clone().unwrap_or_default().join("\u{0}"),
            );
            seen.insert(key)
        });
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.hooks.is_empty()
    }

    #[cfg(test)]
    pub fn hooks(&self) -> &[Hook] {
        &self.hooks
    }

    /// Fill in the session identity sent to every hook as common input fields.
    pub fn set_session(&mut self, session_id: &str, transcript_path: Option<&Path>, permission_mode: &str) {
        self.session_id = session_id.to_string();
        self.transcript_path = transcript_path.map(|p| p.display().to_string()).unwrap_or_default();
        self.permission_mode = permission_mode.to_string();
    }

    /// One-line startup notice, e.g.
    /// `hooks: 2 from .claude/settings.json (PreToolUse, PostToolUse); 1 skipped (http)`.
    /// `None` when there are no project hooks and nothing was skipped.
    pub fn startup_notice(&self) -> Option<String> {
        let project: Vec<&Hook> = self.hooks.iter().filter(|h| h.source.is_project()).collect();
        let project_skipped =
            self.skipped.iter().filter(|s| matches!(s.source, Source::Project | Source::ProjectLocal)).count();
        if project.is_empty() && project_skipped == 0 {
            return None;
        }
        let mut events: Vec<&str> = project.iter().map(|h| h.event.claude_name()).collect();
        events.sort_unstable();
        events.dedup();
        let mut notice = format!(
            "hooks: {} from .claude/settings.json ({})",
            project.len(),
            if events.is_empty() { "none".to_string() } else { events.join(", ") }
        );
        if project_skipped > 0 {
            notice.push_str(&format!("; {project_skipped} skipped"));
        }
        Some(notice)
    }

    /// Lines for the `/hooks` command: every hook with its source, then every
    /// skipped hook and the reason.
    pub fn listing(&self) -> String {
        let mut out = String::new();
        if self.hooks.is_empty() {
            out.push_str("No hooks loaded.\n");
        } else {
            out.push_str("Hooks:\n");
            for hook in &self.hooks {
                let matcher = hook.matcher.as_deref().unwrap_or("*");
                out.push_str(&format!(
                    "  [{}] {} {} -> {}\n",
                    hook.source.label(),
                    hook.event.claude_name(),
                    matcher,
                    hook.command
                ));
            }
        }
        if !self.skipped.is_empty() {
            out.push_str("Skipped:\n");
            for skipped in &self.skipped {
                out.push_str(&format!("  [{}] {}: {}\n", skipped.source.label(), skipped.event_name, skipped.reason));
            }
        }
        if !self.files.is_empty() {
            out.push_str("Loaded from:\n");
            for file in &self.files {
                out.push_str(&format!(
                    "  [{}] {} ({})\n",
                    file.source.label(),
                    file.path.display(),
                    file.hash
                ));
            }
        }
        out
    }

    /// Hooks for `event` whose matcher and `if` rule select this call. For
    /// non-tool events, `tool`/`args` are empty and only the matcher (usually
    /// absent) applies.
    fn selected(&self, event: Event, tool: Option<(&str, &str, &Value)>) -> Vec<&Hook> {
        self.hooks
            .iter()
            .filter(|hook| hook.event == event)
            .filter(|hook| match tool {
                Some((claude_name, nano_name, args)) => matcher_selects(hook.matcher.as_deref(), claude_name, nano_name)
                    && if_selects(hook.if_rule.as_deref(), nano_name, args),
                None => hook.matcher.is_none(),
            })
            .collect()
    }

    fn common_input(&self, event: Event) -> serde_json::Map<String, Value> {
        let mut map = serde_json::Map::new();
        map.insert("session_id".into(), json!(self.session_id));
        map.insert("transcript_path".into(), json!(self.transcript_path));
        map.insert("cwd".into(), json!(self.project_dir.display().to_string()));
        map.insert("permission_mode".into(), json!(self.permission_mode));
        map.insert("hook_event_name".into(), json!(event.claude_name()));
        map
    }

    /// Run the `SessionStart` hooks; returns context to add to the session.
    pub fn run_session_start(&self, trigger: &str) -> Outcome {
        let hooks = self.selected(Event::SessionStart, None);
        let mut input = self.common_input(Event::SessionStart);
        input.insert("source".into(), json!(trigger));
        self.run_all(&hooks, Event::SessionStart, &Value::Object(input))
    }

    /// Run the `UserPromptSubmit` hooks; a block rejects the prompt.
    pub fn run_user_prompt_submit(&self, prompt: &str) -> Outcome {
        let hooks = self.selected(Event::UserPromptSubmit, None);
        let mut input = self.common_input(Event::UserPromptSubmit);
        input.insert("prompt".into(), json!(prompt));
        self.run_all(&hooks, Event::UserPromptSubmit, &Value::Object(input))
    }

    /// Run the `PreToolUse` hooks for `nano_tool` (called after `permissions`
    /// has allowed the call, before it runs).
    pub fn run_pre_tool_use(&self, nano_tool: &str, args: &Value, tool_use_id: &str) -> Outcome {
        let claude_name = claude_tool_name(nano_tool);
        let hooks = self.selected(Event::PreToolUse, Some((&claude_name, nano_tool, args)));
        let mut input = self.common_input(Event::PreToolUse);
        input.insert("tool_name".into(), json!(claude_name));
        input.insert("tool_input".into(), tool_input_for(nano_tool, args));
        input.insert("tool_use_id".into(), json!(tool_use_id));
        self.run_all(&hooks, Event::PreToolUse, &Value::Object(input))
    }

    /// Run the `PostToolUse` hooks after `nano_tool` ran.
    pub fn run_post_tool_use(&self, nano_tool: &str, args: &Value, response: &str, tool_use_id: &str) -> Outcome {
        let claude_name = claude_tool_name(nano_tool);
        let hooks = self.selected(Event::PostToolUse, Some((&claude_name, nano_tool, args)));
        let mut input = self.common_input(Event::PostToolUse);
        input.insert("tool_name".into(), json!(claude_name));
        input.insert("tool_input".into(), tool_input_for(nano_tool, args));
        input.insert("tool_response".into(), json!(response));
        input.insert("tool_use_id".into(), json!(tool_use_id));
        self.run_all(&hooks, Event::PostToolUse, &Value::Object(input))
    }

    /// Run the `Stop` hooks when the agent is about to end its turn. A block
    /// keeps it going with the reason as the next message.
    pub fn run_stop(&self, stop_hook_active: bool) -> Outcome {
        let hooks = self.selected(Event::Stop, None);
        let mut input = self.common_input(Event::Stop);
        input.insert("stop_hook_active".into(), json!(stop_hook_active));
        self.run_all(&hooks, Event::Stop, &Value::Object(input))
    }

    fn run_all(&self, hooks: &[&Hook], event: Event, input: &Value) -> Outcome {
        let mut outcome = Outcome::default();
        for hook in hooks {
            let result = run_one(hook, event, input, &self.sandbox, &self.project_dir);
            outcome.absorb(event, result);
        }
        outcome
    }
}

// ---------------------------------------------------------------------------
// Matching.
// ---------------------------------------------------------------------------

/// A `matcher` selects a tool call when it matches the Claude name or the nano
/// name (so `Edit|Write` and `edit_file` both work). Supports exact, `A|B`
/// alternation and a regex. An absent or `*`/empty matcher matches everything.
fn matcher_selects(matcher: Option<&str>, claude_name: &str, nano_name: &str) -> bool {
    let Some(matcher) = matcher else { return true };
    let matcher = matcher.trim();
    if matcher.is_empty() || matcher == "*" {
        return true;
    }
    let hit = |pat: &str| {
        let pat = pat.trim();
        pat == claude_name || pat == nano_name
    };
    if matcher.split('|').any(hit) {
        return true;
    }
    // Fall back to a full-match regex (Claude supports regex matchers).
    if let Ok(re) = regex::Regex::new(&format!("^(?:{matcher})$")) {
        return re.is_match(claude_name) || re.is_match(nano_name);
    }
    false
}

/// An `if` rule (permission-rule syntax, e.g. `Bash(git push *)`) further
/// narrows a tool hook. Absent means no extra filter.
fn if_selects(if_rule: Option<&str>, nano_name: &str, args: &Value) -> bool {
    match if_rule {
        None => true,
        Some(rule) => permissions::rule_matches(rule, nano_name, args),
    }
}

// ---------------------------------------------------------------------------
// Tool-name and input translation (nano <-> Claude).
// ---------------------------------------------------------------------------

/// nano's tool name as presented to Claude hooks.
pub fn claude_tool_name(nano_tool: &str) -> String {
    match nano_tool {
        "bash" => "Bash",
        "read_file" => "Read",
        "write_file" => "Write",
        "edit_file" => "Edit",
        "grep" => "Grep",
        "glob" => "Glob",
        other => return other.to_string(),
    }
    .to_string()
}

/// nano's tool arguments presented as Claude's `tool_input`.
fn tool_input_for(nano_tool: &str, args: &Value) -> Value {
    let get = |key: &str| args.get(key).cloned();
    match nano_tool {
        "read_file" => {
            let mut map = serde_json::Map::new();
            if let Some(path) = get("path") {
                map.insert("file_path".into(), path);
            }
            for key in ["offset", "limit"] {
                if let Some(v) = get(key) {
                    map.insert(key.into(), v);
                }
            }
            Value::Object(map)
        }
        "write_file" => {
            let mut map = serde_json::Map::new();
            if let Some(path) = get("path") {
                map.insert("file_path".into(), path);
            }
            if let Some(content) = get("content") {
                map.insert("content".into(), content);
            }
            Value::Object(map)
        }
        "edit_file" => {
            let mut map = serde_json::Map::new();
            if let Some(path) = get("path") {
                map.insert("file_path".into(), path);
            }
            for key in ["old_string", "new_string", "replace_all"] {
                if let Some(v) = get(key) {
                    map.insert(key.into(), v);
                }
            }
            Value::Object(map)
        }
        // bash and other tools pass their arguments through unchanged.
        _ => args.clone(),
    }
}

/// Translate a hook's `updatedInput` (Claude `tool_input` space) back into
/// nano's argument space, merged onto the original arguments.
pub fn apply_updated_input(nano_tool: &str, original: &Value, updated: &Value) -> Value {
    let Some(updated) = updated.as_object() else { return original.clone() };
    let mut args = original.as_object().cloned().unwrap_or_default();
    let rename = |key: &str| -> String {
        match (nano_tool, key) {
            ("read_file" | "write_file" | "edit_file", "file_path") => "path".to_string(),
            _ => key.to_string(),
        }
    };
    for (key, value) in updated {
        args.insert(rename(key), value.clone());
    }
    Value::Object(args)
}

// ---------------------------------------------------------------------------
// Running one hook and reading its output.
// ---------------------------------------------------------------------------

/// How one hook resolved, normalized across events.
struct HookResult {
    /// A hard block: exit 2, `permissionDecision: deny`, `decision: block`, or a
    /// fail-closed `PreToolUse` failure.
    blocked: bool,
    reason: Option<String>,
    /// `PreToolUse` `permissionDecision`.
    decision: Option<Decision>,
    /// `updatedInput` (Claude `tool_input` space).
    updated_input: Option<Value>,
    context: Vec<String>,
    /// `continue: false` with its `stopReason`.
    stop: Option<String>,
    system_message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny,
    Ask,
}

fn run_one(hook: &Hook, event: Event, input: &Value, sandbox: &SandboxConfig, project_dir: &Path) -> HookResult {
    let input_json = input.to_string();
    let run = execute(hook, &input_json, sandbox, project_dir, hook.timeout);
    interpret(event, hook, run)
}

/// Raw result of running the hook process.
struct ProcessRun {
    exit: Option<i32>,
    timed_out: bool,
    launch_error: Option<String>,
    stdout: String,
    stderr: String,
}

fn execute(
    hook: &Hook,
    input_json: &str,
    sandbox: &SandboxConfig,
    project_dir: &Path,
    timeout: Duration,
) -> ProcessRun {
    let dir = project_dir.display().to_string();
    // Project hooks run inside the sandbox when one is active; user hooks run
    // outside it.
    let use_sandbox = sandbox.active() && hook.source.is_project();

    let mut command = if use_sandbox {
        let script = sandbox_script(hook, &dir);
        match sandbox::command(sandbox, "bash", &script, project_dir) {
            Ok(sandboxed) => sandboxed.command,
            Err(e) => {
                // The sandbox fails closed: a hook that can't be sandboxed
                // counts as failed (so a PreToolUse hook blocks the call).
                return ProcessRun {
                    exit: None,
                    timed_out: false,
                    launch_error: Some(format!("sandbox could not be applied: {e}")),
                    stdout: String::new(),
                    stderr: String::new(),
                };
            }
        }
    } else if let Some(args) = &hook.args {
        // Exec form: run the program directly, expanding ${CLAUDE_PROJECT_DIR}.
        let mut command = Command::new(expand_project_dir(&hook.command, &dir));
        for arg in args {
            command.arg(expand_project_dir(arg, &dir));
        }
        command
    } else {
        // Shell form: the shell expands $CLAUDE_PROJECT_DIR itself.
        let mut command = Command::new("bash");
        command.arg("-c").arg(&hook.command);
        command
    };

    command
        .current_dir(project_dir)
        .env("CLAUDE_PROJECT_DIR", &dir)
        .env("NANO_CODER", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            return ProcessRun {
                exit: None,
                timed_out: false,
                launch_error: Some(format!("could not start hook: {e}")),
                stdout: String::new(),
                stderr: String::new(),
            };
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input_json.as_bytes());
        // Drop closes the pipe so the hook sees EOF.
    }

    let pid = child.id();
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });

    let output = match rx.recv_timeout(timeout) {
        Ok(result) => {
            let _ = handle.join();
            result.ok()
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            kill_process_group(pid);
            let _ = rx.recv();
            let _ = handle.join();
            return ProcessRun {
                exit: None,
                timed_out: true,
                launch_error: None,
                stdout: String::new(),
                stderr: String::new(),
            };
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            let _ = handle.join();
            None
        }
    };

    match output {
        Some(output) => ProcessRun {
            exit: output.status.code(),
            timed_out: false,
            launch_error: None,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        },
        None => ProcessRun {
            exit: None,
            timed_out: false,
            launch_error: Some("hook did not complete".to_string()),
            stdout: String::new(),
            stderr: String::new(),
        },
    }
}

#[cfg(unix)]
fn kill_process_group(pid: u32) {
    // SAFETY: killpg signals only the hook's own process group.
    unsafe {
        libc::killpg(pid as libc::pid_t, libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_process_group(_pid: u32) {}

/// Build a shell script for the sandbox from a hook's shell or exec form.
fn sandbox_script(hook: &Hook, dir: &str) -> String {
    match &hook.args {
        None => hook.command.clone(),
        Some(args) => {
            let mut parts = vec![shell_quote(&expand_project_dir(&hook.command, dir))];
            for arg in args {
                parts.push(shell_quote(&expand_project_dir(arg, dir)));
            }
            parts.join(" ")
        }
    }
}

fn expand_project_dir(text: &str, dir: &str) -> String {
    text.replace("${CLAUDE_PROJECT_DIR}", dir).replace("$CLAUDE_PROJECT_DIR", dir)
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// Interpret a process run into a normalized [`HookResult`] per the Claude
/// protocol, with nano's fail-closed `PreToolUse` behavior.
fn interpret(event: Event, hook: &Hook, run: ProcessRun) -> HookResult {
    let mut result = HookResult {
        blocked: false,
        reason: None,
        decision: None,
        updated_input: None,
        context: Vec::new(),
        stop: None,
        system_message: None,
    };

    // Launch failure, timeout, or an unexpected exit code.
    let failure = run.launch_error.clone().or_else(|| {
        if run.timed_out {
            Some(format!("hook timed out after {}s", hook.timeout.as_secs()))
        } else {
            match run.exit {
                Some(0) | Some(2) => None,
                Some(code) => Some(format!("hook exited with code {code}")),
                None => Some("hook was terminated".to_string()),
            }
        }
    });

    if let Some(message) = failure {
        if event == Event::PreToolUse {
            // Fail closed: a PreToolUse hook that crashes blocks the call.
            result.blocked = true;
            result.decision = Some(Decision::Deny);
            result.reason = Some(format!("{} ({message})", hook.command));
        }
        // All other events: non-blocking, like Claude. Stderr still surfaces.
        return result;
    }

    // Exit 2: block, with stderr as the reason.
    if run.exit == Some(2) {
        result.blocked = true;
        result.reason = Some(cap(run.stderr.trim()));
        if event == Event::PreToolUse {
            result.decision = Some(Decision::Deny);
        }
        return result;
    }

    // Exit 0: parse stdout as JSON if it is a JSON object; otherwise, for
    // SessionStart and UserPromptSubmit, plain text becomes context.
    let trimmed = run.stdout.trim();
    let parsed = if trimmed.starts_with('{') { serde_json::from_str::<Value>(trimmed).ok() } else { None };

    match parsed {
        Some(json) => apply_json_output(event, json, &mut result),
        None => {
            if !trimmed.is_empty() && matches!(event, Event::SessionStart | Event::UserPromptSubmit) {
                result.context.push(cap(trimmed));
            }
        }
    }
    result
}

fn apply_json_output(event: Event, json: Value, result: &mut HookResult) {
    let get_str = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).map(|s| cap(s));

    if json.get("continue").and_then(Value::as_bool) == Some(false) {
        result.stop = Some(get_str(&json, "stopReason").unwrap_or_default());
    }
    if let Some(msg) = get_str(&json, "systemMessage") {
        result.system_message = Some(msg);
    }

    // `decision` / `reason` (used by PostToolUse `block`, Stop, UserPromptSubmit).
    match json.get("decision").and_then(Value::as_str) {
        Some("block") => {
            result.blocked = true;
            result.reason = get_str(&json, "reason");
        }
        Some("approve") | Some("allow") => {
            if event == Event::PreToolUse {
                result.decision = Some(Decision::Allow);
            }
        }
        _ => {}
    }

    // hookSpecificOutput.
    if let Some(specific) = json.get("hookSpecificOutput") {
        if let Some(ctx) = get_str(specific, "additionalContext") {
            result.context.push(ctx);
        }
        if event == Event::PreToolUse {
            match specific.get("permissionDecision").and_then(Value::as_str) {
                Some("allow") => result.decision = Some(Decision::Allow),
                Some("deny") => {
                    result.decision = Some(Decision::Deny);
                    result.blocked = true;
                    result.reason = get_str(specific, "permissionDecisionReason").or(result.reason.take());
                }
                Some("ask") => result.decision = Some(Decision::Ask),
                _ => {}
            }
            if let Some(updated) = specific.get("updatedInput") {
                result.updated_input = Some(updated.clone());
            }
        }
    }

    // Top-level additionalContext (SessionStart/UserPromptSubmit also accept it).
    if let Some(ctx) = get_str(&json, "additionalContext") {
        result.context.push(ctx);
    }
}

fn cap(text: &str) -> String {
    if text.len() <= FIELD_CAP {
        text.to_string()
    } else {
        let mut end = FIELD_CAP;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}…", &text[..end])
    }
}

// ---------------------------------------------------------------------------
// Combined outcome for one event.
// ---------------------------------------------------------------------------

/// The combined result of every hook that ran for one event. Decisions combine
/// as deny beats ask beats allow; all `additionalContext` values are kept.
#[derive(Debug, Default)]
pub struct Outcome {
    pub blocked: bool,
    pub block_reason: Option<String>,
    pub decision: Option<Decision>,
    pub updated_input: Option<Value>,
    pub context: Vec<String>,
    pub stop: Option<String>,
    pub system_messages: Vec<String>,
}

impl Outcome {
    fn absorb(&mut self, _event: Event, result: HookResult) {
        if result.blocked {
            self.blocked = true;
            if self.block_reason.is_none() {
                self.block_reason = result.reason.clone();
            } else if let Some(reason) = &result.reason
                && !reason.is_empty()
            {
                self.block_reason = Some(reason.clone());
            }
        }
        // deny > ask > allow.
        self.decision = combine_decision(self.decision, result.decision);
        if let Some(updated) = result.updated_input {
            self.updated_input = Some(updated);
        }
        self.context.extend(result.context);
        if result.stop.is_some() && self.stop.is_none() {
            self.stop = result.stop;
        }
        if let Some(msg) = result.system_message {
            self.system_messages.push(msg);
        }
    }

    /// The combined additional context, if any, as one block.
    pub fn context_block(&self) -> Option<String> {
        if self.context.is_empty() {
            None
        } else {
            Some(self.context.join("\n\n"))
        }
    }

    /// Whether this (tool) outcome denies the call outright.
    pub fn denies(&self) -> bool {
        self.blocked || self.decision == Some(Decision::Deny)
    }
}

fn combine_decision(a: Option<Decision>, b: Option<Decision>) -> Option<Decision> {
    let rank = |d: Option<Decision>| match d {
        Some(Decision::Deny) => 3,
        Some(Decision::Ask) => 2,
        Some(Decision::Allow) => 1,
        None => 0,
    };
    if rank(a) >= rank(b) { a } else { b }
}

/// A short, stable hash of a settings file's contents for the audit log.
fn content_hash(text: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn groups_from_map(map: &NanoHooks) -> BTreeMap<String, Vec<HookGroup>> {
    map.clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn write_script(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    fn manager_with(hooks: Vec<Hook>, dir: &Path) -> HookManager {
        HookManager {
            hooks,
            skipped: Vec::new(),
            files: Vec::new(),
            sandbox: SandboxConfig::default(),
            project_dir: dir.to_path_buf(),
            session_id: "s1".into(),
            transcript_path: String::new(),
            permission_mode: "default".into(),
        }
    }

    fn command_hook(event: Event, command: &str) -> Hook {
        Hook {
            event,
            matcher: None,
            if_rule: None,
            command: command.to_string(),
            args: None,
            timeout: Duration::from_secs(10),
            source: Source::UserNano,
        }
    }

    #[test]
    fn matcher_matches_claude_and_nano_names() {
        assert!(matcher_selects(Some("Edit|Write"), "Edit", "edit_file"));
        assert!(matcher_selects(Some("edit_file"), "Edit", "edit_file"));
        assert!(matcher_selects(Some("Bash"), "Bash", "bash"));
        assert!(!matcher_selects(Some("Read"), "Bash", "bash"));
        assert!(matcher_selects(None, "Bash", "bash"));
        assert!(matcher_selects(Some("*"), "Bash", "bash"));
        // Regex matcher.
        assert!(matcher_selects(Some("Edit|Write|Read"), "Read", "read_file"));
    }

    #[test]
    fn translates_tool_input_both_ways() {
        let args = json!({"path": "a.txt", "old_string": "x", "new_string": "y"});
        let input = tool_input_for("edit_file", &args);
        assert_eq!(input["file_path"], json!("a.txt"));
        assert_eq!(input["old_string"], json!("x"));
        assert!(input.get("path").is_none());

        let updated = json!({"file_path": "b.txt", "new_string": "z"});
        let back = apply_updated_input("edit_file", &args, &updated);
        assert_eq!(back["path"], json!("b.txt"));
        assert_eq!(back["new_string"], json!("z"));
        assert_eq!(back["old_string"], json!("x"));
    }

    #[test]
    fn reads_tool_input_command_like_a_claude_script() {
        // A real Claude-style hook: jq reads .tool_input.command, exits 2 to block.
        let dir = tempfile::tempdir().unwrap();
        let script = write_script(
            dir.path(),
            "guard.sh",
            "#!/usr/bin/env bash\nread -r line\necho \"$line\" | grep -q 'rm -rf' && exit 2\nexit 0\n",
        );
        let hook = command_hook(Event::PreToolUse, &format!("{} ", script.display()));
        let manager = manager_with(vec![hook], dir.path());

        let blocked = manager.run_pre_tool_use("bash", &json!({"command": "rm -rf /"}), "t1");
        assert!(blocked.denies(), "rm -rf is blocked");

        let ok = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t2");
        assert!(!ok.denies(), "ls is allowed");
    }

    #[test]
    fn pre_tool_use_json_permission_decision() {
        let dir = tempfile::tempdir().unwrap();
        let script = write_script(
            dir.path(),
            "deny.sh",
            "#!/usr/bin/env bash\ncat >/dev/null\necho '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"nope\"}}'\n",
        );
        let hook = command_hook(Event::PreToolUse, &script.display().to_string());
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(outcome.denies());
        assert_eq!(outcome.block_reason.as_deref(), Some("nope"));
        assert_eq!(outcome.decision, Some(Decision::Deny));
    }

    #[test]
    fn pre_tool_use_fails_closed_on_crash() {
        let dir = tempfile::tempdir().unwrap();
        let hook = command_hook(Event::PreToolUse, "exit 7");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(outcome.denies(), "an unexpected exit code blocks PreToolUse");
    }

    #[test]
    fn post_tool_use_crash_is_non_blocking() {
        let dir = tempfile::tempdir().unwrap();
        let hook = command_hook(Event::PostToolUse, "exit 7");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_post_tool_use("bash", &json!({"command": "ls"}), "ok", "t1");
        assert!(!outcome.blocked, "a crashing PostToolUse hook does not block");
    }

    #[test]
    fn session_start_plain_text_becomes_context() {
        let dir = tempfile::tempdir().unwrap();
        let hook = command_hook(Event::SessionStart, "echo hello world");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_session_start("startup");
        assert_eq!(outcome.context_block().as_deref(), Some("hello world"));
    }

    #[test]
    fn user_prompt_submit_exit_2_blocks_with_stderr() {
        let dir = tempfile::tempdir().unwrap();
        let hook = command_hook(Event::UserPromptSubmit, "echo secret-detected >&2; exit 2");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_user_prompt_submit("hi");
        assert!(outcome.blocked);
        assert_eq!(outcome.block_reason.as_deref(), Some("secret-detected"));
    }

    #[test]
    fn hook_receives_env_and_updated_input() {
        let dir = tempfile::tempdir().unwrap();
        let script = write_script(
            dir.path(),
            "update.sh",
            "#!/usr/bin/env bash\ncat >/dev/null\n[ \"$NANO_CODER\" = 1 ] || exit 2\necho '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"echo patched\"}}}'\n",
        );
        let hook = command_hook(Event::PreToolUse, &script.display().to_string());
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "echo original"}), "t1");
        assert_eq!(outcome.decision, Some(Decision::Allow));
        let updated = outcome.updated_input.unwrap();
        assert_eq!(updated["command"], json!("echo patched"));
    }

    #[test]
    fn if_rule_narrows_tool_hooks() {
        let dir = tempfile::tempdir().unwrap();
        let mut hook = command_hook(Event::PreToolUse, "exit 2");
        hook.if_rule = Some("Bash(git push *)".to_string());
        let manager = manager_with(vec![hook], dir.path());
        // Does not match: not blocked.
        assert!(!manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1").denies());
        // Matches: blocked.
        assert!(manager.run_pre_tool_use("bash", &json!({"command": "git push origin main"}), "t2").denies());
    }

    #[test]
    fn stop_block_keeps_going() {
        let dir = tempfile::tempdir().unwrap();
        let hook = command_hook(Event::Stop, "echo '{\"decision\":\"block\",\"reason\":\"keep going\"}'");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_stop(false);
        assert!(outcome.blocked);
        assert_eq!(outcome.block_reason.as_deref(), Some("keep going"));
    }

    #[test]
    fn timeout_blocks_pre_tool_use_only() {
        let dir = tempfile::tempdir().unwrap();
        let mut hook = command_hook(Event::PreToolUse, "sleep 5");
        hook.timeout = Duration::from_millis(200);
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(outcome.denies(), "a timed-out PreToolUse hook fails closed");
    }

    #[test]
    fn loads_and_dedups_from_settings_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        std::fs::write(
            dir.path().join(".claude/settings.json"),
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}],
                        "Nope":[{"hooks":[{"type":"command","command":"x"}]}],
                        "PostToolUse":[{"hooks":[{"type":"http","command":"x"}]}]}}"#,
        )
        .unwrap();
        let nano = NanoHooks::new();
        let opts = LoadOptions {
            disable_hooks: false,
            disable_project_hooks: false,
            claude_user_hooks: false,
            nano_hooks: &nano,
            sandbox: SandboxConfig::default(),
        };
        let manager = HookManager::load(&opts, dir.path());
        assert_eq!(manager.hooks().len(), 1);
        assert_eq!(manager.hooks()[0].event, Event::PreToolUse);
        // Unsupported event and handler type are both reported, not dropped.
        assert_eq!(manager.skipped.len(), 2);
        assert!(manager.startup_notice().is_some());
        assert_eq!(manager.files.len(), 1);
    }

    #[test]
    fn disable_flags_turn_hooks_off() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        std::fs::write(
            dir.path().join(".claude/settings.json"),
            r#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#,
        )
        .unwrap();
        let nano = NanoHooks::new();
        let disabled = LoadOptions {
            disable_hooks: true,
            disable_project_hooks: false,
            claude_user_hooks: false,
            nano_hooks: &nano,
            sandbox: SandboxConfig::default(),
        };
        assert!(HookManager::load(&disabled, dir.path()).is_empty());

        let no_project = LoadOptions {
            disable_hooks: false,
            disable_project_hooks: true,
            claude_user_hooks: false,
            nano_hooks: &nano,
            sandbox: SandboxConfig::default(),
        };
        assert!(HookManager::load(&no_project, dir.path()).is_empty());
    }

    #[test]
    fn disable_all_hooks_in_a_file_is_honored() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        std::fs::write(
            dir.path().join(".claude/settings.json"),
            r#"{"disableAllHooks":true,"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#,
        )
        .unwrap();
        let nano = NanoHooks::new();
        let opts = LoadOptions {
            disable_hooks: false,
            disable_project_hooks: false,
            claude_user_hooks: false,
            nano_hooks: &nano,
            sandbox: SandboxConfig::default(),
        };
        let manager = HookManager::load(&opts, dir.path());
        assert!(manager.is_empty());
        assert_eq!(manager.files.len(), 1, "the file is still recorded for the audit log");
    }
}
