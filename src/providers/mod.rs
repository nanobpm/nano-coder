//! Model providers: heterogeneous remote (and local) endpoints behind one
//! `LLMClient` interface.
//!
//! A model is addressed as `provider/model`, e.g. `openrouter/anthropic/claude-sonnet-4.5`,
//! `anthropic/claude-sonnet-4-5`, or `ollama/qwen3:8b`. The first path segment
//! selects a provider when it names a configured provider or a built-in preset;
//! otherwise the whole string is a model on `default_provider`.

pub mod anthropic;
pub mod github_copilot;
pub mod mock;
pub mod openai;
pub mod openai_responses;
pub mod retry;

use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::llm::LLMClient;
use retry::{ApiError, RetryPolicy};

/// Wire protocol spoken by a provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderKind {
    /// OpenAI Chat Completions (`POST {base_url}/chat/completions`). Also spoken by
    /// OpenRouter, Fireworks, Groq, Together, DeepSeek, Mistral, Gemini's OpenAI
    /// endpoint, Ollama, llama.cpp, vLLM, LM Studio, DwarfStar ds4, ...
    #[serde(alias = "openai-compatible", alias = "openai-chat")]
    Openai,
    /// Anthropic Messages (`POST {base_url}/messages`).
    Anthropic,
    /// UNOFFICIAL: GitHub Copilot's chat endpoint using a Copilot subscription,
    /// authenticated the way VS Code does (see `github_copilot`).
    #[serde(alias = "copilot")]
    GithubCopilot,
    /// Offline scripted client for demos and tests.
    Mock,
}

/// Provider settings. Every field is optional in TOML so that a user entry can
/// override just part of a built-in preset with the same name.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ProviderConfig {
    pub kind: Option<ProviderKind>,
    pub base_url: Option<String>,
    /// Literal API key. Prefer `api_key_env`.
    pub api_key: Option<String>,
    /// Environment variable holding the API key.
    pub api_key_env: Option<String>,
    /// Shell command whose trimmed stdout is the API key (e.g. `gh auth token`).
    /// Used when neither `api_key` nor a non-empty `api_key_env` is available.
    pub api_key_command: Option<String>,
    /// Model used when the spec names only the provider (e.g. `--model ollama`).
    pub default_model: Option<String>,
    /// Extra HTTP headers (e.g. OpenRouter's `HTTP-Referer` / `X-Title`).
    pub headers: BTreeMap<String, String>,
    /// JSON merged into every request body (e.g. `{ think = false }`,
    /// `{ reasoning_effort = "low" }`, OpenRouter `provider` routing).
    pub extra_body: Option<toml::Table>,
    /// Top-level request fields to remove (e.g. `["temperature"]` for models
    /// that reject it).
    pub drop_params: Option<Vec<String>>,
    /// Field used for the output-token cap: `max_tokens` or `max_completion_tokens`.
    pub max_tokens_param: Option<String>,
    /// Context window in tokens, for the status line and auto-compaction.
    pub context_window: Option<usize>,
    /// Stream responses (server-sent events) in the interactive CLI. Default true.
    pub stream: Option<bool>,
    /// Idle timeout in seconds: the maximum silence between received bytes
    /// before a request fails. Resets on each chunk, so it never cuts off a
    /// slow but steady stream — it only catches a stalled connection. Default 600.
    pub timeout_secs: Option<u64>,
    pub max_retries: Option<u32>,
    pub retry_initial_backoff_ms: Option<u64>,
    pub retry_max_backoff_ms: Option<u64>,
    pub retryable_statuses: Option<Vec<u16>>,
    /// Send each assistant message's `reasoning_content` back to the provider,
    /// for thinking models that require it in multi-turn and tool-call
    /// conversations (e.g. Kimi K3). Default false.
    pub replay_reasoning: Option<bool>,
}

impl ProviderConfig {
    fn preset(kind: ProviderKind, base_url: &str, api_key_env: Option<&str>) -> Self {
        Self {
            kind: Some(kind),
            base_url: Some(base_url.to_string()),
            api_key_env: api_key_env.map(str::to_string),
            ..Default::default()
        }
    }

    /// Overlay `other` onto `self`; fields set in `other` win.
    pub fn merged_with(mut self, other: &ProviderConfig) -> Self {
        macro_rules! take {
            ($($field:ident),*) => { $( if other.$field.is_some() { self.$field = other.$field.clone(); } )* };
        }
        take!(
            kind,
            base_url,
            api_key,
            api_key_env,
            api_key_command,
            default_model,
            extra_body,
            drop_params,
            max_tokens_param,
            context_window,
            stream,
            timeout_secs,
            max_retries,
            retry_initial_backoff_ms,
            retry_max_backoff_ms,
            retryable_statuses,
            replay_reasoning
        );
        self.headers.extend(other.headers.clone());
        self
    }
}

/// Built-in provider presets, overridable from `[providers.<name>]`.
pub fn presets() -> BTreeMap<String, ProviderConfig> {
    use ProviderKind::*;
    let mut presets = BTreeMap::new();
    let mut add = |name: &str, config: ProviderConfig| {
        presets.insert(name.to_string(), config);
    };
    add(
        "openai",
        ProviderConfig {
            max_tokens_param: Some("max_completion_tokens".into()),
            ..ProviderConfig::preset(Openai, "https://api.openai.com/v1", Some("OPENAI_API_KEY"))
        },
    );
    add("anthropic", ProviderConfig::preset(Anthropic, "https://api.anthropic.com/v1", Some("ANTHROPIC_API_KEY")));
    add("openrouter", ProviderConfig::preset(Openai, "https://openrouter.ai/api/v1", Some("OPENROUTER_API_KEY")));
    add(
        "fireworks",
        ProviderConfig::preset(Openai, "https://api.fireworks.ai/inference/v1", Some("FIREWORKS_API_KEY")),
    );
    add("groq", ProviderConfig::preset(Openai, "https://api.groq.com/openai/v1", Some("GROQ_API_KEY")));
    add("together", ProviderConfig::preset(Openai, "https://api.together.xyz/v1", Some("TOGETHER_API_KEY")));
    add("deepseek", ProviderConfig::preset(Openai, "https://api.deepseek.com/v1", Some("DEEPSEEK_API_KEY")));
    add(
        "kimi",
        ProviderConfig {
            max_tokens_param: Some("max_completion_tokens".into()),
            // K3 fixes temperature and rejects other values; it also needs its
            // reasoning replayed with each assistant message.
            drop_params: Some(vec!["temperature".into()]),
            replay_reasoning: Some(true),
            ..ProviderConfig::preset(Openai, "https://api.moonshot.ai/v1", Some("MOONSHOT_API_KEY"))
        },
    );
    add("mistral", ProviderConfig::preset(Openai, "https://api.mistral.ai/v1", Some("MISTRAL_API_KEY")));
    add(
        "gemini",
        ProviderConfig::preset(
            Openai,
            "https://generativelanguage.googleapis.com/v1beta/openai",
            Some("GEMINI_API_KEY"),
        ),
    );
    add(
        "github-copilot",
        ProviderConfig {
            kind: Some(GithubCopilot),
            api_key_env: Some("GITHUB_COPILOT_OAUTH_TOKEN".into()),
            default_model: Some("gpt-4.1".into()),
            ..Default::default()
        },
    );
    add(
        "qwen",
        ProviderConfig::preset(
            Openai,
            "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            Some("DASHSCOPE_API_KEY"),
        ),
    );
    add("ollama", ProviderConfig::preset(Openai, "http://localhost:11434/v1", None));
    add("llamacpp", ProviderConfig::preset(Openai, "http://localhost:8080/v1", None));
    add("mock", ProviderConfig { kind: Some(Mock), default_model: Some("mock".into()), ..Default::default() });
    presets
}

