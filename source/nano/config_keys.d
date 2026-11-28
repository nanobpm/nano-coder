/// Every key `config.toml` accepts, with its type, default and meaning: the
/// table `nano-coder --dump-reference` prints for the generated
/// docs/configuration.md (issue #397). A unittest scans the parsers' sources
/// so a key they read but this table lacks fails the build.
module nano.config_keys;

@safe:

/// One config key.
struct ConfigKey
{
    /// Dotted path, e.g. `sandbox.mode`; `<name>` stands for a table name
    /// you choose and `[]` for an array-of-tables entry.
    string path;
    /// TOML type: string, integer, float, boolean, array, table.
    string type;
    /// The default as TOML (empty: unset).
    string default_;
    /// What it does.
    string description;
}

/// The reference, grouped as the config file is.
immutable ConfigKey[] configKeys = [
    ConfigKey("model", "string", `"gpt-4o-mini"`, "The `provider/model` to use (on the offline `mock` provider by default)"),
    ConfigKey("default_provider", "string", `"mock"`, "Provider for a model with no known provider prefix"),
    ConfigKey("temperature", "float", "0.7", "Sampling temperature, or `\"default\"` to send none"),
    ConfigKey("max_tokens", "integer", "0", "Most tokens per reply (0: the provider's default)"),
    ConfigKey("thinking", "string", "", "Thinking level for models that reason (see Thinking)"),
    ConfigKey("vision", "boolean", "", "Whether the model accepts images (default: guessed from the model name)"),
    ConfigKey("context_window", "integer", "", "Override the model's context window, in tokens"),
    ConfigKey("max_iterations", "integer", "0", "LLM calls per user input (0 = unbounded; headless runs get a 300-call safety cap)"),
    ConfigKey("system_prompt", "string", "", "Replace the built-in system prompt"),
    ConfigKey("timestamps", "boolean", "true", "Prefix CLI messages with the local time (HH:MM:SS)"),
    ConfigKey("verbosity", "string", `"normal"`, "quiet | normal | verbose | debug (or `--verbosity`)"),
    ConfigKey("renderer", "string", "", "Retired: only `\"frame\"` remains; any other value prints a warning"),
    ConfigKey("api_key", "string", "", "Legacy: API key for the default provider (prefer `[providers.<name>]`)"),
    ConfigKey("base_url", "string", "", "Legacy: base URL for the default provider (prefer `[providers.<name>]`)"),
    ConfigKey("bash_timeout_secs", "integer", "600", "Default timeout of a bash call"),
    ConfigKey("bash_heartbeat_secs", "integer", "0", "Interval of the supervisor-visible \"still running\" note of a long bash call (0: the built-in interval; or NANO_CODER_BASH_HEARTBEAT_SECS)"),
    ConfigKey("plan_tools", "boolean", "true", "Offer the plan_* tools (see Task Plans)"),
    ConfigKey("outcome_tool", "boolean", "true", "Offer report_outcome (see Outcomes)"),
    ConfigKey("reminders", "boolean", "true", "Append <system-reminder> notes to tool results"),
    ConfigKey("verify_before_complete", "boolean", "true", "Remind the agent to verify edits before it finishes"),
    ConfigKey("check_updates", "boolean", "true", "Check for a newer release at startup"),
    ConfigKey("show_release_notes", "boolean", "true", "After an update, show what changed"),
    ConfigKey("persist_sessions", "boolean", "true", "Write a session log"),
    ConfigKey("session_dir", "string", "", "Where session logs go (default: <platform data dir>/nano-coder/sessions)"),
    ConfigKey("session_compress_after_days", "integer", "14", "Gzip logs idle this long at startup (0 = never)"),
    ConfigKey("session_retention_days", "integer", "0", "Delete logs untouched this long (0 = keep; named sessions are kept)"),
    ConfigKey("session_titles", "boolean", "false", "Ask the model for a few-word title per session (`--resume` picker)"),
    ConfigKey("title_model", "string", "", "Model for titles (default: the session's model)"),
    ConfigKey("cross_session_history", "boolean", "true", "sessions_list and a session argument on the history tools: read other sessions' logs"),
    ConfigKey("session_messages", "boolean", "false", "Listen for messages from other sessions and offer session_send"),
    ConfigKey("session_messages_confirm", "boolean", "true", "Ask before an incoming session message is queued or run"),
    ConfigKey("session_messages_max_hops", "integer", "4", "Loop guard: refuse sends beyond this many hops in a message thread"),
    ConfigKey("session_messages_max_per_hour", "integer", "10", "Loop guard: most messages to one session per hour (0 = no cap)"),
    ConfigKey("acp_session_messages", "boolean", "false", "Let `--acp` sessions send and receive messages"),
    ConfigKey("subagents", "boolean", "true", "Offer the `agent` tool: read-only sub-agents with their own context"),
    ConfigKey("subagent_model", "string", "", "Model for sub-agents (default: the session's; a call may name one)"),
    ConfigKey("subagent_max_concurrency", "integer", "4", "Sub-agents running at once"),
    ConfigKey("subagent_timeout_secs", "integer", "600", "Per sub-agent wall-clock cap"),
    ConfigKey("subagent_max_turns", "integer", "40", "Per sub-agent turn cap"),
    ConfigKey("subagent_max_tokens", "integer", "1000000", "Per sub-agent token cap"),
    ConfigKey("subagent_models[].model", "string", "", "A model a sub-agent call may pick"),
    ConfigKey("subagent_models[].use", "string", "", "When to pick it, shown to the agent"),
    ConfigKey("subagent_models[].timeout_secs", "integer", "", "This model's wall-clock cap"),
    ConfigKey("subagent_models[].max_turns", "integer", "", "This model's turn cap"),
    ConfigKey("subagent_models[].max_tokens", "integer", "", "This model's token cap"),
    ConfigKey("auto_compact", "boolean", "true", "Summarize automatically when the context fills up"),
    ConfigKey("auto_compact_threshold", "float", "0.8", "Fraction of the context window that triggers compaction"),
    ConfigKey("compaction_mode", "string", `"smart"`, "smart | standard | extract"),
    ConfigKey("compaction_pin_requests", "boolean", "true", "Keep the user's requests verbatim through compaction"),
    ConfigKey("compaction_summary_dag", "boolean", "false", "Layered, expandable summaries"),
    ConfigKey("idle_compact", "boolean", "true", "Compact while the session is idle, before the prompt cache expires"),
    ConfigKey("idle_compact_hold_secs", "integer", "", "How long an idle session waits before it compacts"),
    ConfigKey("project_instructions", "boolean", "true", "Load AGENTS.md and friends"),
    ConfigKey("project_instruction_files", "array", `["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"]`, "Instruction files looked for in each directory"),
    ConfigKey("user_instruction_files", "array", `["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"]`, "Your own instruction files, for every project"),
    ConfigKey("user_rules_dirs", "array", `["~/.claude/rules"]`, "Directories of your rule files"),
    ConfigKey("instruction_imports_outside_project", "boolean", "false", "Let project @imports and rule links leave the repository"),
    ConfigKey("disable_hooks", "boolean", "false", "Run no user hooks (as `--no-hooks`)"),
    ConfigKey("disable_project_hooks", "boolean", "false", "Ignore the repository's .claude/settings*.json hooks"),
    ConfigKey("claude_user_hooks", "boolean", "true", "Load hooks from ~/.claude/settings.json"),
    ConfigKey("hooks", "table", "", "Hooks in Claude Code's format, as in .claude/settings.json"),
    ConfigKey("memory", "string", `"on"`, "on | read_only | off: cross-session memory"),
    ConfigKey("memory_dir", "string", "", "Where memories are kept (default: <platform data dir>/nano-coder/memory)"),
    ConfigKey("memory_expiry_days", "integer", "90", "Expire memories unused this long (0 = never)"),
    ConfigKey("memory_recall", "string", `"entity"`, "entity | anchor: how tool calls recall memories"),
    ConfigKey("terminal.program_status", "boolean", "true", "Report the session's state to the terminal (OSC 7501)"),
    ConfigKey("skills.enabled", "boolean", "true", "Load skills"),
    ConfigKey("skills.dirs", "array", `[".agents/skills", ".github/skills", ".claude/skills"]`, "Skill directories, relative to the git root"),
    ConfigKey("skills.user_dirs", "array", `["~/.agents/skills"]`, "Your own skill directories"),
    ConfigKey("skills.ai_lock", "boolean", "true", "Load skills pinned in ai.lock"),
    ConfigKey("skills.fetch", "boolean", "true", "Fetch ai.lock commits missing from the spm store"),
    ConfigKey("skills.allowed_hosts", "array", `["github.com"]`, "Hosts ai.lock entries may be fetched from (\"*\" = any)"),
    ConfigKey("permissions.builtin_rules", "boolean", "true", "Block destructive commands unless allowed"),
    ConfigKey("permissions.allow", "array", "[]", "Allow rules, e.g. `[\"Bash(sqlite3 test.db *)\"]`"),
    ConfigKey("permissions.deny", "array", "[]", "Deny rules, e.g. `[\"Bash(git push:*)\", \"Edit(**/.env)\"]`"),
    ConfigKey("permissions.protected_branches", "array", `["main", "master", "trunk", "develop"]`, "Branches the git guard blocks force-pushes to and remote deletion of (ordinary commits and pushes are allowed)"),
    ConfigKey("sandbox.mode", "string", "", "off | workspace | read-only (or `--sandbox`); unset: workspace headless, off interactive"),
    ConfigKey("sandbox.writable", "array", "[]", "Extra writable paths"),
    ConfigKey("sandbox.network", "boolean", "true", "false blocks outbound connections"),
    ConfigKey("sandbox.tool_caches", "boolean", "true", "Workspace mode: allow ~/.cargo/registry, ~/.npm, ~/.cache, ..."),
    ConfigKey("web.search", "string", "", "brave | searxng: the web_search backend (unset: no web_search)"),
    ConfigKey("web.api_key", "string", "", "Brave API key (prefer api_key_env)"),
    ConfigKey("web.api_key_env", "string", "", "Environment variable holding the Brave API key"),
    ConfigKey("web.api_key_command", "string", "", "Command printing the Brave API key"),
    ConfigKey("web.searxng_url", "string", "", "Base URL of a SearXNG instance"),
    ConfigKey("web.fetch", "boolean", "true", "Offer web_fetch"),
    ConfigKey("web.fetch_permission", "string", "allow", "allow | ask | deny: what a web_fetch no permission rule covers does (ask refuses when nobody can answer, unless --yolo or --web)"),
    ConfigKey("web.allowed_hosts", "array", "[]", "Hosts web_fetch may reach (empty: any public host); `*.example.com` matches subdomains"),
    ConfigKey("web.denied_hosts", "array", "[]", "Hosts web_fetch never reaches"),
    ConfigKey("web.allow_private", "boolean", "false", "Let web_fetch reach private and local addresses"),
    ConfigKey("web.max_result_bytes", "integer", "32768", "Most bytes of text a web tool returns per call"),
    ConfigKey("web.max_download_bytes", "integer", "5242880", "Most bytes web_fetch downloads"),
    ConfigKey("web.timeout_secs", "integer", "20", "Seconds a web request may take"),
    ConfigKey("providers.<name>.kind", "string", "", "openai | anthropic | github-copilot | mock: the API it speaks"),
    ConfigKey("providers.<name>.base_url", "string", "", "The endpoint"),
    ConfigKey("providers.<name>.api_key", "string", "", "A literal key (prefer api_key_env)"),
    ConfigKey("providers.<name>.api_key_env", "string", "", "Environment variable holding the key"),
    ConfigKey("providers.<name>.api_key_command", "string", "", "Command printing the key, used when the variable is unset"),
    ConfigKey("providers.<name>.default_model", "string", "", "Model used by `--model <name>`"),
    ConfigKey("providers.<name>.headers", "table", "", "Extra HTTP headers"),
    ConfigKey("providers.<name>.extra_body", "table", "", "Merged into every request body"),
    ConfigKey("providers.<name>.drop_params", "array", "", "Request parameters to leave out, e.g. `[\"temperature\"]`"),
    ConfigKey("providers.<name>.max_tokens_param", "string", "", "Name of the max-tokens parameter, e.g. `max_completion_tokens`"),
    ConfigKey("providers.<name>.context_window", "integer", "", "Context window of this provider's models"),
    ConfigKey("providers.<name>.stream", "boolean", "true", "Stream replies"),
    ConfigKey("providers.<name>.temperature", "float", "", "Temperature for this provider's models"),
    ConfigKey("providers.<name>.thinking", "string", "", "Thinking level for this provider's models"),
    ConfigKey("providers.<name>.vision", "boolean", "", "Whether this provider's models accept images"),
    ConfigKey("providers.<name>.thinking_levels", "array", "", "The thinking levels its models support"),
    ConfigKey("providers.<name>.models", "table", "", "Per-model settings (see providers.<name>.models.<model>.*), or a list of model names"),
    ConfigKey("providers.<name>.list_models", "string", `"endpoint"`, "endpoint | configured: where the model picker's list comes from"),
    ConfigKey("providers.<name>.disabled", "boolean", "false", "Hide the provider and refuse its models"),
    ConfigKey("providers.<name>.hidden", "boolean", "false", "Hide the provider from listings"),
    ConfigKey("providers.<name>.timeout_secs", "integer", "", "Idle timeout: most silence between streamed bytes (unset: 120)"),
    ConfigKey("providers.<name>.max_retries", "integer", "5", "Retries of a failed request"),
    ConfigKey("providers.<name>.retry_initial_backoff_ms", "integer", "", "First retry delay"),
    ConfigKey("providers.<name>.retry_max_backoff_ms", "integer", "", "Longest retry delay"),
    ConfigKey("providers.<name>.retryable_statuses", "array", "", "HTTP statuses that are retried"),
    ConfigKey("providers.<name>.replay_reasoning", "boolean", "", "Send each assistant message's reasoning_content back (default: on for Copilot reasoning models and the kimi preset, off otherwise)"),
    ConfigKey("providers.<name>.models.<model>.temperature", "float", "", "Temperature for this model"),
    ConfigKey("providers.<name>.models.<model>.thinking", "string", "", "Thinking level for this model"),
    ConfigKey("providers.<name>.models.<model>.vision", "boolean", "", "Whether this model accepts images"),
    ConfigKey("providers.<name>.models.<model>.thinking_levels", "array", "", "The thinking levels this model supports"),
    ConfigKey("providers.<name>.models.<model>.name", "string", "", "Display name in the model picker"),
    ConfigKey("providers.<name>.models.<model>.base_url", "string", "", "Endpoint for this model, overriding the provider's"),
];

