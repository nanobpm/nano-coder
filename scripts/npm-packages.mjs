#!/usr/bin/env node
// Assemble the npm packages for a release.
//
//   node scripts/npm-packages.mjs --version 0.1.0 --binaries <dir> --out <dir>
//
// <dir> holds one native binary per platform, named `nano-coder-<os>-<cpu>`
// (e.g. nano-coder-darwin-arm64). Writes <out>/<os>-<cpu>/ platform packages and
// <out>/nano-coder/ (the main package, pinned to the same version). Platforms
// without a binary are skipped (and left out of optionalDependencies).
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, chmodSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { values } = parseArgs({ options: { version: { type: 'string' }, binaries: { type: 'string' }, out: { type: 'string' } } });
const { version, binaries, out } = values;
if (!version || !binaries || !out) {
  console.error('usage: npm-packages.mjs --version X.Y.Z --binaries <dir> --out <dir>');
  process.exit(2);
}
const cargoVersion = readFileSync(join(root, 'Cargo.toml'), 'utf8').match(/^version\s*=\s*"([^"]+)"/m)?.[1];
if (cargoVersion !== version) {
  console.error(`version ${version} does not match Cargo.toml (${cargoVersion})`);
  process.exit(1);
}

const main = JSON.parse(readFileSync(join(root, 'npm/nano-coder/package.json'), 'utf8'));
const TARGETS = [['darwin', 'arm64'], ['darwin', 'x64'], ['linux', 'arm64'], ['linux', 'x64']];
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const optional = {};
for (const [os, cpu] of TARGETS) {
  const src = join(binaries, `nano-coder-${os}-${cpu}`);
  if (!existsSync(src)) { console.warn(`skipping ${os}-${cpu}: no ${src}`); continue; }
  const name = `@nanobpm/nano-coder-${os}-${cpu}`;
  const dir = join(out, `${os}-${cpu}`);
  mkdirSync(join(dir, 'bin'), { recursive: true });
  copyFileSync(src, join(dir, 'bin', 'nano-coder'));
  chmodSync(join(dir, 'bin', 'nano-coder'), 0o755);
  writeFileSync(join(dir, 'package.json'), `${JSON.stringify({
    name, version,
    description: `nano-coder native binary for ${os}-${cpu}`,
    license: main.license, repository: main.repository, homepage: main.homepage,
    os: [os], cpu: [cpu],
    files: ['bin/'],
  }, null, 2)}\n`);
  optional[name] = version;
}
if (!Object.keys(optional).length) { console.error('no binaries found'); process.exit(1); }

const mainDir = join(out, 'nano-coder');
cpSync(join(root, 'npm/nano-coder'), mainDir, { recursive: true });
copyFileSync(join(root, 'README.md'), join(mainDir, 'README.md'));
writeFileSync(join(mainDir, 'package.json'), `${JSON.stringify({ ...main, version, optionalDependencies: optional }, null, 2)}\n`);
console.log(JSON.stringify({ version, packages: [...Object.keys(optional), main.name] }));