/// Presets overlaid with user configuration.
pub fn effective_providers(user: &HashMap<String, ProviderConfig>) -> BTreeMap<String, ProviderConfig> {
    let mut providers = presets();
    for (name, config) in user {
        let base = providers.remove(name).unwrap_or_default();
        providers.insert(name.clone(), base.merged_with(config));
    }
    providers
}

/// Split `provider/model` into its parts.
pub fn parse_model_spec<'a>(
    spec: &'a str,
    providers: &BTreeMap<String, ProviderConfig>,
    default_provider: &'a str,
) -> (&'a str, Option<&'a str>) {
    let spec = spec.trim();
    if let Some((head, rest)) = spec.split_once('/') {
        if providers.contains_key(head) {
            return (head, Some(rest).filter(|r| !r.is_empty()));
        }
    } else if providers.contains_key(spec) {
        return (spec, None);
    }
    (default_provider, Some(spec).filter(|s| !s.is_empty()))
}

/// The configured context window and model name for a spec, without
/// resolving credentials.
pub fn context_window(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
) -> (Option<usize>, String) {
    let providers = effective_providers(user);
    let (name, model) = parse_model_spec(spec, &providers, default_provider);
    let provider = providers.get(name);
    let model =
        model.map(str::to_string).or_else(|| provider.and_then(|p| p.default_model.clone())).unwrap_or_default();
    (provider.and_then(|p| p.context_window), model)
}

/// Fully-resolved provider settings used by a client.
#[derive(Debug, Clone)]
pub struct ResolvedProvider {
    pub name: String,
    pub kind: ProviderKind,
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: String,
    pub headers: BTreeMap<String, String>,
    pub extra_body: serde_json::Map<String, Value>,
    pub drop_params: Vec<String>,
    pub max_tokens_param: String,
    pub stream: bool,
    /// Idle timeout: max silence between received bytes before a request fails
    /// (resets on each chunk, so slow steady streams are never cut off).
    pub timeout: Duration,
    pub retry: RetryPolicy,
    pub retryable_statuses: Vec<u16>,
    pub replay_reasoning: bool,
}

/// Check that `spec` names a known provider with a usable `kind`, model, and
/// endpoint, against an already-resolved `providers` map — **without side
/// effects**. Unlike [`resolve`], it never runs an `api_key_command`
/// subprocess or builds a client, so it is safe to call synchronously on the
/// UI thread (e.g. when a `/model <spec>` is typed mid-turn) to report an
/// unbuildable spec immediately instead of letting it fail silently later. It
/// returns the same errors `resolve` would for these cases; the api-key path
/// is intentionally not checked here (that is the apply-time safety net's job).
pub fn validate_spec(spec: &str, providers: &BTreeMap<String, ProviderConfig>, default_provider: &str) -> Result<()> {
    let (name, model) = parse_model_spec(spec, providers, default_provider);
    let config = providers.get(name).ok_or_else(|| {
        anyhow!(
            "unknown provider {name:?} for model {spec:?}; known providers: {}",
            providers.keys().cloned().collect::<Vec<_>>().join(", ")
        )
    })?;
    let kind = config.kind.ok_or_else(|| anyhow!("provider {name:?} has no `kind` (openai, anthropic, or mock)"))?;
    model
        .map(str::to_string)
        .or_else(|| config.default_model.clone())
        .ok_or_else(|| anyhow!("no model given for provider {name:?} and it has no default_model"))?;
    match (kind, &config.base_url) {
        // Mock derives (or does not need) an endpoint, so any/no base_url is
        // fine. Copilot derives its endpoint from the session token *unless
        // overridden*; a present non-empty override is used verbatim by
        // `GithubCopilotClient::api_base`, so it must be validated like any
        // other HTTP endpoint — otherwise a malformed override passes
        // queue-time validation, replaces the working client, and fails only
        // on the next request. A real HTTP provider must carry a usable one.
        //
        // The emptiness guard here must match `api_base`'s `configured.is_empty()`
        // test exactly: that is the string that decides "derive vs use the
        // override". A trimming guard (`!url.trim().is_empty()`) would exempt a
        // whitespace-only override (`"   "`) from validation while `api_base`
        // still treats it as present and uses it verbatim — reopening the
        // fail-open gap. Using `!url.is_empty()` routes any present-but-whitespace
        // override into `validate_http_base_url`, which rejects it.
        (ProviderKind::Mock, _) => {}
        (ProviderKind::GithubCopilot, Some(url)) if !url.is_empty() => validate_http_base_url(name, url)?,
        (ProviderKind::GithubCopilot, _) => {}
        (_, Some(url)) => validate_http_base_url(name, url)?,
        (_, None) => bail!("provider {name:?} has no base_url"),
    }
    Ok(())
}

