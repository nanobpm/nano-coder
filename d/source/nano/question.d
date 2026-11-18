/// The `question` tool (port of `question.rs`): the model asks the user a
/// structured question and blocks until it is answered, without ending its turn.
///
/// The tool handler runs on the agent's thread and parks on the broker; the
/// turn's key reader (which owns the terminal) notices the pending question,
/// renders it and resolves it. With nothing to answer (`-p`, ACP, no tty)
/// the tool returns an error instead.
module nano.question;

@safe:

import std.sumtype : SumType, match;
import core.sync.condition : Condition;
import std.sumtype : SumType, match;
import core.sync.mutex : Mutex;
import std.sumtype : SumType, match;
import std.algorithm : canFind, filter, map;
import std.sumtype : SumType, match;
import std.array : array, join;
import std.sumtype : SumType, match;
import std.conv : to;
import std.sumtype : SumType, match;
import std.json;
import std.sumtype : SumType, match;
import std.string : strip;
import std.sumtype : SumType, match;
import std.uni : isControl;

import std.sumtype : SumType, match;
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
    immutable(QuestionOption)[] options;
    bool custom = true; /// allow a typed answer
}

/// How a question resolves.
/// The user answered: one answer per question.
struct Answered { immutable(string)[] answers; }
/// The user is away from the keyboard.
struct Away {}
/// The user dismissed the questions.
struct Dismissed {}
/// ditto
alias Answer = SumType!(Answered, Away, Dismissed);

class QuestionError : Exception
{
    this(string msg) @safe { super(msg); }
}

/// Drop control characters (newlines too) and line/paragraph separators from
/// a single-line field the model reads back (question.rs). Text bound for the
/// terminal uses `nano.trajectory.terminalSafe`, which drops whole escapes.
string sanitizeLine(string s) @safe
{
    string out_;
    foreach (dchar c; s)
        if (!isControl(c) && c != '\u2028' && c != '\u2029') out_ ~= c.to!string;
    return out_;
}

/// How a question shows in its picker (Rust `question_prompt`): returns the
/// prompt row and sets `body` to rows drawn above it. A plain one-line
/// question that fits stays the prompt (no body). Anything else (several
/// lines, markdown, too wide) is rendered as markdown into `body` with a short
/// prompt, since the prompt is one row and would otherwise collapse a
/// structured question into one unreadable line. The text is sanitised first
/// (escapes dropped, line feeds kept), so the model cannot inject controls.
string questionPrompt(string question, size_t width, out string[] body_)
{
    import std.array : split;
    import std.string : stripRight;
    import nano.markdown : render;
    import nano.resume : cells;
    import nano.trajectory : terminalSafe;
    // Trailing space only: leading indentation is markdown (a code block).
    auto text = terminalSafe(question.stripRight, true);
    // Room for the `? ` prefix and the `› ` after the prompt.
    import nano.arith : saturatingSub;
    auto room = saturatingSub(width, 4);
    auto rendered = render(text, room > 20 ? room : 20);
    // Inline only if it fits the prompt row, in cells (wide glyphs count 2).
    if (rendered == text && !text.canFind('\n') && cells(text) <= room) return text;
    body_ = rendered.split('\n');
    return "Your answer";
}

