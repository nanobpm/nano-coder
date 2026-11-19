# Releasing nano-coder

Releases are cut automatically from `main` by
[semantic-release](https://semantic-release.gitbook.io/) in `.github/workflows/release.yml`.

## Commit messages

The repository only allows squash merges, and the PR title becomes the commit subject on
`main`. PR titles and every commit in a PR must follow
[Conventional Commits](https://www.conventionalcommits.org/): the `Commit messages` check runs
[commitlint](https://commitlint.js.org/) (`commitlint.config.mjs`, the conventional preset) on
both. Subjects start lowercase (`feat: add ...`, not `feat: Add ...`).

To check messages as you commit (needs Node), and run `scripts/ci.sh quick` before each
push, enable the hooks once per clone:

```sh
git config core.hooksPath .githooks
```

| Title | Release |
|---|---|
| `fix: ...`, `perf: ...` | patch (0.2.0 → 0.2.1) |
| `feat: ...` | minor (0.2.0 → 0.3.0) |
| `feat!: ...`, or a `BREAKING CHANGE:` footer | major (0.2.0 → 1.0.0) |
| `docs:`, `refactor:`, `test:`, `ci:`, `build:`, `chore:` | no release |

A scope is optional: `fix(sandbox): ...`.

## What happens on a push to main

1. semantic-release reads the commits since the last `v*` tag. If none calls for a release,
   the workflow stops.
2. Otherwise it sets `packageVersion` in `source/app.d` (`scripts/set-version.mjs`), commits `chore(release): X.Y.Z [skip ci]` to `main`, tags
   `vX.Y.Z`, and creates the GitHub release with generated notes. Released PRs and issues get
   a comment.
3. From the tag, the workflow:
   - runs `dub test` and builds `nano-coder` with LDC for macOS (arm64, x64) and Linux
     (arm64, x64, glibc ≥ 2.35), smoke-tests `--version`, and attaches the tarballs and
     `SHA256SUMS` to the release;
   - points the Homebrew formula at them (below);
   - publishes `@nanobpm/nano-coder-<os>-<cpu>` for each platform, then `@nanobpm/nano-coder`.

Publishing skips any npm package whose version is already on the registry, so a
failed publish job can simply be re-run.

To preview, run the workflow manually (`workflow_dispatch`) with `dry_run` left on. It
reports the next version, builds everything and runs `npm publish --dry-run`, but pushes,
tags and publishes nothing.

Don't bump versions or push `v*` tags by hand: semantic-release owns both.

## Branch protection and the release app

The `main` ruleset (Settings → Rules) requires a pull request, allows only squash merges,
blocks force-pushes and deletion, and requires the `test (ubuntu-24.04)`, `test (macos-15)`,
`lint` and `commitlint` checks (all in `ci.yml` and `commitlint.yml`). The only actor allowed to bypass it is the **release GitHub App**,
which semantic-release uses to push the `chore(release)` commit and tag. The workflow's own
`GITHUB_TOKEN` can't bypass a repository ruleset, and deploy keys are disabled in the org.

The workflow needs repository variable `RELEASE_APP_CLIENT_ID` and secret
`RELEASE_APP_PRIVATE_KEY`. To set up (or rotate) the app:

1. Create it at <https://github.com/organizations/nanobpm/settings/apps/new>: any unique
   name (e.g. `nanobpm-release`), homepage `https://github.com/nanobpm/nano-coder`, webhook
   **off**; repository permissions **Contents**, **Issues** and **Pull requests**:
   Read and write; installable only on this account.
2. On the app page note the **Client ID**, then **Generate a private key** (downloads a
   `.pem`).
3. **Install App** → nanobpm → *Only select repositories* → `nano-coder` and `homebrew-tap`.
4. Store the credentials, then delete the `.pem`:

   ```sh
   gh variable set RELEASE_APP_CLIENT_ID -R nanobpm/nano-coder --body <client-id>
   gh secret set RELEASE_APP_PRIVATE_KEY -R nanobpm/nano-coder < <app>.private-key.pem
   ```
5. Add the app to the ruleset's bypass list (Settings → Rules → `main` → Bypass list → add
   the app, *Always allow*).

## Homebrew tap

The `homebrew` job regenerates `Formula/nano-coder.rb` in
[nanobpm/homebrew-tap](https://github.com/nanobpm/homebrew-tap) from the release's `SHA256SUMS`
(`scripts/homebrew-formula.mjs`) and pushes it with the release app's token, so the app must be
installed on `homebrew-tap` too. Users install with `brew install nanobpm/tap/nano-coder`. To fix
the tap by hand (e.g. after a failed job), run the script locally against the release's
`SHA256SUMS` and push the result to the tap's `main`.

## Registry auth

npm uses trusted publishing (GitHub OIDC); there are no registry tokens. The publishers are
configured for repository `nanobpm/nano-coder`, workflow `release.yml`, so the workflow file
must keep that name:

- npmjs.com → each of the five `@nanobpm/nano-coder*` packages → Settings → Trusted
  Publisher (or `npm trust github @nanobpm/<pkg> --file release.yml --repo nanobpm/nano-coder`).

A new platform package doesn't exist on npm yet, so it can't have a trusted publisher. Publish
its first version locally (`node scripts/npm-packages.mjs --version X.Y.Z --binaries <dir>
--out npm-dist`, then `npm publish --access public` in its directory, with binaries from a
`dry_run` run: `gh run download <run-id> -p 'bin-*'`), then add the publisher.

## Binaries

`dub build -b release` links druntime and Phobos statically
(`-link-defaultlib-shared=false`; Debian's LDC links them shared by default). Bounds checks
stay on. The binary dynamically links only the system libcurl, plus libz on Linux, and the C
runtime. macOS ships libcurl; on Linux users need `libcurl4` (Debian/Ubuntu) or `libcurl`
(Fedora). A binary built on Ubuntu 22.04 runs on any glibc ≥ 2.35.

The npm launcher (`npm/nano-coder`) needs no install scripts: on its first run it replaces
itself with the native binary when the install directory is writable, and otherwise keeps
spawning it.

## Checking the packaging locally

```sh
dub build -b release
mkdir -p /tmp/bins && cp nano-coder /tmp/bins/nano-coder-darwin-arm64
node scripts/npm-packages.mjs --version "$(./nano-coder --version | cut -d' ' -f2)" --binaries /tmp/bins --out /tmp/npm-dist
npm pack --pack-destination /tmp /tmp/npm-dist/darwin-arm64 /tmp/npm-dist/nano-coder
npm install -g --prefix /tmp/prefix /tmp/nanobpm-nano-coder-*.tgz
/tmp/prefix/bin/nano-coder --version
```

## The Rust implementation

Up to 0.69.0 nano-coder was written in Rust and also published to crates.io. That code is on
the `rust` branch (tag `rust-final`); 0.69.0 tells cargo installs to switch to npm or Homebrew.
1.0.0, the first D release, came from a `feat!` commit. Only fixes go to the `rust` branch,
and nothing releases it automatically.

## Adding a platform

Add a row to the `build` matrix in `release.yml`, add the package name to `PLATFORMS` in
`npm/nano-coder/lib/platform.js` and to `TARGETS` in `scripts/npm-packages.mjs`, and add its block to `scripts/homebrew-formula.mjs`. Windows is not
supported yet (the terminal and process-group code is Unix-only).