/// A configured HTTP(S) provider endpoint must be a real, absolute http(s)
/// URL. Requests are built as `format!("{base_url}{path}")` (see
/// [`HttpTransport::post_json`]), so an empty or malformed `base_url` is not
/// caught by `Some(_)`/`HttpTransport::new`; it only fails later while building
/// the request URL — by which point a mid-turn switch has already replaced the
/// working client and lost the current model. Validating it here (shared by
/// [`validate_spec`] and [`resolve`]) rejects the bad endpoint at queue time
/// and preserves the queue-time bad-endpoint guarantee.
fn validate_http_base_url(provider: &str, base_url: &str) -> Result<()> {
    if base_url.trim().is_empty() {
        bail!("provider {provider:?} has an empty base_url");
    }
    // `resolve` stores `base_url` verbatim (only `trim_end_matches('/')`), but
    // `reqwest::Url::parse` silently strips leading/trailing whitespace and C0
    // control characters while validating. That mismatch is a fail-open gap: a
    // value like " http://host/v1" or "http://host\n" parses here yet is kept
    // raw and only breaks later in `format!("{base_url}{path}")`. A real
    // endpoint never contains whitespace or control characters, so reject any —
    // validating the exact string that will be used downstream.
    if let Some(bad) = base_url.chars().find(|c| c.is_whitespace() || c.is_control()) {
        bail!(
            "provider {provider:?} base_url {base_url:?} must not contain whitespace or control characters (found {bad:?})"
        );
    }
    let parsed = reqwest::Url::parse(base_url)
        .map_err(|e| anyhow!("provider {provider:?} has a malformed base_url {base_url:?}: {e}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        bail!("provider {provider:?} base_url {base_url:?} must be http(s), not {:?}", parsed.scheme());
    }
    // Request endpoints are formed by string-appending a path to `base_url`
    // (`format!("{base_url}{path}")`), so a query or fragment makes the result
    // unusable: `https://host/v1?token=x` becomes
    // `https://host/v1?token=x/chat/completions`, putting the API path in the
    // query, and a fragment is never sent. Reject both so a base_url that
    // passes validation is actually usable downstream.
    if parsed.query().is_some() || parsed.fragment().is_some() {
        bail!("provider {provider:?} base_url {base_url:?} must not contain a query or fragment");
    }
    Ok(())
}

/// Test-only convenience wrapper over [`resolve_cancellable`] with no cancel
/// flag; production builds go through `build_client` → `resolve_cancellable`.
#[cfg(test)]
pub fn resolve(spec: &str, user: &HashMap<String, ProviderConfig>, default_provider: &str) -> Result<ResolvedProvider> {
    resolve_cancellable(spec, user, default_provider, None)
}

/// Like [`resolve`], but a running `api_key_command` honours `cancel`: when the
/// flag flips the child process is killed and the build fails fast, so a hung
/// key command can never wedge a cancellable caller (e.g. a mid-turn `/model`
/// switch). `cancel` is `None` for build paths with no turn to cancel against.
pub fn resolve_cancellable(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
    cancel: Option<&Arc<AtomicBool>>,
) -> Result<ResolvedProvider> {
    let providers = effective_providers(user);
    let (name, model) = parse_model_spec(spec, &providers, default_provider);
    let config = providers.get(name).ok_or_else(|| {
        anyhow!(
            "unknown provider {name:?} for model {spec:?}; known providers: {}",
            providers.keys().cloned().collect::<Vec<_>>().join(", ")
        )
    })?;
    let kind = config.kind.ok_or_else(|| anyhow!("provider {name:?} has no `kind` (openai, anthropic, or mock)"))?;
    let model = model
        .map(str::to_string)
        .or_else(|| config.default_model.clone())
        .ok_or_else(|| anyhow!("no model given for provider {name:?} and it has no default_model"))?;
    let base_url = match (kind, &config.base_url) {
        // Mock needs no endpoint. Copilot derives its endpoint from the
        // session token unless overridden; a present non-empty override is used
        // verbatim by `GithubCopilotClient::api_base`, so validate it like any
        // other HTTP endpoint (sharing the queue-time bad-endpoint guarantee)
        // before storing it. The emptiness guard must match `api_base`'s
        // `is_empty()` test (not a trimming one) so a whitespace-only override
        // is validated (and rejected) rather than exempted here yet used there.
        (ProviderKind::Mock, url) => url.clone().unwrap_or_default().trim_end_matches('/').to_string(),
        (ProviderKind::GithubCopilot, Some(url)) if !url.is_empty() => {
            validate_http_base_url(name, url)?;
            url.trim_end_matches('/').to_string()
        }
        (ProviderKind::GithubCopilot, url) => url.clone().unwrap_or_default().trim_end_matches('/').to_string(),
        (_, Some(url)) => {
            validate_http_base_url(name, url)?;
            url.trim_end_matches('/').to_string()
        }
        (_, None) => bail!("provider {name:?} has no base_url"),
    };
    let api_key = match (&config.api_key, &config.api_key_env) {
        (Some(key), _) => Some(key.clone()),
        (None, Some(var)) => std::env::var(var).ok().filter(|v| !v.is_empty()),
        (None, None) => None,
    };
    let api_key = match (api_key, &config.api_key_command) {
        (Some(key), _) => Some(key),
        (None, Some(command)) => Some(run_key_command(name, command, cancel)?),
        (None, None) => None,
    };
    let extra_body = match &config.extra_body {
        Some(table) => {
            serde_json::to_value(table).context("provider extra_body")?.as_object().cloned().unwrap_or_default()
        }
        None => Default::default(),
    };
    let defaults = RetryPolicy::default();
    // Copilot reasoning models (Responses-routed GPT‑5+/Grok/…) require their
    // reasoning items replayed across tool calls, so replay defaults on for
    // them; a user config value still overrides this.
    let replay_reasoning = config
        .replay_reasoning
        .unwrap_or_else(|| kind == ProviderKind::GithubCopilot && github_copilot::is_reasoning_model(&model));
    Ok(ResolvedProvider {
        name: name.to_string(),
        kind,
        base_url,
        api_key,
        model,
        headers: config.headers.clone(),
        extra_body,
        drop_params: config.drop_params.clone().unwrap_or_default(),
        max_tokens_param: config.max_tokens_param.clone().unwrap_or_else(|| "max_tokens".into()),
        stream: config.stream.unwrap_or(true),
        replay_reasoning,
        timeout: Duration::from_secs(config.timeout_secs.unwrap_or(600)),
        retry: RetryPolicy {
            max_retries: config.max_retries.unwrap_or(defaults.max_retries),
            initial_backoff: config
                .retry_initial_backoff_ms
                .map(Duration::from_millis)
                .unwrap_or(defaults.initial_backoff),
            max_backoff: config.retry_max_backoff_ms.map(Duration::from_millis).unwrap_or(defaults.max_backoff),
        },
        retryable_statuses: config
            .retryable_statuses
            .clone()
            .unwrap_or_else(|| retry::DEFAULT_RETRYABLE_STATUSES.to_vec()),
    })
}

/// Upper bound on how long an `api_key_command` may run before it is killed.
/// A key lookup should be near-instant; without a bound a command that hangs
/// (e.g. a credential helper waiting on a prompt that never comes) would freeze
/// every client build — and, for a mid-turn `/model` switch, wedge the turn —
/// indefinitely. Generous enough for a real network round-trip, short enough
/// that a genuine hang is recovered from.
const KEY_COMMAND_TIMEOUT: Duration = Duration::from_secs(120);
/// Poll granularity while waiting for the key command to exit.
const KEY_COMMAND_POLL: Duration = Duration::from_millis(50);
/// Grace period, measured from the leader's exit, to let the reader threads
/// drain the pipes before we force EOF. A well-behaved (even backgrounded)
/// writer closes the pipes within this window; a descendant that keeps a pipe
/// open past it is torn down so the already-captured key is returned rather
/// than discarded.
const KEY_COMMAND_DRAIN_GRACE: Duration = Duration::from_millis(200);

fn run_key_command(provider: &str, command: &str, cancel: Option<&Arc<AtomicBool>>) -> Result<String> {
    run_key_command_bounded(provider, command, KEY_COMMAND_TIMEOUT, cancel)
}

/// Run `command` to produce an api key, bounded by `timeout` and by `cancel`.
///
/// The child is spawned (not `output()`-ed) so it can be killed: the wait loop
/// polls `try_wait` and, on either timeout or a set `cancel` flag, kills the
/// child and its wait returns an error rather than blocking forever. stdout and
/// stderr are drained on dedicated threads so a command that writes more than a
/// pipe buffer cannot deadlock against the wait loop (it would otherwise block
/// on write, never exit, and be killed as a false timeout).
///
/// The child runs in its own process group (`process_group(0)`) and is killed
/// with `killpg`, not `child.kill()`: killing only the `sh` leader would leave
/// descendants it spawned (e.g. the `sleep` in `sleep 30; printf sk`) holding
/// the stdout/stderr pipes open, so the reader-thread joins below would block
/// until those grandchildren exit — defeating the timeout/cancellation. Killing
/// the whole group tears the descendants down too, so the pipes hit EOF and the
/// joins return promptly.
fn run_key_command_bounded(
    provider: &str,
    command: &str,
    timeout: Duration,
    cancel: Option<&Arc<AtomicBool>>,
) -> Result<String> {
    let mut child = std::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        // Own process group so a kill reaches descendants, not just the shell.
        .process_group(0)
        .spawn()
        .with_context(|| format!("provider {provider:?}: running api_key_command {command:?}"))?;
    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();
    // Each reader signals completion via a shared flag so the wait loop can
    // poll whether the pipes have drained (hit EOF) without blocking on a
    // `join`: a descendant that outlives the `sh` leader keeps its inherited
    // pipe open, so an unconditional join after the leader exits would block
    // until that descendant finishes — ignoring the timeout/cancellation.
    let stdout_done = Arc::new(AtomicBool::new(false));
    let stderr_done = Arc::new(AtomicBool::new(false));
    let stdout_done_flag = stdout_done.clone();
    let stdout_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(pipe) = stdout_pipe.as_mut() {
            let _ = pipe.read_to_end(&mut buf);
        }
        stdout_done_flag.store(true, Ordering::SeqCst);
        buf
    });
    let stderr_done_flag = stderr_done.clone();
    let stderr_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(pipe) = stderr_pipe.as_mut() {
            let _ = pipe.read_to_end(&mut buf);
        }
        stderr_done_flag.store(true, Ordering::SeqCst);
        buf
    });
    // Kill the whole process group (not just the `sh` leader) and reap so
    // neither the shell nor any descendant can linger, then drain the reader
    // threads (the pipes hit EOF once the group is gone).
    fn kill_group_and_reap(
        child: &mut std::process::Child,
        stdout_reader: std::thread::JoinHandle<Vec<u8>>,
        stderr_reader: std::thread::JoinHandle<Vec<u8>>,
    ) {
        // SAFETY: killpg only signals the child's own process group.
        unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
        let _ = child.wait();
        let _ = stdout_reader.join();
        let _ = stderr_reader.join();
    }
    let start = Instant::now();
    let mut leader_status: Option<std::process::ExitStatus> = None;
    let mut leader_exit_at: Option<Instant> = None;
    let status = loop {
        // Reap the leader once it exits, but keep polling: a backgrounded
        // descendant (e.g. the `sleep` in `printf sk; sleep 30 &`) can outlive
        // the leader while holding the pipes open.
        if leader_status.is_none() {
            let waited = child
                .try_wait()
                .with_context(|| format!("provider {provider:?}: waiting on api_key_command {command:?}"));
            match waited {
                Ok(Some(status)) => {
                    leader_status = Some(status);
                    leader_exit_at = Some(Instant::now());
                }
                Ok(None) => {}
                Err(e) => {
                    // Can't tell whether the child is alive; kill the whole
                    // process group and reap so neither it nor any descendant
                    // can linger, then surface the wait error.
                    kill_group_and_reap(&mut child, stdout_reader, stderr_reader);
                    return Err(e);
                }
            }
        }
        let readers_done = stdout_done.load(Ordering::SeqCst) && stderr_done.load(Ordering::SeqCst);
        let cancelled = cancel.is_some_and(|flag| flag.load(Ordering::SeqCst));
        let timed_out = start.elapsed() >= timeout;
        if let Some(status) = leader_status {
            // The leader has exited, so everything it wrote to stdout is already
            // buffered in the pipe — the key, if any, is captured. Return as
            // soon as the readers drain naturally. If instead a backgrounded
            // descendant keeps a pipe open (so the readers never hit EOF), don't
            // block on it or discard the captured key: once a short drain grace
            // elapses (or the timeout fires), tear the whole group down to force
            // EOF so the post-loop joins return the captured output promptly. An
            // explicit cancel still aborts, even with a key in hand.
            if cancelled {
                kill_group_and_reap(&mut child, stdout_reader, stderr_reader);
                bail!("provider {provider:?}: api_key_command {command:?} cancelled");
            }
            let drain_grace_elapsed = leader_exit_at.is_some_and(|t| t.elapsed() >= KEY_COMMAND_DRAIN_GRACE);
            if readers_done || drain_grace_elapsed || timed_out {
                if !readers_done {
                    // A descendant still holds a pipe open; close it so the
                    // reader threads hit EOF and the post-loop joins return the
                    // already-captured output promptly.
                    // SAFETY: killpg only signals the child's own process group.
                    unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
                    let _ = child.wait();
                }
                break status;
            }
        } else if cancelled || timed_out {
            // The leader is still running and we've hit the deadline: kill the
            // whole process group (not just the `sh` leader) and reap so no
            // descendant can linger, then surface the timeout/cancellation.
            kill_group_and_reap(&mut child, stdout_reader, stderr_reader);
            if cancelled {
                bail!("provider {provider:?}: api_key_command {command:?} cancelled");
            }
            bail!("provider {provider:?}: api_key_command {command:?} timed out after {}s", timeout.as_secs());
        }
        std::thread::sleep(KEY_COMMAND_POLL);
    };
    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    let key = String::from_utf8_lossy(&stdout).trim().to_string();
    if !status.success() || key.is_empty() {
        bail!(
            "provider {provider:?}: api_key_command {command:?} failed ({}): {}",
            status,
            String::from_utf8_lossy(&stderr).trim()
        );
    }
    Ok(key)
}

