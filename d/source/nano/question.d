/// The `question` tool (port of `question.rs`): the model asks the user a
/// structured question and blocks until it is answered, without ending its turn.
///
/// The tool handler runs on the agent's thread and parks on the broker; the
/// turn's key reader (which owns the terminal) notices the pending question,
/// renders it and resolves it. With nothing to answer (`-p`, ACP, no tty)
/// the tool returns an error instead.
module nano.question;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import std.algorithm : canFind, filter, map;
import std.array : array, join;
import std.conv : to;
import std.json;
import std.string : strip;
import std.uni : isControl;

import nano.llm : ToolDefinition;

enum toolName = "question";

/// What the tool says when nothing can answer.
enum headlessError = "question tool needs an interactive terminal; end your turn with the question, or "
    ~ "report_outcome(needs_input) with the question in the summary, instead";

struct QuestionOption
{
    string label;
    string description;
}

struct Question
{
    string question;
    string header; /// very short label
    QuestionOption[] options;
    bool custom = true; /// allow a typed answer
}

/// How a question resolves.
struct Answer
{
    enum Kind { answers, away, dismissed }
    Kind kind;
    string[] answers; /// one per question
}

class QuestionError : Exception
{
    this(string msg) @safe { super(msg); }
}

/// Drop control characters (newlines too) and line/paragraph separators from
/// a single-line field (Rust `sanitize_terminal_line`).
string sanitizeLine(string s) @safe
{
    string out_;
    foreach (dchar c; s)
        if (!isControl(c) && c != '\u2028' && c != '\u2029') out_ ~= c.to!string;
    return out_;
}

/// Parse the tool's arguments, tolerating a JSON-string body.
Question[] parse(JSONValue args) @trusted
{
    if (args.type == JSONType.string)
    {
        try args = parseJSON(args.str);
        catch (Exception) args = JSONValue(null);
    }
    JSONValue[] list;
    if (args.type == JSONType.object)
        if (auto q = "questions" in args.object)
            if (q.type == JSONType.array) list = q.array;
    if (!list.length) throw new QuestionError("question needs a non-empty `questions` array");
    Question[] out_;
    foreach (item; list)
    {
        if (item.type != JSONType.object) throw new QuestionError("invalid type: expected struct Question");
        Question q;
        string str(string key, bool required)
        {
            auto v = key in item.object;
            if (v is null)
            {
                if (required) throw new QuestionError("missing field `" ~ key ~ "`");
                return null;
            }
            if (v.type != JSONType.string) throw new QuestionError("invalid type for `" ~ key ~ "`: expected a string");
            return v.str;
        }
        q.question = str("question", true);
        q.header = str("header", false);
        if (auto c = "custom" in item.object)
        {
            if (c.type == JSONType.true_) q.custom = true;
            else if (c.type == JSONType.false_) q.custom = false;
            else throw new QuestionError("invalid type for `custom`: expected a boolean");
        }
        if (auto opts = "options" in item.object)
        {
            if (opts.type != JSONType.array) throw new QuestionError("invalid type for `options`: expected a sequence");
            foreach (o; opts.array)
            {
                auto l = o.type == JSONType.object ? "label" in o.object : null;
                if (l is null || l.type != JSONType.string) throw new QuestionError("missing field `label`");
                auto d = "description" in o.object;
                q.options ~= QuestionOption(l.str, d && d.type == JSONType.string ? d.str : null);
            }
        }
        if (!q.question.strip.length) throw new QuestionError("each question needs non-empty `question` text");
        if (!q.custom && !q.options.length)
            throw new QuestionError("a question with `custom: false` needs at least one option");
        out_ ~= q;
    }
    return out_;
}

/// The tool result text for an answer.
string resultText(const Question[] questions, Answer a) @safe
{
    final switch (a.kind)
    {
        case Answer.Kind.away:
            return "The user is away from the keyboard; make the best decision you can and continue.";
        case Answer.Kind.dismissed:
            return "The user dismissed this question without answering; make the best decision you can and continue.";
        case Answer.Kind.answers:
            string[] parts;
            foreach (i, ref q; questions)
            {
                auto ans = i < a.answers.length && a.answers[i].length ? a.answers[i] : "Unanswered";
                parts ~= "\"" ~ sanitizeLine(q.question) ~ "\"=\"" ~ sanitizeLine(ans) ~ "\"";
            }
            return "User has answered your questions: " ~ parts.join(", ") ~ ". Continue with the answers in mind.";
    }
}

/// Shared between the blocked tool (agent thread) and the key reader.
final class QuestionBroker
{
    private Mutex lock;
    private Condition cond;
    private Question[] pending_;
    private bool waiting, resolved;
    private Answer answer;
    private shared bool interactive_;

