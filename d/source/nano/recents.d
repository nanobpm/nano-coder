/// Recently used `provider/model` specs, persisted as JSON in the app data
/// dir (recents.rs). The `/model` type-ahead offers them right after the
/// current model. Best-effort: a corrupt or unreadable file starts empty.
module nano.recents;

@safe:

import std.json;
import std.string : strip;
import nano.config : ProviderConfig, parseModelSpec;

enum maxRecents = 8;

/// The on-disk format version; 1 stores canonical `provider/model` entries.
enum formatVersion = 1;

/// `spec` as `provider/model` (or a bare provider without a default model),
/// parsed the way every model spec is, so a slash-containing model on the
/// default provider keeps its real provider prefix.
string canonical(string spec, const ProviderConfig[string] all, string defaultProvider) @trusted
{
    string provider, model;
    parseModelSpec(spec, all, defaultProvider, provider, model);
    if (!model.length)
        if (auto p = provider in all) model = p.defaultModel;
    return model.length ? provider ~ "/" ~ model : provider;
}

struct Recents
{
    /// A file without the marker is legacy (0) and is canonicalized once.
    uint version_ = formatVersion;
    /// Most recent first.
    string[] models;

    /// Record a switch to `spec`: it becomes the most recent, without duplicates.
    void record(string spec)
    {
        import std.algorithm : remove;
        spec = spec.strip;
        if (!spec.length) return;
        string[] kept = [spec];
        foreach (m; models) if (m != spec) kept ~= m;
        models = kept.length > maxRecents ? kept[0 .. maxRecents] : kept;
    }

    /// Migrate a legacy list to canonical entries, exactly once (re-running it
    /// on canonical entries would be lossy). True when it migrated.
    bool canonicalize(const ProviderConfig[string] all, string defaultProvider)
    {
        if (version_ >= formatVersion) return false;
        string[] out_;
        bool[string] seen;
        foreach (m; models)
        {
            auto c = canonical(m, all, defaultProvider);
            if (!c.length || c in seen) continue;
            seen[c] = true;
            out_ ~= c;
        }
        models = out_.length > maxRecents ? out_[0 .. maxRecents] : out_;
        version_ = formatVersion;
        return true;
    }

    /// serde_json's pretty form, as Rust writes it.
    string toJson() const
    {
        import nano.trajectory : serdeString;
        auto s = "{\n  \"version\": " ~ (() @trusted { import std.conv : to; return version_.to!string; })() ~ ",\n  \"models\": ";
        if (!models.length) return s ~ "[]\n}";
        s ~= "[";
        foreach (i, m; models) s ~= (i ? "," : "") ~ "\n    " ~ serdeString(m);
        return s ~ "\n  ]\n}";
    }
}

string defaultPath()
{
    import std.path : buildPath;
    import nano.copilot : appDataDir;
    return buildPath(appDataDir(), "recent-models.json");
}

Recents load(string path) @trusted
{
    import std.file : readText;
    Recents r;
    try
    {
        auto j = parseJSON(readText(path));
        if (j.type != JSONType.object) return Recents.init;
        r.version_ = 0;
        if (auto v = "version" in j)
        {
            if (v.type != JSONType.integer && v.type != JSONType.uinteger) return Recents.init;
            r.version_ = cast(uint) v.integer;
        }
        if (auto ms = "models" in j)
        {
            if (ms.type != JSONType.array) return Recents.init;
            foreach (m; ms.array)
            {
                if (m.type != JSONType.string) return Recents.init;
                r.models ~= m.str;
            }
        }
    }
    catch (Exception) return Recents.init;
    if (r.models.length > maxRecents) r.models = r.models[0 .. maxRecents];
    return r;
}

/// Write the list, creating the parent directory; errors are ignored.
void save(string path, const Recents r) @trusted
{
    import std.file : mkdirRecurse, write;
    import std.path : dirName;
    try
    {
        mkdirRecurse(path.dirName);
        write(path, r.toJson);
    }
    catch (Exception) {}
}

@trusted unittest
{
    ProviderConfig[string] all;
    foreach (n; ["openai", "together", "ollama"]) all[n] = ProviderConfig.init;
    assert(canonical("meta-llama/llama-4", all, "together") == "together/meta-llama/llama-4");
    assert(canonical("gpt-4o", all, "openai") == "openai/gpt-4o");
    assert(canonical("openai/gpt-4o", all, "openai") == "openai/gpt-4o");
    assert(canonical("ollama", all, "openai") == "ollama");
    ProviderConfig work;
    work.defaultModel = "foo";
    all["work"] = work;
    assert(canonical("work", all, "openai") == "work/foo");

    Recents legacy = {version_: 0, models: ["meta-llama/llama-4", "gpt-4o", "together/gpt-4o"]};
    assert(legacy.canonicalize(all, "together"));
    assert(legacy.models == ["together/meta-llama/llama-4", "together/gpt-4o"]);
    assert(!legacy.canonicalize(all, "together"));
    Recents current = {models: ["work/foo"]};
    assert(!current.canonicalize(all, "openai") && current.models == ["work/foo"]);

    Recents r;
    foreach (i; 0 .. 10) r.record(" m" ~ cast(char)('0' + i) ~ " ");
    r.record("m5");
    assert(r.models.length == maxRecents && r.models[0] == "m5" && r.models[1] == "m9");
    r.record("  ");
    assert(r.models[0] == "m5");

    import std.file : tempDir, exists, remove, readText, write;
    import std.path : buildPath;
    auto path = buildPath(tempDir, "nano-recents-test", "recent-models.json");
    save(path, r);
    assert(readText(path).startsWith("{\n  \"version\": 1,\n  \"models\": [\n    \"m5\",\n    \"m9\""));
    assert(load(path) == r);
    write(path, "{\"models\":[\"a\"]}");
    assert(load(path).version_ == 0 && load(path).models == ["a"]);
    write(path, "not json");
    assert(load(path) == Recents.init);
    save(path, Recents.init);
    assert(readText(path) == "{\n  \"version\": 1,\n  \"models\": []\n}");
    remove(path);
    assert(load(path) == Recents.init);
}

private bool startsWith(string s, string p) { return s.length >= p.length && s[0 .. p.length] == p; }
