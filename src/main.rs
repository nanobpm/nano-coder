#![deny(warnings)]

use anyhow::Result;
use chrono::Local;
use serde_json::json;
use std::collections::VecDeque;
use std::env;
use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

mod acp;
mod agent;
mod bash;
mod commands;
mod config;
mod context;
mod files;
mod frame;
mod goal;
mod history;
mod hooks;
mod input_history;
mod instructions;
mod lineedit;
mod llm;
mod memory;
mod mode;
mod output;
mod permissions;
mod plan;
mod providers;
mod question;
mod queue;
mod recents;
mod reminders;
mod resume;
mod sandbox;
mod session;
mod session_index;
mod settings;
mod shell;
mod skills;
mod status;
mod temperature;
mod tools;
mod trajectory;
mod ui;

use agent::Agent;
use config::ConfigManager;
use hooks::HookEvent;
use tools::ToolDefinition;

fn register_builtin_tools(agent: &mut Agent) {
    // get_time tool
    let time_def =
        ToolDefinition::new("get_time", "Get the current date and time", json!({ "type": "object", "properties": {} }));
    agent.tools().register(time_def, Box::new(|_| Ok(json!({ "time": Local::now().to_string() }))));

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
    agent.tools().register(
        echo_def,
        Box::new(|args| {
            let text = args["text"].as_str().unwrap_or("");
            Ok(json!({ "echo": text }))
        }),
    );

    files::register(agent.tools());

    // bash tool
    let bash_config = bash::BashConfig {
        default_timeout: std::time::Duration::from_secs(agent.config().bash_timeout_secs.max(1)),
        cancel: Some(agent.control().cancel_flag()),
        sandbox: agent.config().sandbox.clone(),
        shared_output_dir: Some(agent.spill_dir_handle()),
        ..Default::default()
    };
    agent.tools().register(bash::definition(), Box::new(move |args| Ok(json!(bash::run(&bash_config, &args)))));

    // question tool: blocks until the turn loop answers (see question.rs).
    // Headless (ACP) sessions have no one to answer, so it errors instead.
    let broker = agent.questions();
    agent.tools().register(question::definition(), Box::new(move |args| {
        if !broker.is_interactive() {
            anyhow::bail!("question tool needs an interactive terminal; end your turn with the question, or report_outcome(needs_input) with the question in the summary, instead");
        }
        let questions = question::parse(&args)?;
        let answer = broker.ask_blocking(questions.clone());
        Ok(json!(question::result_text(&questions, &answer)))
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
        agent.hooks().register(
            event.clone(),
            Box::new(move |ctx| {
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
            }),
        );
    }
}

/// Terminal input, read on demand so `/settings` prompts can use stdin directly.
enum TermInput {
    Line(String),
    /// Ctrl/Cmd-Enter during a turn: queue for a later turn instead of
    /// steering the running one.
    Queue(String),
    Eof,
    Interrupt,
    /// Ctrl-O: expand or collapse thinking.
    ToggleThinking,
    /// A lone Esc press.
    Escape,
    /// Shift+Tab: cycle the agent mode (normal/plan/auto).
    CycleMode,
}

/// "Model set to …", plus a warning when the new model ignores a temperature
/// configured for it.
fn model_set_text(agent: &Agent) -> String {
    let mut text = format!("Model set to {} (provider {})", agent.model_name(), agent.provider_name());
    if let Some(warning) = agent.temperature().warning {
        text.push_str(&format!("\nWarning: {warning}"));
    }
    text
}

/// Esc twice within this window cancels the running turn.
const DOUBLE_ESCAPE_WINDOW: std::time::Duration = std::time::Duration::from_millis(1000);

/// Ctrl-C twice within this window exits the interactive CLI. Time-based (not
/// "next line" based) so an interleaved keystroke or a queued/empty line
/// between the two presses cannot silently disarm the exit.
const DOUBLE_INTERRUPT_WINDOW: std::time::Duration = std::time::Duration::from_millis(2000);

/// Detects a double press of the same key within a window. The window is
/// time-based: a press that lands after the window has elapsed starts a fresh
/// pair rather than completing the old one, so unrelated input in between does
/// not consume or reset the gesture.
struct DoublePress {
    window: std::time::Duration,
    last: Option<std::time::Instant>,
}

impl DoublePress {
    fn new(window: std::time::Duration) -> Self {
        Self { window, last: None }
    }

    /// Record a press at `now`; true when it completes a double press.
    fn press(&mut self, now: std::time::Instant) -> bool {
        match self.last.take() {
            Some(last) if now.duration_since(last) <= self.window => true,
            _ => {
                self.last = Some(now);
                false
            }
        }
    }

    /// When armed (a first press is waiting for its pair), the instant at which
    /// the window lapses and the arm re-starts; `None` when not armed. Callers
    /// use this to bound the wait for the second press so any hint shown while
    /// armed can be cleared the moment the arm expires.
    fn deadline(&self) -> Option<std::time::Instant> {
        self.last.map(|last| last + self.window)
    }

    /// Drop a pending arm so the next press starts a fresh pair. Used when the
    /// window has lapsed with no second press, to keep any displayed hint in
    /// sync with the (now disarmed) detector.
    fn disarm(&mut self) {
        self.last = None;
    }
}

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
    /// Input read during a turn that is not a queue entry (piped prompts,
    /// commands that must wait for the turn to finish).
    queued: VecDeque<TermInput>,
    /// Messages typed during a turn, waiting to run as later prompts.
    /// Editable mid-turn with `/queue` (including removing entries).
    messages: queue::MessageQueue,
    /// Lines typed during a turn join the message queue (only when stdin is a
    /// terminal); piped lines keep the legacy "queued as later prompts" path.
    steerable: bool,
    /// Where `/settings` saves changes.
    config_path: std::path::PathBuf,
    /// The line being typed (terminal stdin only).
    view: lineedit::SharedView,
    /// Recently used models, hoisted in the `/model` type-ahead and saved
    /// here on each successful switch.
    recents: recents::SharedRecents,
    recents_path: std::path::PathBuf,
    renderer: std::sync::Arc<ui::Renderer>,
    /// The renderer mode active when the session started; a live `renderer`
    /// switch in `/settings` is detected against it.
    renderer_before: crate::frame::RendererMode,
    /// The status line, kept so a live renderer switch can re-anchor the
    /// scroll region (legacy) or let the frame clear it (frame).
    status: Option<std::sync::Arc<status::StatusLine>>,
    /// Set to make the stdin reader yield the terminal to a foreground picker
    /// (a `question`/turn-cap prompt), so the two never race for keystrokes.
    suspend: std::sync::Arc<std::sync::atomic::AtomicBool>,
    /// Monotonic generation bumped on every `suspend_input()`. It lets a
    /// picker's cleanup resume the reader only if no *newer* prompt has since
    /// suspended it: a stale auto-away worker must not clear a later prompt's
    /// suspension (which would resume stdin under an active dialoguer).
    suspend_gen: std::sync::Arc<std::sync::atomic::AtomicU64>,
    /// Serialises dialoguer picker workers so at most one ever owns stdin. An
    /// auto-away worker that outlived its timeout keeps this held until it
    /// exits, so a later question cannot spawn a second stdin reader.
    picker_lock: std::sync::Arc<tokio::sync::Mutex<()>>,
}

/// An owned token for one input suspension. Cleanup calls [`InputGate::release`],
/// which resumes the background line reader *only* if this is still the most
/// recent suspension — so a stale worker finishing late cannot clear a newer
/// prompt's gate and resume stdin while that prompt's dialoguer is active.
#[derive(Clone)]
struct InputGate {
    flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
    generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    token: u64,
}

impl InputGate {
    /// Resume the reader iff no later `suspend_input()` has superseded this one.
    fn release(&self) {
        use std::sync::atomic::Ordering::SeqCst;
        if self.generation.load(SeqCst) == self.token {
            self.flag.store(false, SeqCst);
        }
    }
}

impl Terminal {
    fn start(
        config_path: std::path::PathBuf,
        view: lineedit::SharedView,
        renderer: std::sync::Arc<ui::Renderer>,
        recents: recents::SharedRecents,
        recents_path: std::path::PathBuf,
        status: Option<std::sync::Arc<status::StatusLine>>,
        renderer_before: crate::frame::RendererMode,
    ) -> Self {
        let (tx, events) = mpsc::unbounded_channel();
        let (want, want_rx) = std::sync::mpsc::channel::<()>();
        let lines = tx.clone();
        let key_mode = io::stdin().is_terminal() && io::stdout().is_terminal();
        let reader_view = view.clone();
        let suspend = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let reader_suspend = suspend.clone();
        std::thread::spawn(move || {
            if key_mode {
                let mut reader = lineedit::LineReader::with_suspend(reader_suspend);
                let send = |key: lineedit::Key| {
                    let _ = lines.send(match key {
                        lineedit::Key::Line(line) => TermInput::Line(line),
                        lineedit::Key::Queue(line) => TermInput::Queue(line),
                        lineedit::Key::Eof => TermInput::Eof,
                        lineedit::Key::Interrupt => TermInput::Interrupt,
                        lineedit::Key::ToggleThinking => TermInput::ToggleThinking,
                        lineedit::Key::Escape => TermInput::Escape,
                        lineedit::Key::CycleMode => TermInput::CycleMode,
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
            messages: queue::MessageQueue::default(),
            steerable: io::stdin().is_terminal(),
            config_path,
            view,
            recents,
            recents_path,
            renderer,
            renderer_before,
            status,
            suspend,
            suspend_gen: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
            picker_lock: std::sync::Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    /// After a successful model switch: hoist the spec in the `/model`
    /// type-ahead (persisted), and refresh the config the line editor's
    /// argument suggestions read.
    /// `previous` is the spec switched away from. It was in use until now, so
    /// it is recorded too, just behind the new one: the model a session
    /// started with is offered as well, and `/model` then Enter switches back.
    fn model_switched(&mut self, agent: &Agent, previous: &str) {
        let (user, default_provider) = agent.config().effective_providers();
        let all = providers::effective_providers(&user);
        let previous = recents::canonical(previous, &all, &default_provider);
        let spec = recents::canonical(&agent.config().model, &all, &default_provider);
        {
            let mut recents = self.recents.lock().unwrap();
            recents.record(&previous);
            recents.record(&spec);
            recents::save(&self.recents_path, &recents);
        }
        self.sync_context(agent);
    }

    /// The recently used `provider/model` specs, most recent first.
    fn recent_models(&self) -> Vec<String> {
        self.recents.lock().unwrap().models().to_vec()
    }

    /// Refresh the config the line editor's argument suggestions read, after
    /// anything that may have changed it (`/settings`, a provider edit).
    fn sync_context(&mut self, agent: &Agent) {
        let context = self.view.lock().unwrap().context_handle();
        context.lock().unwrap().config = agent.config().clone();
    }

    /// Apply a live `renderer` switch from `/settings`: flip the app-owned
    /// frame renderer, match the line editor's drawing path (frame hook vs
    /// inline), re-anchor the status line / scroll region, and replay the
    /// transcript into the now-active renderer. No-op when the mode is
    /// unchanged. The transcript state is preserved across the flip, so the
    /// conversation is simply re-emitted into whichever renderer is active.
    fn renderer_switched(&mut self, agent: &mut Agent) {
        let mode = agent.config().renderer;
        if mode == self.renderer_before {
            return;
        }
        self.renderer_before = mode;
        let switching_to_frame = mode == crate::frame::RendererMode::Frame;
        // Leaving frame mode: the frame's full redraws cleared the legacy
        // scrollback, so the legacy transcript is gone — the conversation is
        // replayed below, once legacy owns the screen again. The interactive
        // prompt's current line is NOT in the conversation (it is recorded
        // only when submitted), so replaying every user message cannot
        // duplicate the line being edited.
        //
        // Entering frame mode: legacy output that exists only in renderer
        // state (deferred notes, the collapsed thinking summary) must move
        // into the frame transcript BEFORE the frame is activated — once it
        // is, `drain_pending` (a legacy-state accessor) returns empty, and
        // the frame's first full redraw clears the scrollback those notes
        // were headed for.
        let pending = if switching_to_frame { self.renderer.drain_pending() } else { Vec::new() };
        // Whether a frame is ACTIVE right now (before the switch). Off a tty
        // `set_mode(Frame)` leaves `is_frame()` false, so this — not the
        // configured mode — tells whether the post-switch replay/cleanup is
        // needed: with no frame ever active, legacy scrollback was never
        // cleared and replaying would print the whole conversation again.
        let frame_was_active = self.renderer.is_frame();
        self.renderer.set_mode(mode);
        let on = self.renderer.is_frame();
        // Rebuild the frame hook to match: frame routes every edit through the
        // single frame writer; legacy draws inline with its own command menu.
        let renderer = self.renderer.clone();
        let hook: Option<lineedit::EditHook> = on.then(|| {
            let h: lineedit::EditHook =
                std::sync::Arc::new(move |line: &str, cursor: usize, queued: usize, menu: &[String]| {
                    renderer.set_editor(line, cursor, queued, menu)
                });
            h
        });
        self.view.lock().unwrap().set_frame_mode(on, hook);
        // Leaving an active frame: re-own the screen for legacy BEFORE the
        // editor/status redraw below. The frame's last redraw is still
        // visible (dropping it emits nothing), so this clears the screen and
        // scrollback — the replay and the migrated frame-only items reprint
        // everything — then re-pins the scroll region the frame's redraws
        // reset, leaving the cursor on the last scrollable row. Doing it
        // before `view.resize()` (not after) means there is no fresh prompt
        // for the clear to wipe, and the replay can't start writing on the
        // reserved status row. When no status line is installed (a TTY with
        // `AGENTIC_NO_STATUS` or fewer than five rows) there is no region to
        // re-pin, but the frame's display must STILL be cleared — skipping it
        // would leave the replay writing over the stale frame copy.
        if !on && frame_was_active {
            match &self.status {
                Some(status) => status.repin_scroll_region(),
                None => crate::status::clear_display(),
            }
        }
        // Re-anchor the scroll region (legacy) / let the frame re-own the
        // screen (frame), and recompute the prompt at the current size.
        if let Some(status) = &self.status {
            status.resize();
        }
        if !on {
            // The frame left the cursor on the bottom row and the editor's
            // drawn state refers to rows the frame owned: reset it to the
            // single prompt row the next loop print establishes, or the
            // resize redraw would climb into the status row / frame content.
            self.view.lock().unwrap().reset_drawing();
        }
        // Leaving an ACTIVE frame, skip the editor's resize redraw: it would
        // reprint the inline prompt NOW, before `replay_transcript` below
        // restores the history — the renderer still counts itself at a line
        // start, so the first restored item lands after that prompt and the
        // next loop print draws a second one. `reset_drawing` above already
        // re-anchored the editor to the single prompt row, so replaying first
        // and letting the next loop print the prompt keeps it where it
        // belongs. Every other path (entering frame mode, or legacy with no
        // frame ever active) still needs the redraw to recompute the prompt at
        // the current size.
        if on || !frame_was_active {
            self.view.lock().unwrap().resize();
        }
        if on {
            // A fresh frame starts empty, so the transcript must be rebuilt
            // into it (its first full redraw clears scrollback and re-owns the
            // screen). Seed the drained legacy output first so it lands ahead
            // of the conversation, then replay the conversation as one batch:
            // rendering per event would redo the whole transcript layout each
            // time (O(events²) on a long session).
            self.renderer.push_items(pending);
            let renderer = self.renderer.clone();
            self.renderer.frame_batch(|| agent.replay_history_with(|event| renderer.replay_event(event)));
        } else if frame_was_active {
            // Legacy scrollback was cleared by the frame's redraws: reprint
            // the conversation so older turns stay accessible. The tap prints
            // only the user turns (the sink's legacy `Renderer::event` renders
            // everything else and ignores replayed user messages). First flush
            // the frame-only items `set_mode` migrated (banner, `/help`,
            // notes, raw exports): a fresh session has no history events to
            // trigger `out()`'s deferred flush and the next prompt is drawn by
            // `EditView`, so without this they would stay invisible until the
            // first turn's output. Then reprint the plan snapshots the frame
            // accumulated: the replay emits only the CURRENT plan (once, at
            // the end), so without them the earlier checklist states the frame
            // showed would be lost. `replay_plan_snapshots` skips the last
            // snapshot when it is the plan the replay just printed.
            self.renderer.flush_pending();
            let plans = self.renderer.take_pending_plans();
            let renderer = self.renderer.clone();
            agent.replay_history_with(|event| renderer.replay_event(event));
            self.renderer.replay_plan_snapshots(plans, agent.current_plan());
        }
    }

    /// Make the stdin reader yield the terminal so a foreground picker can own
    /// it; returns a generation-stamped [`InputGate`] the caller (or an orphaned
    /// auto-answer worker) releases once the picker is truly done. The stamp
    /// ensures a stale worker cannot resume the reader out from under a newer
    /// prompt that has since re-suspended input.
    fn suspend_input(&self) -> InputGate {
        use std::sync::atomic::Ordering::SeqCst;
        let token = self.suspend_gen.fetch_add(1, SeqCst) + 1;
        self.suspend.store(true, SeqCst);
        InputGate { flag: self.suspend.clone(), generation: self.suspend_gen.clone(), token }
    }

    /// A clone of the picker serialisation lock (see the field docs).
    fn picker_lock(&self) -> std::sync::Arc<tokio::sync::Mutex<()>> {
        self.picker_lock.clone()
    }

    fn request_line(&mut self) {
        if !self.outstanding {
            self.outstanding = self.want.send(()).is_ok();
        }
    }

    /// The next prompt input at the top-level loop. Deferred terminal input
    /// (piped lines, commands typed mid-turn) comes first, then one queued
    /// message — and a queued message is handed over only while the agent is
    /// not waiting for input: a pending `question`/turn-cap picker owns the
    /// terminal, and injecting a queued message there would answer a question
    /// the user can see with a prompt they may already have edited or
    /// removed. With nothing waiting this reads the terminal.
    async fn next(&mut self, agent: &Agent) -> TermInput {
        if let Some(input) = self.queued.pop_front() {
            return input;
        }
        if !self.messages.is_empty() && agent.questions().pending().is_none() {
            let entry = self.messages.pop().expect("checked non-empty");
            self.set_queue_status();
            self.renderer.note(&format!("↧ queued #{}: {}", entry.id, entry.text.trim()));
            return TermInput::Line(entry.text);
        }
        self.request_line();
        self.recv().await
    }

    /// Queue a message typed mid-turn; returns its id.
    fn queue_message(&mut self, text: &str) -> usize {
        let id = self.messages.push(text);
        self.set_queue_status();
        id
    }

    /// Apply a `/queue` edit (`remove`/`edit`/`clear`) and say what happened.
    fn edit_queue(&mut self, op: &queue::QueueOp) -> String {
        let result = queue::apply(&mut self.messages, op);
        self.set_queue_status();
        result
    }

    /// Keep the status line's queue count in sync (None hides the segment).
    fn set_queue_status(&self) {
        let count = self.messages.len();
        self.view.lock().unwrap().set_queue_count((count > 0).then_some(count));
    }

    async fn recv(&mut self) -> TermInput {
        let input = self.events.recv().await.unwrap_or(TermInput::Eof);
        // These are mid-line events delivered from *inside* an active
        // `read_line` (via its `send` callback): the reader keeps running and
        // still owns the outstanding read, so they must not clear `outstanding`
        // or the next `request_line` would queue a second concurrent reader
        // that could race a dialoguer picker for stdin. CycleMode (Shift+Tab)
        // is emitted the same way and belongs in this set.
        if !matches!(input, TermInput::Interrupt | TermInput::ToggleThinking | TermInput::Escape | TermInput::CycleMode)
        {
            self.outstanding = false;
        }
        input
    }
}

/// Run a turn. A line sent with Enter steers it (the agent reads it at its
/// next step); Ctrl/Cmd-Enter or `/queue add` queues it instead (one queued
/// message runs per following turn). `/queue` edits apply immediately, and
/// Ctrl-C or Esc Esc cancels.
async fn run_interactive_turn(agent: &mut Agent, text: &str, terminal: &mut Terminal) -> Result<agent::TurnOutcome> {
    let control = agent.control();
    let stats = agent.context_stats();
    let renderer = terminal.renderer.clone();
    if terminal.steerable && ui::verbosity() >= ui::Verbosity::Verbose {
        renderer.note("[running: Enter sends a message to steer the agent, Ctrl-Enter queues it for later (/queue lists, edits, removes), Esc Esc or Ctrl-C to cancel, Ctrl-O to expand thinking]");
    }
    // Blank line after LLM output (legacy renderer only; the frame renderer
    // owns the screen and must not receive stray direct writes).
    if !renderer.is_frame() {
        println!();
    }
    renderer.begin_turn();
    terminal.view.lock().unwrap().set_mode(lineedit::EditMode::Turn);
    let mut escape = DoubleEscape::default();
    let outcome = async {
        // Grab the broker before the turn future borrows `agent` mutably.
        let questions = agent.questions();
        let turn = agent.run_turn(None, text);
        tokio::pin!(turn);
        let mut question_rx = questions.subscribe();
        let cap = questions.cap();
        let mut cap_rx = cap.subscribe();
        loop {
            if !terminal.queued.iter().any(|i| matches!(i, TermInput::Eof)) {
                terminal.request_line();
            }
            tokio::select! {
                // Poll the turn first: its first poll resets the control, which
                // must happen before a buffered cancel or steer is routed to it.
                biased;
                outcome = &mut turn => break outcome,
                // A `question` tool call is waiting for an answer. The handler
                // is parked on the blocking pool; answer it here, where we own
                // the terminal. While this picker is up the turn future cannot
                // resolve, so the message queue is not drained: no queued
                // message is injected as a prompt while the agent is asking
                // for input (and `Terminal::next` re-checks before draining).
                notified = question_rx.changed() => {
                    if notified.is_err() {
                        // Broker dropped (agent gone): nothing more to answer.
                        continue;
                    }
                    if let Some(request) = questions.pending() {
                        // Yield stdin to the picker so the line reader does not
                        // race it for the answer keystrokes.
                        let gate = terminal.suspend_input();
                        // `prompt_question` owns the gate: it clears it while
                        // holding the picker lock — immediately, or once a
                        // timed-out auto-answer worker frees stdin — so the
                        // reader never resumes while a dialoguer is still active.
                        let answer = prompt_question(request.questions(), &control, &renderer, terminal.picker_lock(), gate).await;
                        questions.resolve(answer);
                        // The picker wrote over the owned frame via dialoguer;
                        // force a full redraw so the next differential render
                        // isn't computed against stale screen coordinates. If an
                        // auto-away worker was orphaned it is still parked on
                        // stdin holding the picker lock, so defer the repaint
                        // behind that lock: never write the frame while a
                        // dialoguer still owns the terminal (single-writer).
                        deferred_frame_resize(&renderer, terminal.picker_lock());
                    }
                }
                // The turn hit the cap in normal mode: ask whether to continue.
                notified = cap_rx.changed() => {
                    if notified.is_err() {
                        continue;
                    }
                    let gate = terminal.suspend_input();
                    let decision = prompt_cap_reached(&renderer, terminal.picker_lock(), gate).await;
                    cap.decide(decision);
                    // Repaint after the dialoguer picker clobbered the frame,
                    // deferred behind the picker lock so it never races an
                    // orphaned worker still parked on stdin (see above).
                    deferred_frame_resize(&renderer, terminal.picker_lock());
                }
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
                    TermInput::CycleMode => {
                        // `control` is a shared handle, so this works while the
                        // turn future holds a `&mut` borrow of the agent.
                        let mode = control.cycle_mode();
                        // `Agent::set_mode` (used between turns) also refreshes
                        // the shared stats; do the equivalent here so the status
                        // line reflects the new mode immediately, mid-turn.
                        stats.lock().unwrap().mode = mode;
                        renderer.event(&agent::AgentEvent::Context);
                        renderer.note(&format!("[mode: {mode} — {}]", mode.describe()));
                    }
                    // A blank Enter typed mid-turn is a no-op: dropping it here
                    // stops it from being deferred into `queued` and replayed
                    // as an empty line after the turn, which would delay the
                    // real queued messages/commands behind it.
                    TermInput::Line(line) | TermInput::Queue(line) if terminal.steerable && line.trim().is_empty() => {}
                    input @ (TermInput::Line(_) | TermInput::Queue(_)) if terminal.steerable => {
                        let (line, steer) = match input {
                            TermInput::Line(line) => (line, true),
                            TermInput::Queue(line) => (line, false),
                            _ => unreachable!(),
                        };
                        let text = line.trim();
                        match classify_steer_input(text, steer) {
                            SteerRoute::QueueCommand(op) => {
                                // `/queue` only touches the message queue, so it is
                                // safe — and most useful — while a turn is running.
                                match op {
                                    Ok(op) => renderer.note(&terminal.edit_queue(&op)),
                                    Err(usage) => renderer.note(&format!("[{usage}]")),
                                }
                            }
                            SteerRoute::DeferCommand => {
                                renderer.note(&format!("[commands wait for the turn to finish: {text}]"));
                                terminal.queued.push_back(TermInput::Line(line));
                            }
                            SteerRoute::Steer => {
                                // The agent adds it to the conversation before its
                                // next model call; if the turn ends first it is
                                // queued (see below).
                                control.steer(text, None);
                                // The frame renderer shows the steer as a user
                                // message once absorbed; the legacy one shows only
                                // this note, so it carries the text.
                                if renderer.is_frame() {
                                    renderer.note("↪ steering: the agent reads this at its next step (Ctrl-Enter queues instead)");
                                } else {
                                    renderer.note(&format!("↪ steer: {text} — read at the agent's next step (Ctrl-Enter queues instead)"));
                                }
                            }
                            SteerRoute::Enqueue => {
                                let id = terminal.queue_message(text);
                                let n = terminal.messages.len();
                                renderer.note(&format!("↧ queued #{id} ({n} waiting) — /queue remove {id} to drop"));
                            }
                            SteerRoute::Ignore => {}
                        }
                    }
                    other => terminal.queued.push_back(other),
                },
            }
        }
    }
    .await;
    renderer.end_turn();
    terminal.view.lock().unwrap().set_mode(lineedit::EditMode::Prompt);
    // A steer typed as the turn finished queues behind what is already
    // waiting, unless the turn was cancelled. Drain it before propagating any
    // turn error too: `start_turn` does not clear pending steers, so a steer
    // left behind on the error path would be silently absorbed into the next
    // unrelated prompt instead of landing in the visible queue. Only a
    // successful cancelled outcome drops it.
    let cancelled = matches!(&outcome, Ok(o) if o.stop_reason == agent::StopReason::Cancelled);
    for steer in control.take_pending() {
        if cancelled {
            renderer.note(&format!("[steer dropped: {}]", steer.text));
        } else {
            terminal.queue_message(&steer.text);
        }
    }
    outcome
}

/// How long auto mode waits for the user before answering a question itself.
const AUTO_AWAY_SECS: u64 = 15;

/// Render one question and return its answer string, `None` when dismissed.
/// Strip terminal control characters from model-controlled text before it is
/// handed to dialoguer for rendering. `q.question`, option labels and
/// descriptions all originate from the model, so a prompt-injected model could
/// otherwise smuggle ANSI/OSC escape sequences (cursor moves, screen clears,
/// clipboard/title writes) through the interactive picker. Dropping C0/C1
/// control characters — including ESC (0x1B), which begins every such sequence —
/// neutralises them while leaving ordinary printable text intact.
///
/// Line feeds (`\n`) are kept: a line feed is not an escape-initiating or
/// cursor-moving control, and dropping it would corrupt multi-line text.
/// Callers that render a single line (option labels, the prompt) hand
/// single-line strings to begin with; the transcript replay in particular
/// relies on `\n` surviving so a multi-line message replays as the same lines
/// the frame showed, not one concatenated line.
///
/// The Unicode line/paragraph separators U+2028/U+2029 are dropped too: they are
/// not `char::is_control`, but terminals and this crate's own memory guards
/// (`memory::is_line_break`) fold them as line breaks, so a hand-edited value
/// could otherwise smuggle a forged extra line (e.g. a fake `/memory` row) past
/// the filter.
pub(crate) fn sanitize_terminal_text(s: &str) -> String {
    s.chars()
        .filter(|c| (!c.is_control() || *c == '\n') && *c != '\u{2028}' && *c != '\u{2029}')
        .collect()
}

fn ask_one(q: &question::Question) -> Result<Option<String>> {
    use dialoguer::{Input, Select};
    let mut labels: Vec<String> = q
        .options
        .iter()
        .map(|o| {
            let label = sanitize_terminal_text(&o.label);
            if o.description.is_empty() {
                label
            } else {
                format!("{} — {}", label, sanitize_terminal_text(&o.description))
            }
        })
        .collect();
    let custom_index = if q.custom {
        labels.push("Type your own answer".into());
        Some(labels.len() - 1)
    } else {
        None
    };
    let choice =
        Select::new().with_prompt(sanitize_terminal_text(&q.question)).items(&labels).default(0).interact_opt()?;
    match choice {
        None => Ok(None),
        Some(i) if Some(i) == custom_index => {
            let text: String = Input::new().with_prompt("Answer").interact_text()?;
            Ok(Some(text))
        }
        Some(i) => Ok(Some(q.options[i].label.clone())),
    }
}

/// Force a full frame redraw, but only once the picker lock is free.
///
/// A foreground dialoguer picker owns the terminal while it runs, and an
/// auto-away `prompt_question` can return `Away` while its `spawn_blocking`
/// worker is still parked on stdin holding the picker lock. Repainting the
/// owned frame immediately would write it while that orphaned worker still
/// owns the terminal, violating the single-writer assumption and letting the
/// two tear each other's output. Awaiting the picker lock first defers the
/// repaint until every picker (orphaned or not) has released the terminal; in
/// the common case the lock is already free, so the redraw runs at once.
/// Spawned so the turn loop is never blocked waiting on an away user.
fn deferred_frame_resize(renderer: &std::sync::Arc<ui::Renderer>, picker_lock: std::sync::Arc<tokio::sync::Mutex<()>>) {
    let renderer = renderer.clone();
    tokio::spawn(async move {
        let _guard = picker_lock.lock_owned().await;
        renderer.frame_resize();
    });
}

/// Render a pending `question` and return the answer, plus an optional handle
/// to a still-running auto-answer worker. In auto mode the user gets
/// `AUTO_AWAY_SECS` to respond before the question is answered with the away
/// message; a `spawn_blocking` dialoguer worker cannot be aborted, so when the
/// timeout fires the worker is handed back (still parked on stdin) for the
/// caller to await before it resumes the line reader — the two must never read
/// keystrokes at once. Runs on the turn loop, which owns the terminal.
async fn prompt_question(
    questions: &[question::Question],
    control: &agent::TurnControl,
    renderer: &std::sync::Arc<ui::Renderer>,
    picker_lock: std::sync::Arc<tokio::sync::Mutex<()>>,
    gate: InputGate,
) -> question::QuestionAnswer {
    use question::QuestionAnswer;
    let auto = control.mode() == mode::AgentMode::Auto;

    // The whole prompt run: ask each question, collecting one string each.
    // Dismissal (Esc) at any question dismisses the lot.
    let ask = |questions: &[question::Question]| -> Result<QuestionAnswer> {
        let mut answers = Vec::new();
        for q in questions {
            match ask_one(q)? {
                Some(answer) => answers.push(answer),
                None => return Ok(QuestionAnswer::Dismissed),
            }
        }
        Ok(QuestionAnswer::Answers(answers))
    };

    if !auto {
        // Normal mode: the user is present, so it is fine to block until any
        // previous (possibly orphaned) worker releases stdin, so only one ever
        // reads keystrokes.
        let guard = picker_lock.lock_owned().await;
        let questions = questions.to_vec();
        let asked = tokio::task::spawn_blocking(move || ask(&questions)).await;
        // Release the gate while still holding the picker guard, so the input
        // reader cannot resume before the next picker (which must take this
        // same lock) has re-suspended it. `release()` is generation-aware, so
        // it is a no-op if a newer prompt has already re-suspended input.
        gate.release();
        drop(guard);
        return asked.ok().and_then(Result::ok).unwrap_or(QuestionAnswer::Dismissed);
    }

    // Auto mode: give the user a chance to answer, then answer ourselves.
    renderer.note(&format!("[auto: answering for you in {AUTO_AWAY_SECS}s — the user is away]"));
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(AUTO_AWAY_SECS);

    // Acquire stdin, but never past the away deadline. If a prior orphaned
    // worker still holds the picker lock while the user is away, blocking here
    // would keep this question from ever resolving (finding: later questions
    // wait on the lock before their own timeout can start). Bound the wait so
    // it still answers `Away`, and serialise so only one worker reads stdin.
    let guard = match tokio::time::timeout_at(deadline, picker_lock.clone().lock_owned()).await {
        Ok(guard) => guard,
        Err(_) => {
            renderer.note("[auto: no answer — making the best decision]");
            // Do not start a competing reader. Keep the caller's input gate
            // suspended until the picker frees (the prior orphan exits), then
            // release the gate while still holding the guard, so a later picker
            // cannot acquire the lock and re-suspend between our lock release
            // and the gate release (which would let the reader race stdin).
            tokio::spawn(async move {
                let guard = picker_lock.lock_owned().await;
                gate.release();
                drop(guard);
            });
            return QuestionAnswer::Away;
        }
    };

    let questions = questions.to_vec();
    let mut worker = tokio::task::spawn_blocking(move || ask(&questions));
    tokio::select! {
        joined = &mut worker => {
            // Release the gate while still holding the guard, then drop it.
            gate.release();
            drop(guard);
            joined.ok().and_then(Result::ok).unwrap_or(QuestionAnswer::Dismissed)
        }
        () = tokio::time::sleep_until(deadline) => {
            renderer.note("[auto: no answer — making the best decision]");
            // Keep the worker alive (it is still blocked on stdin) and hold the
            // picker lock until it exits. Release the gate while still holding
            // the guard so the reader resumes only once this worker exits, with
            // no window for a later picker to slip in between lock and gate
            // release.
            tokio::spawn(async move {
                let _ = worker.await;
                gate.release();
                drop(guard);
            });
            QuestionAnswer::Away
        }
    }
}

/// Ask whether to keep going when the turn cap is reached. Defaults to stop,
/// so an unattended prompt does not run away. Runs on the turn loop.
async fn prompt_cap_reached(
    renderer: &std::sync::Arc<ui::Renderer>,
    picker_lock: std::sync::Arc<tokio::sync::Mutex<()>>,
    gate: InputGate,
) -> question::CapDecision {
    use question::CapDecision;
    // Serialise with the question picker: this is another dialoguer reader, so
    // never run it while an orphaned auto-away worker still holds stdin. Block
    // until that worker releases the lock so only one ever reads keystrokes.
    let guard = picker_lock.lock_owned().await;
    let renderer = renderer.clone();
    let decision = tokio::task::spawn_blocking(move || {
        let keep_going = dialoguer::Confirm::new()
            .with_prompt("Reached the turn cap without a final answer. Keep going?")
            .default(false)
            .interact_opt()
            .ok()
            .flatten()
            .unwrap_or(false);
        if keep_going {
            renderer.note("[continuing past the turn cap]");
            CapDecision::Continue
        } else {
            CapDecision::Stop
        }
    })
    .await
    .unwrap_or(CapDecision::Stop);
    // Release the gate while still holding the guard, so the input reader cannot
    // resume before the next picker re-suspends it (generation-aware: a no-op if
    // a newer prompt already re-suspended input).
    gate.release();
    drop(guard);
    decision
}

/// The `/queue` edit a line asks for, if it is a `/queue` command. Unlike
/// other commands, `/queue` only touches the message queue, so it runs even
/// while a turn or compaction is in flight — that is when queue edits
/// (removals included) are most useful.
fn queue_command(text: &str) -> Option<std::result::Result<queue::QueueOp, String>> {
    let args = match text.strip_prefix("/queue") {
        Some(args) if args.is_empty() || args.starts_with(char::is_whitespace) => args,
        _ => return None,
    };
    Some(queue::parse(args))
}

/// The routing decision for a line typed mid-turn, factored out of the live
/// `select!` loop so the steer/queue/command split can be unit-tested without
/// a running turn. `text` is already trimmed; `steer` is true for a plain
/// Enter (`TermInput::Line`) and false for Ctrl-Enter (`TermInput::Queue`).
enum SteerRoute {
    /// Blank input: dropped as a no-op.
    Ignore,
    /// A `/queue` edit — applied to the message queue even mid-turn.
    QueueCommand(std::result::Result<queue::QueueOp, String>),
    /// A non-`/queue` slash command: deferred until the turn finishes.
    DeferCommand,
    /// Plain Enter: steer the running turn.
    Steer,
    /// Ctrl-Enter: append to the message queue for a later turn.
    Enqueue,
}

/// Classify a mid-turn line into its routing action. Order matters: `/queue`
/// edits run live, other slash commands defer, and otherwise the Enter vs
/// Ctrl-Enter distinction decides steer vs enqueue.
fn classify_steer_input(text: &str, steer: bool) -> SteerRoute {
    if text.is_empty() {
        SteerRoute::Ignore
    } else if let Some(op) = queue_command(text) {
        SteerRoute::QueueCommand(op)
    } else if text.starts_with('/') {
        SteerRoute::DeferCommand
    } else if steer {
        SteerRoute::Steer
    } else {
        SteerRoute::Enqueue
    }
}

/// Whether `/trajectory` / `--trajectory` should open a pager: both ends are
/// a terminal and the ledger doesn't fit on one screen.
fn trajectory_pageable(traj: &trajectory::Trajectory) -> bool {
    io::stdin().is_terminal()
        && io::stdout().is_terminal()
        && status::terminal_size()
            .is_some_and(|(rows, cols)| trajectory::needs_pager(&traj.to_plain(), rows as usize, cols as usize))
}

/// Emit a transient diagnostic: through the frame transcript in frame mode (a
/// direct write would corrupt the owned frame), else to stderr as before.
fn diag(renderer: &ui::Renderer, text: &str) {
    if renderer.is_frame() {
        renderer.note(text);
    } else {
        eprintln!("{text}");
    }
}

/// Run an explicit compaction; Ctrl-C or Esc Esc cancels it.
async fn run_compaction(
    agent: &mut Agent,
    mode: Option<config::CompactionMode>,
    instructions: Option<&str>,
    terminal: &mut Terminal,
) -> Result<Option<agent::CompactReport>> {
    let control = agent.control();
    let stats = agent.context_stats();
    let compaction = agent.compact(mode, instructions);
    tokio::pin!(compaction);
    let mut escape = DoubleEscape::default();
    loop {
        tokio::select! {
            biased;
            report = &mut compaction => return report,
            input = terminal.recv() => match input {
                TermInput::Interrupt => {
                    control.cancel();
                    diag(&terminal.renderer, "[cancelling...]");
                }
                TermInput::Escape if control.is_cancelled() => {}
                TermInput::Escape => {
                    if escape.press(std::time::Instant::now()) {
                        control.cancel();
                        diag(&terminal.renderer, "[cancelling...]");
                    } else {
                        diag(&terminal.renderer, "[Esc again to cancel]");
                    }
                }
                TermInput::ToggleThinking => {
                    terminal.renderer.toggle_thinking();
                }
                TermInput::CycleMode => {
                    let mode = control.cycle_mode();
                    // Mirror the prompt/turn `CycleMode` path: refresh the
                    // shared stats and emit a context event so the status line
                    // reflects the new mode immediately, not just after a later
                    // refresh while `/compact` is still running.
                    stats.lock().unwrap().mode = mode;
                    terminal.renderer.event(&agent::AgentEvent::Context);
                    diag(&terminal.renderer, &format!("[mode: {mode} — {}]", mode.describe()));
                }
                other => {
                    // `/queue` edits apply mid-compaction too; everything else
                    // waits for the loop to pick it up afterwards.
                    if let TermInput::Line(line) = &other
                        && let Some(op) = queue_command(line.trim())
                    {
                        match op {
                            Ok(op) => {
                                let result = terminal.edit_queue(&op);
                                terminal.renderer.note(&result);
                            }
                            Err(usage) => terminal.renderer.note(&format!("[{usage}]")),
                        }
                    } else {
                        terminal.queued.push_back(other);
                    }
                }
            },
        }
    }
}

/// Parse the id from `/memory forget <id>` args, requiring a token boundary
/// after `forget`: the next character must be whitespace (or end of args).
/// Without it, `/memory forgetmem-…` would strip the `forget` prefix and treat
/// `mem-…` as an id, deleting an entry instead of reporting an unknown command
/// (Copilot finding, src/main.rs). Returns `None` when `args` is not a
/// `forget` request at all, so the caller falls through to the
/// unknown-argument branch.
fn parse_forget_id(args: &str) -> Option<&str> {
    let rest = args.strip_prefix("forget")?;
    if rest.is_empty() || rest.starts_with(char::is_whitespace) { Some(rest.trim()) } else { None }
}

/// `/memory` (list) and `/memory forget <id>`.
fn memory_command(agent: &mut Agent, args: &str) -> String {
    if agent.memory().is_none() {
        // `memory()` is `None` for two distinct reasons: memory is genuinely
        // off, or it is *enabled* but no per-user data directory is available
        // and no `memory_dir` was configured (`memory_dir()` refuses the
        // world-shared temp fallback). Telling the latter user to "set
        // `memory = \"on\"`" is wrong — it already is — and leaves them unable
        // to diagnose the real problem, so direct that case to `memory_dir`
        // instead (Copilot finding, src/main.rs).
        if agent.config().memory.enabled() {
            return "Memory is enabled but no storage directory is available: this platform has \
                    no per-user data directory and none was configured. Set `memory_dir` in \
                    config to a directory you control."
                .to_string();
        }
        return "Memory is off (set `memory = \"on\"` in config to enable it).".to_string();
    }
    if let Some(id) = parse_forget_id(args) {
        if id.is_empty() {
            return "Usage: /memory forget <id>".to_string();
        }
        // Plan mode is read-only: the tool path already refuses `memory_forget`
        // (the dispatch backstop in `run_memory_tool`), but this slash command
        // reaches `Store::forget` directly and would otherwise delete the
        // persistent scope file mid-plan, bypassing the no-modification
        // guarantee. Gate it on the live mode the same way (Copilot finding,
        // src/main.rs).
        if agent.mode() == crate::mode::AgentMode::Plan {
            return "Memory is read-only in plan mode; /memory forget cannot delete entries.".to_string();
        }
        if !agent.config().memory.writable() {
            return "Memory is read-only in this session; /memory forget cannot delete entries.".to_string();
        }
        let (msg, ok) = match agent.memory().unwrap().forget(id) {
            Ok(msg) => (msg, true),
            Err(e) => (format!("{e}"), false),
        };
        // Rebuild the folded system prompt so the deleted memory stops appearing
        // in the active session's index (it is captured at session start).
        if ok {
            agent.refresh_memory_index();
        }
        return msg;
    }
    if !args.is_empty() {
        return format!("Unknown /memory argument {args:?}; use /memory or /memory forget <id>.");
    }
    let store = agent.memory().unwrap();
    let entries = match store.all() {
        Ok(entries) => entries,
        Err(e) => return format!("Could not read memory: {e}"),
    };
    if entries.is_empty() {
        // Branch on *effective* writability: in read-only mode (including
        // headless/ACP runs) *and in Plan mode* the `memory_save` tool is
        // unavailable, so pointing the user at it would describe an action the
        // model cannot take. `config().memory.writable()` alone stays `On` in
        // Plan mode, so use `memory_writable()`, which also gates on the live
        // mode (Copilot finding, src/main.rs).
        return if agent.memory_writable() {
            format!(
                "No memories yet. The model saves them with memory_save; files live under {}.",
                store.root().display()
            )
        } else {
            format!(
                "No memories yet. Memory is read-only here, so the model cannot save them; files live under {}.",
                store.root().display()
            )
        };
    }
    let mut out = vec![format!(
        "{} memor{} (memory is {}; edit the files under {}{}):",
        entries.len(),
        if entries.len() == 1 { "y" } else { "ies" },
        agent.config().memory.as_str(),
        store.root().display(),
        if agent.memory_writable() { ", or /memory forget <id>" } else { "" }
    )];
    for (scope, entry) in &entries {
        // Sanitise every interpolated field before it reaches the terminal: the
        // JSONL is documented as human-editable, so a record can carry `\r`, ESC,
        // or other control bytes that the legacy renderer would otherwise print
        // verbatim (`print_block` → `println!`), enabling terminal escape
        // sequences or forged list lines. `sanitize_terminal_text` drops C0/C1
        // control chars (including ESC and newlines) while keeping printable text.
        let mut line = format!(
            "  {} [{}] ({}) {}",
            scope.as_str(),
            sanitize_terminal_text(&entry.id),
            entry.created.format("%Y-%m-%d"),
            sanitize_terminal_text(entry.text.lines().next().unwrap_or("").trim())
        );
        if let Some(evidence) = &entry.evidence {
            line.push_str(&format!(" (check: {})", sanitize_terminal_text(evidence)));
        }
        out.push(line);
    }
    out.join("\n")
}

/// `/resume [ID|last]`: switch this process to a saved session. Without an
/// argument, pick one (or, without a terminal, list them).
fn resume_command(agent: &mut Agent, arg: &str, terminal: &mut Terminal) -> Result<()> {
    if terminal.outstanding {
        // A stdin read is pending (typed during a turn), so a picker would
        // race it, and switching sessions mid-turn would orphan the turn.
        terminal.renderer.print_block("/resume switches sessions: run it at the prompt once the turn is over");
        return Ok(());
    }
    if !agent.config().persist_sessions {
        terminal
            .renderer
            .print_block("Sessions aren't saved (persist_sessions = false), so there is nothing to resume");
        return Ok(());
    }
    let dir = agent.config().session_dir();
    let cwd = env::current_dir().map(|d| d.display().to_string()).unwrap_or_default();
    let current = agent.session_id().map(str::to_string);
    let id = match arg {
        "" if !io::stdin().is_terminal() || !io::stderr().is_terminal() => {
            let rows = resume::list_rows(&dir, &cwd, current.as_deref())?;
            let text = if rows.is_empty() {
                "No saved sessions for this directory".to_string()
            } else {
                format!("Saved sessions (switch with /resume ID):\n{}", rows.join("\n"))
            };
            terminal.renderer.print_block(&text);
            return Ok(());
        }
        "" => {
            let picked = resume::pick_outcome(&dir, &cwd, current.as_deref());
            // The picker drew over the owned frame: repaint it fully, also on error.
            terminal.renderer.frame_resize();
            match picked? {
                resume::Pick::Selected(id) => id,
                // The picker already printed "No saved sessions to resume." to
                // stderr. In frame mode the repaint above painted over it, so
                // repeat it where the user can see it; with the legacy renderer
                // frame_resize() is a no-op and the stderr notice is still on
                // screen, so printing again would duplicate it. Keep
                // "Session unchanged" for an actual Esc.
                resume::Pick::Empty => {
                    if terminal.renderer.is_frame() {
                        terminal.renderer.print_block("No saved sessions to resume");
                    }
                    return Ok(());
                }
                resume::Pick::Cancelled => {
                    terminal.renderer.print_block("Session unchanged");
                    return Ok(());
                }
            }
        }
        "last" => resume::last(&dir, &cwd, current.as_deref())?,
        id => id.to_string(),
    };
    if current.as_deref() == Some(id.as_str()) {
        terminal.renderer.print_block(&format!("Already in session {id}"));
        return Ok(());
    }
    if session::validate_id(&id).is_err() || !dir.join(format!("{id}.jsonl")).is_file() {
        terminal.renderer.print_block(&format!("No saved session {id:?}: /resume without an ID lists them"));
        return Ok(());
    }
    agent.load_session(&id)?;
    terminal.renderer.clear_screen();
    // As at startup with --resume: the frame renderer rebuilds the
    // transcript from the loaded conversation; the legacy one starts clean.
    if terminal.renderer.is_frame() {
        agent.replay_history();
    }
    terminal.renderer.print_block(&format!("Resumed session {id} (resume later with --resume {id})"));
    Ok(())
}

async fn run_command(agent: &mut Agent, cmd: &str, terminal: &mut Terminal) -> Result<bool> {
    match cmd {
        "/exit" | "/quit" => Ok(false),
        "/help" => {
            terminal.renderer.print_block(&commands::help_text());
            Ok(true)
        }
        _ if cmd == "/compact" || cmd.starts_with("/compact ") => {
            let (mode, focus) = commands::parse_compact_args(&cmd["/compact".len()..]);
            let focus = focus.map(str::to_string);
            terminal.renderer.print_block("Compacting...");
            match run_compaction(agent, mode, focus.as_deref(), terminal).await? {
                Some(report) => terminal.renderer.print_block(&format!("Conversation {report}")),
                None => terminal.renderer.print_block("Nothing to compact"),
            }
            Ok(true)
        }
        "/context" => {
            let stats = agent.context_stats().lock().unwrap().clone();
            let mut out: Vec<String> = Vec::new();
            out.push(format!("Model:        {}/{}", stats.provider, stats.model));
            out.push(format!("Temperature:  {}", agent.temperature().describe()));
            out.push(format!(
                "Context:      {}{} of {} tokens ({:.1}%){}",
                if stats.calibrated { "" } else { "~" },
                stats.tokens,
                stats.window,
                stats.percent(),
                if stats.calibrated { ", anchored to reported usage" } else { ", estimated" }
            ));
            out.push(format!("Messages:     {}", stats.messages));
            let system_tokens = crate::context::text_tokens(&agent.system_prompt());
            out.push(format!("System prompt: {} tokens", system_tokens));
            let files = agent.project_instruction_files();
            if files.is_empty() {
                out.push(
                    "Instructions: none (no AGENTS.md, CLAUDE.md or .github/copilot-instructions.md found)".to_string(),
                );
            } else {
                out.push(format!("Instructions: {}", files.join(", ")));
            }
            let skills = agent.skills();
            if !skills.is_empty() || !skills.warnings.is_empty() {
                out.push(format!("Skills:       {} (/skills to list them)", skills.skills.len()));
            }
            if let Some((done, total)) = stats.plan {
                out.push(format!("Plan:         {done}/{total} done (/plan to show it)"));
            }
            out.push(format!(
                "Session:      {} input, {} output tokens",
                stats.session_input_tokens, stats.session_output_tokens
            ));
            if let Some(aic) = stats.session_aic {
                out.push(format!("AI Credits:   {aic:.2} used this session"));
            }
            match stats.auto_compact {
                Some(t) => out.push(format!(
                    "Auto-compact: at {:.0}% (~{} tokens); compacted {} time(s)",
                    t * 100.0,
                    (stats.window as f64 * t) as usize,
                    stats.compactions
                )),
                None => out.push("Auto-compact: off".to_string()),
            }
            out.push(format!(
                "Compaction:   {} mode (/compact --smart or --standard overrides once)",
                agent.config().compaction_mode.as_str()
            ));
            if stats.history_searches + stats.history_reads > 0 {
                out.push(format!(
                    "History:      {} search(es), {} read(s) this session",
                    stats.history_searches, stats.history_reads
                ));
            }
            out.push(format!("(context window {})", agent.context_window_with_source().1));
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        "/settings" if terminal.outstanding => {
            // Typed during a turn: a stdin read is still pending, so an
            // interactive editor would race it for keystrokes.
            let config = agent.config();
            terminal.renderer.print_block(&format!(
                "model: {}\ntemperature: {}\nmax_tokens: {}\n(read-only: run /settings again at the prompt to edit)",
                config.model,
                agent.temperature().describe(),
                config.max_tokens
            ));
            Ok(true)
        }
        "/settings" => {
            let renderer_before = agent.config().renderer;
            // Capture the dialog result rather than `?`-returning it: when the
            // user changed `renderer` and a LATER prompt errors or is
            // cancelled, the config already records the new mode, so the
            // switch must still be applied here — returning early would leave
            // the renderer and editor in the old mode with no diff left to
            // retrigger the switch on the next visit.
            let notices = settings::run(agent, &terminal.config_path, &terminal.recents, &terminal.recents_path).await;
            // The settings dialog (dialoguer) wrote directly over the owned
            // frame; force a full redraw so the frame renderer's next update
            // isn't diffed against stale screen coordinates.
            terminal.renderer.frame_resize();
            // A renderer switch in the settings dialog takes effect live: flip
            // the frame renderer, the line editor's drawing path, and the
            // scroll region, and replay the transcript into the new renderer.
            if agent.config().renderer != renderer_before {
                terminal.renderer_switched(agent);
            }
            // Re-show any notice the dialog retained (e.g. a client-rebuild
            // failure) THROUGH the renderer, now that the redraw has run. The
            // dialog does NOT print these itself (a plain `println!` would be
            // wiped by `frame_resize` in frame mode, and would double-print in
            // legacy); `print_block` captures the notice into the frame
            // transcript (or prints inline in legacy) so it is shown exactly
            // once. `run` returns the notices on EVERY exit — even a
            // cancel/error at a later prompt — so a rebuild failure already
            // recorded is never dropped.
            for notice in &notices {
                terminal.renderer.print_block(notice);
            }
            // Each model switch made in the dialog was recorded into the recents
            // MRU as it happened, so here just refresh the config the line
            // editor's argument suggestions read (providers or the model may
            // have changed).
            terminal.sync_context(agent);
            Ok(true)
        }
        "/tools" => {
            let mut out = vec!["Available tools:".to_string()];
            for def in agent.tool_definitions() {
                out.push(format!("  {} - {}", def.name, def.description));
            }
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        "/skills" => {
            let skills = agent.skills();
            let mut out: Vec<String> = Vec::new();
            if skills.is_empty() {
                out.push(format!(
                    "No skills found (looked in {}, ai.lock and {}).",
                    agent.config().skills.dirs.join(", "),
                    agent.config().skills.user_dirs.join(", ")
                ));
            }
            for skill in &skills.skills {
                out.push(format!("  {} - {}\n      {}", skill.name, skill.description, skill.dir.display()));
            }
            for warning in &skills.warnings {
                out.push(format!("Warning: {warning}"));
            }
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        "/plan" => {
            if agent.plan().is_empty() {
                terminal.renderer.print_block("No plan yet. The agent makes one with the plan_add tool.");
            } else {
                terminal.renderer.print_block(agent.plan().render(true, usize::MAX).trim_end());
            }
            Ok(true)
        }
        _ if cmd == "/memory" || cmd.starts_with("/memory ") => {
            terminal.renderer.print_block(&memory_command(agent, cmd.strip_prefix("/memory").unwrap_or("").trim()));
            Ok(true)
        }
        _ if let Some(op) = queue_command(cmd) => {
            // List is the read-only form; the edits (remove/edit/clear) were
            // already applied mid-turn when typed then, and apply here at the
            // prompt.
            match op {
                Ok(queue::QueueOp::List) => terminal.renderer.print_block(&queue::describe(&terminal.messages)),
                Ok(op) => {
                    let msg = terminal.edit_queue(&op);
                    terminal.renderer.print_block(&msg);
                }
                Err(usage) => terminal.renderer.print_block(&usage),
            }
            Ok(true)
        }
        "/model" if terminal.outstanding => {
            // Typed during a turn: a stdin read is still pending, so an
            // interactive picker would race it for keystrokes.
            terminal.renderer.print_block(&format!(
                "Model: {} (provider {}, spec {:?})\n(read-only: run /model again at the prompt to switch)",
                agent.model_name(),
                agent.provider_name(),
                agent.config().model
            ));
            Ok(true)
        }
        "/model" if !io::stdin().is_terminal() || !io::stderr().is_terminal() => {
            // The picker reads keystrokes from stdin and draws on stderr, so it
            // needs both to be terminals; piped input/output just gets the
            // current model.
            terminal.renderer.print_block(&format!(
                "Model: {} (provider {}, spec {:?})",
                agent.model_name(),
                agent.provider_name(),
                agent.config().model
            ));
            Ok(true)
        }
        "/model" => {
            // Capture the model actually in use (resolved by the live
            // client) before switching, so a provider-default edit made in the
            // same session cannot rewrite which model we record leaving.
            let before = format!("{}/{}", agent.provider_name(), agent.model_name());
            let recent = terminal.recent_models();
            let picked = settings::pick_model_interactive(agent, &recent).await;
            // The picker (dialoguer) wrote directly over the owned frame; force
            // a full redraw so the next differential render isn't diffed against
            // stale screen coordinates. Do it before propagating any error so
            // the frame is repaired on the error path too.
            terminal.renderer.frame_resize();
            if let Some(spec) = picked? {
                agent.set_model(&spec).await?;
                terminal.model_switched(agent, &before);
                terminal.renderer.print_block(&model_set_text(agent));
            } else {
                terminal.renderer.print_block(&format!(
                    "Model unchanged: {} (provider {})",
                    agent.model_name(),
                    agent.provider_name()
                ));
            }
            Ok(true)
        }
        _ if cmd.starts_with("/model ") => {
            // Capture the model actually in use (resolved by the live
            // client) before switching, so a provider-default edit made in the
            // same session cannot rewrite which model we record leaving.
            let before = format!("{}/{}", agent.provider_name(), agent.model_name());
            agent.set_model(cmd["/model ".len()..].trim()).await?;
            terminal.model_switched(agent, &before);
            terminal.renderer.print_block(&model_set_text(agent));
            Ok(true)
        }
        "/providers" => {
            let (user, default_provider) = agent.config().effective_providers();
            let mut out = vec![format!("Providers (default: {default_provider}):")];
            for (name, provider) in providers::effective_providers(&user) {
                let kind = provider.kind.map(|k| format!("{k:?}").to_lowercase()).unwrap_or_else(|| "?".into());
                let key = settings::key_status(&provider);
                let url = provider.base_url.unwrap_or_else(|| match provider.kind {
                    Some(providers::ProviderKind::GithubCopilot) => "(from session token)".into(),
                    _ => "-".into(),
                });
                out.push(format!("  {name:<14} {kind:<14} {url:<55} {key}"));
            }
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        "/session" => {
            match (agent.session_id(), agent.session_path()) {
                (Some(id), Some(path)) => terminal.renderer.print_block(&format!("Session {id}: {}", path.display())),
                _ => terminal.renderer.print_block("Session persistence is disabled"),
            }
            Ok(true)
        }
        _ if cmd == "/trajectory" || cmd.starts_with("/trajectory ") => {
            let arg = cmd["/trajectory".len()..].trim();
            let Some(path) = agent.session_path() else {
                terminal.renderer.print_block("Session persistence is disabled: no trajectory to show");
                return Ok(true);
            };
            let records = match session::read_records_at(path, None) {
                Ok(records) => records,
                Err(e) => {
                    terminal.renderer.print_block(&format!("Could not read the session log: {e:#}"));
                    return Ok(true);
                }
            };
            let traj = trajectory::Trajectory::from_records(&records);
            match arg {
                // Export modes bypass the transcript renderer (`print_raw`, not
                // `print_block`): the frame would wrap long lines and prefix a
                // timestamp, making the JSON unparseable and mangling Markdown.
                "--json" => terminal.renderer.print_raw(&traj.to_json()),
                "--markdown" | "--md" => terminal.renderer.print_raw(&traj.to_markdown()),
                "" if !terminal.outstanding && terminal.renderer.is_frame() && trajectory_pageable(&traj) => {
                    // The pager owns the screen until it exits; force a full
                    // redraw so the frame renderer's next differential render
                    // isn't diffed against what the pager left (as /settings
                    // does). Typed during a turn, a stdin read is still pending
                    // and would race the pager for keys, so print instead; the
                    // legacy renderer's status line pins a scroll region a
                    // full-screen pager would disturb, so it prints too.
                    let text = traj.to_plain();
                    let paged = trajectory::page(&text);
                    terminal.renderer.frame_resize();
                    if !paged {
                        terminal.renderer.print_block(&text);
                    }
                }
                "" => terminal.renderer.print_block(&traj.to_plain()),
                other => terminal
                    .renderer
                    .print_block(&format!("Unknown option {other:?}; use /trajectory [--json|--markdown]")),
            }
            Ok(true)
        }
        _ if cmd == "/resume" || cmd.starts_with("/resume ") => {
            resume_command(agent, cmd["/resume".len()..].trim(), terminal)?;
            Ok(true)
        }
        "/restart" => {
            // Start a brand-new session in place: new ID, context reset to
            // just the system prompt, empty plan, counters zeroed. The
            // previous session log stays on disk and is still resumable.
            let id = agent.new_session()?;
            terminal.renderer.clear_screen();
            if agent.session_path().is_some() {
                terminal.renderer.print_block(&format!("Session: {id} (resume with --resume {id})"));
            } else {
                terminal.renderer.print_block(&format!("Session: {id}"));
            }
            Ok(true)
        }
        "/verbosity" => {
            let current = ui::verbosity();
            let mut out = vec![format!("Verbosity: {current} ({})", current.describe())];
            for level in ui::Verbosity::ALL {
                out.push(format!("  {:<8} {}", level.to_string(), level.describe()));
            }
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        "/mode" => {
            let current = agent.mode();
            let mut out = vec![format!("Mode: {current} ({})", current.describe())];
            for mode in mode::AgentMode::ALL {
                out.push(format!("  {:<8} {}", mode.to_string(), mode.describe()));
            }
            out.push("(Shift+Tab cycles; /mode NAME sets it directly)".to_string());
            terminal.renderer.print_block(&out.join("\n"));
            Ok(true)
        }
        _ if cmd.starts_with("/mode ") => {
            match cmd["/mode ".len()..].parse::<mode::AgentMode>() {
                Ok(m) => {
                    agent.set_mode(m);
                    terminal.renderer.print_block(&format!("Mode set to {m} ({})", m.describe()));
                }
                Err(e) => terminal.renderer.print_block(&e),
            }
            Ok(true)
        }
        _ if cmd.starts_with("/verbosity ") => {
            match cmd["/verbosity ".len()..].parse::<ui::Verbosity>() {
                Ok(level) => {
                    ui::set_verbosity(level);
                    agent.config_mut().verbosity = level;
                    terminal
                        .renderer
                        .print_block(&format!("Verbosity set to {level} ({}); /settings saves it", level.describe()));
                }
                Err(e) => terminal.renderer.print_block(&e),
            }
            Ok(true)
        }
        _ => {
            let outcome = run_interactive_turn(agent, cmd, terminal).await?;
            // In frame mode the turn's response is already rendered from its
            // events; re-printing it here would duplicate the answer and
            // corrupt the owned frame.
            if !terminal.renderer.is_frame() {
                if ui::verbosity() == ui::Verbosity::Quiet {
                    println!("{}", ui::stamp_block(&outcome.response));
                } else if outcome.stop_reason == agent::StopReason::Cancelled {
                    println!("{}", ui::stamp_block(&format!("\x1b[2m{}\x1b[0m", outcome.response)));
                } else if outcome.stop_reason == agent::StopReason::MaxTurnRequests {
                    let last = outcome.response.lines().last().unwrap_or_default();
                    println!("{}", ui::stamp_block(&format!("\x1b[2m{last}\x1b[0m")));
                }
            }
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
    /// `Some("")`: `--resume` without an ID (pick one).
    resume: Option<String>,
    list_sessions: bool,
    all: bool,
    config: Option<std::path::PathBuf>,
    verbosity: Option<ui::Verbosity>,
    sandbox: Option<sandbox::SandboxMode>,
    allow: Vec<String>,
    deny: Vec<String>,
    trajectory: Option<String>,
    json: bool,
    markdown: bool,
}

fn print_version() {
    println!("nano-coder {}", env!("CARGO_PKG_VERSION"));
}

fn print_help() {
    println!(
        "Usage: nano-coder [--acp] [--model provider/model] [--resume [SESSION_ID|last] | --resume=SESSION_ID] [--config PATH]"
    );
    println!("                  [--verbosity quiet|normal|verbose|debug]");
    println!("                  [--sandbox off|workspace|read-only] [--allow RULE]... [--deny RULE]...");
    println!("       nano-coder --list-sessions [--all] [--json]");
    println!("       nano-coder --trajectory SESSION_ID [--json|--markdown]");
    println!("       nano-coder --login github-copilot");
    println!("       nano-coder --list-models PROVIDER[/model]");
    println!("       nano-coder --version");
}

fn parse_args() -> Result<Args> {
    // Handle early-exit flags before the value-consuming loop so a preceding
    // value-taking option (e.g. `--model --version`) can't swallow them.
    for arg in env::args().skip(1) {
        match arg.as_str() {
            "-V" | "--version" => {
                print_version();
                std::process::exit(0);
            }
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            _ => {}
        }
    }
    parse_args_from(env::args().skip(1))
}

/// Parse the argument stream (without the program name) into [`Args`].
/// Split from [`parse_args`] so tests can drive it with a fixed argv.
fn parse_args_from<I: IntoIterator<Item = String>>(argv: I) -> Result<Args> {
    let mut args = Args {
        acp: false,
        login: None,
        list_models: None,
        model: None,
        resume: None,
        list_sessions: false,
        all: false,
        config: None,
        verbosity: None,
        sandbox: None,
        allow: Vec::new(),
        deny: Vec::new(),
        trajectory: None,
        json: false,
        markdown: false,
    };
    let mut iter = argv.into_iter().peekable();
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| iter.next().ok_or_else(|| anyhow::anyhow!("{name} requires a value"));
        match arg.as_str() {
            "--acp" => args.acp = true,
            "--login" => args.login = Some(value("--login")?),
            "--list-models" => args.list_models = Some(value("--list-models")?),
            "--model" => args.model = Some(value("--model")?),
            // The ID is optional: without one, pick from the saved sessions.
            // The attached `--resume=<id>` form is unambiguous and is the only
            // way to name a dash-prefixed id: the separated form leaves any
            // `-…` value in the stream (it looks like a flag), where it would
            // be rejected as an unknown argument.
            "--resume" => args.resume = Some(iter.next_if(|next| !next.starts_with('-')).unwrap_or_default()),
            _ if let Some(id) = arg.strip_prefix("--resume=") => args.resume = Some(id.to_string()),
            "--list-sessions" => args.list_sessions = true,
            "--all" => args.all = true,
            "--config" => args.config = Some(value("--config")?.into()),
            "--trajectory" => args.trajectory = Some(value("--trajectory")?),
            "--json" => args.json = true,
            "--markdown" | "--md" => args.markdown = true,
            "--verbosity" | "-v" => {
                args.verbosity = Some(value("--verbosity")?.parse().map_err(|e: String| anyhow::anyhow!(e))?)
            }
            "--sandbox" => args.sandbox = Some(value("--sandbox")?.parse().map_err(|e: String| anyhow::anyhow!(e))?),
            "--allow" => args.allow.push(value("--allow")?),
            "--deny" => args.deny.push(value("--deny")?),
            "-V" | "--version" => {
                print_version();
                std::process::exit(0);
            }
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            other => anyhow::bail!("unknown argument {other:?} (see --help)"),
        }
    }
    // The `--json` / `--markdown` output selectors are only honoured in
    // trajectory mode; without `--trajectory` they would silently start the
    // normal agent, and specifying both would silently pick one. Reject those
    // invalid combinations rather than run an unintended mode.
    if args.json && args.markdown {
        anyhow::bail!("--json and --markdown are mutually exclusive");
    }
    if args.markdown && args.trajectory.is_none() {
        anyhow::bail!("--markdown requires --trajectory <id>");
    }
    if args.json && args.trajectory.is_none() && !args.list_sessions {
        anyhow::bail!("--json requires --trajectory <id> or --list-sessions");
    }
    if args.all && !args.list_sessions {
        anyhow::bail!("--all requires --list-sessions");
    }
    // `--list-sessions` and `--trajectory` select different, exclusive modes.
    // The trajectory branch runs first, so accepting both would silently emit
    // trajectory output and ignore the requested session list; reject it.
    if args.list_sessions && args.trajectory.is_some() {
        anyhow::bail!("--list-sessions and --trajectory are mutually exclusive");
    }
    // `--list-sessions` and `--resume` also select different, exclusive modes.
    // The listing branch runs before the resume branch, so accepting both would
    // silently print the session list and ignore the requested resume; reject
    // it rather than let argument order-independent input pick an unrelated
    // action.
    if args.list_sessions && args.resume.is_some() {
        anyhow::bail!("--list-sessions and --resume are mutually exclusive");
    }
    // `--list-sessions` likewise conflicts with the other top-level action
    // modes. Dispatch runs `--login` before the listing, and the listing before
    // `--list-models` and `--acp`, so accepting any of these pairs would
    // silently perform one action and ignore the other; reject them.
    if args.list_sessions && args.login.is_some() {
        anyhow::bail!("--list-sessions and --login are mutually exclusive");
    }
    if args.list_sessions && args.list_models.is_some() {
        anyhow::bail!("--list-sessions and --list-models are mutually exclusive");
    }
    if args.list_sessions && args.acp {
        anyhow::bail!("--list-sessions and --acp are mutually exclusive");
    }
    // `--resume` likewise conflicts with the other exclusive action modes.
    // Dispatch runs `--login`, then `--trajectory`, then `--list-models` before
    // the resume branch, so accepting `--resume` with any of them would
    // silently perform that action and ignore the requested resume; reject
    // those pairs. `--acp` is the exception: an explicit `--resume <id>` is
    // honoured in ACP mode (the session is loaded before serving requests), so
    // only a bare picker `--resume` is rejected there (in `main`).
    if args.resume.is_some() && args.login.is_some() {
        anyhow::bail!("--resume and --login are mutually exclusive");
    }
    if args.resume.is_some() && args.trajectory.is_some() {
        anyhow::bail!("--resume and --trajectory are mutually exclusive");
    }
    if args.resume.is_some() && args.list_models.is_some() {
        anyhow::bail!("--resume and --list-models are mutually exclusive");
    }
    Ok(args)
}

#[tokio::main]
async fn main() -> Result<()> {
    // Detect execution mode from command-line args
    let mut args = parse_args()?;
    // Before anything reads the config or data directories.
    config::migrate_legacy_dirs();

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
    if let Some(id) = &args.trajectory {
        let records = session::read_records(&config.session_dir(), id)?;
        let traj = trajectory::Trajectory::from_records(&records);
        if args.json {
            println!("{}", traj.to_json());
        } else if args.markdown {
            println!("{}", traj.to_markdown());
        } else {
            let text = traj.to_plain();
            if !(trajectory_pageable(&traj) && trajectory::page(&text)) {
                println!("{text}");
            }
        }
        return Ok(());
    }
    let cwd = env::current_dir().map(|d| d.display().to_string()).unwrap_or_default();
    if args.list_sessions {
        resume::print_list(&config.session_dir(), &cwd, args.all, args.json)?;
        return Ok(());
    }
    match args.resume.as_deref() {
        Some("") if args.acp => anyhow::bail!("--resume needs a session ID with --acp"),
        Some("") if io::stdin().is_terminal() && io::stderr().is_terminal() => {
            match resume::pick(&config.session_dir(), &cwd, None)? {
                Some(id) => args.resume = Some(id),
                None => return Ok(()),
            }
        }
        Some("") => {
            // No terminal to pick in: list what could be resumed.
            resume::print_list(&config.session_dir(), &cwd, false, false)?;
            return Ok(());
        }
        Some("last") => args.resume = Some(resume::last(&config.session_dir(), &cwd, None)?),
        _ => {}
    }
    if let Some(spec) = &args.list_models {
        let (user, default_provider) = config.effective_providers();
        let client = providers::build_lister(spec, &user, &default_provider)?;
        for model in client.list_models().await? {
            println!("{}/{model}", client.provider_name());
        }
        return Ok(());
    }
    if let Some(model) = args.model.clone().or_else(|| env::var("AGENTIC_HARNESS_MODEL").ok().filter(|m| !m.is_empty()))
    {
        config.model = model;
    }

    if let Some(level) = args.verbosity {
        config.verbosity = level;
    }
    let env_sandbox = env::var("NANO_CODER_SANDBOX").ok().filter(|m| !m.is_empty());
    if let Some(mode) = env_sandbox
        .map(|m| m.parse::<sandbox::SandboxMode>())
        .transpose()
        .map_err(|e| anyhow::anyhow!("NANO_CODER_SANDBOX: {e}"))?
    {
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
        // ACP headless mode; sessions start with session/new or session/load.
        // No human vets a memory save live here, so full memory is downgraded
        // to read-only (the model can still consult earlier notes).
        agent.restrict_memory_to_read_only();
        if let Some(id) = &args.resume {
            agent.load_session(id)?;
        }
        eprintln!("ACP harness ready (provider: {}, model: {})", agent.provider_name(), agent.model_name());
        let saw_valid = acp::run_acp(&mut agent).await?;
        if !saw_valid {
            eprintln!(
                "no valid ACP requests received on stdin — is the client speaking ACP (JSON-RPC 2.0, one message per line)?"
            );
            std::process::exit(2);
        }
    } else {
        // The interactive CLI answers `question` tool calls, but only when a
        // real terminal is attached: with piped stdin/stdout the picker cannot
        // be driven, so `question` must take the documented headless path
        // instead of blocking in dialoguer while `Terminal` also reads stdin.
        let interactive = io::stdin().is_terminal() && io::stdout().is_terminal();
        agent.questions().set_interactive(interactive);
        if !interactive {
            // Piped stdin/stdout is a headless run (a script or agent fleet
            // drives the CLI): like ACP, no human vets a memory save live, so
            // downgrade full memory to read-only to uphold the headless
            // guarantee that the model cannot persist memories unvetted.
            agent.restrict_memory_to_read_only();
        }
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

        // Interactive CLI mode: build the startup banner. In frame mode the
        // renderer owns the screen and its first full redraw clears the
        // scrollback, so `println!`-ing the banner here would wipe it before it
        // is ever seen. Collect the lines now and emit them once the renderer
        // exists (below): seeded into the owned transcript in frame mode, or
        // printed inline as before in legacy mode.
        let mut banner = vec![
            format!("nano-coder v{}", env!("CARGO_PKG_VERSION")),
            format!("Model: {} (provider: {})", agent.model_name(), agent.provider_name()),
        ];
        if let Some(id) = agent.session_id() {
            banner.push(format!("Session: {id} (resume with --resume {id})"));
        }
        for file in agent.project_instruction_files() {
            banner.push(format!("Instructions: {file}"));
        }
        let skills = agent.skills();
        if !skills.is_empty() {
            banner.push(format!("Skills: {}", skills.names().join(", ")));
        }
        for warning in &skills.warnings {
            banner.push(format!("Skills warning: {warning}"));
        }
        if let Some(warning) = agent.temperature().warning {
            banner.push(format!("Warning: {warning}"));
        }
        banner.push("Type /help for commands".to_string());

        // Main loop
        let status = status::StatusLine::install(agent.context_stats());
        let _status_guard = StatusGuard(status.clone());
        let previous_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            lineedit::restore_terminal();
            previous_hook(info);
        }));
        let renderer = ui::Renderer::new(status.clone(), agent.config().renderer);
        ui::install(renderer.clone());
        let sink = renderer.clone();
        agent.set_event_sink(Box::new(move |_, event| sink.event(event)));
        agent.set_streaming(true);
        agent.refresh_stats();
        let frame_mode = renderer.is_frame();
        // Emit the startup banner now the renderer exists. In frame mode seed it
        // into the owned transcript via `print_block` so the first full redraw
        // (which clears the scrollback) cannot erase it; in legacy mode print it
        // inline, with the trailing blank line the banner has always had.
        if frame_mode {
            renderer.print_block(&banner.join("\n"));
        } else {
            println!("{}\n", banner.join("\n"));
        }
        let recents_path = recents::default_path();
        let recents: recents::SharedRecents = {
            let mut loaded = recents::load(&recents_path);
            // Migrate a legacy file recorded before entries were canonicalized,
            // so a raw default-provider spec (`meta-llama/llama-4`) is not
            // hidden by the picker's provider filter on the first `/model`. The
            // migration is gated on a persisted format marker and runs once; on
            // success we save the upgraded file so later loads skip it (and so a
            // removed provider's canonical entry is never reinterpreted).
            let (user, default_provider) = agent.config().effective_providers();
            if loaded.canonicalize(&providers::effective_providers(&user), &default_provider) {
                recents::save(&recents_path, &loaded);
            }
            Arc::new(Mutex::new(loaded))
        };
        let view = {
            let context = Arc::new(Mutex::new(lineedit::EditContext {
                config: agent.config().clone(),
                recents: recents.clone(),
            }));
            lineedit::EditView::shared(status.clone(), context)
        };
        if frame_mode {
            // The app-owned frame renderer draws the editor row itself; route
            // every edit through it instead of the inline/scroll-region path.
            let renderer = renderer.clone();
            view.lock().unwrap().set_edit_hook(Arc::new(
                move |line: &str, cursor: usize, queued: usize, menu: &[String]| {
                    renderer.set_editor(line, cursor, queued, menu)
                },
            ));
        }
        if let Ok(mut resized) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change()) {
            let view = view.clone();
            let status = status.clone();
            let renderer = renderer.clone();
            tokio::spawn(async move {
                // Debounce a burst of resizes (a window drag) into one render at
                // the final size: after a resize, wait for ~40 ms of quiet.
                let quiet = std::time::Duration::from_millis(40);
                let mut debounce = frame::Debouncer::new(quiet);
                while resized.recv().await.is_some() {
                    if !renderer.is_frame() {
                        // Legacy: re-anchor immediately, as before.
                        if let Some(status) = &status {
                            status.resize();
                        }
                        view.lock().unwrap().resize();
                        continue;
                    }
                    debounce.record(std::time::Instant::now());
                    // Coalesce further resizes arriving within the quiet window.
                    while debounce.pending() {
                        tokio::select! {
                            more = resized.recv() => match more {
                                Some(()) => debounce.record(std::time::Instant::now()),
                                None => break,
                            },
                            _ = tokio::time::sleep(quiet) => {
                                if debounce.ready(std::time::Instant::now()) {
                                    debounce.clear();
                                }
                            }
                        }
                    }
                    // Regenerate the editor's command-menu rows at the new size
                    // and redraw in a single pass. `view.resize()` re-runs
                    // `frame_menu` through the edit hook so `FrameState.menu` is
                    // sized to the new terminal, then renders; because the frame
                    // renderer's `render` detects the changed width/height it
                    // already performs one full invalidated redraw of every row
                    // (clearing scrollback). Calling `frame_resize()` afterwards
                    // would invalidate that just-rendered frame and re-emit the
                    // entire transcript a second time — a redundant O(history)
                    // redraw on every resize — so the hook-driven redraw is the
                    // sole one here.
                    view.lock().unwrap().resize();
                }
            });
        }
        // A resumed session loads its conversation before the sink is wired,
        // so the app-owned frame opens empty. Replay the loaded history now
        // (the sink is installed) to reconstruct the transcript into
        // `FrameState`; `frame_event` populates user, assistant, tool and plan
        // items. Only in frame mode — the legacy renderer would dump the whole
        // conversation inline, which it has never done on resume. Batched into
        // one render: per-event renders would redo the whole transcript layout
        // for every replayed event.
        if frame_mode && args.resume.is_some() {
            renderer.frame_batch(|| agent.replay_history());
        }
        let mut terminal = Terminal::start(
            config_path,
            view,
            renderer,
            recents,
            recents_path,
            status.clone(),
            agent.config().renderer,
        );
        let mut running = true;
        // Ctrl-C twice within the window exits; time-based so an interleaved
        // key or a queued/empty line cannot silently disarm it (see
        // `DoublePress`). The note stays visible until the window lapses.
        let mut exit_press = DoublePress::new(DOUBLE_INTERRUPT_WINDOW);
        let mut separate = false;
        while running {
            if let Some(status) = &status
                && !terminal.renderer.is_frame()
            {
                status.draw();
            }
            let prompt = |terminal: &Terminal, separate: bool| {
                if terminal.queued.is_empty() && terminal.messages.is_empty() {
                    let mut view = terminal.view.lock().unwrap();
                    if terminal.renderer.is_frame() {
                        // The frame renderer owns the screen: refresh the editor
                        // row (and thus the whole frame) instead of writing an
                        // inline prompt.
                        // `prompt_redrawn` re-renders the editor (and its
                        // command menu) through the edit hook.
                        view.prompt_redrawn();
                        return;
                    }
                    let prompt = view.prompt();
                    // Serialise the prompt write under the terminal lock so it
                    // cannot move the cursor mid-way through the SIGWINCH
                    // anchor's query-to-scroll critical section (status::anchor).
                    crate::status::with_term_lock(|| {
                        let mut out = io::stdout().lock();
                        if separate {
                            let _ = out.write_all(b"\n");
                        }
                        let _ = out.write_all(prompt.as_bytes());
                        let _ = out.flush();
                    });
                    view.prompt_redrawn();
                }
            };
            prompt(&terminal, separate);
            separate = false;

            let input = loop {
                let next = terminal.next(&agent);
                // While the Ctrl-C exit hint is armed, bound the wait on the
                // exit window: if the second press never comes, clear the stale
                // "(Ctrl-C again to exit)" hint and disarm the detector so the
                // visible instruction stays in sync with the armed state (a
                // press after the window re-arms rather than exits).
                let event = if let Some(deadline) = exit_press.deadline() {
                    match tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), next).await {
                        Ok(event) => event,
                        Err(_) => {
                            exit_press.disarm();
                            terminal.renderer.clear_transient();
                            continue;
                        }
                    }
                } else {
                    next.await
                };
                match event {
                    TermInput::ToggleThinking => {
                        if terminal.renderer.toggle_thinking() {
                            prompt(&terminal, false);
                        }
                    }
                    TermInput::CycleMode => {
                        let mode = agent.control().cycle_mode();
                        agent.set_mode(mode);
                        if terminal.renderer.is_frame() {
                            terminal.renderer.note(&format!("Mode: {mode} ({})", mode.describe()));
                        } else {
                            println!("\nMode: {mode} ({})", mode.describe());
                        }
                        prompt(&terminal, false);
                    }
                    other => break other,
                }
            };
            let input = match input {
                TermInput::Eof => break,
                TermInput::Interrupt => {
                    if exit_press.press(std::time::Instant::now()) {
                        break;
                    }
                    // Show the hint where the user is actually looking: as a
                    // transient on the status line / editor row (both
                    // renderers), not as a transcript item that triggers a
                    // full-screen clear in frame mode.
                    terminal.renderer.transient_note("(Ctrl-C again to exit)");
                    continue;
                }
                TermInput::ToggleThinking | TermInput::Escape | TermInput::CycleMode => continue,
                TermInput::Line(line) | TermInput::Queue(line) => line.trim().to_string(),
            };
            if input.trim().is_empty() {
                continue;
            }
            if terminal.renderer.is_frame() && !input.starts_with('/') {
                terminal.renderer.frame_user_message(&input);
            }

            match run_command(&mut agent, &input, &mut terminal).await {
                Ok(continue_running) => {
                    running = continue_running;
                }
                Err(e) => {
                    if terminal.renderer.is_frame() {
                        terminal.renderer.note(&format!("Error: {:#}", e));
                    } else {
                        eprintln!("Error: {:#}", e);
                    }
                }
            }
            separate = true;
        }

        println!("\nGoodbye!");
        // Repeat the resume instruction on exit so it is still on screen (and
        // in scrollback) after a long session has pushed the start-up banner
        // away. `/restart` may have swapped the session mid-run, so re-read
        // the current ID rather than remembering the start-up one. Gate on
        // `session_path()` (not `session_id()`): when persistence is disabled
        // `/restart` still assigns a session ID even though nothing is written
        // to disk, so printing a `--resume` command there would be unusable.
        if agent.session_path().is_some()
            && let Some(id) = agent.session_id()
        {
            println!("Session: {id} (resume with --resume {id})");
        }
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

    #[test]
    fn double_press_is_time_based_not_disarmed_by_other_input() {
        // The Ctrl-C exit gesture: two presses within the window exit, and —
        // unlike the old `exit_armed` bool — input arriving between the presses
        // (a stray key, a queued/empty line) must not reset the arm, because
        // the arm lives in the detector's timestamp, not in loop state.
        let mut exit = DoublePress::new(Duration::from_millis(2000));
        let t = Instant::now();
        assert!(!exit.press(t), "first press arms, does not exit");
        // … the user hits Enter (an empty line) here; the loop no longer
        // touches the detector, so the arm survives …
        assert!(
            exit.press(t + Duration::from_millis(1200)),
            "second press within the window exits even after interleaved input"
        );
        // A completed pair is consumed: the next press starts a fresh pair.
        assert!(!exit.press(t + Duration::from_millis(1300)));
        // Too slow: a press after the window re-arms instead of exiting.
        let mut exit = DoublePress::new(Duration::from_millis(2000));
        assert!(!exit.press(t));
        assert!(!exit.press(t + Duration::from_millis(2500)), "outside the window: re-arm");
        assert!(exit.press(t + Duration::from_millis(2600)), "and the next press completes");
    }

    #[test]
    fn double_press_deadline_arms_and_disarm_clears_it() {
        // The exit-hint lifecycle: arming a first press exposes the window's
        // deadline so the caller can bound its wait and clear the stale hint
        // when the window lapses; disarming (the timeout path) resets it so a
        // later press starts a fresh pair instead of completing the old one.
        let window = Duration::from_millis(2000);
        let mut exit = DoublePress::new(window);
        let t = Instant::now();
        assert_eq!(exit.deadline(), None, "not armed before any press");
        assert!(!exit.press(t), "first press arms");
        assert_eq!(exit.deadline(), Some(t + window), "armed: deadline is press + window");
        // Simulate the window lapsing with no second press: disarm.
        exit.disarm();
        assert_eq!(exit.deadline(), None, "disarmed: no pending deadline");
        // A press after disarming re-arms rather than exiting.
        assert!(!exit.press(t + Duration::from_millis(2500)), "post-timeout press re-arms");
        assert_eq!(exit.deadline(), Some(t + Duration::from_millis(2500) + window));
    }

    #[test]
    fn sanitize_terminal_text_strips_control_and_escape_sequences() {
        // A prompt-injected ANSI/OSC payload is neutralised, printable text kept.
        assert_eq!(sanitize_terminal_text("hi\x1b[2Jthere"), "hi[2Jthere");
        assert_eq!(sanitize_terminal_text("a\x07\x00b\tc"), "abc");
        assert_eq!(sanitize_terminal_text("plain — label"), "plain — label");
    }

    #[test]
    fn sanitize_terminal_text_strips_unicode_line_separators() {
        // U+2028/U+2029 are not `char::is_control`, but a terminal folds them as
        // line breaks, so a hand-edited `/memory` id/text/evidence value could
        // otherwise render a forged extra row (Copilot finding, src/main.rs).
        assert_eq!(sanitize_terminal_text("mem-evil\u{2028}forged row"), "mem-evilforged row");
        assert_eq!(sanitize_terminal_text("head\u{2029}forged row"), "headforged row");
        // Ordinary printable text (including non-ASCII) is left intact.
        assert_eq!(sanitize_terminal_text("café — label"), "café — label");
    }

    #[test]
    fn resume_attached_form_names_dash_prefixed_ids() {
        let argv = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        // The separated form still takes a following non-flag value…
        assert_eq!(parse_args_from(argv(&["--resume", "sess-1"])).unwrap().resume.as_deref(), Some("sess-1"));
        // …and no value means "pick one".
        assert_eq!(parse_args_from(argv(&["--resume"])).unwrap().resume.as_deref(), Some(""));
        // A dash-prefixed id is only addressable in the attached form: the
        // separated form would leave `-sess` in the stream as an unknown flag.
        assert_eq!(parse_args_from(argv(&["--resume=-sess"])).unwrap().resume.as_deref(), Some("-sess"));
        assert!(parse_args_from(argv(&["--resume", "-sess"])).is_err());
    }

    #[test]
    fn list_sessions_and_trajectory_are_mutually_exclusive() {
        let argv = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        // Each mode on its own parses fine…
        assert!(parse_args_from(argv(&["--list-sessions"])).is_ok());
        assert!(parse_args_from(argv(&["--trajectory", "sess-1"])).is_ok());
        // …but combining them is rejected rather than silently running the
        // trajectory branch and ignoring the requested session list.
        assert!(parse_args_from(argv(&["--list-sessions", "--trajectory", "sess-1"])).is_err());
        assert!(parse_args_from(argv(&["--trajectory", "sess-1", "--list-sessions", "--json"])).is_err());
    }

    #[test]
    fn list_sessions_and_resume_are_mutually_exclusive() {
        let argv = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        // Each mode on its own parses fine…
        assert!(parse_args_from(argv(&["--list-sessions"])).is_ok());
        assert!(parse_args_from(argv(&["--resume", "sess-1"])).is_ok());
        // …but combining them is rejected rather than silently printing the
        // list and ignoring the requested resume, regardless of order or
        // whether `--resume` carries an explicit id.
        assert!(parse_args_from(argv(&["--list-sessions", "--resume", "sess-1"])).is_err());
        assert!(parse_args_from(argv(&["--resume", "sess-1", "--list-sessions"])).is_err());
        assert!(parse_args_from(argv(&["--list-sessions", "--resume"])).is_err());
    }

    #[test]
    fn list_sessions_conflicts_with_other_action_modes() {
        let argv = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        // Each action mode on its own parses fine…
        assert!(parse_args_from(argv(&["--login", "github-copilot"])).is_ok());
        assert!(parse_args_from(argv(&["--list-models", "openai"])).is_ok());
        assert!(parse_args_from(argv(&["--acp"])).is_ok());
        // …but combining `--list-sessions` with any of them is rejected rather
        // than silently performing one action (login first, or the listing
        // before `--list-models`/`--acp`) and ignoring the other.
        assert!(parse_args_from(argv(&["--list-sessions", "--login", "github-copilot"])).is_err());
        assert!(parse_args_from(argv(&["--list-sessions", "--list-models", "openai"])).is_err());
        assert!(parse_args_from(argv(&["--list-sessions", "--acp"])).is_err());
        assert!(parse_args_from(argv(&["--acp", "--list-sessions"])).is_err());
    }

    #[test]
    fn resume_conflicts_with_other_action_modes() {
        let argv = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        // `--resume` (bare picker or explicit id) and each other action mode on
        // their own parse fine…
        assert!(parse_args_from(argv(&["--resume"])).is_ok());
        assert!(parse_args_from(argv(&["--resume", "sess-1"])).is_ok());
        assert!(parse_args_from(argv(&["--login", "github-copilot"])).is_ok());
        assert!(parse_args_from(argv(&["--trajectory", "sess-1"])).is_ok());
        assert!(parse_args_from(argv(&["--list-models", "openai"])).is_ok());
        // …but combining `--resume` with `--login`, `--trajectory`, or
        // `--list-models` is rejected rather than silently running that mode
        // (each dispatches before the resume branch) and ignoring the resume.
        assert!(parse_args_from(argv(&["--resume", "--login", "github-copilot"])).is_err());
        assert!(parse_args_from(argv(&["--login", "github-copilot", "--resume", "sess-1"])).is_err());
        assert!(parse_args_from(argv(&["--resume", "--trajectory", "sess-1"])).is_err());
        assert!(parse_args_from(argv(&["--trajectory", "sess-1", "--resume"])).is_err());
        assert!(parse_args_from(argv(&["--resume", "--list-models", "openai"])).is_err());
        assert!(parse_args_from(argv(&["--list-models", "openai", "--resume=sess-1"])).is_err());
        // `--acp` stays compatible with an explicit `--resume <id>` (the session
        // is loaded before serving ACP requests); only a bare picker `--resume`
        // is rejected there (in `main`, not parse_args).
        assert!(parse_args_from(argv(&["--acp", "--resume", "sess-1"])).is_ok());
    }

    #[test]
    fn sanitize_terminal_text_preserves_line_feeds() {
        // Multi-line model/tool text must keep its line breaks: the transcript
        // replay re-prints it as the lines the frame showed, so stripping `\n`
        // would concatenate the lines. Other controls are still dropped.
        assert_eq!(sanitize_terminal_text("one\ntwo\nthree"), "one\ntwo\nthree");
        assert_eq!(sanitize_terminal_text("one\x1b[2J\ntwo"), "one[2J\ntwo");
    }

    #[test]
    fn classify_steer_input_routes_line_queue_and_commands() {
        // Plain Enter (`TermInput::Line`, steer = true) steers the running turn.
        assert!(matches!(classify_steer_input("keep going", true), SteerRoute::Steer));
        // Ctrl-Enter (`TermInput::Queue`, steer = false) enqueues for a later turn.
        assert!(matches!(classify_steer_input("keep going", false), SteerRoute::Enqueue));
        // A regression that swapped these two would flip the feature's core
        // behaviour while still routing the same text — the pair above catches it.

        // `/queue` edits run live regardless of the Enter vs Ctrl-Enter flag.
        assert!(matches!(classify_steer_input("/queue add hello", true), SteerRoute::QueueCommand(_)));
        assert!(matches!(classify_steer_input("/queue add hello", false), SteerRoute::QueueCommand(_)));

        // Any other slash command defers until the turn finishes.
        assert!(matches!(classify_steer_input("/help", true), SteerRoute::DeferCommand));
        assert!(matches!(classify_steer_input("/model", false), SteerRoute::DeferCommand));

        // Blank input is a no-op on both paths.
        assert!(matches!(classify_steer_input("", true), SteerRoute::Ignore));
        assert!(matches!(classify_steer_input("", false), SteerRoute::Ignore));
    }

    #[test]
    fn forget_id_requires_a_token_boundary() {
        // A well-formed `forget` request yields the trimmed id.
        assert_eq!(parse_forget_id("forget mem-abc"), Some("mem-abc"));
        assert_eq!(parse_forget_id("forget  mem-abc  "), Some("mem-abc"));
        assert_eq!(parse_forget_id("forget\tmem-abc"), Some("mem-abc"));
        // `forget` alone is a forget request with an empty id (usage error).
        assert_eq!(parse_forget_id("forget"), Some(""));
        // No token boundary: `forgetmem-…` is NOT a forget request, so the
        // caller reports an unknown argument instead of deleting `mem-…`
        // (Copilot finding, src/main.rs).
        assert_eq!(parse_forget_id("forgetmem-abc"), None);
        assert_eq!(parse_forget_id("forgetful"), None);
        // Unrelated args are not forget requests either.
        assert_eq!(parse_forget_id(""), None);
        assert_eq!(parse_forget_id("list"), None);
    }

    /// Minimal `LLMClient` for `memory_command` tests: the slash command never
    /// calls the model, so a client that panics if it ever is suffices.
    struct NoModel;

    #[async_trait::async_trait]
    impl crate::llm::LLMClient for NoModel {
        async fn chat(&self, _: &crate::llm::ChatRequest<'_>) -> Result<crate::llm::LLMResponse> {
            panic!("memory_command must not call the model")
        }
        fn model_name(&self) -> &str {
            "none"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    /// A memory-enabled agent (user+project store under `dir`) for
    /// `memory_command` tests.
    fn memory_command_agent(dir: &std::path::Path) -> Agent {
        let config = config::Config {
            session_dir: Some(dir.join("sessions")),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            memory: config::MemoryMode::On,
            memory_dir: Some(dir.join("memory")),
            ..config::Config::default()
        };
        Agent::new(Box::new(NoModel), config)
    }

    #[test]
    fn memory_forget_is_refused_in_plan_mode() {
        // `/memory forget` reaches `Store::forget` directly, bypassing the tool
        // dispatch that refuses `memory_forget` in Plan mode. It must gate on
        // the live mode itself, or a mid-plan `/memory forget` would delete the
        // persistent scope file despite Plan mode's read-only promise (Copilot
        // finding, src/main.rs).
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_command_agent(dir.path());
        let id = agent.memory().unwrap().save(memory::Scope::User, "a fact to keep", None, None).unwrap().id;
        agent.set_mode(crate::mode::AgentMode::Plan);
        let msg = memory_command(&mut agent, &format!("forget {id}"));
        assert!(msg.contains("plan mode"), "forget refused in plan mode: {msg}");
        assert!(
            agent.memory().unwrap().all().unwrap().iter().any(|(_, e)| e.id == id),
            "plan mode did not delete the entry"
        );
        // Leaving Plan mode lifts the gate: the same forget now succeeds.
        agent.set_mode(crate::mode::AgentMode::Normal);
        let msg = memory_command(&mut agent, &format!("forget {id}"));
        assert!(!msg.contains("plan mode"), "normal mode forgets: {msg}");
        assert!(
            !agent.memory().unwrap().all().unwrap().iter().any(|(_, e)| e.id == id),
            "normal mode deleted the entry"
        );
    }

    #[test]
    fn memory_list_hints_gate_on_effective_plan_mode_writability() {
        // In Plan mode the configured memory stays `On`, but `memory_save` is
        // removed and `/memory forget` is refused. The `/memory` output must not
        // advertise either: gate both the empty-list `memory_save` pointer and
        // the populated-list `/memory forget <id>` hint on `memory_writable()`,
        // which includes the live mode (Copilot finding, src/main.rs).
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_command_agent(dir.path());

        // Empty memory, Plan mode: no `memory_save` suggestion.
        agent.set_mode(crate::mode::AgentMode::Plan);
        let msg = memory_command(&mut agent, "");
        assert!(!msg.contains("memory_save"), "plan-mode empty hint hides memory_save: {msg}");
        // Normal mode restores the suggestion.
        agent.set_mode(crate::mode::AgentMode::Normal);
        let msg = memory_command(&mut agent, "");
        assert!(msg.contains("memory_save"), "normal-mode empty hint offers memory_save: {msg}");

        // Populated memory, Plan mode: no `/memory forget` hint.
        agent.memory().unwrap().save(memory::Scope::User, "a fact to keep", None, None).unwrap();
        agent.set_mode(crate::mode::AgentMode::Plan);
        let msg = memory_command(&mut agent, "");
        assert!(!msg.contains("/memory forget"), "plan-mode list hides forget hint: {msg}");
        // Normal mode restores the hint.
        agent.set_mode(crate::mode::AgentMode::Normal);
        let msg = memory_command(&mut agent, "");
        assert!(msg.contains("/memory forget"), "normal-mode list offers forget hint: {msg}");
    }
}
