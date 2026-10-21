/// The `report_outcome` tool: the model's explicit "done", "blocked" or
/// "needs input" signal, so an orchestrator need not guess from the stop
/// reason. Port of `goal.rs`.
///
/// Reporting an outcome ends the turn: the summary becomes the final answer
/// and the outcome is recorded at the turn's end (ACP `_meta.outcome`).
module nano.goal;

@safe:

import std.json;
import std.string : strip, toLower;
import std.array : replace;
import std.format : format;
import nano.llm : Message, Role, ToolDefinition;

enum toolName = "report_outcome";

enum OutcomeStatus { completed, blocked, needsInput }

/// Parse a status leniently (Rust `Status::parse`); false when unknown.
bool parseStatus(string text, out OutcomeStatus s)
{
    switch (text.strip.toLower.replace("-", "_").replace(" ", "_"))
    {
        case "completed", "complete", "done", "success", "succeeded": s = OutcomeStatus.completed; return true;
        case "blocked", "stuck", "failed", "failure", "needs_help": s = OutcomeStatus.blocked; return true;
        case "needs_input", "question", "ask", "clarify", "needs_decision": s = OutcomeStatus.needsInput; return true;
        default: return false;
    }
}

string statusName(OutcomeStatus s)
{
    final switch (s)
    {
        case OutcomeStatus.completed: return "completed";
        case OutcomeStatus.blocked: return "blocked";
        case OutcomeStatus.needsInput: return "needs_input";
    }
}

class OutcomeError : Exception
{
    this(string msg) { super(msg); }
}

struct Outcome
{
    OutcomeStatus status;
    string summary;

    /// Parse the tool's arguments, tolerating arguments sent as a JSON string.
    static Outcome fromArgs(JSONValue args) @trusted
    {
        if (args.type == JSONType.string)
        {
            try args = parseJSON(args.str);
            catch (Exception) args = JSONValue(null);
        }
        auto st = args.type == JSONType.object ? "status" in args.object : null;
        if (st is null || st.type != JSONType.string)
            throw new OutcomeError(`report_outcome needs ` ~ "`status`" ~ `: "completed", "blocked" or "needs_input"`);
        Outcome o;
        if (!parseStatus(st.str, o.status))
            throw new OutcomeError(format!`report_outcome %sstatus%s must be "completed", "blocked" or "needs_input", got %s`(
                "`", "`", JSONValue(st.str).toString));
        auto sm = "summary" in args.object;
        o.summary = sm !is null && sm.type == JSONType.string ? sm.str.strip : "";
        if (!o.summary.length) throw new OutcomeError("report_outcome needs a `summary`");
        return o;
    }

    /// The turn's final answer.
    string response() const
    {
        final switch (status)
        {
            case OutcomeStatus.completed: return summary;
            case OutcomeStatus.blocked: return "Blocked: " ~ summary;
            case OutcomeStatus.needsInput: return "Question: " ~ summary;
        }
    }

    JSONValue toJSON() const
    {
        return JSONValue(["status": statusName(status), "summary": summary]);
    }

    /// The latest successful `report_outcome` call among one turn's messages.
    static bool reportedIn(const Message[] messages, out Outcome found) @trusted
    {
        bool succeeded(string id)
        {
            foreach (ref m; messages)
                if (m.role == Role.tool && m.toolCallId == id && !m.isError) return true;
            return false;
        }
        foreach_reverse (ref m; messages)
        {
            if (m.role != Role.assistant) continue;
            foreach_reverse (ref c; m.toolCalls)
            {
                if (c.name != toolName || !succeeded(c.id)) continue;
                try
                {
                    found = fromArgs(c.arguments);
                    return true;
                }
                catch (OutcomeError) {}
            }
        }
        return false;
    }
}

ToolDefinition definition() @trusted
{
    return ToolDefinition(toolName,
        "Report the outcome of the task you were given. This ends your turn: the summary becomes your final "
        ~ "answer. Use status \"completed\" only when the whole task is done and checked (for example, tests pass); "
        ~ "summarize what changed and include any PR URLs, branches, or commits. Use status \"blocked\" only when "
        ~ "you cannot make progress: after three or more different failed attempts at the same problem, or when "
        ~ "you need access or information that only a person can give. Use status \"needs_input\" when you have a "
        ~ "question or need a decision from the user to proceed; put the question in the summary. Do not "
        ~ "call this for partial progress.",
        parseJSON(`{
            "type": "object",
            "properties": {
                "status": { "type": "string", "enum": ["completed", "blocked", "needs_input"] },
                "summary": {
                    "type": "string",
                    "description": "Completed: what was done, with PR URLs or commits. Blocked: what was tried and what is needed to continue. NeedsInput: the question or decision you need from the user."
                }
            },
            "required": ["status", "summary"]
        }`));
}

@trusted unittest // parses arguments leniently
{
    import std.exception : assertThrown;
    auto o = Outcome.fromArgs(parseJSON(`{"status": "Done", "summary": " opened #12 "}`));
    assert(o.status == OutcomeStatus.completed && o.summary == "opened #12");
    o = Outcome.fromArgs(JSONValue(`{"status": "stuck", "summary": "no token"}`));
    assert(o.status == OutcomeStatus.blocked && o.response == "Blocked: no token");
    assertThrown(Outcome.fromArgs(parseJSON(`{"status": "maybe", "summary": "x"}`)));
    assertThrown(Outcome.fromArgs(parseJSON(`{"status": "completed"}`)));
    assertThrown(Outcome.fromArgs(parseJSON(`{}`)));
}

@trusted unittest // finds the last successful report
{
    import nano.llm : ToolCall;
    ToolCall call(string id, string status)
    {
        ToolCall c;
        c.id = id;
        c.name = toolName;
        c.arguments = JSONValue(["status": status, "summary": id]);
        return c;
    }
    auto messages = [
        Message.user("go"),
        Message.assistant("", [call("a", "blocked")]),
        Message.toolResult("a", toolName, "ok", false),
        Message.assistant("", [call("b", "completed")]),
        Message.toolResult("b", toolName, "failed", true),
    ];
    Outcome o;
    assert(Outcome.reportedIn(messages, o) && o.summary == "a");
    assert(!Outcome.reportedIn(messages[0 .. 1], o));
}
