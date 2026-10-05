//! Qwen Cloud / Alibaba Cloud Model Studio endpoints.
//!
//! Model Studio offers the same models through several *plans*, each with its
//! own hostnames, region endpoints and API-key variable. This module is the one
//! source of truth for the plan × region matrix: the `qwen` preset's default
//! endpoint and the endpoint picker in `/settings` are both derived from
//! [`ENDPOINTS`], so a new region or plan is added here once and appears
//! everywhere at once — the preset and the picker cannot drift apart.
//!
//! Mirror of qwen-code's `coding-plan` / `token-plan` / `alibabaStandard`
//! provider presets (`@qwen-code/qwen-code`, 0.21.x).

/// A Model Studio billing plan. The plan decides the API-key variable and the
/// set of regional hostnames; it does not change the wire protocol (all are
/// OpenAI Chat Completions).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QwenPlan {
    /// Model Studio on-demand ("Standard API key"): a plain DashScope key.
    Standard,
    /// Token Plan: usage-based billing with a dedicated endpoint.
    TokenPlan,
    /// Coding Plan: a weekly-quota subscription.
    CodingPlan,
}

impl QwenPlan {
    /// The environment variable holding this plan's API key.
    pub const fn api_key_env(self) -> &'static str {
        match self {
            QwenPlan::Standard => "DASHSCOPE_API_KEY",
            QwenPlan::TokenPlan => "BAILIAN_TOKEN_PLAN_API_KEY",
            QwenPlan::CodingPlan => "BAILIAN_CODING_PLAN_API_KEY",
        }
    }

    /// Label for the endpoint picker, e.g. `Token Plan`.
    pub const fn label(self) -> &'static str {
        match self {
            QwenPlan::Standard => "Standard API key",
            QwenPlan::TokenPlan => "Token Plan",
            QwenPlan::CodingPlan => "Coding Plan",
        }
    }
}

/// One Model Studio endpoint: a plan, a region and its base URL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QwenEndpoint {
    pub plan: QwenPlan,
    /// Short region name, e.g. `China (Beijing)`.
    pub region: &'static str,
    /// OpenAI-compatible base URL (no trailing slash).
    pub base_url: &'static str,
}

impl QwenEndpoint {
    /// The row shown in the endpoint picker, e.g. `Token Plan — China (Beijing)`.
    pub fn label(&self) -> String {
        format!("{} — {}", self.plan.label(), self.region)
    }
}

/// Every Model Studio endpoint nano-coder can be pointed at. The `qwen`
/// preset's default (`default_endpoint`) is the first entry, and the preset's
/// base URL and API-key variable are derived from it — adding a region here
/// adds it to the preset default and the picker alike.
pub const ENDPOINTS: &[QwenEndpoint] = &[
    QwenEndpoint {
        plan: QwenPlan::Standard,
        region: "Singapore (International)",
        base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::Standard,
        region: "China (Beijing)",
        base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::Standard,
        region: "US (Virginia)",
        base_url: "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::Standard,
        region: "China (Hong Kong)",
        base_url: "https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::TokenPlan,
        region: "China (Beijing)",
        base_url: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::TokenPlan,
        region: "Singapore (International)",
        base_url: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::CodingPlan,
        region: "China (Beijing)",
        base_url: "https://coding.dashscope.aliyuncs.com/v1",
    },
    QwenEndpoint {
        plan: QwenPlan::CodingPlan,
        region: "Singapore (International)",
        base_url: "https://coding-intl.dashscope.aliyuncs.com/v1",
    },
];

/// The default endpoint for the `qwen` preset: the first entry — Model Studio
/// Standard in Singapore, which is what the preset has always used.
pub fn default_endpoint() -> &'static QwenEndpoint {
    &ENDPOINTS[0]
}

