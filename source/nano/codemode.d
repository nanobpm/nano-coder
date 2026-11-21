/// Codemode spike: run a model-written JavaScript program in an embedded
/// quickjs-ng interpreter. The program calls nano-coder's tools as
/// synchronous functions; only what it returns goes back to the model.
module nano.codemode;

import std.json;
import nano.llm : ToolDefinition;

@safe:

/// Calls a tool by name with JSON arguments; returns its text result or
/// throws (the message becomes a JS exception).
alias Host = string delegate(string name, JSONValue args);

/// The JS prelude: tool functions over the shim's `__host(name, argsJson)`.
/// Each returns the tool's text output; `tool(name, args)` reaches any
/// tool the host allows.
enum string prelude = q{
const tool = (name, args) => JSON.parse(__host(name, JSON.stringify(args ?? {})));
const read_file = (path, opts) => tool("read_file", Object.assign({path}, opts));
const grep = (pattern, opts) => tool("grep", Object.assign({pattern}, opts));
const glob = (pattern, opts) => tool("glob", Object.assign({pattern}, opts));
const bash = (command, opts) => tool("bash", Object.assign({command}, opts));
const history_search = (pattern, opts) => tool("history_search", Object.assign({pattern}, opts));
const print = (...xs) => { __out.push(xs.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ")); };
const console = { log: print };
var __out = [];
};

/// The `run_script` tool offered to the model.
ToolDefinition scriptDefinition() pure
{
    return ToolDefinition("run_script",
        "Run a JavaScript program (QuickJS, ES2023, synchronous) that calls tools as functions, "
        ~ "and get back only what it prints or returns. Use it when a task needs many tool calls, loops, "
        ~ "filtering or aggregation over tool output, so intermediate results stay out of the conversation. "
        ~ "In scope: read_file(path, {offset, limit}), grep(pattern, {path, glob, output_mode, limit}), "
        ~ "glob(pattern, {path, limit}), bash(command, {timeout_seconds}), history_search(pattern, opts), "
        ~ "and tool(name, args) for any other tool; each returns that tool's text output, exactly as a "
        ~ "direct call would, and throws an Error (catchable) when the tool fails or is not allowed. "
        ~ "print(...) / console.log(...) collect lines; the body may `return` a value (JSON-encoded). "
        ~ "No filesystem, network or process access except through these tools. Time limit 120 s.",
        parseJSON(`{"type":"object","properties":{"code":{"type":"string",`
            ~ `"description":"The program body (a function body: it may use return)."}},"required":["code"]}`));
}

/// The result of one script run.
struct ScriptResult
{
    /// The printed lines, then the returned value (JSON) when not undefined.
    string output;
    bool isError;
    /// Host tool calls the script made.
    size_t toolCalls;
}

private alias qjs_host_fn = extern (C) int function(void* ud, const(char)* name, const(char)* args,
    size_t argsLen, char** out_, size_t* outLen) nothrow;

private extern (C) nothrow @nogc
{
    struct qjs_box;
    qjs_box* qjs_new(size_t memLimit, qjs_host_fn host, void* ud);
    void qjs_free(qjs_box* b);
    int qjs_eval(qjs_box* b, const(char)* code, size_t codeLen, long timeoutMs, shared(int)* cancel,
        char** out_, size_t* outLen);
    void qjs_free_str(char* s);
}

private struct HostBox
{
    Host host;
    size_t calls;
}

// Called from C while the interpreter runs on this thread; never lets a D
// exception cross the C frames: errors go back as (1, message).
private extern (C) int hostCall(void* ud, const(char)* name, const(char)* args, size_t argsLen,
    char** out_, size_t* outLen) nothrow @trusted
{
    import core.stdc.stdlib : malloc;
    import core.stdc.string : memcpy, strlen;
    auto box = cast(HostBox*) ud;
    string result;
    int err;
    try
    {
        box.calls++;
        auto n = name[0 .. strlen(name)].idup;
        auto a = parseJSON(args[0 .. argsLen]);
        // Tool results are text: hand them to JS as a JSON string.
        result = JSONValue(box.host(n, a)).toString;
    }
    catch (Exception e)
    {
        result = e.msg;
        err = 1;
    }
    auto p = cast(char*) malloc(result.length + 1);
    if (p is null) return 1;
    memcpy(p, result.ptr, result.length);
    p[result.length] = 0;
    *out_ = p;
    *outLen = result.length;
    return err;
}

/// Run `code` as the body of a function (so it may `return`), with the
/// prelude's tool functions in scope. Bounded by `timeoutMs` wall time and
/// `memLimit` bytes of interpreter heap; `cancel` (when set) stops it.
ScriptResult runScript(string code, Host host, long timeoutMs = 120_000, size_t memLimit = 256 << 20,
    shared(int)* cancel = null) @trusted
{
    import std.format : format;
    auto box = new HostBox(host);
    auto b = qjs_new(memLimit, &hostCall, cast(void*) box);
    if (b is null) return ScriptResult("run_script: could not start the interpreter", true);
    scope (exit) qjs_free(b);
    auto src = prelude ~ "\n(() => {\nconst __r = (() => {\n" ~ code
        ~ "\n})();\nreturn {out: __out, value: __r};\n})()";
    char* out_;
    size_t outLen;
    auto rc = qjs_eval(b, src.ptr, src.length, timeoutMs, cancel, &out_, &outLen);
    scope (exit) qjs_free_str(out_);
    auto text = out_ is null ? "" : out_[0 .. outLen].idup;
    final switch (rc)
    {
        case 0:
            break;
        case 1:
            return ScriptResult("run_script error: " ~ text, true, box.calls);
        case 2:
            return ScriptResult(format("run_script timed out after %s ms", timeoutMs), true, box.calls);
        case 3:
            return ScriptResult("run_script cancelled", true, box.calls);
    }
    string rendered;
    try
    {
        auto j = parseJSON(text);
        foreach (line; j["out"].array) rendered ~= line.str ~ "\n";
        if (auto v = "value" in j)
            rendered ~= v.type == JSONType.string ? v.str : v.toPrettyString;
    }
    catch (Exception e) rendered = text; // not our JSON shape: show the raw result
    return ScriptResult(rendered.length ? rendered : "(no output: return a value or print())", false, box.calls);
}

unittest
{
    auto r = runScript(`return 1 + 2;`, (string n, JSONValue a) => "");
    assert(!r.isError && r.output == "3", r.output);
    auto echoed = runScript(`const t = tool("echo", {x: 1}); print("got", t); return t.length;`,
        (string n, JSONValue a) => n ~ ":" ~ a.toString);
    assert(!echoed.isError && echoed.toolCalls == 1, echoed.output);
    assert(echoed.output == "got echo:{\"x\":1}\n12", echoed.output);
    auto thrown = runScript(`try { tool("x", {}); } catch (e) { return "caught " + e.message; }`,
        delegate string(string n, JSONValue a) { throw new Exception("denied"); });
    assert(thrown.output == "caught denied", thrown.output);
    auto spin = runScript(`for (;;) {}`, (string n, JSONValue a) => "", 200);
    assert(spin.isError && spin.output == "run_script timed out after 200 ms", spin.output);
    auto bad = runScript(`return nope.x;`, (string n, JSONValue a) => "");
    assert(bad.isError && bad.output.length > 0);
}
