/// Thinking level: how much the model reasons before it answers (port of
/// `thinking.rs`). `default` sends nothing, `off` turns thinking off where the
/// model allows it, and a level (`low` .. `max`) asks for that much. Set
/// globally, per provider and per model (`[providers.NAME.models."MODEL"]`);
/// the most specific wins and `/thinking LEVEL` overrides them for the
/// session. Levels come from `thinking_levels` (model, then provider), else
/// what the endpoint reports, else a built-in table of model families; a level
/// the model lacks moves to the nearest it has, with a warning.
module nano.thinking;

@safe:

import std.algorithm : canFind, countUntil, filter, map, all;
import std.array : array, join;
import std.ascii : isAlphaNum, isDigit;
import std.conv : to;
import std.format : format;
static import std.format;
import std.json;
import std.string : strip, toLower, indexOf, startsWith, lastIndexOf;
import std.typecons : Nullable;
import nano.config : ProviderConfig, ProviderKind;

/// Named levels from least to most thinking.
immutable string[] ORDER = ["minimal", "low", "medium", "high", "xhigh", "max"];
/// The level of models that can only switch thinking on or off.
enum ON = "on";
/// Smallest budget Anthropic accepts.
enum uint MIN_BUDGET = 1024;

/// A thinking setting.
struct Thinking
{
    enum Kind { default_, off, level }
    Kind kind;
    string level;

    static Thinking off() { return Thinking(Kind.off); }
    static Thinking of(string l) { return Thinking(Kind.level, l); }
    bool isDefault() const { return kind == Kind.default_; }

    /// Parse a setting; throws with Rust's message on a bad one.
    static Thinking parse(string s)
    {
        s = s.strip.toLower;
        switch (s)
        {
            case "default", "model default", "auto": return Thinking.init;
            case "off", "none", "disabled": return Thinking.off;
            case "": throw new Exception(`thinking level is empty; use "default", "off" or a level such as "high"`);
            default:
                if (s.all!(c => isAlphaNum(c) || c == '-' || c == '_')) return Thinking.of(s);
                throw new Exception(format(`thinking must be "default", "off" or a level name such as "high"; got "%s"`, s));
        }
    }

    string toString() const
    {
        final switch (kind)
        {
            case Kind.default_: return "model default";
            case Kind.off: return "off";
            case Kind.level: return level;
        }
    }

    /// The config spelling (`default` rather than `model default`).
    string configValue() const { return kind == Kind.default_ ? "default" : toString(); }
}

/// How an Anthropic Messages model takes a level.
enum AnthropicStyle { adaptive, budget }

/// How a Chat Completions request carries the level.
enum Format { effort, templateSwitch, templateEffort }

/// Which request format a client sends.
enum Wire { chatCompletions, responses, anthropicMessages }

Wire wireFor(ProviderKind kind, string model)
{
    if (kind == ProviderKind.githubCopilot)
    {
        import nano.copilot : CopilotApi, apiForModel;
        final switch (apiForModel(model))
        {
            case CopilotApi.completions: return Wire.chatCompletions;
            case CopilotApi.responses: return Wire.responses;
            case CopilotApi.messages: return Wire.anthropicMessages;
        }
    }
    if (kind == ProviderKind.muse) return Wire.responses;
    return kind == ProviderKind.anthropic ? Wire.anthropicMessages : Wire.chatCompletions;
}

/// What the request asks for, after resolution.
struct Request
{
    enum Kind { none, off, effort, budget, adaptiveOn, templateSwitch, templateEffort }
    Kind kind;
    string level;
    uint budget;
    bool on;
}

/// Anthropic thinking budget for a level on budget-style models.
uint budgetTokens(string level)
{
    switch (level)
    {
        case "minimal": return 1024;
        case "low": return 2048;
        case "medium": return 8192;
        case "high": return 16384;
        case "xhigh": return 32768;
        case "max": return 65536;
        default: return 16384;
    }
}

/// The budget to send under an output cap of `maxTokens` (it must stay below
/// it); 0 when the cap leaves no room for the minimum.
uint cappedBudget(uint budget, long maxTokens)
{
    long room = maxTokens - 1;
    if (room < 0) room = 0;
    if (room > uint.max) room = uint.max;
    uint b = budget < room ? budget : cast(uint) room;
    return b >= MIN_BUDGET ? b : 0;
}

/// What a model supports, from the built-in table.
struct Profile
{
    string[] levels;
    bool hasAnthropic;
    AnthropicStyle anthropic;
}

private Profile profile(string[] levels, bool claude = false, AnthropicStyle s = AnthropicStyle.adaptive)
{
    return Profile(levels, claude, s);
}

/// A one- or two-digit number at the start of `s`, and what follows it.
private bool number(string s, out uint n, out string rest)
{
    size_t d;
    while (d < s.length && isDigit(s[d])) d++;
    if (d == 0 || d > 2) return false;
    n = s[0 .. d].to!uint;
    rest = s[d .. $];
    return true;
}

