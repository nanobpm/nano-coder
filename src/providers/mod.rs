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
pub mod retry;

use std::collections::{BTreeMap, HashMap};
use std::time::Duration;

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
    pub timeout_secs: Option<u64>,
    pub max_retries: Option<u32>,
    pub retry_initial_backoff_ms: Option<u64>,
    pub retry_max_backoff_ms: Option<u64>,
    pub retryable_statuses: Option<Vec<u16>>,
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
            kind, base_url, api_key, api_key_env, api_key_command, default_model, extra_body, drop_params,
            max_tokens_param, context_window, stream, timeout_secs, max_retries, retry_initial_backoff_ms,
            retry_max_backoff_ms, retryable_statuses
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
    add("fireworks", ProviderConfig::preset(Openai, "https://api.fireworks.ai/inference/v1", Some("FIREWORKS_API_KEY")));
    add("groq", ProviderConfig::preset(Openai, "https://api.groq.com/openai/v1", Some("GROQ_API_KEY")));
    add("together", ProviderConfig::preset(Openai, "https://api.together.xyz/v1", Some("TOGETHER_API_KEY")));
    add("deepseek", ProviderConfig::preset(Openai, "https://api.deepseek.com/v1", Some("DEEPSEEK_API_KEY")));
    add("mistral", ProviderConfig::preset(Openai, "https://api.mistral.ai/v1", Some("MISTRAL_API_KEY")));
    add(
        "gemini",
        ProviderConfig::preset(Openai, "https://generativelanguage.googleapis.com/v1beta/openai", Some("GEMINI_API_KEY")),
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
    add("ollama", ProviderConfig::preset(Openai, "http://localhost:11434/v1", None));
    add("llamacpp", ProviderConfig::preset(Openai, "http://localhost:8080/v1", None));
    add(
        "mock",
        ProviderConfig {
            kind: Some(Mock),
            default_model: Some("mock".into()),
            ..Default::default()
        },
    );
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
    let model = model
        .map(str::to_string)
        .or_else(|| provider.and_then(|p| p.default_model.clone()))
        .unwrap_or_default();
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
    pub timeout: Duration,
    pub retry: RetryPolicy,
    pub retryable_statuses: Vec<u16>,
}

pub fn resolve(
    spec: &str,
    user: &HashMap<String, ProviderConfig>,
    default_provider: &str,
) -> Result<ResolvedProvider> {
    let providers = effective_providers(user);
    let (name, model) = parse_model_spec(spec, &providers, default_provider);
    let config = providers.get(name).ok_or_else(|| {
        anyhow!(
            "unknown provider {name:?} for model {spec:?}; known providers: {}",
            providers.keys().cloned().collect::<Vec<_>>().join(", ")
        )
    })?;
    let kind = config
        .kind
        .ok_or_else(|| anyhow!("provider {name:?} has no `kind` (openai, anthropic, or mock)"))?;
    let model = model
        .map(str::to_string)
        .or_else(|| config.default_model.clone())
        .ok_or_else(|| anyhow!("no model given for provider {name:?} and it has no default_model"))?;
    let base_url = match (kind, &config.base_url) {
        // Copilot derives its endpoint from the session token unless overridden.
        (ProviderKind::Mock | ProviderKind::GithubCopilot, url) => {
            url.clone().unwrap_or_default().trim_end_matches('/').to_string()
        }
        (_, Some(url)) => url.trim_end_matches('/').to_string(),
        (_, None) => bail!("provider {name:?} has no base_url"),
    };
    let api_key = match (&config.api_key, &config.api_key_env) {
        (Some(key), _) => Some(key.clone()),
        (None, Some(var)) => std::env::var(var).ok().filter(|v| !v.is_empty()),
        (None, None) => None,
    };
    let api_key = match (api_key, &config.api_key_command) {
        (Some(key), _) => Some(key),
        (None, Some(command)) => Some(run_key_command(name, command)?),
        (None, None) => None,
    };
    let extra_body = match &config.extra_body {
        Some(table) => serde_json::to_value(table)
            .context("provider extra_body")?
            .as_object()
            .cloned()
            .unwrap_or_default(),
        None => Default::default(),
    };
    let defaults = RetryPolicy::default();
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
        timeout: Duration::from_secs(config.timeout_secs.unwrap_or(600)),
        retry: RetryPolicy {
            max_retries: config.max_retries.unwrap_or(defaults.max_retries),
            initial_backoff: config
                .retry_initial_backoff_ms
                .map(Duration::from_millis)
                .unwrap_or(defaults.initial_backoff),
            max_backoff: config
                .retry_max_backoff_ms
                .map(Duration::from_millis)
                .unwrap_or(defaults.max_backoff),
        },
        retryable_statuses: config
            .retryable_statuses
            .clone()
            .unwrap_or_else(|| retry::DEFAULT_RETRYABLE_STATUSES.to_vec()),
    })
}

fn run_key_command(provider: &str, command: &str) -> Result<String> {
    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .stdin(std::process::Stdio::null())
        .output()
        .with_context(|| format!("provider {provider:?}: running api_key_command {command:?}"))?;
    let key = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() || key.is_empty() {
        bail!(
            "provider {provider:?}: api_key_command {command:?} failed ({}): {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
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
    let resolved = resolve(spec, user, default_provider)?;
    Ok(match resolved.kind {
        ProviderKind::Openai => Box::new(openai::OpenAiClient::new(resolved)?),
        ProviderKind::Anthropic => Box::new(anthropic::AnthropicClient::new(resolved)?),
        ProviderKind::GithubCopilot => Box::new(github_copilot::GithubCopilotClient::new(resolved)?),
        ProviderKind::Mock => Box::new(mock::MockLLMClient::new(&resolved.model)),
    })
}

/// Shared JSON-over-HTTP transport with retries.
pub(crate) struct HttpTransport {
    client: reqwest::Client,
    provider: ResolvedProvider,
}

impl HttpTransport {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(provider.timeout)
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
            let delay = retry::retry_delay(
                policy,
                attempt,
                api,
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

    /// POST `body` expecting server-sent events; each `data:` payload is passed
    /// to `on_data`. Failures before the stream starts are retried like
    /// `post_json_to`; a failure mid-stream is returned. If the server answers
    /// with plain JSON instead, that value is returned.
    pub async fn post_stream_to(
        &self,
        url: &str,
        body: &Value,
        auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
        on_data: &mut (dyn FnMut(&str) -> Result<()> + Send),
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
                        loop {
                            let chunk = response
                                .chunk()
                                .await
                                .map_err(|e| self.wrap(anyhow!(e).context("reading response stream")))?;
                            let Some(chunk) = chunk else { break };
                            for data in parser.push(&chunk) {
                                if data.trim() == "[DONE]" {
                                    return Ok(None);
                                }
                                on_data(&data).map_err(|e| self.wrap(e))?;
                            }
                        }
                        if let Some(data) = parser.finish()
                            && data.trim() != "[DONE]"
                        {
                            on_data(&data).map_err(|e| self.wrap(e))?;
                        }
                        return Ok(None);
                    }
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
                Err(e) if e.is_builder() => return Err(self.wrap(anyhow!(e))),
                Err(e) => (anyhow!(e), None),
            };
            if attempt >= policy.max_retries {
                return Err(self.wrap(err));
            }
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
    pub async fn serve(
        responses: Vec<(u16, &'static str, String)>,
    ) -> (String, Arc<Mutex<Vec<Captured>>>) {
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
