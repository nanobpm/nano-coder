# nano-coder-d

[nano-coder](https://github.com/nanobpm/nano-coder), reimplemented in D. It
reads the same config (`~/.config/nano-coder/config.toml`, `NANO_CODER_*`),
writes Rust-compatible session logs, and speaks the same ACP protocol. It
installs as a separate `nano-coder-d` command, so it can sit next to the Rust
`nano-coder`.

## Install

```sh
npm install -g @nanobpm/nano-coder-d
nano-coder-d --help
```

Prebuilt binaries cover macOS (arm64, x64) and Linux (arm64, x64, glibc 2.35+).
They link the system libcurl. macOS ships it; on Linux install `libcurl4`
(Debian/Ubuntu) or `libcurl` (Fedora).

## Build from source

You need [LDC](https://github.com/ldc-developers/ldc) 1.36+ and dub, plus the
libcurl development headers on Linux.

```sh
cd d
dub build -b release   # ./nano-coder-d
dub test               # unit tests
```

All code is `@safe`: every module starts with `@safe:`, and calls the
compiler can't check are wrapped in small `@trusted` functions (shared ones
live in `source/nano/safeio.d`). `scripts/check-safe.sh` runs before every
`dub build` and `dub test` and fails the build on a module without `@safe:`,
a `@system:`/`@trusted:` label, `@system` outside `extern (C)`, a `@trusted`
without a comment above it saying why it is safe, or more `@trusted` than the
budgets allow (`scripts/trusted-budget` outside `safeio.d`,
`scripts/trusted-budget-safeio` inside it). A value that may be absent is an
`Option!T` (`source/nano/option.d`), not a null class reference or a
`Nullable!`: check-safe caps null checks on class references, `Nullable!`
uses and class declarations (`scripts/class-null-budget`,
`scripts/nullable-budget`, `scripts/class-budget`), so prefer a struct, a
`SumType` or an always-present object. A field or global holding a class
reference is `NotNull!C`, `Option!C` or `@nullable("why") C`; the build
checks every module for this at compile time (`source/nano/nullaudit.d`). The build uses `-preview=dip1000`
and `-preview=nosharedaccess` and requires LDC 1.43 or later (dub rejects
DMD and GDC). CI also runs D-Scanner with the bug-finding checks in
`dscanner.ini`, and `.github/CODEOWNERS` routes changes to `safeio.d`, the
budgets and the build settings to the owner for review.

## Status

- `PORTING.md` maps every Rust module to its D counterpart and lists the known
  differences.
- `REVIEW.md` compares the safety and architecture of the two implementations.
- `RELEASING.md` explains how the npm packages are built and published.