/// Build a client for a model spec.
/// Client for listing a provider's models; the spec may name just the
/// provider even when it has no `default_model`.
pub fn build_lister(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
) -> Result<Box<dyn LLMClient>> {
    let providers = effective_providers(user);
    let (name, model) = parse_model_spec(spec, &providers, default_provider);
    if model.is_none() && providers.get(name).is_some_and(|p| p.default_model.is_none()) {
        return build_client(&format!("{name}/list-models"), user, default_provider);
    }
    build_client(spec, user, default_provider)
}

pub fn build_client(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
) -> Result<Box<dyn LLMClient>> {
    build_client_cancellable(spec, user, default_provider, None)
}

/// Like [`build_client`], but a running `api_key_command` honours `cancel`: the
/// child is killed and the build fails fast when the flag flips, so a mid-turn
/// `/model` switch whose key command hangs cannot wedge the turn. `cancel` is
/// `None` for build paths with no turn to cancel against.
pub fn build_client_cancellable(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
    cancel: Option<&Arc<AtomicBool>>,
) -> Result<Box<dyn LLMClient>> {
    let resolved = resolve_cancellable(spec, user, default_provider, cancel)?;
    Ok(match resolved.kind {
        ProviderKind::Openai => Box::new(openai::OpenAiClient::new(resolved)?),
        ProviderKind::Anthropic => Box::new(anthropic::AnthropicClient::new(resolved)?),
        ProviderKind::GithubCopilot => Box::new(github_copilot::GithubCopilotClient::new(resolved)?),
        ProviderKind::Mock => Box::new(mock::MockLLMClient::new(&resolved.model)),
    })
}

/// Shared JSON-over-HTTP transport with retries.
#[derive(Clone)]
pub(crate) struct HttpTransport {
    client: reqwest::Client,
    provider: ResolvedProvider,
}

/// A step in consuming a server-sent event stream, handed to the `on_data`
/// callback of [`HttpTransport::post_stream_to`].
pub(crate) enum StreamAction<'a> {
    /// A decoded `data:` payload to process. The callback returns `true` once
    /// it has delivered visible output (text/thinking) to the caller.
    Data(&'a str),
    /// The stream is about to be restarted after a transient failure; discard
    /// any attempt-local accumulator state so buffered deltas are not
    /// duplicated on the retry.
    Reset,
}