/// The quoted identifiers directly before each `marker` in `src`, e.g. the
/// `x` of `"x" in doc)`.
private string[] quotedBefore(string src, string marker) pure
{
    import std.string : indexOf, lastIndexOf;
    string[] keys;
    for (ptrdiff_t at = src.indexOf(marker); at >= 0; at = src.indexOf(marker, at + 1))
    {
        auto open = src[0 .. at].lastIndexOf('"');
        if (open >= 0) keys ~= src[open + 1 .. at];
    }
    return keys;
}

// Every key a parser reads is in the table: a new key without a reference
// entry fails here (and then the docs drift check, once the table has it).
unittest
{
    import std.algorithm : any, canFind, map, startsWith;
    import std.array : array;
    auto paths = configKeys.map!(k => k.path).array;
    void check(string prefix, string[] keys)
    {
        foreach (k; keys)
            // A table (`sandbox`, `[[subagent_models]]`) is documented by its keys.
            assert(paths.canFind(prefix ~ k) || paths.any!(p => p.startsWith(prefix ~ k ~ ".") || p.startsWith(prefix ~ k ~ "[")),
                "config key " ~ prefix ~ k ~ " is not in nano.config_keys.configKeys: add it, then run scripts/gen-reference.sh");
    }
    check("", quotedBefore(import("nano/config.d"), `" in doc)`));
    // Provider and per-model keys share one marker: each must be either.
    foreach (k; quotedBefore(import("nano/config.d"), `" in o)`))
        assert(paths.canFind("providers.<name>." ~ k) || paths.canFind("providers.<name>.models.<model>." ~ k),
            "provider key " ~ k ~ " is not in nano.config_keys.configKeys: add it, then run scripts/gen-reference.sh");
    check("skills.", quotedBefore(import("nano/skills.d"), `" in t)`));
    check("sandbox.", quotedBefore(import("nano/sandbox.d"), `" in v)`));
    check("permissions.", quotedBefore(import("nano/permissions.d"), `" in section)`));
    check("terminal.", quotedBefore(import("nano/config.d"), `" in *t)`));
    check("subagent_models[].", quotedBefore(import("nano/config.d"), `" in e.objectNoRef)`));
    foreach (k; ["timeout_secs", "max_turns", "max_tokens"]) check("subagent_models[].", [k]);
    // [web] is a switch over its keys.
    import std.string : indexOf;
    auto web = import("nano/tools/web.d");
    auto from = web.indexOf("static WebConfig fromJSON");
    auto to = web.indexOf("default: throw", from);
    string[] webKeys;
    foreach (k; quotedBefore(web[from .. to], `":`)) webKeys ~= k;
    assert(webKeys.length >= 12);
    check("web.", webKeys);
}

