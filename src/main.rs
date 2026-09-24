#![deny(warnings)]

use anyhow::Result;
use chrono::Local;
use serde_json::json;
use std::env;
use std::collections::VecDeque;
use std::io::{self, IsTerminal, Write};
use tokio::sync::mpsc;

mod agent;
mod acp;
mod bash;
mod commands;
mod config;
mod context;
mod files;
mod goal;
mod hooks;
mod instructions;
mod plan;
mod lineedit;
mod llm;
mod output;
mod permissions;
mod providers;
mod reminders;
mod sandbox;
mod settings;
mod session;
mod shell;
mod skills;
mod status;
mod tools;
mod ui;

use agent::Agent;
use config::ConfigManager;
use hooks::HookEvent;
use tools::ToolDefinition;

fn register_builtin_tools(agent: &mut Agent) {
    // get_time tool
    let time_def = ToolDefinition::new(
        "get_time",
        "Get the current date and time",
        json!({ "type": "object", "properties": {} }),
    );
    agent.tools().register(time_def, Box::new(|_| {
        Ok(json!({ "time": Local::now().to_string() }))
    }));

    // echo tool
    let echo_def = ToolDefinition::new(
        "echo",
        "Echo back the input text",
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string" }
            },
            "required": ["text"]
        }),
    );
    agent.tools().register(echo_def, Box::new(|args| {
        let text = args["text"].as_str().unwrap_or("");
        Ok(json!({ "echo": text }))
    }));

    files::register(agent.tools());

    // bash tool
    let bash_config = bash::BashConfig {
        default_timeout: std::time::Duration::from_secs(agent.config().bash_timeout_secs.max(1)),
        cancel: Some(agent.control().cancel_flag()),
        sandbox: agent.config().sandbox.clone(),
        ..Default::default()
    };
    agent.tools().register(bash::definition(), Box::new(move |args| {
        Ok(json!(bash::run(&bash_config, &args)))
    }));
}

fn register_hooks(agent: &mut Agent) {
    // Log all lifecycle events
    for event in [
        HookEvent::BeforeContextLoad,
        HookEvent::AfterContextLoad,
        HookEvent::BeforeLLMSend,
        HookEvent::AfterLLMResponse,
        HookEvent::BeforeToolCall,
        HookEvent::AfterToolCall,
    ] {
        let event_name = event.to_string();
        agent.hooks().register(event.clone(), Box::new(move |ctx| {
            if ui::verbosity() < ui::Verbosity::Debug {
                return;
            }
            match ctx.event {
                HookEvent::BeforeContextLoad => {
                    let input = ctx.data.get("user_input").and_then(|v| v.as_str()).unwrap_or("");
                    ui::log(&format!("[hook] {} - user: {}", event_name, input));
                }
                HookEvent::AfterContextLoad => {
                    let count = ctx.data.get("message_count").and_then(|v| v.as_i64()).unwrap_or(0);
                    ui::log(&format!("[hook] {} - messages: {}", event_name, count));
                }
                HookEvent::BeforeLLMSend => {
                    let iter = ctx.data.get("iteration").and_then(|v| v.as_i64()).unwrap_or(0);
                    ui::log(&format!("[hook] {} - iteration: {}", event_name, iter));
                }
                HookEvent::AfterLLMResponse => {
                    let has_tools = ctx.data.get("has_tool_calls").and_then(|v| v.as_bool()).unwrap_or(false);
                    ui::log(&format!("[hook] {} - tool_calls: {}", event_name, has_tools));
                }
                HookEvent::BeforeToolCall => {
                    let name = ctx.data.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
                    ui::log(&format!("[hook] {} - tool: {}", event_name, name));
                }
                HookEvent::AfterToolCall => {
                    let name = ctx.data.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
                    ui::log(&format!("[hook] {} - tool: {}", event_name, name));
                }
            }
        }));
    }
}

