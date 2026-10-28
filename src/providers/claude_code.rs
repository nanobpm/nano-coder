//! Claude Code provider: runs the user's installed Claude Code CLI in headless
//! mode (`claude -p`), so a Claude plan (Pro/Max) can drive nano-coder without
//! an Anthropic API key.
//!
//! nano-coder never reads or sends Claude Code's credentials. Each model call
//! starts one `claude -p` process, which signs in the way it always does and
//! counts against the plan's usage limits like any other Claude Code session.
//!
//! One call works like this:
//! - Claude Code's own tools, settings files (hooks, plugins, CLAUDE.md), slash
//!   commands and MCP servers are switched off, and nano-coder's system prompt
//!   replaces Claude Code's.
//! - nano-coder's tools are offered through a stub MCP server (this binary, run
//!   with [`TOOL_STUB_FLAG`]), so the model calls them natively. The stub lists
//!   the tools but never answers a call: once the model's message ends, the
//!   process is stopped and nano-coder runs the tools itself, as it does for an
//!   HTTP provider.
//! - Headless mode cannot replay earlier assistant turns, so the conversation is
//!   sent as one user turn holding a transcript (see [`transcript_blocks`]). Its
//!   last block carries a cache breakpoint, so each call reuses the previous
//!   call's cached prefix.

use std::io::{BufRead, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use super::anthropic::StreamAccumulator;
use super::{ProviderKind, ResolvedProvider};
use crate::llm::{
    AttachmentPlan, ChatRequest, DetectedWindow, LLMClient, LLMResponse, Message, ResolvedAttachment, Role,
    StreamEvent, StreamSink, report_whole,
};
use crate::thinking::{Format, Reported, Request};

/// Hidden command-line flag that runs this binary as the tool stub
/// (`nano-coder --claude-code-tool-stub TOOLS.json`).
pub const TOOL_STUB_FLAG: &str = "--claude-code-tool-stub";
/// Environment variable naming the `claude` executable, for installs that are
/// not on `PATH` or in Claude Code's usual install locations.
pub const BINARY_ENV: &str = "NANO_CODER_CLAUDE_PATH";
/// MCP server name of the stub. Claude Code offers its tools as
/// `mcp__nano__<tool>`.
const MCP_SERVER: &str = "nano";
const TOOL_PREFIX: &str = "mcp__nano__";
/// Effort levels `claude --effort` accepts.
const EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
/// Aliases Claude Code resolves to the newest model of each family.
const MODEL_ALIASES: [&str; 4] = ["fable", "opus", "sonnet", "haiku"];
/// Context window assumed for every model. Claude Code does not report one
/// before a request; 200k is safe for every current Claude model, and a larger
/// window can be set with `context_window`.
const CONTEXT_WINDOW: usize = 200_000;
/// Cache breakpoint on the transcript's last block. Claude Code caches with a
/// one-hour TTL, and the API rejects a 1h breakpoint after a 5m one.
const CACHE_BREAKPOINT: &str = r#"{"type":"ephemeral","ttl":"1h"}"#;
/// How long a stopped `claude` process gets to exit before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(2);

/// Appended to the system prompt so the model reads the transcript as history.
const TRANSCRIPT_NOTE: &str = "\
# Conversation transcript
This connection cannot replay earlier turns natively, so the conversation so far is given as a \
transcript in the user turn. Its <user>, <assistant>, <tool_call> and <tool_result> entries record \
what already happened. Continue as the assistant from where the transcript ends. The tools are \
offered as mcp__nano__<name>; the transcript records them by <name>. Call tools only through the \
tool interface, and never write <tool_call> or <tool_result> tags yourself.";

#[derive(Clone)]
pub struct ClaudeCodeClient {
    provider: ResolvedProvider,
    /// A program to run in place of `claude`, with arguments to put before
    /// the usual ones. Tests use it to run a fake `claude`; `None` runs the
    /// real one (see [`claude_binary`]).
    program: Option<(PathBuf, Vec<String>)>,
}

impl ClaudeCodeClient {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        Ok(Self { provider, program: None })
    }

    async fn run(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        // The attachment plan is not `Send`, so build everything that reads it
        // before the first await.
        let input = {
            let plan = request.attachment_plan();
            json!({
                "type": "user",
                "message": {"role": "user", "content": transcript_blocks(request, &plan)},
            })
        };
        let files = CallFiles::create()?;
        std::fs::write(files.path("system.md"), system_prompt(request.messages))
            .context("writing the Claude Code system prompt")?;
        let has_tools = !request.tools.is_empty();
        if has_tools {
            let tools: Vec<Value> = request
                .tools
                .iter()
                .map(|tool| json!({"name": tool.name, "description": tool.description, "inputSchema": tool.parameters}))
                .collect();
            std::fs::write(files.path("tools.json"), serde_json::to_vec(&tools)?)
                .context("writing the Claude Code tool list")?;
            let exe = std::env::current_exe().context("locating the nano-coder binary for the tool stub")?;
            std::fs::write(files.path("mcp.json"), mcp_config(&exe, &files.path("tools.json")).to_string())
                .context("writing the Claude Code MCP config")?;
        }
        let args = command_args(&self.provider.model, &files.dir, has_tools, effort(request.thinking.as_ref()));

        let (binary, leading_args) = match &self.program {
            Some((program, leading)) => (program.clone(), leading.clone()),
            None => (claude_binary(), Vec::new()),
        };
        let mut child = tokio::process::Command::new(&binary)
            .args(&leading_args)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => anyhow!(
                    "Claude Code (`claude`) was not found. Install it, sign in by running `claude` once, \
                     or set {BINARY_ENV} to its path"
                ),
                _ => anyhow!("starting Claude Code ({}): {e}", binary.display()),
            })?;

        // Feed the input from its own task: a large transcript can fill the
        // pipe while Claude Code is still writing its startup output.
        let mut stdin = child.stdin.take().context("Claude Code stdin")?;
        let mut line = serde_json::to_vec(&input)?;
        line.push(b'\n');
        tokio::spawn(async move {
            let _ = stdin.write_all(&line).await;
            // Dropping stdin closes it: Claude Code answers this one message.
        });
        let mut stderr = child.stderr.take().context("Claude Code stderr")?;
        let stderr_task = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = stderr.read_to_end(&mut buf).await;
            String::from_utf8_lossy(&buf).into_owned()
        });

        let stdout = child.stdout.take().context("Claude Code stdout")?;
        let mut lines = BufReader::new(stdout).lines();
        let mut reader = OutputReader::new(has_tools);
        let idle = self.provider.timeout;
        loop {
            let line = tokio::time::timeout(idle, lines.next_line())
                .await
                .map_err(|_| anyhow!("Claude Code sent nothing for {}s", idle.as_secs()))?
                .context("reading Claude Code output")?;
            let Some(line) = line else { break };
            let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
            if reader.push(&event, sink)? == Step::Done {
                stop(child);
                return Ok(reader.finish(sink));
            }
        }
        // Output ended before the answer did.
        let status = child.wait().await.ok();
        let stderr = stderr_task.await.unwrap_or_default();
        let detail = last_lines(&stderr, 5);
        let status = status.map(|s| s.to_string()).unwrap_or_else(|| "unknown status".into());
        if detail.is_empty() {
            bail!("Claude Code exited ({status}) before answering")
        }
        bail!("Claude Code exited ({status}) before answering: {detail}")
    }
}

