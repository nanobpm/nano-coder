/// `/settings` (settings.rs): what changed, the labels and choice lists the
/// dialog shows, and saving the changes into the config file with
/// format-preserving edits. The dialog itself is `nano.settings_dialog`.
module nano.settings;

@safe:

import std.format : format;
import std.math : isNaN;
import std.typecons : Nullable, Tuple, tuple;
import nano.config : Config, ProviderConfig, ProviderKind, ModelSettings, enabledProviderNames, isVisible, parseModelSpec;
import nano.qwen : QwenEndpoint;
import std.string : strip;
import nano.thinking : Thinking;
import nano.toml_edit;
import nano.result : toOption, unwrap;

/// What a visit changed (each saved as its own key).
struct Changes
{
    bool model, temperature, thinking, maxTokens, maxIterations, systemPrompt, compaction, verbosity, subagents,
        sessionMessages, sessionMessagesConfirm;
    bool[string] providerTemperatures, providerThinking, providers;
    /// "provider\0model" pairs.
    bool[string] modelTemperatures, modelThinking;

    bool any() pure const
    {
        return model || temperature || thinking || maxTokens || maxIterations || systemPrompt || compaction
            || verbosity || subagents || sessionMessages || sessionMessagesConfirm
            || providerTemperatures.length || providerThinking.length || providers.length
            || modelTemperatures.length || modelThinking.length;
    }
}

string pairKey(string provider, string model) pure { return provider ~ "\0" ~ model; }

string turnCapLabel(long maxIterations) pure
{
    return maxIterations <= 0 ? "unbounded" : format("%s LLM calls per input (normal mode asks before stopping)", maxIterations);
}

/// `0` is "unset": shown as what it resolves to.
string maxTokensLabel(long configured, string effective) pure
{
    return configured > 0 ? format("%s", configured) : format("auto (%s)", effective);
}

enum size_t recentModelsShown = 4;