/// Terminal input, read on demand so `/settings` prompts can use stdin directly.
enum TermInput {
    Line(String),
    Eof,
    Interrupt,
    /// Ctrl-O: expand or collapse thinking.
    ToggleThinking,
    /// A lone Esc press.
    Escape,
}

/// Esc twice within this window cancels the running turn.
const DOUBLE_ESCAPE_WINDOW: std::time::Duration = std::time::Duration::from_millis(1000);

/// Detects a double Esc press.
#[derive(Default)]
struct DoubleEscape {
    last: Option<std::time::Instant>,
}

impl DoubleEscape {
    /// Record a press at `now`; true when it completes a double press.
    fn press(&mut self, now: std::time::Instant) -> bool {
        match self.last.take() {
            Some(last) if now.duration_since(last) <= DOUBLE_ESCAPE_WINDOW => true,
            _ => {
                self.last = Some(now);
                false
            }
        }
    }
}

struct Terminal {
    want: std::sync::mpsc::Sender<()>,
    outstanding: bool,
    events: mpsc::UnboundedReceiver<TermInput>,
    /// Input read during a turn that is not a steer (piped prompts, commands).
    queued: VecDeque<TermInput>,
    /// Lines typed during a turn steer it (only when stdin is a terminal).
    steerable: bool,
    /// Where `/settings` saves changes.
    config_path: std::path::PathBuf,
    /// The line being typed (terminal stdin only).
    view: lineedit::SharedView,
    renderer: std::sync::Arc<ui::Renderer>,
}

impl Terminal {
    fn start(config_path: std::path::PathBuf, view: lineedit::SharedView, renderer: std::sync::Arc<ui::Renderer>) -> Self {
        let (tx, events) = mpsc::unbounded_channel();
        let (want, want_rx) = std::sync::mpsc::channel::<()>();
        let lines = tx.clone();
        let key_mode = io::stdin().is_terminal() && io::stdout().is_terminal();
        let reader_view = view.clone();
        std::thread::spawn(move || {
            if key_mode {
                let mut reader = lineedit::LineReader::default();
                let send = |key: lineedit::Key| {
                    let _ = lines.send(match key {
                        lineedit::Key::Line(line) => TermInput::Line(line),
                        lineedit::Key::Eof => TermInput::Eof,
                        lineedit::Key::Interrupt => TermInput::Interrupt,
                        lineedit::Key::ToggleThinking => TermInput::ToggleThinking,
                        lineedit::Key::Escape => TermInput::Escape,
                    });
                };
                for () in want_rx {
                    let key = reader.read_line(&reader_view, &send);
                    let eof = matches!(key, lineedit::Key::Eof);
                    send(key);
                    if eof {
                        break;
                    }
                }
                return;
            }
            for () in want_rx {
                let mut line = String::new();
                match io::stdin().read_line(&mut line) {
                    Ok(0) | Err(_) => {
                        let _ = lines.send(TermInput::Eof);
                        break;
                    }
                    Ok(_) => {
                        if lines.send(TermInput::Line(line)).is_err() {
                            break;
                        }
                    }
                }
            }
        });
        tokio::spawn(async move {
            while tokio::signal::ctrl_c().await.is_ok() {
                if tx.send(TermInput::Interrupt).is_err() {
                    break;
                }
            }
        });
        Self {
            want,
            outstanding: false,
            events,
            queued: VecDeque::new(),
            steerable: io::stdin().is_terminal(),
            config_path,
            view,
            renderer,
        }
    }

    fn request_line(&mut self) {
        if !self.outstanding {
            self.outstanding = self.want.send(()).is_ok();
        }
    }

    async fn next(&mut self) -> TermInput {
        if let Some(input) = self.queued.pop_front() {
            return input;
        }
        self.request_line();
        self.recv().await
    }