/// `fieldName` in snake_case, the config file's spelling of a `Config` field.
private string snakeCase(string fieldName) pure
{
    import std.ascii : isUpper, toLower;
    string s;
    foreach (c; fieldName)
        if (c.isUpper) s ~= "_" ~ [c.toLower];
        else s ~= c;
    return s;
}

/// `v` written as TOML, as `ConfigKey.default_` spells it; null for a type the
/// reference does not render.
private string tomlOf(T)(const T v)
{
    import std.conv : to;
    import std.format : format;
    static if (is(T == bool) || is(T == long) || is(T == int))
        return v.to!string;
    else static if (is(T == double))
        return format("%g", v);
    else static if (is(T == string))
        return v.length ? format(`"%s"`, v) : "";
    else static if (is(T == string[]))
    {
        string s = "[";
        foreach (i, e; v) s ~= (i ? ", " : "") ~ format(`"%s"`, e);
        return s ~ "]";
    }
    else
        return null;
}

/// The TOML type name of `T`, as `ConfigKey.type` spells it; null otherwise.
private string tomlType(T)()
{
    static if (is(T == bool)) return "boolean";
    else static if (is(T == long) || is(T == int)) return "integer";
    else static if (is(T == double)) return "float";
    else static if (is(T == string)) return "string";
    else static if (is(T == string[])) return "array";
    else return null;
}

