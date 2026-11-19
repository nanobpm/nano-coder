/// A scripted client for tests: returns queued responses in order and records
/// every request it was given.
module nano.providers.mock;

@safe:

import nano.llm;

class MockClient : LLMClient
{
    LLMResponse[] script;
    Message[][] seen;
    /// The tool names offered with each request.
    string[][] toolsSeen;
    /// The `max_tokens` sent with each request.
    long[] maxTokensSeen;

    this(LLMResponse[] script) { this.script = script; }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        Message[] copy;
        // The recorded copies are only read back by tests.
        foreach (ref m; req.messages) copy ~= imported!"nano.safeio".deepCopy(m);
        seen ~= copy;
        string[] names;
        foreach (ref t; req.tools) names ~= t.name;
        toolsSeen ~= names;
        maxTokensSeen ~= req.maxTokens;
        if (script.length == 0) return LLMResponse("(mock: script exhausted)");
        auto r = script[0];
        script = script[1 .. $];
        // A scripted provider error.
        if (r.content.length > 7 && r.content[0 .. 7] == "!error:") throw new Exception(r.content[7 .. $]);
        // A scripted stream that breaks mid-reply after showing some text.
        if (r.content.length > 6 && r.content[0 .. 6] == "!drop:")
        {
            import nano.http : StreamInterrupted;
            if (sink !is null) sink(false, r.content[6 .. $]);
            throw new StreamInterrupted("mock: connection lost mid-reply");
        }
        if (sink !is null && r.content.length) sink(false, r.content);
        return r;
    }

    string[] listModels() pure { return ["mock"]; }
    string modelName() pure const { return "mock"; }
    string providerName() pure const { return "mock"; }
}
