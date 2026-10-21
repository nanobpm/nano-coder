/// A scripted client for tests: returns queued responses in order and records
/// every request it was given.
module nano.providers.mock;

import nano.llm;

class MockClient : LLMClient
{
    LLMResponse[] script;
    Message[][] seen;
    /// The tool names offered with each request.
    string[][] toolsSeen;

    this(LLMResponse[] script) { this.script = script; }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        Message[] copy;
        foreach (m; req.messages) copy ~= cast(Message) m;
        seen ~= copy;
        string[] names;
        foreach (ref t; req.tools) names ~= t.name;
        toolsSeen ~= names;
        if (script.length == 0) return LLMResponse("(mock: script exhausted)");
        auto r = script[0];
        script = script[1 .. $];
        // A scripted provider error.
        if (r.content.length > 7 && r.content[0 .. 7] == "!error:") throw new Exception(r.content[7 .. $]);
        if (sink !is null && r.content.length) sink(false, r.content);
        return r;
    }

    string[] listModels() { return ["mock"]; }
    string modelName() const { return "mock"; }
    string providerName() const { return "mock"; }
}
