/// The `/settings` dialog and the interactive `/model` picker (settings.rs
/// `run`, `pick_model_interactive`, `edit_provider` and the editors), over
/// a small prompt interface so tests can script it.
module nano.settings_dialog;

@safe:

import std.format : format;
import std.math : isNaN;
import std.string : strip, toUpper;
import std.array : replace;
import std.typecons : Nullable;
import nano.config : Config, ProviderConfig, ProviderKind, ModelSettings, presets;
import nano.agent : Agent;
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

/// What the dialog asks of the app.
struct SettingsHost
{
    Config* cfg;
    Agent agent;
    string configPath;
    string[] delegate() @safe recents;
    /// Switches the session's model (recording it in recents); an error or null.
    string delegate(string spec) @safe switchModel;
    /// The provider's model IDs (throws on failure).
    string[] delegate(string provider) @safe listModels;
    /// Rebuilds the system prompt after `system_prompt` changed.
    void delegate() @safe refreshSystem;
    /// Rebuilds the client when `provider` is the session's; an error or null.
    string delegate(string provider) @safe refreshClient;
    /// Where `/providers` key status reads stored logins (tests).
    string dataDir;
}

/// The bare `/model` picker: a recent model or a provider, then its model.
/// Returns the chosen spec, or null.
string pickModel(SettingsUi ui, ref SettingsHost h) @trusted
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

/// A model from `name`'s list (or typed); null goes back to the providers.
string pickFromProvider(SettingsUi ui, ref SettingsHost h, string name) @trusted
{
    import std.algorithm : countUntil;
    auto p = name in h.cfg.providers;
    string defaultModel = p !is null ? p.defaultModel : null;
    ui.say(format("Fetching models from %s...", name));
    string[] models;
    try models = h.listModels(name);
    catch (Exception e) ui.say(format("Could not list models: %s", e.msg));
    string model;
    enum typed = "Model ID (empty to go back to the provider list)";
    if (!models.length) model = ui.input(typed, "");
    else
    {
        auto labels = models ~ ["Other (type a model ID)", "Back to providers"];
        auto at = models.countUntil(defaultModel);
        auto i = ui.select(format("Model from %s (Esc to go back)", name), labels, at >= 0 ? at : 0);
        if (i < 0 || i > models.length) return null;
        model = i == models.length ? ui.input(typed, "") : models[i];
    }
    if (model is null || !model.strip.length) return null;
    return name ~ "/" ~ model.strip;
}

/// The dialog. Returns notices to show after it closes.
string[] runSettings(SettingsUi ui, ref SettingsHost h) @trusted
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
            format("Max tokens       %s", maxTokensLabel(cfg.maxTokens, a.maxTokens > 0 ? format("%s", a.maxTokens) : "model default")),
            format("Turn cap         %s", turnCapLabel(cfg.maxIterations)),
            "System prompt",
            format("Context          %s window, auto-compact %s, %s compaction", formatTokens(a.contextWindow),
                cfg.autoCompact ? format("at %.0f%%", cfg.autoCompactThreshold * 100) : "off", cfg.compactionMode),
            format("Verbosity        %s (%s)", cfg.verbosity.vname, cfg.verbosity.vdescribe),
            format("Renderer         %s (%s)", cfg.renderer, rendererDescribe(cfg.renderer)),
            format("Save to config file%s", changes.any ? " (unsaved changes)" : ""),
            "Done",
        ];
        auto sel = ui.select("Select setting", items, 0);
        if (sel < 0 || sel == 11)
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
            case 9:
                auto modes = ["legacy", "frame"];
                auto i = ui.select("Renderer", [format("%-7s %s", "legacy", rendererDescribe("legacy")),
                    format("%-7s %s", "frame", rendererDescribe("frame"))], cfg.renderer == "frame" ? 1 : 0);
                if (i < 0) break;
                if (modes[i] != cfg.renderer) ui.say(format("Renderer set to %s — taking effect now.", modes[i]));
                cfg.renderer = modes[i];
                changes.renderer = true;
                break;
            case 10: saveAndReport(ui, h, changes, notices); break;
            default: break;
        }
    }
}

/// Applies a verbosity picked in the dialog (set by the app).
void delegate(imported!"nano.ui".Verbosity) @safe onVerbosity;

string rendererDescribe(string mode)
{
    return mode == "frame" ? "app-owned frame; nano-coder re-renders on a width change"
        : "scroll region; the terminal owns scrollback and reflow";
}

private bool parseCount(string t, out long v)
{
    import std.conv : to;
    try { v = t.strip.to!long; return v >= 0; }
    catch (Exception) return false;
}

private void switchTo(SettingsUi ui, ref SettingsHost h, string spec, ref Changes changes, ref string[] notices) @trusted
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

private void saveAndReport(SettingsUi ui, ref SettingsHost h, ref Changes changes, ref string[] notices) @trusted
{
    ProviderConfig[string] user;
    foreach (n; changes.providers.byKey) if (auto p = n in h.cfg.providers) user[n] = *p;
    if (userEntries !is null) foreach (n, p; userEntries) if (n in changes.providers) user[n] = p;
    try
    {
        save(*h.cfg, changes, user, h.configPath);
        changes = Changes.init;
        ui.say(format("Saved to %s", h.configPath));
    }
    catch (Exception e) notices ~= format("Could not save settings: %s", e.msg);
}

/// The user's own entries for providers edited this visit (the diff from presets).
private ProviderConfig[string] userEntries;