/// Parse the tool's arguments, tolerating a JSON-string body.
Question[] parse(JSONValue args)
{
    if (args.type == JSONType.string)
    {
        try args = parseJSON(args.str);
        catch (Exception) args = JSONValue(null); // a non-JSON string is reported as missing questions below
    }
    JSONValue[] list;
    if (args.type == JSONType.object)
        if (auto q = "questions" in args.objectNoRef)
            if (q.type == JSONType.array) list = q.arrayNoRef;
    if (!list.length) throw new QuestionError("question needs a non-empty `questions` array");
    Question[] out_;
    foreach (item; list)
    {
        if (item.type != JSONType.object) throw new QuestionError("invalid type: expected struct Question");
        Question q;
        string str(string key, bool required)
        {
            auto v = key in item.objectNoRef;
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
        if (auto c = "custom" in item.objectNoRef)
        {
            if (c.type == JSONType.true_) q.custom = true;
            else if (c.type == JSONType.false_) q.custom = false;
            else throw new QuestionError("invalid type for `custom`: expected a boolean");
        }
        if (auto opts = "options" in item.objectNoRef)
        {
            if (opts.type != JSONType.array) throw new QuestionError("invalid type for `options`: expected a sequence");
            foreach (o; opts.arrayNoRef)
            {
                auto l = o.type == JSONType.object ? "label" in o.objectNoRef : null;
                if (l is null || l.type != JSONType.string) throw new QuestionError("missing field `label`");
                auto d = "description" in o.objectNoRef;
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
    return a.match!(
        (Away _) => "The user is away from the keyboard; make the best decision you can and continue.",
        (Dismissed _) => "The user dismissed this question without answering; make the best decision you can and continue.",
        (Answered got) {
            string[] parts;
            foreach (i, ref q; questions)
            {
                auto ans = i < got.answers.length && got.answers[i].length ? got.answers[i] : "Unanswered";
                parts ~= "\"" ~ sanitizeLine(q.question) ~ "\"=\"" ~ sanitizeLine(ans) ~ "\"";
            }
            return "User has answered your questions: " ~ parts.join(", ") ~ ". Continue with the answers in mind.";
        },
    );
}

/// An immutable copy of `a`.
immutable(Answer) immutableAnswer(Answer a)
{
    return a.match!(
        (Answered x) => immutable Answer(Answered(x.answers)),
        (Away _) => immutable Answer(Away()),
        (Dismissed _) => immutable Answer(Dismissed()),
    );
}

/// A mutable copy of `a`.
Answer mutableAnswer(immutable Answer a)
{
    return a.match!(
        (immutable Answered x) => Answer(Answered(x.answers)),
        (immutable Away _) => Answer(Away()),
        (immutable Dismissed _) => Answer(Dismissed()),
    );
}

/// Shared between the blocked tool (agent thread) and the key reader: a
/// sendable handle (copies refer to the same broker).
struct QuestionBroker
{
    import nano.safeio : Shared;
    private static struct State
    {
        immutable(Question)[] pending;
        bool waiting, resolved, interactive;
        // A one-element slice, not an `Answer` field: assigning over a
        // SumType that holds references is not @safe, replacing a slice is.
        immutable(Answer)[] answer;
    }
    private Shared!State state;

    /// A new broker.
    static QuestionBroker make() { return QuestionBroker(Shared!State.make); }
    /// Whether this handle refers to a broker.
    bool opCast(B : bool)() const { return cast(bool) state; }

    void interactive(bool on) { state.update((ref State s) { s.interactive = on; }); }
    bool interactive() { return state.get.interactive; }

    /// Register questions and block until `resolve`.
    Answer ask(const Question[] questions)
    {
        auto qs = questions.idup;
        state.update((ref State s) {
            s.pending = qs;
            s.waiting = true;
            s.resolved = false;
        });
        return state.await!Answer((ref const State s) => s.resolved, (ref State s) {
            s.waiting = false;
            s.pending = null;
            return mutableAnswer(s.answer[0]);
        });
    }

    /// The waiting questions, or null.
    immutable(Question)[] pending()
    {
        auto s = state.get;
        return s.waiting && !s.resolved ? s.pending : null;
    }

    /// Resolve the waiting question (no-op when none).
    void resolve(Answer a)
    {
        immutable(Answer)[] boxed = [immutableAnswer(a)];
        state.update((ref State s) {
            if (!s.waiting || s.resolved) return;
            s.answer = boxed;
            s.resolved = true;
        });
    }

    /// The tool handler.
    string run(JSONValue args)
    {
        if (!interactive) throw new QuestionError(headlessError);
        auto qs = parse(args);
        return resultText(qs, ask(qs));
    }
}

ToolDefinition definition()
{
    return ToolDefinition(toolName,
        "Ask the user a question and wait for the answer, without ending your turn. Use when you need a "
        ~ "decision, preference, or clarification to proceed. Offer the likely choices as `options` (put a "
        ~ "recommended option first, with \"(Recommended)\" in its label); the user can also type a custom "
        ~ "answer. Do not use this for a final answer — use report_outcome when the task is done or blocked.",
        parseJSON(`{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string","description":"The complete question to ask"},"header":{"type":"string","description":"Very short label (max 30 chars)"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"]}},"custom":{"type":"boolean","description":"Allow a custom typed answer (default true)"}},"required":["question"]}}},"required":["questions"]}`));
}

// rust: question.rs::parses_questions_and_requires_text
unittest // parses_questions_and_requires_text
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

// rust: question.rs::ask_blocks_until_resolved
unittest // ask_blocks_until_resolved, and sequential questions each register
{
    import core.thread : Thread;
    import nano.safeio : spawn;
    import core.time : msecs;
    static immutable(Answer)[] askOne(QuestionBroker b, string q) { return [immutableAnswer(b.ask([Question(q)]))]; }
    auto broker = QuestionBroker.make;
    foreach (expected; ["first", "second"])
    {
        auto t = spawn(&askOne, broker, expected);
        immutable(Question)[] req;
        while ((req = broker.pending()) is null) Thread.sleep(1.msecs);
        assert(req[0].question == expected);
        broker.resolve(Answer(Answered(["yes"])));
        assert(mutableAnswer(t.join()[0]) == Answer(Answered(["yes"])));
        assert(broker.pending() is null);
    }
}

// rust: main.rs::sanitize_terminal_line_drops_line_feeds
// rust: question.rs::away_and_dismissed_have_stable_wording
// rust: question.rs::result_text_strips_control_sequences_from_model_and_user_text
// rust: question.rs::result_text_strips_newlines_from_quoted_question_and_answer
unittest // wording, and control sequences/newlines stripped
{
    auto qs = [Question("Q")];
    assert(resultText(qs, Answer(Away())).canFind("away from the keyboard"));
    assert(resultText(qs, Answer(Dismissed())).canFind("dismissed"));
    assert(resultText(qs, Answer(Answered(["opt"]))).canFind(`"Q"="opt"`));
    auto a = resultText([Question("pick\x1b[2Jone")], Answer(Answered(["ans\x07wer"])));
    assert(a.canFind(`"pick[2Jone"="answer"`) && !a.canFind('\x1b') && !a.canFind('\x07'));
    a = resultText([Question("line1\nline2")], Answer(Answered(["ans\nwer"])));
    assert(a.canFind(`"line1line2"="answer"`) && !a.canFind('\n'));
    assert(sanitizeLine("hi\x1b[2J\nthere") == "hi[2Jthere" && sanitizeLine("plain — label") == "plain — label");
}

// rust: main.rs::a_plain_one_line_question_stays_the_picker_prompt
// rust: main.rs::a_structured_question_is_rendered_as_markdown_above_the_picker
// rust: main.rs::a_long_question_wraps_and_escapes_are_dropped
unittest // questionPrompt: inline, markdown body, wrapping and escapes
{
    import std.algorithm : any, canFind;
    import std.array : replicate;
    string[] body_;
    assert(questionPrompt("Which database should I use?", 80, body_) == "Which database should I use?");
    assert(body_ is null);

    auto q = "I found two options:\n\n- **Postgres**: already in `docker-compose.yml`\n- SQLite: simpler\n\nWhich should I use?";
    assert(questionPrompt(q, 80, body_) == "Your answer");
    assert(body_.length >= 4, "line breaks kept");
    assert(body_.any!(l => l.canFind("Postgres") && !l.canFind("**")), "markdown rendered");
    assert(body_.any!(l => l.canFind("Which should I use?")));

    string[] wrapped;
    assert(questionPrompt("\x1b[2J" ~ "word ".replicate(40), 40, wrapped) == "Your answer");
    assert(wrapped.length > 1);
    foreach (l; wrapped) assert(!l.canFind("\x1b[2J"), "escapes dropped");
}

// rust: main.rs::an_over_wide_question_leaves_the_inline_prompt_on_a_narrow_terminal
unittest
{
    string[] body_;
    assert(questionPrompt("Which should I use?", 18, body_) == "Your answer" && body_.length, "over-wide renders above");
    body_ = null;
    assert(questionPrompt("fits exactly!?", 18, body_) == "fits exactly!?" && !body_.length);
    assert(questionPrompt("数据库用哪个比较好呢？", 19, body_) == "Your answer", "20 cells on a 19-col terminal");
}

// rust: main.rs::leading_indentation_is_preserved_for_markdown
unittest
{
    string[] body_;
    assert(questionPrompt("    indented\n    code", 80, body_) == "Your answer");
    assert(body_.canFind!(l => l.canFind("indented")) && body_.canFind!(l => l.canFind("code")));
    body_ = null;
    assert(questionPrompt("Plain question?   \n", 80, body_) == "Plain question?" && !body_.length);
}