private uint minorOf(string s)
{
    if (!s.length || (s[0] != '.' && s[0] != '-')) return 0;
    uint m; string after;
    if (number(s[1 .. $], m, after) && m < 10 && !(after.length && isDigit(after[0]))) return m;
    return 0;
}

/// `(family, major, minor)` of a Claude id: `claude-sonnet-4-5-20250929` is
/// sonnet 4.5, `claude-3-7-sonnet-latest` sonnet 3.7.
bool claudeVersion(string id, out string family, out uint major, out uint minor)
{
    auto at = id.indexOf("claude-");
    if (at < 0) return false;
    auto rest = id[at + 7 .. $];
    foreach (f; ["opus", "sonnet", "haiku", "fable"])
    {
        if (rest.startsWith(f ~ "-"))
        {
            string tail;
            if (number(rest[f.length + 1 .. $], major, tail))
            {
                family = f;
                minor = minorOf(tail);
                return true;
            }
        }
    }
    string tail;
    if (!number(rest, major, tail)) return false;
    minor = minorOf(tail);
    foreach (f; ["opus", "sonnet", "haiku"])
        if (tail.canFind(f)) { family = f; return true; }
    return false;
}

/// `(major, minor)` of `gpt-<major>[.<minor>]` with the prefix stripped.
private bool gptVersion(string rest, out uint major, out uint minor)
{
    size_t d;
    while (d < rest.length && isDigit(rest[d])) d++;
    if (d == 0 || d > 6) return false;
    major = rest[0 .. d].to!uint;
    minor = 0;
    if (d < rest.length && rest[d] == '.')
    {
        size_t e = d + 1;
        while (e < rest.length && isDigit(rest[e]) && e - d < 7) e++;
        if (e > d + 1) minor = rest[d + 1 .. e].to!uint;
    }
    return true;
}

/// The built-in profile for a model id, if its family is known.
Nullable!Profile builtin(string model)
{
    alias A = AnthropicStyle;
    Nullable!Profile none;
    auto id = model.toLower;
    string family; uint major, minor;
    if (claudeVersion(id, family, major, minor))
    {
        auto v = major * 100 + minor;
        immutable full = ["low", "medium", "high", "xhigh", "max"];
        if (family == "fable") return Nullable!Profile(profile(full.dup, true));
        if ((family == "opus" || family == "sonnet") && v >= 505) return Nullable!Profile(profile(full.dup, true));
        if ((family == "opus" || family == "sonnet") && v >= 407)
            return Nullable!Profile(profile(["off", "low", "medium", "high", "xhigh", "max"], true));
        if ((family == "opus" || family == "sonnet") && v == 406)
            return Nullable!Profile(profile(["off", "low", "medium", "high", "max"], true));
        if (v >= 307 && v < 406 && !(family == "haiku" && v < 405))
            return Nullable!Profile(profile(["off", "low", "medium", "high"], true, A.budget));
        return none;
    }
    auto slash = id.lastIndexOf('/');
    if (slash >= 0) id = id[slash + 1 .. $];
    if (id.startsWith("gpt-") && gptVersion(id[4 .. $], major, minor))
    {
        if (id.canFind("chat")) return none;
        if (major == 5 && minor == 0) return Nullable!Profile(profile(["minimal", "low", "medium", "high"]));
        if (major >= 5) return Nullable!Profile(profile(["off", "low", "medium", "high"]));
    }
    if (id == "o1-mini" || id.startsWith("o1-mini-")) return none;
    foreach (p; ["o1", "o3", "o4"])
        if (id == p || id.startsWith(p ~ "-")) return Nullable!Profile(profile(["low", "medium", "high"]));
    return none;
}

/// Thinking levels an endpoint reports for a model.
struct Reported
{
    string[] levels;
    bool adaptive;
    Format format;

    /// Copilot-style `/models` entry: `capabilities.supports.reasoning_effort`.
    static Nullable!Reported fromModelEntry(const JSONValue entry) @trusted
    {
        Nullable!Reported none;
        auto caps = objGet(entry, "capabilities");
        auto supports = caps is null ? null : objGet(*caps, "supports");
        if (supports is null) return none;
        auto effort = objGet(*supports, "reasoning_effort");
        if (effort is null || effort.type != JSONType.array) return none;
        string[] levels;
        foreach (l; effort.array)
        {
            if (l.type != JSONType.string) continue;
            auto s = l.str.strip.toLower;
            if (s == "none") s = "off";
            if (s.length) levels ~= s;
        }
        if (!levels.length) return none;
        auto ad = objGet(*supports, "adaptive_thinking");
        bool adaptive = ad !is null && ad.type == JSONType.true_;
        return Nullable!Reported(Reported(levels, adaptive, Format.effort));
    }

    /// Ollama `/api/show`: the `thinking` capability takes `reasoning_effort`.
    static Nullable!Reported fromOllamaShow(const JSONValue show) @trusted
    {
        auto caps = objGet(show, "capabilities");
        if (caps !is null && caps.type == JSONType.array)
            foreach (c; caps.array)
                if (c.type == JSONType.string && c.str == "thinking")
                    return Nullable!Reported(Reported(["off", "low", "medium", "high"], false, Format.effort));
        return Nullable!Reported.init;
    }

