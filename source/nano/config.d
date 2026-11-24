/// Configuration: `~/.config/nano-coder/config.toml` (same file and keys as the
/// Rust nano-coder; keys this port doesn't implement yet are ignored), plus
/// built-in provider presets.
module nano.config;

@safe:

import std.conv : to;
import nano.safeio : jsonText, jsonPretty;

import nano.skills : SkillsConfig;
import nano.memory : MemoryMode, parseMemoryMode, defaultExpiryDays, RecallMode, parseRecallMode;

import std.json;
import nano.sandbox : SandboxConfig;
import std.file : exists, readText;
import std.path : buildPath, expandTilde;
import std.process : environment, executeShell;
import std.string : strip, indexOf, startsWith;
import std.algorithm : stripRight;
import std.format : format;
import std.math : isNaN;
import nano.toml;
import std.typecons : Nullable;
import nano.thinking : Thinking;
import nano.result : orThrow, unwrap;

/// A temperature setting: null = unset, NaN = "default" (send none).
alias TemperatureSetting = Nullable!double;

/// Settings for one model of a provider (`[providers.NAME.models."MODEL"]`).
struct ModelSettings
{
    TemperatureSetting temperature;
    Nullable!Thinking thinking;
    /// Whether this model can view images (overrides detection).
    Nullable!bool vision;
    /// Levels this model accepts; set only when `hasThinkingLevels`.
    string[] thinkingLevels;
    bool hasThinkingLevels;
    /// Display name in the model picker (`list_models = "configured"`).
    string name;
    /// Endpoint for this model, overriding the provider's `base_url` (null:
    /// unset), e.g. an OpenRouter workspace serving each model on one region.
    string baseUrl;

    static ModelSettings fromJSON(JSONValue o) pure
    {
        ModelSettings m;
        m.overlay(o);
        return m;
    }

    /// Set the fields present in `o`, keeping the rest (a later layer).
    void overlay(JSONValue o) pure
    {
        if (auto v = "temperature" in o) temperature = numberOrDefault(*v);
        if (auto v = "thinking" in o) thinking = Thinking.parse(v.str).orThrow!(e => new Exception(e));
        if (auto v = "vision" in o) vision = v.boolean;
        if (auto v = "thinking_levels" in o) thinkingLevels = strings(*v), hasThinkingLevels = true;
        if (auto v = "name" in o) name = v.str;
        if (auto v = "base_url" in o) baseUrl = v.str;
    }
}

string[] strings(JSONValue v) pure
{
    string[] o;
    foreach (x; v.arrayNoRef) o ~= x.str;
    return o;
}

enum ProviderKind { openai, anthropic, githubCopilot, mock }

/// A client that speaks a real provider API reports which (Rust
/// `LLMClient::kind`). The agent takes the kind from the live client, not the
/// config: a test double implements no kind, and is then treated as `mock`.
interface KindedClient
{
    ProviderKind kind() const;
}

ProviderKind parseKind(string s) pure
{
    switch (s)
    {
        case "openai", "openai-compatible", "openai-chat": return ProviderKind.openai;
        case "anthropic": return ProviderKind.anthropic;
        case "github-copilot", "github_copilot", "copilot": return ProviderKind.githubCopilot;
        case "muse", "muse-code":
            throw new Exception("the unofficial Meta Muse Code provider was removed (it stopped working); "
                ~ "use another provider");
        case "mock": return ProviderKind.mock;
        default: throw new Exception(format("unknown provider kind %s (openai, anthropic, github-copilot, mock)", s));
    }
}

struct ProviderConfig
{
    bool hasKind;
    ProviderKind kind;
    string baseUrl;
    string apiKey;
    string apiKeyEnv;
    bool apiKeyEnvSet;
    string apiKeyCommand;
    string defaultModel;
    string[string] headers;
    JSONValue extraBody;
    string[] dropParams;
    string maxTokensParam;
    long contextWindow;
    bool stream = true;
    TemperatureSetting temperature;
    Nullable!Thinking thinking;
    Nullable!bool vision;
    string[] thinkingLevels;
    bool hasThinkingLevels;
    ModelSettings[string] models;
    /// `list_models = "configured"`: list only `models` (with their names)
    /// instead of the endpoint's `/models`.
    bool configuredList;
    /// `disabled = true`: hidden from listings; naming it is an error.
    bool disabled;
    /// `hidden = true`: left out of listings and pickers, but still usable
    /// when named in a model spec (the mock preset is hidden by default).
    bool hidden;
    /// `timeout_secs`, the stream idle timeout; 0 (unset) means
    /// `defaultTimeoutSecs()`.
    long timeoutSecs;
    long maxRetries = 5;
    long retryInitialBackoffMs = -1, retryMaxBackoffMs = -1;
    ushort[] retryableStatuses;
    bool hasRetryableStatuses;

    /// The retry policy these settings describe.
    imported!"nano.retry".RetryPolicy retryPolicy() pure const
    {
        import core.time : msecs;
        imported!"nano.retry".RetryPolicy r;
        r.maxRetries = maxRetries;
        if (retryInitialBackoffMs >= 0) r.initialBackoff = retryInitialBackoffMs.msecs;
        if (retryMaxBackoffMs >= 0) r.maxBackoff = retryMaxBackoffMs.msecs;
        return r;
    }

    /// HTTP statuses worth retrying.
    const(ushort)[] statuses() pure const
    {
        import nano.retry : defaultRetryableStatuses;
        return hasRetryableStatuses ? retryableStatuses : defaultRetryableStatuses;
    }
    /// Send the model's reasoning back on later turns (null: on for models
    /// that reason over the Responses API).
    Nullable!bool replayReasoning;

    /// Merge `extra_body` into a built request body (nested objects field by
    /// field, so an unrelated option doesn't clobber a generated sibling), then
    /// strip `drop_params`. `temperature` is owned by the resolver and skipped.
    void finishBody(ref JSONValue b) const
    {
        import nano.safeio : jsonCopy;
        static void mergeObject(ref JSONValue into, const JSONValue from) @safe
        {
            foreach (k, v; from.objectNoRef)
            {
                if (auto e = k in into.objectNoRef)
                    if (e.type == JSONType.object && v.type == JSONType.object) { mergeObject(*e, v); continue; }
                into[k] = jsonCopy(v);
            }
        }
        if (extraBody.type == JSONType.object)
            foreach (k, v; extraBody.objectNoRef)
            {
                if (k == "temperature") continue;
                if (auto e = k in b.objectNoRef)
                    if (e.type == JSONType.object && v.type == JSONType.object) { mergeObject(*e, v); continue; }
                b[k] = jsonCopy(v);
            }
        foreach (string d; dropParams) b.objectNoRef.remove(d);
    }

