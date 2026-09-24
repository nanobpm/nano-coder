//! UNOFFICIAL GitHub Copilot provider.
//!
//! Uses a Copilot subscription by authenticating the way the VS Code Copilot
//! Chat extension does: a GitHub device-flow login with VS Code's OAuth client
//! ID, an exchange of that OAuth token for a short-lived Copilot session token,
//! and OpenAI-compatible Chat Completions calls carrying VS Code's editor
//! headers. This is not a GitHub-sanctioned integration: it may conflict with
//! GitHub's terms or your organisation's Copilot policy, and it can break when
//! GitHub changes what it checks. It is only used when explicitly selected.

use std::path::PathBuf;

use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::openai;
use super::retry::ApiError;
use super::{HttpTransport, ResolvedProvider};
use crate::llm::{ChatRequest, DetectedWindow, LLMClient, LLMResponse, Role, StreamSink, report_whole};

/// VS Code Copilot Chat's public OAuth app client ID.
pub const DEFAULT_CLIENT_ID: &str = "Iv1.b507a08c87ecfe98";
const DEFAULT_API_BASE: &str = "https://api.individual.githubcopilot.com";
const MODELS_API_VERSION: &str = "2025-05-01";
/// Refresh the session token this long before it expires.
const REFRESH_MARGIN_SECS: i64 = 300;

/// Per-request timeout for the context-window detection probe, matching the
/// OpenAI-compatible probe so a stalled `/models` call cannot consume the whole
/// startup/model-switch budget.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

const EDITOR_HEADERS: [(&str, &str); 4] = [
    ("User-Agent", "GitHubCopilotChat/0.35.0"),
    ("Editor-Version", "vscode/1.107.0"),
    ("Editor-Plugin-Version", "copilot-chat/0.35.0"),
    ("Copilot-Integration-Id", "vscode-chat"),
];

/// GitHub host (`github.com`, or a GHE.com domain via `GITHUB_COPILOT_DOMAIN`).
pub fn domain() -> String {
    std::env::var("GITHUB_COPILOT_DOMAIN")
        .ok()
        .map(|d| d.trim().trim_start_matches("https://").trim_end_matches('/').to_string())
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "github.com".into())
}

fn client_id() -> String {
    std::env::var("GITHUB_COPILOT_CLIENT_ID")
        .ok()
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| DEFAULT_CLIENT_ID.into())
}

#[derive(Debug, Clone)]
pub struct Endpoints {
    pub device_code: String,
    pub access_token: String,
    pub copilot_token: String,
}

impl Endpoints {
    pub fn for_domain(domain: &str) -> Self {
        Self {
            device_code: format!("https://{domain}/login/device/code"),
            access_token: format!("https://{domain}/login/oauth/access_token"),
            copilot_token: format!("https://api.{domain}/copilot_internal/v2/token"),
        }
    }
}

/// OAuth credentials saved by `--login github-copilot`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredCredentials {
    pub oauth_token: String,
    pub domain: String,
    pub created_at: chrono::DateTime<Utc>,
}

pub fn credentials_path() -> Option<PathBuf> {
    dirs::data_local_dir().map(|d| crate::config::app_dir(&d).join("github-copilot.json"))
}

pub fn load_credentials() -> Option<StoredCredentials> {
    let text = std::fs::read_to_string(credentials_path()?).ok()?;
    serde_json::from_str(&text).ok()
}

