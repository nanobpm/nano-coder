/// The pure core: every module that starts with `pure:` (check-safe keeps
/// this list in step with them; nano.pureaudit itself is left out, as its
/// test declares impure members on purpose). `pure:` makes the compiler reject
/// impure free functions; this rejects impure member functions, which the
/// label doesn't reach. A pure function's result depends only on its
/// arguments, so the clock, environment, files and other I/O stay in callers.
/// They are also strongly pure (see the end of this file).
module nano.pure_core_test;
@safe:

import std.array : join;
import std.meta : AliasSeq;
import nano.pureaudit : impureFunctions, weaklyPureFunctions;
static import nano.arith;
static import nano.context;
static import nano.emoji;
static import nano.emoji_table;
static import nano.extract;
static import nano.goal;
static import nano.history;
static import nano.instruction_state;
static import nano.markdown;
static import nano.mdblock;
static import nano.mdinline;
static import nano.mdtable;
static import nano.mode;
static import nano.plan;
static import nano.qwen;
static import nano.result;
static import nano.shell;
static import nano.status;
static import nano.temperature;
static import nano.thinking;
static import nano.toml;
static import nano.toml_edit;
static import nano.turn;
static import nano.vision;

alias pureCore = AliasSeq!(
    nano.arith,
    nano.context,
    nano.emoji,
    nano.emoji_table,
    nano.extract,
    nano.goal,
    nano.history,
    nano.instruction_state,
    nano.markdown,
    nano.mdblock,
    nano.mdinline,
    nano.mdtable,
    nano.mode,
    nano.plan,
    nano.qwen,
    nano.result,
    nano.shell,
    nano.status,
    nano.temperature,
    nano.thinking,
    nano.toml,
    nano.turn,
    nano.toml_edit,
    nano.vision,
);

static foreach (M; pureCore)
    static assert(impureFunctions!M().length == 0, "not pure: " ~ impureFunctions!M().join(", "));

// Strongly pure: no public function takes a `ref`/`out` or mutable-pointing
// argument, so a call can't change what its caller passed. Results and
// errors come back as values (`Option`, `Result`, a new struct). A method
// may still update its own struct, and private helper structs (a parser's
// cursor) are exempt.
static foreach (M; pureCore)
    static assert(weaklyPureFunctions!M().length == 0,
        "takes mutable arguments (return the result instead): " ~ weaklyPureFunctions!M().join(", "));
