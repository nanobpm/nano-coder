/// Ported temperature.rs tests: precedence, provider ranges, fixed models,
/// stale warnings and config parsing.
module nano.temperature_test;

@safe:

import std.algorithm : canFind;
import std.math : isNaN;
import nano.config : ProviderConfig, ProviderKind, Config, numberOrDefault;
import nano.temperature;
import nano.toml : parseToml;
import nano.result : unwrap;

private ProviderConfig provider(string toml)
{
    ProviderConfig p;
    p.merge(parseToml(toml).unwrap("valid TOML"));
    return p;
}

/// `resolve` for a provider given as TOML.
private Resolved res(double global, ProviderKind kind, string toml, string model)
{
    auto p = provider(toml);
    return resolve(global, kind, p, model);
}

// rust: temperature.rs::anthropic_range_is_checked
// rust: temperature.rs::copilot_claude_uses_the_anthropic_range
unittest
{
    ProviderConfig none;
    auto r = res(0.7, ProviderKind.anthropic, ("temperature = 1.5\n"), "claude");
    assert(r.effective == 1 && r.warning.canFind("Anthropic's maximum"));
    r = res(0.7, ProviderKind.anthropic, ("temperature = -0.5\n"), "claude");
    assert(r.effective == 0 && r.warning.canFind("Anthropic's minimum"));
    r = resolve(0.7, ProviderKind.anthropic, none, "claude");
    assert(r.effective == 0.7 && r.warning is null);

    r = res(0.7, ProviderKind.githubCopilot, ("temperature = 1.5\n"), "claude-sonnet-4.5");
    assert(r.effective == 1 && r.warning.canFind("Anthropic's maximum"));
    r = res(0.7, ProviderKind.githubCopilot, ("temperature = -0.5\n"), "claude-opus-5");
    assert(r.effective == 0 && r.warning.canFind("Anthropic's minimum"));
    r = resolve(0.7, ProviderKind.githubCopilot, none, "claude-haiku-4.5");
    assert(r.effective == 0.7 && r.warning is null);
    // Non-Messages Copilot models keep the wider OpenAI range.
    foreach (m; ["gpt-4.1", "claude-sonnet-3.5"])
    {
        r = res(0.7, ProviderKind.githubCopilot, ("temperature = 1.5\n"), m);
        assert(r.effective == 1.5 && r.warning is null, m);
    }
}

// rust: temperature.rs::fixed_by_clears_the_stale_range_warning
unittest
{
    enum why = "thinking is on, and Anthropic then requires the default temperature";
    ProviderConfig none;
    auto r = resolve(1.5, ProviderKind.anthropic, none, "claude-sonnet-4-6");
    assert(r.effective == 1 && r.warning.canFind("sending 1"));
    r = r.fixedBy(why);
    assert(isNaN(r.effective) && r.warning is null, "nothing is sent, so the clamp warning is stale");

    r = res(0.7, ProviderKind.anthropic, ("temperature = 1.5\n"), "claude-sonnet-4-6").fixedBy(why);
    assert(isNaN(r.effective));
    assert(r.warning.canFind("ignored") && r.warning.canFind("temperature 1 ") && !r.warning.canFind("sending 1"), r.warning);

    r = res(1.5, ProviderKind.anthropic, ("extra_body = { temperature = nan }\n"), "claude-sonnet-4-6");
    assert(r.warning.canFind("not finite") && r.warning.canFind("sending 1"), r.warning);
    r = r.fixedBy(why);
    assert(isNaN(r.effective) && r.warning.canFind("not finite") && !r.warning.canFind("sending 1"), r.warning);

    r = res(0.7, ProviderKind.anthropic, ("temperature = 0.5\nextra_body = { temperature = nan }\n"),
        "claude-sonnet-4-6").fixedBy(why);
    assert(isNaN(r.effective) && r.warning.canFind("not finite") && r.warning.canFind("0.5") && r.warning.canFind("ignored"), r.warning);
}

