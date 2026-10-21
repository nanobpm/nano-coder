/// `/settings` (settings.rs): what changed, the labels and choice lists the
/// dialog shows, and saving the changes into the config file with
/// format-preserving edits. The dialog itself is `nano.settings_dialog`.
module nano.settings;

@safe:

import std.format : format;
import std.math : isNaN;
import std.typecons : Nullable, Tuple, tuple;
import nano.config : Config, ProviderConfig, ProviderKind, ModelSettings;
import nano.thinking : Thinking;
import nano.toml_edit;

/// What a visit changed (each saved as its own key).
struct Changes
{
    bool model, temperature, thinking, maxTokens, maxIterations, systemPrompt, compaction, verbosity, renderer;
    bool[string] providerTemperatures, providerThinking, providers;
    /// "provider\0model" pairs.
    bool[string] modelTemperatures, modelThinking;

    bool any() const
    {
        return model || temperature || thinking || maxTokens || maxIterations || systemPrompt || compaction
            || verbosity || renderer || providerTemperatures.length || providerThinking.length || providers.length
            || modelTemperatures.length || modelThinking.length;
    }
}

string pairKey(string provider, string model) { return provider ~ "\0" ~ model; }

string turnCapLabel(long maxIterations)
{
    return maxIterations <= 0 ? "unbounded" : format("%s LLM calls per input (normal mode asks before stopping)", maxIterations);
}

/// `0` is "unset": shown as what it resolves to.
string maxTokensLabel(long configured, string effective)
{
    return configured > 0 ? format("%s", configured) : format("auto (%s)", effective);
}

enum size_t recentModelsShown = 4;

/// Recent specs whose provider still exists, newest first, at most four.
string[] recentModels(const string[] recents, const ProviderConfig[string] all)
{
    import std.string : indexOf;
    string[] out_;
    foreach (spec; recents)
    {
        auto slash = spec.indexOf('/');
        if (slash >= 0 && spec[0 .. slash] !in all) continue;
        out_ ~= spec;
        if (out_.length == recentModelsShown) break;
    }
    return out_;
}

/// A row of the first `/model` list: a recent model, a provider, or Cancel.
struct ProviderRow
{
    string label;
    enum Kind { model, provider, cancel }
    Kind kind;
    string value;
}

/// The recent models (current one marked), the providers with their key
/// status, then Cancel; and the row to preselect: the newest recent model
/// that isn't current (so Enter flips back), else the current provider.
ProviderRow[] providerRows(const string[] recent, string currentSpec, string currentProvider,
    const ProviderConfig[string] all, out size_t initial, string dataDir = null) @trusted
{
    import std.algorithm : sort, countUntil;
    import nano.ui : keyStatus;
    ProviderRow[] rows;
    foreach (spec; recent)
        rows ~= ProviderRow(format("↺ %s%s", spec, spec == currentSpec ? "  (current)" : ""), ProviderRow.Kind.model, spec);
    auto first = rows.length;
    auto names = all.keys;
    names.sort();
    foreach (n; names) rows ~= ProviderRow(format("%-14s %s", n, keyStatus(all[n], dataDir)), ProviderRow.Kind.provider, n);
    rows ~= ProviderRow("Cancel", ProviderRow.Kind.cancel);
    auto prev = recent.countUntil!(s => s != currentSpec);
    if (prev >= 0) initial = prev;
    else
    {
        auto at = names.countUntil(currentProvider);
        initial = first + (at >= 0 ? at : 0);
    }
    return rows;
}

/// Thinking choices for a scope (0 model, 1 provider, 2 global): "unset"
/// for the narrower scopes, "default", the model's levels, and the existing
/// value if it isn't among them; plus the existing value's row.
Tuple!(Nullable!Thinking, string)[] thinkingChoices(size_t scope_, const string[] levels, Nullable!Thinking existing,
    out size_t initial)
{
    alias C = Tuple!(Nullable!Thinking, string);
    C[] choices;
    if (scope_ < 2) choices ~= C(Nullable!Thinking.init, "unset (use the broader setting)");
    choices ~= C(Nullable!Thinking(Thinking.parse("default")), "default (send no level; the model decides)");
    foreach (l; levels) choices ~= C(Nullable!Thinking(Thinking.parse(l)), l);
    bool has(Nullable!Thinking v)
    {
        foreach (c; choices) if (c[0] == v) return true;
        return false;
    }
    if (!existing.isNull && !has(existing)) choices ~= C(existing, existing.get.toString);
    initial = 0;
    foreach (i, c; choices) if (c[0] == existing) { initial = i; break; }
    return choices;
}

/// Is this the Qwen / Model Studio provider (by name or URL)?
bool isQwenProvider(string name, const ref ProviderConfig p)
{
    import nano.qwen : isModelStudioUrl;
    return name == "qwen" || (p.baseUrl.length && isModelStudioUrl(p.baseUrl));
}