    /// Overlay the fields set in `o` (a user table) onto this preset.
    void merge(JSONValue o) pure
    {
        if (auto v = "kind" in o) { hasKind = true; kind = parseKind(v.str); }
        if (auto v = "base_url" in o) baseUrl = v.str;
        if (auto v = "api_key" in o) apiKey = v.str;
        if (auto v = "api_key_env" in o) { apiKeyEnv = v.str; apiKeyEnvSet = true; }
        if (auto v = "api_key_command" in o) apiKeyCommand = v.str;
        if (auto v = "default_model" in o) defaultModel = v.str;
        if (auto v = "headers" in o) foreach (k, h; v.objectNoRef) headers[k] = h.str;
        if (auto v = "extra_body" in o) extraBody = *v;
        if (auto v = "drop_params" in o) { dropParams = null; foreach (p; v.arrayNoRef) dropParams ~= p.str; }
        if (auto v = "max_tokens_param" in o) maxTokensParam = v.str;
        if (auto v = "context_window" in o) contextWindow = v.integer;
        if (auto v = "stream" in o) stream = v.boolean;
        if (auto v = "temperature" in o) temperature = numberOrDefault(*v);
        if (auto v = "thinking" in o) thinking = Thinking.parse(v.str).orThrow!(e => new Exception(e));
        if (auto v = "vision" in o) vision = v.boolean;
        if (auto v = "thinking_levels" in o) thinkingLevels = strings(*v), hasThinkingLevels = true;
        if (auto v = "models" in o)
            foreach (name, m; v.objectNoRef)
            {
                if (auto e = name in models) e.overlay(m);
                else models[name] = ModelSettings.fromJSON(m);
            }
        if (auto v = "list_models" in o)
        {
            if (v.str != "configured" && v.str != "endpoint")
                throw new Exception(format("list_models must be \"endpoint\" or \"configured\", not \"%s\"", v.str));
            configuredList = v.str == "configured";
        }
        if (auto v = "disabled" in o) disabled = v.boolean;
        if (auto v = "hidden" in o) hidden = v.boolean;
        if (auto v = "timeout_secs" in o) timeoutSecs = v.integer;
        if (auto v = "max_retries" in o) maxRetries = v.integer;
        if (auto v = "retry_initial_backoff_ms" in o) retryInitialBackoffMs = v.integer;
        if (auto v = "retry_max_backoff_ms" in o) retryMaxBackoffMs = v.integer;
        if (auto v = "retryable_statuses" in o)
        {
            hasRetryableStatuses = true;
            retryableStatuses = null;
            foreach (st; v.arrayNoRef) retryableStatuses ~= st.integer.to!ushort;
        }
        if (auto v = "replay_reasoning" in o) replayReasoning = v.boolean;
    }

    /// The configured models as (id, display name), sorted by id, when
    /// `list_models = "configured"`; null means list from the endpoint.
    string[2][] configuredModels() pure const
    {
        import std.algorithm : sort;
        if (!configuredList) return null;
        string[2][] o;
        foreach (id, m; models) o ~= [id, m.name];
        o.sort!((a, b) => a[0] < b[0]);
        return o;
    }
}

/// Default provider stream idle timeout (`timeout_secs`): the longest silence
/// between received bytes before a request fails. It must stay below a
/// supervising worker's idle-kill budget (`workerIdleKillSecs`), or the worker
/// kills the run before a stalled stream is detected and retried (Rust #179).
enum long defaultTimeoutSecsValue = 120;
/// The c8ctl-nano worker's documented idle-kill budget.
enum long workerIdleKillSecs = 300;
static assert(defaultTimeoutSecsValue < workerIdleKillSecs,
    "default provider timeout must stay below the worker idle-kill budget");
/// Overrides the default timeout in seconds; an explicit `timeout_secs` wins.
enum providerTimeoutSecsEnv = "NANO_CODER_PROVIDER_TIMEOUT_SECS";

/// A positive integer env override, or 0 when unset or non-numeric (a bad
/// value means "no override", never a crash at startup).
private long envPositiveLong(string name)
{
    import std.conv : to;
    import std.string : strip;
    try
    {
        auto v = environment.get(name, "").strip.to!long;
        if (v > 0) return v;
    }
    catch (Exception) {} // a non-numeric env value is ignored; use the default
    return 0;
}

/// The effective default stream idle timeout: the env override when it holds
/// a positive integer, else `defaultTimeoutSecsValue`.
long defaultTimeoutSecs()
{
    auto v = envPositiveLong(providerTimeoutSecsEnv);
    return v > 0 ? v : defaultTimeoutSecsValue;
}

/// The default bash heartbeat interval (`bash_heartbeat_secs`): how often a
/// running bash call emits a supervisor-visible "still running" note. It must
/// stay below the worker idle-kill budget, or a healthy long command looks dead.
enum long defaultBashHeartbeatSecsValue = 60;
static assert(defaultBashHeartbeatSecsValue < workerIdleKillSecs,
    "default bash heartbeat must stay below the worker idle-kill budget");
/// Overrides the heartbeat interval in seconds; an explicit
/// `bash_heartbeat_secs` config value wins over it.
enum bashHeartbeatSecsEnv = "NANO_CODER_BASH_HEARTBEAT_SECS";

/// The effective bash heartbeat interval in seconds: an explicit `configSecs`
/// (> 0) wins, else the env override when it holds a positive integer, else
/// `defaultBashHeartbeatSecsValue`.
long bashHeartbeatIntervalSecs(long configSecs)
{
    if (configSecs > 0) return configSecs;
    auto v = envPositiveLong(bashHeartbeatSecsEnv);
    return v > 0 ? v : defaultBashHeartbeatSecsValue;
}

/// The names of the providers to offer in listings: `disabled` and `hidden` ones dropped, sorted.
string[] enabledProviderNames(const ProviderConfig[string] providers) pure
{
    import std.algorithm : sort;
    string[] o;
    foreach (k, p; providers) if (p.isVisible) o ~= k;
    o.sort();
    return o;
}

/// Whether a provider appears in listings and pickers.
bool isVisible(const ref ProviderConfig p) pure nothrow { return !p.disabled && !p.hidden; }

/// Whether a model spec (`provider/model`, or a bare model on the default
/// provider) names a visible provider, so it may be offered as a suggestion.
/// A spec on a hidden or removed provider stays usable but isn't offered.
bool specVisible(string spec, const ProviderConfig[string] providers, string defaultProvider) pure
{
    import std.string : indexOf;
    auto slash = spec.indexOf('/');
    auto name = slash > 0 && spec[0 .. slash] in providers ? spec[0 .. slash] : defaultProvider;
    auto p = name in providers;
    return p !is null && (*p).isVisible;
}

/// Refuse a spec naming a disabled provider.
void checkEnabled(string name, const ref ProviderConfig p) pure
{
    if (p.disabled)
        throw new Exception(format("provider \"%s\" is disabled (`disabled = true` in [providers.%s])", name, name));
}

/// A number, or NaN for `"default"` (send none).
double numberOrDefault(JSONValue v) pure
{
    if (v.type == JSONType.string)
    {
        if (v.str == "default") return double.nan;
        throw new Exception("temperature must be a number or \"default\"");
    }
    if (v.type == JSONType.integer) return double(v.integer);
    if (v.type == JSONType.uinteger) return double(v.uinteger);
    if (v.type != JSONType.float_) throw new Exception("temperature must be a number or \"default\"");
    // TOML reads nan/inf as floats; NaN here would silently mean "default".
    import std.math : isFinite;
    if (!isFinite(v.floating)) throw new Exception("temperature must be finite");
    return v.floating;
}

ProviderConfig preset(ProviderKind kind, string url, string env, string model = null) pure
{
    ProviderConfig p;
    p.hasKind = true;
    p.kind = kind;
    p.baseUrl = url;
    p.apiKeyEnv = env;
    p.defaultModel = model;
    return p;
}

