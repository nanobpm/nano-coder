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
/// Cap on the raw stdout/stderr a hook may emit before the result is treated as
/// a failure. Generous (well above `FIELD_CAP`, so legitimately large but valid
/// JSON still parses) yet bounded, so a noisy hook cannot exhaust the agent's
/// memory while it runs.
const OUTPUT_CAP: usize = 1_000_000;
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
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            // A missing file is normal (most settings files are optional); say
            // nothing. Any *other* read failure (permissions, invalid UTF-8, …)
            // means a present file's hooks silently never load, so report it as
            // a skipped entry — as the parser already does for invalid JSON.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
            Err(e) => {
                self.skipped.push(Skipped {
                    event_name: path.display().to_string(),
                    reason: format!("could not read settings file: {e}"),
                    source,
                });
                return;
            }
        };
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
                    // Validate the `if` filter now rather than at call time:
                    // `permissions::rule_matches` returns `false` for a malformed
                    // rule, so a broken filter (e.g. `Bash(git push *`, missing
                    // its closing `)`) would silently never run while `/hooks`
                    // still lists it as loaded. Report it as skipped instead.
                    if let Some(rule) = entry.if_rule.as_deref().filter(|r| !r.trim().is_empty())
                        && let Err(err) = permissions::validate_rule(rule)
                    {
                        self.skipped.push(Skipped {
                            event_name: event_name.clone(),
                            reason: format!("invalid `if` filter {rule:?}: {err}"),
                            source,
                        });
                        continue;
                    }
                    // Normalize a blank/whitespace-only `if` to `None`. Stored as
                    // `Some("  ")`, it would reach `if_selects` -> `Rule::parse`,
                    // which fails, so the hook would never run despite being
                    // listed as loaded — the same silent-disable the validation
                    // above rejects for a malformed rule. A blank filter means
                    // "no filter", so treat it as absent.
                    let if_rule = entry.if_rule.clone().filter(|r| !r.trim().is_empty());
                    self.hooks.push(Hook {
                        event,
                        matcher: group.matcher.clone().filter(|m| !m.is_empty()),
                        if_rule,
                        command,
                        args: entry.args.clone(),
                        timeout: Duration::from_secs(entry.timeout.unwrap_or(DEFAULT_TIMEOUT_SECS)),
                        source,
                    });
                }
            }
        }
    }

    /// Drop duplicate handlers (same event, matcher, `if` rule and
    /// command/args), keeping the first — as Claude Code does. The `if` rule is
    /// part of the identity: two entries with the same command and matcher but
    /// different filters (e.g. `Bash(git push *)` vs `Bash(git commit *)`) are
    /// distinct, and collapsing them would drop the calls only the second
    /// filter matches. `args` is kept optional: `None` means shell execution
    /// while `Some([])` means direct execution, so they must not compare equal.
    fn dedup(&mut self) {
        let mut seen = std::collections::HashSet::new();
        self.hooks.retain(|hook| {
            let key = (
                hook.event.claude_name(),
                hook.matcher.clone().unwrap_or_default(),
                hook.if_rule.clone().unwrap_or_default(),
                hook.command.clone(),
                hook.args.as_ref().map(|args| args.join("\u{0}")),
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
                    listing_field(matcher),
                    listing_field(&hook.command)
                ));
            }
        }
        if !self.skipped.is_empty() {
            out.push_str("Skipped:\n");
            for skipped in &self.skipped {
                out.push_str(&format!(
                    "  [{}] {}: {}\n",
                    skipped.source.label(),
                    listing_field(&skipped.event_name),
                    listing_field(&skipped.reason)
                ));
            }
        }
        if !self.files.is_empty() {
            out.push_str("Loaded from:\n");
            for file in &self.files {
                out.push_str(&format!(
                    "  [{}] {} ({})\n",
                    file.source.label(),
                    listing_field(&file.path.display().to_string()),
                    file.hash
                ));
            }
        }
        out
    }

    /// Hooks for `event` whose matcher and `if` rule select this call. For
    /// tool events, `tool` carries the Claude/nano names and arguments. For
    /// `SessionStart`, `trigger` carries the source (`startup`/`resume`) that
    /// the matcher (`startup`, `resume`, `*`, or an alternation) is tested
    /// against. For the remaining non-tool events (`UserPromptSubmit`, `Stop`)
    /// Claude ignores the matcher, so every hook for the event is selected.
    fn selected(&self, event: Event, tool: Option<(&str, &str, &Value)>, trigger: Option<&str>) -> Vec<&Hook> {
        self.hooks
            .iter()
            .filter(|hook| hook.event == event)
            .filter(|hook| match tool {
                Some((claude_name, nano_name, args)) => {
                    matcher_selects(hook.matcher.as_deref(), claude_name, nano_name)
                        && if_selects(hook.if_rule.as_deref(), nano_name, args)
                }
                None => match trigger {
                    // `SessionStart` groups select on their source trigger, so a
                    // `startup`/`resume`/`*` matcher runs rather than being
                    // excluded for having any matcher at all.
                    Some(source) => source_matcher_selects(hook.matcher.as_deref(), source),
                    // `UserPromptSubmit`/`Stop`: the matcher does not apply.
                    None => true,
                },
            })
            .collect()
    }

    fn common_input(&self, event: Event) -> serde_json::Map<String, Value> {
        let mut map = serde_json::Map::new();
        map.insert("session_id".into(), json!(self.session_id));
        map.insert("transcript_path".into(), json!(self.transcript_path));
        // Report the directory tools actually resolve relative paths against
        // (the process working directory), not the repository root: a hook that
        // combines `cwd` with a tool's relative `file_path` must land on the
        // file the tool touched. `CLAUDE_PROJECT_DIR` still carries the project
        // root, so project-level hooks keep their anchor.
        let cwd = std::env::current_dir().unwrap_or_else(|_| self.project_dir.clone());
        map.insert("cwd".into(), json!(cwd.display().to_string()));
        map.insert("permission_mode".into(), json!(self.permission_mode));
        map.insert("hook_event_name".into(), json!(event.claude_name()));
        map
    }

    /// Run the `SessionStart` hooks; returns context to add to the session.
    pub fn run_session_start(&self, trigger: &str) -> Outcome {
        let hooks = self.selected(Event::SessionStart, None, Some(trigger));
        let mut input = self.common_input(Event::SessionStart);
        input.insert("source".into(), json!(trigger));
        self.run_all(&hooks, Event::SessionStart, &Value::Object(input))
    }

    /// Run the `UserPromptSubmit` hooks; a block rejects the prompt.
    pub fn run_user_prompt_submit(&self, prompt: &str) -> Outcome {
        let hooks = self.selected(Event::UserPromptSubmit, None, None);
        let mut input = self.common_input(Event::UserPromptSubmit);
        input.insert("prompt".into(), json!(prompt));
        self.run_all(&hooks, Event::UserPromptSubmit, &Value::Object(input))
    }

    /// Run the `PreToolUse` hooks for `nano_tool` (called after `permissions`
    /// has allowed the call, before it runs).
    pub fn run_pre_tool_use(&self, nano_tool: &str, args: &Value, tool_use_id: &str) -> Outcome {
        let claude_name = claude_tool_name(nano_tool);
        let hooks = self.selected(Event::PreToolUse, Some((&claude_name, nano_tool, args)), None);
        let mut input = self.common_input(Event::PreToolUse);
        input.insert("tool_name".into(), json!(claude_name));
        input.insert("tool_input".into(), tool_input_for(nano_tool, args));
        input.insert("tool_use_id".into(), json!(tool_use_id));
        self.run_all(&hooks, Event::PreToolUse, &Value::Object(input))
    }

    /// Run the `PostToolUse` hooks after `nano_tool` ran.
    pub fn run_post_tool_use(&self, nano_tool: &str, args: &Value, response: &str, tool_use_id: &str) -> Outcome {
        let claude_name = claude_tool_name(nano_tool);
        let hooks = self.selected(Event::PostToolUse, Some((&claude_name, nano_tool, args)), None);
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
        let hooks = self.selected(Event::Stop, None, None);
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

/// A `SessionStart` matcher selects on the session's source trigger
/// (`startup`/`resume`). An absent, empty or `*` matcher matches every source;
/// otherwise the source is tested against the matcher's alternation or a
/// full-match regex, so a group keyed `startup`, `resume` or `startup|resume`
/// runs for the matching source instead of being excluded for having a matcher.
fn source_matcher_selects(matcher: Option<&str>, source: &str) -> bool {
    let Some(matcher) = matcher else { return true };
    let matcher = matcher.trim();
    if matcher.is_empty() || matcher == "*" {
        return true;
    }
    if matcher.split('|').any(|pat| pat.trim() == source) {
        return true;
    }
    if let Ok(re) = regex::Regex::new(&format!("^(?:{matcher})$")) {
        return re.is_match(source);
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
    // Reject an unrepresentable timeout *before* spawning: `Instant::now() +
    // timeout` panics on overflow (e.g. a `u64::MAX`-second timeout), which
    // would abort the agent after the hook was already spawned. Failing closed
    // here turns a bad config into a hook failure (PreToolUse blocks the call)
    // instead of a crash.
    let Some(deadline) = std::time::Instant::now().checked_add(timeout) else {
        return ProcessRun {
            exit: None,
            timed_out: false,
            launch_error: Some(format!("hook timeout of {}s is not representable", timeout.as_secs())),
            stdout: String::new(),
            stderr: String::new(),
        };
    };
    let dir = project_dir.display().to_string();
    // Project hooks run inside the sandbox when one is active; user hooks run
    // outside it.
    let use_sandbox = sandbox.active() && hook.source.is_project();

    // The sandbox wrapper (`Sandboxed`) owns the Linux ruleset fd that must
    // stay open until the child is spawned. Hold it in `sandboxed` and *borrow*
    // its command rather than moving the command out (which would drop the
    // wrapper, and with it the ruleset, before `spawn()` — leaving a project
    // hook unsandboxed or failing to start). Mirrors `src/bash.rs`.
    let mut sandboxed: Option<sandbox::Sandboxed> = None;
    let mut plain: Command;
    let command: &mut Command = if use_sandbox {
        let script = sandbox_script(hook, &dir);
        match sandbox::command(sandbox, "bash", &script, project_dir) {
            Ok(wrapped) => &mut sandboxed.insert(wrapped).command,
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
        plain = Command::new(expand_project_dir(&hook.command, &dir));
        for arg in args {
            plain.arg(expand_project_dir(arg, &dir));
        }
        &mut plain
    } else {
        // Shell form: the shell expands $CLAUDE_PROJECT_DIR itself.
        plain = Command::new("bash");
        plain.arg("-c").arg(&hook.command);
        &mut plain
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
        // `setsid()` starts the hook in a new session *and* a new process group
        // whose id is the child pid. The new session detaches the controlling
        // terminal, so an interactive hook cannot open `/dev/tty` to write into
        // nano's UI or block on a terminal read until the timeout — the
        // terminal-isolation issue #92 requires. The pid-named process group is
        // the one `kill_process_group(child.id())` signals on timeout, so the
        // whole descendant tree is still cleaned up. (`process_group(0)` alone
        // makes the group but keeps nano's controlling terminal.)
        // SAFETY: `setsid` is async-signal-safe and the closure does nothing else.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
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
    // The child has been spawned; the ruleset fd can now be released.
    drop(sandboxed);

    // Write stdin on its own thread so a hook that does not read stdin (or a
    // large prompt/Write payload) cannot fill the pipe and block the write
    // forever. Killing the process group on timeout closes the read end, so a
    // stuck write unblocks with EPIPE and the writer joins.
    let stdin = child.stdin.take();
    let input_bytes = input_json.as_bytes().to_vec();
    let writer = std::thread::spawn(move || {
        if let Some(mut stdin) = stdin {
            let _ = stdin.write_all(&input_bytes);
            // Drop closes the pipe so the hook sees EOF.
        }
    });

    // Drain stdout and stderr concurrently into *bounded* buffers. A noisy hook
    // can otherwise exhaust the agent's memory during its timeout, because
    // `wait_with_output` accumulates both streams unbounded before any field cap
    // is applied. Each reader stops storing past `OUTPUT_CAP` but keeps draining
    // (so the child never blocks on a full pipe); an over-cap stream is flagged
    // so the result fails closed rather than being parsed as truncated JSON.
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let out_reader = std::thread::spawn(move || drain_bounded(stdout));
    let err_reader = std::thread::spawn(move || drain_bounded(stderr));

    // Wait for the child on its own thread so the timeout below can fire while
    // a detached descendant still holds the pipes open.
    let pid = child.id();
    let (tx, rx) = std::sync::mpsc::channel();
    let wait_handle = std::thread::spawn(move || {
        let _ = tx.send(child.wait());
    });

    // `recv()`/`join()` have no deadline, and a detached descendant that
    // inherits the pipes can keep them (and the readers/writer) blocked after
    // the group is killed. Bound every wait on the same timeout plus a grace
    // period for the kill to take effect, so a stuck descendant cannot wedge
    // the agent. `deadline` was computed with `checked_add` before spawning.
    let grace = Duration::from_secs(2);
    let wait_result = match rx.recv_timeout(timeout) {
        Ok(result) => Some(result.ok()),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            kill_process_group(pid);
            // Give the killed group a bounded grace period to reap; if a
            // detached descendant keeps the wait blocked past that, abandon it
            // (the thread is detached and finishes on its own once the pipes
            // close) rather than hanging the agent.
            let _ = rx.recv_timeout(grace);
            None
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => None,
    };
    // The wait thread is detached (not joined): on a timeout a detached
    // descendant can keep it blocked, so it finishes on its own once the pipes
    // close.
    drop(wait_handle);

    // Collect the drained streams with the same deadline awareness. The readers
    // finish as soon as the child closes its ends (normal exit or the kill
    // above), so these joins return promptly in the common case; bound them so
    // a descendant holding a pipe cannot block shutdown. `join_reader` reports
    // whether the stream actually finished: a blown deadline means a descendant
    // is still holding the pipe open and the drained bytes are incomplete.
    let (out_buf, out_overflow, out_finished) = join_reader(out_reader, deadline, grace);
    let (err_buf, err_overflow, err_finished) = join_reader(err_reader, deadline, grace);
    // The stdin writer unblocks once the read end closes (kill) or the child
    // exits; bound its join for the same reason.
    let writer_finished = join_thread(writer, deadline, grace).is_some();
    let io_unfinished = !(out_finished && err_finished && writer_finished);
    if io_unfinished {
        // A descendant survived the child and still holds a pipe open, so the
        // drained output is incomplete. An exit-0 hook whose JSON denial (or
        // any decision) was cut off must not be read as success — that would
        // let PreToolUse allow a denied call. Kill the surviving process group
        // and fail closed.
        kill_process_group(pid);
    }

    match wait_result {
        Some(Some(status)) => {
            let overflow = out_overflow || err_overflow;
            ProcessRun {
                exit: status.code(),
                timed_out: false,
                // Over-cap output is untrustworthy (truncated JSON would be
                // misparsed), so report it as a failure and fail closed.
                // Unfinished I/O (a descendant held a pipe past the deadline)
                // is untrustworthy for the same reason.
                launch_error: if overflow {
                    Some(format!("hook output exceeded {} bytes", OUTPUT_CAP))
                } else if io_unfinished {
                    Some(
                        "hook did not finish its I/O before the deadline; a descendant may still be running"
                            .to_string(),
                    )
                } else {
                    None
                },
                stdout: String::from_utf8_lossy(&out_buf).into_owned(),
                stderr: String::from_utf8_lossy(&err_buf).into_owned(),
            }
        }
        Some(None) => ProcessRun {
            exit: None,
            timed_out: false,
            launch_error: Some("hook did not complete".to_string()),
            stdout: String::new(),
            stderr: String::new(),
        },
        None => {
            ProcessRun { exit: None, timed_out: true, launch_error: None, stdout: String::new(), stderr: String::new() }
        }
    }
}

/// Read a stream to EOF, storing at most `OUTPUT_CAP` bytes. Returns the
/// (possibly truncated) buffer and whether any bytes were dropped. Keeps
/// draining after the cap so the child never blocks on a full pipe.
fn drain_bounded(stream: Option<impl std::io::Read>) -> (Vec<u8>, bool) {
    let mut buf = Vec::new();
    let mut overflow = false;
    if let Some(mut stream) = stream {
        let mut chunk = [0u8; 8192];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    let room = OUTPUT_CAP.saturating_sub(buf.len());
                    if room > 0 {
                        buf.extend_from_slice(&chunk[..n.min(room)]);
                    }
                    if n > room {
                        overflow = true;
                    }
                }
                Err(_) => break,
            }
        }
    }
    (buf, overflow)
}

/// Join a drain thread, returning its buffer; on a blown deadline return what
/// is available (empty) rather than blocking. The thread is detached and
/// finishes once its stream closes. The third tuple element reports whether the
/// reader actually finished (`true`) or was abandoned at the deadline (`false`)
/// — callers must treat unfinished output as untrustworthy and fail closed.
fn join_reader(
    handle: std::thread::JoinHandle<(Vec<u8>, bool)>,
    deadline: std::time::Instant,
    grace: Duration,
) -> (Vec<u8>, bool, bool) {
    match join_thread(handle, deadline, grace) {
        Some((buf, overflow)) => (buf, overflow, true),
        None => (Vec::new(), false, false),
    }
}

/// Join a thread with a bounded wait: poll briefly until it finishes or the
/// deadline (plus grace) passes, then detach it if still running. Returns
/// `None` when the thread did not finish in time.
fn join_thread<T: Send + 'static>(
    handle: std::thread::JoinHandle<T>,
    deadline: std::time::Instant,
    grace: Duration,
) -> Option<T> {
    use std::sync::mpsc;
    // `checked_add` keeps a near-overflow deadline from panicking; an
    // unrepresentable limit simply means "wait effectively forever" here, which
    // is safe because the caller already bounded the real work by `timeout`.
    let Some(limit) = deadline.checked_add(grace) else {
        return handle.join().ok();
    };
    let (tx, rx) = mpsc::channel();
    // Move the join onto a helper so we can bound the wait; if it times out the
    // helper (and the not-yet-joined handle) are simply dropped/detached.
    std::thread::spawn(move || {
        let _ = tx.send(handle.join());
    });
    loop {
        let now = std::time::Instant::now();
        if now >= limit {
            return None;
        }
        match rx.recv_timeout(Duration::from_millis(10).min(limit - now)) {
            Ok(Ok(value)) => return Some(value),
            Ok(Err(_)) => return None, // the thread panicked
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => return None,
        }
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

/// Single-line sanitiser for config-derived text rendered in the `/hooks`
/// listing. A hook command or matcher containing a line break would otherwise
/// forge an apparent extra listing row (e.g. a `[user]` line inside the
/// project section), misleading users about a hook's source. Every control
/// character, `\n` included, becomes a visible `␍`-style marker (U+240x) so
/// the attempt stays evident rather than silently concatenating into a
/// convincing row, and the Unicode line/paragraph separators U+2028/U+2029
/// that a terminal folds into an extra row become a visible ␤ marker. This is a
/// local helper — `claude_hooks` is a library module that must not depend on the
/// binary crate's `main::sanitize_terminal_line`.
fn listing_field(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c == '\u{2028}' || c == '\u{2029}' {
                '\u{2424}' // ␤: visible "newline was here" marker.
            } else if (c as u32) <= 0x1f {
                char::from_u32(0x2400 + c as u32).unwrap() // ␀…␟ control pictures.
            } else if c == '\u{7f}' {
                '\u{2421}' // ␡
            } else {
                c
            }
        })
        .collect()
}

