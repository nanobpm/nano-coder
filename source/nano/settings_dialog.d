/// The `/settings` dialog and the interactive `/model` picker (settings.rs
/// `run`, `pick_model_interactive`, `edit_provider` and the editors), over
/// a small prompt interface so tests can script it.
module nano.settings_dialog;

@safe:

import nano.arith : toSize;

import nano.option : NotNull;
import std.format : format;
import std.math : isNaN;
import std.string : strip, toUpper;
import std.array : replace;
import std.typecons : Nullable;
import nano.config : Config, ProviderConfig, ProviderKind, ModelSettings, presets;
import nano.agent : Agent, ConfiguredWindow;
import nano.settings;

/// The prompts the dialog needs. `select` and `input` return -1 / null on Esc.
interface SettingsUi
{
    ptrdiff_t select(string prompt, const string[] labels, size_t initial);
    string input(string prompt, string initial);
    string secret(string prompt);
    void say(string line);
}

bool confirm(SettingsUi ui, string prompt, bool dflt)
{
    return ui.select(prompt, ["Yes", "No"], dflt ? 0 : 1) == 0;
}

/// Asks yes or no; false when cancelled (Esc), so a caller that changes a
/// setting can leave it alone rather than read Esc as "No".
private bool askYesNo(SettingsUi ui, string prompt, bool dflt, out bool answer)
{
    auto sel = ui.select(prompt, ["Yes", "No"], dflt ? 0 : 1);
    if (sel < 0) return false;
    answer = sel == 0;
    return true;
}

/// What the dialog asks of the app.
struct SettingsHost
{
    Config* cfg;
    NotNull!Agent agent;
    string configPath;
    string[] delegate() @safe recents;
    /// Switches the session's model (recording it in recents); an error or null.
    string delegate(string spec) @safe switchModel;
    /// The provider's model IDs (throws on failure).
    string[] delegate(string provider) @safe listModels;
    /// Rebuilds the system prompt after `system_prompt` changed.
    void delegate() @safe refreshSystem;
    /// Rebuilds the client when `provider` is the session's: "" when rebuilt,
    /// an error message, or null when the session uses another provider.
    string delegate(string provider) @safe refreshClient;
    /// Where `/providers` key status reads stored logins (tests).
    string dataDir;
    /// Runs `/subagents <arg>` (`on`/`off`) and returns its reply, so the
    /// dialog switches the `agent` tool the same way the command does.
    string delegate(string arg) @safe subagentsCommand;
    /// Re-applies the `subagent_*` settings of `cfg` to the session after
    /// the dialog changed the model, limits or candidates.
    void delegate() @safe reconfigureSubagents;
    /// Runs `/messages <arg>` (`on`, `off`, `confirm on`, `confirm off`)
    /// and returns its reply, so the registry socket opens or closes as
    /// with the command.
    string delegate(string arg) @safe messagesCommand;
    /// Whether this session has inter-session messages on (listening).
    bool delegate() @safe messagesOn;
    /// Whether incoming messages wait for confirmation.
    bool delegate() @safe messagesConfirm;
}

/// The bare `/model` picker: a recent model or a provider, then its model.
/// Returns the chosen spec, or null.
string pickModel(SettingsUi ui, ref SettingsHost h)
{
    import nano.recents : canonical;
    auto cfg = h.cfg;
    auto a = h.agent;
    ui.say(format("Current model: %s (provider %s)", a.client.modelName, a.client.providerName));
    auto recent = recentModels(h.recents(), cfg.providers);
    auto current = canonical(a.client.providerName ~ "/" ~ a.client.modelName, cfg.providers, cfg.defaultProvider);
    for (;;)
    {
        size_t initial;
        auto rows = providerRows(recent, current, a.client.providerName, cfg.providers, initial, h.dataDir);
        string[] labels;
        foreach (r; rows) labels ~= r.label;
        auto prompt = recent.length
            ? "Recent model or provider (↑/↓ to scroll, Enter to select, Esc to keep the current model)"
            : "Provider (↑/↓ to scroll, Enter to select, Esc to keep the current model)";
        auto i = ui.select(prompt, labels, initial);
        if (i < 0 || rows[i].kind == ProviderRow.Kind.cancel) return null;
        if (rows[i].kind == ProviderRow.Kind.model) return rows[i].value;
        auto spec = pickFromProvider(ui, h, rows[i].value);
        if (spec !is null) return spec;
    }
}

