/// Whether the model can view images (port of `vision.rs`): a configured
/// `vision` (model, then provider, then global) wins; otherwise what the
/// endpoint reports (Copilot `/models`, Ollama `/api/show`, llama.cpp
/// `/props`); otherwise direct OpenAI/Anthropic endpoints are assumed capable
/// for known vision families.
module nano.vision;

@safe:

import std.algorithm : canFind, any;
import std.json;
import std.string : toLower, startsWith, indexOf, lastIndexOf;
import std.typecons : Nullable;
import nano.config : ProviderConfig, ProviderKind;
import nano.thinking : objGet;

/// Default image byte cap (Rust `attachment::DEFAULT_MAX_BYTES`).
enum size_t DEFAULT_MAX_BYTES = 5 * 1024 * 1024;

struct Vision
{
    size_t maxImages = 1;
    size_t maxImageBytes = DEFAULT_MAX_BYTES;
    string[] mediaTypes;

    static Vision capable() { return Vision.init; }

    static Nullable!Vision fromModelEntry(const JSONValue entry) @trusted
    {
        Nullable!Vision none;
        auto caps = objGet(entry, "capabilities");
        auto supports = caps is null ? null : objGet(*caps, "supports");
        if (supports is null) return none;
        auto v = objGet(*supports, "vision");
        if (v is null || v.type != JSONType.true_) return none;
        auto limits = objGet(*caps, "limits");
        auto lv = limits is null ? null : objGet(*limits, "vision");
        Vision out_;
        if (lv !is null)
        {
            if (auto m = objGet(*lv, "max_prompt_images"))
                if (m.type == JSONType.integer || m.type == JSONType.uinteger)
                {
                    if (m.integer == 0) return none;
                    out_.maxImages = cast(size_t) m.integer;
                }
            if (auto m = objGet(*lv, "max_prompt_image_size"))
                if ((m.type == JSONType.integer || m.type == JSONType.uinteger) && m.integer > 0)
                    out_.maxImageBytes = cast(size_t) m.integer;
            if (auto m = objGet(*lv, "supported_media_types"))
                if (m.type == JSONType.array)
                    foreach (t; m.array) if (t.type == JSONType.string) out_.mediaTypes ~= t.str;
        }
        return Nullable!Vision(out_);
    }

    static Nullable!Vision fromOllamaShow(const JSONValue show) @trusted
    {
        auto caps = objGet(show, "capabilities");
        if (caps !is null && caps.type == JSONType.array)
            foreach (c; caps.array) if (c.type == JSONType.string && c.str == "vision") return Nullable!Vision(capable);
        return Nullable!Vision.init;
    }

    static Nullable!Vision fromLlamacppProps(const JSONValue props) @trusted
    {
        auto m = objGet(props, "modalities");
        auto v = m is null ? null : objGet(*m, "vision");
        return v !is null && v.type == JSONType.true_ ? Nullable!Vision(capable) : Nullable!Vision.init;
    }
}

enum Source { model, provider, global, detected }

private Vision copy(const Vision v) { return Vision(v.maxImages, v.maxImageBytes, v.mediaTypes.dup); }

/// The configured override (model, provider, global) and where it came from.
Nullable!bool configuredOverride(Nullable!bool global, const ref ProviderConfig provider, string model, out Source source) @trusted
{
    if (auto ms = model in provider.models)
        if (!ms.vision.isNull) { source = Source.model; return Nullable!bool(ms.vision.get); }
    if (!provider.vision.isNull) { source = Source.provider; return Nullable!bool(provider.vision.get); }
    if (!global.isNull) { source = Source.global; return global; }
    source = Source.detected;
    return Nullable!bool.init;
}

Nullable!Vision resolve(Nullable!bool global, ProviderKind kind, const ref ProviderConfig provider, string model,
    const(Vision)* reported = null)
{
    Source s;
    auto o = configuredOverride(global, provider, model, s);
    if (!o.isNull)
    {
        if (!o.get) return Nullable!Vision.init;
        return Nullable!Vision(reported !is null ? copy(*reported) : Vision.capable);
    }
    if (reported !is null) return Nullable!Vision(copy(*reported));
    if (kind == ProviderKind.anthropic && hostIs(provider.baseUrl, "api.anthropic.com") && assumesAnthropicVision(model))
        return Nullable!Vision(Vision.capable);
    if (kind == ProviderKind.openai && hostIs(provider.baseUrl, "api.openai.com") && assumesOpenaiVision(model))
        return Nullable!Vision(Vision.capable);
    return Nullable!Vision.init;
}

