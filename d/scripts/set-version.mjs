#!/usr/bin/env node
// Set the D port's version (`packageVersion` in d/source/app.d).
//
//   node d/scripts/set-version.mjs 0.2.0
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version ?? '')) {
  console.error('usage: set-version.mjs X.Y.Z');
  process.exit(2);
}
const file = join(dirname(fileURLToPath(import.meta.url)), '..', 'source/app.d');
const text = readFileSync(file, 'utf8');
const re = /^enum string packageVersion = "[^"]+";/m;
if (!re.test(text)) { console.error(`no packageVersion in ${file}`); process.exit(1); }
writeFileSync(file, text.replace(re, `enum string packageVersion = "${version}";`));
console.log(`d/source/app.d packageVersion = ${version}`);