    /// llama.cpp `/props`: what the chat template accepts.
    static Nullable!Reported fromLlamacppProps(const JSONValue props) @trusted
    {
        auto t = objGet(props, "chat_template");
        if (t is null || t.type != JSONType.string) return Nullable!Reported.init;
        if (t.str.canFind("reasoning_effort"))
            return Nullable!Reported(Reported(["low", "medium", "high"], false, Format.templateEffort));
        if (t.str.canFind("enable_thinking"))
            return Nullable!Reported(Reported(["off", ON], false, Format.templateSwitch));
        return Nullable!Reported.init;
    }
}

/// `v[key]` when `v` is an object holding it.
const(JSONValue)* objGet(const ref JSONValue v, string key) @trusted
{
    if (v.type != JSONType.object) return null;
    return key in v.object;
}

/// `extra_body` keys that carry a thinking setting for `wire`.
immutable(string[]) extraBodyKeys(Wire wire)
{
    final switch (wire)
    {
        case Wire.chatCompletions: return ["reasoning_effort", "reasoning", "think", "chat_template_kwargs"];
        case Wire.responses: return ["reasoning"];
        case Wire.anthropicMessages: return ["thinking", "output_config"];
    }
}

/// Whether an Anthropic `extra_body` control under `key` leaves the model
/// thinking. A present control thinks unless it explicitly turns thinking off
/// (`disabled`, `off`, `none` or `false`); `output_config` counts only through
/// its `effort` field (null otherwise: not a thinking control).
Nullable!bool anthropicExtraBodyThinks(string key, const JSONValue v) @trusted
{
    static bool isOff(string s)
    {
        auto t = s.strip.toLower;
        return t == "disabled" || t == "off" || t == "none" || t == "false";
    }
    static bool enables(const JSONValue v)
    {
        if (v.type == JSONType.true_) return true;
        if (v.type == JSONType.false_) return false;
        if (v.type == JSONType.string) return !isOff(v.str);
        return true;
    }
    if (key == "output_config")
    {
        auto e = v.type == JSONType.object ? objGet(v, "effort") : null;
        return e is null ? Nullable!bool.init : Nullable!bool(enables(*e));
    }
    if (v.type == JSONType.object)
    {
        foreach (k; ["type", "effort"])
        {
            auto f = objGet(v, k);
            if (f !is null && f.type == JSONType.string && isOff(f.str)) return Nullable!bool(false);
        }
        return Nullable!bool(true);
    }
    return Nullable!bool(enables(v));
}

/// Whether `extra_body[key]` replaces the generated control (not just an
/// unrelated sibling field of a nested one).
private bool extraBodyOverridesGenerated(string key, Wire wire, Format fmt, const(JSONValue)* value) @trusted
{
    string nested;
    if (wire == Wire.responses && key == "reasoning") nested = "effort";
    else if (wire == Wire.chatCompletions && key == "chat_template_kwargs")
    {
        if (fmt == Format.templateSwitch) nested = "enable_thinking";
        else if (fmt == Format.templateEffort) nested = "reasoning_effort";
        else return false;
    }
    if (!nested.length) return true;
    if (value is null || value.type != JSONType.object) return true;
    return objGet(*value, nested) !is null;
}

private Request generatedRequest(const Thinking eff, Wire wire, AnthropicStyle anthropic, Format fmt)
{
    alias K = Request.Kind;
    final switch (eff.kind)
    {
        case Thinking.Kind.default_: return Request.init;
        case Thinking.Kind.off:
            if (wire == Wire.chatCompletions && fmt == Format.templateSwitch) return Request(K.templateSwitch, null, 0, false);
            if (wire == Wire.chatCompletions && fmt == Format.templateEffort) return Request(K.templateEffort, "none");
            return Request(K.off);
        case Thinking.Kind.level:
            if (wire == Wire.anthropicMessages && anthropic == AnthropicStyle.budget)
                return Request(K.budget, null, budgetTokens(eff.level));
            if (wire == Wire.chatCompletions && fmt == Format.templateSwitch) return Request(K.templateSwitch, null, 0, true);
            if (wire == Wire.chatCompletions && fmt == Format.templateEffort) return Request(K.templateEffort, eff.level);
            return Request(K.effort, eff.level);
    }
}

private immutable(string[]) requestFieldKeys(Wire wire, const Request r)
{
    alias K = Request.Kind;
    final switch (wire)
    {
        case Wire.chatCompletions:
            return r.kind == K.templateSwitch || r.kind == K.templateEffort ? ["chat_template_kwargs"] : ["reasoning_effort"];
        case Wire.responses: return ["reasoning"];
        case Wire.anthropicMessages: return r.kind == K.effort ? ["thinking", "output_config"] : ["thinking"];
    }
}

/// Where the level in effect came from.
enum Source { session, model, provider, global }

string label(Source s)
{
    final switch (s)
    {
        case Source.session: return "set for this session";
        case Source.model: return "set for this model";
        case Source.provider: return "set for this provider";
        case Source.global: return "global setting";
    }
}