/// Recent specs whose provider still exists and is visible, newest first, at most four.
string[] recentModels(const string[] recents, const ProviderConfig[string] all) pure
{
    import std.string : indexOf;
    string[] out_;
    foreach (spec; recents)
    {
        auto slash = spec.indexOf('/');
        if (slash >= 0)
        {
            // A spec on a removed or hidden provider neither shows nor takes a slot.
            auto p = spec[0 .. slash] in all;
            if (p is null || !(*p).isVisible) continue;
        }
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
    const ProviderConfig[string] all, out size_t initial, string dataDir = null)
{
    import std.algorithm : sort, countUntil;
    import nano.ui : keyStatus;
    ProviderRow[] rows;
    foreach (spec; recent)
        rows ~= ProviderRow(format("↺ %s%s", spec, spec == currentSpec ? "  (current)" : ""), ProviderRow.Kind.model, spec);
    auto first = rows.length;
    auto names = enabledProviderNames(all);
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
    out size_t initial) pure
{
    alias C = Tuple!(Nullable!Thinking, string);
    C[] choices;
    if (scope_ < 2) choices ~= C(Nullable!Thinking.init, "unset (use the broader setting)");
    choices ~= C(Nullable!Thinking(Thinking.parse("default").unwrap("a valid level")), "default (send no level; the model decides)");
    // Levels can come from the endpoint, so one that doesn't parse is skipped.
    foreach (l; levels) foreach (t; Thinking.parse(l).toOption) choices ~= C(Nullable!Thinking(t), l);
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
bool isQwenProvider(string name, const ref ProviderConfig p) pure
{
    import nano.qwen : isModelStudioUrl;
    return name == "qwen" || (p.baseUrl.length && isModelStudioUrl(p.baseUrl));
}

/// What a row of the Qwen endpoint picker does.
enum QwenChoice { known, custom, keep }

/// One row of the Qwen / Model Studio endpoint picker.
struct QwenRow
{
    string label;
    QwenChoice choice;
    /// The endpoint, for `QwenChoice.known`.
    immutable(QwenEndpoint)* endpoint;
}

/// The endpoint picker for a provider now on `currentUrl`: the current
/// endpoint first (so Enter keeps it), every other endpoint once, then
/// Custom URL and Keep.
QwenRow[] qwenEndpointRows(string currentUrl) pure
{
    import nano.qwen : endpointForUrl, endpoints;
    auto match = endpointForUrl(currentUrl);
    QwenRow[] rows;
    if (match !is null) rows ~= QwenRow(match.label ~ "  (current)", QwenChoice.known, match);
    foreach (ref e; endpoints) if (&e !is match) rows ~= QwenRow(e.label, QwenChoice.known, &e);
    rows ~= QwenRow("Custom URL (e.g. your workspace domain, a proxy)", QwenChoice.custom);
    rows ~= QwenRow(match is null ? "Keep " ~ currentUrl : format("Keep current URL (%s)", currentUrl), QwenChoice.keep);
    return rows;
}

/// The row picked (`-1` for Esc); Esc or a stale index keeps the endpoint.
QwenRow qwenEndpointPick(ptrdiff_t pick, const QwenRow[] rows) pure
{
    if (pick < 0 || pick >= rows.length) return QwenRow(null, QwenChoice.keep);
    return QwenRow(rows[pick].label, rows[pick].choice, rows[pick].endpoint);
}

/// Point `p` at endpoint `e`. A plan variable (one of the known plan
/// `api_key_env` names) moves to `e`'s plan; a custom variable, a literal key
/// or a command stays, and no variable is introduced where there was none
/// (an unused env var would shadow a key command: env ranks above command).
void applyQwenEndpoint(ref ProviderConfig p, const ref QwenEndpoint e) pure
{
    import nano.qwen : endpoints;
    p.baseUrl = e.baseUrl;
    if (!p.apiKeyEnv.length) return;
    foreach (ref k; endpoints) if (k.apiKeyEnv == p.apiKeyEnv) { p.apiKeyEnv = e.apiKeyEnv; return; }
}

/// The env-var prompt's default: the provider's variable, else the chosen
/// endpoint's plan variable, else `<NAME>_API_KEY`.
string suggestedKeyEnv(const ref ProviderConfig p, scope const(QwenEndpoint)* chosen, string name) pure
{
    import std.string : toUpper, replace;
    if (p.apiKeyEnv.length) return p.apiKeyEnv;
    if (chosen !is null) return chosen.apiKeyEnv;
    return name.toUpper.replace("-", "_") ~ "_API_KEY";
}

/// A model-picker step: back to the providers, or a model ID ("" prompts for one).
struct ModelStep
{
    bool back;
    string model;
}

/// The model picker's row `pick` (`-1` for Esc) over `models`, followed by
/// "Other (type a model ID)" and "Back to providers".
ModelStep modelChoice(ptrdiff_t pick, const string[] models) pure
{
    if (pick < 0 || pick > models.length) return ModelStep(true);
    return ModelStep(false, pick == models.length ? "" : models[pick]);
}

/// `provider/model` for a typed ID; a blank ID goes back.
ModelStep modelSpec(string provider, string id) pure
{
    return id.strip.length ? ModelStep(false, provider ~ "/" ~ id.strip) : ModelStep(true);
}

/// Whether an edit to provider `name` must rebuild the running client: it
/// built the client, or the configured model now resolves to it (a
/// `work/foo` spec falls back to the default provider until `work` exists).
/// `c.providers` is the effective table (presets and legacy keys applied).
bool editRebuilds(const ref Config c, string name, string clientProvider) pure
{
    string provider, model;
    parseModelSpec(c.model, c.providers, c.defaultProvider, provider, model);
    return clientProvider == name || provider == name;
}

/// Notices after a successful save: an earlier save failure is resolved.
string[] clearSaveFailures(string[] notices) pure
{
    import std.algorithm : filter, startsWith;
    import std.array : array;
    return notices.filter!(n => !n.startsWith("Could not save")).array;
}

/// The user's entry after an edit: only fields that differ from the preset,
/// with key sources replaced and an emptied preset `api_key_env` kept as "".
ProviderConfig diffFrom(const ref ProviderConfig preset, const ref ProviderConfig existing, const ref ProviderConfig updated) pure
{
    import nano.safeio : deepCopy;
    ProviderConfig e = deepCopy(existing);
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

string kindName(ProviderKind k) pure
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

private string temperatureLiteral(double t) pure { return isNaN(t) ? tomlString("default") : tomlFloat(t); }

private string thinkingLiteral(const Nullable!Thinking t) pure
{
    return t.isNull ? null : tomlString(t.get.toString);
}

/// The config text with `changes` applied (settings.rs `save`, minus the
/// write). `user` holds each changed provider's own entry.
string applyChanges(string doc, const ref Config c, const ref Changes ch, const ProviderConfig[string] user) pure
{
    import std.string : indexOf;
    import nano.ui : vname = name;
    import nano.result : orThrow;
    // The edge for toml_edit: a key a line edit can't follow fails the save.
    string tomlSet(string doc, const string[] path, string key, string value)
    {
        return nano.toml_edit.tomlSet(doc, path, key, value).orThrow!(e => new Exception(e));
    }
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
    if (ch.subagents) doc = tomlSet(doc, [], "subagents", c.subagents ? "true" : "false");
    if (ch.sessionMessages) doc = tomlSet(doc, [], "session_messages", c.sessionMessages ? "true" : "false");
    if (ch.sessionMessagesConfirm)
        doc = tomlSet(doc, [], "session_messages_confirm", c.sessionMessagesConfirm ? "true" : "false");
    // The retired `renderer` key (Rust #133) is dropped on any save.
    doc = tomlSet(doc, [], "renderer", null);
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
void save(const ref Config c, const ref Changes ch, const ProviderConfig[string] user, string path)
{
    import std.file : exists, readText, mkdirRecurse, rename, write;
    import std.path : dirName;
    import std.conv : octal;
    auto doc = path.exists ? readText(path) : "";
    doc = applyChanges(doc, c, ch, user);
    bool secret;
    foreach (ref p; user) if (p.apiKey.length) secret = true;
    // The file may already hold inline keys of providers this save leaves
    // alone; keep it private so a rewrite never widens their permissions.
    foreach (ref p; c.providers) if (p.apiKey.length) secret = true;
    if (path.dirName.length) mkdirRecurse(path.dirName);
    auto tmp = path ~ ".tmp";
    write(tmp, doc);
    version (Posix)
    {
        import nano.safeio : chmodPath;
        if (secret) chmodPath(tmp, octal!600);
    }
    rename(tmp, path);
}

// rust: settings.rs::editing_a_preset_stores_only_the_overrides
// rust: settings.rs::switching_a_preset_to_a_key_command_overrides_its_env_var
// rust: settings.rs::save_updates_only_changed_keys_and_keeps_comments
// rust: settings.rs::thinking_choices_offer_the_models_levels_for_every_scope
// rust: settings.rs::thinking_choices_default_lands_on_the_existing_level
// rust: settings.rs::provider_rows_list_recents_first_and_highlight_the_previous_model
// rust: settings.rs::recent_models_keep_four_with_a_configured_provider
// rust: settings.rs::turn_cap_label_marks_zero_as_unbounded
// rust: settings.rs::recent_models_skip_hidden_providers_without_consuming_slots
unittest
{
    import std.algorithm : canFind;
    assert(turnCapLabel(0) == "unbounded" && maxTokensLabel(0, "model default") == "auto (model default)");
    ProviderConfig a, b;
    ProviderConfig[string] all = ["a": a, "b": b];
    assert(recentModels(["a/x", "gone/y", "b/z", "a/1", "a/2", "a/3"], all) == ["a/x", "b/z", "a/1", "a/2"]);
    ProviderConfig work;
    work.hidden = true;
    ProviderConfig[string] withHidden = ["a": a, "b": b, "work": work];
    assert(recentModels(["work/llama3", "a/claude", "bare-model", "b/gpt-5", "b/o3"], withHidden)
        == ["a/claude", "bare-model", "b/gpt-5", "b/o3"]);
    size_t initial;
    auto rows = providerRows(["a/x", "b/z"], "a/x", "b", all, initial, "/nonexistent");
    assert(rows[0].label == "↺ a/x  (current)" && initial == 1);
    assert(rows[$ - 1].kind == ProviderRow.Kind.cancel && rows.length == 5);
    rows = providerRows([], "a/x", "b", all, initial, "/nonexistent");
    assert(initial == 1 && rows[1].value == "b");

    // A disabled provider is not offered; the preselection counts shown rows.
    // rust: settings.rs::provider_rows_skip_disabled_providers_and_configured_models_show_names
    ProviderConfig off;
    off.disabled = true;
    ProviderConfig[string] some = ["a": a, "b": b, "off": off];
    rows = providerRows([], "b/x", "b", some, initial, "/nonexistent");
    assert(rows.length == 3 && rows[1].value == "b" && initial == 1);
    {
        import nano.ui : providersListing;
        auto listing = providersListing(some, "a", "/nonexistent");
        assert(listing.canFind("\n  b ") && !listing.canFind("off"), listing);
    }
    {
        import nano.settings_dialog : modelLabel;
        assert(modelLabel("amazon/nova-lite-v1", "Nova Lite 1.0") == "Nova Lite 1.0  (amazon/nova-lite-v1)");
        assert(modelLabel("m", " ") == "m");
        assert(!modelLabel("m", "A\x1b[2Jb").canFind('\x1b'), "escape dropped");
    }

    auto ch = thinkingChoices(1, ["low", "high"], Nullable!Thinking(Thinking.parse("medium").unwrap("a valid level")), initial);
    assert(ch.length == 5 && ch[0][1].canFind("unset") && ch[4][1] == "medium" && initial == 4);
    ch = thinkingChoices(2, ["low"], Nullable!Thinking.init, initial);
    assert(ch.length == 2 && initial == 0);
    // A level the endpoint reports but that doesn't parse is left out.
    ch = thinkingChoices(2, ["low", "very high"], typeof(ch[0][0]).init, initial);
    assert(ch.length == 2 && !ch.canFind!(c => c[1] == "very high"));

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
    // Saving drops the retired `renderer` key.
    Changes none_;
    assert(applyChanges("renderer = \"legacy\"\nmodel = \"a/b\"\n", c, none_, null) == "model = \"a/b\"\n");

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

// rust: settings.rs::save_writes_thinking_levels_in_place
// rust: settings.rs::save_keeps_temperature_comments_when_the_provider_is_also_edited
unittest
{
    import std.math : isNaN;
    import nano.thinking : Thinking;
    auto doc = "temperature = 0.2 # global tune\n\n[providers.groq] # fast\nmax_retries = 2\n"
        ~ "temperature = 0.1 # tuned for this provider\nthinking = \"high\" # tuned\n\n"
        ~ "[providers.kimi]\nmodels = { k3 = { temperature = 0.7, thinking = \"low\" } }\n";
    Config c;
    c.temperature = double.nan;
    ProviderConfig groq, kimi;
    groq.temperature = 0.4;
    groq.thinking = Thinking.off;
    kimi.models["k3"] = ModelSettings.init;
    c.providers = ["groq": groq, "kimi": kimi];
    c.providers["anthropic"] = ProviderConfig.init;
    c.providers["anthropic"].models["claude"] = ModelSettings.init;
    c.providers["anthropic"].models["claude"].temperature = 0.3;
    c.providers["anthropic"].models["claude"].thinking = Thinking.parse("xhigh").unwrap("a valid level");
    Changes ch;
    ch.temperature = true;
    ch.providerTemperatures["groq"] = true;
    ch.providerThinking["groq"] = true;
    ch.modelTemperatures[pairKey("anthropic", "claude")] = true;
    ch.modelThinking[pairKey("anthropic", "claude")] = true;
    auto out_ = applyChanges(doc, c, ch, null);
    import std.algorithm : canFind;
    assert(out_.canFind("temperature = \"default\" # global tune\n"), out_);
    assert(out_.canFind("[providers.groq] # fast\nmax_retries = 2\ntemperature = 0.4 # tuned for this provider\nthinking = \"off\" # tuned\n"), out_);
    // Not changed, so the inline table is left as written.
    assert(out_.canFind("models = { k3 = { temperature = 0.7, thinking = \"low\" } }"), out_);
    assert(out_.canFind("temperature = 0.3") && out_.canFind("thinking = \"xhigh\""), out_);
}

// rust: settings.rs::save_writes_provider_and_model_temperatures_in_place
unittest
{
    import std.algorithm : canFind;
    import std.math : isNaN;
    import nano.toml : parseToml;
    import nano.result : unwrap;
    auto doc = "temperature = 0.2 # global tune\n\n[providers.groq] # fast\nmax_retries = 2\n"
        ~ "temperature = 0.1 # tuned for this provider\n\n[providers.kimi]\nmodels = { \"k3\" = { temperature = 0.5 } }\n";
    Config c;
    c.temperature = double.nan;
    ProviderConfig groq, kimi;
    groq.temperature = 0.4;
    kimi.models["k3"] = ModelSettings.init; // temperature unset
    c.providers = ["groq": groq, "kimi": kimi];
    c.providers["anthropic"] = ProviderConfig.init;
    c.providers["anthropic"].models["claude"] = ModelSettings.init;
    c.providers["anthropic"].models["claude"].temperature = 0.3;
    Changes ch;
    ch.temperature = true;
    ch.providerTemperatures["groq"] = true;
    ch.modelTemperatures[pairKey("anthropic", "claude")] = true;
    ch.modelTemperatures[pairKey("kimi", "k3")] = true;
    auto text = applyChanges(doc, c, ch, null);
    assert(text.canFind("temperature = \"default\" # global tune"), text);
    assert(text.canFind("[providers.groq] # fast\nmax_retries = 2\ntemperature = 0.4 # tuned for this provider"), text);
    assert(text.canFind("[providers.anthropic.models.claude]\ntemperature = 0.3"), text);
    assert(!text.canFind("[providers]\n") && !text.canFind("[providers.anthropic]\n"), text);
    assert(!text.canFind("0.5"), "unsetting inside an inline table removes the key: " ~ text);
    parseToml(text).unwrap("valid TOML"); // still valid TOML
}

// rust: settings.rs::save_creates_a_missing_file
unittest
{
    import std.file : tempDir, rmdirRecurse, readText, exists;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-settings-save-test");
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto path = buildPath(dir, "nested/config.toml");
    Config c;
    c.model = "ollama/qwen3";
    Changes ch;
    ch.model = true;
    save(c, ch, null, path);
    assert(readText(path) == "model = \"ollama/qwen3\"\n");
}

unittest
{
    // A save that touches no provider still keeps a file holding inline
    // keys private (e.g. `/subagents off --save`).
    import std.file : tempDir, remove, exists, getAttributes;
    import std.path : buildPath;
    import std.conv : octal;
    auto path = buildPath(tempDir, "nano-settings-secret-test.toml");
    scope (exit) if (path.exists) remove(path);
    Config c;
    ProviderConfig p;
    p.apiKey = "k";
    c.providers["box"] = p;
    c.subagents = false;
    Changes ch;
    ch.subagents = true;
    save(c, ch, null, path);
    version (Posix) assert((getAttributes(path) & octal!7777) == octal!600);
}
