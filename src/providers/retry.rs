//! Retry classification and backoff for provider requests.
//!
//! Ported from unreal-agent's `harness/llm/responsesapi/retry.go`
//! (MIT, Copyright (c) 2026 Unreal Labs). Providers report failures
//! inconsistently, so the classifier intentionally fails open, favouring
//! retries, except for errors that can never succeed on retry.

use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;

pub const DEFAULT_RETRYABLE_STATUSES: &[u16] = &[408, 409, 425, 429, 500, 502, 503, 504, 529];

static RETRY_AFTER_MESSAGE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\btry again in\s*(\d+(?:\.\d+)?)\s*(ms|milliseconds?|s|seconds?)\b").unwrap()
});

/// A normalized provider error.
#[derive(Debug, Clone, Default)]
pub struct ApiError {
    pub status: u16,
    pub code: Option<String>,
    pub kind: Option<String>,
    pub message: String,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HTTP {}", self.status)?;
        if let Some(kind) = &self.kind {
            write!(f, " {kind}")?;
        }
        if let Some(code) = &self.code {
            write!(f, " ({code})")?;
        }
        if !self.message.is_empty() {
            write!(f, ": {}", self.message)?;
        }
        Ok(())
    }
}

impl std::error::Error for ApiError {}

impl ApiError {
    /// Parse an error body in either OpenAI (`{"error":{"code","type","message"}}`)
    /// or Anthropic (`{"type":"error","error":{"type","message"}}`) shape.
    pub fn from_body(status: u16, body: &str) -> Self {
        let parsed: Option<serde_json::Value> = serde_json::from_str(body).ok();
        let error = parsed.as_ref().and_then(|v| v.get("error"));
        let field = |name: &str| {
            error
                .and_then(|e| e.get(name))
                .and_then(|v| match v {
                    serde_json::Value::String(s) => Some(s.clone()),
                    serde_json::Value::Number(n) => Some(n.to_string()),
                    _ => None,
                })
        };
        let message = match error {
            Some(serde_json::Value::String(s)) => s.clone(),
            _ => field("message").unwrap_or_else(|| body.chars().take(2000).collect()),
        };
        Self {
            status,
            code: field("code"),
            kind: field("type"),
            message,
        }
    }

    fn is_overloaded(&self) -> bool {
        matches!(self.code.as_deref(), Some("server_is_overloaded" | "slow_down"))
            || self.kind.as_deref() == Some("overloaded_error")
            || self.status == 529
    }

    fn is_rate_limited(&self) -> bool {
        self.code.as_deref() == Some("rate_limit_exceeded")
            || self.kind.as_deref() == Some("rate_limit_error")
            || self.status == 429
    }
}

/// Whether an API error is worth retrying.
pub fn retryable(err: &ApiError, retryable_statuses: &[u16]) -> bool {
    if let Some(code) = err.code.as_deref()
        && matches!(
            code,
            "context_length_exceeded"
                | "insufficient_quota"
                | "usage_not_included"
                | "usage_limit_reached"
                | "credit_balance_exhausted"
                | "billing_hard_limit_reached"
                | "cyber_policy"
                | "misalignment_policy_violation"
                | "invalid_prompt"
                | "bio_policy"
                | "invalid_api_key"
                | "invalid_token"
        ) {
            return false;
        }
    if let Some(kind) = err.kind.as_deref()
        && matches!(
            kind,
            "authentication_error" | "permission_error" | "insufficient_quota" | "invalid_request_error"
                if err.status != 429
        ) {
            return false;
        }
    if !(200..300).contains(&err.status) {
        return retryable_statuses.contains(&err.status);
    }
    // An error reported inside a 2xx body: fail open.
    true
}

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: u32,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 5,
            initial_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(30),
        }
    }
}

impl RetryPolicy {
    /// Exponential backoff for a zero-based attempt number.
    pub fn backoff(&self, attempt: u32) -> Duration {
        let factor = 2u32.saturating_pow(attempt.min(20));
        self.initial_backoff.saturating_mul(factor).min(self.max_backoff)
    }
}

/// Delay before the next attempt. `jitter` is in `[0, 1)` and shaves up to
/// 20% off computed backoffs; server-provided hints are honoured exactly
/// (capped at `max_backoff`).
pub fn retry_delay(
    policy: &RetryPolicy,
    attempt: u32,
    err: Option<&ApiError>,
    retry_after_header: Option<&str>,
    now: chrono::DateTime<chrono::Utc>,
    jitter: f64,
) -> Duration {
    let mut hint = retry_after_header
        .map(|value| parse_retry_after_header(value, now))
        .unwrap_or_default();
    if let Some(err) = err
        && err.is_rate_limited() {
            hint = hint.max(parse_retry_after_message(&err.message));
        }
    if !hint.is_zero() {
        return hint.min(policy.max_backoff);
    }
    let mut policy = policy.clone();
    if err.is_some_and(ApiError::is_overloaded) {
        // Unattended runs retry overloads with a longer backoff.
        policy.initial_backoff = Duration::from_secs(10);
        policy.max_backoff = Duration::from_secs(60);
    }
    let delay = policy.backoff(attempt);
    delay - (delay / 5).mul_f64(jitter.clamp(0.0, 1.0))
}