/// The thinking level a model is sent, and why.
struct Resolved
{
    Thinking requested;
    /// What is sent: default sends nothing.
    Thinking effective;
    Source source;
    /// Levels the model supports (`off` included); empty when unknown.
    string[] levels;
    Wire wire;
    AnthropicStyle anthropic;
    Format format;
    /// The `extra_body` key that carries the thinking control instead.
    string extraBodyOverride;
    /// Anthropic: an `extra_body` control on the wire leaves thinking on/off.
    Nullable!bool extraBodyThinkingOn;
    string extraBodyThinkingKey;
    bool overridden;
    bool dropped;
    string warning;

    /// What to put in the request (kind `none` for nothing).
    Request request() const
    {
        if (dropped) return Request.init;
        if (extraBodyOverride.length)
        {
            if (extraBodyOverride == "output_config" && wire == Wire.anthropicMessages
                && anthropic == AnthropicStyle.adaptive)
            {
                if (effective.kind == Thinking.Kind.level && !extraBodyThinkingOn.isNull && extraBodyThinkingOn.get)
                    return Request(Request.Kind.adaptiveOn);
                if (effective.kind == Thinking.Kind.off) return Request(Request.Kind.off);
            }
            return Request.init;
        }
        return generatedRequest(effective, wire, anthropic, format);
    }

    private bool modelAlwaysThinks() const
    {
        return wire == Wire.anthropicMessages && levels.length && !levels.canFind("off");
    }

    private bool extraBodyEnables() const { return !extraBodyThinkingOn.isNull && extraBodyThinkingOn.get; }

    private bool extraBodyControlComplete() const
    {
        return extraBodyThinkingKey != "output_config" || request().kind == Request.Kind.adaptiveOn;
    }

    /// Whether Anthropic Messages is asked to think (no custom temperature then).
    bool anthropicThinkingOn() const
    {
        if (modelAlwaysThinks) return true;
        if (extraBodyEnables && request().kind != Request.Kind.off && !dropped && extraBodyControlComplete) return true;
        if (extraBodyOverride.length || dropped || wire != Wire.anthropicMessages) return false;
        return effective.kind == Thinking.Kind.level;
    }

    /// Whether the model thinks on Anthropic Messages even with no thinking
    /// field in the request (compaction).
    bool alwaysAnthropicThinking() const
    {
        if (wire != Wire.anthropicMessages) return false;
        return modelAlwaysThinks || (extraBodyEnables && extraBodyControlComplete);
    }

    /// One line for `/context`, e.g. `high (set for this model)`.
    string describe() const
    {
        auto t = std.format.format("%s (%s)", effective, source.label);
        if (effective != requested) t ~= std.format.format(", %s requested", requested);
        if (overridden) t ~= ", overridden by extra_body";
        if (dropped) t ~= ", dropped by drop_params";
        return t;
    }

    /// The levels `/thinking` can set, for display.
    string choices() const { return (["default"] ~ levels.dup).join(", "); }
}

/// The level sent, for ACP and logs: null when nothing reaches the wire.
JSONValue wireValue(const ref Resolved r) @trusted
{
    if (r.overridden || r.dropped || r.effective.isDefault) return JSONValue(null);
    return JSONValue(r.effective.toString);
}

/// `/thinking` with no argument: the level, the model's levels and how to change it.
string statusText(const ref Resolved r, string model)
{
    string[] out_ = ["Thinking: " ~ r.describe];
    if (!r.levels.length)
        out_ ~= format("No thinking levels are known for %s; list them with thinking_levels in its provider or model settings.", model);
    else out_ ~= format("Levels for %s: %s", model, r.choices);
    if (r.warning.length) out_ ~= "Warning: " ~ r.warning;
    out_ ~= "(/thinking LEVEL sets it for this session; /thinking reset uses the config again)";
    return out_.join("\n");
}

/// Apply a `/thinking ARG` (`reset` clears the session level).
void setSession(ref Nullable!Thinking session, string arg)
{
    arg = arg.strip;
    if (arg.toLower == "reset") session.nullify;
    else session = Thinking.parse(arg);
}

/// The level in `levels` nearest to `wanted`: the highest at or below it on
/// ORDER, else the lowest above it. A name off the scale matches only itself.
string nearest(const string[] levels, string wanted)
{
    if (levels.canFind(wanted)) return wanted;
    static ptrdiff_t rank(string l) { return ORDER.countUntil(l); }
    string[] ranked;
    foreach (l; levels) if (rank(l) >= 0) ranked ~= l;
    if (!ranked.length) return levels.canFind(ON) ? ON : null;
    auto w = rank(wanted);
    if (w < 0) return null;
    string below, above;
    foreach (l; ranked)
    {
        auto r = rank(l);
        if (r <= w && (below is null || r > rank(below))) below = l;
        if (r > w && (above is null || r < rank(above))) above = l;
    }
    return below !is null ? below : above;
}

private string quoted(string s) { return format("%s", [s])[1 .. $ - 1]; }