/// Ask a finished `claude` process to exit (the tool stub keeps it waiting on
/// a tool call), killing it if it is still running after [`STOP_GRACE`].
fn stop(mut child: tokio::process::Child) {
    if let Some(pid) = child.id() {
        // SAFETY: plain signal to our own child, which has not been reaped.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
    }
    tokio::spawn(async move {
        if tokio::time::timeout(STOP_GRACE, child.wait()).await.is_err() {
            let _ = child.kill().await;
        }
    });
}

/// The system prompt: nano-coder's system messages, then [`TRANSCRIPT_NOTE`].
fn system_prompt(messages: &[Message]) -> String {
    let mut parts: Vec<&str> = messages
        .iter()
        .filter(|m| m.role == Role::System && !m.content.is_empty())
        .map(|m| m.content.as_str())
        .collect();
    parts.push(TRANSCRIPT_NOTE);
    parts.join("\n\n")
}

/// The conversation as content blocks for one user turn. Each user message and
/// each assistant message is one text block, and each run of tool results is
/// one text block (split around any images it carries), so earlier blocks stay
/// byte-identical from call to call and the cached prefix keeps matching. The
/// last block carries the cache breakpoint.
pub(crate) fn transcript_blocks(request: &ChatRequest<'_>, plan: &AttachmentPlan) -> Vec<Value> {
    let mut blocks: Vec<Value> = Vec::new();
    // Text of the tool results gathered since the last flush.
    let mut results = String::new();
    let flush = |results: &mut String, blocks: &mut Vec<Value>| {
        if !results.is_empty() {
            blocks.push(json!({"type": "text", "text": results.trim_end()}));
            results.clear();
        }
    };
    for message in request.messages {
        match message.role {
            Role::System => {}
            Role::User => {
                flush(&mut results, &mut blocks);
                let (body, images) = with_attachments(request, plan, message);
                blocks.push(json!({"type": "text", "text": format!("<user>\n{body}\n</user>")}));
                blocks.extend(images);
            }
            Role::Assistant => {
                flush(&mut results, &mut blocks);
                let mut text = String::from("<assistant>\n");
                if !message.content.is_empty() {
                    text.push_str(&message.content);
                    text.push('\n');
                }
                for call in &message.tool_calls {
                    let arguments = call.malformed_arguments.clone().unwrap_or_else(|| call.encoded_arguments());
                    text.push_str(&format!(
                        "<tool_call id=\"{}\" name=\"{}\">{arguments}</tool_call>\n",
                        call.id, call.name
                    ));
                }
                if message.content.is_empty() && message.tool_calls.is_empty() {
                    continue;
                }
                text.push_str("</assistant>");
                blocks.push(json!({"type": "text", "text": text}));
            }
            Role::Tool => {
                let id = message.tool_call_id.as_deref().unwrap_or_default();
                let name = message.name.as_deref().unwrap_or_default();
                let error = if message.is_error { " error=\"true\"" } else { "" };
                let (body, images) = with_attachments(request, plan, message);
                results
                    .push_str(&format!("<tool_result id=\"{id}\" name=\"{name}\"{error}>\n{body}\n</tool_result>\n"));
                // Images follow the result they belong to.
                if !images.is_empty() {
                    flush(&mut results, &mut blocks);
                    blocks.extend(images);
                }
            }
        }
    }
    flush(&mut results, &mut blocks);
    if blocks.is_empty() {
        blocks.push(json!({"type": "text", "text": "<user>\n</user>"}));
    }
    if let Some(last) = blocks.last_mut() {
        last["cache_control"] = serde_json::from_str(CACHE_BREAKPOINT).expect("valid breakpoint");
    }
    blocks
}

/// `message`'s text with the placeholders of images the plan leaves out, and
/// image blocks for the ones it sends.
fn with_attachments(request: &ChatRequest<'_>, plan: &AttachmentPlan, message: &Message) -> (String, Vec<Value>) {
    let mut body = message.content.clone();
    let mut images = Vec::new();
    for item in request.resolve_attachments_with(message, plan) {
        match item {
            ResolvedAttachment::Image(image) => images.push(json!({
                "type": "image",
                "source": {"type": "base64", "media_type": image.media_type, "data": image.data_base64},
            })),
            ResolvedAttachment::Omitted(text) => {
                body.push('\n');
                body.push_str(&text);
            }
        }
    }
    (body, images)
}

