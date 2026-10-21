# Rust vs D: safety and architecture review

This compares the Rust `nano-coder` with its D port in `d/`. The port now covers
everything listed in `PORTING.md`. It is about 33k lines of D including 302
unit-test blocks, against about 72k lines of Rust including inline tests. The
known differences are listed in `PORTING.md`. Performance numbers are in
`bench/results.json` (from `bench/run.py`) and in section 6.

Each finding is rated **R** (Rust is stronger), **D** (D is stronger), or
**=** (about the same).

## 1. Memory safety

| | Rust | D port |
|---|---|---|
| Default | Safe. 27 `unsafe` blocks outside tests, all FFI: signals, `ioctl` window size, `setsid`/`killpg`, Landlock and Seatbelt syscalls. | Opt-in. 35 of 65 modules start with `@safe:`; this covers everything ported after the first pass, including shell parsing, permissions, the sandbox and Landlock, the TUI and the frame renderer. The other 30 (17k lines) are still `@system`. These include the agent loop, HTTP, the providers, config, sessions, ACP, and the bash and file tools. There are 357 `@trusted` annotations, many of them on whole functions that touch `std.json`, which isn't `@safe`. **R** |
| Use-after-free and double free | Prevented by ownership. | Prevented in practice by the GC; the port does no manual memory management. **=** |
| Bounds checks | Always on; an overrun is a panic. | Found in the first review: dub's `release` build type turned them off in `@system` code. They are on again (`-boundscheck=on`), so an overrun is an `Error` that ends the process, like a panic. **=** |
| Casts | `as` only between numeric types. Reinterpreting bytes as `str` needs `from_utf8` or `unsafe`. | 221 `cast(...)` expressions, mostly numeric and FFI. Bytes from the network and from tools go through `lossyUtf8`/validation, but the compiler doesn't make that happen. **R** |
| Invalid UTF-8 | `String::from_utf8_lossy` on tool output. | `lossyUtf8` (U+FFFD replacement) on tool output. Missing it was a review finding, now fixed. **=** |

Recommended: retrofit `@safe:` onto the remaining 30 modules, starting with
`tools/*`, `http.d` and `agent.d`. Then push `@trusted` down from whole
functions to the individual `std.json` and FFI calls.

## 2. Error handling

| | Rust | D port |
|---|---|---|
| Model | `Result<T, anyhow::Error>` in every signature. A call that can fail can't be ignored without `?` or a visible `unwrap`. | Exceptions. A function's signature doesn't say whether it can fail. **R** |
| Panics and crashes | 108 `unwrap`/`expect` and 0 `panic!` outside tests. | D's `Error`s (bounds, assert, out of memory) are not `Exception`s, so they end the process, like an uncaught panic. **=** |
| Tool failures | Typed `ToolError` returned to the model. | Same, plus any other `Exception` becomes "`<tool>` failed: …". **=** |
| Being explicit | Every fallible step shows. | 178 `catch (Exception)` blocks. Most turn failures into Rust's messages or fall back (best-effort file reads, probes), but nothing distinguishes the deliberate ones from the careless ones. **R** |

## 3. Concurrency

Rust runs on tokio. Anything shared between tasks must be `Send`/`Sync`, so
data races don't compile.

The D port uses plain threads:
- a turn runs on the main thread;
- a key or stdin reader thread routes cancel, steer, `/queue` and ACP messages;
- an atomic cancel flag is polled by libcurl's progress callback and the bash
  wait loop;
- the agent waits on a broker when the `question` tool runs;
- a progress thread drives the status bar.

Shared state goes through mutexes, `shared` and atomics. There are 9
`__gshared` globals, all for the terminal and status bar. None of this is
checked the way `Send`/`Sync` is. **R**

Bugs found:
- **The stdio lock deadlock.** A reader thread blocked in `readln` holds
  stdin's `FILE` lock, and `spawnProcess` flushes (and so locks) every stdio
  stream before forking, so the first bash call hung. The fix reads fd 0 with
  raw `read(2)`. Rule: threads that block on input must not use `std.stdio`.
  This is lock ordering, so `Send`/`Sync` wouldn't have caught it either, but
  Phobos hiding a global lock makes it a D-specific hazard.