pub fn parse_retry_after_header(value: &str, now: chrono::DateTime<chrono::Utc>) -> Duration {
    let value = value.trim();
    if let Ok(seconds) = value.parse::<u64>() {
        return Duration::from_secs(seconds);
    }
    if let Ok(seconds) = value.parse::<f64>()
        && seconds.is_finite() && seconds > 0.0 {
            return Duration::from_secs_f64(seconds);
        }
    if let Ok(deadline) = chrono::DateTime::parse_from_rfc2822(value) {
        return (deadline.with_timezone(&chrono::Utc) - now).to_std().unwrap_or_default();
    }
    Duration::ZERO
}

pub fn parse_retry_after_message(message: &str) -> Duration {
    let Some(captures) = RETRY_AFTER_MESSAGE.captures(message) else {
        return Duration::ZERO;
    };
    let Ok(amount) = captures[1].parse::<f64>() else {
        return Duration::ZERO;
    };
    if captures[2].to_ascii_lowercase().starts_with('m') {
        Duration::from_secs_f64(amount / 1000.0)
    } else {
        Duration::from_secs_f64(amount)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn err(status: u16, code: Option<&str>, kind: Option<&str>, message: &str) -> ApiError {
        ApiError {
            status,
            code: code.map(str::to_string),
            kind: kind.map(str::to_string),
            message: message.to_string(),
        }
    }

    #[test]
    fn classifies_retryable_errors() {
        let statuses = DEFAULT_RETRYABLE_STATUSES;
        assert!(retryable(&err(429, None, None, ""), statuses));
        assert!(retryable(&err(503, None, None, ""), statuses));
        assert!(retryable(&err(529, None, Some("overloaded_error"), ""), statuses));
        assert!(!retryable(&err(400, None, None, ""), statuses));
        assert!(!retryable(&err(401, None, Some("authentication_error"), ""), statuses));
        assert!(!retryable(&err(429, Some("insufficient_quota"), None, ""), statuses));
        assert!(!retryable(&err(400, Some("context_length_exceeded"), None, ""), statuses));
        // An in-body error on a 2xx fails open.
        assert!(retryable(&err(200, Some("server_error"), None, ""), statuses));
    }

    #[test]
    fn parses_error_bodies() {
        let openai = ApiError::from_body(
            429,
            r#"{"error":{"message":"Rate limit. Please try again in 1.5s.","type":"requests","code":"rate_limit_exceeded"}}"#,
        );
        assert_eq!(openai.code.as_deref(), Some("rate_limit_exceeded"));
        assert!(openai.message.starts_with("Rate limit"));

        let anthropic = ApiError::from_body(
            529,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        );
        assert_eq!(anthropic.kind.as_deref(), Some("overloaded_error"));

        let plain = ApiError::from_body(502, "bad gateway");
        assert_eq!(plain.message, "bad gateway");
    }

    #[test]
    fn honours_retry_after_hints() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
        assert_eq!(parse_retry_after_header("7", now), Duration::from_secs(7));
        assert_eq!(
            parse_retry_after_header("Thu, 01 Jan 2026 00:00:03 GMT", now),
            Duration::from_secs(3)
        );
        assert_eq!(parse_retry_after_message("try again in 250ms"), Duration::from_millis(250));
        assert_eq!(parse_retry_after_message("Please try again in 2 seconds"), Duration::from_secs(2));

        let policy = RetryPolicy::default();
        let rate = err(429, Some("rate_limit_exceeded"), None, "try again in 2s");
        assert_eq!(retry_delay(&policy, 0, Some(&rate), None, now, 0.5), Duration::from_secs(2));
        assert_eq!(retry_delay(&policy, 0, None, Some("999"), now, 0.0), policy.max_backoff);
    }

    #[test]
    fn backs_off_exponentially_with_jitter() {
        let now = chrono::Utc::now();
        let policy = RetryPolicy::default();
        assert_eq!(retry_delay(&policy, 0, None, None, now, 0.0), Duration::from_secs(1));
        assert_eq!(retry_delay(&policy, 2, None, None, now, 0.0), Duration::from_secs(4));
        assert_eq!(retry_delay(&policy, 10, None, None, now, 0.0), Duration::from_secs(30));
        assert_eq!(retry_delay(&policy, 0, None, None, now, 1.0), Duration::from_millis(800));
        let overloaded = err(503, Some("server_is_overloaded"), None, "");
        assert_eq!(
            retry_delay(&policy, 0, Some(&overloaded), None, now, 0.0),
            Duration::from_secs(10)
        );
    }
}