/// The `--mcp-config` for the tool stub.
fn mcp_config(exe: &Path, tools: &Path) -> Value {
    json!({
        "mcpServers": {
            MCP_SERVER: {
                "type": "stdio",
                "command": exe,
                "args": [TOOL_STUB_FLAG, tools],
            }
        }
    })
}

/// `claude` arguments for one call, with its files in `dir`.
fn command_args(model: &str, dir: &Path, has_tools: bool, effort: Option<&str>) -> Vec<String> {
    let path = |name: &str| dir.join(name).to_string_lossy().into_owned();
    let mut args: Vec<String> = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--model",
        model,
        // No built-in tools, no settings files (so no hooks, plugins, CLAUDE.md
        // or permission rules), no slash commands, and no session saved to the
        // user's Claude Code history.
        "--tools",
        "",
        "--setting-sources",
        "",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--strict-mcp-config",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.push("--system-prompt-file".into());
    args.push(path("system.md"));
    if has_tools {
        args.extend(["--mcp-config".into(), path("mcp.json"), "--allowedTools".into(), format!("mcp__{MCP_SERVER}")]);
    }
    if let Some(level) = effort {
        args.extend(["--effort".into(), level.to_string()]);
    }
    args
}

/// The `--effort` level for a thinking request, when Claude Code takes it.
fn effort(thinking: Option<&Request>) -> Option<&str> {
    match thinking {
        Some(Request::Effort(level)) => EFFORT_LEVELS.iter().find(|l| **l == level.as_str()).copied(),
        _ => None,
    }
}

/// The `claude` executable: [`BINARY_ENV`], else `claude` on `PATH`, else
/// Claude Code's usual install locations, else plain `claude` (so the spawn
/// error names it).
fn claude_binary() -> PathBuf {
    if let Some(path) = std::env::var_os(BINARY_ENV).filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    let on_path = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .map(|dir| dir.join("claude"))
        .find(|candidate| is_executable(candidate));
    if let Some(path) = on_path {
        return path;
    }
    dirs::home_dir()
        .into_iter()
        .flat_map(|home| [home.join(".local/bin/claude"), home.join(".claude/local/claude")])
        .find(|candidate| is_executable(candidate))
        .unwrap_or_else(|| PathBuf::from("claude"))
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The last `n` non-empty lines of `text`, joined with ` | `.
fn last_lines(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    lines[lines.len().saturating_sub(n)..].join(" | ")
}

/// A private temporary directory for one call's files, removed on drop.
struct CallFiles {
    dir: PathBuf,
}

impl CallFiles {
    fn create() -> Result<Self> {
        let base = std::env::temp_dir();
        for _ in 0..8 {
            let dir = base.join(format!("nano-coder-claude-code-{}-{:016x}", std::process::id(), fastrand::u64(..)));
            match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
                Ok(()) => return Ok(Self { dir }),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e).context("creating a temporary directory for Claude Code"),
            }
        }
        bail!("could not create a temporary directory for Claude Code")
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }
}

impl Drop for CallFiles {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Step {
    Continue,
    Done,
}

/// Reads Claude Code's `stream-json` output for one model message.
struct OutputReader {
    accumulator: StreamAccumulator,
    /// A `message_start` was seen, so the accumulator holds the answer.
    started: bool,
    /// The final `result` text, used only when no message was streamed.
    result_text: Option<String>,
    expects_tools: bool,
}

impl OutputReader {
    fn new(expects_tools: bool) -> Self {
        Self { accumulator: StreamAccumulator::default(), started: false, result_text: None, expects_tools }
    }

    fn push(&mut self, event: &Value, sink: StreamSink<'_>) -> Result<Step> {
        let str_at = |pointer: &str| event.pointer(pointer).and_then(Value::as_str);
        match str_at("/type") {
            Some("system") if str_at("/subtype") == Some("init") && self.expects_tools => {
                let servers = event.get("mcp_servers").and_then(Value::as_array);
                let status = servers
                    .and_then(|s| s.iter().find(|s| s.get("name").and_then(Value::as_str) == Some(MCP_SERVER)))
                    .and_then(|s| s.get("status").and_then(Value::as_str));
                match status {
                    Some("connected" | "pending") => {}
                    other => bail!(
                        "Claude Code could not load nano-coder's tools (MCP server status: {})",
                        other.unwrap_or("missing")
                    ),
                }
            }
            // Events from subagents carry their parent tool call; there are
            // none with Claude Code's tools switched off, but never mix them in.
            Some("stream_event") if event.get("parent_tool_use_id").is_none_or(Value::is_null) => {
                let inner = event.get("event").cloned().unwrap_or(Value::Null);
                match inner.get("type").and_then(Value::as_str) {
                    Some("message_start") => {
                        // A retried request starts over.
                        if self.started {
                            self.accumulator = StreamAccumulator::default();
                        }
                        self.started = true;
                    }
                    Some("message_stop") => return Ok(Step::Done),
                    _ => {}
                }
                self.accumulator.push(&inner.to_string(), sink)?;
            }
            Some("result") => {
                let text = str_at("/result").unwrap_or_default().trim().to_string();
                if event.get("is_error").and_then(Value::as_bool).unwrap_or(false) {
                    return Err(result_error(event, &text));
                }
                self.result_text = Some(text);
                return Ok(Step::Done);
            }
            _ => {}
        }
        Ok(Step::Continue)
    }

