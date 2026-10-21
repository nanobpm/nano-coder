/// Configuration: `~/.config/nano-coder/config.toml` (same file and keys as the
/// Rust nano-coder; keys this port doesn't implement yet are ignored), plus
/// built-in provider presets.
module nano.config;

import nano.skills : SkillsConfig;
import nano.memory : MemoryMode, parseMemoryMode, defaultExpiryDays;

import std.json;
import nano.sandbox : SandboxConfig;
import std.file : exists, readText;
import std.path : buildPath, expandTilde;
import std.process : environment, executeShell;
import std.string : strip, indexOf, startsWith;
import std.format : format;
import std.math : isNaN;
import nano.toml;
import std.typecons : Nullable;
import nano.thinking : Thinking;

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

    static ModelSettings fromJSON(JSONValue o)
    {
        ModelSettings m;
        if (auto v = "temperature" in o) m.temperature = numberOrDefault(*v);
        if (auto v = "thinking" in o) m.thinking = Thinking.parse(v.str);
        if (auto v = "vision" in o) m.vision = v.boolean;
        if (auto v = "thinking_levels" in o) m.thinkingLevels = strings(*v), m.hasThinkingLevels = true;
        return m;
    }
}

string[] strings(JSONValue v)
{
    string[] o;
    foreach (x; v.array) o ~= x.str;
    return o;
}

enum ProviderKind { openai, anthropic, githubCopilot }

