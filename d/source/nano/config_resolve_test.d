/// Resolving a `provider/model` spec (providers/mod.rs tests). D has one
/// path, `resolve`, where Rust also has `validate_spec`; the rows that check
/// the two agree are covered by resolve accepting and refusing the same cases.
module nano.config_resolve_test;
@safe:

version (unittest):

import std.algorithm : canFind, endsWith;
import std.exception : assertThrown, collectExceptionMsg;
import nano.config;

private:

Config withProvider(string name, ProviderConfig p)
{
    Config c;
    c.providers = presets();
    c.providers[name] = p;
    return c;
}

ProviderConfig openai(string url)
{
    ProviderConfig p;
    p.kind = ProviderKind.openai;
    p.hasKind = true;
    p.defaultModel = "m";
    p.baseUrl = url;
    return p;
}

// rust: providers/mod.rs::api_key_command_supplies_key
unittest
{
    auto p = openai("http://localhost:9/v1");
    p.apiKeyCommand = `printf '  sk-from-cmd\n'`;
    auto c = withProvider("cmd", p);
    assert(resolve(c, "cmd/m").apiKey == "sk-from-cmd");
}

// rust: providers/mod.rs::the_qwen_preset_is_derived_from_the_endpoint_table
unittest
{
    import qwen = nano.qwen;
    auto preset = presets()["qwen"];
    assert(preset.baseUrl == qwen.defaultEndpoint.baseUrl && preset.apiKeyEnv == qwen.defaultEndpoint.apiKeyEnv);
    foreach (ref e; qwen.endpoints)
    {
        assert(*qwen.endpointForUrl(e.baseUrl) == e);
        assert(e.apiKeyEnv.endsWith("_API_KEY"), e.apiKeyEnv);
    }
}

// rust: providers/mod.rs::validate_spec_matches_resolve_for_the_buildable_cases
unittest
{
    Config c;
    c.providers = presets();
    resolve(c, "mock/anything");
    auto broken = openai(null);
    auto bc = withProvider("broken", broken);
    auto msg = collectExceptionMsg(resolve(bc, "broken/x"));
    assert(msg.canFind("base_url"), msg);
}

// rust: providers/mod.rs::validate_spec_rejects_an_empty_or_malformed_base_url
unittest
{
    foreach (url; ["   ", "not a url", "ftp://host/v1", "http://", " http://host/v1", "http://host/v1\n",
        "http://ho\tst/v1", "http://host/v1\x01", "https://host/v1?token=x", "https://host/v1#frag"])
    {
        auto bad = withProvider("bad", openai(url));
        assertThrown(resolve(bad, "bad/x"), url);
    }
    auto good = withProvider("good", openai("http://localhost:9/v1"));
    assert(resolve(good, "good/x").config.baseUrl == "http://localhost:9/v1");
}