/// A configured model's picker row: its display name, then its id.
string modelLabel(string id, string name) pure
{
    import nano.trajectory : terminalSafe;
    return name.strip.length ? format("%s  (%s)", terminalSafe(name), id) : id;
}

/// A model from `name`'s list (or typed); null goes back to the providers.
string pickFromProvider(SettingsUi ui, ref SettingsHost h, string name)
{
    import std.algorithm : countUntil;
    auto p = name in h.cfg.providers;
    string defaultModel = p !is null ? p.defaultModel : null;
    // A curated list (`list_models = "configured"`) needs no request.
    auto configured = p !is null ? p.configuredModels : null;
    string[] models, shown;
    if (configured !is null)
        foreach (m; configured) models ~= m[0], shown ~= modelLabel(m[0], m[1]);
    else
    {
        ui.say(format("Fetching models from %s...", name));
        try models = h.listModels(name);
        catch (Exception e) ui.say(format("Could not list models: %s", e.msg));
        shown = models;
    }
    string model;
    enum typed = "Model ID (empty to go back to the provider list)";
    if (!models.length) model = ui.input(typed, "");
    else
    {
        auto labels = shown ~ ["Other (type a model ID)", "Back to providers"];
        auto at = models.countUntil(defaultModel);
        auto step = modelChoice(ui.select(format("Model from %s (Esc to go back)", name), labels, at >= 0 ? at : 0), models);
        if (step.back) return null;
        model = step.model.length ? step.model : ui.input(typed, "");
    }
    if (model is null) return null;
    auto spec = modelSpec(name, model);
    return spec.back ? null : spec.model;
}

/// The dialog. Returns notices to show after it closes.
string[] runSettings(SettingsUi ui, ref SettingsHost h)
{
    import nano.ui : Verbosity, allVerbosities, vname = name, vdescribe = describe;
    import nano.context : formatTokens;
    Changes changes;
    string[] notices;
    auto cfg = h.cfg;
    auto a = h.agent;
    for (;;)
    {
        ui.say(format("\nSettings (%s):", h.configPath));
        auto items = [
            format("Model            %s (provider %s)", cfg.model, a.client.providerName),
            "Add or edit a provider",
            format("Temperature      %s", a.temperatureNow.describe),
            format("Thinking         %s", a.thinking.describe),
            format("Max tokens       %s", maxTokensLabel(cfg.maxTokens, format("%s", a.effectiveMaxTokens))),
            format("Turn cap         %s", turnCapLabel(cfg.maxIterations)),
            "System prompt",
            format("Context          %s window, auto-compact %s, %s compaction", formatTokens(a.contextWindow),
                cfg.autoCompact ? format("at %.0f%%", cfg.autoCompactThreshold * 100) : "off", cfg.compactionMode),
            format("Verbosity        %s (%s)", cfg.verbosity.vname, cfg.verbosity.vdescribe),
            format("Sub-agents       %s", subagentsSummary(a.subagentsOn, cfg.subagentModel, cfg.subagentModels.length)),
            format("Session messages %s", messagesSummary(stateOf(h.messagesOn, cfg.sessionMessages),
                stateOf(h.messagesConfirm, cfg.sessionMessagesConfirm))),
            format("Save to config file%s", changes.any ? " (unsaved changes)" : ""),
            "Done",
        ];
        auto sel = ui.select("Select setting", items, 0);
        if (sel < 0 || sel == 12)
        {
            if (changes.any && confirm(ui, format("Save changes to %s?", h.configPath), true))
                saveAndReport(ui, h, changes, notices);
            return notices;
        }
        switch (sel)
        {
            case 0:
                if (auto spec = pickModel(ui, h)) switchTo(ui, h, spec, changes, notices);
                break;
            case 1:
                auto name = editProvider(ui, h, notices);
                if (name is null) break;
                changes.providers[name] = true;
                if (confirm(ui, format("Pick a model from %s now?", name), true))
                    if (auto spec = pickFromProvider(ui, h, name)) switchTo(ui, h, spec, changes, notices);
                break;
            case 2: editTemperature(ui, h, changes); break;
            case 3: editThinking(ui, h, changes); break;
            case 4:
                auto t = ui.input("Max tokens", format("%s", cfg.maxTokens));
                long v;
                if (t !is null && parseCount(t, v)) { cfg.maxTokens = v; a.maxTokens = v; changes.maxTokens = true; }
                break;
            case 5:
                auto t = ui.input("Turn cap in LLM calls per input (0 = unbounded; a positive cap makes normal mode ask "
                    ~ "before stopping, auto ignores it)", format("%s", cfg.maxIterations));
                long v;
                if (t !is null && parseCount(t, v)) { cfg.maxIterations = v; a.maxIterations = v; changes.maxIterations = true; }
                break;
            case 6:
                auto t = ui.input("System prompt", cfg.systemPrompt);
                if (t is null) break;
                cfg.systemPrompt = t;
                h.refreshSystem();
                changes.systemPrompt = true;
                break;
            case 7: if (editContext(ui, h)) changes.compaction = true; break;
            case 8:
                string[] labels;
                size_t cur = 1;
                foreach (i, l; allVerbosities)
                {
                    labels ~= format("%-8s %s", l.vname, l.vdescribe);
                    if (l == cfg.verbosity) cur = i;
                }
                auto i = ui.select("Verbosity", labels, cur);
                if (i < 0) break;
                cfg.verbosity = allVerbosities[i];
                if (onVerbosity !is null) onVerbosity(allVerbosities[i]);
                changes.verbosity = true;
                break;
            case 9: editSubagents(ui, h, changes); break;
            case 10: editMessages(ui, h, changes); break;
            case 11: saveAndReport(ui, h, changes, notices); break;
            default: break;
        }
    }
}