    fn finish(self, sink: StreamSink<'_>) -> LLMResponse {
        if !self.started
            && let Some(text) = self.result_text
        {
            let response = LLMResponse { content: text, stop_reason: Some("end_turn".into()), ..Default::default() };
            report_whole(sink, &response);
            return response;
        }
        let mut response = self.accumulator.finish();
        for call in &mut response.tool_calls {
            if let Some(name) = call.name.strip_prefix(TOOL_PREFIX) {
                call.name = name.to_string();
            }
        }
        // Thinking signatures belong to Claude Code's requests and are never
        // replayed by the transcript; keep them out of the session so another
        // provider never replays them either.
        response.thinking_blocks.clear();
        response
    }
}

/// The error for a failed `result`, with a sign-in hint where it helps.
fn result_error(event: &Value, text: &str) -> anyhow::Error {
    let text = if text.is_empty() { "the request failed" } else { text };
    let status =
        event.get("api_error_status").and_then(Value::as_u64).map(|s| format!(" (HTTP {s})")).unwrap_or_default();
    let lower = text.to_lowercase();
    let hint = if lower.contains("/login") || lower.contains("not logged in") || lower.contains("log in") {
        "; run `claude` in a terminal and sign in with your Claude account"
    } else {
        ""
    };
    anyhow!("Claude Code: {text}{status}{hint}")
}

#[async_trait]
impl LLMClient for ClaudeCodeClient {
    fn clone_boxed(&self) -> Box<dyn LLMClient> {
        Box::new(self.clone())
    }

    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        self.run(request, &|_: StreamEvent<'_>| {}).await
    }

    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        if !self.provider.stream {
            let response = self.chat(request).await?;
            report_whole(sink, &response);
            return Ok(response);
        }
        self.run(request, sink).await
    }

    async fn list_models(&self) -> Result<Vec<String>> {
        Ok(MODEL_ALIASES.iter().map(|m| m.to_string()).collect())
    }

    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        Some(DetectedWindow::total(CONTEXT_WINDOW, "Claude Code (assumed; set context_window to change)"))
    }

    async fn detect_thinking_levels(&self) -> Option<Reported> {
        Some(Reported {
            levels: EFFORT_LEVELS.iter().map(|l| l.to_string()).collect(),
            adaptive: true,
            format: Format::Effort,
        })
    }

    async fn detect_vision(&self) -> Option<crate::vision::Vision> {
        Some(crate::vision::Vision::capable())
    }

    fn model_name(&self) -> &str {
        &self.provider.model
    }

    fn provider_name(&self) -> &str {
        &self.provider.name
    }

    fn kind(&self) -> Option<ProviderKind> {
        Some(ProviderKind::ClaudeCode)
    }
}