private bool editContext(SettingsUi ui, ref SettingsHost h) @trusted
{
    import nano.context : CompactionMode;
    auto cfg = h.cfg;
    auto a = h.agent;
    bool auto_ = confirm(ui, "Auto-compact when the context fills up?", cfg.autoCompact);
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
            catch (Exception) { ui.say("between 10 and 99"); continue; }
            if (p < 10 || p > 99) { ui.say("between 10 and 99"); continue; }
            threshold = p / 100;
            break;
        }
    }
    auto m = ui.select("Compaction mode", ["standard: summary only",
        "smart (experimental): summary cites the session log; history tools recover originals"],
        cfg.compactionMode == "smart" ? 1 : 0);
    if (m < 0) return false;
    auto w = ui.input("Context window in tokens (0 = from provider/model)", format("%s", cfg.contextWindow));
    long window;
    if (w is null || !parseCount(w, window)) return false;
    cfg.autoCompact = a.autoCompact = auto_;
    cfg.autoCompactThreshold = a.autoCompactThreshold = threshold;
    cfg.compactionMode = m == 1 ? "smart" : "standard";
    a.compactionMode = m == 1 ? CompactionMode.smart : CompactionMode.standard;
    cfg.contextWindow = window;
    auto pc = a.client.providerName in cfg.providers;
    a.configuredWindow = window > 0 ? cast(size_t) window : pc !is null && pc.contextWindow > 0 ? cast(size_t) pc.contextWindow : 0;
    return true;
}

private string[] scopes(Agent a) @trusted
{
    auto p = a.client.providerName, m = a.client.modelName;
    return [format("This model (%s/%s)", p, m), format("All %s models", p), "All models (global)"];
}

private void editTemperature(SettingsUi ui, ref SettingsHost h, ref Changes changes) @trusted
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

private void editThinking(SettingsUi ui, ref SettingsHost h, ref Changes changes) @trusted
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
private string editProvider(SettingsUi ui, ref SettingsHost h, ref string[] notices) @trusted
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

    immutable kinds = [ProviderKind.openai, ProviderKind.anthropic, ProviderKind.githubCopilot, ProviderKind.muse];
    auto kindLabels = ["OpenAI-compatible (/chat/completions)", "Anthropic (/messages)", "GitHub Copilot (unofficial)",
        "Muse Code (unofficial)"];
    size_t kindDefault;
    foreach (i, k; kinds) if (current.hasKind && current.kind == k) kindDefault = i;
    auto ki = ui.select("API kind", kindLabels, kindDefault);
    if (ki < 0) return null;
    auto kind = kinds[ki];

    const(qwen.QwenEndpoint)* chosen;
    bool forceUrl;
    if (isQwenProvider(name, current))
    {
        auto match = qwen.endpointForUrl(currentUrl);
        string[] rows;
        const(qwen.QwenEndpoint)*[] eps;
        if (match !is null) { rows ~= match.label ~ "  (current)"; eps ~= match; }
        foreach (ref e; qwen.endpoints) if (&e !is match) { rows ~= e.label; eps ~= &e; }
        rows ~= "Custom URL (e.g. your workspace domain, a proxy)";
        rows ~= match is null ? "Keep " ~ currentUrl : format("Keep current URL (%s)", currentUrl);
        auto pick = ui.select("Qwen / Model Studio endpoint", rows, rows.length - 1);
        if (pick >= 0 && pick < eps.length) chosen = eps[pick];
        else if (pick == eps.length) forceUrl = true;
    }
    string baseUrl;
    if (chosen !is null) baseUrl = chosen.baseUrl;
    else
    {
        import nano.copilot : defaultApiBase, domain;
        string dflt = forceUrl ? "" : current.baseUrl.length ? current.baseUrl
            : kind == ProviderKind.githubCopilot && choice == 0 && name !in cfg.providers && domain() == "github.com"
                ? defaultApiBase : "";
        bool optional = kind == ProviderKind.githubCopilot || kind == ProviderKind.muse;
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
    if (chosen !is null)
    {
        bool known;
        foreach (ref e; qwen.endpoints) if (e.apiKeyEnv == updated.apiKeyEnv) known = true;
        if (updated.apiKeyEnv.length && known) updated.apiKeyEnv = chosen.apiKeyEnv;
    }
    auto sources = ["Environment variable (recommended)", "Shell command (e.g. `op read ...`, `gh auth token`)",
        "Literal key, saved in the config file", "No key", "Keep current"];
    size_t srcDefault = current.apiKeyEnv.length || current.apiKeyCommand.length || current.apiKey.length ? 4 : 0;
    auto src = ui.select(format("API key (%s)", keyStatus(updated, h.dataDir)), sources, srcDefault);
    if (src < 0) return null;
    switch (src)
    {
        case 0:
            auto suggested = updated.apiKeyEnv.length ? updated.apiKeyEnv : chosen !is null ? chosen.apiKeyEnv
                : name.toUpper.replace("-", "_") ~ "_API_KEY";
            auto v = ui.input("Variable name", suggested);
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
        else if (err.length) notices ~= stale ~ " " ~ err;
    }
    return name;
}

private string kindLabelOf(ProviderKind k)
{
    final switch (k)
    {
        case ProviderKind.openai: return "openai";
        case ProviderKind.anthropic: return "anthropic";
        case ProviderKind.githubCopilot: return "githubcopilot";
        case ProviderKind.muse: return "muse";
        case ProviderKind.mock: return "mock";
    }
}
