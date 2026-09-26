#!/usr/bin/env node
// Set the nano-coder version in Cargo.toml and Cargo.lock (used by semantic-release).
// Usage: node scripts/set-version.mjs 1.2.3
import { readFileSync, writeFileSync } from 'node:fs';

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version ?? '')) {
  console.error(`usage: set-version.mjs X.Y.Z (got ${version})`);
  process.exit(1);
}

function replaceOnce(file, pattern, replacement) {
  const text = readFileSync(file, 'utf8');
  if (!pattern.test(text)) {
    console.error(`${file}: nano-coder version not found`);
    process.exit(1);
  }
  writeFileSync(file, text.replace(pattern, replacement));
}

// First `version` under [package].
replaceOnce('Cargo.toml', /^(\[package\][^[]*?\nversion\s*=\s*")[^"]+(")/m, `$1${version}$2`);
replaceOnce('Cargo.lock', /(\[\[package\]\]\nname = "nano-coder"\nversion = ")[^"]+(")/, `$1${version}$2`);
console.log(`nano-coder version set to ${version}`);
