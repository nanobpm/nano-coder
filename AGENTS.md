# Working on nano-coder

nano-coder is a terminal coding agent written in D (LDC, dub). This file is the
coding standard for anyone changing it, human or agent. Most rules below are
enforced by `scripts/check-safe.sh`; the reasons are in REVIEW.md.

## Before you push

- `scripts/ci.sh all` must pass. It is exactly what CI runs: check-safe,
  dscanner, both builds typechecked, `dub test`, the release build and the
  smoke checks. Enable the hooks once per clone with
  `git config core.hooksPath .githooks` (pre-push runs `ci.sh quick`).
- Add a check to `scripts/ci.sh`, never to the workflow files.
- The PR title is a Conventional Commit (`feat(scope): …`, `fix: …`,
  `docs: …`); it becomes the squash-merge subject on main and picks the next
  release version (RELEASING.md).
- Don't run the tests from a checkout under `/tmp`: some sandbox tests rely on
  their "outside the workspace" directories not being writable temp dirs.
- `dub build` without `-b release` overwrites `./nano-coder` with a debug
  build; rebuild with `-b release` before benchmarking.

## Safety

- Every module starts with `@safe:`. `@system` is only for `extern (C)`
  declarations. Never use `@trusted:` or `@system:` to cover a scope.
- Unsafe operations live in `source/nano/safeio.d`. Anywhere else, an
  `@trusted` is the smallest possible lambda or function, with a comment
  directly above it saying why it is safe.
- Budgets only go down. `scripts/*-budget` files cap `@trusted`, casts,
  `catch (Exception)`, classes, nullable references and more; the `*-floor`
  files set minimums for `pure`. If you remove an escape, lower the budget in
  the same PR. Raising one needs a stated reason in the PR description.
  Ratchets are measured against the merge base; a worse count fails unless
  a commit carries a `Ratchet-Override: <name> <reason>` trailer. A squash
  merge drops that trailer, so on main `scripts/check-safe.sh` also reads
  the trailers of the commits of the PR named by the squash subject
  (`… (#N)`), through the GitHub API.
- Compiler flags include `-preview=dip1000 -preview=nosharedaccess`: scope and
  shared errors are real bugs, not noise.

## Threads and shared state

- Start threads only with `nano.safeio.spawn`/`spawnDaemon`, passing sendable
  arguments. No `new Thread`, `std.concurrency`, `__gshared` or `union`
  outside `safeio.d`.
- Share state through `shared` types: `Locked!T`, `Shared!T`, `Chan!T`, or
  atomics. Hand over an unshared object with `Isolated!T`; every
  `assumeIsolated` needs the same "why it is safe" comment as `@trusted`.

## Types and errors

- A value that may be absent is `Option!T` (`nano.option`), not a null class
  reference or `Nullable`. Reach it with `match`, `foreach`, `ifSome`,
  `orElse` or `unwrap("why it can't be absent")`.
- Pure-core modules (those starting with `pure:`) return `Result!(T, E)`
  (`nano.result`) instead of throwing. Convert to an exception only at the
  I/O edge with `orThrow`.
- Variants are `std.sumtype.SumType` with exhaustive `match`, not a kind
  field plus optional members. A `switch` over an enum is a `final switch`.
- Prefer a struct, enum or SumType to a new class.
- Never catch `Throwable` or `Error`. A `catch (Exception)` that neither
  rethrows nor uses the exception has a `//` comment saying why it is safe
  to ignore.
- Keep functions `pure` where you can: move I/O to the caller. Mark
  `nothrow` where it compiles.
- Read the clock and sleep through `nano.clock` (tests fake time). Use
  `nano.arith.saturatingSub` instead of `a > b ? a - b : 0`.

## Memory

A session runs for days. Anything that grows per turn or per tool call must be
bounded.

- Don't keep large text (tool output, file contents, folded history) alive
  for the life of the session. Keep a reference (a session-log line, a path)
  and read it back when needed; the session log already holds everything.
- Caps count bytes, not lines or items: one item can be megabytes.
- Avoid building large strings by repeated `~=` in hot paths; use an
  `Appender` and release it.
- A change that could affect long-run memory reports before/after numbers
  (`GC.stats` and physical footprint) over many turns in the PR.

## Terminal UI

- All output goes through the frame renderer (`frame.d`/`frameui.d`). Don't
  write to stdout directly or add another renderer.
- A UI change is checked in a real terminal, not only in tests; say in the PR
  what you checked and in which terminal (and in a Herdr pane if it touches
  the Herdr integration).

## Tests and docs

- There is no such thing as a flaky test. Always green. A test failure is a
  product defect or a test defect. Root cause it and fix it.
- Unit tests sit in `unittest` blocks next to the code or in a
  `*_test.d` module; new behaviour comes with tests. Each module's tests must
  finish within 1 s: use `nano.clock`'s fake time rather than real waits.
  A module that must wait on real processes or sockets is listed, with the
  reason, in `scripts/slow-tests`; one that changes process-wide state is
  listed in `scripts/serial-tests`.
- Public symbols have `///` doc comments that say what and why.
- User-visible behaviour (commands, keys, config, output) is documented in
  README.md in the same PR.
- Benchmark changes on hot paths (rendering, the agent loop, session I/O) and
  report the numbers.
- Don't add dependencies without a reason in the PR.

## Reviewing a PR

- Check the change against this file and run `scripts/ci.sh all`.
- Every review comment you say you addressed is a pushed commit. If you
  decide a comment needs no change, reply on the PR saying why instead.
- Keep review rounds about the PR's goal: file unrelated improvements as
  issues rather than growing the PR.