/// The level for `model` on `provider`: the session override, else the
/// model's setting, else the provider's, else `global`, fitted to the levels
/// the model supports (config `thinking_levels`, else `reported`, else the
/// built-in table).
Resolved resolve(const Thinking global, const(Thinking)* session, ProviderKind kind,
    const ref ProviderConfig provider, string model, const(Reported)* reported = null) @trusted
{
    Resolved r;
    auto ms = model in provider.models;
    if (session !is null) { r.requested = *session; r.source = Source.session; }
    else if (ms !is null && !ms.thinking.isNull) { r.requested = ms.thinking.get; r.source = Source.model; }
    else if (!provider.thinking.isNull) { r.requested = provider.thinking.get; r.source = Source.provider; }
    else { r.requested = global; r.source = Source.global; }
    auto prof = builtin(model);
    string[] invalid, aliases, reserved;
    const(string[])* configured = ms !is null && ms.hasThinkingLevels ? &ms.thinkingLevels
        : provider.hasThinkingLevels ? &provider.thinkingLevels : null;
    if (configured !is null)
    {
        foreach (raw; *configured)
        {
            auto l = raw.strip.toLower;
            try
            {
                auto t = Thinking.parse(l);
                if (t.kind == Thinking.Kind.off && l != "off") aliases ~= l;
                else if (t.isDefault) reserved ~= l;
                else r.levels ~= l;
            }
            catch (Exception) invalid ~= l;
        }
    }
    else if (reported !is null) r.levels = reported.levels.dup;
    else if (!prof.isNull) r.levels = prof.get.levels.dup;
    r.wire = wireFor(kind, model);
    r.anthropic = reported !is null && reported.adaptive ? AnthropicStyle.adaptive
        : !prof.isNull && prof.get.hasAnthropic ? prof.get.anthropic : AnthropicStyle.adaptive;
    r.format = reported !is null ? reported.format : Format.effort;
    bool explicit = r.source != Source.global;
    string warn;
    final switch (r.requested.kind)
    {
        case Thinking.Kind.default_: break;
        case Thinking.Kind.off:
            if (!r.levels.length)
            {
                if (explicit) warn = format("thinking %s (%s) is ignored: no thinking levels are known for %s; "
                    ~ "list them with thinking_levels in its provider or model settings", r.requested, r.source.label, model);
            }
            else if (r.levels.canFind("off")) r.effective = Thinking.off;
            else if (explicit) warn = format("%s can't turn thinking off; using the model default", model);
            break;
        case Thinking.Kind.level:
            if (!r.levels.length)
            {
                if (explicit) warn = format("thinking %s (%s) is ignored: no thinking levels are known for %s; "
                    ~ "list them with thinking_levels in its provider or model settings", r.requested, r.source.label, model);
                break;
            }
            auto level = r.requested.level;
            auto on = r.levels.filter!(l => l != "off").array;
            auto found = nearest(on, level);
            if (found is null)
            {
                if (explicit) warn = format("%s has no thinking level %s (it has: %s); using the model default",
                    model, quoted(level), r.levels.join(", "));
            }
            else
            {
                r.effective = Thinking.of(found);
                if (found == level) {}
                else if (found == ON)
                {
                    if (explicit) warn = format("%s only switches thinking on or off; %s turns it on", model, quoted(level));
                }
                else if (explicit) warn = format("%s has no thinking level %s; using %s", model, quoted(level), quoted(found));
            }
            break;
    }
    bool droppedKey(string k) { return provider.dropParams.canFind(k); }
    const(JSONValue)* bodyGet(string k)
    {
        return provider.extraBody.type == JSONType.object ? k in provider.extraBody.object : null;
    }
    if (!r.requested.isDefault)
        foreach (k; extraBodyKeys(r.wire))
        {
            auto v = bodyGet(k);
            if (v is null || droppedKey(k)) continue;
            bool overrides = r.wire == Wire.anthropicMessages ? !anthropicExtraBodyThinks(k, *v).isNull
                : extraBodyOverridesGenerated(k, r.wire, r.format, v);
            if (overrides) { r.extraBodyOverride = k; break; }
        }
    if (r.extraBodyOverride.length)
    {
        auto shown = !r.effective.isDefault ? r.effective : r.requested;
        warn = format("the provider's extra_body sets %s, which is sent instead of thinking %s; "
            ~ "remove it from extra_body to use the thinking setting", quoted(r.extraBodyOverride), shown);
    }
    if (r.wire == Wire.anthropicMessages)
        foreach (k; extraBodyKeys(r.wire))
        {
            auto v = bodyGet(k);
            if (v is null || droppedKey(k)) continue;
            auto on = anthropicExtraBodyThinks(k, *v);
            if (!on.isNull) { r.extraBodyThinkingKey = k; r.extraBodyThinkingOn = on; break; }
        }
    r.overridden = r.extraBodyOverride.length > 0;
    bool preserved = r.overridden && r.extraBodyOverride == "output_config"
        && r.wire == Wire.anthropicMessages && r.anthropic == AnthropicStyle.adaptive;
    if (!r.effective.isDefault && (!r.overridden || preserved))
    {
        auto req = generatedRequest(r.effective, r.wire, r.anthropic, r.format);
        if (req.kind != Request.Kind.none)
            foreach (k; requestFieldKeys(r.wire, req))
                if (droppedKey(k))
                {
                    warn = format("the provider drops %s (drop_params), so thinking %s is not sent; "
                        ~ "remove it from drop_params to use the thinking setting", quoted(k), r.effective);
                    r.dropped = true;
                    break;
                }
    }
    string[] notices;
    static string list(string[] xs) { return xs.map!quoted.join(", "); }
    if (invalid.length) notices ~= format("ignoring invalid thinking_levels %s for %s: a level name is letters, "
        ~ "digits, '-' or '_' — fix them in its provider or model settings", list(invalid), model);
    if (aliases.length) notices ~= format(`ignoring thinking_levels %s for %s: an off alias is not a level — use "off"`,
        list(aliases), model);
    if (reserved.length) notices ~= format("ignoring thinking_levels %s for %s: the model default is always "
        ~ "available and is not a selectable level", list(reserved), model);
    if (notices.length) warn = warn.length ? notices.join("; ") ~ "; " ~ warn : notices.join("; ");
    r.warning = warn;
    return r;
}