/// The endpoint whose `base_url` matches `url` exactly (after trimming a
/// trailing slash), or `None` for a custom URL. Matching is exact so a
/// self-hosted gateway that merely shares a hostname is not mistaken for a plan
/// endpoint.
pub fn endpoint_for_url(url: &str) -> Option<&'static QwenEndpoint> {
    let url = url.trim_end_matches('/');
    ENDPOINTS.iter().find(|endpoint| endpoint.base_url == url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn every_plan_and_region_is_named() {
        // The user-facing matrix the task asks for: all three plans, each with
        // its China and International (plus the Standard-only extra regions).
        assert_eq!(ENDPOINTS.iter().filter(|e| e.plan == QwenPlan::Standard).count(), 4);
        assert_eq!(ENDPOINTS.iter().filter(|e| e.plan == QwenPlan::TokenPlan).count(), 2);
        assert_eq!(ENDPOINTS.iter().filter(|e| e.plan == QwenPlan::CodingPlan).count(), 2);
        for plan in [QwenPlan::Standard, QwenPlan::TokenPlan, QwenPlan::CodingPlan] {
            let regions: Vec<&str> = ENDPOINTS.iter().filter(|e| e.plan == plan).map(|e| e.region).collect();
            assert!(regions.iter().any(|r| r.contains("China")), "{plan:?} needs a China region: {regions:?}");
            assert!(
                regions.iter().any(|r| r.contains("International")),
                "{plan:?} needs an international region: {regions:?}"
            );
        }
    }

    #[test]
    fn every_plan_has_its_own_api_key_variable() {
        // The API key is bound to the plan, not just the region: a Coding Plan
        // key is rejected on the Standard host and vice versa.
        assert_eq!(QwenPlan::Standard.api_key_env(), "DASHSCOPE_API_KEY");
        assert_eq!(QwenPlan::TokenPlan.api_key_env(), "BAILIAN_TOKEN_PLAN_API_KEY");
        assert_eq!(QwenPlan::CodingPlan.api_key_env(), "BAILIAN_CODING_PLAN_API_KEY");
        // ...and the three are distinct, so retargeting a plan always changes it.
        let envs: BTreeSet<&str> =
            [QwenPlan::Standard, QwenPlan::TokenPlan, QwenPlan::CodingPlan].iter().map(|p| p.api_key_env()).collect();
        assert_eq!(envs.len(), 3);
    }

    #[test]
    fn endpoints_are_unique_and_well_formed() {
        let labels: BTreeSet<String> = ENDPOINTS.iter().map(|e| e.label()).collect();
        let urls: BTreeSet<&str> = ENDPOINTS.iter().map(|e| e.base_url).collect();
        assert_eq!(labels.len(), ENDPOINTS.len(), "plan + region rows must be unique");
        assert_eq!(urls.len(), ENDPOINTS.len(), "endpoint base URLs must be unique");
        for endpoint in ENDPOINTS {
            assert!(endpoint.base_url.starts_with("https://"), "{endpoint:?} must be https");
            assert!(!endpoint.base_url.ends_with('/'), "{} must not end with a slash", endpoint.base_url);
            assert!(endpoint.label().contains(endpoint.plan.label()));
            assert!(endpoint.label().contains(endpoint.region));
        }
    }

    #[test]
    fn the_default_endpoint_matches_the_historical_preset() {
        // The `qwen` preset has always pointed at the Singapore international
        // DashScope endpoint; deriving it from the table must not silently move
        // existing `qwen/...` users to another host.
        let default = default_endpoint();
        assert_eq!(default.plan, QwenPlan::Standard);
        assert_eq!(default.base_url, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1");
        assert_eq!(default.plan.api_key_env(), "DASHSCOPE_API_KEY");
        assert_eq!(default_endpoint(), &ENDPOINTS[0]);
    }

    #[test]
    fn urls_round_trip_to_the_same_endpoint() {
        for endpoint in ENDPOINTS {
            assert_eq!(endpoint_for_url(endpoint.base_url), Some(endpoint));
            // A trailing slash is the only tolerance: the resolve path strips it.
            assert_eq!(endpoint_for_url(&format!("{}/", endpoint.base_url)), Some(endpoint));
        }
        assert_eq!(endpoint_for_url("https://example.com/v1"), None);
        // A host that merely *contains* a plan base URL is not that plan.
        assert_eq!(endpoint_for_url("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/extra"), None);
    }
}