/// Serve the tool stub over stdio until Claude Code closes it: answer the MCP
/// handshake and `tools/list` with the tools in `tools_path`, and never answer
/// `tools/call` (nano-coder stops Claude Code and runs the tool itself).
pub fn run_tool_stub(tools_path: &Path) -> Result<()> {
    let tools: Value = serde_json::from_slice(&std::fs::read(tools_path).context("reading the tool list")?)
        .context("parsing the tool list")?;
    let mut stdout = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        if let Some(reply) = stub_reply(&line?, &tools) {
            writeln!(stdout, "{reply}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

/// The stub's JSON-RPC reply to one message, if it gets one.
fn stub_reply(line: &str, tools: &Value) -> Option<Value> {
    let message: Value = serde_json::from_str(line).ok()?;
    // Notifications and responses get no reply.
    let id = message.get("id").filter(|id| !id.is_null())?.clone();
    let method = message.get("method").and_then(Value::as_str)?;
    let result = match method {
        "initialize" => json!({
            "protocolVersion": message.pointer("/params/protocolVersion").cloned().unwrap_or(json!("2025-06-18")),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "nano-coder", "version": env!("CARGO_PKG_VERSION")},
        }),
        "tools/list" => json!({"tools": tools}),
        "ping" => json!({}),
        "tools/call" => return None,
        _ => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32601, "message": format!("method not found: {method}")},
            }));
        }
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::ToolCall;
    use std::sync::Mutex;

    fn tool_call(id: &str, name: &str, arguments: Value) -> ToolCall {
        ToolCall { id: id.into(), name: name.into(), arguments, item_id: None, malformed_arguments: None }
    }

    fn tool_result(id: &str, name: &str, content: &str, is_error: bool) -> Message {
        let mut message = Message::user(content);
        message.role = Role::Tool;
        message.tool_call_id = Some(id.into());
        message.name = Some(name.into());
        message.is_error = is_error;
        message
    }

    fn conversation() -> Vec<Message> {
        let mut assistant = Message::user("I'll read it.");
        assistant.role = Role::Assistant;
        assistant.tool_calls = vec![
            tool_call("toolu_1", "read_file", json!({"path": "Cargo.toml"})),
            tool_call("toolu_2", "bash", json!({"command": "ls"})),
        ];
        vec![
            Message::system("You are nano-coder."),
            Message::user("What version is this?"),
            assistant,
            tool_result("toolu_1", "read_file", "version = \"0.50.0\"", false),
            tool_result("toolu_2", "bash", "exit 1", true),
        ]
    }

    #[test]
    fn transcript_renders_turns_and_groups_tool_results() {
        let messages = conversation();
        let request = ChatRequest::test_request(&messages);
        let blocks = transcript_blocks(&request, &request.attachment_plan());
        let texts: Vec<&str> = blocks.iter().map(|b| b["text"].as_str().unwrap()).collect();
        assert_eq!(
            texts,
            [
                "<user>\nWhat version is this?\n</user>",
                "<assistant>\nI'll read it.\n\
                 <tool_call id=\"toolu_1\" name=\"read_file\">{\"path\":\"Cargo.toml\"}</tool_call>\n\
                 <tool_call id=\"toolu_2\" name=\"bash\">{\"command\":\"ls\"}</tool_call>\n</assistant>",
                "<tool_result id=\"toolu_1\" name=\"read_file\">\nversion = \"0.50.0\"\n</tool_result>\n\
                 <tool_result id=\"toolu_2\" name=\"bash\" error=\"true\">\nexit 1\n</tool_result>",
            ]
        );
        // Only the last block carries the cache breakpoint.
        assert_eq!(blocks[2]["cache_control"], json!({"type": "ephemeral", "ttl": "1h"}));
        assert!(blocks[..2].iter().all(|b| b.get("cache_control").is_none()));
    }

    #[test]
    fn transcript_prefix_is_stable_as_the_conversation_grows() {
        // The cached prefix only matches when earlier blocks are unchanged.
        let mut messages = conversation();
        let request = ChatRequest::test_request(&messages);
        let before = transcript_blocks(&request, &request.attachment_plan());
        messages.push(Message::user("Thanks"));
        let request = ChatRequest::test_request(&messages);
        let after = transcript_blocks(&request, &request.attachment_plan());
        assert_eq!(after.len(), before.len() + 1);
        for (old, new) in before.iter().zip(&after) {
            assert_eq!(old["text"], new["text"]);
        }
    }

    #[test]
    fn transcript_skips_empty_assistant_turns_and_never_sends_nothing() {
        let mut empty = Message::user("");
        empty.role = Role::Assistant;
        let messages = vec![Message::system("s"), empty];
        let request = ChatRequest::test_request(&messages);
        let blocks = transcript_blocks(&request, &request.attachment_plan());
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0]["text"], "<user>\n</user>");
    }

    #[test]
    fn system_prompt_joins_system_messages_and_explains_the_transcript() {
        let messages = conversation();
        let prompt = system_prompt(&messages);
        assert!(prompt.starts_with("You are nano-coder.\n\n# Conversation transcript"));
    }

    #[test]
    fn command_args_switch_off_claude_code_extras() {
        let args = command_args("sonnet", Path::new("/tmp/x"), true, Some("high"));
        let joined = args.join(" ");
        for expected in [
            "-p --input-format stream-json --output-format stream-json",
            "--model sonnet",
            "--tools  --setting-sources  --disable-slash-commands --no-session-persistence --strict-mcp-config",
            "--system-prompt-file /tmp/x/system.md",
            "--mcp-config /tmp/x/mcp.json --allowedTools mcp__nano",
            "--effort high",
        ] {
            assert!(joined.contains(expected), "{expected:?} missing from {joined:?}");
        }
        let args = command_args("haiku", Path::new("/tmp/x"), false, None);
        assert!(!args.iter().any(|a| a == "--mcp-config" || a == "--effort"));
        // Without tools, user MCP servers stay off too.
        assert!(args.iter().any(|a| a == "--strict-mcp-config"));
    }

    #[test]
    fn effort_maps_only_levels_claude_code_takes() {
        assert_eq!(effort(Some(&Request::Effort("xhigh".into()))), Some("xhigh"));
        assert_eq!(effort(Some(&Request::Effort("minimal".into()))), None);
        assert_eq!(effort(Some(&Request::Off)), None);
        assert_eq!(effort(None), None);
    }

    fn stream(event: Value) -> Value {
        json!({"type": "stream_event", "event": event, "parent_tool_use_id": null})
    }

    fn push_all(reader: &mut OutputReader, events: &[Value], seen: &Mutex<String>) -> Result<Step> {
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(text) = event {
                seen.lock().unwrap().push_str(text);
            }
        };
        for event in events {
            if reader.push(event, &sink)? == Step::Done {
                return Ok(Step::Done);
            }
        }
        Ok(Step::Continue)
    }

    fn init(status: &str) -> Value {
        json!({"type": "system", "subtype": "init", "mcp_servers": [{"name": "nano", "status": status}]})
    }

    fn text_block(index: u64, text: &str) -> [Value; 2] {
        [
            stream(
                json!({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}),
            ),
            stream(
                json!({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": text}}),
            ),
        ]
    }

    /// Claude Code's output for an answer that says "Reading." and calls
    /// `read_file`, up to the end of the model's message.
    fn answer_with_tool_call() -> Vec<Value> {
        let mut events = vec![
            init("connected"),
            stream(
                json!({"type": "message_start", "message": {"usage": {"input_tokens": 2, "cache_read_input_tokens": 100}}}),
            ),
        ];
        events.extend(text_block(0, "Reading."));
        events.extend([
            stream(
                json!({"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": "toolu_9", "name": "mcp__nano__read_file"}}),
            ),
            stream(
                json!({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "{\"path\":\"a\"}"}}),
            ),
            stream(
                json!({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 7}}),
            ),
            stream(json!({"type": "message_stop"})),
        ]);
        events
    }

    #[test]
    fn reader_returns_tool_calls_with_the_mcp_prefix_removed() {
        let mut reader = OutputReader::new(true);
        let seen = Mutex::new(String::new());
        let mut events = answer_with_tool_call();
        events.push(json!({"type": "result", "is_error": false, "result": "never read"}));
        assert_eq!(push_all(&mut reader, &events, &seen).unwrap(), Step::Done);
        let response = reader.finish(&|_: StreamEvent<'_>| {});
        assert_eq!(*seen.lock().unwrap(), "Reading.");
        assert_eq!(response.content, "Reading.");
        assert_eq!(response.stop_reason.as_deref(), Some("tool_use"));
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].name, "read_file");
        assert_eq!(response.tool_calls[0].id, "toolu_9");
        assert_eq!(response.tool_calls[0].arguments, json!({"path": "a"}));
        let usage = response.usage.unwrap();
        assert_eq!((usage.prompt_tokens, usage.completion_tokens), (102, 7));
    }

    #[test]
    fn reader_reports_failed_results_with_a_sign_in_hint() {
        let mut reader = OutputReader::new(false);
        let seen = Mutex::new(String::new());
        let events = [json!({
            "type": "result",
            "is_error": true,
            "result": "Not logged in · Please run /login",
            "api_error_status": 401,
        })];
        let error = push_all(&mut reader, &events, &seen).unwrap_err().to_string();
        assert!(
            error.starts_with("Claude Code: Not logged in · Please run /login (HTTP 401); run `claude`"),
            "{error}"
        );
    }

    #[test]
    fn reader_rejects_a_tool_stub_that_failed_to_start() {
        let mut reader = OutputReader::new(true);
        let seen = Mutex::new(String::new());
        let events =
            [json!({"type": "system", "subtype": "init", "mcp_servers": [{"name": "nano", "status": "failed"}]})];
        let error = push_all(&mut reader, &events, &seen).unwrap_err().to_string();
        assert!(error.contains("status: failed"), "{error}");
        // Without tools, no stub is expected.
        let mut reader = OutputReader::new(false);
        let events = [json!({"type": "system", "subtype": "init", "mcp_servers": []})];
        assert_eq!(push_all(&mut reader, &events, &seen).unwrap(), Step::Continue);
    }

    #[test]
    fn reader_falls_back_to_the_result_text_and_ignores_subagent_events() {
        let mut reader = OutputReader::new(false);
        let seen = Mutex::new(String::new());
        let mut subagent = stream(json!({"type": "message_start", "message": {}}));
        subagent["parent_tool_use_id"] = json!("toolu_x");
        let events = [subagent, json!({"type": "result", "is_error": false, "result": " Done. "})];
        assert_eq!(push_all(&mut reader, &events, &seen).unwrap(), Step::Done);
        let response = reader.finish(&|_: StreamEvent<'_>| {});
        assert_eq!(response.content, "Done.");
    }

    #[test]
    fn stub_answers_the_handshake_and_lists_tools_but_never_runs_one() {
        let tools = json!([{"name": "read_file", "description": "Read", "inputSchema": {"type": "object"}}]);
        let init = stub_reply(
            r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            &tools,
        )
        .unwrap();
        assert_eq!(init["id"], 0);
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        assert!(init["result"]["capabilities"]["tools"].is_object());
        assert_eq!(stub_reply(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, &tools), None);
        let list = stub_reply(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, &tools).unwrap();
        assert_eq!(list["result"]["tools"], tools);
        let call = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file"}}"#;
        assert_eq!(stub_reply(call, &tools), None);
        let unknown = stub_reply(r#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#, &tools).unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
    }

    #[test]
    fn mcp_config_runs_this_binary_as_the_stub() {
        let config = mcp_config(Path::new("/bin/nano-coder"), Path::new("/tmp/x/tools.json"));
        assert_eq!(
            config,
            json!({"mcpServers": {"nano": {
                "type": "stdio",
                "command": "/bin/nano-coder",
                "args": ["--claude-code-tool-stub", "/tmp/x/tools.json"],
            }}})
        );
    }

    #[test]
    fn last_lines_keeps_the_tail() {
        assert_eq!(last_lines("a\n\nb\nc\n", 2), "b | c");
        assert_eq!(last_lines("", 3), "");
    }

    #[test]
    fn reader_starts_over_when_claude_code_retries_the_request() {
        let mut reader = OutputReader::new(false);
        let seen = Mutex::new(String::new());
        let mut events = vec![stream(json!({"type": "message_start", "message": {"usage": {"input_tokens": 5}}}))];
        events.extend(text_block(0, "Partial"));
        // Claude Code retried (say, after an overload): a new message starts.
        events.push(stream(json!({"type": "message_start", "message": {"usage": {"input_tokens": 9}}})));
        events.extend(text_block(0, "Whole answer."));
        events.push(stream(json!({"type": "message_stop"})));
        assert_eq!(push_all(&mut reader, &events, &seen).unwrap(), Step::Done);
        let response = reader.finish(&|_: StreamEvent<'_>| {});
        assert_eq!(response.content, "Whole answer.");
        assert_eq!(response.usage.unwrap().prompt_tokens, 9);
    }

    #[test]
    fn reader_keeps_thinking_text_but_drops_its_signature() {
        let mut reader = OutputReader::new(false);
        let seen = Mutex::new(String::new());
        let mut events = vec![
            stream(json!({"type": "message_start", "message": {}})),
            stream(
                json!({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
            ),
            stream(
                json!({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Check the manifest."}}),
            ),
            stream(
                json!({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "c2ln"}}),
            ),
        ];
        events.extend(text_block(1, "0.50.0"));
        events.push(stream(json!({"type": "message_stop"})));
        assert_eq!(push_all(&mut reader, &events, &seen).unwrap(), Step::Done);
        let response = reader.finish(&|_: StreamEvent<'_>| {});
        assert_eq!(response.thinking, "Check the manifest.");
        assert_eq!(response.content, "0.50.0");
        assert!(response.thinking_blocks.is_empty(), "{:?}", response.thinking_blocks);
    }

    #[test]
    fn reader_waits_for_a_pending_stub_and_rejects_a_missing_one() {
        let seen = Mutex::new(String::new());
        let mut reader = OutputReader::new(true);
        assert_eq!(push_all(&mut reader, &[init("pending")], &seen).unwrap(), Step::Continue);
        let missing = [
            json!({"type": "system", "subtype": "init", "mcp_servers": []}),
            json!({"type": "system", "subtype": "init"}),
            json!({"type": "system", "subtype": "init", "mcp_servers": [{"name": "other", "status": "connected"}]}),
        ];
        for event in missing {
            let mut reader = OutputReader::new(true);
            let error = push_all(&mut reader, std::slice::from_ref(&event), &seen).unwrap_err().to_string();
            assert_eq!(error, "Claude Code could not load nano-coder's tools (MCP server status: missing)", "{event}");
        }
    }

    #[test]
    fn reader_reports_failed_results_without_text_or_a_sign_in_problem() {
        let seen = Mutex::new(String::new());
        let failure = |result: &str, status: Option<u64>| {
            let mut event = json!({"type": "result", "is_error": true, "result": result});
            if let Some(status) = status {
                event["api_error_status"] = json!(status);
            }
            push_all(&mut OutputReader::new(false), &[event], &seen).unwrap_err().to_string()
        };
        assert_eq!(failure("", Some(529)), "Claude Code: the request failed (HTTP 529)");
        // Only a sign-in problem gets the sign-in hint.
        assert_eq!(failure("Overloaded", None), "Claude Code: Overloaded");
    }

    /// A small PNG stored in `dir` as an attachment read from `/work/{name}`,
    /// with the base64 the request should carry for it.
    fn stored_image(dir: &Path, name: &str, color: [u8; 3]) -> (crate::llm::Attachment, String) {
        let image = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(8, 8, image::Rgb(color)));
        let mut out = std::io::Cursor::new(Vec::new());
        image.write_to(&mut out, image::ImageFormat::Png).unwrap();
        let bytes = out.into_inner();
        let attachment = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: PathBuf::from(format!("/work/{name}")),
            sha256: crate::attachment::sha256_hex(&bytes),
            width: 8,
            height: 8,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        crate::attachment::store(dir, &attachment, &bytes).unwrap();
        (attachment, base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &bytes))
    }

    /// A user message with an image, then a tool call whose first result
    /// carries an image and whose second does not.
    fn conversation_with_images(dir: &Path) -> (Vec<Message>, String, String) {
        let (pasted, pasted_data) = stored_image(dir, "pasted.png", [200, 30, 30]);
        let (read, read_data) = stored_image(dir, "diagram.png", [30, 30, 200]);
        let messages = vec![
            Message::user("compare these").with_attachments(vec![pasted]),
            Message::assistant_with_tools(
                "",
                vec![tool_call("t1", "read_file", json!({"path": "diagram.png"})), tool_call("t2", "bash", json!({}))],
            ),
            Message::tool_result("t1", "read_file", "image/png, 8×8").with_attachments(vec![read]),
            Message::tool_result("t2", "bash", "ok"),
        ];
        (messages, pasted_data, read_data)
    }

    fn vision(max_images: usize) -> crate::vision::Vision {
        crate::vision::Vision {
            max_images,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        }
    }

    #[test]
    fn transcript_puts_each_image_right_after_its_message() {
        let dir = tempfile::tempdir().unwrap();
        let (messages, pasted, read) = conversation_with_images(dir.path());
        let request = ChatRequest {
            vision: Some(vision(5)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        let blocks = transcript_blocks(&request, &request.attachment_plan());
        let image = |data: &str| json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}});
        assert_eq!(blocks.len(), 6, "{blocks:#?}");
        assert_eq!(blocks[0]["text"], "<user>\ncompare these\n</user>");
        assert_eq!(blocks[1], image(&pasted));
        assert!(blocks[2]["text"].as_str().unwrap().starts_with("<assistant>\n<tool_call id=\"t1\""));
        // The image splits the run of tool results: the result it belongs to,
        // the image, then the remaining results.
        assert_eq!(blocks[3]["text"], "<tool_result id=\"t1\" name=\"read_file\">\nimage/png, 8×8\n</tool_result>");
        assert_eq!(blocks[4], image(&read));
        assert_eq!(blocks[5]["text"], "<tool_result id=\"t2\" name=\"bash\">\nok\n</tool_result>");
        assert!(blocks[5].get("cache_control").is_some());
        assert!(blocks[..5].iter().all(|b| b.get("cache_control").is_none()));
    }

    #[test]
    fn transcript_replaces_images_over_the_limit_with_a_placeholder() {
        let dir = tempfile::tempdir().unwrap();
        let (messages, _, read) = conversation_with_images(dir.path());
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        let blocks = transcript_blocks(&request, &request.attachment_plan());
        // Only the newest image is sent; the older one is named in its message.
        assert_eq!(
            blocks[0]["text"],
            "<user>\ncompare these\n[image omitted: /work/pasted.png (sent earlier)]\n</user>"
        );
        assert_eq!(blocks[1]["type"], "text");
        let images: Vec<&Value> = blocks.iter().filter(|b| b["type"] == "image").collect();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0]["source"]["data"], read);
    }

    // The `claude` process itself, run through a fake `claude`.

    /// A client that runs `body` as a fake `claude` (an `sh -c` script, so no
    /// executable file is written). Before `body`, the script records into
    /// `dir` its pid, arguments and stdin, and copies the system prompt, MCP
    /// config and tool list it was pointed at, since nano-coder deletes those
    /// once the call ends. `body` can print canned output from `$dir/events`.
    fn fake_claude(dir: &Path, body: &str) -> ClaudeCodeClient {
        let script = format!(
            r#"dir='{dir}'
echo $$ > "$dir/pid"
printf '%s\n' "$@" > "$dir/args"
prev=
for arg in "$@"; do
  case "$prev" in
    --system-prompt-file) cp "$arg" "$dir/system.md"; printf '%s' "$arg" > "$dir/system-path" ;;
    --mcp-config) cp "$arg" "$dir/mcp.json"; cp "$(dirname "$arg")/tools.json" "$dir/tools.json" ;;
  esac
  prev=$arg
done
cat > "$dir/stdin"
{body}"#,
            dir = dir.display()
        );
        let provider = crate::providers::resolve("claude-code", &Default::default(), "openai").unwrap();
        let mut client = ClaudeCodeClient::new(provider).unwrap();
        client.program = Some(("/bin/sh".into(), vec!["-c".into(), script, "claude".into()]));
        client
    }

    fn write_events(dir: &Path, events: &[Value]) {
        std::fs::write(dir.join("events"), events.iter().map(|e| format!("{e}\n")).collect::<String>()).unwrap();
    }

    fn read(dir: &Path, name: &str) -> String {
        std::fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("reading {name}: {e}"))
    }

    fn running(pid: libc::pid_t) -> bool {
        // SAFETY: signal 0 only checks whether the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// Whether process `pid` is gone within `limit`.
    async fn exits_within(pid: libc::pid_t, limit: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + limit;
        while running(pid) {
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        true
    }

    #[tokio::test]
    async fn run_sends_the_call_and_stops_claude_once_the_answer_ends() {
        let dir = tempfile::tempdir().unwrap();
        write_events(dir.path(), &answer_with_tool_call());
        // Like the real CLI, the fake keeps running after the answer: it is
        // waiting on the tool stub, which never answers.
        let client = fake_claude(dir.path(), r#"cat "$dir/events"; exec sleep 30"#);
        let messages = conversation();
        let tools = [crate::tools::ToolDefinition {
            name: "read_file".into(),
            description: "Read a file".into(),
            parameters: json!({"type": "object"}),
        }];
        let request = ChatRequest {
            tools: &tools,
            thinking: Some(Request::Effort("high".into())),
            ..ChatRequest::test_request(&messages)
        };
        let seen = Mutex::new(String::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(text) = event {
                seen.lock().unwrap().push_str(text);
            }
        };
        let response = client.chat_stream(&request, &sink).await.unwrap();
        assert_eq!(*seen.lock().unwrap(), "Reading.");
        assert_eq!(response.content, "Reading.");
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].name, "read_file");
        assert_eq!(response.tool_calls[0].arguments, json!({"path": "a"}));

        // stdin held one message: a user turn with the transcript.
        let stdin = read(dir.path(), "stdin");
        assert_eq!(stdin.lines().count(), 1, "{stdin}");
        let input: Value = serde_json::from_str(&stdin).unwrap();
        let expected = json!(transcript_blocks(&request, &request.attachment_plan()));
        assert_eq!(input, json!({"type": "user", "message": {"role": "user", "content": expected}}));
        assert_eq!(read(dir.path(), "system.md"), system_prompt(&messages));
        let args: Vec<String> = read(dir.path(), "args").lines().map(String::from).collect();
        assert!(args.windows(2).any(|pair| pair == ["--effort", "high"]), "{args:?}");
        assert!(args.windows(2).any(|pair| pair == ["--allowedTools", "mcp__nano"]), "{args:?}");

        // The MCP config runs this binary as the stub, over the offered tools.
        let mcp: Value = serde_json::from_str(&read(dir.path(), "mcp.json")).unwrap();
        let stub = &mcp["mcpServers"]["nano"];
        assert_eq!(stub["command"], json!(std::env::current_exe().unwrap()));
        assert_eq!(stub["args"][0], TOOL_STUB_FLAG);
        let tools: Value = serde_json::from_str(&read(dir.path(), "tools.json")).unwrap();
        assert_eq!(
            tools,
            json!([{"name": "read_file", "description": "Read a file", "inputSchema": {"type": "object"}}])
        );

        // The call's files are gone, and so is `claude`.
        let call_dir = PathBuf::from(read(dir.path(), "system-path")).parent().unwrap().to_path_buf();
        assert!(!call_dir.exists(), "{} was left behind", call_dir.display());
        let pid: libc::pid_t = read(dir.path(), "pid").trim().parse().unwrap();
        assert!(exits_within(pid, Duration::from_secs(5)).await, "claude kept running after the answer");
    }

    #[tokio::test]
    async fn run_kills_a_claude_that_ignores_the_stop_signal() {
        let dir = tempfile::tempdir().unwrap();
        write_events(dir.path(), &answer_with_tool_call());
        // `sleep` inherits the ignored SIGTERM.
        let client = fake_claude(dir.path(), r#"trap '' TERM; cat "$dir/events"; exec sleep 30"#);
        let messages = conversation();
        let response = client.chat(&ChatRequest::test_request(&messages)).await.unwrap();
        assert_eq!(response.content, "Reading.");
        let pid: libc::pid_t = read(dir.path(), "pid").trim().parse().unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(running(pid), "SIGTERM should have been ignored");
        assert!(exits_within(pid, STOP_GRACE + Duration::from_secs(5)).await, "claude was never killed");
    }

    #[tokio::test]
    async fn run_reports_claude_exiting_early_with_its_stderr() {
        let messages = conversation();
        let request = ChatRequest::test_request(&messages);
        let dir = tempfile::tempdir().unwrap();
        let client = fake_claude(dir.path(), "echo 'starting up' >&2; echo >&2; echo 'fatal: bad config' >&2; exit 3");
        let error = client.chat(&request).await.unwrap_err().to_string();
        assert_eq!(error, "Claude Code exited (exit status: 3) before answering: starting up | fatal: bad config");
        let client = fake_claude(dir.path(), "exit 0");
        let error = client.chat(&request).await.unwrap_err().to_string();
        assert_eq!(error, "Claude Code exited (exit status: 0) before answering");
    }

    #[tokio::test]
    async fn run_gives_up_when_claude_goes_quiet() {
        let dir = tempfile::tempdir().unwrap();
        write_events(dir.path(), &[init("connected")]);
        let mut client = fake_claude(dir.path(), r#"cat "$dir/events"; exec sleep 30"#);
        client.provider.timeout = Duration::from_secs(1);
        let messages = conversation();
        let started = std::time::Instant::now();
        let error = client.chat(&ChatRequest::test_request(&messages)).await.unwrap_err().to_string();
        assert_eq!(error, "Claude Code sent nothing for 1s");
        assert!(started.elapsed() < Duration::from_secs(10), "took {:?}", started.elapsed());
    }

    #[tokio::test]
    async fn run_explains_how_to_find_a_missing_claude() {
        let provider = crate::providers::resolve("claude-code", &Default::default(), "openai").unwrap();
        let mut client = ClaudeCodeClient::new(provider).unwrap();
        client.program = Some(("/nonexistent/claude".into(), Vec::new()));
        let messages = conversation();
        let error = client.chat(&ChatRequest::test_request(&messages)).await.unwrap_err().to_string();
        assert!(error.starts_with("Claude Code (`claude`) was not found"), "{error}");
        assert!(error.contains(BINARY_ENV), "{error}");
    }
}