impl HttpTransport {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        let client = reqwest::Client::builder()
            // An *idle* timeout: it resets on every received byte, so a slow but
            // steady stream (e.g. a local model emitting a few tokens/second) is
            // never cut off mid-response — only a genuinely stalled connection
            // (no data for `provider.timeout`) trips it. A total request deadline
            // would kill long, healthy streams by wall-clock alone.
            .read_timeout(provider.timeout)
            .connect_timeout(Duration::from_secs(30))
            .build()
            .context("build HTTP client")?;
        Ok(Self { client, provider })
    }

    pub fn provider(&self) -> &ResolvedProvider {
        &self.provider
    }

    /// Apply `extra_body` and `drop_params` to a request body.
    pub fn finish_body(&self, mut body: Value) -> Value {
        if let Some(object) = body.as_object_mut() {
            for (key, value) in &self.provider.extra_body {
                object.insert(key.clone(), value.clone());
            }
            for key in &self.provider.drop_params {
                object.remove(key);
            }
        }
        body
    }

    /// Mark a finished body as a streaming request.
    pub fn stream_body(&self, mut body: Value, extra: Value) -> Value {
        if let (Some(object), Value::Object(extra)) = (body.as_object_mut(), extra) {
            object.extend(extra);
            for key in &self.provider.drop_params {
                object.remove(key);
            }
        }
        body
    }

    /// POST `body` to `{base_url}{path}`, retrying transient failures.
    /// `auth` adds provider-specific authentication headers.
    pub async fn post_json(
        &self,
        path: &str,
        body: &Value,
        auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<Value> {
        let url = format!("{}{}", self.provider.base_url, path);
        self.post_json_to(&url, body, auth).await
    }

    pub fn http(&self) -> &reqwest::Client {
        &self.client
    }

    /// POST `body` to an absolute `url`, retrying transient failures.
    pub async fn post_json_to(
        &self,
        url: &str,
        body: &Value,
        auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Result<Value> {
        let policy = &self.provider.retry;
        let mut attempt = 0;
        loop {
            let mut request = self.client.post(url).json(body);
            for (name, value) in &self.provider.headers {
                request = request.header(name, value);
            }
            let outcome = auth(request).send().await;
            let (err, retry_after): (anyhow::Error, Option<String>) = 'failed: {
                match outcome {
                    Ok(response) => {
                        let status = response.status().as_u16();
                        let retry_after = response
                            .headers()
                            .get(reqwest::header::RETRY_AFTER)
                            .and_then(|v| v.to_str().ok())
                            .map(str::to_string);
                        let text = match response.text().await {
                            Ok(text) => text,
                            // The body was cut off (reset, timeout): transient like a send error.
                            Err(e) => {
                                let e = anyhow!(e).context(format!("reading HTTP {status} response body"));
                                if attempt >= policy.max_retries {
                                    return Err(self.wrap(e));
                                }
                                break 'failed (e, retry_after);
                            }
                        };
                        if (200..300).contains(&status) {
                            match serde_json::from_str::<Value>(&text) {
                                Ok(value) if value.get("error").is_some_and(|e| !e.is_null()) => {
                                    let api = ApiError::from_body(status, &text);
                                    if attempt >= policy.max_retries
                                        || !retry::retryable(&api, &self.provider.retryable_statuses)
                                    {
                                        return Err(self.wrap(api.into()));
                                    }
                                    (api.into(), retry_after)
                                }
                                Ok(value) => return Ok(value),
                                Err(e) => {
                                    return Err(self.wrap(anyhow!(
                                        "invalid JSON response ({e}): {}",
                                        text.chars().take(500).collect::<String>()
                                    )));
                                }
                            }
                        } else {
                            let api = ApiError::from_body(status, &text);
                            if attempt >= policy.max_retries
                                || !retry::retryable(&api, &self.provider.retryable_statuses)
                            {
                                return Err(self.wrap(api.into()));
                            }
                            (api.into(), retry_after)
                        }
                    }
                    Err(e) => {
                        // Connection resets, timeouts, DNS: transient by assumption.
                        if attempt >= policy.max_retries || e.is_builder() {
                            return Err(self.wrap(anyhow!(e)));
                        }
                        (anyhow!(e), None)
                    }
                }
            };
            let api = err.downcast_ref::<ApiError>();
            let delay =
                retry::retry_delay(policy, attempt, api, retry_after.as_deref(), chrono::Utc::now(), fastrand::f64());
            eprintln!(
                "[provider {}] attempt {} failed: {err}; retrying in {:.1}s",
                self.provider.name,
                attempt + 1,
                delay.as_secs_f64()
            );
            tokio::time::sleep(delay).await;
            attempt += 1;
        }
    }

    /// POST `body` expecting server-sent events; each `data:` payload is handed
    /// to `on_data` as [`StreamAction::Data`], which returns `true` once it has
    /// delivered *visible* output to the caller's sink (text/thinking) rather
    /// than merely consuming metadata-only events (role, usage, tool-call
    /// deltas). Failures before the stream starts are retried like
    /// `post_json_to`. A mid-stream failure (e.g. a transient connection reset
    /// or timeout) is retried the same way *as long as no visible output has
    /// reached the caller yet* — restarting after visible output would
    /// duplicate it, so once any is delivered the error is returned. Before
    /// each retry `on_data` is invoked with [`StreamAction::Reset`] so it can
    /// discard attempt-local accumulator state and avoid duplicating buffered
    /// deltas on the restarted stream. If the server answers with plain JSON
    /// instead, that value is returned.
    pub async fn post_stream_to(
        &self,
        url: &str,
        body: &Value,
        auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
        on_data: &mut (dyn FnMut(StreamAction<'_>) -> Result<bool> + Send),
    ) -> Result<Option<Value>> {
        let policy = &self.provider.retry;
        let mut attempt = 0;
        loop {
            let mut request = self.client.post(url).json(body).header(reqwest::header::ACCEPT, "text/event-stream");
            for (name, value) in &self.provider.headers {
                request = request.header(name, value);
            }
            let (err, retry_after): (anyhow::Error, Option<String>) = match auth(request).send().await {
                Ok(mut response) => {
                    let status = response.status().as_u16();
                    let retry_after = response
                        .headers()
                        .get(reqwest::header::RETRY_AFTER)
                        .and_then(|v| v.to_str().ok())
                        .map(str::to_string);
                    let is_sse = response
                        .headers()
                        .get(reqwest::header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .is_some_and(|v| v.contains("event-stream"));
                    if (200..300).contains(&status) && is_sse {
                        let mut parser = SseParser::default();
                        let mut emitted = false;
                        let stream_err = loop {
                            match response.chunk().await {
                                Ok(Some(chunk)) => {
                                    for data in parser.push(&chunk) {
                                        if data.trim() == "[DONE]" {
                                            return Ok(None);
                                        }
                                        if on_data(StreamAction::Data(&data)).map_err(|e| self.wrap(e))? {
                                            emitted = true;
                                        }
                                    }
                                }
                                Ok(None) => {
                                    if let Some(data) = parser.finish()
                                        && data.trim() != "[DONE]"
                                    {
                                        on_data(StreamAction::Data(&data)).map_err(|e| self.wrap(e))?;
                                    }
                                    return Ok(None);
                                }
                                // Connection reset/timeout mid-stream: transient.
                                Err(e) => break anyhow!(e).context("reading response stream"),
                            }
                        };
                        // Retry only if we haven't handed any *visible* output
                        // to the caller yet; otherwise a restart would duplicate
                        // it. Metadata-only events (role/usage/tool-call deltas)
                        // do not count as visible output.
                        if emitted || attempt >= policy.max_retries {
                            return Err(self.wrap(stream_err));
                        }
                        (stream_err, retry_after)
                    } else {
                        match response.text().await {
                            Err(e) => (anyhow!(e).context(format!("reading HTTP {status} response body")), retry_after),
                            Ok(text) if (200..300).contains(&status) => {
                                return match serde_json::from_str::<Value>(&text) {
                                    Ok(value) if value.get("error").is_some_and(|e| !e.is_null()) => {
                                        Err(self.wrap(ApiError::from_body(status, &text).into()))
                                    }
                                    Ok(value) => Ok(Some(value)),
                                    Err(e) => Err(self.wrap(anyhow!(
                                        "invalid response ({e}): {}",
                                        text.chars().take(500).collect::<String>()
                                    ))),
                                };
                            }
                            Ok(text) => {
                                let api = ApiError::from_body(status, &text);
                                if !retry::retryable(&api, &self.provider.retryable_statuses) {
                                    return Err(self.wrap(api.into()));
                                }
                                (api.into(), retry_after)
                            }
                        }
                    }
                }
                Err(e) if e.is_builder() => return Err(self.wrap(anyhow!(e))),
                Err(e) => (anyhow!(e), None),
            };
            if attempt >= policy.max_retries {
                return Err(self.wrap(err));
            }
            // Discard attempt-local accumulator state before retrying so the
            // restarted stream is re-read from scratch without duplicating any
            // deltas buffered during the failed attempt.
            on_data(StreamAction::Reset).map_err(|e| self.wrap(e))?;
            let delay = retry::retry_delay(
                policy,
                attempt,
                err.downcast_ref::<ApiError>(),
                retry_after.as_deref(),
                chrono::Utc::now(),
                fastrand::f64(),
            );
            eprintln!(
                "[provider {}] attempt {} failed: {err}; retrying in {:.1}s",
                self.provider.name,
                attempt + 1,
                delay.as_secs_f64()
            );
            tokio::time::sleep(delay).await;
            attempt += 1;
        }
    }

    fn wrap(&self, err: anyhow::Error) -> anyhow::Error {
        err.context(format!(
            "provider {:?} ({}) request for model {:?} failed",
            self.provider.name, self.provider.base_url, self.provider.model
        ))
    }
}

/// Incremental server-sent-events parser yielding each event's `data`.
#[derive(Debug, Default)]
pub(crate) struct SseParser {
    buffer: Vec<u8>,
    data: Vec<String>,
}

impl SseParser {
    pub fn push(&mut self, bytes: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(bytes);
        let mut events = Vec::new();
        while let Some(end) = self.buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end_matches(['\n', '\r']);
            if line.is_empty() {
                if !self.data.is_empty() {
                    events.push(std::mem::take(&mut self.data).join("\n"));
                }
            } else if let Some(value) = line.strip_prefix("data:") {
                self.data.push(value.strip_prefix(' ').unwrap_or(value).to_string());
            }
        }
        events
    }

    pub fn finish(&mut self) -> Option<String> {
        if !self.buffer.is_empty() {
            let rest = std::mem::take(&mut self.buffer);
            let line = String::from_utf8_lossy(&rest);
            if let Some(value) = line.trim_end().strip_prefix("data:") {
                self.data.push(value.trim_start().to_string());
            }
        }
        (!self.data.is_empty()).then(|| std::mem::take(&mut self.data).join("\n"))
    }
}

#[cfg(test)]
mod sse_tests {
    use super::SseParser;

    #[test]
    fn parses_events_split_across_chunks() {
        let mut parser = SseParser::default();
        assert!(parser.push(b"event: x\ndata: {\"a\"").is_empty());
        assert_eq!(parser.push(b":1}\r\n\r\ndata: one\ndata: two\n\n: comment\n"), vec!["{\"a\":1}", "one\ntwo"]);
        assert!(parser.push(b"data: [DONE]").is_empty());
        assert_eq!(parser.finish().as_deref(), Some("[DONE]"));
    }
}

#[cfg(test)]
pub(crate) mod test_server {
    //! Minimal scripted HTTP server for provider tests.
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[derive(Clone, Debug)]
    pub struct Captured {
        pub path: String,
        pub headers: String,
        pub body: serde_json::Value,
    }

    /// Serve each `(status, extra_headers, body)` in turn; returns base URL and captured requests.
    pub async fn serve(responses: Vec<(u16, &'static str, String)>) -> (String, Arc<Mutex<Vec<Captured>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let captured = Arc::new(Mutex::new(Vec::new()));
        let log = captured.clone();
        tokio::spawn(async move {
            for (status, extra, body) in responses {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let (head_end, content_length) = loop {
                    let n = socket.read(&mut chunk).await.unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..pos]).to_lowercase();
                        let length = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .map(|v| v.trim().parse::<usize>().unwrap())
                            .unwrap_or(0);
                        break (pos + 4, length);
                    }
                };
                while buf.len() < head_end + content_length {
                    let n = socket.read(&mut chunk).await.unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                }
                let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                let path = head.split_whitespace().nth(1).unwrap_or("").to_string();
                let request_body = serde_json::from_slice(&buf[head_end..head_end + content_length])
                    .unwrap_or(serde_json::Value::Null);
                log.lock().unwrap().push(Captured { path, headers: head, body: request_body });
                // `x-truncate` advertises more body than is sent, simulating a cut-off response.
                let advertised = body.len() + if extra.contains("x-truncate") { 100 } else { 0 };
                let content_type =
                    if extra.contains("content-type") { "" } else { "content-type: application/json\r\n" };
                let reply = format!(
                    "HTTP/1.1 {status} X\r\n{content_type}{extra}content-length: {advertised}\r\nconnection: close\r\n\r\n{body}"
                );
                socket.write_all(reply.as_bytes()).await.unwrap();
                socket.shutdown().await.ok();
            }
        });
        (format!("http://{addr}"), captured)
    }
}

