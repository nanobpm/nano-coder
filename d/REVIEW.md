# Rust vs D: safety and architecture review

This compares the modules that exist in both implementations: config, the LLM
types, providers (OpenAI-compatible, Copilot, Anthropic), the HTTP/SSE layer,
the six tools, permissions, sessions and the core agent loop. The rest of the
Rust crate is out of scope until it's ported. Performance numbers are in
`bench/results.json` (from `bench/run.py`).

Each finding is rated **R** (Rust is stronger), **D** (D is stronger), or
**=** (about the same).

## 1. Memory safety

| | Rust | D port |
|---|---|---|
| Default | Safe. 27 `unsafe` blocks outside tests, all FFI: signals, `ioctl` window size, `setsid`/`killpg`, Landlock and Seatbelt syscalls. | `@system` everywhere. Nothing in the port is marked `@safe`, so the compiler checks no pointer, cast or escape rules. |
| Use-after-free and double free | Prevented by ownership. | Prevented in practice by the GC, since the port does no manual memory management. **=** |
| Bounds checks | Always on; an overrun is a panic. | **Found in review:** dub's `release` build type (`-release`) turns bounds checks *off* in `@system` code, so an out-of-range index read garbage silently (checked with a small test program). Fixed by `-boundscheck=on` in `dub.json`, which adds 19 KB. **R** until the code is `@safe` by construction. |
| Casts | `as` only between numeric types. Reinterpreting bytes as `str` needs `from_utf8` (checked) or `unsafe`. | 28 `cast(...)` expressions, including `ubyte[]` → `string` without validation, and two that cast away `const` (`config.d`, `mock.d`). **R** |
| Invalid UTF-8 | `String::from_utf8_lossy` on tool output. | **Found in review:** `bash` used `readText`, which throws on invalid UTF-8, so a command that printed one bad byte returned no output at all, only an error. Fixed with `lossyUtf8` (U+FFFD replacement, unit-tested). `read_file` already validated. |

Recommended for D: put `@safe:` at the top of each module and mark the few
FFI and cast sites `@trusted` with a comment. The new ports (`shell.d`
onward) are written this way. Retrofitting the existing modules is tracked in
PORTING.md.

## 2. Error handling

| | Rust | D port |
|---|---|---|
| Model | `Result<T, anyhow::Error>` in every signature. A call that can fail can't be ignored without `?` or a visible `unwrap`. | Exceptions. A function's signature doesn't say whether it can fail. **R** |
| Panics and crashes | 108 `unwrap`/`expect` and 0 `panic!` outside tests, mostly on invariants (mutex poisoning, `serde_json` on values it just built). | D's `Error`s (bounds, assert, out of memory) are not `Exception`s, so the agent loop's `catch (Exception)` doesn't catch them and they end the process. That matches a Rust panic, which also isn't caught. **=** |
| Tool failures | Typed `ToolError` returned to the model. | `ToolError` returned to the model. Any other `Exception` becomes "`<tool>` failed: …". Simpler, and nothing gets lost. **=** |
| Being explicit | Every fallible step shows. | There are 15 broad `catch (Exception)` blocks. They're easy to write and easy to overuse. **R** |

## 3. Concurrency

The D port is single-threaded and blocking. A turn runs on the main thread,
and Ctrl-C ends the process. Rust runs on tokio, and cancel, steer, the queue
and ACP all run at the same time as the turn. Its compiler requires anything
shared between tasks to be `Send`/`Sync`, so data races don't compile.

D has the tools for this: `shared`, which bans unsynchronised access;
`immutable`, which is thread-safe; and `std.concurrency` message passing.
`@safe` code can't touch `__gshared`. These are opt-in, though, and they're
weaker than Rust's checks because `shared` is easy to cast away. **R**.

**After porting cancel/steer and ACP.** The D port now uses threads: a
`TurnControl` behind a mutex, a process-wide atomic cancel flag that the
libcurl progress callback and the bash wait loop poll, and a stdin reader
thread that routes ACP messages while the turn runs on the main thread. No
data race turned up. The one real bug was a **deadlock**: a reader thread
blocked in `readln` holds stdin's `FILE` lock, and `std.process.spawnProcess`
flushes (and so locks) every stdio stream before forking. The first bash call
in a turn hung forever. Rust's `Send`/`Sync` wouldn't have caught this either,
since it's lock ordering rather than a race. It is a D-specific hazard, though,
because Phobos's stdio hides a global lock. Fix: `FdLineReader` reads fd 0
with raw `read(2)`. Rule: threads that block on input must not use `std.stdio`.

Toolchain note: LDC 1.43 failed to link once `acp.d` was added (an undefined
`core.internal.switch_.__switch_error` instance, because LDC dropped a
template instance that other modules relied on). `dub.json` builds with
`-allinst` to work around it.

## 4. Architecture

| Area | Rust | D port | |
|---|---|---|---|
| Provider abstraction | `LLMClient` trait with async methods. Providers are boxed trait objects. | `LLMClient` interface with blocking methods and a streaming delegate. Shorter, with no async colouring. | **D** for simplicity, **R** once concurrency is needed |
| JSON | serde derives typed structs. Malformed provider JSON fails at the boundary. | `std.json` `JSONValue` trees read by key. A missing field shows up wherever it's first read, as a `JSONException`. | **R** |
| Tool schemas | Hand-written JSON in both. | Same. | **=** |
| Permissions | A real shell parser (`shell.rs`). It fails closed on anything it can't parse. | Split on operators and match regexes. It is **weaker**: it misses commands inside `$(...)`, here-docs and quoted operators. Being replaced by a port of `shell.rs`. | **R** (for now) |
| Session log | Versioned and torn-line safe, with input IDs. | A header plus messages. | **R** |
| HTTP | reqwest and rustls, compiled in. Supply chain: 288 crates. | System libcurl (TLS from macOS). Supply chain: D standard library and libcurl only. | **D** on dependency surface, **R** on not needing a system library |
| Build | 68 s clean release, 46 s to rebuild one file (fat LTO, one codegen unit). | 3 s clean release, but it's a single compilation unit, so every change rebuilds everything. | **D** (at this size) |

## 5. Summary

- **Fixed while reviewing:** bounds checks were disabled in the D release build,
  and non-UTF-8 bash output was lost.
- **Where Rust is clearly stronger:** checking that is on by default (memory
  safety, `Send`/`Sync`, typed JSON, errors in signatures). Every one of these
  exists in D but is opt-in, and the first pass of the port didn't opt in.
- **Where D is stronger:** build speed, dependency surface, and simpler code at
  this size. The D core is 3.6k lines including tests. The matching Rust
  modules are 9.7k lines without tests, but they also do more (Copilot routing,
  capability probes, shell parsing), so this isn't a like-for-like ratio.
- **Concurrency (cancel, steer, ACP):** ported and tested live. No data
  races were found. One stdio-lock deadlock was found and fixed (section 3). D's
  thread safety depends on discipline (`shared` and mutexes are opt-in), but at
  this size that was manageable.
