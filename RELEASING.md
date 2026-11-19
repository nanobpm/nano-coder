# Releasing the D port

The D port is released on its own, separately from the Rust `nano-coder`. It
has its own version (`packageVersion` in `source/app.d`), its own npm packages
and its own tags (`d-vX.Y.Z`). Nothing in it runs on a push to main.

## Packages

| Package | Contents |
|---|---|
| `@nanobpm/nano-coder-d` | The `nano-coder-d` launcher (`npm/nano-coder-d`). Its `optionalDependencies` list the platform packages at the same version. |
| `@nanobpm/nano-coder-d-<os>-<cpu>` | `bin/nano-coder-d` for darwin-arm64, darwin-x64, linux-arm64 or linux-x64. |

The launcher works like the Rust one. On its first run it replaces itself with
the native binary when the install directory is writable. Otherwise it keeps
spawning the binary. It needs no install scripts, so it is unaffected by npm 12
blocking lifecycle scripts.

## Binaries

`dub build -b release` links druntime and Phobos statically
(`-link-defaultlib-shared=false`; Debian's LDC links them shared by default).
Bounds checks stay on. The binary dynamically links only the system libcurl,
plus libz on Linux, and the C runtime. A binary built on Ubuntu 24.04 needs
only `GLIBC_2.34`, and runs on a clean Ubuntu 22.04 with `libcurl4` installed.

## Running a release

1. Run the **Release (D port)** workflow (`.github/workflows/release-d.yml`)
   with `version` and `dry_run` left on. It sets the version, runs `dub test`
   and builds a release binary on each platform. It then smoke-tests
   `--version`, packs the npm packages and runs `npm publish --dry-run`.
2. Run it again with `dry_run` off. It publishes the platform packages, then
   the main package, skipping any version already on npm. It then tags
   `d-vX.Y.Z` at the workflow's commit and creates a GitHub release with the
   tarballs and `SHA256SUMS`.

Optionally commit the version bump: `node d/scripts/set-version.mjs X.Y.Z`.

## One-time setup

npm trusted publishing (OIDC) has to be configured for each new package name
before the first real publish:
- `@nanobpm/nano-coder-d`
- `@nanobpm/nano-coder-d-darwin-arm64`
- `@nanobpm/nano-coder-d-darwin-x64`
- `@nanobpm/nano-coder-d-linux-arm64`
- `@nanobpm/nano-coder-d-linux-x64`

Each one names this repository and the `release-d.yml` workflow. Until that is
done, only the dry run works. A package that doesn't exist yet may need to be
published once by hand with a token first.

## Checking the packaging locally

```sh
cd d && dub build -b release
mkdir -p /tmp/bins && cp nano-coder-d /tmp/bins/nano-coder-d-darwin-arm64
node scripts/npm-packages.mjs --version 0.1.0 --binaries /tmp/bins --out /tmp/npm-dist
npm pack --pack-destination /tmp /tmp/npm-dist/darwin-arm64 /tmp/npm-dist/nano-coder-d
npm install -g --prefix /tmp/prefix /tmp/nanobpm-nano-coder-d-*.tgz
/tmp/prefix/bin/nano-coder-d --version
```
