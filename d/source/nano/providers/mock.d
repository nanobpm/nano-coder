/// A scripted client for tests: returns queued responses in order and records
/// every request it was given.
module nano.providers.mock;

import nano.llm;

class MockClient : LLMClient
{
    LLMResponse[] script;
    Message[][] seen;

    this(LLMResponse[] script) { this.script = script; }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        Message[] copy;
        foreach (m; req.messages) copy ~= cast(Message) m;
        seen ~= copy;
        if (script.length == 0) return LLMResponse("(mock: script exhausted)");
        auto r = script[0];
        script = script[1 .. $];
        if (sink !is null && r.content.length) sink(false, r.content);
        return r;
    }

    string[] listModels() { return ["mock"]; }
    string modelName() const { return "mock"; }
    string providerName() const { return "mock"; }
}