/// The user's entry after an edit: only fields that differ from the preset,
/// with key sources replaced and an emptied preset `api_key_env` kept as "".
ProviderConfig diffFrom(const ref ProviderConfig preset, const ref ProviderConfig existing, const ref ProviderConfig updated)
    @trusted
{
    ProviderConfig e = cast(ProviderConfig) existing;
    e.hasKind = updated.hasKind && !(preset.hasKind && preset.kind == updated.kind);
    e.kind = updated.kind;
    e.baseUrl = updated.baseUrl == preset.baseUrl ? null : updated.baseUrl;
    e.defaultModel = updated.defaultModel == preset.defaultModel ? null : updated.defaultModel;
    e.apiKey = updated.apiKey;
    e.apiKeyCommand = updated.apiKeyCommand;
    e.apiKeyEnv = updated.apiKeyEnv == preset.apiKeyEnv ? null : updated.apiKeyEnv;
    e.apiKeyEnvSet = e.apiKeyEnv.length > 0;
    if (preset.apiKeyEnv.length && !updated.apiKeyEnv.length) { e.apiKeyEnv = ""; e.apiKeyEnvSet = true; }
    return e;
}

string kindName(ProviderKind k)
{
    final switch (k)
    {
        case ProviderKind.openai: return "openai";
        case ProviderKind.anthropic: return "anthropic";
        case ProviderKind.githubCopilot: return "github-copilot";
        case ProviderKind.muse: return "muse";
        case ProviderKind.mock: return "mock";
    }
}

private string temperatureLiteral(double t) { return isNaN(t) ? tomlString("default") : tomlFloat(t); }

private string thinkingLiteral(const Nullable!Thinking t) @trusted
{
    return t.isNull ? null : tomlString(t.get.toString);
}

/// The config text with `changes` applied (settings.rs `save`, minus the
/// write). `user` holds each changed provider's own entry.
string applyChanges(string doc, const ref Config c, const ref Changes ch, const ProviderConfig[string] user) @trusted
{
    import std.string : indexOf;
    import nano.ui : vname = name;
    if (ch.model) doc = tomlSet(doc, [], "model", tomlString(c.model));
    if (ch.temperature) doc = tomlSet(doc, [], "temperature", temperatureLiteral(c.temperature));
    foreach (name; ch.providerTemperatures.byKey)
    {
        auto p = name in c.providers;
        doc = tomlSet(doc, ["providers", name], "temperature",
            p is null || p.temperature.isNull ? null : temperatureLiteral(p.temperature.get));
    }
    foreach (pair; ch.modelTemperatures.byKey)
    {
        auto z = pair.indexOf('\0');
        string name = pair[0 .. z], model = pair[z + 1 .. $];
        const(ModelSettings)* m;
        if (auto p = name in c.providers) m = model in p.models;
        doc = tomlSet(doc, ["providers", name, "models", model], "temperature",
            m is null || m.temperature.isNull ? null : temperatureLiteral(m.temperature.get));
    }
    if (ch.thinking) doc = tomlSet(doc, [], "thinking", tomlString(c.thinking.toString));
    foreach (name; ch.providerThinking.byKey)
    {
        auto p = name in c.providers;
        doc = tomlSet(doc, ["providers", name], "thinking", p is null ? null : thinkingLiteral(p.thinking));
    }
    foreach (pair; ch.modelThinking.byKey)
    {
        auto z = pair.indexOf('\0');
        string name = pair[0 .. z], model = pair[z + 1 .. $];
        const(ModelSettings)* m;
        if (auto p = name in c.providers) m = model in p.models;
        doc = tomlSet(doc, ["providers", name, "models", model], "thinking", m is null ? null : thinkingLiteral(m.thinking));
    }
    if (ch.maxTokens) doc = tomlSet(doc, [], "max_tokens", format("%s", c.maxTokens));
    if (ch.maxIterations) doc = tomlSet(doc, [], "max_iterations", format("%s", c.maxIterations));
    if (ch.systemPrompt) doc = tomlSet(doc, [], "system_prompt", tomlString(c.systemPrompt));
    if (ch.verbosity) doc = tomlSet(doc, [], "verbosity", tomlString(c.verbosity.vname));
    if (ch.renderer) doc = tomlSet(doc, [], "renderer", tomlString(c.renderer));
    if (ch.compaction)
    {
        doc = tomlSet(doc, [], "auto_compact", c.autoCompact ? "true" : "false");
        doc = tomlSet(doc, [], "auto_compact_threshold", tomlFloat(c.autoCompactThreshold));
        doc = tomlSet(doc, [], "compaction_mode", tomlString(c.compactionMode));
        doc = tomlSet(doc, [], "context_window", c.contextWindow > 0 ? format("%s", c.contextWindow) : null);
    }
    foreach (name; ch.providers.byKey)
    {
        auto p = name in user;
        if (p is null) continue;
        string s(string v) { return v.length ? tomlString(v) : null; }
        auto path = ["providers", name];
        doc = tomlSet(doc, path, "kind", p.hasKind ? tomlString(kindName(p.kind)) : null);
        doc = tomlSet(doc, path, "base_url", s(p.baseUrl));
        doc = tomlSet(doc, path, "default_model", s(p.defaultModel));
        doc = tomlSet(doc, path, "api_key", s(p.apiKey));
        doc = tomlSet(doc, path, "api_key_command", s(p.apiKeyCommand));
        doc = tomlSet(doc, path, "api_key_env", p.apiKeyEnvSet ? tomlString(p.apiKeyEnv) : null);
        if (doc.indexOf("[providers." ~ tomlKey(name) ~ "]") < 0 && doc.indexOf("[providers." ~ tomlString(name) ~ "]") < 0)
            doc ~= "\n[providers." ~ tomlKey(name) ~ "]\n"; // an entry with nothing but defaults still marks it as the user's
    }
    return doc;
}

