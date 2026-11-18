/// Hooks around the turn and the plan tools (agent.rs tests): PreToolUse
/// deny context and rewrites, SessionStart across a rejected prompt, the
/// plan tools' switch and their staleness reminder.
module nano.agent_hooks_test;
@safe:

version (unittest):

import core.time : seconds;
import std.algorithm : all, any, canFind, count, filter, startsWith;
import std.array : array;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.goal : OutcomeStatus;
import nano.claude_hooks : Event, Hook, HookManager;
import nano.llm;
import nano.option : some;
import nano.permissions : Policy, parseRule;
import nano.providers.mock : MockClient;
import nano.reminders : planStaleAfter;
import nano.tools : ToolRegistry;

private:

Hook hook(Event e, string command, string matcher = null)
{
    Hook h;
    h.event = e;
    h.command = command;
    h.matcher = matcher;
    h.timeout = 10.seconds;
    return h;
}

string freshDir(string name)
{
    auto dir = buildPath(tempDir, "nano-d-agent-hooks-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

LLMResponse call(string id, string name, string args) { return LLMResponse("", "", [ToolCall.fromRaw(id, name, args)]); }

ToolRegistry echoTools()
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) {
        auto t = "text" in a;
        return t is null ? "pong" : t.str;
    });
    return reg;
}

// rust: agent.rs::plan_tools_can_be_turned_off
unittest
{
    auto agent = new Agent(new MockClient([]), echoTools, Policy.init, "sys");
    assert(agent.offeredTools.any!(d => d.name == "plan_add"));
    agent.planTools = false;
    assert(!agent.offeredTools.any!(d => d.name.startsWith("plan_")));
}

// A plan left in progress while other tools run draws a reminder in the
// tool result that crosses the staleness mark.
// rust: agent.rs::stale_plan_gets_a_reminder_in_a_tool_result
unittest
{
    LLMResponse[] script = [call("p1", "plan_add", `{"items":["Find it","Fix it"]}`),
        call("p2", "plan_update", `{"id":1,"status":"in_progress"}`)];
    foreach (i; 0 .. planStaleAfter)
        script ~= call("c" ~ i.to!string, "echo", format(`{"text":"pong %s"}`, i));
    script ~= LLMResponse("done");
    auto mock = new MockClient(script);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    agent.run("go", new NullEvents);
    auto results = mock.seen[$ - 1].filter!(m => m.toolName == "echo").array;
    assert(results.length == planStaleAfter);
    foreach (i, m; results[0 .. $ - 1]) assert(m.content == format("pong %s", i), m.content);
    auto reminded = results[$ - 1].content;
    assert(reminded.startsWith(format("pong %s\n\n<system-reminder>\n", planStaleAfter - 1))
        && reminded.canFind(`#1 "Find it" is still in progress`), reminded);
}

// rust: agent.rs::pre_tool_use_context_survives_a_deny
unittest
{
    auto mock = new MockClient([call("e1", "echo", `{}`), LLMResponse("done")]);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    agent.hooks = some(new HookManager([hook(Event.preToolUse,
        `cat >/dev/null; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"not allowed","additionalContext":"ctx-explains-why"}}'`,
        "echo")], tempDir));
    agent.run("go", new NullEvents);
    auto result = agent.messages.filter!(m => m.role == Role.tool).array[0];
    assert(result.isError, "the denied call is blocked: " ~ result.content);
    assert(result.content.canFind("not allowed"), result.content);
    assert(result.content.canFind("ctx-explains-why"), "the deny hook's context still reaches the model: " ~ result.content);
}

// A command rewritten by a hook passes the policy again: a denied rewrite
// never reaches the handler.
// rust: agent.rs::pre_tool_use_rewrite_is_rechecked_against_policy
unittest
{
    string[] ran;
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("bash", "bash", parseJSON(`{"type":"object"}`)), (JSONValue a) {
        ran ~= a["command"].str;
        return "ran";
    });
    Policy policy;
    policy.deny ~= parseRule("Bash(forbidden-cmd*)");
    auto agent = new Agent(new MockClient([call("b1", "bash", `{"command":"ls"}`), LLMResponse("done")]), reg, policy, "sys");
    agent.hooks = some(new HookManager([hook(Event.preToolUse,
        `cat >/dev/null; echo '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"forbidden-cmd"}}}'`,
        "Bash")], tempDir));
    agent.run("list files", new NullEvents);
    assert(agent.lastStop == StopReason.endTurn);
    auto result = agent.messages.filter!(m => m.role == Role.tool).array[0];
    assert(result.isError, "the rewritten command is re-checked and denied: " ~ result.content);
    assert(ran.length == 0, "the denied rewrite never reached bash");
}

// rust: agent.rs::pre_tool_use_rewrite_reaches_special_tools
unittest
{
    auto agent = new Agent(new MockClient([call("o1", "report_outcome", `{"status":"completed","summary":"all green"}`)]),
        echoTools, Policy.init, "sys");
    agent.hooks = some(new HookManager([hook(Event.preToolUse,
        `cat >/dev/null; echo '{"hookSpecificOutput":{"updatedInput":{"status":"blocked","summary":"all green"}}}'`,
        "report_outcome")], tempDir));
    agent.run("finish", new NullEvents);
    assert(agent.hasOutcome && agent.lastOutcome.status == OutcomeStatus.blocked,
        "a rewrite of a special tool's arguments reaches its handler");
}

// SessionStart runs once; its context waits for the first accepted prompt
// when the first one is rejected.
// rust: agent.rs::session_start_context_survives_a_rejected_first_prompt
unittest
{
    auto dir = freshDir("session-start");
    scope (exit) rmdirRecurse(dir);
    auto mock = new MockClient([LLMResponse("accepted answer")]);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    agent.hooks = some(new HookManager([
        hook(Event.sessionStart, "echo startup-context; echo ran >> session_start_count"),
        hook(Event.userPromptSubmit, "grep -q reject-me && exit 2 || exit 0")], dir));
    auto rejected = agent.run("reject-me", new NullEvents);
    assert(rejected.length && mock.seen.length == 0, "a rejected prompt never reaches the model");
    assert(agent.run("hello", new NullEvents) == "accepted answer");
    assert(mock.seen[0].any!(m => m.role == Role.user && m.content.canFind("startup-context")),
        "SessionStart context arrives with the first accepted prompt");
    auto countFile = buildPath(dir, "session_start_count");
    assert(countFile.exists && readText(countFile).count("ran") == 1, "SessionStart runs once per session");
}
