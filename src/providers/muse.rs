//! UNOFFICIAL Meta Muse Code provider.
//!
//! Uses a Muse Code subscription by authenticating the way the `muse` CLI does:
//! an RFC 8628 device-code login against `auth.meta.com` with Muse's public
//! OAuth client id, a **mint** of that OAuth token for a short-lived Meta API
//! key (`POST {mint}/muse-code/key`), and model calls carrying Muse's client
//! headers against the OpenAI-compatible Meta API (`https://api.meta.ai/v1`).
//!
//! This is not a Meta-sanctioned integration: it may conflict with Meta's terms
//! or your organisation's policy, and it can break when Meta changes what it
//! checks. It is only used when explicitly selected.
//!
//! Model calls speak plain OpenAI Chat Completions; the catalog (`GET
//! {mint}/muse-code/models`) is only read for the window / thinking levels /
//! vision probes and for `--list-models`.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::openai;
use super::retry::ApiError;
use super::{HttpTransport, ProviderKind, ResolvedProvider};
use crate::llm::{ChatRequest, ContextCap, DetectedWindow, LLMClient, LLMResponse, StreamSink, report_whole};
use crate::thinking::{Format, Reported};

/// Muse Code's public OAuth app client id. The `muse` CLI hardcodes this; Meta
/// login does not use dynamic client registration (the DCR paths in the binary
/// are for MCP servers only).
pub const DEFAULT_CLIENT_ID: &str = "1031625952748946";
/// OAuth/device-code host.
pub const DEFAULT_AUTH_BASE: &str = "https://auth.meta.com";
/// Meta API host that serves the key-mint and the model catalog.
pub const DEFAULT_MINT_BASE: &str = "https://api.meta.ai";
/// OpenAI-compatible chat endpoint, used when a provider entry carries no
/// `base_url` override and no minted base url.
pub const DEFAULT_API_BASE: &str = "https://api.meta.ai/v1";
/// `x-api-version` the Muse wire protocol sends on every endpoint: the OIDC
/// device authorization and token poll, the key mint, and the model catalog.
pub const MUSE_API_VERSION: &str = "1.0.0";

/// OpenAI Chat Completions path, relative to the (minted) API base.
const CHAT_PATH: &str = "/chat/completions";

/// Per-request timeout for the capability probes, matching the other providers
/// so a stalled catalog call cannot consume the whole startup/model-switch
/// budget.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Client identity headers the `muse` CLI sends on catalog requests. A provider
/// entry's own `headers` (given to `with_client_headers`) override any of these
/// case-insensitively.
const CLIENT_HEADERS: [(&str, &str); 2] =
    [("User-Agent", "muse-build/1.4.7 (non-interactive; macos-aarch64; nano-coder)"), ("x-client-id", "tbh:exec")];

fn env_base(var: &str, default: &str) -> String {
    std::env::var(var)
        .ok()
        .map(|v| v.trim().trim_end_matches('/').to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_string())
}

/// OAuth/device-code host (override with `MUSE_AUTH_BASE_URL`, e.g. to point a
/// test at a local server).
pub fn auth_base() -> String {
    env_base("MUSE_AUTH_BASE_URL", DEFAULT_AUTH_BASE)
}

/// Meta API host serving the key mint and the catalog (override with
/// `MUSE_MINT_BASE_URL`).
pub fn mint_base() -> String {
    env_base("MUSE_MINT_BASE_URL", DEFAULT_MINT_BASE)
}

fn client_id() -> String {
    std::env::var("MUSE_CLIENT_ID").ok().filter(|id| !id.is_empty()).unwrap_or_else(|| DEFAULT_CLIENT_ID.into())
}

#[derive(Debug, Clone)]
pub struct Endpoints {
    /// RFC 8628 device-authorization endpoint.
    pub device_authorization: String,
    /// RFC 8628 device-token endpoint (polled).
    pub token: String,
    /// Key-mint endpoint (`POST`, bearer OAuth token).
    pub mint: String,
    /// Model-catalog endpoint (`GET`, bearer API key).
    pub catalog: String,
}

impl Endpoints {
    pub fn for_bases(auth_base: &str, mint_base: &str) -> Self {
        Self {
            device_authorization: format!("{auth_base}/oidc/device/authorization/"),
            token: format!("{auth_base}/oidc/device/token/"),
            mint: format!("{mint_base}/muse-code/key"),
            catalog: format!("{mint_base}/muse-code/models"),
        }
    }
}

/// Muse credentials saved by `--login muse`: the OAuth token plus the API key
/// that was minted from it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredCredentials {
    pub oauth_token: String,
    /// Refresh token, when the device grant returned one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// Unix expiry (seconds) of the OAuth access token, when reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    /// The minted Meta API key used as a bearer for model calls.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    /// The `base_url` the mint reported for the key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_base: Option<String>,
    pub created_at: chrono::DateTime<Utc>,
}

