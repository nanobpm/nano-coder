/// Sampling temperature (port of `temperature.rs`): a number, or "default" to
/// send none. Set globally, per provider and per model; the most specific
/// wins, and an `extra_body` temperature overrides them all. Models that take
/// no temperature (`drop_params = ["temperature"]`) only use their default.
module nano.temperature;

@safe:

import std.algorithm : canFind;
import std.format : format;
import std.json;
import std.math : isNaN, isFinite;
import nano.config : ProviderConfig, ProviderKind;

/// Highest temperature accepted (OpenAI's range).
enum MAX = 2.0;

enum Source { model, provider, global, extraBody, required }

string label(Source s)
{
    final switch (s)
    {
        case Source.model: return "set for this model";
        case Source.provider: return "set for this provider";
        case Source.global: return "global setting";
        case Source.extraBody: return "from the provider's extra_body";
        case Source.required: return "required: the model accepts no temperature";
    }
}

/// Display a value: NaN is the model default; whole numbers print bare.
string show(double v)
{
    if (isNaN(v)) return "model default";
    return format("%g", v);
}

/// The temperature a model is sent, and why.
struct Resolved
{
    /// NaN sends no `temperature`.
    double effective = double.nan;
    Source source;
    /// Why the model can only use its default.
    string fixed;
    string warning;
    private string extraBodyWarning;

    /// This resolution with the temperature dropped for `reason`.
    Resolved fixedBy(string reason) const
    {
        if (fixed.length) return this;
        Resolved r;
        r.source = Source.required;
        r.fixed = reason;
        if (!isNaN(effective) && (source == Source.model || source == Source.provider || source == Source.extraBody))
        {
            auto ignored = format("temperature %s (%s) is ignored: %s; using the model default", show(effective), label(source), reason);
            r.warning = extraBodyWarning.length ? extraBodyWarning ~ "; " ~ ignored : ignored;
        }
        else r.warning = extraBodyWarning;
        return r;
    }

    string describe() const { return format("%s (%s)", show(effective), label(source)); }
}

/// Why `model` accepts no temperature, if it doesn't.
string fixedReason(ProviderKind kind, const ref ProviderConfig provider, string model)
{
    import nano.config : reasonsOverResponses;
    if (provider.dropParams.canFind("temperature")) return "the provider drops temperature (drop_params)";
    if (reasonsOverResponses(kind, model)) return model ~ " is a reasoning model and rejects a custom temperature";
    return null;
}

/// The temperature for `model` on `provider`: the model's, else the
/// provider's, else `global` (NaN = default); then `extra_body`, the fixed
/// rules, and Anthropic's 0..1 clamp.
Resolved resolve(double global, ProviderKind kind, const ref ProviderConfig provider, string model) @trusted
{
    double chosen;
    Source source;
    auto ms = model in provider.models;
    if (ms !is null && !ms.temperature.isNull) { chosen = ms.temperature.get; source = Source.model; }
    else if (!provider.temperature.isNull) { chosen = provider.temperature.get; source = Source.provider; }
    else { chosen = global; source = Source.global; }
    double effective = chosen;
    string ebWarning;
    if (provider.extraBody.type == JSONType.object)
        if (auto v = "temperature" in provider.extraBody.object)
        {
            double t = double.nan;
            bool num = true;
            if (v.type == JSONType.float_) t = v.floating;
            else if (v.type == JSONType.integer) t = v.integer;
            else if (v.type == JSONType.uinteger) t = v.uinteger;
            else num = false;
            if (num && isFinite(t)) { effective = t; source = Source.extraBody; }
            else if (num) ebWarning = format("extra_body temperature %s is not finite and is ignored; using %s", t, show(chosen));
        }
    Resolved r;
    if (auto reason = fixedReason(kind, provider, model))
    {
        r.source = Source.required;
        r.fixed = reason;
        if (!isNaN(effective) && (source == Source.model || source == Source.provider || source == Source.extraBody))
        {
            auto ignored = format("temperature %s (%s) is ignored: %s; using the model default", show(effective), label(source), reason);
            r.warning = ebWarning.length ? ebWarning ~ "; " ~ ignored : ignored;
        }
        else r.warning = ebWarning;
        return r;
    }
    r.extraBodyWarning = ebWarning;
    r.warning = ebWarning;
    // Anthropic Messages (also Copilot's Claude 4/5 route) takes 0..1.
    import nano.copilot : usesAnthropicMessages;
    auto anthropicMessages = kind == ProviderKind.anthropic
        || (kind == ProviderKind.githubCopilot && usesAnthropicMessages(model));
    if (anthropicMessages && !isNaN(effective))
    {
        string w;
        if (effective > 1) { w = format("temperature %s is above Anthropic's maximum of 1; sending 1", show(effective)); effective = 1; }
        else if (effective < 0) { w = format("temperature %s is below Anthropic's minimum of 0; sending 0", show(effective)); effective = 0; }
        if (w.length) r.warning = r.warning.length ? r.warning ~ "; " ~ w : w;
    }
    r.effective = effective;
    r.source = source;
    return r;
}

@trusted unittest
{
    import std.algorithm : canFind;
    import nano.toml : parseToml;
    ProviderConfig p;
    p.merge(parseToml("temperature = 0.4\n[models.\"m\"]\ntemperature = 0.2\n[models.\"d\"]\ntemperature = \"default\"\n"));
    auto r = resolve(0.9, ProviderKind.openai, p, "m");
    assert(r.effective == 0.2 && r.source == Source.model && r.describe == "0.2 (set for this model)");
    r = resolve(0.9, ProviderKind.openai, p, "other");
    assert(r.effective == 0.4 && r.source == Source.provider);
    r = resolve(0.9, ProviderKind.openai, p, "d");
    assert(isNaN(r.effective) && r.source == Source.model);
    ProviderConfig none;
    assert(resolve(0.9, ProviderKind.openai, none, "x").source == Source.global);
    // Anthropic clamps to 0..1.
    r = resolve(1.5, ProviderKind.anthropic, none, "claude");
    assert(r.effective == 1 && r.warning.canFind("sending 1"));
    // drop_params: only the default; a provider value is reported ignored.
    ProviderConfig d;
    d.merge(parseToml("temperature = 0.3\ndrop_params = [\"temperature\"]\n"));
    r = resolve(0.9, ProviderKind.openai, d, "x");
    assert(isNaN(r.effective) && r.source == Source.required && r.warning.canFind("is ignored"));
    assert(resolve(0.9, ProviderKind.openai, none, "x").fixedBy("thinking").warning is null);
    // extra_body wins.
    ProviderConfig e;
    e.merge(parseToml("[extra_body]\ntemperature = 0.7\n"));
    r = resolve(0.1, ProviderKind.openai, e, "x");
    assert(r.effective == 0.7 && r.source == Source.extraBody);
    r = r.fixedBy("thinking is on");
    assert(isNaN(r.effective) && r.warning.canFind("from the provider's extra_body"));
}

@trusted unittest
{
    ProviderConfig none;
    // Copilot reasoning models take no temperature; Copilot Claude is clamped.
    auto r = resolve(0.5, ProviderKind.githubCopilot, none, "gpt-5");
    assert(isNaN(r.effective) && r.fixed.length);
    auto c = resolve(1.5, ProviderKind.githubCopilot, none, "claude-sonnet-4.5");
    assert(c.effective == 1 && c.warning.length);
    assert(resolve(1.5, ProviderKind.githubCopilot, none, "gpt-4.1").effective == 1.5);
}