    async fn recv(&mut self) -> TermInput {
        let input = self.events.recv().await.unwrap_or(TermInput::Eof);
        if !matches!(input, TermInput::Interrupt | TermInput::ToggleThinking | TermInput::Escape) {
            self.outstanding = false;
        }
        input
    }
}

/// Run a turn; typed lines steer it, and Ctrl-C or Esc Esc cancels it.
async fn run_interactive_turn(agent: &mut Agent, text: &str, terminal: &mut Terminal) -> Result<agent::TurnOutcome> {
    let control = agent.control();
    let renderer = terminal.renderer.clone();
    if terminal.steerable && ui::verbosity() >= ui::Verbosity::Verbose {
        renderer.note("[running: type a message and Enter to steer, Esc Esc or Ctrl-C to cancel, Ctrl-O to expand thinking]");
    }
    // Blank line separates user input from LLM output.
    println!();
    renderer.begin_turn();
    terminal.view.lock().unwrap().set_mode(lineedit::EditMode::Turn);
    let mut escape = DoubleEscape::default();
    let outcome = async {
        let turn = agent.run_turn(None, text);
        tokio::pin!(turn);
        loop {
            if !terminal.queued.iter().any(|i| matches!(i, TermInput::Eof)) {
                terminal.request_line();
            }
            tokio::select! {
                // Poll the turn first: its first poll resets the control, which
                // must happen before a buffered cancel or steer is routed to it.
                biased;
                outcome = &mut turn => break outcome,
                input = terminal.recv() => match input {
                    TermInput::Interrupt => {
                        control.cancel();
                        renderer.urgent_note("[cancelling...]");
                    }
                    TermInput::Escape if control.is_cancelled() => {}
                    TermInput::Escape => {
                        if escape.press(std::time::Instant::now()) {
                            control.cancel();
                            renderer.urgent_note("[cancelling...]");
                        } else {
                            renderer.urgent_note("[Esc again to cancel]");
                        }
                    }
                    TermInput::ToggleThinking => {
                        renderer.toggle_thinking();
                    }
                    TermInput::Line(line) if terminal.steerable && !line.trim().is_empty() && !line.trim().starts_with('/') => {
                        control.steer(line.trim(), None);
                        renderer.note(&format!("↳ steer: {}", line.trim()));
                    }
                    TermInput::Line(line) if terminal.steerable && line.trim().starts_with('/') => {
                        renderer.note(&format!("[commands wait for the turn to finish: {}]", line.trim()));
                        terminal.queued.push_back(TermInput::Line(line));
                    }
                    TermInput::Line(line) if terminal.steerable => drop(line),
                    other => terminal.queued.push_back(other),
                },
            }
        }
    }
    .await;
    renderer.end_turn();
    terminal.view.lock().unwrap().set_mode(lineedit::EditMode::Prompt);
    let outcome = outcome?;
    // A steer typed as the turn finished becomes the next prompt, unless the
    // turn was cancelled.
    for steer in control.take_pending() {
        if outcome.stop_reason == agent::StopReason::Cancelled {
            renderer.note(&format!("[steer dropped: {}]", steer.text));
        } else {
            terminal.queued.push_back(TermInput::Line(steer.text));
        }
    }
    Ok(outcome)
}

/// Run an explicit compaction; Ctrl-C or Esc Esc cancels it.
async fn run_compaction(
    agent: &mut Agent,
    instructions: Option<&str>,
    terminal: &mut Terminal,
) -> Result<Option<agent::CompactReport>> {
    let control = agent.control();
    let compaction = agent.compact(instructions);
    tokio::pin!(compaction);
    let mut escape = DoubleEscape::default();
    loop {
        tokio::select! {
            biased;
            report = &mut compaction => return report,
            input = terminal.recv() => match input {
                TermInput::Interrupt => {
                    control.cancel();
                    eprintln!("[cancelling...]");
                }
                TermInput::Escape if control.is_cancelled() => {}
                TermInput::Escape => {
                    if escape.press(std::time::Instant::now()) {
                        control.cancel();
                        eprintln!("[cancelling...]");
                    } else {
                        eprintln!("[Esc again to cancel]");
                    }
                }
                TermInput::ToggleThinking => {
                    terminal.renderer.toggle_thinking();
                }
                other => terminal.queued.push_back(other),
            },
        }
    }
}

