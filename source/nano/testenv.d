/// The unit-test process's environment. `dub test` started from a git hook
/// (pre-push, a rebase `exec`) inherits `GIT_DIR` and friends, which point
/// every `git` the tests run in their temp directories at the enclosing
/// repository instead: tests then commit to its current branch, add
/// worktrees and branches, and `git init --bare` turns it bare. Clearing
/// git's repository variables before any test runs keeps the tests hermetic.
module nano.testenv;
@safe:

version (unittest):

/// `git rev-parse --local-env-vars`.
immutable string[] gitLocalEnvVars = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
    "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
];

shared static this()
{
    import std.process : environment;
    foreach (name; gitLocalEnvVars) environment.remove(name);
}

unittest
{
    import std.process : environment;
    foreach (name; gitLocalEnvVars) assert(environment.get(name) is null, name);
}