ProviderConfig[string] presets() pure
{
    alias O = ProviderKind.openai;
    ProviderConfig[string] m;
    m["openai"] = preset(O, "https://api.openai.com/v1", "OPENAI_API_KEY");
    m["openai"].maxTokensParam = "max_completion_tokens";
    m["anthropic"] = preset(ProviderKind.anthropic, "https://api.anthropic.com/v1", "ANTHROPIC_API_KEY");
    m["openrouter"] = preset(O, "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY");
    m["fireworks"] = preset(O, "https://api.fireworks.ai/inference/v1", "FIREWORKS_API_KEY");
    m["groq"] = preset(O, "https://api.groq.com/openai/v1", "GROQ_API_KEY");
    m["together"] = preset(O, "https://api.together.xyz/v1", "TOGETHER_API_KEY");
    m["deepseek"] = preset(O, "https://api.deepseek.com/v1", "DEEPSEEK_API_KEY");
    m["kimi"] = preset(O, "https://api.moonshot.ai/v1", "MOONSHOT_API_KEY");
    // K3 fixes temperature and rejects other values; it also needs its
    // reasoning replayed with each assistant message.
    m["kimi"].maxTokensParam = "max_completion_tokens";
    m["kimi"].dropParams = ["temperature"];
    m["kimi"].replayReasoning = true;
    m["mistral"] = preset(O, "https://api.mistral.ai/v1", "MISTRAL_API_KEY");
    m["gemini"] = preset(O, "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY");
    // No base_url: the session token names the API endpoint.
    m["github-copilot"] = preset(ProviderKind.githubCopilot, null, "GITHUB_COPILOT_OAUTH_TOKEN", "gpt-4.1");
    // The endpoint is minted alongside the API key on login.
    {
        import nano.qwen : defaultEndpoint;
        m["qwen"] = preset(O, defaultEndpoint.baseUrl, defaultEndpoint.apiKeyEnv);
    }
    m["ollama"] = preset(O, "http://localhost:11434/v1", null);
    m["llamacpp"] = preset(O, "http://localhost:8080/v1", null);
    m["mock"] = preset(ProviderKind.mock, null, null, "mock");
    m["mock"].hidden = true;
    return m;
}

struct Config
{
    string model = "gpt-4o-mini";
    string defaultProvider = "mock";
    double temperature = 0.7;
    /// Top-level `context_window`: overrides every provider's.
    long contextWindow;
    /// The retired `renderer` setting. Only the frame renderer remains (Rust
    /// #133); the key is still read so an old `renderer = "legacy"` loads and
    /// gets a one-line notice (`retiredRendererNotice`). Never written.
    string retiredRenderer;
    /// Dim `HH:MM:SS` stamps on the prompt and transcript (`timestamps`).
    bool timestamps = true;
    /// Output detail (`verbosity`): quiet, normal, verbose or debug.
    imported!"nano.ui".Verbosity verbosity = imported!"nano.ui".Verbosity.normal;
    /// Global thinking level and vision override.
    Thinking thinking;
    Nullable!bool vision;
    long maxTokens = 0;
    string systemPrompt;
    /// Ask a model for a few-word title per session (`session_titles`).
    bool sessionTitles;
    /// The model titles come from (`title_model`); null uses the session's.
    string titleModel;
    /// Offer the `agent` tool (read-only sub-agents, `subagents`).
    bool subagents = true;
    /// The model sub-agents run on (`subagent_model`); null: the session's.
    string subagentModel;
    /// Sub-agents running at once (`subagent_max_concurrency`).
    long subagentMaxConcurrency = 4;
    /// Per sub-agent caps (`subagent_timeout_secs`, `subagent_max_turns`,
    /// `subagent_max_tokens`).
    long subagentTimeoutSecs = 600, subagentMaxTurns = 40, subagentMaxTokens = 1_000_000;
    /// The curated models the `agent` tool may pick (`[[subagent_models]]`);
    /// empty: any model, defaulting to `subagent_model`.
    SubagentModel[] subagentModels;
    /// Problems found while loading (bad `[[subagent_models]]` entries),
    /// reported at startup; never fatal.
    string[] warnings;
    long maxIterations = 0;
    long bashTimeoutSecs = 600;
    /// Bash heartbeat interval (`bash_heartbeat_secs`): how often a running
    /// bash call emits a supervisor-visible "still running" note. 0 (the
    /// default) means unset — `defaultBashHeartbeatSecsValue` applies.
    long bashHeartbeatSecs = 0;
    ProviderConfig[string] providers;
    /// Providers with a `[providers.*]` table in the config file (presets the user touched, or their own).
    string[] userProviders;
    SkillsConfig skills;
    MemoryMode memory = MemoryMode.on;
    /// `memory_recall`: how tool calls recall memories — "entity" (default) or
    /// "anchor" (the pre-entity substring match, kept to compare or roll back).
    string memoryRecall = "entity";
    /// Hooks: `disable_hooks` (or `--no-hooks`), `disable_project_hooks`,
    /// `claude_user_hooks`, and nano's own `[hooks]` table (Claude's shape).
    /// Offer the `plan_*` tools (`plan_tools`, default on).
    bool planTools = true;
    /// Offer `report_outcome` (`outcome_tool`, default on).
    bool outcomeTool = true;
    /// System reminders and the repeated-call loop detector.
    bool reminders = true;
    /// Compact automatically at `autoCompactThreshold` of the context window.
    bool autoCompact = true;
    /// Check for a newer release in the background (interactive sessions).
    bool checkUpdates = true;
    /// After an update, show what changed since the version that ran last (#282).
    bool showReleaseNotes = true;
    /// Instruction files (AGENTS.md and friends, the user's own, rules).
    bool projectInstructions = true;
    string[] projectInstructionFiles = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"];
    string[] userInstructionFiles = ["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"];
    string[] userRulesDirs = ["~/.claude/rules"];
    bool instructionImportsOutsideProject;
    double autoCompactThreshold = 0.8;
    /// `standard` or `smart` (summary cites the session log; history tools).
    string compactionMode = "smart";
    /// Pin the user's requests verbatim after each compaction summary.
    bool compactionPinRequests = true;
    /// Compact at the idle prompt, once quiet for the hold (Rust #186).
    bool idleCompact = true;
    /// Persist conversations as JSONL session logs (false: like --no-session).
    bool persistSessions = true;
    /// Let the history tools read other sessions' logs (`cross_session_history`,
    /// issue #271): the `sessions_list` tool and the `session` argument on
    /// `history_search`/`history_read`. Off, the tools behave as before and
    /// other sessions' logs are never opened.
    bool crossSessionHistory = true;
    /// Send and receive messages between running sessions (issue #272):
    /// this session listens on a registry socket, appears reachable in
    /// `sessions_list`, and offers the `session_send` tool. Off (the
    /// default), it opens no socket and has no `session_send`.
    bool sessionMessages;
    /// An incoming message waits for the user to accept it before it is
    /// queued (`session_messages_confirm`, default true); off, it is queued
    /// (or starts a turn) at once.
    bool sessionMessagesConfirm = true;
    /// The most hops a message thread between sessions may take
    /// (`session_messages_max_hops`, default 4; issue #350).
    uint sessionMessagesMaxHops = 4;
    /// The most messages one session may send another per hour
    /// (`session_messages_max_per_hour`, default 10, 0: no cap; issue #350).
    uint sessionMessagesMaxPerHour = 10;
    /// Inter-session messages for `--acp` sessions (`acp_session_messages`,
    /// default false; issue #347). ACP ignores `session_messages`: a worker
    /// runs unattended, so it joins the registry only when opted in here or
    /// with `--session-messages`.
    bool acpSessionMessages;
    /// Session log directory (empty: the platform data folder).
    string sessionDir;
    /// Gzip session logs idle this many days at startup (0: never; issue #205).
    long sessionCompressAfterDays = 14;
    /// Delete session logs untouched this many days (0: keep forever), except
    /// named sessions (issue #205).
    long sessionRetentionDays;
    /// Ask once per turn for a check's evidence before accepting a completed
    /// outcome when files were edited after the last bash call. ACP turns it off.
    bool verifyBeforeComplete = true;
    /// Seconds the prompt must sit untouched before an idle compaction
    /// (0 = unset: `lineedit.idleCompactHold`).
    long idleCompactHoldSecs;
    bool disableHooks;
    bool disableProjectHooks;
    bool claudeUserHooks = true;
    JSONValue hooks;
    /// `[sandbox]`: OS sandbox for shell commands and project hooks.
    SandboxConfig sandbox;
    string memoryDir;
    long memoryExpiryDays = defaultExpiryDays;
    string path;