async fn run_command(agent: &mut Agent, cmd: &str, terminal: &mut Terminal) -> Result<bool> {
    match cmd {
        "/exit" | "/quit" => Ok(false),
        "/help" => {
            println!("{}", commands::help_text());
            Ok(true)
        }
        _ if cmd == "/compact" || cmd.starts_with("/compact ") => {
            let instructions = cmd["/compact".len()..].trim().to_string();
            println!("Compacting...");
            match run_compaction(agent, Some(instructions.as_str()).filter(|i| !i.is_empty()), terminal).await? {
                Some(report) => println!("Conversation {report}"),
                None => println!("Nothing to compact"),
            }
            Ok(true)
        }
        "/context" => {
            let stats = agent.context_stats().lock().unwrap().clone();
            println!("Model:        {}/{}", stats.provider, stats.model);
            println!(
                "Context:      {}{} of {} tokens ({:.1}%){}",
                if stats.calibrated { "" } else { "~" },
                stats.tokens,
                stats.window,
                stats.percent(),
                if stats.calibrated { ", anchored to reported usage" } else { ", estimated" }
            );
            println!("Messages:     {}", stats.messages);
            let system_tokens = crate::context::text_tokens(&agent.system_prompt());
            println!("System prompt: {} tokens", system_tokens);
            let files = agent.project_instruction_files();
            if files.is_empty() {
                println!("Instructions: none (no AGENTS.md, CLAUDE.md or .github/copilot-instructions.md found)");
            } else {
                println!("Instructions: {}", files.join(", "));
            }
            let skills = agent.skills();
            if !skills.is_empty() || !skills.warnings.is_empty() {
                println!("Skills:       {} (/skills to list them)", skills.skills.len());
            }
            if let Some((done, total)) = stats.plan {
                println!("Plan:         {done}/{total} done (/plan to show it)");
            }
            println!("Session:      {} input, {} output tokens", stats.session_input_tokens, stats.session_output_tokens);
            match stats.auto_compact {
                Some(t) => println!(
                    "Auto-compact: at {:.0}% (~{} tokens); compacted {} time(s)",
                    t * 100.0,
                    (stats.window as f64 * t) as usize,
                    stats.compactions
                ),
                None => println!("Auto-compact: off"),
            }
            println!("(context window {})", agent.context_window_with_source().1);
            Ok(true)
        }
        "/settings" if terminal.outstanding => {
            // Typed during a turn: a stdin read is still pending, so an
            // interactive editor would race it for keystrokes.
            let config = agent.config();
            println!("model: {}", config.model);
            println!("temperature: {}", config.temperature);
            println!("max_tokens: {}", config.max_tokens);
            println!("(read-only: run /settings again at the prompt to edit)");
            Ok(true)
        }
        "/settings" => {
            settings::run(agent, &terminal.config_path).await?;
            Ok(true)
        }
        "/tools" => {
            println!("Available tools:");
            for def in agent.tool_definitions() {
                println!("  {} - {}", def.name, def.description);
            }
            Ok(true)
        }
        "/skills" => {
            let skills = agent.skills();
            if skills.is_empty() {
                println!("No skills found (looked in {}, ai.lock and {}).", agent.config().skills.dirs.join(", "), agent.config().skills.user_dirs.join(", "));
            }
            for skill in &skills.skills {
                println!("  {} - {}\n      {}", skill.name, skill.description, skill.dir.display());
            }
            for warning in &skills.warnings {
                println!("Warning: {warning}");
            }
            Ok(true)
        }
        "/plan" => {
            if agent.plan().is_empty() {
                println!("No plan yet. The agent makes one with the plan_add tool.");
            } else {
                print!("{}", agent.plan().render(true, usize::MAX));
            }
            Ok(true)
        }
        "/model" => {
            println!("Model: {} (provider {}, spec {:?})", agent.model_name(), agent.provider_name(), agent.config().model);
            Ok(true)
        }
        _ if cmd.starts_with("/model ") => {
            agent.set_model(cmd["/model ".len()..].trim()).await?;
            println!("Model set to {} (provider {})", agent.model_name(), agent.provider_name());
            Ok(true)
        }
        "/providers" => {
            let (user, default_provider) = agent.config().effective_providers();
            println!("Providers (default: {default_provider}):");
            for (name, provider) in providers::effective_providers(&user) {
                let kind = provider.kind.map(|k| format!("{k:?}").to_lowercase()).unwrap_or_else(|| "?".into());
                let key = settings::key_status(&provider);
                let url = provider.base_url.unwrap_or_else(|| match provider.kind {
                    Some(providers::ProviderKind::GithubCopilot) => "(from session token)".into(),
                    _ => "-".into(),
                });
                println!("  {name:<14} {kind:<14} {url:<55} {key}");
            }
            Ok(true)
        }
        "/session" => {
            match (agent.session_id(), agent.session_path()) {
                (Some(id), Some(path)) => println!("Session {id}: {}", path.display()),
                _ => println!("Session persistence is disabled"),
            }
            Ok(true)
        }
        "/verbosity" => {
            let current = ui::verbosity();
            println!("Verbosity: {current} ({})", current.describe());
            for level in ui::Verbosity::ALL {
                println!("  {:<8} {}", level.to_string(), level.describe());
            }
            Ok(true)
        }
        _ if cmd.starts_with("/verbosity ") => {
            match cmd["/verbosity ".len()..].parse::<ui::Verbosity>() {
                Ok(level) => {
                    ui::set_verbosity(level);
                    agent.config_mut().verbosity = level;
                    println!("Verbosity set to {level} ({}); /settings saves it", level.describe());
                }
                Err(e) => println!("{e}"),
            }
            Ok(true)
        }
        _ => {
            let outcome = run_interactive_turn(agent, cmd, terminal).await?;
            if ui::verbosity() == ui::Verbosity::Quiet {
                println!("\n{}", ui::stamp_block(&outcome.response));
            } else if outcome.stop_reason == agent::StopReason::Cancelled {
                println!("{}", ui::stamp_block(&format!("\x1b[2m{}\x1b[0m", outcome.response)));
            } else if outcome.stop_reason == agent::StopReason::MaxTurnRequests {
                let last = outcome.response.lines().last().unwrap_or_default();
                println!("{}", ui::stamp_block(&format!("\x1b[2m{last}\x1b[0m")));
            }
            println!();
            Ok(true)
        }
    }
}