#[cfg(test)]
mod key_command_tests {
    use super::*;

    fn with_command(command: &str) -> HashMap<String, ProviderConfig> {
        HashMap::from([(
            "cmd".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some("http://localhost:1".into()),
                api_key_command: Some(command.into()),
                ..Default::default()
            },
        )])
    }

    #[test]
    fn api_key_command_supplies_key() {
        let resolved = resolve("cmd/m", &with_command("printf '  sk-from-cmd\\n'"), "mock").unwrap();
        assert_eq!(resolved.api_key.as_deref(), Some("sk-from-cmd"));
    }

    #[test]
    fn failing_api_key_command_is_an_error() {
        let err = resolve("cmd/m", &with_command("echo nope >&2; exit 3"), "mock").unwrap_err();
        assert!(format!("{err:#}").contains("nope"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_returns_the_trimmed_key() {
        let key = run_key_command_bounded("cmd", "printf '  sk-ok\\n'", Duration::from_secs(5), None).unwrap();
        assert_eq!(key, "sk-ok");
    }

    #[test]
    fn bounded_key_command_times_out_and_kills_a_hung_command() {
        // A command that never exits must not block forever: the timeout fires,
        // the child is killed, and the error names the timeout — all promptly.
        let start = Instant::now();
        let err = run_key_command_bounded("cmd", "sleep 30", Duration::from_millis(100), None).unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "timed out slowly: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("timed out"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_timeout_kills_descendants_holding_the_pipes() {
        // Regression: `sleep 30; printf sk` makes `sh` FORK `sleep` (rather than
        // exec-replacing itself), so `sleep` inherits the stdout/stderr pipes.
        // Killing only the `sh` leader would leave `sleep` holding them open and
        // the reader-thread joins would block for the full 30s — defeating the
        // timeout. Killing the whole process group tears `sleep` down too, so
        // the pipes hit EOF and the call returns promptly.
        let start = Instant::now();
        let err =
            run_key_command_bounded("cmd", "sleep 30; printf sk", Duration::from_millis(100), None).unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "descendant blocked the join: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("timed out"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_cancel_kills_descendants_holding_the_pipes() {
        // As above, but via the cancel path: the forked `sleep` must be torn
        // down with the group so the reader joins do not block out the long
        // timeout.
        let cancel = Arc::new(AtomicBool::new(true));
        let start = Instant::now();
        let err = run_key_command_bounded("cmd", "sleep 30; printf sk", Duration::from_secs(600), Some(&cancel))
            .unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "descendant blocked the join: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("cancelled"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_returns_captured_key_after_the_leader_exits() {
        // Regression: `printf sk; sleep 30 &` makes `sh` write the key in the
        // foreground and then exit IMMEDIATELY (the `sleep` is backgrounded),
        // so the leader `try_wait` returns Some right away — but the
        // backgrounded `sleep` still holds the stdout/stderr pipes open.
        // Joining the reader threads unconditionally at that point would block
        // for the full 30s; discarding the captured key on timeout (an earlier
        // regression) would throw away a perfectly good key. The wait loop must
        // instead tear the whole process group down to force EOF and return the
        // already-captured key promptly, well inside the timeout.
        let start = Instant::now();
        let key =
            run_key_command_bounded("cmd", "printf sk; sleep 30 &", Duration::from_millis(100), None).unwrap();
        assert_eq!(key, "sk");
        assert!(start.elapsed() < Duration::from_secs(10), "backgrounded descendant blocked the return: {:?}", start.elapsed());
    }

    #[test]
    fn bounded_key_command_returns_key_when_descendant_holds_pipe_before_the_key() {
        // The adversarial-finding shape: the key is printed in the foreground
        // AFTER a backgrounded descendant that keeps a pipe open past the
        // timeout. The leader still exits once the foreground `printf` is done,
        // the key is buffered, and it must come back rather than erroring just
        // because the descendant is still holding a pipe.
        let start = Instant::now();
        let key =
            run_key_command_bounded("cmd", "sleep 30 & printf sk-good", Duration::from_millis(100), None).unwrap();
        assert_eq!(key, "sk-good");
        assert!(start.elapsed() < Duration::from_secs(10), "backgrounded descendant blocked the return: {:?}", start.elapsed());
    }

    #[test]
    fn bounded_key_command_times_out_when_no_key_was_captured() {
        // A backgrounded descendant that holds the pipe open but where the
        // leader produced NO key must still fail: there is nothing to return, so
        // the group is torn down and the empty capture surfaces as a failure
        // rather than hanging on the descendant.
        let start = Instant::now();
        let err =
            run_key_command_bounded("cmd", "sleep 30 &", Duration::from_millis(100), None).unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "backgrounded descendant blocked the return: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("failed"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_cancel_applies_after_the_leader_exits() {
        // As above, but via the cancel path with a long timeout: the leader
        // exits immediately while the backgrounded `sleep` holds the pipes, so
        // only the cancel flag can end the wait — and it must do so promptly by
        // killing the whole process group.
        let cancel = Arc::new(AtomicBool::new(true));
        let start = Instant::now();
        let err = run_key_command_bounded("cmd", "sleep 30 & printf sk", Duration::from_secs(600), Some(&cancel))
            .unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "backgrounded descendant blocked the join: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("cancelled"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_backgrounded_success_returns_the_key() {
        // A backgrounded writer that FINISHES promptly must still yield its
        // key: the leader exits immediately, the pipes hit EOF once the
        // short-lived background `printf` closes them, and the call returns the
        // key without waiting for any timeout.
        let start = Instant::now();
        let key = run_key_command_bounded("cmd", "printf sk-ok &", Duration::from_secs(5), None).unwrap();
        assert_eq!(key, "sk-ok");
        assert!(start.elapsed() < Duration::from_secs(4), "took the slow path: {:?}", start.elapsed());
    }

    #[test]
    fn bounded_key_command_honours_cancellation_and_kills_the_child() {
        // With the cancel flag already set, a hung command is killed and the
        // build fails fast with a cancellation error rather than waiting out
        // the (here, long) timeout.
        let cancel = Arc::new(AtomicBool::new(true));
        let start = Instant::now();
        let err = run_key_command_bounded("cmd", "sleep 30", Duration::from_secs(600), Some(&cancel)).unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "cancelled slowly: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("cancelled"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_cancelled_mid_flight_is_killed() {
        // Flag starts clear and flips from another thread while the command is
        // running: the wait loop observes it, kills the child, and fails fast.
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            flag.store(true, Ordering::SeqCst);
        });
        let start = Instant::now();
        let err = run_key_command_bounded("cmd", "sleep 30", Duration::from_secs(600), Some(&cancel)).unwrap_err();
        assert!(start.elapsed() < Duration::from_secs(10), "cancelled slowly: {:?}", start.elapsed());
        assert!(format!("{err:#}").contains("cancelled"), "{err:#}");
    }

    #[test]
    fn bounded_key_command_drains_large_output_without_deadlock() {
        // A command that writes more than a pipe buffer (64KiB) must not
        // deadlock the wait loop: the reader threads drain concurrently, so the
        // command exits and the (trimmed) key comes back intact.
        let key = run_key_command_bounded(
            "cmd",
            "printf 'sk-'; yes x | head -c 200000 | tr -d '\\n'",
            Duration::from_secs(10),
            None,
        )
        .unwrap();
        assert!(key.starts_with("sk-x"), "unexpected key prefix: {}", &key[..key.len().min(8)]);
        assert!(key.len() > 64 * 1024, "drained well past a pipe buffer without deadlock: {} bytes", key.len());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_model_specs() {
        let providers = presets();
        assert_eq!(
            parse_model_spec("openrouter/anthropic/claude-sonnet-4.5", &providers, "openai"),
            ("openrouter", Some("anthropic/claude-sonnet-4.5"))
        );
        assert_eq!(parse_model_spec("ollama", &providers, "openai"), ("ollama", None));
        assert_eq!(parse_model_spec("gpt-4o-mini", &providers, "mock"), ("mock", Some("gpt-4o-mini")));
        assert_eq!(
            parse_model_spec("meta-llama/llama-4", &providers, "together"),
            ("together", Some("meta-llama/llama-4"))
        );
    }

    #[test]
    fn validate_spec_matches_resolve_for_the_buildable_cases() {
        let providers = effective_providers(&HashMap::new());
        // A buildable spec passes validation and also resolves.
        assert!(validate_spec("mock/anything", &providers, "mock").is_ok());
        assert!(resolve("mock/anything", &HashMap::new(), "mock").is_ok());
        // A provider that cannot build a client (openai kind, no base_url) is
        // rejected the same way by both, so queue-time validation never queues
        // a spec that would only fail (silently, pre-fix) at the next model call.
        let mut user = HashMap::new();
        user.insert(
            "broken".to_string(),
            ProviderConfig { kind: Some(ProviderKind::Openai), default_model: Some("m".into()), ..Default::default() },
        );
        let providers = effective_providers(&user);
        let err = validate_spec("broken/x", &providers, "mock").unwrap_err().to_string();
        assert!(err.contains("base_url"), "{err}");
        assert!(resolve("broken/x", &user, "mock").is_err());
    }

    #[test]
    fn validate_spec_rejects_a_provider_without_a_model() {
        // A user provider with a kind and base_url but no default model, and a
        // bare spec that supplies none, must be rejected (not silently queued).
        let mut user = HashMap::new();
        user.insert(
            "bare".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some("http://localhost:9/v1".into()),
                ..Default::default()
            },
        );
        let providers = effective_providers(&user);
        let err = validate_spec("bare", &providers, "mock").unwrap_err().to_string();
        assert!(err.contains("no model"), "{err}");
    }

    #[test]
    fn validate_spec_rejects_an_empty_or_malformed_base_url() {
        // An HTTP provider whose base_url is *present* but empty/whitespace,
        // unparseable, or non-http(s) must be rejected at queue time by BOTH
        // `validate_spec` and `resolve`: `Some(_)` and `HttpTransport::new`
        // accept it, so without parsing it a mid-turn switch would replace the
        // working client and only fail later while building the request URL
        // (losing the current model). Each variant is its own occurrence of the
        // same fail-open class.
        let mut user = HashMap::new();
        for (name, url) in [
            ("empty", "   "),
            ("bad", "not a url"),
            ("ftp", "ftp://host/v1"),
            ("nohost", "http://"),
            // Leading/trailing whitespace and control characters are stripped
            // by the URL parser but kept verbatim by `resolve`, so they must be
            // rejected too — otherwise they pass validation yet break later at
            // request-build time (same fail-open class).
            ("lead_space", " http://host/v1"),
            ("trail_newline", "http://host/v1\n"),
            ("inner_tab", "http://ho\tst/v1"),
            ("control", "http://host/v1\u{0001}"),
            // A query or fragment makes the string-appended request URL
            // unusable (the API path lands in the query / the fragment is
            // dropped), so both must be rejected too — same fail-open class.
            ("query", "https://host/v1?token=x"),
            ("fragment", "https://host/v1#frag"),
        ] {
            user.insert(
                name.to_string(),
                ProviderConfig {
                    kind: Some(ProviderKind::Openai),
                    default_model: Some("m".into()),
                    base_url: Some(url.into()),
                    ..Default::default()
                },
            );
        }
        let providers = effective_providers(&user);
        for name in [
            "empty",
            "bad",
            "ftp",
            "nohost",
            "lead_space",
            "trail_newline",
            "inner_tab",
            "control",
            "query",
            "fragment",
        ] {
            let spec = format!("{name}/x");
            assert!(validate_spec(&spec, &providers, "mock").is_err(), "validate_spec accepted {name}");
            assert!(resolve(&spec, &user, "mock").is_err(), "resolve accepted {name}");
        }
        // A well-formed endpoint still passes both, unchanged.
        let mut ok = HashMap::new();
        ok.insert(
            "good".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                default_model: Some("m".into()),
                base_url: Some("http://localhost:9/v1".into()),
                ..Default::default()
            },
        );
        let providers = effective_providers(&ok);
        assert!(validate_spec("good/x", &providers, "mock").is_ok());
        assert!(resolve("good/x", &ok, "mock").is_ok());
    }

    #[test]
    fn copilot_endpoint_override_is_validated_when_present() {
        // A GitHub Copilot provider derives its endpoint from the session token
        // when `base_url` is absent/empty, but a *present non-empty* override is
        // used verbatim by `GithubCopilotClient::api_base`. Both `validate_spec`
        // and `resolve` must reject a malformed override (rather than exempting
        // every Copilot base_url), or a bad override passes queue-time
        // validation and only fails on the next request.
        for (name, url) in [
            ("malformed", "not a url"),
            ("non-http", "ftp://host/v1"),
            ("query", "https://host/v1?token=x"),
            ("whitespace", " https://host/v1"),
            // A whitespace-only override is *not* empty to `api_base`'s
            // `configured.is_empty()` test, so it is used verbatim
            // (`format!("{}{}", "   ", path)` -> a broken endpoint). It must be
            // rejected here too, not exempted by a trimming guard — otherwise it
            // passes queue-time validation and fails only on the next request.
            ("whitespace-only", "   "),
        ] {
            let mut user = HashMap::new();
            user.insert(
                "github-copilot".to_string(),
                ProviderConfig { base_url: Some(url.into()), ..Default::default() },
            );
            let providers = effective_providers(&user);
            let spec = "github-copilot/gpt-4.1";
            assert!(
                validate_spec(spec, &providers, "github-copilot").is_err(),
                "validate_spec accepted {name} override"
            );
            assert!(resolve(spec, &user, "github-copilot").is_err(), "resolve accepted {name} override");
        }
        // A well-formed override passes both, and an absent/empty override still
        // derives from the session token (no validation, no error).
        let mut user = HashMap::new();
        user.insert(
            "github-copilot".to_string(),
            ProviderConfig { base_url: Some("https://copilot.example.com/v1".into()), ..Default::default() },
        );
        let providers = effective_providers(&user);
        assert!(validate_spec("github-copilot/gpt-4.1", &providers, "github-copilot").is_ok());
        let resolved = resolve("github-copilot/gpt-4.1", &user, "github-copilot").unwrap();
        assert_eq!(resolved.base_url, "https://copilot.example.com/v1");
        // Absent override -> derived (empty stored base_url), valid.
        assert!(
            validate_spec("github-copilot/gpt-4.1", &effective_providers(&HashMap::new()), "github-copilot").is_ok()
        );
    }

    #[test]
    fn copilot_reasoning_models_default_to_reasoning_replay() {
        let user = HashMap::new();
        // A reasoning model (Responses-routed GPT‑5+) turns replay on by default.
        assert!(resolve("github-copilot/gpt-6-astra", &user, "mock").unwrap().replay_reasoning);
        // A non-reasoning Copilot model leaves replay off.
        assert!(!resolve("github-copilot/gpt-4.1", &user, "mock").unwrap().replay_reasoning);
        assert!(!resolve("github-copilot/o4-mini", &user, "mock").unwrap().replay_reasoning);
        // An explicit config value still overrides the reasoning-model default.
        let mut off = HashMap::new();
        off.insert(
            "github-copilot".to_string(),
            ProviderConfig { replay_reasoning: Some(false), ..Default::default() },
        );
        assert!(!resolve("github-copilot/gpt-6-astra", &off, "mock").unwrap().replay_reasoning);
    }

    #[test]
    fn qwen_and_kimi_presets() {
        let user = HashMap::new();
        let qwen = resolve("qwen/qwen3.8-max", &user, "mock").unwrap();
        assert_eq!(qwen.base_url, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1");
        assert!(!qwen.replay_reasoning);
        let kimi = resolve("kimi/kimi-k3", &user, "mock").unwrap();
        assert_eq!((kimi.base_url.as_str(), kimi.model.as_str()), ("https://api.moonshot.ai/v1", "kimi-k3"));
        assert!(kimi.replay_reasoning);
        assert_eq!(kimi.drop_params, vec!["temperature"]);
        assert_eq!(kimi.max_tokens_param, "max_completion_tokens");
        assert_eq!(presets()["kimi"].api_key_env.as_deref(), Some("MOONSHOT_API_KEY"));
        assert_eq!(presets()["qwen"].api_key_env.as_deref(), Some("DASHSCOPE_API_KEY"));
    }

    #[test]
    fn user_config_overrides_and_extends_presets() {
        let mut user = HashMap::new();
        user.insert(
            "ollama".to_string(),
            ProviderConfig {
                base_url: Some("http://merlin.local:11434/v1/".into()),
                default_model: Some("qwen3:8b".into()),
                ..Default::default()
            },
        );
        user.insert(
            "ds4".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some("http://localhost:8100/v1".into()),
                extra_body: Some(toml::from_str("think = false").unwrap()),
                ..Default::default()
            },
        );
        let ollama = resolve("ollama", &user, "mock").unwrap();
        assert_eq!(ollama.base_url, "http://merlin.local:11434/v1");
        assert_eq!(ollama.model, "qwen3:8b");
        assert_eq!(ollama.kind, ProviderKind::Openai);

        let ds4 = resolve("ds4/qwen3.8-flash-next", &user, "mock").unwrap();
        assert_eq!(ds4.model, "qwen3.8-flash-next");
        assert_eq!(ds4.extra_body.get("think"), Some(&Value::Bool(false)));

        let openai = resolve("openai/gpt-5", &user, "mock").unwrap();
        assert_eq!(openai.max_tokens_param, "max_completion_tokens");

        assert!(resolve("nope/x", &HashMap::new(), "missing").is_err());
    }
}
