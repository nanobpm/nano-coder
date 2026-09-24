# Releasing nano-coder

1. Bump `version` in `Cargo.toml`, run `cargo build` so `Cargo.lock` follows, and merge that.
2. Tag the merge commit `vX.Y.Z` and push the tag. `.github/workflows/release.yml` then:
   - builds `nano-coder` for macOS (arm64, x64) and Linux (arm64, x64, glibc ≥ 2.35);
   - creates a GitHub release with tarballs and `SHA256SUMS`;
   - publishes the crate `nano-coder` to crates.io;
   - publishes `@nanobpm/nano-coder-<os>-<cpu>` for each platform, then `@nanobpm/nano-coder`.

To check a release without publishing, run the workflow manually (`workflow_dispatch`) with
`dry_run` left on. It builds everything and runs `npm publish --dry-run`.

Publishing skips any crate or npm package whose version is already on the registry, so a
failed release can be re-run, and a tag can be pushed for a version that was published locally.

## Registry auth

Both registries use trusted publishing (GitHub OIDC), so no long-lived tokens are needed once
it is set up. A trusted publisher can only be added to a package that already exists, so the
first release needs one of these:

- **Secrets:** add `CARGO_REGISTRY_TOKEN` (crates.io token with publish-new scope) and
  `NPM_TOKEN` (npm automation token with publish rights on the `@nanobpm` scope) as repository
  secrets. When they are set the workflow uses them.
- **Local:** `cargo login` then `cargo publish`; for npm, run
  `node scripts/npm-packages.mjs --version X.Y.Z --binaries <dir> --out npm-dist` and
  `npm publish --access public` in each `npm-dist/*` directory (platform packages first).
  0.1.0 was published this way, using the binaries from a `dry_run` workflow run
  (`gh run download <run-id> -p 'bin-*'`).

Then configure trusted publishing and remove the tokens:

- crates.io → `nano-coder` → Settings → Trusted Publishing: repository `nanobpm/nano-coder`,
  workflow `release.yml`.
- npmjs.com → each of the five packages → Settings → Trusted Publisher: GitHub Actions,
  repository `nanobpm/nano-coder`, workflow `release.yml`.

## Adding a platform

Add a row to the `build` matrix in `release.yml`, add the package name to `PLATFORMS` in
`npm/nano-coder/lib/platform.js` and to `TARGETS` in `scripts/npm-packages.mjs`. Windows is not
supported yet (the terminal and process-group code is Unix-only).