/// Applies a verbosity picked in the dialog (set by the app).
void delegate(imported!"nano.ui".Verbosity) @safe onVerbosity;

private bool parseCount(string t, out long v) pure
{
    import std.conv : to;
    try { v = t.strip.to!long; return v >= 0; }
    catch (Exception) return false; // not a number: the caller asks again
}

private void switchTo(SettingsUi ui, ref SettingsHost h, string spec, ref Changes changes, ref string[] notices)
{
    import std.algorithm : filter, startsWith;
    import std.array : array;
    auto err = h.switchModel(spec);
    if (err !is null) { notices ~= "Could not switch model: " ~ err; return; }
    auto a = h.agent;
    h.cfg.model = a.client.providerName ~ "/" ~ a.client.modelName;
    changes.model = true;
    auto stale = format("Provider %s saved, but could not rebuild the client:", a.client.providerName);
    notices = notices.filter!(n => !n.startsWith(stale) && !n.startsWith("Could not switch model:")).array;
    ui.say(format("Model set to %s (provider %s)", a.client.modelName, a.client.providerName));
    if (auto w = a.temperatureNow.warning) ui.say("Warning: " ~ w);
    if (auto w = a.thinking.warning) ui.say("Warning: " ~ w);
}

private void saveAndReport(SettingsUi ui, ref SettingsHost h, ref Changes changes, ref string[] notices)
{
    ProviderConfig[string] user;
    foreach (n; changes.providers.byKey) if (auto p = n in h.cfg.providers) user[n] = *p;
    if (userEntries !is null) foreach (n, p; userEntries) if (n in changes.providers) user[n] = p;
    try
    {
        save(*h.cfg, changes, user, h.configPath);
        changes = Changes.init;
        notices = clearSaveFailures(notices);
        ui.say(format("Saved to %s", h.configPath));
    }
    catch (Exception e) notices ~= format("Could not save settings: %s", e.msg);
}

/// The user's own entries for providers edited this visit (the diff from presets).
private ProviderConfig[string] userEntries;