    static string defaultPath()
    {
        if (auto x = environment.get("NANO_CODER_CONFIG")) return x;
        if (auto x = environment.get("XDG_CONFIG_HOME")) return buildPath(x, "nano-coder", "config.toml");
        return buildPath(expandTilde("~"), ".config", "nano-coder", "config.toml");
    }

    /// A notice for a config that still sets the retired `renderer` option
    /// to anything but `frame` (the only renderer left).
    string retiredRendererNotice() pure const
    {
        import std.string : strip;
        if (retiredRenderer is null || retiredRenderer.strip == "frame") return null;
        return format("Note: renderer = %s is no longer available; using the frame renderer (remove the setting)",
            imported!"std.json".JSONValue(retiredRenderer).jsonText);
    }

    static Config load(string path)
    {
        Config c;
        c.providers = presets();
        c.path = path;
        if (!path.exists) return c;
        auto doc = parseToml(readText(path)).orThrow!(e => new Exception(e));
        if (auto v = "model" in doc) c.model = v.str;
        if (auto v = "default_provider" in doc) c.defaultProvider = v.str;
        if (auto v = "temperature" in doc) c.temperature = numberOrDefault(*v);
        if (auto v = "max_tokens" in doc) c.maxTokens = v.integer;
        if (auto v = "thinking" in doc) c.thinking = Thinking.parse(v.str).orThrow!(e => new Exception(e));
        if (auto v = "vision" in doc) c.vision = v.boolean;
        if (auto v = "timestamps" in doc) c.timestamps = v.boolean;
        if (auto v = "context_window" in doc) c.contextWindow = v.integer;
        if (auto v = "renderer" in doc) c.retiredRenderer = v.str;
        if (auto v = "system_prompt" in doc) c.systemPrompt = v.str;
        if (auto v = "verbosity" in doc) c.verbosity = imported!"nano.ui".parseVerbosity(v.str);
        if (auto v = "max_iterations" in doc) c.maxIterations = v.integer;
        if (auto v = "session_titles" in doc) c.sessionTitles = v.boolean;
        if (auto v = "title_model" in doc) c.titleModel = v.str;
        if (auto v = "subagents" in doc) c.subagents = v.boolean;
        if (auto v = "subagent_model" in doc) c.subagentModel = v.str;
        if (auto v = "subagent_max_concurrency" in doc) c.subagentMaxConcurrency = v.integer;
        if (auto v = "subagent_timeout_secs" in doc) c.subagentTimeoutSecs = v.integer;
        if (auto v = "subagent_max_turns" in doc) c.subagentMaxTurns = v.integer;
        if (auto v = "subagent_max_tokens" in doc) c.subagentMaxTokens = v.integer;
        if (auto v = "subagent_models" in doc) c.subagentModels = parseSubagentModels(*v, c.warnings);
        if (auto v = "bash_timeout_secs" in doc) c.bashTimeoutSecs = v.integer;
        if (auto v = "bash_heartbeat_secs" in doc) c.bashHeartbeatSecs = v.integer;
        if (auto v = "plan_tools" in doc) c.planTools = v.boolean;
        if (auto v = "outcome_tool" in doc) c.outcomeTool = v.boolean;
        if (auto v = "reminders" in doc) c.reminders = v.boolean;
        if (auto v = "auto_compact" in doc) c.autoCompact = v.boolean;
        if (auto v = "check_updates" in doc) c.checkUpdates = v.boolean;
        if (auto v = "show_release_notes" in doc) c.showReleaseNotes = v.boolean;
        if (auto v = "project_instructions" in doc) c.projectInstructions = v.boolean;
        static string[] strs(JSONValue v) { string[] o; foreach (x; v.arrayNoRef) o ~= x.str; return o; }
        if (auto v = "project_instruction_files" in doc) c.projectInstructionFiles = strs(*v);
        if (auto v = "user_instruction_files" in doc) c.userInstructionFiles = strs(*v);
        if (auto v = "user_rules_dirs" in doc) c.userRulesDirs = strs(*v);
        if (auto v = "instruction_imports_outside_project" in doc) c.instructionImportsOutsideProject = v.boolean;
        if (auto v = "auto_compact_threshold" in doc)
            c.autoCompactThreshold = v.type == JSONType.integer ? v.integer : v.floating;
        if (auto v = "compaction_mode" in doc) c.compactionMode = v.str;
        if (auto v = "compaction_pin_requests" in doc) c.compactionPinRequests = v.boolean;
        if (auto v = "idle_compact" in doc) c.idleCompact = v.boolean;
        if (auto v = "persist_sessions" in doc) c.persistSessions = v.boolean;
        if (auto v = "cross_session_history" in doc) c.crossSessionHistory = v.boolean;
        if (auto v = "session_messages" in doc) c.sessionMessages = v.boolean;
        if (auto v = "acp_session_messages" in doc) c.acpSessionMessages = v.boolean;
        if (auto v = "session_messages_confirm" in doc) c.sessionMessagesConfirm = v.boolean;
        import std.algorithm : clamp;
        import std.conv : to;
        if (auto v = "session_messages_max_hops" in doc)
            c.sessionMessagesMaxHops = clamp(v.integer, 1, 1000).to!uint;
        if (auto v = "session_messages_max_per_hour" in doc)
            c.sessionMessagesMaxPerHour = clamp(v.integer, 0, 100_000).to!uint;
        if (auto v = "session_dir" in doc) c.sessionDir = v.str;
        if (auto v = "session_compress_after_days" in doc) c.sessionCompressAfterDays = v.integer;
        if (auto v = "session_retention_days" in doc) c.sessionRetentionDays = v.integer;
        if (auto v = "verify_before_complete" in doc) c.verifyBeforeComplete = v.boolean;
        if (auto v = "idle_compact_hold_secs" in doc) c.idleCompactHoldSecs = v.integer;
        if (auto v = "disable_hooks" in doc) c.disableHooks = v.boolean;
        if (auto v = "disable_project_hooks" in doc) c.disableProjectHooks = v.boolean;
        if (auto v = "claude_user_hooks" in doc) c.claudeUserHooks = v.boolean;
        if (auto v = "hooks" in doc) c.hooks = *v;
        if (auto v = "sandbox" in doc)
        {
            try c.sandbox = SandboxConfig.fromJSON(*v);
            catch (Exception e) throw new Exception("[sandbox]: " ~ e.msg);
        }
        if (auto v = "memory" in doc) c.memory = parseMemoryMode(v.str);
        if (auto v = "memory_dir" in doc) c.memoryDir = expandTilde(v.str);
        if (auto v = "memory_expiry_days" in doc) c.memoryExpiryDays = v.integer;
        if (auto v = "memory_recall" in doc) { parseRecallMode(v.str); c.memoryRecall = v.str.strip; }
        if (auto v = "skills" in doc) c.skills = SkillsConfig.fromToml(*v);
        if (auto ps = "providers" in doc)
            foreach (name, table; ps.objectNoRef)
            {
                auto p = name in c.providers ? c.providers[name] : ProviderConfig.init;
                p.merge(table);
                c.providers[name] = p;
                c.userProviders ~= name;
            }
        // Legacy top-level credentials apply to the default provider (OpenAI
        // when that is still the offline mock); explicit [providers.*] win.
        auto apiKey = "api_key" in doc, baseUrl = "base_url" in doc;
        if (apiKey !is null || baseUrl !is null)
        {
            if (c.defaultProvider == "mock") c.defaultProvider = "openai";
            auto own = "providers" in doc;
            auto table = own is null ? null : c.defaultProvider in own.objectNoRef;
            auto p = c.defaultProvider in c.providers ? c.providers[c.defaultProvider] : ProviderConfig.init;
            if (apiKey !is null && (table is null || "api_key" !in table.objectNoRef)) p.apiKey = apiKey.str;
            if (baseUrl !is null && (table is null || "base_url" !in table.objectNoRef)) p.baseUrl = baseUrl.str;
            c.providers[c.defaultProvider] = p;
        }
        return c;
    }
}