fn cap(text: &str) -> String {
    // The documented limit is FIELD_CAP *characters* (matching Claude Code's
    // 10,000-character field cap), so count Unicode scalar values rather than
    // UTF-8 bytes: 4,000 emoji are 4,000 characters (16,000 bytes) and must
    // not be truncated.
    let mut chars = text.chars();
    if chars.by_ref().take(FIELD_CAP + 1).count() <= FIELD_CAP {
        return text.to_string();
    }
    // Over the cap: keep FIELD_CAP - 1 characters so the ellipsis stays within
    // the character limit.
    let kept: String = text.chars().take(FIELD_CAP - 1).collect();
    format!("{kept}…")
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
        if self.context.is_empty() { None } else { Some(self.context.join("\n\n")) }
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
    fn session_start_matcher_selects_on_source_trigger() {
        let dir = tempfile::tempdir().unwrap();
        // A SessionStart hook keyed to `startup` must run on startup and be
        // skipped on resume; a `resume`-keyed one the other way around; a
        // matcher-less one must run for every source.
        let mut startup_hook = command_hook(Event::SessionStart, "echo from-startup");
        startup_hook.matcher = Some("startup".to_string());
        let mut resume_hook = command_hook(Event::SessionStart, "echo from-resume");
        resume_hook.matcher = Some("resume".to_string());
        let always_hook = command_hook(Event::SessionStart, "echo always");

        let manager = manager_with(vec![startup_hook, resume_hook, always_hook], dir.path());

        let on_startup = manager.run_session_start("startup").context_block().unwrap_or_default();
        assert!(on_startup.contains("from-startup"), "startup matcher runs on startup");
        assert!(!on_startup.contains("from-resume"), "resume matcher skipped on startup");
        assert!(on_startup.contains("always"), "matcher-less hook always runs");

        let on_resume = manager.run_session_start("resume").context_block().unwrap_or_default();
        assert!(on_resume.contains("from-resume"), "resume matcher runs on resume");
        assert!(!on_resume.contains("from-startup"), "startup matcher skipped on resume");
        assert!(on_resume.contains("always"), "matcher-less hook always runs");
    }

    #[test]
    fn source_matcher_alternation_and_wildcard() {
        assert!(source_matcher_selects(Some("startup|resume"), "startup"));
        assert!(source_matcher_selects(Some("startup|resume"), "resume"));
        assert!(!source_matcher_selects(Some("startup|resume"), "clear"));
        assert!(source_matcher_selects(Some("*"), "clear"));
        assert!(source_matcher_selects(None, "clear"));
        assert!(!source_matcher_selects(Some("resume"), "startup"));
    }

    #[test]
    fn hook_that_ignores_large_stdin_does_not_deadlock() {
        let dir = tempfile::tempdir().unwrap();
        // A hook that never reads stdin. With a large payload this would fill
        // the OS pipe buffer and block the writer forever if stdin were written
        // on the calling thread; the dedicated writer thread (and EOF on exit)
        // must let it complete. Use a big input to exceed the pipe buffer.
        let hook = command_hook(Event::PostToolUse, "echo done");
        let manager = manager_with(vec![hook], dir.path());
        let big = "x".repeat(1_000_000);
        let outcome = manager.run_post_tool_use("bash", &json!({"command": big}), "ok", "t1");
        assert!(!outcome.blocked, "a hook that ignores a large stdin still completes");
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

    #[test]
    fn unreadable_settings_file_is_reported_not_silently_skipped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        let settings = dir.path().join(".claude/settings.json");
        std::fs::write(&settings, r#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#)
            .unwrap();
        // Make the present file unreadable: its hooks must not silently vanish.
        let mut perms = std::fs::metadata(&settings).unwrap().permissions();
        perms.set_mode(0o000);
        std::fs::set_permissions(&settings, perms).unwrap();

        let nano = NanoHooks::new();
        let opts = LoadOptions {
            disable_hooks: false,
            disable_project_hooks: false,
            claude_user_hooks: false,
            nano_hooks: &nano,
            sandbox: SandboxConfig::default(),
        };
        let manager = HookManager::load(&opts, dir.path());
        // Restore permissions so the tempdir can be cleaned up.
        let mut perms = std::fs::metadata(&settings).unwrap().permissions();
        perms.set_mode(0o644);
        std::fs::set_permissions(&settings, perms).unwrap();

        assert!(manager.is_empty(), "the unreadable file's hooks do not load");
        assert_eq!(manager.skipped.len(), 1, "the read failure is reported as a skipped entry");
        assert!(manager.skipped[0].reason.contains("could not read settings file"), "{}", manager.skipped[0].reason);
    }

    #[test]
    fn missing_settings_file_is_not_a_skip() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
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
        assert!(manager.skipped.is_empty(), "an absent optional file is not reported");
    }

    #[test]
    fn dedup_keeps_entries_with_distinct_if_rules() {
        let dir = tempfile::tempdir().unwrap();
        // Same event, matcher and command, but different `if` filters: these are
        // distinct handlers and must not collapse to the first.
        let mut push = command_hook(Event::PreToolUse, "echo hi");
        push.matcher = Some("Bash".to_string());
        push.if_rule = Some("Bash(git push *)".to_string());
        let mut commit = command_hook(Event::PreToolUse, "echo hi");
        commit.matcher = Some("Bash".to_string());
        commit.if_rule = Some("Bash(git commit *)".to_string());
        let mut no_rule = command_hook(Event::PreToolUse, "echo hi");
        no_rule.matcher = Some("Bash".to_string());
        // An exact duplicate of `push` (same if_rule) must still be dropped.
        let dup_push = push.clone();

        let mut manager = manager_with(vec![push, commit, no_rule, dup_push], dir.path());
        manager.dedup();
        assert_eq!(manager.hooks().len(), 3, "distinct if_rules survive; only the exact duplicate is dropped");
    }

    #[test]
    fn dedup_distinguishes_shell_from_direct_exec() {
        let dir = tempfile::tempdir().unwrap();
        // `args: None` (shell execution) and `args: Some([])` (direct execution)
        // are different identities and must not collapse.
        let shell = command_hook(Event::PreToolUse, "echo hi");
        let mut direct = command_hook(Event::PreToolUse, "echo hi");
        direct.args = Some(Vec::new());
        let mut manager = manager_with(vec![shell, direct], dir.path());
        manager.dedup();
        assert_eq!(manager.hooks().len(), 2, "shell form and empty-args exec form are distinct");
    }

    #[test]
    fn over_cap_hook_output_fails_closed_for_pre_tool_use() {
        let dir = tempfile::tempdir().unwrap();
        // A hook that floods stdout past OUTPUT_CAP must not have its truncated
        // output misparsed as a decision; for PreToolUse it fails closed.
        let hook = command_hook(Event::PreToolUse, "head -c 2000000 /dev/zero | tr '\\0' 'a'");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(outcome.denies(), "over-cap output is a failure, and PreToolUse fails closed");
    }

    #[test]
    fn over_cap_hook_output_is_bounded() {
        let dir = tempfile::tempdir().unwrap();
        // A noisy non-PreToolUse hook is drained to a bounded buffer rather than
        // exhausting memory; the run completes (non-blocking) without the agent
        // holding the full stream.
        let hook = command_hook(Event::PostToolUse, "head -c 5000000 /dev/zero | tr '\\0' 'b'");
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_post_tool_use("bash", &json!({"command": "ls"}), "ok", "t1");
        assert!(!outcome.blocked, "a noisy PostToolUse hook does not block");
    }

    #[test]
    fn detached_descendant_does_not_hang_past_timeout() {
        let dir = tempfile::tempdir().unwrap();
        // A hook that spawns a detached descendant inheriting its pipes, then
        // exits. The descendant survives the group kill and holds the pipes
        // open; the drain/wait must still finish within the timeout + grace
        // rather than hanging the agent.
        let hook = command_hook(Event::PreToolUse, "setsid sleep 30 & exit 0");
        let mut hook = hook;
        hook.timeout = Duration::from_millis(300);
        let manager = manager_with(vec![hook], dir.path());
        let start = std::time::Instant::now();
        let _ = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(start.elapsed() < Duration::from_secs(15), "a detached descendant cannot wedge the hook runner");
    }

    #[test]
    fn unrepresentable_timeout_fails_closed_instead_of_panicking() {
        let dir = tempfile::tempdir().unwrap();
        // A `u64::MAX`-second timeout overflows `Instant::now() + timeout`. The
        // hook must be rejected before spawning (fail closed for PreToolUse)
        // rather than panicking the agent.
        let mut hook = command_hook(Event::PreToolUse, "echo hi");
        hook.timeout = Duration::from_secs(u64::MAX);
        let manager = manager_with(vec![hook], dir.path());
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(outcome.denies(), "an unrepresentable timeout is a hook failure, and PreToolUse fails closed");
    }

    #[test]
    fn unfinished_hook_io_fails_closed_and_kills_descendants() {
        let dir = tempfile::tempdir().unwrap();
        // An exit-0 hook that writes a JSON denial but leaves a detached
        // descendant holding its pipes open: the readers cannot finish, so the
        // drained output is incomplete and must NOT be parsed as a (successful)
        // decision. PreToolUse must fail closed (deny), and the surviving
        // process group must be killed.
        let hook = command_hook(
            Event::PreToolUse,
            "printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'; setsid sleep 30 & exit 0",
        );
        let mut hook = hook;
        hook.timeout = Duration::from_millis(300);
        let manager = manager_with(vec![hook], dir.path());
        let start = std::time::Instant::now();
        let outcome = manager.run_pre_tool_use("bash", &json!({"command": "ls"}), "t1");
        assert!(start.elapsed() < Duration::from_secs(15), "unfinished I/O cannot wedge the hook runner");
        assert!(outcome.denies(), "incomplete hook output is untrustworthy; PreToolUse fails closed");
    }

    // Linux-only: the probe reads the hook's session id via `ps -o sid=`, a
    // procps (GNU) keyword — BSD/macOS `ps` has no `sid` column (`sess`
    // prints a session-struct address, not a pid-comparable sid), so the
    // parse would panic there. The product code under test (`setsid` in
    // `pre_exec`) is portable; only this probe is not.
    #[cfg(all(unix, target_os = "linux"))]
    #[test]
    fn hook_runs_in_a_new_session_without_controlling_terminal() {
        let dir = tempfile::tempdir().unwrap();
        // `setsid` detaches the hook into its own session, so its session id is
        // its own pid — not nano's. A hook that echoes `$$` (its shell pid) and
        // its `ps` session id proves the new session: with only
        // `process_group(0)` the sid would be nano's, not the hook's.
        let hook = command_hook(Event::PreToolUse, "echo \"$$ $(ps -o sid= -p $$ | tr -d ' ')\"");
        let manager = manager_with(vec![hook], dir.path());
        let hook = &manager.hooks()[0];
        let run = execute(hook, "{}", &manager.sandbox, &manager.project_dir, hook.timeout);
        assert!(run.launch_error.is_none(), "hook launches: {:?}", run.launch_error);
        let mut parts = run.stdout.split_whitespace();
        let pid: u32 = parts.next().unwrap().parse().unwrap();
        let sid: u32 = parts.next().unwrap().parse().unwrap();
        assert_eq!(pid, sid, "setsid makes the hook its own session leader (terminal detached)");
    }

    #[test]
    fn malformed_if_filter_is_reported_as_skipped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        // `Bash(git push *` is missing its closing `)`: it must be rejected at
        // load with a parse error, not silently loaded as a never-matching
        // filter.
        std::fs::write(
            dir.path().join(".claude/settings.json"),
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
                {"type":"command","command":"echo bad","if":"Bash(git push *"},
                {"type":"command","command":"echo good","if":"Bash(git push *)"}
            ]}]}}"#,
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
        assert_eq!(manager.hooks().len(), 1, "only the well-formed filter loads");
        assert_eq!(manager.hooks()[0].command, "echo good");
        assert_eq!(manager.skipped.len(), 1, "the malformed filter is reported, not dropped silently");
        assert!(manager.skipped[0].reason.contains("invalid `if` filter"), "the skip reason names the parse error");
    }

    #[test]
    fn blank_if_filter_is_normalized_to_none() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::create_dir_all(dir.path().join(".claude")).unwrap();
        // A whitespace-only `if` carries no filter. Stored as `Some("  ")` it
        // would reach `Rule::parse` via `if_selects` and fail, silently
        // disabling the hook while `/hooks` lists it as loaded. It must be
        // normalized to `None` so the hook runs unfiltered.
        std::fs::write(
            dir.path().join(".claude/settings.json"),
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
                {"type":"command","command":"echo hi","if":"   "}
            ]}]}}"#,
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
        assert_eq!(manager.hooks().len(), 1, "the blank filter still loads the hook");
        assert_eq!(manager.hooks()[0].if_rule, None, "a blank `if` is stored as no filter");
        // And it selects a call rather than being silently disabled.
        let selected = manager.selected(Event::PreToolUse, Some(("Bash", "bash", &json!({"command":"ls"}))), None);
        assert_eq!(selected.len(), 1, "a blank-filtered hook is not silently disabled");
    }

    #[test]
    fn listing_neutralises_line_breaks_in_config_fields() {
        // A project hook command/matcher containing a line break would render
        // an apparent extra row in `/hooks` — e.g. a forged `[user]` line
        // inside the project section — misleading users about a hook's source
        // (Copilot finding, src/claude_hooks.rs). Config-derived fields are
        // sanitised to a single line before rendering.
        let dir = tempfile::tempdir().unwrap();
        let mut hook = command_hook(Event::Stop, "evil\n  [user] Stop * -> forged");
        hook.matcher = Some("Stop\n  [user] forged".to_string());
        hook.source = Source::Project;
        let mut manager = manager_with(vec![hook], dir.path());
        manager.skipped.push(Skipped {
            event_name: "Bad\n  [user] forged".to_string(),
            reason: "broken\n  [user] forged".to_string(),
            source: Source::Project,
        });
        manager.files.push(LoadedFile {
            path: dir.path().join(".claude/settings.json\n  [user] forged"),
            source: Source::Project,
            hash: "abc123".to_string(),
        });
        let listing = manager.listing();
        // No injected line break survives: every row is one the listing itself
        // emitted, so no config field can forge an apparent `[user]` row.
        for line in listing.lines().filter(|l| l.starts_with("  [")) {
            assert!(line.starts_with("  [project]"), "only the real source label remains: {line}");
        }
        // The attempt stays visible: the newline renders as its control
        // picture (␊) inside the field's own row instead of breaking it.
        assert!(listing.contains("evil␊  [user] Stop * -> forged"), "content kept, flattened:\n{listing}");
    }

    #[test]
    fn cap_counts_characters_not_bytes() {
        // The documented limit is 10,000 *characters* (Claude Code's field
        // cap), so multi-byte text below the character limit is kept whole
        // even when it exceeds 10,000 UTF-8 bytes (Copilot finding,
        // src/claude_hooks.rs).
        let emoji = "🦀".repeat(4_000); // 4,000 chars, 16,000 bytes.
        assert_eq!(cap(&emoji), emoji, "4,000 emoji are under the character cap");
        // Exactly at the cap: unchanged, no ellipsis.
        let at_cap = "a".repeat(FIELD_CAP);
        assert_eq!(cap(&at_cap), at_cap);
        // Over the cap: truncated at a character boundary, and the ellipsis
        // stays within the character limit.
        let over = "🦀".repeat(FIELD_CAP + 10);
        let capped = cap(&over);
        assert!(capped.ends_with('…'));
        assert_eq!(capped.chars().count(), FIELD_CAP, "ellipsis included within the cap");
        assert!(capped.chars().take(FIELD_CAP - 1).all(|c| c == '🦀'));
        // Plain ASCII over the cap truncates the same way.
        let ascii = "x".repeat(FIELD_CAP + 1);
        assert_eq!(cap(&ascii).chars().count(), FIELD_CAP);
    }
}
