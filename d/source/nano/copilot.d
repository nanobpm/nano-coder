/// GitHub Copilot model routing (from `providers/github_copilot.rs`): which
/// upstream API a model is served through, and which models reason.
module nano.copilot;

@safe:

import std.algorithm : startsWith, any;
import std.ascii : isDigit;

/// The Copilot upstream API a model must be called through: the wrong one
/// fails with `unsupported_api_for_model` rather than falling back.
enum CopilotApi { completions, responses, messages }

string path(CopilotApi api) pure nothrow
{
    final switch (api)
    {
        case CopilotApi.completions: return "/chat/completions";
        case CopilotApi.responses: return "/responses";
        case CopilotApi.messages: return "/v1/messages";
    }
}

/// The leading integer of a version tail (`"5.6"` → 5); -1 when none.
private long leadingMajor(string tail) pure
{
    import std.conv : to;
    size_t n;
    while (n < tail.length && tail[n].isDigit) n++;
    return n && n < 10 ? tail[0 .. n].to!long : -1;
}

/// Claude 4.x/5.x (`claude-(haiku|sonnet|opus|fable)-[45]` then `.`, `-` or end).
bool usesAnthropicMessages(string model) pure
{
    foreach (family; ["claude-haiku-", "claude-sonnet-", "claude-opus-", "claude-fable-"])
        if (model.startsWith(family))
        {
            auto rest = model[family.length .. $];
            if (rest.length && (rest[0] == '4' || rest[0] == '5') && (rest.length == 1 || rest[1] == '.' || rest[1] == '-'))
                return true;
        }
    return false;
}

/// Claude 4/5 → Messages; GPT before 5 → Chat Completions; newer GPT, Grok,
/// OSWE and MAI → Responses; anything else → Chat Completions.
CopilotApi apiForModel(string model) pure
{
    if (usesAnthropicMessages(model)) return CopilotApi.messages;
    if (model.startsWith("gpt-"))
    {
        auto major = leadingMajor(model[4 .. $]);
        if (major >= 0 && major < 5) return CopilotApi.completions;
    }
    if (["gpt-", "grok-", "oswe", "mai-"].any!(p => model.startsWith(p))) return CopilotApi.responses;
    return CopilotApi.completions;
}

/// Responses-routed models reason: they need reasoning items replayed and
/// reject a non-default temperature. GPT-5 and later, Grok, OSWE, MAI.
bool isReasoningModel(string model) pure
{
    if (apiForModel(model) != CopilotApi.responses) return false;
    if (model.startsWith("gpt-")) return leadingMajor(model[4 .. $]) >= 5;
    return true;
}

unittest
{
    assert(apiForModel("claude-sonnet-4.5") == CopilotApi.messages);
    assert(apiForModel("claude-opus-4-1") == CopilotApi.messages);
    assert(apiForModel("claude-sonnet-42") == CopilotApi.completions);
    assert(apiForModel("claude-3.5-sonnet") == CopilotApi.completions);
    assert(apiForModel("gpt-4.1") == CopilotApi.completions);
    assert(apiForModel("gpt-4o") == CopilotApi.completions);
    assert(apiForModel("gpt-5-mini") == CopilotApi.responses);
    assert(apiForModel("gpt-6-astra") == CopilotApi.responses);
    assert(apiForModel("grok-code-fast-1") == CopilotApi.responses);
    assert(apiForModel("o4-mini") == CopilotApi.completions);
    assert(isReasoningModel("gpt-5") && isReasoningModel("grok-code-fast-1"));
    assert(!isReasoningModel("gpt-4.1") && !isReasoningModel("o4-mini") && !isReasoningModel("claude-sonnet-4.5"));
}