- **No `pre_exec` in `std.process`.** Rust applies Landlock in a `pre_exec`
  hook. D can't run code between fork and exec, and doing that by hand in a
  multi-threaded GC'd process isn't async-signal-safe anyway. So the sandboxed
  argv re-executes the binary with an internal `--landlock-exec` flag; that
  single-threaded process restricts itself and `execvp`s the shell. It costs
  one extra exec per sandboxed command and is easier to reason about than a
  fork hook.

## 4. Architecture

| Area | Rust | D port | |
|---|---|---|---|
| Provider abstraction | `LLMClient` trait with async methods. | `LLMClient` interface with blocking methods and a streaming delegate. Cancellation goes through a flag, not future drops. | **=** |
| JSON | serde derives typed structs. Malformed provider JSON fails at the boundary. | `std.json` `JSONValue` trees read by key. A missing field shows up wherever it's first read. `std.json` also isn't `@safe`, which is the main source of `@trusted`. | **R** |
| Permissions | `shell.rs` parser that fails closed. | A port of `shell.rs` with Rust's tests (`nano/shell.d`, `nano/permissions.d`). | **=** |
| Sandbox | Seatbelt and Landlock. | Seatbelt and Landlock, with Rust's containment tests run against the real OS sandbox. On Linux they were verified in a container (section 3 explains the exec helper). | **=** |
| Session log | Versioned and torn-line safe, with input IDs. | The same format; `--list-sessions --json` output is byte-identical to Rust's. | **=** |
| HTTP | reqwest and rustls, compiled in. Supply chain: 288 crates. | System libcurl. Supply chain: Phobos and libcurl (plus libz on Linux). | **D** on dependency surface, **R** on not needing a system library |
| Packaging | One static binary per platform. | One binary per platform with druntime and Phobos static. It needs the system libcurl (bundled on macOS, `libcurl4` on Linux). Finding: Debian/Ubuntu's LDC links Phobos as a shared library by default, so the release build forces `-link-defaultlib-shared=false` and links libz. | **R** |
| Build | 64 s clean release, 43 s to rebuild one file (fat LTO). | 12 s clean release. It is one compilation unit, so touching one file also takes 12 s. | **D** |

Toolchain notes:
- LDC 1.43 dropped a template instance that other modules needed, which broke
  the link. `dub.json` builds with `-allinst` to work around it.
- The code also builds with LDC 1.36 (Ubuntu 24.04).

## 5. Summary

- **Where Rust is stronger:** checking that is on by default (memory safety,
  `Send`/`Sync`, typed JSON, errors in signatures). D has each of these, but
  only as an opt-in. Half the port opted in to `@safe`, and none of it gets
  thread-safety checking from the compiler.
- **Where D is stronger:** build time (about 5x faster for a clean release
  build and 3.5x for an edit) and a much smaller dependency surface.
- **Same:** behaviour. The tool names, schemas and messages, the session
  format, the permission and sandbox policy, and ACP all match Rust, and
  Rust's test cases are ported for the security-relevant modules.

## 6. Performance

Measured with `bench/run.py --runs 10` at `c431373` on an Apple M4 Pro, using
rustc 1.97.0 and LDC 1.43.0. The task is a scripted glob, read, edit, bash,
grep and final answer against a local mock model, so only the harness is
measured. Figures are medians.

| | Rust | D |
|---|---|---|
| Clean release build | 63.8 s | 12.1 s |
| Rebuild after touching one file (release) | 42.8 s | 11.9 s |
| Clean debug build / touch one file | 26.4 s / 1.8 s | 4.7 s / 4.0 s |
| Binary size (stripped) | 6.0 MB | 4.8 MB |
| Task wall time | 70 ms | 70 ms |
| Task peak RSS | 14.1 MB | 13.4 MB |
| Task peak footprint | 5.3 MB | 4.3 MB |
| Task instructions retired | 131 M | 234 M |
| Idle start and exit: instructions | 58 M | 191 M |

D retires more instructions without being slower in wall time. Most of that
is fixed start-up cost:
- A trivial D "hello" retires 70M instructions (78M with libcurl), against
  11M for a C one, before any nano-coder code runs.
- `--version` alone retires 173M.

Worth a look if start-up matters (many short `-p` runs from a fleet): module
constructors, `-allinst` bloat and GC start-up options.