pub fn credentials_path() -> Option<PathBuf> {
    dirs::data_local_dir().map(|d| crate::config::app_dir(&d).join("muse.json"))
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

fn with_client_headers(
    mut builder: reqwest::RequestBuilder,
    overrides: &std::collections::BTreeMap<String, String>,
) -> reqwest::RequestBuilder {
    for (name, value) in CLIENT_HEADERS {
        if !overrides.keys().any(|k| k.eq_ignore_ascii_case(name)) {
            builder = builder.header(name, value);
        }
    }
    builder
}

/// Interactive device-code login; mints an API key and saves both, returning
/// the credential file path.
pub async fn login() -> Result<PathBuf> {
    let endpoints = Endpoints::for_bases(&auth_base(), &mint_base());
    let http = reqwest::Client::new();
    let client_id = client_id();
    let device: Value = with_client_headers(http.post(&endpoints.device_authorization), &Default::default())
        .header("Accept", "application/json")
        .header("x-api-version", MUSE_API_VERSION)
        .form(&[("client_id", client_id.as_str())])
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

    eprintln!("UNOFFICIAL: this signs in as the Muse Code CLI; use at your own risk.");
    eprintln!("Open {uri} and enter code: {user_code}");
    eprintln!("Waiting for authorization...");

    loop {
        if std::time::Instant::now() > deadline {
            bail!("device code expired before authorization");
        }
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        let poll: Value = with_client_headers(http.post(&endpoints.token), &Default::default())
            .header("Accept", "application/json")
            .header("x-api-version", MUSE_API_VERSION)
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
            let expires_at = poll.get("expires_in").and_then(Value::as_i64).map(|secs| Utc::now().timestamp() + secs);
            // Prove the account can actually mint a key before reporting success.
            // Interactive login onboards: this may be a first-time account.
            let minted = mint(&http, &endpoints, token, true).await?;
            let credentials = StoredCredentials {
                oauth_token: token.to_string(),
                refresh_token: poll.get("refresh_token").and_then(Value::as_str).map(str::to_string),
                expires_at,
                api_key: Some(minted.api_key),
                api_base: Some(minted.base_url),
                created_at: Utc::now(),
            };
            let path = save_credentials(&credentials)?;
            eprintln!("Logged in; Muse API endpoint {}", credentials.api_base.as_deref().unwrap_or(DEFAULT_API_BASE));
            return Ok(path);
        }
        match poll.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => {}
            Some("slow_down") => {
                interval = slow_down_interval(interval, poll.get("interval").and_then(Value::as_u64));
            }
            Some(other) => {
                bail!("login failed: {other}: {}", poll.get("error_description").and_then(Value::as_str).unwrap_or(""))
            }
            None => bail!("unexpected token response: {poll}"),
        }
    }
}

/// RFC 8628 §3.5: every `slow_down` response must raise the device-token
/// polling interval by at least five seconds. Clamp the server-advertised value
/// so a smaller (or missing) one cannot *reduce* the interval and get us
/// rate-limited on the next poll.
fn slow_down_interval(current: u64, advertised: Option<u64>) -> u64 {
    advertised.unwrap_or(0).max(current + 5)
}

/// A minted Meta API key plus the endpoint it is valid for.
#[derive(Debug, Clone)]
pub struct MintedKey {
    pub api_key: String,
    pub base_url: String,
}

/// Exchange a Muse OAuth access token for a Meta API key. `onboard` is `true`
/// only for the interactive `--login muse` mint (which may be a first-time
/// account that must be onboarded); the silent 401 re-mints pass `false`.
pub async fn mint(http: &reqwest::Client, endpoints: &Endpoints, oauth: &str, onboard: bool) -> Result<MintedKey> {
    let response = with_client_headers(http.post(&endpoints.mint), &Default::default())
        .header("Accept", "application/json")
        .header("x-api-version", MUSE_API_VERSION)
        .bearer_auth(oauth)
        .json(&serde_json::json!({ "onboard": onboard }))
        .send()
        .await
        .context("Muse key mint")?;
    let status = response.status().as_u16();
    let text = response.text().await?;
    let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if !(200..300).contains(&status) {
        bail!("{}", mint_refusal(status, &value, &text));
    }
    let api_key = value
        .get("api_key")
        .and_then(Value::as_str)
        .filter(|k| !k.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("{}", mint_refusal(status, &value, &text)))?;
    // A 2xx can still carry the account gate (`is_subs_active` / `require_payment`)
    // alongside a key. An inactive subscription must not proceed through the
    // metered lane, so reject it before the key is stored or used.
    let inactive = value.get("is_subs_active").and_then(Value::as_bool) == Some(false);
    let payment = value.get("require_payment").and_then(Value::as_bool).unwrap_or(false);
    if inactive || payment {
        bail!("{}", mint_refusal(status, &value, &text));
    }
    // A successful mint may omit `base_url`; fall back to the default API base.
    let base_url = value
        .get("base_url")
        .and_then(Value::as_str)
        .map(|u| u.trim_end_matches('/').to_string())
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| DEFAULT_API_BASE.to_string());
    Ok(MintedKey { api_key, base_url })
}

/// Turn a refused/empty mint into an actionable message. A subscription or
/// onboarding problem comes back as a structured body (`detail`/`title`,
/// `action_url`, `require_payment`), which is far more useful than "missing
/// api_key" — see the `MintedKey` fields in the Muse binary.
fn mint_refusal(status: u16, value: &Value, raw: &str) -> String {
    let field = |name: &str| value.get(name).and_then(Value::as_str).filter(|s| !s.is_empty());
    let detail = field("detail").or_else(|| field("title"));
    let action = field("action_url").or_else(|| field("require_payment_action_url"));
    let payment = value.get("require_payment").and_then(Value::as_bool).unwrap_or(false);
    let mut message = match detail {
        Some(detail) => format!("Muse key mint refused (HTTP {status}): {detail}"),
        None => format!("Muse key mint failed (HTTP {status}): {}", raw.chars().take(300).collect::<String>()),
    };
    if payment && detail.is_none() {
        message.push_str(": a payment method or Muse Code subscription is required");
    }
    if let Some(action) = action {
        message.push_str(&format!(" — {action}"));
    }
    message.push_str(". Run `nano-coder --login muse` again once fixed (or set META_API_KEY).");
    message
}

fn is_unauthorized(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| cause.downcast_ref::<ApiError>().is_some_and(|api| api.status == 401))
}

/// A live credential: either a minted API key (from `--login muse`) or the
/// `META_API_KEY` passed in as the provider's `api_key`.
#[derive(Debug, Clone)]
pub(crate) struct SessionKey {
    api_key: String,
    base_url: String,
    refresh_at: i64,
}