/// A provider with its model chosen and credentials resolved.
struct ResolvedProvider
{
    string name;
    string model;
    ProviderConfig config;
    string apiKey;
    /// Whether reasoning items are replayed (see `ProviderConfig.replayReasoning`).
    bool replayReasoning;
}

/// Whether this provider and model reason over the Responses API: they
/// need reasoning replayed and reject a non-default temperature.
bool reasonsOverResponses(ProviderKind kind, string model) pure @safe
{
    import nano.copilot : isReasoningModel;
    return kind == ProviderKind.githubCopilot && isReasoningModel(model);
}

/// Split `provider/model` (or a bare provider, or a bare model).
void parseModelSpec(string spec, const ProviderConfig[string] providers, string defaultProvider,
        out string provider, out string model) pure
{
    spec = spec.strip;
    auto slash = spec.indexOf('/');
    if (slash > 0 && spec[0 .. slash] in providers)
    {
        provider = spec[0 .. slash];
        model = spec[slash + 1 .. $];
        return;
    }
    if (slash < 0 && spec in providers)
    {
        provider = spec;
        return;
    }
    provider = defaultProvider;
    model = spec;
}

/// A base URL a request path can be appended to: http(s), no whitespace or
/// control characters, no query or fragment.
void validateHttpBaseUrl(string provider, string url) pure
{
    auto why = baseUrlProblem(provider, url);
    if (why.length) throw new Exception(why);
}

/// Why `url` is not a usable http(s) base URL for `provider`; null when it
/// is. Shared by `resolve` and the credential-free candidate filter.
string baseUrlProblem(string provider, string url) pure
{
    import std.uni : isWhite;
    import std.ascii : isControl;
    import std.string : toLower;
    if (url.strip.length == 0) return format("provider \"%s\" has an empty base_url", provider);
    foreach (dchar ch; url)
        if (isWhite(ch) || (ch < 0x80 && isControl(ch)) || (ch >= 0x80 && ch < 0xa0))
            return format("provider \"%s\" base_url \"%s\" must not contain whitespace or control characters", provider, url);
    auto colon = url.indexOf("://");
    if (colon <= 0) return format("provider \"%s\" has a malformed base_url \"%s\"", provider, url);
    auto scheme = url[0 .. colon].toLower;
    if (scheme != "http" && scheme != "https")
        return format("provider \"%s\" base_url \"%s\" must be http(s), not \"%s\"", provider, url, scheme);
    if (url.length == colon + 3) return format("provider \"%s\" has a malformed base_url \"%s\"", provider, url);
    if (url.indexOf('?') >= 0 || url.indexOf('#') >= 0)
        return format("provider \"%s\" base_url \"%s\" must not contain a query or fragment", provider, url);
    return null;
}

/// Why provider `name` (`pc`) has no usable endpoint for `model`, honouring
/// a model's own `base_url`; null when it has one. Fetches no key.
string endpointProblem(string name, const ref ProviderConfig pc, string model) pure
{
    string url = pc.baseUrl;
    if (auto ms = model in pc.models)
        if (ms.baseUrl !is null) url = ms.baseUrl;
    auto kind = pc.hasKind ? pc.kind : ProviderKind.openai;
    final switch (kind)
    {
        case ProviderKind.mock: return null;
        case ProviderKind.githubCopilot:
            return url.length ? baseUrlProblem(name, url) : null;
        case ProviderKind.openai, ProviderKind.anthropic:
            if (url is null) return format("provider \"%s\" has no base_url", name);
            return baseUrlProblem(name, url);
    }
}

/// One `[[subagent_models]]` entry: a model the `agent` tool offers, what
/// to use it for, and its own limits (0: the `subagent_*` default).
struct SubagentModel
{
    string model, use;
    long timeoutSecs, maxTurns, maxTokens;
}

/// The `[[subagent_models]]` entries of `v`; a bad entry is skipped with a
/// line in `warnings`, so a typo never stops the agent starting.
SubagentModel[] parseSubagentModels(const JSONValue v, ref string[] warnings) pure
{
    SubagentModel[] out_;
    if (v.type != JSONType.array)
    {
        warnings ~= "subagent_models must be a list of tables ([[subagent_models]]); ignored";
        return null;
    }
    foreach (i, e; v.arrayNoRef)
    {
        string bad(string why) { return format("subagent_models entry %s %s; skipped", i + 1, why); }
        if (e.type != JSONType.object) { warnings ~= bad("is not a table"); continue; }
        auto m = "model" in e.objectNoRef;
        if (m is null || m.type != JSONType.string || !m.str.strip.length) { warnings ~= bad("has no model"); continue; }
        SubagentModel s;
        s.model = m.str.strip;
        bool ok = true;
        if (auto u = "use" in e.objectNoRef)
        {
            if (u.type == JSONType.string) s.use = u.str.strip;
            else { warnings ~= bad("has a use that is not a string"); ok = false; }
        }
        foreach (key; ["timeout_secs", "max_turns", "max_tokens"])
            if (auto n = key in e.objectNoRef)
            {
                if (n.type != JSONType.integer || n.integer <= 0)
                {
                    warnings ~= bad("has a " ~ key ~ " that is not a positive integer");
                    ok = false;
                    break;
                }
                if (key == "timeout_secs") s.timeoutSecs = n.integer;
                else if (key == "max_turns") s.maxTurns = n.integer;
                else s.maxTokens = n.integer;
            }
        if (ok) out_ ~= s;
    }
    return out_;
}

/// Why `spec` doesn't name a usable model of `c` (an unknown or disabled
/// provider, or no model); null when it does. Fetches no key.
string specProblem(const ref Config c, string spec) pure
{
    string name, model;
    parseModelSpec(spec, c.providers, c.defaultProvider, name, model);
    auto pc = name in c.providers;
    if (pc is null) return format("unknown provider \"%s\"", name);
    if (pc.disabled) return format("provider \"%s\" is disabled", name);
    if (!model.length && !pc.defaultModel.length) return format("no model given and provider \"%s\" has no default_model", name);
    return endpointProblem(name, *pc, model.length ? model : pc.defaultModel);
}

/// The candidates of `c.subagentModels` that resolve against the configured
/// providers (without fetching keys); each one that doesn't is dropped with
/// a line in `warnings`.
SubagentModel[] usableSubagentModels(const ref Config c, ref string[] warnings) pure
{
    SubagentModel[] out_;
    foreach (m; c.subagentModels)
    {
        auto why = specProblem(c, m.model);
        if (why.length) warnings ~= format("subagent model %s dropped: %s", m.model, why);
        else out_ ~= m;
    }
    if (c.subagentModels.length && !out_.length)
        warnings ~= "no subagent_models resolve; sub-agents use subagent_model or the session's model";
    return out_;
}