    this() @trusted
    {
        lock = new Mutex;
        cond = new Condition(lock);
    }

    void interactive(bool on) @trusted { import core.atomic : atomicStore; atomicStore(interactive_, on); }
    bool interactive() @trusted { import core.atomic : atomicLoad; return atomicLoad(interactive_); }

    /// Register questions and block until `resolve`.
    Answer ask(Question[] questions) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        pending_ = questions;
        waiting = true;
        resolved = false;
        while (!resolved) cond.wait();
        waiting = false;
        pending_ = null;
        return answer;
    }

    /// The waiting questions, or null.
    Question[] pending() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        return waiting && !resolved ? pending_ : null;
    }

    /// Resolve the waiting question (no-op when none).
    void resolve(Answer a) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        if (!waiting || resolved) return;
        answer = a;
        resolved = true;
        cond.notifyAll();
    }

    /// The tool handler.
    string run(JSONValue args) @trusted
    {
        if (!interactive) throw new QuestionError(headlessError);
        auto qs = parse(args);
        return resultText(qs, ask(qs));
    }
}

ToolDefinition definition() @trusted
{
    return ToolDefinition(toolName,
        "Ask the user a question and wait for the answer, without ending your turn. Use when you need a "
        ~ "decision, preference, or clarification to proceed. Offer the likely choices as `options` (put a "
        ~ "recommended option first, with \"(Recommended)\" in its label); the user can also type a custom "
        ~ "answer. Do not use this for a final answer — use report_outcome when the task is done or blocked.",
        parseJSON(`{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string","description":"The complete question to ask"},"header":{"type":"string","description":"Very short label (max 30 chars)"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"]}},"custom":{"type":"boolean","description":"Allow a custom typed answer (default true)"}},"required":["question"]}}},"required":["questions"]}`));
}

@trusted unittest // parses_questions_and_requires_text
{
    import std.exception : assertThrown, assertNotThrown;
    auto qs = parse(parseJSON(`{ "questions": [ { "question": "Which DB?", "options": [ {"label": "Postgres"}, {"label": "SQLite"} ] } ] }`));
    assert(qs.length == 1 && qs[0].question == "Which DB?" && qs[0].options.length == 2 && qs[0].custom);
    assertThrown(parse(parseJSON(`{ "questions": [] }`)));
    assertThrown(parse(parseJSON(`{ "questions": [ { "question": "  " } ] }`)));
    assertThrown(parse(parseJSON(`{ "questions": [ { "question": "Pick", "custom": false } ] }`)));
    assertNotThrown(parse(parseJSON(`{ "questions": [ { "question": "Pick", "custom": false, "options": [ {"label": "A"} ] } ] }`)));
    assert(parse(JSONValue(`{"questions":[{"question":"s"}]}`))[0].question == "s");
}

@trusted unittest // ask_blocks_until_resolved, and sequential questions each register
{
    import core.thread : Thread;
    import core.time : msecs;
    auto broker = new QuestionBroker;
    foreach (expected; ["first", "second"])
    {
        Answer got;
        auto t = new Thread(() { got = broker.ask([Question(expected)]); });
        t.start();
        Question[] req;
        while ((req = broker.pending()) is null) Thread.sleep(1.msecs);
        assert(req[0].question == expected);
        broker.resolve(Answer(Answer.Kind.answers, ["yes"]));
        t.join();
        assert(got.answers == ["yes"]);
        assert(broker.pending() is null);
    }
}

@trusted unittest // wording, and control sequences/newlines stripped
{
    auto qs = [Question("Q")];
    assert(resultText(qs, Answer(Answer.Kind.away)).canFind("away from the keyboard"));
    assert(resultText(qs, Answer(Answer.Kind.dismissed)).canFind("dismissed"));
    assert(resultText(qs, Answer(Answer.Kind.answers, ["opt"])).canFind(`"Q"="opt"`));
    auto a = resultText([Question("pick\x1b[2Jone")], Answer(Answer.Kind.answers, ["ans\x07wer"]));
    assert(a.canFind(`"pick[2Jone"="answer"`) && !a.canFind('\x1b') && !a.canFind('\x07'));
    a = resultText([Question("line1\nline2")], Answer(Answer.Kind.answers, ["ans\nwer"]));
    assert(a.canFind(`"line1line2"="answer"`) && !a.canFind('\n'));
    assert(sanitizeLine("hi\x1b[2J\nthere") == "hi[2Jthere" && sanitizeLine("plain — label") == "plain — label");
}