/// Writes the changes into `path` atomically (0600 when a key is stored).
void save(const ref Config c, const ref Changes ch, const ProviderConfig[string] user, string path) @trusted
{
    import std.file : exists, readText, mkdirRecurse, rename, write;
    import std.path : dirName;
    import std.conv : octal;
    auto doc = path.exists ? readText(path) : "";
    doc = applyChanges(doc, c, ch, user);
    bool secret;
    foreach (ref p; user) if (p.apiKey.length) secret = true;
    if (path.dirName.length) mkdirRecurse(path.dirName);
    auto tmp = path ~ ".tmp";
    write(tmp, doc);
    version (Posix)
    {
        import core.sys.posix.sys.stat : chmod;
        import std.string : toStringz;
        if (secret) chmod(tmp.toStringz, octal!600);
    }
    rename(tmp, path);
}

unittest
{
    import std.algorithm : canFind;
    assert(turnCapLabel(0) == "unbounded" && maxTokensLabel(0, "model default") == "auto (model default)");
    ProviderConfig a, b;
    ProviderConfig[string] all = ["a": a, "b": b];
    assert(recentModels(["a/x", "gone/y", "b/z", "a/1", "a/2", "a/3"], all) == ["a/x", "b/z", "a/1", "a/2"]);
    size_t initial;
    auto rows = providerRows(["a/x", "b/z"], "a/x", "b", all, initial, "/nonexistent");
    assert(rows[0].label == "↺ a/x  (current)" && initial == 1);
    assert(rows[$ - 1].kind == ProviderRow.Kind.cancel && rows.length == 5);
    rows = providerRows([], "a/x", "b", all, initial, "/nonexistent");
    assert(initial == 1 && rows[1].value == "b");

    auto ch = thinkingChoices(1, ["low", "high"], Nullable!Thinking(Thinking.parse("medium")), initial);
    assert(ch.length == 5 && ch[0][1].canFind("unset") && ch[4][1] == "medium" && initial == 4);
    ch = thinkingChoices(2, ["low"], Nullable!Thinking.init, initial);
    assert(ch.length == 2 && initial == 0);

    Config c;
    c.model = "x/y";
    c.temperature = double.nan;
    c.maxTokens = 2048;
    Changes changes;
    changes.model = changes.temperature = changes.maxTokens = true;
    ProviderConfig w;
    w.hasKind = true;
    w.kind = ProviderKind.openai;
    w.baseUrl = "http://h/v1";
    w.apiKeyEnv = "W_KEY";
    w.apiKeyEnvSet = true;
    changes.providers["work"] = true;
    auto doc = applyChanges("# mine\nmodel = \"a/b\"\n", c, changes, ["work": w]);
    assert(doc == "# mine\nmodel = \"x/y\"\ntemperature = \"default\"\nmax_tokens = 2048\n\n[providers.work]\n"
        ~ "kind = \"openai\"\nbase_url = \"http://h/v1\"\napi_key_env = \"W_KEY\"\n", doc);
    assert(changes.any && !Changes.init.any);

    ProviderConfig preset;
    preset.hasKind = true;
    preset.kind = ProviderKind.openai;
    preset.apiKeyEnv = "P_KEY";
    ProviderConfig upd = preset;
    upd.apiKeyEnv = null;
    upd.apiKeyCommand = "pass x";
    ProviderConfig none;
    auto d = diffFrom(preset, none, upd);
    assert(!d.hasKind && d.apiKeyEnv == "" && d.apiKeyEnvSet && d.apiKeyCommand == "pass x");
}