private bool editContext(SettingsUi ui, ref SettingsHost h)
{
    import nano.context : CompactionMode;
    auto cfg = h.cfg;
    auto a = h.agent;
    bool auto_;
    if (!askYesNo(ui, "Auto-compact when the context fills up?", cfg.autoCompact, auto_)) return false;
    double threshold = cfg.autoCompactThreshold;
    if (auto_)
    {
        for (;;)
        {
            auto t = ui.input("Compact at this % of the context window", format("%.0f", cfg.autoCompactThreshold * 100));
            if (t is null) return false;
            import std.conv : to;
            double p;
            try p = t.strip.to!double;
            catch (Exception) { ui.say("between 10 and 99"); continue; } // reported to the user just here, then asked again
            if (p < 10 || p > 99) { ui.say("between 10 and 99"); continue; }
            threshold = p / 100;
            break;
        }
    }
    auto m = ui.select("Compaction mode", ["standard: summary only",
        "smart: summary cites the session log; history tools recover originals",
        "extract: like smart, but the summary is built in code (no model call, instant)"],
        cfg.compactionMode == "extract" ? 2 : cfg.compactionMode == "smart" ? 1 : 0);
    if (m < 0) return false;
    auto w = ui.input("Context window in tokens (0 = from provider/model)", format("%s", cfg.contextWindow));
    long window;
    if (w is null || !parseCount(w, window)) return false;
    cfg.autoCompact = a.autoCompact = auto_;
    cfg.autoCompactThreshold = a.autoCompactThreshold = threshold;
    cfg.compactionMode = m == 2 ? "extract" : m == 1 ? "smart" : "standard";
    a.compactionMode = m == 2 ? CompactionMode.extract : m == 1 ? CompactionMode.smart : CompactionMode.standard;
    cfg.contextWindow = window;
    auto pc = a.client.providerName in cfg.providers;
    a.setConfiguredWindow(window > 0 ? ConfiguredWindow(toSize(window), "context_window in config")
        : pc !is null && pc.contextWindow > 0 ? ConfiguredWindow(toSize(pc.contextWindow), "provider context_window")
        : ConfiguredWindow.init);
    return true;
}

private string[] scopes(Agent a) pure
{
    auto p = a.client.providerName, m = a.client.modelName;
    return [format("This model (%s/%s)", p, m), format("All %s models", p), "All models (global)"];
}

private void editTemperature(SettingsUi ui, ref SettingsHost h, ref Changes changes)
{
    import nano.temperature : maxTemperature = MAX, show;
    auto a = h.agent;
    auto cfg = h.cfg;
    auto provider = a.client.providerName, model = a.client.modelName;
    auto current = a.temperatureNow;
    if (current.fixed.length)
    {
        ui.say(format("%s/%s always uses the model default: %s.", provider, model, current.fixed));
        return;
    }
    auto sc = ui.select("Set the temperature for", scopes(a), 0);
    if (sc < 0) return;
    auto entry = provider in cfg.providers;
    Nullable!double existing;
    if (sc == 0) { if (entry) if (auto ms = model in entry.models) existing = ms.temperature; }
    else if (sc == 1) { if (entry) existing = entry.temperature; }
    else existing = cfg.temperature;
    double value;
    bool unset;
    for (;;)
    {
        auto t = ui.input(format("Temperature (0-%s, \"default\" for the model default%s)", show(maxTemperature),
            sc < 2 ? ", empty to unset" : ""), existing.isNull ? "" : show(existing.get));
        if (t is null) return;
        t = t.strip;
        if (!t.length) { if (sc < 2) { unset = true; break; } continue; }
        if (t == "default") { value = double.nan; break; }
        import std.conv : to;
        try value = t.to!double;
        // reported to the user just here, then asked again
        catch (Exception) { ui.say(format("invalid temperature %s", t)); continue; }
        if (value < 0 || value > maxTemperature) { ui.say(format("temperature must be between 0 and %s", show(maxTemperature))); continue; }
        break;
    }
    auto pe = &cfg.providers.require(provider, ProviderConfig.init);
    if (sc == 0)
    {
        if (unset) { if (auto ms = model in pe.models) ms.temperature.nullify(); }
        else pe.models.require(model, ModelSettings.init).temperature = value;
        changes.modelTemperatures[pairKey(provider, model)] = true;
    }
    else if (sc == 1)
    {
        if (unset) pe.temperature.nullify();
        else pe.temperature = value;
        changes.providerTemperatures[provider] = true;
    }
    else
    {
        cfg.temperature = value;
        a.temperature = value;
        changes.temperature = true;
    }
    auto now = a.temperatureNow;
    ui.say("Temperature for this model: " ~ now.describe);
    if (now.warning.length) ui.say("Note: " ~ now.warning);
}

