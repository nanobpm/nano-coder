/// Runs nano.nullaudit over every module except app (checked by a static
/// assert at the end of app.d, since dub test leaves it out) and the *_test
/// modules: a field or global holding a bare class reference must become
/// `NotNull!C`, `Option!C` or `@nullable("why") C`. check-safe fails when a
/// module is missing from this list.
module nano.null_audit_test;
@safe:

import nano.nullaudit;
static import nano.acp;
static import nano.agent;
static import nano.clock;
static import nano.agent_status;
static import nano.system_prompt;
static import nano.testserver;
static import nano.testenv_test;
static import nano.arith;
static import nano.attachment;
static import nano.claude_hooks;
static import nano.cmdexpand;
static import nano.commands;
static import nano.config;
static import nano.context;
static import nano.control;
static import nano.copilot;
static import nano.emoji;
static import nano.emoji_table;
static import nano.frame;
static import nano.frameui;
static import nano.extract;
static import nano.goal;
static import nano.session_settings;
static import nano.guard;
static import nano.herdr;
static import nano.history;
static import nano.http;
static import nano.instruction_state;
static import nano.instructions;
static import nano.keycmd;
static import nano.landlock;
static import nano.lineedit;
static import nano.llm;
static import nano.markdown;
static import nano.mdblock;
static import nano.mdinline;
static import nano.mdtable;
static import nano.memory;
static import nano.memmigrate;
static import nano.memsecret;
static import nano.mode;
static import nano.nullaudit;
static import nano.option;
static import nano.paths;
static import nano.permissions;
static import nano.plan;
static import nano.probe;
static import nano.pureaudit;
static import nano.result;
static import nano.providers.anthropic;
static import nano.providers.demo;
static import nano.providers.mock;
static import nano.providers.openai;
static import nano.providers;
static import nano.providers.responses;
static import nano.question;
static import nano.queue;
static import nano.qwen;
static import nano.recents;
static import nano.release_notes;
static import nano.reminders;
static import nano.resume;
static import nano.retry;
static import nano.safeio;
static import nano.sandbox;
static import nano.session;
static import nano.session_history;
static import nano.session_index;
static import nano.cross_session;
static import nano.settings;
static import nano.settings_dialog;
static import nano.shell;
static import nano.skills;
static import nano.status;
static import nano.subagent;
static import nano.temperature;
static import nano.thinking;
static import nano.timers;
static import nano.toml;
static import nano.toml_edit;
static import nano.turn;
static import nano.tools.bash;
static import nano.tools.files;
static import nano.tools;
static import nano.tools.search;
static import nano.trajectory;
static import nano.trust;
static import nano.turn_commands;
static import nano.ui;
static import nano.update;
static import nano.vision;

private alias modules = imported!"std.meta".AliasSeq!(
    nano.acp,
    nano.agent,
    nano.agent_status,
    nano.clock,
    nano.system_prompt,
    nano.testserver,
    nano.testenv_test,
    nano.arith,
    nano.attachment,
    nano.claude_hooks,
    nano.cmdexpand,
    nano.commands,
    nano.config,
    nano.context,
    nano.control,
    nano.copilot,
    nano.emoji,
    nano.emoji_table,
    nano.frame,
    nano.frameui,
    nano.extract,
    nano.goal,
    nano.session_settings,
    nano.guard,
    nano.herdr,
    nano.history,
    nano.http,
    nano.instruction_state,
    nano.instructions,
    nano.keycmd,
    nano.landlock,
    nano.lineedit,
    nano.llm,
    nano.markdown,
    nano.mdblock,
    nano.mdinline,
    nano.mdtable,
    nano.memory,
    nano.memmigrate,
    nano.memsecret,
    nano.mode,
    nano.nullaudit,
    nano.option,
    nano.paths,
    nano.permissions,
    nano.plan,
    nano.probe,
    nano.pureaudit,
    nano.result,
    nano.providers.anthropic,
    nano.providers.demo,
    nano.providers.mock,
    nano.providers.openai,
    nano.providers,
    nano.providers.responses,
    nano.question,
    nano.queue,
    nano.qwen,
    nano.recents,
    nano.release_notes,
    nano.reminders,
    nano.resume,
    nano.retry,
    nano.safeio,
    nano.sandbox,
    nano.session,
    nano.session_history,
    nano.session_index,
    nano.cross_session,
    nano.settings,
    nano.settings_dialog,
    nano.shell,
    nano.skills,
    nano.status,
    nano.subagent,
    nano.temperature,
    nano.thinking,
    nano.timers,
    nano.toml,
    nano.turn,
    nano.toml_edit,
    nano.tools.bash,
    nano.tools.files,
    nano.tools,
    nano.tools.search,
    nano.trajectory,
    nano.trust,
    nano.turn_commands,
    nano.ui,
    nano.update,
    nano.vision,
);

unittest
{
    string[] bare;
    static foreach (M; modules)
        bare ~= bareRefs!M();
    import std.array : join;
    assert(bare.length == 0, "bare class references (use NotNull!C, Option!C or @nullable(\"why\")):\n  "
        ~ bare.join("\n  "));
}