/// The lower-cased host of `url`.
string baseUrlHost(string url)
{
    auto at = url.indexOf("://");
    auto rest = at >= 0 ? url[at + 3 .. $] : url;
    size_t end = rest.length;
    foreach (i, c; rest) if (c == '/' || c == '?' || c == '#') { end = i; break; }
    auto auth = rest[0 .. end];
    auto atSign = auth.lastIndexOf('@');
    if (atSign >= 0) auth = auth[atSign + 1 .. $];
    auto colon = auth.lastIndexOf(':');
    if (colon >= 0) auth = auth[0 .. colon];
    return auth.toLower;
}

private bool hostIs(string url, string domain)
{
    auto h = baseUrlHost(url);
    return h == domain || (h.length > domain.length && h.endsWith("." ~ domain));
}

private bool endsWith(string s, string t) { return s.length >= t.length && s[$ - t.length .. $] == t; }

private string baseModel(string model)
{
    auto m = model.toLower;
    if (m.startsWith("ft:"))
    {
        m = m[3 .. $];
        auto c = m.indexOf(':');
        if (c >= 0) m = m[0 .. c];
    }
    return m;
}

private bool familyMatch(string base, string family)
{
    if (!base.startsWith(family)) return false;
    auto rest = base[family.length .. $];
    return rest.length == 0 || rest[0] == '-' || rest[0] == '.';
}

bool assumesAnthropicVision(string model)
{
    auto b = baseModel(model);
    return !familyMatch(b, "claude-2") && !familyMatch(b, "claude-instant");
}

bool assumesOpenaiVision(string model)
{
    auto b = baseModel(model);
    foreach (t; ["o3-mini", "o1-mini", "o1-preview"])
        if (b == t || b.startsWith(t ~ "-")) return false;
    foreach (f; ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4", "o1"])
        if (familyMatch(b, f)) return true;
    return false;
}

unittest
{
    import std.json : parseJSON;
    auto v = Vision.fromModelEntry(parseJSON(`{"capabilities":{"supports":{"vision":true},"limits":{"vision":{"max_prompt_images":5,"max_prompt_image_size":3145728,"supported_media_types":["image/png"]}}}}`));
    assert(!v.isNull && v.get.maxImages == 5 && v.get.maxImageBytes == 3145728 && v.get.mediaTypes == ["image/png"]);
    assert(Vision.fromModelEntry(parseJSON(`{"capabilities":{"supports":{"vision":true},"limits":{"vision":{"max_prompt_images":0}}}}`)).isNull);
    assert(!Vision.fromOllamaShow(parseJSON(`{"capabilities":["vision"]}`)).isNull);
    assert(!Vision.fromLlamacppProps(parseJSON(`{"modalities":{"vision":true}}`)).isNull);
    ProviderConfig openai;
    openai.baseUrl = "https://api.openai.com/v1";
    Nullable!bool unset;
    assert(!resolve(unset, ProviderKind.openai, openai, "gpt-4o").isNull);
    assert(resolve(unset, ProviderKind.openai, openai, "o3-mini").isNull);
    assert(resolve(unset, ProviderKind.openai, openai, "gpt-3.5-turbo").isNull);
    ProviderConfig other;
    other.baseUrl = "https://openrouter.ai/api/v1";
    assert(resolve(unset, ProviderKind.openai, other, "gpt-4o").isNull);
    assert(!resolve(Nullable!bool(true), ProviderKind.openai, other, "gpt-4o").isNull);
    ProviderConfig anth;
    anth.baseUrl = "https://api.anthropic.com/v1";
    assert(!resolve(unset, ProviderKind.anthropic, anth, "claude-sonnet-4-5").isNull);
    assert(resolve(unset, ProviderKind.anthropic, anth, "claude-2.1").isNull);
    assert(baseUrlHost("http://user@Host.example:8080/x") == "host.example");
}