/// Restores the full screen and terminal modes when the interactive loop ends.
struct StatusGuard(Option<std::sync::Arc<status::StatusLine>>);

impl Drop for StatusGuard {
    fn drop(&mut self) {
        lineedit::restore_terminal();
        if let Some(status) = &self.0 {
            status.teardown();
        }
    }
}

struct Args {
    acp: bool,
    login: Option<String>,
    list_models: Option<String>,
    model: Option<String>,
    resume: Option<String>,
    config: Option<std::path::PathBuf>,
    verbosity: Option<ui::Verbosity>,
    sandbox: Option<sandbox::SandboxMode>,
    allow: Vec<String>,
    deny: Vec<String>,
}

fn parse_args() -> Result<Args> {
    let mut args = Args {
        acp: false,
        login: None,
        list_models: None,
        model: None,
        resume: None,
        config: None,
        verbosity: None,
        sandbox: None,
        allow: Vec::new(),
        deny: Vec::new(),
    };
    let mut iter = env::args().skip(1);
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| iter.next().ok_or_else(|| anyhow::anyhow!("{name} requires a value"));
        match arg.as_str() {
            "--acp" => args.acp = true,
            "--login" => args.login = Some(value("--login")?),
            "--list-models" => args.list_models = Some(value("--list-models")?),
            "--model" => args.model = Some(value("--model")?),
            "--resume" => args.resume = Some(value("--resume")?),
            "--config" => args.config = Some(value("--config")?.into()),
            "--verbosity" | "-v" => {
                args.verbosity = Some(value("--verbosity")?.parse().map_err(|e: String| anyhow::anyhow!(e))?)
            }
            "--sandbox" => {
                args.sandbox = Some(value("--sandbox")?.parse().map_err(|e: String| anyhow::anyhow!(e))?)
            }
            "--allow" => args.allow.push(value("--allow")?),
            "--deny" => args.deny.push(value("--deny")?),
            "-h" | "--help" => {
                println!("Usage: nano-coder [--acp] [--model provider/model] [--resume SESSION_ID] [--config PATH]");
                println!("                  [--verbosity quiet|normal|verbose|debug]");
                println!("                  [--sandbox off|workspace|read-only] [--allow RULE]... [--deny RULE]...");
                println!("       nano-coder --login github-copilot");
                println!("       nano-coder --list-models PROVIDER[/model]");
                std::process::exit(0);
            }
            other => anyhow::bail!("unknown argument {other:?} (see --help)"),
        }
    }
    Ok(args)
}

