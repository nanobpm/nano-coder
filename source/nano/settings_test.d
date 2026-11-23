/// /settings helpers: key status, the Qwen endpoint picker, model steps,
/// rebuild resolution and save notices (settings.rs tests).
module nano.settings_test;
@safe:

version (unittest):

import std.algorithm : canFind, count, endsWith, any;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import nano.config : Config, ProviderConfig, ProviderKind, parseModelSpec;
import nano.qwen : QwenEndpoint, QwenPlan, endpoints, defaultEndpoint, label;
import nano.settings;
import nano.ui : keyStatus;

private string scratch(string name)
{
    auto d = buildPath(tempDir, "nano-d-settings-" ~ name);
    if (d.exists) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

// rust: settings.rs::key_status_reports_no_key_for_a_non_login_provider_without_credentials
unittest
{
    auto none = scratch("nologin");
    scope (exit) rmdirRecurse(none);
    ProviderConfig openai;
    openai.hasKind = true;
    openai.kind = ProviderKind.openai;
    assert(keyStatus(openai, none) == "no key");
}

private immutable(QwenEndpoint) planEndpoint(QwenPlan plan)
{
    foreach (e; endpoints) if (e.plan == plan) return e;
    assert(0);
}

// rust: settings.rs::applying_an_endpoint_never_introduces_a_variable_that_would_shadow_a_command
// rust: settings.rs::applying_an_endpoint_retargets_the_api_key_variable_to_its_plan
// rust: settings.rs::applying_an_endpoint_seeds_the_key_prompt_with_the_plan_variable
unittest
{
    auto token = planEndpoint(QwenPlan.tokenPlan), coding = planEndpoint(QwenPlan.codingPlan);

    ProviderConfig command;
    command.apiKeyCommand = "op read op://x";
    applyQwenEndpoint(command, token);
    assert(command.apiKeyCommand == "op read op://x" && command.apiKeyEnv is null && command.baseUrl == token.baseUrl);
    ProviderConfig cleared;
    cleared.apiKeyCommand = "op read op://x";
    cleared.apiKeyEnv = "";
    cleared.apiKeyEnvSet = true;
    applyQwenEndpoint(cleared, token);
    assert(cleared.apiKeyEnv == "" && cleared.apiKeyEnvSet, "a cleared variable stays cleared");

    ProviderConfig std_;
    std_.apiKeyEnv = "DASHSCOPE_API_KEY";
    applyQwenEndpoint(std_, token);
    assert(std_.baseUrl == token.baseUrl && std_.apiKeyEnv == "BAILIAN_TOKEN_PLAN_API_KEY");
    applyQwenEndpoint(std_, coding);
    assert(std_.apiKeyEnv == "BAILIAN_CODING_PLAN_API_KEY", "a second switch moves it again");
    ProviderConfig literal;
    literal.apiKey = "sk-sp-x";
    applyQwenEndpoint(literal, coding);
    assert(literal.apiKey == "sk-sp-x" && literal.apiKeyEnv is null);
    ProviderConfig custom;
    custom.apiKeyEnv = "MY_QWEN_KEY";
    applyQwenEndpoint(custom, token);
    assert(custom.apiKeyEnv == "MY_QWEN_KEY" && custom.baseUrl == token.baseUrl);
    ProviderConfig customLiteral;
    customLiteral.apiKey = "sk-sp-y";
    customLiteral.apiKeyEnv = "MY_QWEN_KEY";
    applyQwenEndpoint(customLiteral, coding);
    assert(customLiteral.apiKeyEnv == "MY_QWEN_KEY" && customLiteral.apiKey == "sk-sp-y");

    // The key prompt is seeded from the chosen plan, with nothing planted.
    ProviderConfig fresh;
    fresh.baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
    applyQwenEndpoint(fresh, token);
    assert(fresh.apiKeyEnv is null, "nothing is planted into the config");
    assert(suggestedKeyEnv(fresh, &token, "myprovider") == "BAILIAN_TOKEN_PLAN_API_KEY");
    assert(suggestedKeyEnv(fresh, null, "my-provider") == "MY_PROVIDER_API_KEY");
}

// rust: settings.rs::qwen_endpoint_pick_maps_rows_to_actions
// rust: settings.rs::qwen_endpoint_rows_offer_every_plan_region_plus_custom_and_keep
unittest
{
    auto rows = qwenEndpointRows(defaultEndpoint.baseUrl);
    assert(qwenEndpointPick(-1, rows).choice == QwenChoice.keep, "Esc keeps the endpoint");
    auto first = qwenEndpointPick(0, rows);
    assert(first.choice == QwenChoice.known && first.endpoint.baseUrl == defaultEndpoint.baseUrl);
    size_t customAt;
    foreach (i, r; rows) if (r.choice == QwenChoice.custom) customAt = i;
    assert(qwenEndpointPick(customAt, rows).choice == QwenChoice.custom);
    assert(qwenEndpointPick(rows.length - 1, rows).choice == QwenChoice.keep);
    assert(qwenEndpointPick(999, rows).choice == QwenChoice.keep, "a stale index never fails");

    assert(rows[0].label.endsWith("(current)"), rows[0].label);
    assert(rows.count!(r => r.choice == QwenChoice.known) == endpoints.length, "every endpoint offered once");
    assert(rows[$ - 1].choice == QwenChoice.keep);
    foreach (plan; [QwenPlan.standard, QwenPlan.tokenPlan, QwenPlan.codingPlan])
        assert(rows.any!(r => r.label.canFind(plan.label)), plan.label);
    auto gateway = qwenEndpointRows("https://my-gateway.example.com/v1");
    assert(gateway.count!(r => r.choice == QwenChoice.known) == endpoints.length);
    assert(gateway[$ - 1].label.canFind("https://my-gateway.example.com/v1"));
}

// rust: settings.rs::the_picker_is_offered_for_qwen_providers_only
unittest
{
    ProviderConfig p;
    assert(isQwenProvider("qwen", p), "the named preset always qualifies");
    p.baseUrl = defaultEndpoint.baseUrl;
    assert(isQwenProvider("my-dashscope", p));
    p.baseUrl = "https://abc123.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1";
    assert(isQwenProvider("my-workspace", p), "a Model Studio workspace host qualifies");
    p.baseUrl = "https://api.openai.com/v1";
    assert(!isQwenProvider("work", p));
    ProviderConfig blank;
    assert(!isQwenProvider("work", blank));
}

// rust: settings.rs::model_choice_maps_rows_to_steps
// rust: settings.rs::model_spec_builds_provider_slash_model_or_goes_back
unittest
{
    auto models = ["alpha", "beta"];
    assert(modelChoice(-1, models).back, "Esc steps back");
    assert(modelChoice(0, models) == ModelStep(false, "alpha"));
    assert(modelChoice(1, models) == ModelStep(false, "beta"));
    assert(modelChoice(2, models) == ModelStep(false, ""), "Other prompts for an ID");
    assert(modelChoice(3, models).back, "Back to providers");
    assert(modelSpec("work", "llama3") == ModelStep(false, "work/llama3"));
    assert(modelSpec("work", "  qwen3  ") == ModelStep(false, "work/qwen3"), "IDs are trimmed");
    assert(modelSpec("work", "").back && modelSpec("work", "   ").back);
}

// rust: settings.rs::edited_provider_resolution_detects_a_spec_that_newly_resolves_to_it
unittest
{
    Config c;
    c.model = "work/foo";
    c.defaultProvider = "anthropic";
    c.providers["anthropic"] = ProviderConfig.init;
    c.providers["openai"] = ProviderConfig.init;
    assert(!editRebuilds(c, "work", "anthropic"), "work doesn't exist yet");
    c.providers["work"] = ProviderConfig.init;
    assert(editRebuilds(c, "work", "anthropic"), "the spec now resolves to the edited provider");
    assert(editRebuilds(c, "anthropic", "anthropic"), "the client's own provider");
    assert(!editRebuilds(c, "openai", "anthropic"));
}

// rust: settings.rs::edited_provider_resolution_uses_the_effective_provider_table
unittest // legacy top-level credentials flip a mock default to openai at load
{
    auto d = scratch("legacy");
    scope (exit) rmdirRecurse(d);
    auto path = buildPath(d, "config.toml");
    write(path, "api_key = \"sk-test\"\nmodel = \"some-model\"\n");
    auto c = Config.load(path);
    assert(c.defaultProvider == "openai", c.defaultProvider);
    assert(editRebuilds(c, "openai", "openai") && !editRebuilds(c, "mock", "openai"));
}

// rust: settings.rs::a_successful_save_clears_an_earlier_save_failure_notice
unittest
{
    auto d = scratch("save");
    scope (exit) rmdirRecurse(d);
    auto path = buildPath(d, "config.toml");
    Config c;
    Changes ch;
    ch.model = true;
    save(c, ch, null, path);
    assert(path.exists, "the save wrote the config");
    auto left = clearSaveFailures(["Could not save settings: earlier disk error", "Model set to x"]);
    assert(left == ["Model set to x"], "a resolved save failure is dropped");
}