/// Write `req` into a Chat Completions body.
void applyChat(const Request req, ref JSONValue body) @trusted
{
    alias K = Request.Kind;
    final switch (req.kind)
    {
        case K.effort: body["reasoning_effort"] = req.level; break;
        case K.off: body["reasoning_effort"] = "none"; break;
        case K.templateSwitch: body["chat_template_kwargs"] = JSONValue(["enable_thinking": JSONValue(req.on)]); break;
        case K.templateEffort: body["chat_template_kwargs"] = JSONValue(["reasoning_effort": JSONValue(req.level)]); break;
        case K.budget, K.adaptiveOn, K.none: break;
    }
}

/// Write `req` into an Anthropic Messages body; returns whether thinking is on
/// (which rules out a custom temperature).
bool applyAnthropic(const Request req, ref JSONValue body, long maxTokens) @trusted
{
    alias K = Request.Kind;
    final switch (req.kind)
    {
        case K.effort:
            body["thinking"] = JSONValue(["type": "adaptive"]);
            body["output_config"] = JSONValue(["effort": req.level]);
            return true;
        case K.adaptiveOn:
            body["thinking"] = JSONValue(["type": "adaptive"]);
            return true;
        case K.budget:
            auto b = cappedBudget(req.budget, maxTokens);
            if (!b) return false;
            JSONValue t = ["type": "enabled"];
            t["budget_tokens"] = cast(long) b;
            body["thinking"] = t;
            return true;
        case K.off:
            body["thinking"] = JSONValue(["type": "disabled"]);
            return false;
        case K.templateSwitch, K.templateEffort, K.none: return false;
    }
}

version (unittest)
{
    private ProviderConfig prov(string toml) @trusted
    {
        import nano.toml : parseToml;
        ProviderConfig p;
        p.merge(parseToml(toml));
        return p;
    }
    private Thinking lv(string l) { return Thinking.of(l); }
    private string levelsOf(string m)
    {
        auto p = builtin(m);
        return p.isNull ? null : p.get.levels.join(",");
    }
    private Resolved res(Thinking global, Thinking* session, ProviderKind kind, ProviderConfig p, string model) @trusted
    {
        return resolve(global, session, kind, p, model);
    }
    private Resolved sess(Thinking t, ProviderKind kind, ProviderConfig p, string model) @trusted
    {
        return resolve(Thinking.init, &t, kind, p, model);
    }
}

unittest
{
    assert(Thinking.parse("default").isDefault);
    assert(Thinking.parse(" Off ").kind == Thinking.Kind.off);
    assert(Thinking.parse("HIGH") == lv("high"));
    import std.exception : assertThrown;
    assertThrown(Thinking.parse(""));
    assertThrown(Thinking.parse("very high!"));
}

unittest
{
    assert(levelsOf("claude-fable-5-1") == "low,medium,high,xhigh,max");
    assert(levelsOf("claude-opus-5-5") == "low,medium,high,xhigh,max");
    assert(levelsOf("claude-sonnet-5") == "off,low,medium,high,xhigh,max");
    assert(levelsOf("claude-opus-4.7") == "off,low,medium,high,xhigh,max");
    assert(levelsOf("claude-sonnet-4-6") == "off,low,medium,high,max");
    foreach (m; ["claude-sonnet-4-5-20250929", "claude-sonnet-4.5", "anthropic/claude-opus-4.1",
            "anthropic.claude-sonnet-4-20250514-v1:0", "claude-haiku-4-5", "claude-3-7-sonnet-latest"])
    {
        assert(builtin(m).get.anthropic == AnthropicStyle.budget, m);
        assert(levelsOf(m) == "off,low,medium,high", m);
    }
    assert(builtin("claude-3-5-sonnet-latest").isNull && builtin("claude-3-5-haiku").isNull);
    assert(levelsOf("gpt-5") == "minimal,low,medium,high" && levelsOf("gpt-5-mini") == "minimal,low,medium,high");
    assert(levelsOf("gpt-5.1") == "off,low,medium,high" && levelsOf("gpt-5.1-codex") == "off,low,medium,high");
    assert(levelsOf("openai/gpt-5.6-sol") == "off,low,medium,high");
    assert(builtin("gpt-5-chat-latest").isNull);
    assert(levelsOf("o4-mini") == "low,medium,high" && levelsOf("o1") == "low,medium,high");
    assert(builtin("o1-mini").isNull && builtin("o1-mini-2024-09-12").isNull);
    assert(builtin("gpt-4.1").isNull && builtin("llama3.3").isNull && builtin("omni-moderation").isNull);
}