unittest
{
    import nano.result : unwrap;
    import std.algorithm : canFind;
    string[] w;
    auto doc = parseToml(`[[subagent_models]]
model = "a/x"
use = "quick"
max_turns = 5
[[subagent_models]]
use = "no model"
[[subagent_models]]
model = "b/y"
timeout_secs = -1
[[subagent_models]]
model = "c/z"
`).unwrap("valid TOML");
    auto ms = parseSubagentModels(doc["subagent_models"], w);
    assert(ms.length == 2 && ms[0] == SubagentModel("a/x", "quick", 0, 5, 0) && ms[1].model == "c/z", format("%s", ms));
    assert(w.length == 2 && w[0].canFind("entry 2") && w[1].canFind("timeout_secs"), format("%s", w));
    w = null;
    assert(parseSubagentModels(JSONValue("x"), w) is null && w.length == 1);
}

unittest
{
    // Unresolvable candidates are dropped; all of them: a fallback warning.
    import std.algorithm : canFind;
    auto c = regionalConfig(`[[subagent_models]]
model = "mock/m"
[[subagent_models]]
model = "openrouter/x"
max_tokens = 9
`);
    assert(c.subagentModels.length == 2 && c.subagentModels[1].maxTokens == 9 && !c.warnings.length);
    string[] w;
    auto ok = usableSubagentModels(c, w);
    assert(ok.length == 1 && ok[0].model == "mock/m" && w.length == 1 && w[0].canFind("openrouter/x"), format("%s", w));
    c.subagentModels = c.subagentModels[1 .. $];
    w = null;
    assert(!usableSubagentModels(c, w).length && w.length == 2 && w[1].canFind("no subagent_models"));
    c.subagentModels = null;
    w = null;
    assert(!usableSubagentModels(c, w).length && !w.length);
}

unittest
{
    // A candidate whose endpoint `resolve` would reject is dropped up front:
    // no base_url, a bad provider base_url, a bad model-specific base_url.
    import std.algorithm : canFind;
    auto c = regionalConfig(`[[subagent_models]]
model = "openrouter-regional/amazon/nova-lite-v1"
[[subagent_models]]
model = "openrouter-regional/moonshotai/kimi-k3"
`);
    string[] w;
    assert(usableSubagentModels(c, w).length == 2 && !w.length, format("%s", w));
    c.providers["openrouter-regional"].models["amazon/nova-lite-v1"].baseUrl = "ftp://eu";
    w = null;
    auto ok = usableSubagentModels(c, w);
    assert(ok.length == 1 && w.length == 1 && w[0].canFind("http(s)"), format("%s", w));
    c.providers["openrouter-regional"].baseUrl = "https://x?q";
    w = null;
    assert(!usableSubagentModels(c, w).length && w[1].canFind("query"), format("%s", w));
    c.providers["openrouter-regional"].baseUrl = null;
    w = null;
    assert(!usableSubagentModels(c, w).length && w[1].canFind("no base_url"), format("%s", w));
}

ResolvedProvider resolve(const ref Config c, string spec)
{
    string name, model;
    parseModelSpec(spec, c.providers, c.defaultProvider, name, model);
    auto pc = name in c.providers;
    if (pc is null)
    {
        import std.algorithm : sort;
        import std.array : join;
        auto names = c.providers.keys.dup;
        names.sort();
        throw new Exception(format("unknown provider \"%s\" for model \"%s\"; known providers: %s", name, spec, names.join(", ")));
    }
    checkEnabled(name, *pc);
    ResolvedProvider r;
    r.name = name;
    // A deep copy out of the const table, so callers may edit it freely.
    r.config = imported!"nano.safeio".deepCopy(*pc);
    r.model = model.length ? model : pc.defaultModel;
    if (!r.model.length)
        throw new Exception(format("no model given for provider \"%s\" and it has no default_model", name));
    // A model's own `base_url` wins (regional OpenRouter hosts, #169).
    if (auto ms = r.model in pc.models)
        if (ms.baseUrl !is null) r.config.baseUrl = ms.baseUrl;
    if (!r.config.hasKind) r.config.kind = ProviderKind.openai;
    auto why = endpointProblem(name, *pc, r.model);
    if (why.length) throw new Exception(why);
    r.config.baseUrl = r.config.baseUrl.stripRight('/');
    if (r.config.timeoutSecs <= 0) r.config.timeoutSecs = defaultTimeoutSecs();
    r.replayReasoning = pc.replayReasoning.isNull ? reasonsOverResponses(r.config.kind, r.model) : pc.replayReasoning.get;
    r.apiKey = pc.apiKey;
    if (!r.apiKey.length && pc.apiKeyEnv.length) r.apiKey = environment.get(pc.apiKeyEnv, "");
    if (!r.apiKey.length && pc.apiKeyCommand.length)
    {
        import nano.keycmd : runKeyCommand;
        r.apiKey = runKeyCommand(name, pc.apiKeyCommand);
    }
    return r;
}

unittest
{
    auto ps = presets();
    string p, m;
    parseModelSpec("anthropic/claude-x", ps, "openai", p, m);
    assert(p == "anthropic" && m == "claude-x");
    parseModelSpec("ollama", ps, "openai", p, m);
    assert(p == "ollama" && m == "");
    parseModelSpec("weird/model", ps, "openai", p, m);
    assert(p == "openai" && m == "weird/model");
}

unittest
{
    import std.file : write, tempDir, remove;
    auto path = buildPath(tempDir, "nano-coder-config-test.toml");
    write(path, "model = \"box/m1\"\ntemperature = \"default\"\n[providers.box]\nkind = \"openai\"\nbase_url = \"http://x/v1\"\napi_key = \"k\"\n[providers.anthropic]\ndefault_model = \"c9\"\n");
    scope (exit) remove(path);
    auto c = Config.load(path);
    auto r = resolve(c, c.model);
    assert(r.name == "box" && r.model == "m1" && r.apiKey == "k" && r.config.baseUrl == "http://x/v1");
    assert(isNaN(c.temperature));
    assert(c.compactionMode == "smart", "smart compaction is the default");
    assert(Config.init.compactionMode == "smart");
    auto a = resolve(c, "anthropic");
    assert(a.model == "c9" && a.config.baseUrl == "https://api.anthropic.com/v1");
}

// The session, verification and idle-compaction keys: defaults and parsing.
unittest
{
    import std.file : write, tempDir, remove;
    Config d;
    assert(d.persistSessions && d.sessionDir is null && d.verifyBeforeComplete && d.idleCompact && d.idleCompactHoldSecs == 0);
    auto path = buildPath(tempDir, "nano-coder-keys-test.toml");
    write(path, "persist_sessions = false\nsession_dir = \"~/logs\"\nverify_before_complete = false\n"
        ~ "idle_compact = false\nidle_compact_hold_secs = 30\n");
    scope (exit) remove(path);
    auto c = Config.load(path);
    assert(!c.persistSessions && c.sessionDir == "~/logs" && !c.verifyBeforeComplete);
    assert(!c.idleCompact && c.idleCompactHoldSecs == 30);
}

// Issue #347: ACP sessions take messages only with `acp_session_messages`;
// `session_messages` alone (the interactive key) leaves it off.
unittest
{
    import std.file : write, tempDir, remove;
    import nano.acp : acpSessionMessages;
    assert(!Config.init.acpSessionMessages);
    auto path = buildPath(tempDir, "nano-coder-acp-messages-test.toml");
    scope (exit) remove(path);
    write(path, "session_messages = true\n");
    auto c = Config.load(path);
    assert(c.sessionMessages && !acpSessionMessages(false, c.acpSessionMessages));
    write(path, "session_messages = true\nacp_session_messages = true\n");
    assert(acpSessionMessages(false, Config.load(path).acpSessionMessages));
}