ProviderKind parseKind(string s)
{
    switch (s)
    {
        case "openai": return ProviderKind.openai;
        case "anthropic": return ProviderKind.anthropic;
        case "github-copilot", "github_copilot": return ProviderKind.githubCopilot;
        default: throw new Exception(format("provider kind %s is not supported by the D port yet (openai, anthropic, github-copilot)", s));
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
    long timeoutSecs = 600;
    long maxRetries = 3;
    /// Send the model's reasoning back on later turns (null: on for models
    /// that reason over the Responses API).
    Nullable!bool replayReasoning;

    /// Merge `extra_body` into a built request body (nested objects field by
    /// field, so an unrelated option doesn't clobber a generated sibling), then
    /// strip `drop_params`. `temperature` is owned by the resolver and skipped.
    void finishBody(ref JSONValue b) const @trusted
    {
        static void mergeObject(ref JSONValue into, const JSONValue from)
        {
            foreach (k, v; from.object)
            {
                if (auto e = k in into.object)
                    if (e.type == JSONType.object && v.type == JSONType.object) { mergeObject(*e, v); continue; }
                into.object[k] = cast(JSONValue) v;
            }
        }
        if (extraBody.type == JSONType.object)
            foreach (k, v; extraBody.object)
            {
                if (k == "temperature") continue;
                if (auto e = k in b.object)
                    if (e.type == JSONType.object && v.type == JSONType.object) { mergeObject(*e, v); continue; }
                b.object[k] = cast(JSONValue) v;
            }
        foreach (d; dropParams) b.object.remove(d);
    }

    /// Overlay the fields set in `o` (a user table) onto this preset.
    void merge(JSONValue o)
    {
        if (auto v = "kind" in o) { hasKind = true; kind = parseKind(v.str); }
        if (auto v = "base_url" in o) baseUrl = v.str;
        if (auto v = "api_key" in o) apiKey = v.str;
        if (auto v = "api_key_env" in o) { apiKeyEnv = v.str; apiKeyEnvSet = true; }
        if (auto v = "api_key_command" in o) apiKeyCommand = v.str;
        if (auto v = "default_model" in o) defaultModel = v.str;
        if (auto v = "headers" in o) foreach (k, h; v.object) headers[k] = h.str;
        if (auto v = "extra_body" in o) extraBody = *v;
        if (auto v = "drop_params" in o) { dropParams = null; foreach (p; v.array) dropParams ~= p.str; }
        if (auto v = "max_tokens_param" in o) maxTokensParam = v.str;
        if (auto v = "context_window" in o) contextWindow = v.integer;
        if (auto v = "stream" in o) stream = v.boolean;
        if (auto v = "temperature" in o) temperature = numberOrDefault(*v);
        if (auto v = "thinking" in o) thinking = Thinking.parse(v.str);
        if (auto v = "vision" in o) vision = v.boolean;
        if (auto v = "thinking_levels" in o) thinkingLevels = strings(*v), hasThinkingLevels = true;
        if (auto v = "models" in o)
            foreach (name, m; v.object) models[name] = ModelSettings.fromJSON(m);
        if (auto v = "timeout_secs" in o) timeoutSecs = v.integer;
        if (auto v = "max_retries" in o) maxRetries = v.integer;
        if (auto v = "replay_reasoning" in o) replayReasoning = v.boolean;
    }
}

/// A number, or NaN for `"default"` (send none).
double numberOrDefault(JSONValue v)
{
    if (v.type == JSONType.string)
    {
        if (v.str == "default") return double.nan;
        throw new Exception("temperature must be a number or \"default\"");
    }
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

ProviderConfig preset(ProviderKind kind, string url, string env, string model = null)
{
    ProviderConfig p;
    p.hasKind = true;
    p.kind = kind;
    p.baseUrl = url;
    p.apiKeyEnv = env;
    p.defaultModel = model;
    return p;
}

ProviderConfig[string] presets()
{
    alias O = ProviderKind.openai;
    ProviderConfig[string] m;
    m["openai"] = preset(O, "https://api.openai.com/v1", "OPENAI_API_KEY", "gpt-5");
    m["openai"].maxTokensParam = "max_completion_tokens";
    m["anthropic"] = preset(ProviderKind.anthropic, "https://api.anthropic.com/v1", "ANTHROPIC_API_KEY", "claude-sonnet-4-5");
    m["openrouter"] = preset(O, "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY");
    m["fireworks"] = preset(O, "https://api.fireworks.ai/inference/v1", "FIREWORKS_API_KEY");
    m["groq"] = preset(O, "https://api.groq.com/openai/v1", "GROQ_API_KEY");
    m["together"] = preset(O, "https://api.together.xyz/v1", "TOGETHER_API_KEY");
    m["deepseek"] = preset(O, "https://api.deepseek.com/v1", "DEEPSEEK_API_KEY");
    m["moonshot"] = preset(O, "https://api.moonshot.ai/v1", "MOONSHOT_API_KEY");
    m["mistral"] = preset(O, "https://api.mistral.ai/v1", "MISTRAL_API_KEY");
    m["gemini"] = preset(O, "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY");
    m["ollama"] = preset(O, "http://localhost:11434/v1", null);
    m["github-copilot"] = preset(ProviderKind.githubCopilot, "https://api.githubcopilot.com", null, "gpt-4.1");
    return m;
}

struct Config
{
    string model = "openai/gpt-5";
    string defaultProvider = "openai";
    double temperature = double.nan;
    /// Global thinking level and vision override.
    Thinking thinking;
    Nullable!bool vision;
    long maxTokens = 0;
    string systemPrompt;
    long maxIterations = 0;
    long bashTimeoutSecs = 600;
    ProviderConfig[string] providers;
    SkillsConfig skills;
    MemoryMode memory = MemoryMode.on;
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
    /// Instruction files (AGENTS.md and friends, the user's own, rules).
    bool projectInstructions = true;
    string[] projectInstructionFiles = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"];
    string[] userInstructionFiles = ["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"];
    string[] userRulesDirs = ["~/.claude/rules"];
    bool instructionImportsOutsideProject;
    double autoCompactThreshold = 0.8;
    /// `standard` or `smart` (summary cites the session log; history tools).
    string compactionMode = "standard";
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

    static Config load(string path)
    {
        Config c;
        c.providers = presets();
        c.path = path;
        if (!path.exists) return c;
        auto doc = parseToml(readText(path));
        if (auto v = "model" in doc) c.model = v.str;
        if (auto v = "default_provider" in doc) c.defaultProvider = v.str;
        if (auto v = "temperature" in doc) c.temperature = numberOrDefault(*v);
        if (auto v = "max_tokens" in doc) c.maxTokens = v.integer;
        if (auto v = "thinking" in doc) c.thinking = Thinking.parse(v.str);
        if (auto v = "vision" in doc) c.vision = v.boolean;
        if (auto v = "system_prompt" in doc) c.systemPrompt = v.str;
        if (auto v = "max_iterations" in doc) c.maxIterations = v.integer;
        if (auto v = "bash_timeout_secs" in doc) c.bashTimeoutSecs = v.integer;
        if (auto v = "plan_tools" in doc) c.planTools = v.boolean;
        if (auto v = "outcome_tool" in doc) c.outcomeTool = v.boolean;
        if (auto v = "reminders" in doc) c.reminders = v.boolean;
        if (auto v = "auto_compact" in doc) c.autoCompact = v.boolean;
        if (auto v = "project_instructions" in doc) c.projectInstructions = v.boolean;
        static string[] strs(JSONValue v) { string[] o; foreach (x; v.array) o ~= x.str; return o; }
        if (auto v = "project_instruction_files" in doc) c.projectInstructionFiles = strs(*v);
        if (auto v = "user_instruction_files" in doc) c.userInstructionFiles = strs(*v);
        if (auto v = "user_rules_dirs" in doc) c.userRulesDirs = strs(*v);
        if (auto v = "instruction_imports_outside_project" in doc) c.instructionImportsOutsideProject = v.boolean;
        if (auto v = "auto_compact_threshold" in doc)
            c.autoCompactThreshold = v.type == JSONType.integer ? v.integer : v.floating;
        if (auto v = "compaction_mode" in doc) c.compactionMode = v.str;
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
        if (auto v = "skills" in doc) c.skills = SkillsConfig.fromToml(*v);
        if (auto ps = "providers" in doc)
            foreach (name, table; ps.object)
            {
                auto p = name in c.providers ? c.providers[name] : ProviderConfig.init;
                p.merge(table);
                c.providers[name] = p;
            }
        // Legacy top-level credentials apply to the default provider.
        if (auto v = "api_key" in doc) c.providers[c.defaultProvider].apiKey = v.str;
        if (auto v = "base_url" in doc) c.providers[c.defaultProvider].baseUrl = v.str;
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
bool reasonsOverResponses(ProviderKind kind, string model)
{
    import nano.copilot : isReasoningModel;
    return kind == ProviderKind.githubCopilot && isReasoningModel(model);
}

/// Split `provider/model` (or a bare provider, or a bare model).
void parseModelSpec(string spec, const ProviderConfig[string] providers, string defaultProvider,
        out string provider, out string model)
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

ResolvedProvider resolve(const ref Config c, string spec)
{
    string name, model;
    parseModelSpec(spec, c.providers, c.defaultProvider, name, model);
    auto pc = name in c.providers;
    if (pc is null) throw new Exception("unknown provider " ~ name);
    ResolvedProvider r;
    r.name = name;
    r.config = cast(ProviderConfig) *pc;
    r.model = model.length ? model : pc.defaultModel;
    if (!r.model.length) throw new Exception(format("no model given for provider %s; use --model %s/<model>", name, name));
    if (!r.config.hasKind) r.config.kind = ProviderKind.openai;
    if (r.config.baseUrl.indexOf('?') >= 0 || r.config.baseUrl.indexOf('#') >= 0)
        throw new Exception(format("provider %s: base_url must not contain a query or fragment", name));
    r.replayReasoning = pc.replayReasoning.isNull ? reasonsOverResponses(r.config.kind, r.model) : pc.replayReasoning.get;
    r.apiKey = pc.apiKey;
    if (!r.apiKey.length && pc.apiKeyEnv.length) r.apiKey = environment.get(pc.apiKeyEnv, "");
    if (!r.apiKey.length && pc.apiKeyCommand.length)
    {
        auto res = executeShell(pc.apiKeyCommand);
        if (res.status != 0) throw new Exception(format("provider %s: api_key_command failed: %s", name, res.output.strip));
        r.apiKey = res.output.strip;
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
    auto path = buildPath(tempDir, "nano-coder-d-config-test.toml");
    write(path, "model = \"box/m1\"\ntemperature = \"default\"\n[providers.box]\nkind = \"openai\"\nbase_url = \"http://x/v1\"\napi_key = \"k\"\n[providers.anthropic]\ndefault_model = \"c9\"\n");
    scope (exit) remove(path);
    auto c = Config.load(path);
    auto r = resolve(c, c.model);
    assert(r.name == "box" && r.model == "m1" && r.apiKey == "k" && r.config.baseUrl == "http://x/v1");
    assert(isNaN(c.temperature));
    auto a = resolve(c, "anthropic");
    assert(a.model == "c9" && a.config.baseUrl == "https://api.anthropic.com/v1");
}

@trusted unittest
{
    import nano.toml : parseToml;
    // replay_reasoning defaults on only for Copilot reasoning models.
    Config c;
    c.providers = presets();
    c.providers["github-copilot"].apiKey = "x";
    assert(resolve(c, "github-copilot/gpt-6-astra").replayReasoning);
    assert(!resolve(c, "github-copilot/gpt-4.1").replayReasoning);
    assert(!resolve(c, "github-copilot/o4-mini").replayReasoning);
    c.providers["github-copilot"].merge(parseToml("replay_reasoning = false"));
    assert(!resolve(c, "github-copilot/gpt-5").replayReasoning);
    c.providers["deepseek"].merge(parseToml("replay_reasoning = true"));
    assert(resolve(c, "deepseek/deepseek-reasoner").replayReasoning);
}