private void editThinking(SettingsUi ui, ref SettingsHost h, ref Changes changes)
{
    import nano.thinking : Thinking, Source;
    auto a = h.agent;
    auto cfg = h.cfg;
    auto provider = a.client.providerName, model = a.client.modelName;
    auto sc = ui.select("Set the thinking level for", scopes(a), 0);
    if (sc < 0) return;
    auto entry = provider in cfg.providers;
    Nullable!Thinking existing;
    if (sc == 0) { if (entry) if (auto ms = model in entry.models) existing = ms.thinking; }
    else if (sc == 1) { if (entry) existing = entry.thinking; }
    else existing = cfg.thinking;
    size_t initial;
    auto choices = thinkingChoices(sc, a.thinking.levels, existing, initial);
    string[] labels;
    foreach (c; choices) labels ~= c[1];
    auto pick = ui.select("Thinking level", labels, initial);
    if (pick < 0) return;
    auto value = choices[pick][0];
    auto pe = &cfg.providers.require(provider, ProviderConfig.init);
    if (sc == 0)
    {
        if (value.isNull) { if (auto ms = model in pe.models) ms.thinking.nullify(); }
        else pe.models.require(model, ModelSettings.init).thinking = value;
        changes.modelThinking[pairKey(provider, model)] = true;
    }
    else if (sc == 1)
    {
        pe.thinking = value;
        changes.providerThinking[provider] = true;
    }
    else if (!value.isNull)
    {
        cfg.thinking = value.get;
        a.globalThinking = value.get;
        changes.thinking = true;
    }
    auto now = a.thinking;
    ui.say("Thinking for this model: " ~ now.describe);
    if (now.source == Source.session)
        ui.say("Note: /thinking set a level for this session, which wins until /thinking reset.");
    if (now.warning.length) ui.say("Note: " ~ now.warning);
}