// rust: temperature.rs::models_without_temperature_only_use_the_default
unittest
{
    ProviderConfig none;
    auto r = resolve(0.7, ProviderKind.githubCopilot, none, "gpt-5");
    assert(isNaN(r.effective) && r.source == Source.required && r.fixed.canFind("reasoning model") && r.warning is null);
    assert(resolve(0.7, ProviderKind.githubCopilot, none, "gpt-4.1").effective == 0.7);

    r = res(0.7, ProviderKind.openai, ("drop_params = [\"temperature\"]\n[models.\"k3\"]\ntemperature = 0.3\n"), "k3");
    assert(isNaN(r.effective) && r.warning.canFind("0.3") && r.warning.canFind("drop_params"), r.warning);
    assert(res(0.7, ProviderKind.openai, ("drop_params = [\"temperature\"]\ntemperature = \"default\"\n"), "k3").warning is null);
    r = res(0.7, ProviderKind.openai, ("drop_params = [\"temperature\"]\nextra_body = { temperature = nan }\n"), "k3");
    assert(isNaN(r.effective) && r.source == Source.required && r.warning.canFind("not finite"), r.warning);
    r = res(0.7, ProviderKind.openai, ("temperature = 0.5\ndrop_params = [\"temperature\"]\nextra_body = { temperature = nan }\n"), "k3");
    assert(r.source == Source.required && r.warning.canFind("not finite") && r.warning.canFind("0.5") && r.warning.canFind("ignored"), r.warning);
}

// rust: temperature.rs::most_specific_setting_wins
unittest
{
    auto p = provider("temperature = 0.4\n[models.\"big\"]\ntemperature = \"default\"\n");
    auto r = resolve(0.7, ProviderKind.openai, p, "big");
    assert(isNaN(r.effective) && r.source == Source.model);
    r = resolve(0.7, ProviderKind.openai, p, "small");
    assert(r.effective == 0.4 && r.source == Source.provider);
    ProviderConfig none;
    r = resolve(0.7, ProviderKind.openai, none, "small");
    assert(r.effective == 0.7 && r.source == Source.global && r.describe == "0.7 (global setting)" && r.warning is null);
    r = res(0.7, ProviderKind.openai, ("temperature = 0.4\nextra_body = { temperature = 0.1 }\n"), "m");
    assert(r.effective == 0.1 && r.source == Source.extraBody);
    foreach (t; ["nan", "inf", "-inf"])
    {
        r = res(0.7, ProviderKind.openai, ("temperature = 0.4\nextra_body = { temperature = " ~ t ~ " }\n"), "m");
        assert(r.effective == 0.4 && r.source == Source.provider && r.warning.canFind("not finite"), t);
    }
}

// rust: temperature.rs::parses_numbers_and_default
// rust: temperature.rs::rejects_non_finite_values
unittest
{
    import std.exception : collectExceptionMsg;
    assert(numberOrDefault(parseToml("temperature = 1").unwrap("valid TOML")["temperature"]) == 1);
    assert(numberOrDefault(parseToml("temperature = 0.2").unwrap("valid TOML")["temperature"]) == 0.2);
    assert(isNaN(numberOrDefault(parseToml("temperature = \"default\"").unwrap("valid TOML")["temperature"])));
    assert(collectExceptionMsg(numberOrDefault(parseToml("temperature = \"warm\"").unwrap("valid TOML")["temperature"])).canFind("number or \"default\""));
    foreach (t; ["nan", "inf", "-inf"])
        assert(collectExceptionMsg(numberOrDefault(parseToml("temperature = " ~ t).unwrap("valid TOML")["temperature"])) == "temperature must be finite", t);
    // A provider-level non-finite value is rejected the same way.
    assert(collectExceptionMsg(provider("temperature = nan\n")) == "temperature must be finite");
    // "default" round-trips through the config file.
    import nano.settings : applyChanges, Changes;
    Config c;
    c.temperature = double.nan;
    Changes ch;
    ch.temperature = true;
    assert(applyChanges("", c, ch, null).canFind("temperature = \"default\""));
}

// rust: temperature.rs::user_model_settings_merge_over_presets
unittest
{
    auto merged = provider("temperature = 0.2\n[models.\"a\"]\ntemperature = 0.1\n");
    merged.merge(parseToml("[models.\"b\"]\ntemperature = \"default\"\n").unwrap("valid TOML"));
    assert(merged.temperature.get == 0.2);
    assert(merged.models["a"].temperature.get == 0.1);
    assert(isNaN(merged.models["b"].temperature.get));
}