pub struct MuseClient {
    transport: HttpTransport,
    /// OAuth token to mint with. `None` when `META_API_KEY` supplied the key, so
    /// there is nothing to mint.
    oauth: Option<String>,
    endpoints: Endpoints,
    /// The cached minted key, shared across clones (`clone_boxed`) so a freshly
    /// built client and its clone reuse one mint instead of each performing
    /// their own on first use.
    session: Arc<tokio::sync::Mutex<Option<SessionKey>>>,
    /// The catalog list the probes read, keyed by the `api_base` it was fetched
    /// from. Shared across clones like `session`.
    models_cache: Arc<tokio::sync::Mutex<Option<(String, Value)>>>,
}

impl MuseClient {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        // `META_API_KEY` arrives as the provider's `api_key` (see the preset's
        // `api_key_env`); a stored login carries the OAuth token to mint with,
        // plus the key it already minted (reused here, then re-minted on a 401).
        let stored = provider.api_key.is_none().then(load_credentials).flatten();
        let oauth = stored.as_ref().map(|c| c.oauth_token.clone());
        if provider.api_key.is_none() && oauth.is_none() {
            bail!("not logged in to Muse Code: run `nano-coder --login muse` or set META_API_KEY");
        }
        let seeded = stored.and_then(|c| {
            let api_key = c.api_key?;
            let base_url = c.api_base.unwrap_or_else(|| DEFAULT_API_BASE.to_string());
            Some(SessionKey { api_key, base_url, refresh_at: i64::MAX })
        });
        Self::with_endpoints(provider, oauth, Endpoints::for_bases(&auth_base(), &mint_base()), seeded)
    }

    pub(crate) fn with_endpoints(
        provider: ResolvedProvider,
        oauth: Option<String>,
        endpoints: Endpoints,
        session: Option<SessionKey>,
    ) -> Result<Self> {
        Ok(Self {
            transport: HttpTransport::new(provider)?,
            oauth,
            endpoints,
            session: Arc::new(tokio::sync::Mutex::new(session)),
            models_cache: Arc::new(tokio::sync::Mutex::new(None)),
        })
    }

    /// The key to authenticate model calls with. `META_API_KEY` (if set) is used
    /// outright; otherwise the OAuth token is minted for a short-lived key, with
    /// a cached copy reused until a margin before its expiry.
    async fn session_key(&self, force: bool) -> Result<SessionKey> {
        if let Some(key) = &self.transport.provider().api_key {
            return Ok(SessionKey {
                api_key: key.clone(),
                base_url: self.configured_base().unwrap_or_else(|| DEFAULT_API_BASE.to_string()),
                refresh_at: i64::MAX,
            });
        }
        let mut session = self.session.lock().await;
        if !force
            && let Some(current) = session.as_ref()
            && Utc::now().timestamp() < current.refresh_at
        {
            return Ok(current.clone());
        }
        let oauth = self.oauth.as_deref().ok_or_else(|| anyhow!("no Muse credentials"))?;
        let minted = mint(self.transport.http(), &self.endpoints, oauth, false).await?;
        let fresh = SessionKey { api_key: minted.api_key, base_url: minted.base_url, refresh_at: i64::MAX };
        *session = Some(fresh.clone());
        Ok(fresh)
    }

    fn configured_base(&self) -> Option<String> {
        let configured = &self.transport.provider().base_url;
        (!configured.is_empty()).then(|| configured.clone())
    }

    fn api_base(&self, session: &SessionKey) -> String {
        self.configured_base().unwrap_or_else(|| session.base_url.clone())
    }

    async fn catalog_json(&self, session: &SessionKey, timeout: Option<std::time::Duration>) -> Result<Value> {
        let mut request = self.transport.http().get(&self.endpoints.catalog);
        // Apply the provider's configured headers first, then the Muse client
        // defaults for any header the config did not override.
        for (name, value) in &self.transport.provider().headers {
            request = request.header(name, value);
        }
        let mut request = with_client_headers(request, &self.transport.provider().headers)
            .bearer_auth(&session.api_key)
            .header("Accept", "application/json")
            .header("x-api-version", MUSE_API_VERSION);
        if let Some(timeout) = timeout {
            request = request.timeout(timeout);
        }
        let response = request.send().await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            // Classify the status *before* parsing: a 401 (or any error) with an
            // empty or non-JSON body must still surface as `ApiError` so the
            // one-time remint recognises it, rather than a serde error.
            return Err(ApiError::from_body(status.as_u16(), &text).into());
        }
        Ok(serde_json::from_str(&text)?)
    }

    /// The current model's catalog row, from the cached list (fetched with
    /// `timeout` the first time). The cache is keyed on the minted `api_base`,
    /// mirroring the Copilot provider. A 401 from the catalog remints the key
    /// once and retries, so an expired seeded key does not silently lose the
    /// capability probes.
    async fn model_entry(&self, timeout: std::time::Duration) -> Option<Value> {
        let mut session = self.session_key(false).await.ok()?;
        let mut reminted = false;
        loop {
            let api_base = self.api_base(&session);
            let cached = {
                let cache = self.models_cache.lock().await;
                cache.as_ref().map(|(base, _)| base.as_str()) == Some(api_base.as_str())
            };
            if cached {
                break;
            }
            match self.catalog_json(&session, Some(timeout)).await {
                Ok(value) => {
                    *self.models_cache.lock().await = Some((api_base, value));
                    break;
                }
                // A 401 means the seeded/minted key expired: remint once and retry.
                Err(e) if !reminted && is_unauthorized(&e) => {
                    session = self.session_key(true).await.ok()?;
                    reminted = true;
                }
                Err(_) => return None,
            }
        }
        let cache = self.models_cache.lock().await;
        let model = &self.transport.provider().model;
        catalog_rows(&cache.as_ref()?.1).into_iter().find(|row| model_id(row) == Some(model.as_str())).cloned()
    }
}