/// Add or edit a provider; returns its name, or null when cancelled.
private string editProvider(SettingsUi ui, ref SettingsHost h, ref string[] notices)
{
    import std.algorithm : sort, canFind, filter, startsWith;
    import std.array : array;
    import nano.ui : keyStatus, derivedEndpointSource;
    import qwen = nano.qwen;
    auto cfg = h.cfg;
    auto names = cfg.providers.keys;
    names.sort();
    string[] labels = ["New provider"];
    foreach (n; names) labels ~= cfg.userProviders.canFind(n) ? "✓ " ~ n : n;
    labels ~= "Cancel";
    auto choice = ui.select("Provider to add or edit", labels, 0);
    if (choice < 0 || choice == labels.length - 1) return null;
    string name;
    if (choice == 0)
    {
        for (;;)
        {
            auto n = ui.input("Name (used as the model prefix, e.g. work in work/llama3)", "");
            if (n is null) return null;
            n = n.strip;
            import std.string : indexOf;
            import std.algorithm : any;
            import std.ascii : isWhite;
            if (!n.length || n.indexOf('/') >= 0 || n.any!isWhite) { ui.say("use a non-empty name without '/' or spaces"); continue; }
            name = n;
            break;
        }
    }
    else name = names[choice - 1];
    auto pp = name in cfg.providers;
    ProviderConfig current = pp !is null ? *pp : ProviderConfig.init;
    auto allPresets = presets();
    auto presetP = name in allPresets;
    ProviderConfig preset = presetP !is null ? *presetP : ProviderConfig.init;
    string currentUrl = current.baseUrl.length ? current.baseUrl : name == "qwen" ? preset.baseUrl : "";

    immutable kinds = [ProviderKind.openai, ProviderKind.anthropic, ProviderKind.githubCopilot];
    auto kindLabels = ["OpenAI-compatible (/chat/completions)", "Anthropic (/messages)", "GitHub Copilot (unofficial)"];
    size_t kindDefault;
    foreach (i, k; kinds) if (current.hasKind && current.kind == k) kindDefault = i;
    auto ki = ui.select("API kind", kindLabels, kindDefault);
    if (ki < 0) return null;
    auto kind = kinds[ki];

    const(qwen.QwenEndpoint)* chosen;
    bool forceUrl;
    if (isQwenProvider(name, current))
    {
        auto rows = qwenEndpointRows(currentUrl);
        string[] rowLabels;
        foreach (r; rows) rowLabels ~= r.label;
        auto row = qwenEndpointPick(ui.select("Qwen / Model Studio endpoint", rowLabels, rows.length - 1), rows);
        final switch (row.choice)
        {
            case QwenChoice.known: chosen = row.endpoint; break;
            case QwenChoice.custom: forceUrl = true; break;
            case QwenChoice.keep: break;
        }
    }
    string baseUrl;
    if (chosen !is null) baseUrl = chosen.baseUrl;
    else
    {
        import nano.copilot : defaultApiBase, domain;
        string dflt = forceUrl ? "" : current.baseUrl.length ? current.baseUrl
            : kind == ProviderKind.githubCopilot && choice == 0 && name !in cfg.providers && domain() == "github.com"
                ? defaultApiBase : "";
        bool optional = kind == ProviderKind.githubCopilot;
        for (;;)
        {
            auto u = ui.input("Base URL (e.g. http://merlin.local:8000/v1)", dflt);
            if (u is null) return null;
            import std.algorithm : stripRight;
            baseUrl = u.strip.stripRight('/');
            if (baseUrl.length || optional) break;
        }
    }

    ProviderConfig updated = current;
    updated.hasKind = true;
    updated.kind = kind;
    updated.baseUrl = baseUrl;
    if (chosen !is null) applyQwenEndpoint(updated, *chosen);
    auto sources = ["Environment variable (recommended)", "Shell command (e.g. `op read ...`, `gh auth token`)",
        "Literal key, saved in the config file", "No key", "Keep current"];
    size_t srcDefault = current.apiKeyEnv.length || current.apiKeyCommand.length || current.apiKey.length ? 4 : 0;
    auto src = ui.select(format("API key (%s)", keyStatus(updated, h.dataDir)), sources, srcDefault);
    if (src < 0) return null;
    switch (src)
    {
        case 0:
            auto v = ui.input("Variable name", suggestedKeyEnv(updated, chosen, name));
            if (v is null) return null;
            updated.apiKeyEnv = v.strip;
            updated.apiKeyEnvSet = true;
            updated.apiKeyCommand = updated.apiKey = null;
            break;
        case 1:
            auto v = ui.input("Command", current.apiKeyCommand);
            if (v is null) return null;
            updated.apiKeyCommand = v.strip;
            updated.apiKey = updated.apiKeyEnv = null;
            break;
        case 2:
            auto v = ui.secret("API key");
            if (v is null) return null;
            updated.apiKey = v.strip;
            updated.apiKeyEnv = updated.apiKeyCommand = null;
            break;
        case 3:
            updated.apiKey = updated.apiKeyEnv = updated.apiKeyCommand = null;
            break;
        default: break;
    }
    auto dm = ui.input("Default model (optional)", current.defaultModel);
    if (dm is null) return null;
    updated.defaultModel = dm.strip;

    ProviderConfig existingUser;
    if (userEntries !is null) if (auto e = name in userEntries) existingUser = *e;
    userEntries[name] = diffFrom(preset, existingUser, updated);
    cfg.providers[name] = updated;
    if (!cfg.userProviders.canFind(name)) cfg.userProviders ~= name;
    ui.say(format("Provider %s: %s %s", name, kindLabelOf(kind), updated.baseUrl.length ? updated.baseUrl
        : derivedEndpointSource(updated)));
    auto stale = format("Provider %s saved, but could not rebuild the client:", name);
    notices = notices.filter!(n => !n.startsWith(stale)).array;
    if (h.refreshClient !is null)
    {
        auto err = h.refreshClient(name);
        if (err is null) {}
        else if (!err.length) ui.say(format("Rebuilt the session's client for %s.", name));
        else notices ~= stale ~ " " ~ err;
    }
    return name;
}

