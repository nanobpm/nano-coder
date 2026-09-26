# Security model: shell command safety

nano-coder runs shell commands on the user's behalf. Two independent layers
guard that execution. They are **not** equivalent, and it is important to
understand which one is the actual security boundary.

## The two layers

### 1. Static command-safety guard (`src/permissions.rs`) — best-effort advisory

Before a command runs, a static analyzer parses it and blocks obvious footguns
(`rm -rf /`, tautological SQL deletes, force-pushes to protected branches,
writes that escape the workspace, and so on). It exists to catch mistakes early
and surface a clear, high-signal warning **before** anything executes.

It is **not** a containment boundary. Deciding whether an arbitrary string in a
Turing-complete shell will perform a dangerous effect reduces to the halting
problem, so a static parser over that language has an **unbounded** population of
bypass vectors. Every additional parser rule is itself fresh attack surface and
maintenance cost, and the encodings that dodge the parser are exactly the
effects the OS sandbox exists to contain. We therefore treat this layer as a
**best-effort, high-signal advisory** and do **not** try to make it complete.

The guard does fail **closed** on the one bounded case it can recognise as
uninspectable: a command whose body is computed at run time and cannot be parsed
at all (e.g. `bash -c "$CMD"`). That is a genuine "cannot inspect" signal, not a
gap in an option grammar.

#### Known, accepted static-bypass classes

These are documented limitations of static analysis, **not** bugs. They are
intentionally **out of scope** for the static guard and are contained by the OS
sandbox instead:

- Incomplete option grammars for wrapper commands — e.g. `docker`/`podman`
  run/exec flags such as `--ip`, `ssh -o ProxyCommand=…` executing a local
  command, or GNU `time -f/-o` value-taking options.
- Host-writing subcommands outside the inspected set — e.g.
  `docker cp container:/f /etc/hosts`, bind-mounting `$PWD` or `/` into a
  container.
- Payloads hidden by shell encoding — e.g. an ANSI-C-quoted fork bomb
  (`bash -c $'\x3a(){ \x3a|\x26 };\x3a'`).
- Git refspec forms the parser does not fully model — e.g. a matching refspec
  `git push --force origin :` / `+:`.
- Dynamic / run-time-computed / externally-sourced command text and dynamic
  SQL in general.

Blocking these at the static layer would either be ineffective (the same class
of encoding simply re-hides the payload) or would break ubiquitous legitimate
workflows (`docker cp`, mounting `$PWD`, build scripts, `ProxyCommand`, GNU
`time`, dynamic SQL) for only illusory safety. A static parse-miss is a missed
early warning, **not** a containment failure.

### 2. OS sandbox (`src/sandbox.rs`) — the containment boundary

The real boundary is the operating-system sandbox: **Landlock** on Linux
(ABI 3, Linux 6.2+) and **Seatbelt** (`sandbox-exec`) on macOS. It confines what
a command can actually *do* regardless of how the command is spelled:

- writes are limited to the workspace (plus temp dirs, git dirs, and explicitly
  granted `writable` paths); `read-only` mode allows writes only to temp dirs;
- `network = false` blocks outbound connections;
- it **fails closed**: if the sandbox is enabled but cannot be applied, the
  command does not run.

Because the sandbox mediates effects, not syntax, the encoded fork bomb, the
`docker cp` write escape, and the `$PWD`-mount escape above are all contained by
it even though the static guard cannot see through them.

## Posture and recommendation

The OS sandbox is **off by default**. Running with the sandbox off is a
**documented, user-accepted best-effort posture**: only the advisory static
guard is active, with the known limitations above.

**For untrusted or prompt-injectable model use, enable the sandbox**
(`workspace` or `read-only` mode, and `network = false` where possible). That is
the recommended posture and the layer you should rely on for containment. The
static guard remains a helpful early-warning footgun filter on top of it, not a
substitute for it.

## Invariants under test

`src/sandbox.rs` and `src/permissions.rs` carry defect-**class** tests that pin
the boundary rather than the parser's completeness:

- a command the static guard cannot see through (an encoded write escaping the
  workspace) is still contained by the OS sandbox (write-root boundary);
- uninspectable / run-time-computed input still fails closed in the static guard.
