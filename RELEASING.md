# Releasing nano-coder

Releases are cut automatically from `main` by
[semantic-release](https://semantic-release.gitbook.io/) in `.github/workflows/release.yml`.

## Commit messages

PRs are squash-merged, and the PR title becomes the commit subject, so PR titles must follow
[Conventional Commits](https://www.conventionalcommits.org/). The `PR title` check enforces it.

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
2. Otherwise it sets the version in `Cargo.toml` and `Cargo.lock`
   (`scripts/set-version.mjs`), commits `chore(release): X.Y.Z [skip ci]` to `main`, tags
   `vX.Y.Z`, and creates the GitHub release with generated notes. Released PRs and issues get
   a comment.
3. From the tag, the workflow:
   - builds `nano-coder` for macOS (arm64, x64) and Linux (arm64, x64, glibc ≥ 2.35) and
     attaches the tarballs and `SHA256SUMS` to the release;
   - publishes the crate `nano-coder` to crates.io;
   - publishes `@nanobpm/nano-coder-<os>-<cpu>` for each platform, then `@nanobpm/nano-coder`.

Publishing skips any crate or npm package whose version is already on the registry, so a
failed publish job can simply be re-run.

To preview, run the workflow manually (`workflow_dispatch`) with `dry_run` left on. It
reports the next version, builds everything and runs `npm publish --dry-run`, but pushes,
tags and publishes nothing.

Don't bump versions or push `v*` tags by hand: semantic-release owns both.

## Registry auth

Both registries use trusted publishing (GitHub OIDC); there are no registry tokens. The
publishers are configured for repository `nanobpm/nano-coder`, workflow `release.yml`, so the
workflow file must keep that name:

- crates.io → `nano-coder` → Settings → Trusted Publishing.
- npmjs.com → each of the five `@nanobpm/nano-coder*` packages → Settings → Trusted
  Publisher (or `npm trust github @nanobpm/<pkg> --file release.yml --repo nanobpm/nano-coder`).

A new platform package doesn't exist on npm yet, so it can't have a trusted publisher. Publish
its first version locally (`node scripts/npm-packages.mjs --version X.Y.Z --binaries <dir>
--out npm-dist`, then `npm publish --access public` in its directory, with binaries from a
`dry_run` run: `gh run download <run-id> -p 'bin-*'`), then add the publisher.

## Adding a platform

Add a row to the `build` matrix in `release.yml`, add the package name to `PLATFORMS` in
`npm/nano-coder/lib/platform.js` and to `TARGETS` in `scripts/npm-packages.mjs`. Windows is not
supported yet (the terminal and process-group code is Unix-only).
