/// The `session_settings` tool (issue #293): the agent reads its own
/// session's effective settings and adjusts a short allowlist of them for
/// this session only. Phase 1: compaction (`compaction_mode`, `compact_now`).
///
/// Guardrails: security settings (permissions, sandbox, hooks, providers,
/// keys) are never agent-writable, whatever the request says; nothing is
/// written to config.toml; every change is logged and shown; a setting the
/// agent changed can't be changed again for a few turns.
module nano.session_settings;

@safe:
pure:

import std.algorithm : canFind;
import std.format : format;
import std.json;
import std.string : strip, toLower;
import nano.context : CompactionMode, parseCompactionMode;
import nano.llm : ToolDefinition;
import nano.result : Result;
import nano.safeio : jsonText;

alias Parsed = Result!(Request, string);

enum string toolName = "session_settings";

/// Keys the agent may `set`.
immutable string[] writableKeys = ["compaction_mode"];

/// Keys that are refused outright, with a reason: widening any of them would
/// let a prompt injection loosen the user's safety settings or spend money.
immutable string[] protectedKeys = ["permissions", "permission_mode", "mode", "allow", "deny", "ask", "sandbox",
    "yolo", "hooks", "providers", "provider", "api_key", "api_key_command", "base_url", "model", "thinking",
    "max_tokens", "persist_sessions", "cross_session_history"];

/// Turns after an agent change before the same setting may change again.
enum settingCooldownTurns = 3;

enum Action { get, set, compactNow }

struct Request
{
    Action action;
    string key;
    CompactionMode mode;
    bool hasMode;
    string focus;
    string reason;
}

ToolDefinition definition()
{
    return ToolDefinition(toolName,
        "Read or adjust this session's harness settings. action \"get\" shows the effective settings (model, "
        ~ "compaction mode and threshold, context use). action \"set\" changes one setting for this session only "
        ~ "(never the user's config); allowed keys: " ~ format("%-(%s, %)", writableKeys) ~ ". action "
        ~ "\"compact_now\" compacts the context before your next request (optional mode and focus), e.g. before "
        ~ "reading something large or when old tool output is no longer needed. compaction_mode: standard (model "
        ~ "summary), smart (model summary citing #N, history tools) or extract (summary built in code, no model "
        ~ "call; you recover details with history_read). Give a reason: the user sees every change. Security and "
        ~ "cost settings (permissions, sandbox, hooks, providers, model, thinking) cannot be changed.",
        parseJSON(`{"type":"object","properties":{`
            ~ `"action":{"type":"string","enum":["get","set","compact_now"]},`
            ~ `"key":{"type":"string","description":"For set: the setting, e.g. compaction_mode"},`
            ~ `"value":{"type":"string","description":"For set: the new value"},`
            ~ `"mode":{"type":"string","enum":["standard","smart","extract"],"description":"For compact_now: this compaction's mode (default: the session's)"},`
            ~ `"focus":{"type":"string","description":"For compact_now: what the summary should keep"},`
            ~ `"reason":{"type":"string","description":"Why, shown to the user and logged"}},`
            ~ `"required":["action"]}`));
}

private string str(JSONValue args, string key)
{
    if (args.type != JSONType.object) return null;
    auto v = key in args;
    return v !is null && v.type == JSONType.string ? v.str.strip : null;
}

/// Set `r.mode` from `s`, or the error for the model.
private string modeInto(string s, ref Request r)
{
    import nano.option : unwrap;
    auto m = parseCompactionMode(s.toLower);
    if (m.isNone) return format("unknown compaction mode %s (standard, smart or extract)", JSONValue(s).jsonText);
    r.mode = m.unwrap("checked");
    r.hasMode = true;
    return null;
}

/// Parse and police a call; the error is a message for the model.
Parsed parse(JSONValue args)
{
    Request r;
    r.reason = str(args, "reason");
    switch (str(args, "action"))
    {
        case "get":
            r.action = Action.get;
            return Parsed.ok(r);
        case "compact_now":
            r.action = Action.compactNow;
            if (auto m = str(args, "mode"))
                if (auto e = modeInto(m, r)) return Parsed.err(e);
            r.focus = str(args, "focus");
            return Parsed.ok(r);
        case "set":
            r.action = Action.set;
            r.key = str(args, "key").toLower;
            if (protectedKeys.canFind(r.key))
                return Parsed.err(format("%s can't be changed by the agent: security and cost settings stay "
                    ~ "with the user (ask them to use /settings)", r.key));
            if (!writableKeys.canFind(r.key))
                return Parsed.err(format("unknown setting %s; settable: %-(%s, %)", JSONValue(r.key).jsonText, writableKeys));
            auto value = str(args, "value");
            if (!value.length) return Parsed.err("set needs a value");
            if (auto e = modeInto(value, r)) return Parsed.err(e);
            return Parsed.ok(r);
        default:
            return Parsed.err("action must be get, set or compact_now");
    }
}

unittest
{
    import nano.result : unwrap;
    import nano.result : match;
    string collectExceptionMsg(Parsed p) { return p.match!((Request _) => string.init, (string e) => e); }
    auto r = parse(parseJSON(`{"action":"set","key":"Compaction_Mode","value":"Extract","reason":"big logs"}`)).unwrap("ok");
    assert(r.action == Action.set && r.key == "compaction_mode" && r.mode == CompactionMode.extract && r.reason == "big logs");
    r = parse(parseJSON(`{"action":"compact_now","mode":"smart","focus":"the failing test"}`)).unwrap("ok");
    assert(r.action == Action.compactNow && r.hasMode && r.mode == CompactionMode.smart && r.focus == "the failing test");
    assert(!parse(parseJSON(`{"action":"compact_now"}`)).unwrap("ok").hasMode);
    assert(parse(parseJSON(`{"action":"get"}`)).unwrap("ok").action == Action.get);
    foreach (k; ["permissions", "sandbox", "yolo", "hooks", "model", "api_key_command", "thinking"])
        assert(collectExceptionMsg(parse(parseJSON(format(`{"action":"set","key":"%s","value":"x"}`, k))))
            .canFind("can't be changed by the agent"), k);
    assert(collectExceptionMsg(parse(parseJSON(`{"action":"set","key":"colour","value":"x"}`))).canFind("unknown setting"));
    assert(collectExceptionMsg(parse(parseJSON(`{"action":"set","key":"compaction_mode","value":"magic"}`)))
        .canFind("unknown compaction mode"));
    assert(collectExceptionMsg(parse(parseJSON(`{"action":"set","key":"compaction_mode"}`))).canFind("needs a value"));
    assert(collectExceptionMsg(parse(parseJSON(`{"action":"delete"}`))).canFind("action must be"));
}