// The table's types and defaults match the parsers' structs: changing a
// default or a field's type in `Config` (or `ProviderConfig`) without the
// reference fails here, so the generated docs cannot go stale silently.
unittest
{
    import nano.config : Config, ProviderConfig;
    void checkStruct(S)(string prefix)
    {
        S init_ = S.init;
        static foreach (i, field; S.tupleof)
        {{
            enum name = __traits(identifier, field);
            alias F = typeof(field);
            static if (tomlType!F !is null)
            {
                immutable path = prefix ~ snakeCase(name);
                foreach (k; configKeys)
                    if (k.path == path)
                    {
                        assert(k.type == tomlType!F,
                            "config key " ~ path ~ ": type " ~ k.type ~ " in nano.config_keys, " ~ tomlType!F ~ " in the parser");
                        auto actual = tomlOf!F(init_.tupleof[i]);
                        // An empty reference default means unset: the field must be too (zero, or the -1 "unset" sentinel).
                        assert(k.default_ == actual || (k.default_.length == 0 && (actual == tomlOf!F(F.init) || actual == "-1")),
                            "config key " ~ path ~ ": default " ~ k.default_ ~ " in nano.config_keys, " ~ actual
                            ~ " in the parser; fix the table, then run scripts/gen-reference.sh");
                    }
            }
        }}
    }
    checkStruct!Config("");
    checkStruct!ProviderConfig("providers.<name>.");
}