private string kindLabelOf(ProviderKind k) pure nothrow
{
    final switch (k)
    {
        case ProviderKind.openai: return "openai";
        case ProviderKind.anthropic: return "anthropic";
        case ProviderKind.githubCopilot: return "githubcopilot";
        case ProviderKind.mock: return "mock";
    }
}

/// The `Sub-agents` row: on/off, the default model and the candidate count.
string subagentsSummary(bool on, string model, size_t candidates) pure
{
    return format("%s, model %s, %s candidate model%s", on ? "on" : "off",
        model.length ? model : "same as session", candidates, candidates == 1 ? "" : "s");
}

/// The `Session messages` row: on/off and whether incoming ones are confirmed.
string messagesSummary(bool on, bool confirm_) pure
{
    return format("%s, confirm %s", on ? "on" : "off", confirm_ ? "on" : "off");
}

private bool stateOf(bool delegate() @safe get, bool fallback)
{
    return get !is null ? get() : fallback;
}

/// A sub-agent candidate's row: its model, what it is for and its own limits.
string candidateLabel(const ref imported!"nano.config".SubagentModel m) pure
{
    import nano.trajectory : terminalSafe;
    string[] lim;
    if (m.timeoutSecs > 0) lim ~= format("timeout %ss", m.timeoutSecs);
    if (m.maxTurns > 0) lim ~= format("%s turns", m.maxTurns);
    if (m.maxTokens > 0) lim ~= format("%s tokens", m.maxTokens);
    import std.array : join;
    return format("%s — %s%s", m.model, m.use.length ? terminalSafe(m.use) : "(no use given)",
        lim.length ? " (" ~ lim.join(", ") ~ ")" : "");
}

/// Asks for a whole number of at least `min` until one is given; false on Esc.
private bool askCount(SettingsUi ui, string prompt, long min, ref long value)
{
    for (;;)
    {
        auto t = ui.input(prompt, format("%s", value));
        if (t is null) return false;
        long v;
        if (parseCount(t, v) && v >= min) { value = v; return true; }
        ui.say(format("enter a whole number of at least %s", min));
    }
}

private void editSubagents(SettingsUi ui, ref SettingsHost h, ref Changes changes)
{
    auto cfg = h.cfg;
    auto a = h.agent;
    void reconfigure() { if (h.reconfigureSubagents !is null) h.reconfigureSubagents(); }
    for (;;)
    {
        auto items = [
            format("Enabled          %s", a.subagentsOn ? "on" : "off"),
            format("Default model    %s", cfg.subagentModel.length ? cfg.subagentModel : "same as session"),
            format("Max concurrent   %s", cfg.subagentMaxConcurrency),
            format("Timeout          %ss", cfg.subagentTimeoutSecs),
            format("Max turns        %s", cfg.subagentMaxTurns),
            format("Max tokens       %s", cfg.subagentMaxTokens),
            format("Candidate models %s", cfg.subagentModels.length),
            "Back",
        ];
        auto sel = ui.select("Sub-agents", items, 0);
        if (sel < 0 || sel == 7) return;
        switch (sel)
        {
            case 0:
                bool on;
                if (!askYesNo(ui, "Offer sub-agents (the agent tool)?", a.subagentsOn, on) || on == a.subagentsOn) break;
                if (h.subagentsCommand !is null) ui.say(h.subagentsCommand(on ? "on" : "off"));
                if (a.subagentsOn != on) break; // not available in this session: nothing changed
                cfg.subagents = on;
                changes.subagents = true;
                break;
            case 1:
                auto m = ui.select("Model sub-agents run on", ["Same as the session's model", "Pick a model"],
                    cfg.subagentModel.length ? 1 : 0);
                if (m < 0) break;
                string spec;
                if (m == 1)
                {
                    spec = pickModel(ui, h);
                    if (spec is null) break;
                }
                cfg.subagentModel = spec;
                changes.subagentModel = true;
                reconfigure();
                break;
            case 2: .. case 5:
                static immutable prompts = ["Sub-agents running at once", "Sub-agent timeout in seconds",
                    "Sub-agent turn cap (LLM calls)", "Sub-agent token cap"];
                long*[4] fields = [&cfg.subagentMaxConcurrency, &cfg.subagentTimeoutSecs, &cfg.subagentMaxTurns,
                    &cfg.subagentMaxTokens];
                long v = *fields[sel - 2];
                if (!askCount(ui, prompts[sel - 2], 1, v)) break;
                *fields[sel - 2] = v;
                changes.subagentLimits = true;
                reconfigure();
                break;
            case 6:
                if (editCandidates(ui, h)) { changes.subagentModels = true; reconfigure(); }
                break;
            default: break;
        }
    }
}