/// A regional OpenRouter workspace (#169): US by default, one model on EU, a
/// curated list, and the global preset disabled.
version (unittest) Config regionalConfig(string extra = "")
{
    import std.file : write, tempDir, remove;
    auto path = buildPath(tempDir, "nano-coder-regional-test.toml");
    write(path, `default_provider = "mock"
[providers.openrouter]
disabled = true
[providers.openrouter-regional]
kind = "openai"
base_url = "https://us.openrouter.ai/api/v1/"
api_key = "k"
list_models = "configured"
default_model = "moonshotai/kimi-k3"
[providers.openrouter-regional.models."moonshotai/kimi-k3"]
name = "Kimi K3"
[providers.openrouter-regional.models."amazon/nova-lite-v1"]
name = "Nova Lite 1.0"
base_url = "https://eu.openrouter.ai/api/v1"
` ~ extra);
    scope (exit) remove(path);
    return Config.load(path);
}

// rust: providers/mod.rs::a_models_base_url_overrides_the_providers
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    auto c = regionalConfig();
    auto eu = resolve(c, "openrouter-regional/amazon/nova-lite-v1");
    assert(eu.config.baseUrl == "https://eu.openrouter.ai/api/v1" && eu.model == "amazon/nova-lite-v1");
    auto us = resolve(c, "openrouter-regional/moonshotai/kimi-k3");
    assert(us.config.baseUrl == "https://us.openrouter.ai/api/v1", us.config.baseUrl);
    assert(resolve(c, "openrouter-regional/x-ai/grok-4.6").config.baseUrl == us.config.baseUrl);
    assert(resolve(c, "openrouter-regional").model == "moonshotai/kimi-k3");
    // A bad per-model host is refused like a bad provider host.
    auto bad = regionalConfig("[providers.openrouter-regional.models.\"m\"]\nbase_url = \"ftp://eu.openrouter.ai\"\n");
    assert(collectExceptionMsg(resolve(bad, "openrouter-regional/m")).canFind("must be http(s)"));
}

// rust: providers/mod.rs::a_hidden_provider_is_filtered_from_listings_but_still_usable
unittest // the mock preset is hidden from listings, yet `mock/...` still resolves
{
    import std.algorithm : canFind;
    Config c;
    c.providers = presets();
    assert(c.providers["mock"].hidden && !c.providers["mock"].disabled);
    auto shown = enabledProviderNames(c.providers);
    assert(!shown.canFind("mock") && shown.canFind("openai"));
    resolve(c, "mock/test");
    ProviderConfig internal;
    internal.merge(parseToml("hidden = true\n").unwrap("valid TOML"));
    c.providers["internal"] = internal;
    assert(!enabledProviderNames(c.providers).canFind("internal"));
}

// rust: commands.rs::model_suggestions_skip_hidden_current_and_recent_models
unittest // suggestions skip a current or recent model on a hidden provider
{
    Config c;
    c.providers = presets();
    assert(!specVisible("mock/test", c.providers, "openai"));
    assert(specVisible("openai/gpt-4o", c.providers, "openai"));
    assert(specVisible("bare-model", c.providers, "openai"));
    assert(!specVisible("bare-model", c.providers, "mock"));
    ProviderConfig internal;
    internal.hidden = true;
    c.providers["internal"] = internal;
    assert(!specVisible("internal/dev-model", c.providers, "openai"));
}

// rust: providers/mod.rs::default_timeout_stays_below_the_worker_idle_kill_budget
// rust: providers/mod.rs::env_override_sets_the_default_timeout
// rust: providers/mod.rs::config_timeout_secs_wins_over_the_env_override
// rust: providers/mod.rs::invalid_env_values_fall_back_to_the_default
unittest // the stream idle timeout: 120 s default, env override, explicit config wins
{
    // Unittests run one at a time, so changing the environment here is safe.
    {
        auto saved = environment.get(providerTimeoutSecsEnv);
        scope (exit)
        {
            if (saved is null) environment.remove(providerTimeoutSecsEnv);
            else environment[providerTimeoutSecsEnv] = saved;
        }
        environment.remove(providerTimeoutSecsEnv);
        Config c;
        c.providers = presets();
        auto r = resolve(c, "mock/m");
        assert(r.config.timeoutSecs == defaultTimeoutSecsValue && r.config.timeoutSecs < workerIdleKillSecs);
        environment[providerTimeoutSecsEnv] = "90";
        assert(resolve(c, "mock/m").config.timeoutSecs == 90);
        ProviderConfig x;
        x.merge(parseToml("kind = \"openai\"\nbase_url = \"http://localhost:1\"\ntimeout_secs = 45\n").unwrap("valid TOML"));
        c.providers["x"] = x;
        assert(resolve(c, "x/m").config.timeoutSecs == 45);
        foreach (v; ["", "abc", "-5", "0", "  "])
        {
            environment[providerTimeoutSecsEnv] = v;
            assert(defaultTimeoutSecs() == defaultTimeoutSecsValue, v);
        }
    }
}

// rust: providers/mod.rs::a_disabled_provider_is_hidden_and_refused
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    auto c = regionalConfig();
    assert(c.providers["openrouter"].disabled);
    assert(c.providers["openrouter"].baseUrl == "https://openrouter.ai/api/v1", "the preset merges");
    auto shown = enabledProviderNames(c.providers);
    assert(!shown.canFind("openrouter") && shown.canFind("openrouter-regional"));
    foreach (spec; ["openrouter/moonshotai/kimi-k3", "openrouter"])
        assert(collectExceptionMsg(resolve(c, spec)).canFind(`"openrouter" is disabled`), spec);
}

// rust: providers/mod.rs::a_configured_model_list_keeps_names_and_merges_over_presets
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    auto c = regionalConfig();
    string[2][] want = [["amazon/nova-lite-v1", "Nova Lite 1.0"], ["moonshotai/kimi-k3", "Kimi K3"]];
    assert(c.providers["openrouter-regional"].configuredModels == want);
    assert(c.providers["openai"].configuredModels is null, "presets list from the endpoint");
    // A later layer sets only some fields of a model: the rest survive.
    ProviderConfig p;
    p.merge(parseToml("list_models = \"configured\"\n[models.m]\nname = \"M\"\nbase_url = \"https://a/v1\"\n").unwrap("valid TOML"));
    p.merge(parseToml("list_models = \"endpoint\"\n[models.m]\nname = \"Em\"\n").unwrap("valid TOML"));
    assert(!p.configuredList && p.models["m"].name == "Em" && p.models["m"].baseUrl == "https://a/v1");
    assert(collectExceptionMsg(p.merge(parseToml("list_models = \"all\"\n").unwrap("valid TOML"))).canFind("list_models must be"));
}

// rust: config.rs::a_retired_legacy_renderer_setting_still_loads_with_a_notice
unittest // a retired `renderer = "legacy"` still loads, with a notice
{
    import std.algorithm : canFind;
    import std.file : write, tempDir, remove;
    auto path = buildPath(tempDir, "nano-coder-renderer-test.toml");
    scope (exit) remove(path);
    write(path, "model = \"work/x\"\n");
    assert(Config.load(path).retiredRendererNotice is null);
    write(path, "model = \"work/x\"\nrenderer = \"frame\"\n");
    assert(Config.load(path).retiredRendererNotice is null);
    write(path, "model = \"work/x\"\nrenderer = \"legacy\"\n");
    assert(Config.load(path).retiredRendererNotice
        == `Note: renderer = "legacy" is no longer available; using the frame renderer (remove the setting)`);
}