unittest
{
    alias O = ProviderKind.openai;
    auto p = prov("kind = \"openai\"\nthinking = \"low\"\n[models.\"gpt-5\"]\nthinking = \"high\"\n");
    auto r = res(lv("medium"), null, O, p, "gpt-5");
    assert(r.effective == lv("high") && r.source == Source.model);
    assert(r.request() == Request(Request.Kind.effort, "high"));
    r = res(lv("medium"), null, O, p, "gpt-5.1");
    assert(r.effective == lv("low") && r.source == Source.provider);
    r = res(lv("medium"), null, O, ProviderConfig.init, "gpt-5");
    assert(r.effective == lv("medium") && r.source == Source.global);
    r = sess(Thinking.init, O, p, "gpt-5");
    assert(r.effective.isDefault && r.source == Source.session && r.request().kind == Request.Kind.none);
}

unittest
{
    import std.algorithm : canFind;
    alias A = ProviderKind.anthropic;
    ProviderConfig none;
    auto r = sess(lv("xhigh"), A, none, "claude-sonnet-4-6");
    assert(r.effective == lv("high") && r.warning.canFind(`using "high"`) && r.describe.canFind("xhigh requested"));
    assert(sess(lv("minimal"), A, none, "claude-opus-5-5").effective == lv("low"));
    r = sess(Thinking.off, A, none, "claude-fable-5-1");
    assert(r.effective.isDefault && r.warning.canFind("can't turn thinking off"));
    assert(sess(Thinking.off, A, none, "claude-sonnet-4-5").request().kind == Request.Kind.off);
    r = res(lv("high"), null, ProviderKind.openai, none, "llama3.3");
    assert(r.effective.isDefault && r.warning is null);
    r = sess(lv("high"), ProviderKind.openai, none, "llama3.3");
    assert(r.effective.isDefault && r.warning.canFind("thinking_levels"));
    r = res(lv("max"), null, ProviderKind.openai, none, "gpt-5");
    assert(r.effective == lv("high") && r.warning is null);
    // GPT-5 sends minimal; GPT-5.1 fits minimal to low and can turn off.
    assert(sess(lv("minimal"), ProviderKind.openai, none, "gpt-5").request() == Request(Request.Kind.effort, "minimal"));
    assert(sess(Thinking.off, ProviderKind.openai, none, "gpt-5.1").request().kind == Request.Kind.off);
    assert(sess(lv("minimal"), ProviderKind.openai, none, "gpt-5.1").effective == lv("low"));
    // Budget models get a budget.
    assert(sess(lv("high"), A, none, "claude-sonnet-4-5").request() == Request(Request.Kind.budget, null, 16384));
}

unittest
{
    import std.algorithm : canFind;
    alias O = ProviderKind.openai;
    auto p = prov("thinking_levels = [\"low\", \"high\"]\n[models.\"qwen3\"]\nthinking_levels = [\"off\", \"on\"]\n");
    auto r = sess(lv("medium"), O, p, "kimi-k3");
    assert(r.effective == lv("low") && r.choices == "default, low, high");
    assert(sess(lv("on"), O, p, "qwen3").request() == Request(Request.Kind.effort, "on"));
    assert(sess(lv("high"), O, p, "qwen3").effective == lv("on"));
    assert(sess(lv("deep"), O, p, "qwen3").request() == Request(Request.Kind.effort, "on"));
    p = prov("thinking_levels = [\"fast\", \"deep\"]\n");
    r = sess(lv("high"), O, p, "x");
    assert(r.effective.isDefault && r.warning.canFind("it has: fast, deep"));
    assert(sess(lv("deep"), O, p, "x").request() == Request(Request.Kind.effort, "deep"));
    p = prov("thinking_levels = [\"low\", \"very high\", \"none\", \"auto\"]\n");
    r = sess(lv("low"), O, p, "x");
    assert(r.levels == ["low"] && r.warning.canFind(`invalid thinking_levels "very high"`)
        && r.warning.canFind(`thinking_levels "none"`) && r.warning.canFind(`thinking_levels "auto"`));
}