#[tokio::main]
async fn main() -> Result<()> {
    // Detect execution mode from command-line args
    let args = parse_args()?;

    if let Some(provider) = &args.login {
        if provider != "github-copilot" {
            anyhow::bail!("--login supports only github-copilot (other providers use API keys)");
        }
        let path = providers::github_copilot::login().await?;
        println!("Saved GitHub Copilot credentials to {}", path.display());
        return Ok(());
    }

    // Load config
    let config_mgr = match &args.config {
        Some(path) => ConfigManager::from_path(path.clone())?,
        None => ConfigManager::new()?,
    };
    let config_path = config_mgr.config_path().to_path_buf();
    let mut config = config_mgr.get().clone();
    if let Some(spec) = &args.list_models {
        let (user, default_provider) = config.effective_providers();
        let client = providers::build_lister(spec, &user, &default_provider)?;
        for model in client.list_models().await? {
            println!("{}/{model}", client.provider_name());
        }
        return Ok(());
    }
    if let Some(model) = args.model.clone().or_else(|| env::var("AGENTIC_HARNESS_MODEL").ok().filter(|m| !m.is_empty())) {
        config.model = model;
    }

    if let Some(level) = args.verbosity {
        config.verbosity = level;
    }
    let env_sandbox = env::var("NANO_CODER_SANDBOX").ok().filter(|m| !m.is_empty());
    if let Some(mode) = env_sandbox.map(|m| m.parse::<sandbox::SandboxMode>()).transpose().map_err(|e| anyhow::anyhow!("NANO_CODER_SANDBOX: {e}"))? {
        config.sandbox.mode = mode;
    }
    if let Some(mode) = args.sandbox {
        config.sandbox.mode = mode;
    }
    config.permissions.allow.extend(args.allow.iter().cloned());
    config.permissions.deny.extend(args.deny.iter().cloned());
    ui::set_verbosity(config.verbosity);
    ui::set_timestamps(config.timestamps);

    // Create agent with the configured provider
    let mut agent = Agent::from_config(config)?;

    agent.detect_context_window().await;

    // Register tools and hooks
    register_builtin_tools(&mut agent);
    register_hooks(&mut agent);

    if args.acp {
        // ACP headless mode; sessions start with session/new or session/load
        if let Some(id) = &args.resume {
            agent.load_session(id)?;
        }
        eprintln!("ACP harness ready (provider: {}, model: {})", agent.provider_name(), agent.model_name());
        acp::run_acp(&mut agent).await?;
    } else {
        match &args.resume {
            Some(id) => agent.load_session(id)?,
            None => {
                if agent.config().persist_sessions {
                    agent.new_session()?;
                } else {
                    agent.apply_project_instructions();
                }
            }
        }

        // Interactive CLI mode
        println!("nano-coder v{}", env!("CARGO_PKG_VERSION"));
        println!("Model: {} (provider: {})", agent.model_name(), agent.provider_name());
        if let Some(id) = agent.session_id() {
            println!("Session: {id} (resume with --resume {id})");
        }
        for file in agent.project_instruction_files() {
            println!("Instructions: {file}");
        }
        let skills = agent.skills();
        if !skills.is_empty() {
            println!("Skills: {}", skills.names().join(", "));
        }
        for warning in &skills.warnings {
            println!("Skills warning: {warning}");
        }
        println!("Type /help for commands\n");

        // Main loop
        let status = status::StatusLine::install(agent.context_stats());
        let _status_guard = StatusGuard(status.clone());
        let previous_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            lineedit::restore_terminal();
            previous_hook(info);
        }));
        let renderer = ui::Renderer::new(status.clone());
        ui::install(renderer.clone());
        let sink = renderer.clone();
        agent.set_event_sink(Box::new(move |_, event| sink.event(event)));
        agent.set_streaming(true);
        agent.refresh_stats();
        let view = lineedit::EditView::shared(status.clone());
        if let Ok(mut resized) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
        {
            let view = view.clone();
            let status = status.clone();
            tokio::spawn(async move {
                while resized.recv().await.is_some() {
                    if let Some(status) = &status {
                        status.resize();
                    }
                    view.lock().unwrap().resize();
                }
            });
        }
        let mut terminal = Terminal::start(config_path, view, renderer);
        let mut running = true;
        let mut exit_armed = false;
        while running {
            if let Some(status) = &status {
                status.draw();
            }
            let prompt = |terminal: &Terminal| {
                if terminal.queued.is_empty() {
                    let mut view = terminal.view.lock().unwrap();
                    let prompt = view.prompt();
                    io::stdout().write_all(prompt.as_bytes()).unwrap();
                    io::stdout().flush().unwrap();
                    view.prompt_redrawn();
                }
            };
            prompt(&terminal);

            let input = loop {
                match terminal.next().await {
                    TermInput::ToggleThinking => {
                        if terminal.renderer.toggle_thinking() {
                            prompt(&terminal);
                        }
                    }
                    other => break other,
                }
            };
            let input = match input {
                TermInput::Eof => break,
                TermInput::Interrupt if exit_armed => break,
                TermInput::Interrupt => {
                    exit_armed = true;
                    println!("\n(Ctrl-C again to exit)");
                    continue;
                }
                TermInput::ToggleThinking | TermInput::Escape => continue,
                TermInput::Line(line) => line.trim().to_string(),
            };
            exit_armed = false;
            if input.is_empty() {
                continue;
            }

            match run_command(&mut agent, &input, &mut terminal).await {
                Ok(continue_running) => {
                    running = continue_running;
                }
                Err(e) => {
                    eprintln!("Error: {:#}", e);
                }
            }
        }

        println!("\nGoodbye!");
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn double_escape_needs_two_presses_within_the_window() {
        let mut escape = DoubleEscape::default();
        let t = Instant::now();
        assert!(!escape.press(t));
        assert!(escape.press(t + Duration::from_millis(400)));
        // The pair is consumed: the next press starts over.
        assert!(!escape.press(t + Duration::from_millis(500)));
        // Too slow: the second press re-arms instead of cancelling.
        assert!(!escape.press(t + Duration::from_millis(1600)));
        assert!(escape.press(t + Duration::from_millis(1700)));
    }
}