// rust: agent.rs::temperature_resolves_against_the_live_client
// rust: providers/mod.rs::copilot_reasoning_models_default_to_reasoning_replay
unittest
{
    import nano.toml : parseToml;
    import nano.result : unwrap;
    // replay_reasoning defaults on only for Copilot reasoning models.
    Config c;
    c.providers = presets();
    c.providers["github-copilot"].apiKey = "x";
    assert(resolve(c, "github-copilot/gpt-6-astra").replayReasoning);
    assert(!resolve(c, "github-copilot/gpt-4.1").replayReasoning);
    assert(!resolve(c, "github-copilot/o4-mini").replayReasoning);
    c.providers["github-copilot"].merge(parseToml("replay_reasoning = false").unwrap("valid TOML"));
    assert(!resolve(c, "github-copilot/gpt-5").replayReasoning);
    c.providers["deepseek"].merge(parseToml("replay_reasoning = true").unwrap("valid TOML"));
    assert(resolve(c, "deepseek/deepseek-reasoner").replayReasoning);
}

// rust: providers/mod.rs::qwen_and_kimi_presets
// rust: settings.rs::editing_qwen_to_the_token_plan_stores_the_endpoint_and_key_variable
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    Config c;
    c.providers = presets();
    // Rust's defaults: the offline mock, temperature 0.7.
    assert(c.defaultProvider == "mock" && c.temperature == 0.7);
    auto mock = resolve(c, c.model);
    assert(mock.name == "mock" && mock.config.kind == ProviderKind.mock && mock.model == "gpt-4o-mini");
    auto qwen = resolve(c, "qwen/qwen3.8-max");
    assert(qwen.config.baseUrl == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1" && !qwen.replayReasoning);
    assert(c.providers["qwen"].apiKeyEnv == "DASHSCOPE_API_KEY");
    auto kimi = resolve(c, "kimi/kimi-k3");
    assert(kimi.config.baseUrl == "https://api.moonshot.ai/v1" && kimi.replayReasoning);
    assert(kimi.config.dropParams == ["temperature"] && kimi.config.maxTokensParam == "max_completion_tokens");
    assert(collectExceptionMsg(resolve(c, "openai")).canFind("has no default_model"));
    assert(collectExceptionMsg(resolve(c, "nope/x")) is null); // a bare model on the default provider
    c.defaultProvider = "none";
    assert(collectExceptionMsg(resolve(c, "x")).canFind("known providers: anthropic, deepseek"));
    assert(parseKind("openai-compatible") == ProviderKind.openai);
    assert(collectExceptionMsg(parseKind("muse")).canFind("was removed"));
}

unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    string msg(string url)
    {
        return collectExceptionMsg(validateHttpBaseUrl("p", url));
    }
    assert(msg("https://host/v1") is null && msg("http://127.0.0.1:8080/v1") is null);
    assert(msg(" https://host/v1").canFind("whitespace") && msg("https://host/v1\n").canFind("control"));
    assert(msg("ftp://host").canFind("must be http(s)") && msg("host/v1").canFind("malformed"));
    assert(msg("https://host/v1?k=1").canFind("query or fragment") && msg("").canFind("empty base_url"));
    Config c;
    c.providers = presets();
    c.providers["local"] = ProviderConfig.init;
    assert(collectExceptionMsg(resolve(c, "local/m")).canFind("has no base_url"));
}

unittest
{
    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    auto path = buildPath(tempDir, "nano-d-legacy.toml");
    scope (exit) remove(path);
    // Legacy top-level credentials move the mock default to OpenAI.
    write(path, "api_key = \"sk-legacy\"\nbase_url = \"http://legacy/v1\"\n");
    auto c = Config.load(path);
    assert(c.defaultProvider == "openai" && c.providers["openai"].apiKey == "sk-legacy");
    assert(c.providers["openai"].baseUrl == "http://legacy/v1");
    // Explicit [providers.*] settings win.
    write(path, "default_provider = \"groq\"\napi_key = \"sk-legacy\"\n[providers.groq]\napi_key = \"sk-own\"\n");
    c = Config.load(path);
    assert(c.providers["groq"].apiKey == "sk-own" && c.providers["openai"].apiKey is null);
}

// rust: providers/mod.rs::finish_body_deep_merges_nested_extra_body_objects
// rust: providers/mod.rs::finish_body_keeps_resolved_temperature
// rust: providers/mod.rs::copilot_endpoint_override_is_validated_when_present
// rust: providers/mod.rs::validate_spec_rejects_a_provider_without_a_model
// rust: providers/mod.rs::user_config_overrides_and_extends_presets
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    import std.file : write, tempDir, remove;
    ProviderConfig x;
    x.extraBody = parseJSON(`{"output_config":{"format":"json"},"temperature":2}`);
    auto b = parseJSON(`{"output_config":{"effort":"high"},"temperature":0.3}`);
    x.finishBody(b);
    assert(b["output_config"]["effort"].str == "high" && b["output_config"]["format"].str == "json");
    assert(b["temperature"].toString == parseJSON(`0.3`).toString, b.toString);

    auto path = buildPath(tempDir, "nano-coder-config-test2.toml");
    scope (exit) remove(path);
    string cfg(string body_) { write(path, body_); return path; }
    foreach (url; ["not a url", "ftp://host/v1", "https://host/v1?token=x", " https://host/v1", "   "])
        foreach (kind; ["github-copilot"])
        {
            auto c = Config.load(cfg(format("[providers.p]\nkind = %s\nbase_url = %s\n", tomlQuote(kind), tomlQuote(url))));
            assert(collectExceptionMsg(resolve(c, "p/m")).canFind("base_url"), kind ~ " " ~ url);
        }
    auto c = Config.load(cfg("[providers.bare]\nkind = \"openai\"\nbase_url = \"http://localhost:9/v1\"\n"));
    assert(collectExceptionMsg(resolve(c, "bare")).canFind("no model"));
    c = Config.load(cfg("[providers.ollama]\nbase_url = \"http://merlin.local:11434/v1/\"\ndefault_model = \"qwen3:8b\"\n"
        ~ "[providers.ds4]\nkind = \"openai\"\nbase_url = \"http://localhost:8100/v1\"\ndefault_model = \"m\"\n"));
    auto o = resolve(c, "ollama");
    assert(o.config.baseUrl == "http://merlin.local:11434/v1" && o.model == "qwen3:8b");
    assert(resolve(c, "ds4").config.baseUrl == "http://localhost:8100/v1");
    assert(resolve(c, "anthropic/claude").config.baseUrl == "https://api.anthropic.com/v1", "presets remain");
}

version (unittest) private string tomlQuote(string s) pure { return `"` ~ s ~ `"`; }

// rust: config.rs::legacy_base_url_targets_an_openai_compatible_default
// rust: config.rs::parses_partial_config_with_providers
unittest
{
    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    auto path = buildPath(tempDir, "nano-d-config-partial.toml");
    scope (exit) remove(path);
    write(path, "model = \"llama3\"\nbase_url = \"http://localhost:8080/v1\"\n");
    auto c = Config.load(path);
    auto r = resolve(c, c.model);
    assert(r.name == "openai" && r.config.baseUrl == "http://localhost:8080/v1" && r.model == "llama3", r.name);

    write(path, "model = \"work/gpt-oss-120b\"\n[providers.work]\nkind = \"openai\"\n"
        ~ "base_url = \"http://merlin.local:8000/v1\"\napi_key_env = \"WORK_KEY\"\nheaders = { \"X-Team\" = \"nwf\" }\n"
        ~ "[providers.anthropic]\nmax_retries = 2\n");
    c = Config.load(path);
    assert(c.maxTokens == 0 && c.providers["work"].headers["X-Team"] == "nwf");
    assert(c.defaultProvider == "mock", c.defaultProvider);
    r = resolve(c, c.model);
    assert(r.name == "work" && r.model == "gpt-oss-120b");
    auto anthropic = resolve(c, "anthropic/claude");
    assert(anthropic.config.retryPolicy.maxRetries == 2 && anthropic.config.baseUrl == "https://api.anthropic.com/v1");
}