unittest
{
    import std.algorithm : canFind;
    // extra_body owning the control suppresses the generated field.
    auto p = prov("[extra_body]\nreasoning_effort = \"low\"\n");
    auto r = sess(lv("high"), ProviderKind.openai, p, "gpt-5");
    assert(r.overridden && r.request().kind == Request.Kind.none && r.warning.canFind(`extra_body sets "reasoning_effort"`));
    assert(r.describe.canFind("overridden by extra_body"));
    // drop_params strips it.
    p = prov("drop_params = [\"reasoning_effort\"]\n");
    r = sess(lv("high"), ProviderKind.openai, p, "gpt-5");
    assert(r.dropped && r.request().kind == Request.Kind.none && r.warning.canFind("drops"));
    // A dropped extra_body key is no override.
    p = prov("drop_params = [\"reasoning_effort\"]\n[extra_body]\nreasoning_effort = \"low\"\n");
    assert(!sess(lv("high"), ProviderKind.openai, p, "gpt-5").overridden);
    // A format-only output_config is no thinking override on Anthropic.
    p = prov("[extra_body.output_config]\nformat = \"json\"\n");
    r = sess(lv("high"), ProviderKind.anthropic, p, "claude-sonnet-4-6");
    assert(!r.overridden && r.request() == Request(Request.Kind.effort, "high"));
    // An effort override keeps the adaptive enable half.
    p = prov("[extra_body.output_config]\neffort = \"low\"\n");
    r = sess(lv("high"), ProviderKind.anthropic, p, "claude-sonnet-4-6");
    assert(r.overridden && r.request().kind == Request.Kind.adaptiveOn && r.anthropicThinkingOn);
    assert(sess(Thinking.off, ProviderKind.anthropic, p, "claude-sonnet-4-6").request().kind == Request.Kind.off);
    // Always-thinking models lock the temperature even when dropped.
    p = prov("drop_params = [\"thinking\"]\n");
    r = sess(lv("high"), ProviderKind.anthropic, p, "claude-fable-5");
    assert(r.dropped && r.anthropicThinkingOn && r.alwaysAnthropicThinking);
    // A disabling extra_body thinking does not lock it.
    p = prov("[extra_body.thinking]\ntype = \"disabled\"\n");
    r = res(Thinking.init, null, ProviderKind.anthropic, p, "claude-sonnet-4-6");
    assert(!r.anthropicThinkingOn && !r.alwaysAnthropicThinking);
    p = prov("[extra_body.thinking]\ntype = \"enabled\"\nbudget_tokens = 2048\n");
    r = res(Thinking.init, null, ProviderKind.anthropic, p, "claude-sonnet-4-6");
    assert(r.anthropicThinkingOn && r.alwaysAnthropicThinking);
}

unittest
{
    assert(budgetTokens("custom") == 16384);
    assert(cappedBudget(16384, 4096) == 4095 && cappedBudget(16384, 1000) == 0 && cappedBudget(2048, 64000) == 2048);
    JSONValue b = parseJSON("{}");
    assert(applyAnthropic(Request(Request.Kind.budget, null, 16384), b, 4096));
    assert(b["thinking"]["budget_tokens"].integer == 4095);
    b = parseJSON("{}");
    assert(!applyAnthropic(Request(Request.Kind.budget, null, 16384), b, 1000) && "thinking" !in b);
    b = parseJSON("{}");
    assert(applyAnthropic(Request(Request.Kind.effort, "high"), b, 8000));
    assert(b["thinking"]["type"].str == "adaptive" && b["output_config"]["effort"].str == "high");
    b = parseJSON("{}");
    applyChat(Request(Request.Kind.off), b);
    assert(b["reasoning_effort"].str == "none");
    b = parseJSON("{}");
    applyChat(Request(Request.Kind.templateSwitch, null, 0, false), b);
    assert(b["chat_template_kwargs"]["enable_thinking"].boolean == false);
}

@trusted unittest
{
    auto e = parseJSON(`{"id":"x","capabilities":{"supports":{"reasoning_effort":["none","Low","high"],"adaptive_thinking":true}}}`);
    auto r = Reported.fromModelEntry(e);
    assert(!r.isNull && r.get.levels == ["off", "low", "high"] && r.get.adaptive);
    assert(Reported.fromModelEntry(parseJSON(`{"capabilities":{"supports":{}}}`)).isNull);
    assert(Reported.fromOllamaShow(parseJSON(`{"capabilities":["completion","thinking"]}`)).get.levels.length == 4);
    assert(Reported.fromOllamaShow(parseJSON(`{"capabilities":["completion"]}`)).isNull);
    auto l = Reported.fromLlamacppProps(parseJSON(`{"chat_template":"{% if enable_thinking %}"}`));
    assert(l.get.format == Format.templateSwitch && l.get.levels == ["off", ON]);
    l = Reported.fromLlamacppProps(parseJSON(`{"chat_template":"reasoning_effort"}`));
    assert(l.get.format == Format.templateEffort);
    // Reported levels feed resolution; template formats pick the field.
    ProviderConfig none;
    auto rep = l.get;
    auto t = lv("high");
    auto res = resolve(Thinking.init, &t, ProviderKind.openai, none, "local", &rep);
    assert(res.request() == Request(Request.Kind.templateEffort, "high"));
}