fn save_credentials(credentials: &StoredCredentials) -> Result<PathBuf> {
    let path = credentials_path().ok_or_else(|| anyhow!("no local data directory"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path).with_context(|| format!("open {}", path.display()))?;
    std::io::Write::write_all(&mut file, serde_json::to_string_pretty(credentials)?.as_bytes())?;
    Ok(path)
}

fn with_editor_headers(
    mut builder: reqwest::RequestBuilder,
    overrides: &std::collections::BTreeMap<String, String>,
) -> reqwest::RequestBuilder {
    for (name, value) in EDITOR_HEADERS {
        if !overrides.keys().any(|k| k.eq_ignore_ascii_case(name)) {
            builder = builder.header(name, value);
        }
    }
    builder
}

/// Interactive device-flow login; saves the OAuth token and returns its path.
pub async fn login() -> Result<PathBuf> {
    let domain = domain();
    let endpoints = Endpoints::for_domain(&domain);
    let http = reqwest::Client::new();
    let client_id = client_id();
    let device: Value = with_editor_headers(http.post(&endpoints.device_code), &Default::default())
        .header("Accept", "application/json")
        .form(&[("client_id", client_id.as_str()), ("scope", "read:user")])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let field = |name: &str| device.get(name).and_then(Value::as_str).map(str::to_string);
    let (Some(device_code), Some(user_code), Some(uri)) =
        (field("device_code"), field("user_code"), field("verification_uri"))
    else {
        bail!("unexpected device code response: {device}");
    };
    let mut interval = device.get("interval").and_then(Value::as_u64).unwrap_or(5).max(1);
    let deadline = std::time::Instant::now()
        + std::time::Duration::from_secs(device.get("expires_in").and_then(Value::as_u64).unwrap_or(900));

    eprintln!("UNOFFICIAL: this signs in as the VS Code Copilot extension; use at your own risk.");
    eprintln!("Open {uri} and enter code: {user_code}");
    eprintln!("Waiting for authorization...");

    loop {
        if std::time::Instant::now() > deadline {
            bail!("device code expired before authorization");
        }
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        let poll: Value = with_editor_headers(http.post(&endpoints.access_token), &Default::default())
            .header("Accept", "application/json")
            .form(&[
                ("client_id", client_id.as_str()),
                ("device_code", device_code.as_str()),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            .send()
            .await?
            .json()
            .await?;
        if let Some(token) = poll.get("access_token").and_then(Value::as_str) {
            let credentials = StoredCredentials {
                oauth_token: token.to_string(),
                domain: domain.clone(),
                created_at: Utc::now(),
            };
            // Prove the account actually has Copilot before reporting success.
            let session = exchange(&http, &endpoints, token).await?;
            let path = save_credentials(&credentials)?;
            eprintln!("Logged in; Copilot API endpoint {}", session.base_url);
            return Ok(path);
        }
        match poll.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => {}
            Some("slow_down") => {
                interval = poll.get("interval").and_then(Value::as_u64).unwrap_or(interval + 5);
            }
            Some(other) => bail!(
                "login failed: {other}: {}",
                poll.get("error_description").and_then(Value::as_str).unwrap_or("")
            ),
            None => bail!("unexpected token response: {poll}"),
        }
    }
}

/// Short-lived Copilot API credentials.
#[derive(Debug, Clone)]
pub struct SessionToken {
    pub token: String,
    pub base_url: String,
    pub refresh_at: i64,
}

/// `proxy-ep=proxy.individual.githubcopilot.com` → `https://api.individual.githubcopilot.com`.
pub fn base_url_from_token(token: &str) -> Option<String> {
    let endpoint = token.split(';').find_map(|part| part.strip_prefix("proxy-ep="))?;
    let host = endpoint.strip_prefix("proxy.").map(|rest| format!("api.{rest}"));
    Some(format!("https://{}", host.as_deref().unwrap_or(endpoint)))
}

/// Exchange a GitHub OAuth token for a Copilot session token.
pub async fn exchange(http: &reqwest::Client, endpoints: &Endpoints, oauth: &str) -> Result<SessionToken> {
    let response = with_editor_headers(http.get(&endpoints.copilot_token), &Default::default())
        .header("Accept", "application/json")
        .bearer_auth(oauth)
        .send()
        .await
        .context("Copilot token exchange")?;
    let status = response.status().as_u16();
    let text = response.text().await?;
    if !(200..300).contains(&status) {
        bail!(
            "Copilot token exchange failed (HTTP {status}): {}. Run `nano-coder --login github-copilot` \
             or set GITHUB_COPILOT_OAUTH_TOKEN; the account must have an active Copilot subscription.",
            text.chars().take(300).collect::<String>()
        );
    }
    let value: Value = serde_json::from_str(&text).context("Copilot token response")?;
    let token = value
        .get("token")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Copilot token response has no token"))?
        .to_string();
    let expires_at = value
        .get("expires_at")
        .and_then(Value::as_i64)
        .unwrap_or_else(|| Utc::now().timestamp() + 1500);
    let base_url = value
        .pointer("/endpoints/api")
        .and_then(Value::as_str)
        .map(|u| u.trim_end_matches('/').to_string())
        .or_else(|| base_url_from_token(&token))
        .unwrap_or_else(|| DEFAULT_API_BASE.into());
    Ok(SessionToken {
        token,
        base_url,
        refresh_at: expires_at - REFRESH_MARGIN_SECS,
    })
}

fn is_unauthorized(err: &anyhow::Error) -> bool {
    err.chain()
        .any(|cause| cause.downcast_ref::<ApiError>().is_some_and(|api| api.status == 401))
}

pub struct GithubCopilotClient {
    transport: HttpTransport,
    oauth: String,
    endpoints: Endpoints,
    session: tokio::sync::Mutex<Option<SessionToken>>,
}

impl GithubCopilotClient {
    async fn models_json(&self, timeout: Option<std::time::Duration>) -> Result<Value> {
        let session = self.session_token(false).await?;
        let url = format!("{}/models", self.api_base(&session));
        let mut request = with_editor_headers(self.transport.http().get(&url), &self.transport.provider().headers)
            .bearer_auth(&session.token)
            .header("Accept", "application/json")
            .header("X-GitHub-Api-Version", MODELS_API_VERSION);
        if let Some(timeout) = timeout {
            request = request.timeout(timeout);
        }
        let response = request.send().await?;
        let status = response.status();
        let value: Value = response.json().await?;
        if !status.is_success() {
            bail!("listing Copilot models failed (HTTP {status}): {value}");
        }
        Ok(value)
    }

    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        let domain = domain();
        let oauth = provider
            .api_key
            .clone()
            .or_else(|| load_credentials().filter(|c| c.domain == domain).map(|c| c.oauth_token))
            .ok_or_else(|| {
                anyhow!(
                    "not logged in to GitHub Copilot: run `nano-coder --login github-copilot` \
                     or set GITHUB_COPILOT_OAUTH_TOKEN"
                )
            })?;
        Self::with_endpoints(provider, oauth, Endpoints::for_domain(&domain))
    }

    pub fn with_endpoints(provider: ResolvedProvider, oauth: String, endpoints: Endpoints) -> Result<Self> {
        Ok(Self {
            transport: HttpTransport::new(provider)?,
            oauth,
            endpoints,
            session: tokio::sync::Mutex::new(None),
        })
    }

    async fn session_token(&self, force: bool) -> Result<SessionToken> {
        let mut session = self.session.lock().await;
        if !force
            && let Some(current) = session.as_ref()
            && Utc::now().timestamp() < current.refresh_at
        {
            return Ok(current.clone());
        }
        let fresh = exchange(self.transport.http(), &self.endpoints, &self.oauth).await?;
        *session = Some(fresh.clone());
        Ok(fresh)
    }

    fn api_base(&self, session: &SessionToken) -> String {
        let configured = &self.transport.provider().base_url;
        if configured.is_empty() { session.base_url.clone() } else { configured.clone() }
    }
}

#[async_trait]
impl LLMClient for GithubCopilotClient {
    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        let body = openai::build_body(&self.transport, request);
        // Copilot bills a premium request per user-initiated turn; tool
        // follow-ups are marked agent-initiated, as VS Code does.
        let initiator = match request.messages.last().map(|m| &m.role) {
            Some(Role::User) => "user",
            _ => "agent",
        };
        let overrides = self.transport.provider().headers.clone();
        let mut force_refresh = false;
        loop {
            let session = self.session_token(force_refresh).await?;
            let url = format!("{}/chat/completions", self.api_base(&session));
            let result = self
                .transport
                .post_json_to(&url, &body, |builder| {
                    with_editor_headers(builder, &overrides)
                        .bearer_auth(&session.token)
                        .header("X-Initiator", initiator)
                        .header("Openai-Intent", "conversation-edits")
                })
                .await;
            match result {
                Ok(value) => return openai::parse_response(&value, self.transport.provider().replay_reasoning),
                // The session token was revoked or expired early: re-exchange once.
                Err(e) if !force_refresh && is_unauthorized(&e) => force_refresh = true,
                Err(e) => return Err(e),
            }
        }
    }

    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        if !self.transport.provider().stream {
            let response = self.chat(request).await?;
            report_whole(sink, &response);
            return Ok(response);
        }
        let body = openai::build_body(&self.transport, request);
        let initiator = match request.messages.last().map(|m| &m.role) {
            Some(Role::User) => "user",
            _ => "agent",
        };
        let overrides = self.transport.provider().headers.clone();
        let mut force_refresh = false;
        loop {
            let session = self.session_token(force_refresh).await?;
            let url = format!("{}/chat/completions", self.api_base(&session));
            let result = openai::stream_chat(&self.transport, &url, body.clone(), |builder| {
                with_editor_headers(builder, &overrides)
                    .bearer_auth(&session.token)
                    .header("X-Initiator", initiator)
                    .header("Openai-Intent", "conversation-edits")
            }, sink)
            .await;
            match result {
                Err(e) if !force_refresh && is_unauthorized(&e) => force_refresh = true,
                other => return other,
            }
        }
    }

    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        let models = self.models_json(Some(PROBE_TIMEOUT)).await.ok()?;
        let model = &self.transport.provider().model;
        let entry = models.get("data")?.as_array()?.iter().find(|m| m.get("id").and_then(Value::as_str) == Some(model))?;
        // Copilot enforces the prompt budget, which is below the full window.
        ["max_prompt_tokens", "max_context_window_tokens"].iter().find_map(|field| {
            let tokens = entry.pointer(&format!("/capabilities/limits/{field}"))?.as_u64().filter(|&n| n > 0)?;
            Some(DetectedWindow { tokens: tokens as usize, source: format!("Copilot /models {field}") })
        })
    }

    async fn list_models(&self) -> Result<Vec<String>> {
        let value = self.models_json(None).await?;
        let mut models: Vec<String> = value
            .get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|m| m.pointer("/capabilities/type").and_then(Value::as_str).is_none_or(|t| t == "chat"))
            .filter(|m| m.pointer("/policy/state").and_then(Value::as_str) != Some("disabled"))
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();
        models.sort();
        models.dedup();
        Ok(models)
    }

    fn model_name(&self) -> &str {
        &self.transport.provider().model
    }

    fn provider_name(&self) -> &str {
        &self.transport.provider().name
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{Message, ToolCall};
    use crate::providers::{ProviderConfig, ProviderKind, resolve, test_server};
    use serde_json::json;
    use std::collections::HashMap;

    fn client(base: &str) -> GithubCopilotClient {
        let mut user = HashMap::new();
        user.insert(
            "github-copilot".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::GithubCopilot),
                retry_initial_backoff_ms: Some(1),
                ..Default::default()
            },
        );
        let provider = resolve("github-copilot/gpt-4.1", &user, "mock").unwrap();
        let endpoints = Endpoints {
            device_code: format!("{base}/login/device/code"),
            access_token: format!("{base}/login/oauth/access_token"),
            copilot_token: format!("{base}/copilot_internal/v2/token"),
        };
        GithubCopilotClient::with_endpoints(provider, "gho_oauth".into(), endpoints).unwrap()
    }

    fn token_body(base: &str, token: &str) -> String {
        json!({
            "token": token,
            "expires_at": Utc::now().timestamp() + 1800,
            "endpoints": { "api": base },
        })
        .to_string()
    }

    const CHAT_OK: &str = r#"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}"#;

    #[test]
    fn derives_api_base_from_proxy_endpoint() {
        assert_eq!(
            base_url_from_token("tid=1;exp=2;proxy-ep=proxy.individual.githubcopilot.com;sku=x").as_deref(),
            Some("https://api.individual.githubcopilot.com")
        );
        assert_eq!(base_url_from_token("tid=1;exp=2"), None);
    }

    #[tokio::test]
    async fn exchanges_token_and_sends_editor_headers() {
        // The token response's `endpoints.api` points at a second server.
        let (api, api_log) = test_server::serve(vec![
            (200, "", CHAT_OK.into()),
            (200, "", CHAT_OK.into()),
        ])
        .await;
        let (auth, auth_log) = test_server::serve(vec![(200, "", token_body(&api, "sess-1"))]).await;
        let client = client(&auth);

        let messages = vec![Message::user("hello")];
        let request = ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None };
        assert_eq!(client.chat(&request).await.unwrap().content, "hi");
        let followup = vec![
            Message::user("hello"),
            Message::assistant_with_tools("", vec![ToolCall { id: "c".into(), name: "t".into(), arguments: json!({}) }]),
            Message::tool_result("c", "t", "ok"),
        ];
        let request = ChatRequest { messages: &followup, tools: &[], temperature: None, max_tokens: None };
        client.chat(&request).await.unwrap();

        let auth_log = auth_log.lock().unwrap();
        assert_eq!(auth_log.len(), 1, "session token is cached");
        assert!(auth_log[0].headers.to_lowercase().contains("authorization: bearer gho_oauth"));
        assert!(auth_log[0].headers.contains("vscode/"));
        let api_log = api_log.lock().unwrap();
        let first = api_log[0].headers.to_lowercase();
        assert_eq!(api_log[0].path, "/chat/completions");
        assert!(first.contains("authorization: bearer sess-1"));
        assert!(first.contains("copilot-integration-id: vscode-chat"));
        assert!(first.contains("x-initiator: user"));
        assert!(api_log[1].headers.to_lowercase().contains("x-initiator: agent"));
        assert_eq!(api_log[0].body["model"], "gpt-4.1");
    }

    #[tokio::test]
    async fn reexchanges_once_on_unauthorized() {
        let (api, api_log) = test_server::serve(vec![
            (401, "", r#"{"error":{"message":"token expired"}}"#.into()),
            (200, "", CHAT_OK.into()),
        ])
        .await;
        let (auth, auth_log) = test_server::serve(vec![
            (200, "", token_body(&api, "sess-1")),
            (200, "", token_body(&api, "sess-2")),
        ])
        .await;
        let client = client(&auth);
        let messages = vec![Message::user("hello")];
        let request = ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None };
        assert_eq!(client.chat(&request).await.unwrap().content, "hi");
        assert_eq!(auth_log.lock().unwrap().len(), 2);
        assert!(api_log.lock().unwrap()[1].headers.to_lowercase().contains("bearer sess-2"));
    }

    #[tokio::test]
    async fn exchange_failure_explains_login() {
        let (auth, _) = test_server::serve(vec![(404, "", r#"{"message":"Not Found"}"#.into())]).await;
        let client = client(&auth);
        let messages = vec![Message::user("hello")];
        let request = ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None };
        let err = format!("{:#}", client.chat(&request).await.unwrap_err());
        assert!(err.contains("--login github-copilot"), "{err}");
    }

    async fn detect_window(models: Value) -> Option<DetectedWindow> {
        let (api, _api_log) = test_server::serve(vec![(200, "", models.to_string())]).await;
        let (auth, _auth_log) = test_server::serve(vec![(200, "", token_body(&api, "sess-1"))]).await;
        client(&auth).detect_context_window().await
    }

    #[tokio::test]
    async fn detects_context_window_field_fallbacks() {
        // `max_prompt_tokens` is Copilot's enforced prompt budget and wins over
        // `max_context_window_tokens` when both are present.
        let window = detect_window(json!({
            "data": [{ "id": "gpt-4.1", "capabilities": { "limits": {
                "max_prompt_tokens": 111,
                "max_context_window_tokens": 999,
            } } }]
        }))
        .await
        .unwrap();
        assert_eq!(window.tokens, 111);
        assert_eq!(window.source, "Copilot /models max_prompt_tokens");

        // With `max_prompt_tokens` absent, fall back to `max_context_window_tokens`.
        let window = detect_window(json!({
            "data": [{ "id": "gpt-4.1", "capabilities": { "limits": {
                "max_context_window_tokens": 222,
            } } }]
        }))
        .await
        .unwrap();
        assert_eq!(window.tokens, 222);
        assert_eq!(window.source, "Copilot /models max_context_window_tokens");

        // Neither field present: no detection rather than a bogus default.
        assert!(
            detect_window(json!({ "data": [{ "id": "gpt-4.1", "capabilities": { "limits": {} } }] }))
                .await
                .is_none()
        );

        // A non-positive budget is ignored, not treated as a window.
        assert!(
            detect_window(json!({
                "data": [{ "id": "gpt-4.1", "capabilities": { "limits": { "max_prompt_tokens": 0 } } }]
            }))
            .await
            .is_none()
        );

        // A matching id must exist; a different model is not silently used.
        assert!(
            detect_window(json!({
                "data": [{ "id": "other", "capabilities": { "limits": { "max_prompt_tokens": 111 } } }]
            }))
            .await
            .is_none()
        );
    }
}