/// The rows of a Muse catalog response. The exact envelope is not documented;
/// we accept a bare array or an object with a `data`/`models`/`rows` array.
fn catalog_rows(value: &Value) -> Vec<&Value> {
    for key in ["data", "models", "rows"] {
        if let Some(rows) = value.get(key).and_then(Value::as_array) {
            return rows.iter().collect();
        }
    }
    value.as_array().map(|rows| rows.iter().collect()).unwrap_or_default()
}

/// A catalog row's model id, under either the OpenAI-style `id` or Muse's
/// `model_id`.
fn model_id(row: &Value) -> Option<&str> {
    ["id", "model_id", "modelId"].iter().find_map(|k| row.get(*k).and_then(Value::as_str))
}

/// Whether a catalog row is explicitly hidden (`visibility: "hidden"`). Muse's
/// picker never offers these internal/disabled rows, so neither should we.
fn is_hidden_row(row: &Value) -> bool {
    ["visibility", "Visibility"]
        .iter()
        .find_map(|k| row.get(*k).and_then(Value::as_str))
        .is_some_and(|v| v.eq_ignore_ascii_case("hidden"))
}

/// Whether a catalog row is an image-*generation* model (Muse's
/// `supports_image_generation`), as opposed to a chat model that accepts image
/// *input*. The catalog has no Copilot-style `capabilities.supports.vision`
/// schema; its image flag describes generation, not input.
fn is_image_generation_row(row: &Value) -> bool {
    row.get("supports_image_generation")
        .or_else(|| row.get("supportsImageGeneration"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// A Muse chat model's vision support. Muse chat models accept image input, but
/// the catalog carries no vision schema (its image flag is generation-only), so
/// a normal chat row is reported vision-capable with default limits while an
/// image-*generation* or hidden row reports no input vision. A configured
/// `vision = false` override still wins over this in `vision::resolve`.
fn muse_vision(row: &Value) -> Option<crate::vision::Vision> {
    if is_image_generation_row(row) || is_hidden_row(row) {
        return None;
    }
    Some(crate::vision::Vision::capable())
}

fn positive(row: &Value, keys: &[&str]) -> Option<usize> {
    keys.iter().find_map(|k| row.get(*k).and_then(Value::as_u64)).filter(|&n| n > 0).map(|n| n as usize)
}

/// A row's context window: Muse's `context_limit` (snake or camel), falling back
/// to OpenAI-shaped `max_context_window_tokens`.
fn context_limit(row: &Value) -> Option<usize> {
    positive(row, &["context_limit", "contextLimit", "context_window", "contextWindow", "max_context_window_tokens"])
}

/// A row's reasoning-effort tiers: Muse's `reasoning_effort_variants` (`[{tier}]`,
/// `[{effort}]`, or `["low", …]`), else a flat `reasoning_effort` list. Muse's
/// object shape carries the level under `effort` (e.g. `{ "effort": "high" }`).
fn effort_levels(row: &Value) -> Option<Vec<String>> {
    let raw = ["reasoning_effort_variants", "reasoningEffortVariants", "reasoning_effort", "reasoningEffort"]
        .iter()
        .find_map(|k| row.get(*k).and_then(Value::as_array))?;
    let levels: Vec<String> = raw
        .iter()
        .filter_map(|v| {
            v.as_str().or_else(|| {
                ["tier", "effort"].iter().find_map(|k| v.get(*k).and_then(Value::as_str))
            })
        })
        .map(|level| match level.trim().to_ascii_lowercase().as_str() {
            "none" => "off".to_string(),
            other => other.to_string(),
        })
        .filter(|level| !level.is_empty())
        .collect();
    (!levels.is_empty()).then_some(levels)
}

#[async_trait]
impl LLMClient for MuseClient {
    fn clone_boxed(&self) -> Box<dyn LLMClient> {
        Box::new(Self {
            transport: self.transport.clone(),
            oauth: self.oauth.clone(),
            endpoints: self.endpoints.clone(),
            session: self.session.clone(),
            models_cache: self.models_cache.clone(),
        })
    }

    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        let body = {
            let plan = request.attachment_plan();
            openai::build_body_with_plan(&self.transport, request, &plan)
        };
        let overrides = self.transport.provider().headers.clone();
        let mut force_refresh = false;
        loop {
            let session = self.session_key(force_refresh).await?;
            let url = format!("{}{CHAT_PATH}", self.api_base(&session));
            let result = self
                .transport
                .post_json_to(&url, &body, |builder| {
                    with_client_headers(builder, &overrides).bearer_auth(&session.api_key)
                })
                .await;
            match result {
                Ok(value) => return openai::parse_response(&value, self.transport.provider().replay_reasoning),
                // The key was revoked or expired early: mint once more, then fail.
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
        // One attachment plan for the body, scoped so the non-`Send` plan is
        // dropped before the retry loop's awaits.
        let body = {
            let plan = request.attachment_plan();
            openai::build_body_with_plan(&self.transport, request, &plan)
        };
        let overrides = self.transport.provider().headers.clone();
        let mut force_refresh = false;
        loop {
            let session = self.session_key(force_refresh).await?;
            let url = format!("{}{CHAT_PATH}", self.api_base(&session));
            let auth = |builder: reqwest::RequestBuilder| {
                with_client_headers(builder, &overrides).bearer_auth(&session.api_key)
            };
            let result = openai::stream_chat(&self.transport, &url, body.clone(), auth, sink).await;
            match result {
                Err(e) if !force_refresh && is_unauthorized(&e) => force_refresh = true,
                other => return other,
            }
        }
    }

    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        tokio::time::timeout(PROBE_TIMEOUT, async {
            let entry = self.model_entry(PROBE_TIMEOUT).await?;
            context_limit(&entry).map(|tokens| DetectedWindow {
                tokens,
                source: "Muse /muse-code/models context_limit".to_string(),
                cap: ContextCap::Total,
                total_tokens: None,
            })
        })
        .await
        .ok()
        .flatten()
    }

    async fn detect_thinking_levels(&self) -> Option<Reported> {
        tokio::time::timeout(PROBE_TIMEOUT, async {
            let entry = self.model_entry(PROBE_TIMEOUT).await?;
            // Prefer the documented Copilot-style shape if the endpoint returns
            // it; otherwise read Muse's flat `reasoning_effort_variants`.
            Reported::from_model_entry(&entry).or_else(|| {
                effort_levels(&entry).map(|levels| Reported { levels, adaptive: false, format: Format::Effort })
            })
        })
        .await
        .ok()
        .flatten()
    }

    async fn detect_vision(&self) -> Option<crate::vision::Vision> {
        tokio::time::timeout(PROBE_TIMEOUT, async {
            let entry = self.model_entry(PROBE_TIMEOUT).await?;
            muse_vision(&entry)
        })
        .await
        .ok()
        .flatten()
    }

    async fn detect_capabilities(&self) -> (Option<DetectedWindow>, Option<Reported>, Option<crate::vision::Vision>) {
        tokio::time::timeout(PROBE_TIMEOUT, async {
            let entry = self.model_entry(PROBE_TIMEOUT).await?;
            let window = context_limit(&entry).map(|tokens| DetectedWindow {
                tokens,
                source: "Muse /muse-code/models context_limit".to_string(),
                cap: ContextCap::Total,
                total_tokens: None,
            });
            let thinking = Reported::from_model_entry(&entry).or_else(|| {
                effort_levels(&entry).map(|levels| Reported { levels, adaptive: false, format: Format::Effort })
            });
            let vision = muse_vision(&entry);
            Some((window, thinking, vision))
        })
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
    }

    async fn detect_thinking_and_vision(&self) -> (Option<Reported>, Option<crate::vision::Vision>) {
        tokio::time::timeout(PROBE_TIMEOUT, async {
            let entry = self.model_entry(PROBE_TIMEOUT).await?;
            let thinking = Reported::from_model_entry(&entry).or_else(|| {
                effort_levels(&entry).map(|levels| Reported { levels, adaptive: false, format: Format::Effort })
            });
            let vision = muse_vision(&entry);
            Some((thinking, vision))
        })
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
    }

    async fn list_models(&self) -> Result<Vec<String>> {
        let mut session = self.session_key(false).await?;
        let mut reminted = false;
        let value = loop {
            match self.catalog_json(&session, None).await {
                Ok(value) => break value,
                // A 401 means the seeded/minted key expired: remint once and retry.
                Err(e) if !reminted && is_unauthorized(&e) => {
                    session = self.session_key(true).await?;
                    reminted = true;
                }
                Err(e) => return Err(e),
            }
        };
        let mut models: Vec<String> = catalog_rows(&value)
            .into_iter()
            .filter_map(|row| {
                let id = model_id(row)?;
                // Skip rows the picker would never offer: image-generation
                // models and explicitly hidden/internal rows. Muse marks the
                // former with `supports_image_generation` and the latter with
                // `visibility: "hidden"`.
                let image = row
                    .get("supports_image_generation")
                    .or_else(|| row.get("supportsImageGeneration"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let hidden = is_hidden_row(row);
                (!image && !hidden).then(|| id.to_string())
            })
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

    fn kind(&self) -> Option<ProviderKind> {
        Some(ProviderKind::Muse)
    }

    fn endpoint(&self) -> Option<&str> {
        Some(&self.transport.provider().base_url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::Message;
    use crate::providers::{ProviderConfig, ProviderKind, resolve, test_server};
    use serde_json::json;
    use std::collections::HashMap;

    fn client_model(base: &str, model: &str) -> MuseClient {
        let mut user = HashMap::new();
        user.insert(
            "muse".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Muse),
                base_url: Some(base.to_string()),
                retry_initial_backoff_ms: Some(1),
                ..Default::default()
            },
        );
        let provider = resolve(&format!("muse/{model}"), &user, "mock").unwrap();
        let endpoints = Endpoints::for_bases(base, base);
        MuseClient::with_endpoints(provider, Some("oauth-tok".into()), endpoints, None).unwrap()
    }

    fn mint_body(base: &str) -> String {
        json!({ "api_key": "minted-key", "base_url": base }).to_string()
    }

    /// Endpoints with the mint and the catalog on separate hosts, as in
    /// production (mint on `api.meta.ai`, catalog also there — but tests need
    /// distinct scripted servers).
    fn endpoints(mint_base: &str, catalog_base: &str) -> Endpoints {
        Endpoints {
            device_authorization: format!("{mint_base}/oidc/device/authorization/"),
            token: format!("{mint_base}/oidc/device/token/"),
            mint: format!("{mint_base}/muse-code/key"),
            catalog: format!("{catalog_base}/muse-code/models"),
        }
    }

    #[tokio::test]
    async fn mints_and_calls_chat_completions() {
        let ok = r#"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}"#;
        let (mint_srv, mint_log) = test_server::serve(vec![(200, "", mint_body("http://unused"))]).await;
        let (api, api_log) = test_server::serve(vec![(200, "", ok.into())]).await;
        // The provider base_url is the API server; the mint returns a base that
        // is ignored because the provider carries an explicit base_url.
        let client = client_model(&api, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            client.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &mint_srv),
            None,
        )
        .unwrap();
        let messages = vec![Message::user("hello")];
        let request = ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        assert_eq!(client.chat(&request).await.unwrap().content, "hi");
        let api_log = api_log.lock().unwrap();
        assert_eq!(api_log[0].path, "/chat/completions");
        assert_eq!(api_log[0].body["model"], "muse-spark-1.3");
        assert!(api_log[0].body.get("messages").is_some());
        let headers = api_log[0].headers.to_lowercase();
        assert!(headers.contains("authorization: bearer minted-key"), "{headers}");
        assert!(headers.contains("x-client-id: tbh:exec"), "{headers}");
        // The mint was called with the OAuth token and the pinned api version.
        let mint_log = mint_log.lock().unwrap();
        assert_eq!(mint_log[0].path, "/muse-code/key");
        assert_eq!(mint_log[0].body["onboard"], false);
        let mint_headers = mint_log[0].headers.to_lowercase();
        assert!(mint_headers.contains("authorization: bearer oauth-tok"), "{mint_headers}");
        assert!(mint_headers.contains("x-api-version: 1.0.0"), "{mint_headers}");
    }

    #[tokio::test]
    async fn uses_a_literal_api_key_without_minting() {
        // `META_API_KEY` arrives as the provider's `api_key`; the client must
        // use it directly and never touch the mint endpoint.
        let ok = r#"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}"#;
        let (api, api_log) = test_server::serve(vec![(200, "", ok.into())]).await;
        let provider = {
            let mut user = HashMap::new();
            user.insert(
                "muse".to_string(),
                ProviderConfig {
                    kind: Some(ProviderKind::Muse),
                    base_url: Some(api.clone()),
                    api_key: Some("env-key".into()),
                    retry_initial_backoff_ms: Some(1),
                    ..Default::default()
                },
            );
            resolve("muse/muse-spark-1.3", &user, "mock").unwrap()
        };
        // `new` (not `with_endpoints`): with a literal key it must not need the
        // OAuth/mint endpoints at all.
        let client = MuseClient::new(provider).unwrap();
        let messages = vec![Message::user("hello")];
        let request = ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        assert_eq!(client.chat(&request).await.unwrap().content, "hi");
        let api_log = api_log.lock().unwrap();
        assert_eq!(api_log[0].path, "/chat/completions");
        assert!(api_log[0].headers.to_lowercase().contains("authorization: bearer env-key"));
    }

    #[tokio::test]
    async fn reuses_a_stored_minted_key_without_minting_again() {
        // A `--login muse` writes the minted key to disk; the client seeds its
        // session from it, so the first call doesn't need the mint endpoint.
        let ok = r#"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}"#;
        let (api, api_log) = test_server::serve(vec![(200, "", ok.into())]).await;
        let (mint_srv, mint_log) = test_server::serve(vec![(500, "", "should not be called".into())]).await;
        let provider = client_model(&api, "muse-spark-1.3");
        let seeded =
            SessionKey { api_key: "stored-key".into(), base_url: "http://unused".into(), refresh_at: i64::MAX };
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &mint_srv),
            Some(seeded),
        )
        .unwrap();
        let messages = vec![Message::user("hello")];
        let request = ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        assert_eq!(client.chat(&request).await.unwrap().content, "hi");
        assert!(mint_log.lock().unwrap().is_empty(), "the seeded key must skip the mint");
        assert!(api_log.lock().unwrap()[0].headers.to_lowercase().contains("authorization: bearer stored-key"));
    }

    #[test]
    fn parses_stored_credentials() {
        let creds: StoredCredentials = serde_json::from_value(json!({
            "oauth_token": "tok",
            "api_key": "key",
            "api_base": "https://api.meta.ai/v1",
            "created_at": "2026-01-01T00:00:00Z"
        }))
        .unwrap();
        assert_eq!(creds.api_key.as_deref(), Some("key"));
        assert_eq!(creds.refresh_token, None);
    }

    #[test]
    fn parses_the_catalog_envelope_tolerantly() {
        // Bare array, `data`, and `models` envelopes all yield rows.
        let bare = json!([{ "model_id": "muse-spark-1.3", "context_limit": 131072 }]);
        assert_eq!(catalog_rows(&bare).len(), 1);
        let data = json!({ "data": [{ "id": "a" }, { "id": "b" }] });
        assert_eq!(catalog_rows(&data).len(), 2);
        let models = json!({ "models": [{ "model_id": "c" }] });
        assert_eq!(catalog_rows(&models).len(), 1);
        assert_eq!(model_id(&models["models"][0]), Some("c"));
        assert_eq!(model_id(&json!({ "id": "d" })), Some("d"));
        assert_eq!(context_limit(&json!({ "context_limit": 131072 })), Some(131072));
        assert_eq!(context_limit(&json!({ "contextLimit": 200000 })), Some(200000));
        assert_eq!(context_limit(&json!({ "context_limit": 0 })), None);
    }

    #[test]
    fn reads_effort_variants_in_both_shapes() {
        let tiers = json!({ "reasoning_effort_variants": [{ "tier": "low" }, { "tier": "high" }] });
        assert_eq!(effort_levels(&tiers), Some(vec!["low".to_string(), "high".to_string()]));
        let camel = json!({ "reasoningEffortVariants": ["none", "medium"] });
        assert_eq!(effort_levels(&camel), Some(vec!["off".to_string(), "medium".to_string()]));
        // Muse's object shape carries the level under `effort` (e.g. `{ "effort": "high" }`).
        let effort = json!({ "reasoning_effort_variants": [{ "effort": "low" }, { "effort": "high" }] });
        assert_eq!(effort_levels(&effort), Some(vec!["low".to_string(), "high".to_string()]));
        assert_eq!(effort_levels(&json!({})), None);
    }

    #[tokio::test]
    async fn lists_models_hiding_image_generation() {
        let body = json!({
            "data": [
                { "model_id": "muse-spark-1.3" },
                { "model_id": "muse-image-1.0", "supports_image_generation": true },
                { "model_id": "muse-spark-1.3" }
            ]
        })
        .to_string();
        let (catalog, log) = test_server::serve(vec![(200, "", body)]).await;
        let (mint_srv, _) = test_server::serve(vec![(200, "", mint_body("http://unused"))]).await;
        let provider = client_model(&catalog, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        let models = client.list_models().await.unwrap();
        assert_eq!(models, vec!["muse-spark-1.3".to_string()]);
        assert_eq!(log.lock().unwrap()[0].path, "/muse-code/models");
    }

    #[test]
    fn mint_refusal_surfaces_the_subscription_gate() {
        // A subscription/payment problem comes back as a structured body; the
        // message must point at the fix, not at a missing api_key.
        let body = json!({
            "title": "Payment Required",
            "detail": "Muse Code requires a payment method",
            "require_payment": true,
            "action_url": "https://accountscenter.meta.com/muse_code/?ep=no_payg",
            "is_subs_active": false,
            "can_subscribe": true
        });
        let message = mint_refusal(402, &body, &body.to_string());
        assert!(message.contains("Muse Code requires a payment method"), "{message}");
        assert!(message.contains("accountscenter.meta.com/muse_code"), "{message}");
        assert!(message.contains("--login muse"), "{message}");
        // A bare 401 with an unhelpful body still names the gate.
        let bare = json!({ "require_payment": true });
        let message = mint_refusal(401, &bare, "{}");
        assert!(message.contains("subscription is required"), "{message}");
    }

    #[tokio::test]
    async fn remints_once_after_a_401() {
        let ok = r#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#;
        let (mint_srv, mint_log) =
            test_server::serve(vec![(200, "", mint_body("http://unused")), (200, "", mint_body("http://unused"))])
                .await;
        let (api, api_log) = test_server::serve(vec![
            (401, "", json!({ "error": { "code": "invalid_api_key", "message": "expired" } }).to_string()),
            (200, "", ok.into()),
        ])
        .await;
        let client = client_model(&api, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            client.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &mint_srv),
            None,
        )
        .unwrap();
        let messages = vec![Message::user("hello")];
        let request = ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        assert_eq!(client.chat(&request).await.unwrap().content, "ok");
        // A 401 minted a fresh key and retried: two mint calls, two chat calls.
        assert_eq!(mint_log.lock().unwrap().len(), 2);
        assert_eq!(api_log.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn mint_defaults_base_url_when_omitted() {
        // A successful mint may omit `base_url`; the client falls back to the
        // default API base rather than failing the login.
        let endpoints = Endpoints::for_bases("http://unused", "http://unused");
        let http = reqwest::Client::new();
        let (mint_srv, _) =
            test_server::serve(vec![(200, "", json!({ "api_key": "minted-key" }).to_string())]).await;
        let endpoints = Endpoints { mint: format!("{mint_srv}/muse-code/key"), ..endpoints };
        let minted = mint(&http, &endpoints, "oauth-tok", false).await.unwrap();
        assert_eq!(minted.api_key, "minted-key");
        assert_eq!(minted.base_url, DEFAULT_API_BASE);
    }

    #[tokio::test]
    async fn mint_rejects_an_inactive_subscription_even_with_a_key() {
        // A 2xx carrying the account gate must not proceed through the metered
        // lane just because a key is present.
        let http = reqwest::Client::new();
        for gate in [
            json!({ "api_key": "k", "base_url": "http://x", "is_subs_active": false }),
            json!({ "api_key": "k", "base_url": "http://x", "require_payment": true }),
        ] {
            let (mint_srv, _) = test_server::serve(vec![(200, "", gate.to_string())]).await;
            let endpoints = Endpoints {
                mint: format!("{mint_srv}/muse-code/key"),
                ..Endpoints::for_bases("http://unused", "http://unused")
            };
            let err = mint(&http, &endpoints, "oauth-tok", false).await.unwrap_err();
            assert!(err.to_string().contains("--login muse"), "{err}");
        }
    }

    #[tokio::test]
    async fn catalog_remints_once_after_a_401() {
        // A catalog request that meets an expired key remints once and retries,
        // so `--list-models` recovers instead of failing until a chat happens.
        let body = json!({ "data": [{ "model_id": "muse-spark-1.3" }] }).to_string();
        let (catalog, catalog_log) = test_server::serve(vec![
            (401, "", json!({ "error": { "message": "expired" } }).to_string()),
            (200, "", body),
        ])
        .await;
        let (mint_srv, mint_log) =
            test_server::serve(vec![(200, "", mint_body("http://unused")), (200, "", mint_body("http://unused"))])
                .await;
        let provider = client_model(&catalog, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        let models = client.list_models().await.unwrap();
        assert_eq!(models, vec!["muse-spark-1.3".to_string()]);
        // First catalog call 401s, the remint produces a fresh key, retry succeeds.
        assert_eq!(mint_log.lock().unwrap().len(), 2);
        assert_eq!(catalog_log.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn catalog_applies_configured_provider_headers() {
        // A configured `User-Agent` override must reach the catalog request (and
        // suppress the Muse default), not be dropped.
        let body = json!({ "data": [{ "model_id": "muse-spark-1.3" }] }).to_string();
        let (catalog, catalog_log) = test_server::serve(vec![(200, "", body)]).await;
        let (mint_srv, _) = test_server::serve(vec![(200, "", mint_body("http://unused"))]).await;
        let mut user = HashMap::new();
        let mut headers = std::collections::BTreeMap::new();
        headers.insert("User-Agent".to_string(), "custom-agent/9".to_string());
        user.insert(
            "muse".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Muse),
                base_url: Some(catalog.clone()),
                headers,
                retry_initial_backoff_ms: Some(1),
                ..Default::default()
            },
        );
        let provider = resolve("muse/muse-spark-1.3", &user, "mock").unwrap();
        let client = MuseClient::with_endpoints(
            provider,
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        client.list_models().await.unwrap();
        let sent = catalog_log.lock().unwrap()[0].headers.to_lowercase();
        assert!(sent.contains("user-agent: custom-agent/9"), "{sent}");
        assert!(!sent.contains("muse-build/"), "{sent}");
    }

    #[test]
    fn slow_down_never_reduces_the_poll_interval() {
        // RFC 8628: a slow_down must raise the interval by >= 5s. A smaller or
        // missing advertised value must not shrink it.
        assert_eq!(slow_down_interval(5, Some(2)), 10);
        assert_eq!(slow_down_interval(5, None), 10);
        assert_eq!(slow_down_interval(5, Some(5)), 10);
        // A larger advertised value is honoured.
        assert_eq!(slow_down_interval(5, Some(30)), 30);
        assert_eq!(slow_down_interval(5, Some(10)), 10);
    }

    #[tokio::test]
    async fn catalog_remints_on_a_401_with_a_non_json_body() {
        // A 401 with an empty/non-JSON error body must still be classified as
        // ApiError(401) so the one-time remint runs, not swallowed as a parse
        // error that aborts --list-models.
        let body = json!({ "data": [{ "model_id": "muse-spark-1.3" }] }).to_string();
        let (catalog, catalog_log) = test_server::serve(vec![
            (401, "", "Unauthorized".to_string()),
            (200, "", body),
        ])
        .await;
        let (mint_srv, mint_log) =
            test_server::serve(vec![(200, "", mint_body("http://unused")), (200, "", mint_body("http://unused"))])
                .await;
        let provider = client_model(&catalog, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        let models = client.list_models().await.unwrap();
        assert_eq!(models, vec!["muse-spark-1.3".to_string()]);
        assert_eq!(mint_log.lock().unwrap().len(), 2);
        assert_eq!(catalog_log.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn lists_models_excludes_hidden_rows() {
        // Muse marks internal/disabled rows `visibility: "hidden"`; its picker
        // skips them, so --list-models must too (alongside image rows).
        let body = json!({
            "data": [
                { "model_id": "muse-spark-1.3" },
                { "model_id": "muse-internal-x", "visibility": "hidden" },
                { "model_id": "muse-image-1.0", "supports_image_generation": true }
            ]
        })
        .to_string();
        let (catalog, _) = test_server::serve(vec![(200, "", body)]).await;
        let (mint_srv, _) = test_server::serve(vec![(200, "", mint_body("http://unused"))]).await;
        let provider = client_model(&catalog, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        let models = client.list_models().await.unwrap();
        assert_eq!(models, vec!["muse-spark-1.3".to_string()]);
    }

    #[tokio::test]
    async fn mint_sends_api_version_and_onboard_flag() {
        // The Muse wire protocol sends `x-api-version` on the mint, and the
        // interactive login onboards (`onboard: true`) while a silent re-mint
        // does not.
        let http = reqwest::Client::new();
        for (onboard, want) in [(true, "true"), (false, "false")] {
            let (mint_srv, log) =
                test_server::serve(vec![(200, "", json!({ "api_key": "k", "base_url": "http://x" }).to_string())]).await;
            let endpoints = Endpoints {
                mint: format!("{mint_srv}/muse-code/key"),
                ..Endpoints::for_bases("http://unused", "http://unused")
            };
            mint(&http, &endpoints, "oauth-tok", onboard).await.unwrap();
            let captured = log.lock().unwrap();
            let req = &captured[0];
            assert!(req.headers.contains("x-api-version: 1.0.0"), "{}", req.headers);
            assert_eq!(req.body.get("onboard").and_then(Value::as_bool).map(|b| b.to_string()), Some(want.to_string()));
        }
    }

    #[tokio::test]
    async fn catalog_sends_api_version_header() {
        let body = json!({ "data": [{ "model_id": "muse-spark-1.3" }] }).to_string();
        let (catalog, log) = test_server::serve(vec![(200, "", body)]).await;
        let (mint_srv, _) = test_server::serve(vec![(200, "", mint_body("http://unused"))]).await;
        let provider = client_model(&catalog, "muse-spark-1.3");
        let client = MuseClient::with_endpoints(
            provider.transport.provider().clone(),
            Some("oauth-tok".into()),
            endpoints(&mint_srv, &catalog),
            None,
        )
        .unwrap();
        client.list_models().await.unwrap();
        let captured = log.lock().unwrap();
        assert!(captured[0].headers.contains("x-api-version: 1.0.0"), "{}", captured[0].headers);
    }

    #[test]
    fn mint_refusal_relays_the_payment_remediation_url() {
        // Muse may return the remediation link as `require_payment_action_url`
        // rather than `action_url`; both must surface in the message.
        let value = json!({ "require_payment": true, "require_payment_action_url": "https://accountscenter.meta.com/muse_code" });
        let message = mint_refusal(402, &value, &value.to_string());
        assert!(message.contains("https://accountscenter.meta.com/muse_code"), "{message}");
    }

    #[test]
    fn muse_vision_treats_chat_rows_as_image_capable() {
        // Muse chat models accept image input; the catalog carries no vision
        // schema, so a normal chat row is vision-capable while an
        // image-generation or hidden row is not.
        assert!(muse_vision(&json!({ "model_id": "muse-spark-1.3" })).is_some());
        assert!(muse_vision(&json!({ "model_id": "muse-image-1.0", "supports_image_generation": true })).is_none());
        assert!(muse_vision(&json!({ "model_id": "muse-internal-x", "visibility": "hidden" })).is_none());
    }
}