/// The `[[subagent_models]]` list: add, edit or remove; true when it changed.
private bool editCandidates(SettingsUi ui, ref SettingsHost h)
{
    import std.algorithm : remove;
    auto cfg = h.cfg;
    bool changed;
    for (;;)
    {
        string[] labels;
        foreach (ref m; cfg.subagentModels) labels ~= candidateLabel(m);
        labels ~= ["Add a candidate model", "Back"];
        auto sel = ui.select("Candidate models the agent tool may pick", labels, 0);
        if (sel < 0 || sel == labels.length - 1) return changed;
        if (sel == labels.length - 2)
        {
            imported!"nano.config".SubagentModel m;
            if (editCandidate(ui, h, m, true)) { cfg.subagentModels ~= m; changed = true; }
            continue;
        }
        auto act = ui.select(cfg.subagentModels[sel].model, ["Edit", "Remove", "Back"], 0);
        if (act == 0)
        {
            auto m = cfg.subagentModels[sel];
            if (editCandidate(ui, h, m, false)) { cfg.subagentModels[sel] = m; changed = true; }
        }
        else if (act == 1)
        {
            cfg.subagentModels = cfg.subagentModels.dup.remove(sel);
            changed = true;
        }
    }
}

private bool editCandidate(SettingsUi ui, ref SettingsHost h, ref imported!"nano.config".SubagentModel m, bool isNew)
{
    import nano.config : specProblem;
    auto c = m;
    if (isNew || ui.select("Model", ["Keep " ~ c.model, "Pick another model"], 0) == 1)
    {
        auto spec = pickModel(ui, h);
        if (spec is null) return false;
        c.model = spec;
    }
    auto u = ui.input("Use for (what the agent picks this model for)", c.use);
    if (u is null) return false;
    c.use = u.strip;
    if (!askCount(ui, "Timeout in seconds (0 = the sub-agent default)", 0, c.timeoutSecs)) return false;
    if (!askCount(ui, "Turn cap (0 = the sub-agent default)", 0, c.maxTurns)) return false;
    if (!askCount(ui, "Token cap (0 = the sub-agent default)", 0, c.maxTokens)) return false;
    if (auto why = specProblem(*h.cfg, c.model)) ui.say("Warning: the agent tool won't offer it: " ~ why);
    m = c;
    return true;
}

private void editMessages(SettingsUi ui, ref SettingsHost h, ref Changes changes)
{
    auto cfg = h.cfg;
    for (;;)
    {
        bool on = stateOf(h.messagesOn, cfg.sessionMessages), conf = stateOf(h.messagesConfirm, cfg.sessionMessagesConfirm);
        auto sel = ui.select("Session messages", [format("Enabled          %s", on ? "on" : "off"),
            format("Confirm incoming %s", conf ? "on" : "off"), "Back"], 0);
        if (sel < 0 || sel == 2) return;
        if (sel == 0)
        {
            bool want;
            if (!askYesNo(ui, "Listen for messages from other sessions and offer session_send?", on, want) || want == on)
                continue;
            if (h.messagesCommand !is null) ui.say(h.messagesCommand(want ? "on" : "off"));
            auto now = stateOf(h.messagesOn, want);
            if (now != want) continue; // could not switch: nothing to save
            cfg.sessionMessages = now;
            changes.sessionMessages = true;
        }
        else
        {
            bool want;
            if (!askYesNo(ui, "Ask before accepting an incoming message?", conf, want) || want == conf) continue;
            if (h.messagesCommand !is null) ui.say(h.messagesCommand(want ? "confirm on" : "confirm off"));
            auto now = stateOf(h.messagesConfirm, want);
            if (now != want) continue; // could not switch: nothing to save
            cfg.sessionMessagesConfirm = now;
            changes.sessionMessagesConfirm = true;
        }
    }
}
