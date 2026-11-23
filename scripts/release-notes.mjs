#!/usr/bin/env node
// Write source/release-notes.json: the user-facing changes of every release,
// compiled into nano-coder so it can say what changed after an update.
//
//   node scripts/release-notes.mjs X.Y.Z           write the notes, including X.Y.Z
//   node scripts/release-notes.mjs --check         fail when the committed file
//                                                  differs from git (tagged versions)
//   options: --repo DIR (default: this checkout), --out FILE, --cap N (default 100)
//
// For each `vX.Y.Z` tag, plus the version being released when it has no tag
// yet (its range ends at HEAD), the conventional-commit subjects of the
// squash merges since the previous version are read. `feat`, `fix` and `perf`
// are kept, as is any breaking change (`type!:` or a `BREAKING CHANGE` footer);
// everything else (chore, docs, test, ci, refactor, build, style, ...) is
// dropped. The PR number comes from the subject's trailing `(#N)`.
//
// Output is deterministic: versions newest first, items in git order, dates
// from the commits themselves, and only the newest `cap` versions.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION_RE = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;
const KEPT = new Set(['feat', 'fix', 'perf']);

/** Compares two versions (no leading `v`); a release sorts after its pre-releases. */
export function compareVersions(a, b) {
  const split = (v) => {
    const [core, pre] = v.split(/-(.*)/s);
    return { nums: core.split('.').map((n) => Number(n) || 0), pre: pre ?? '' };
  };
  const x = split(a);
  const y = split(b);
  for (let i = 0; i < Math.max(x.nums.length, y.nums.length); i++) {
    const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0);
    if (d) return d < 0 ? -1 : 1;
  }
  if (x.pre === y.pre) return 0;
  if (!x.pre) return 1;
  if (!y.pre) return -1;
  return x.pre < y.pre ? -1 : 1;
}

/**
 * The user-facing item for one commit, or null when it is dropped.
 * `subject` is the first line, `body` the rest of the message.
 */
export function parseCommit(subject, body = '') {
  const m = /^([a-zA-Z]+)(?:\(([^)]*)\))?(!)?:\s*(.+)$/.exec(subject.trim());
  if (!m) return null;
  const type = m[1].toLowerCase();
  const breaking = !!m[3] || /^BREAKING[ -]CHANGE:/m.test(body);
  if (!KEPT.has(type) && !breaking) return null;
  let title = m[4].trim();
  let pr = null;
  const p = /\s*\(#(\d+)\)$/.exec(title);
  if (p) {
    pr = Number(p[1]);
    title = title.slice(0, p.index).trim();
  }
  const item = { type: KEPT.has(type) ? type : 'feat', scope: m[2] ? m[2].trim() : '', title, pr };
  if (breaking) item.breaking = true;
  return item;
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
}

/** The `vX.Y.Z` tags of `repo`, oldest version first (without the `v`). */
export function releaseTags(repo) {
  return git(repo, ['tag', '--list', 'v*'])
    .split('\n')
    .map((t) => t.trim())
    .filter((t) => VERSION_RE.test(t.slice(1)))
    .map((t) => t.slice(1))
    .sort(compareVersions);
}

/** The notes for the range `from..to` (git revisions; `from` may be null). */
function rangeNotes(repo, from, to) {
  const range = from ? `${from}..${to}` : to;
  const out = git(repo, ['log', '--format=%cs%x1f%s%x1f%b%x1e', range]);
  const items = [];
  let date = '';
  for (const rec of out.split('\x1e')) {
    const r = rec.replace(/^\n/, '');
    if (!r.trim()) continue;
    const [d, subject, body = ''] = r.split('\x1f');
    if (/^chore\(release\)/.test(subject)) continue;
    if (!date) date = d;
    const item = parseCommit(subject, body);
    if (item) items.push(item);
  }
  if (!date) date = git(repo, ['log', '-1', '--format=%cs', to]).trim();
  return { date, items };
}

/**
 * Every release's notes, newest first, capped at `cap` versions. `version`
 * (optional) is the version being released: without a tag yet, its range
 * ends at HEAD.
 */
export function buildNotes(repo, { version = null, cap = 100, taggedOnly = false } = {}) {
  const tags = releaseTags(repo);
  const all = tags.map((v) => ({ version: v, ref: `v${v}` }));
  if (!taggedOnly && version && !tags.includes(version)) all.push({ version, ref: 'HEAD' });
  all.sort((a, b) => compareVersions(a.version, b.version));
  const start = Math.max(0, all.length - cap);
  const out = [];
  for (let i = start; i < all.length; i++) {
    const prev = i > 0 ? all[i - 1].ref : null;
    const { date, items } = rangeNotes(repo, prev, all[i].ref);
    out.push({ version: all[i].version, date, items });
  }
  return out.reverse();
}

/** The file's text: stable formatting, one item per line. */
export function formatNotes(notes) {
  const rel = notes.map((r) => {
    const items = r.items.map((it) => '      ' + JSON.stringify(it));
    const list = items.length ? `[\n${items.join(',\n')}\n    ]` : '[]';
    return `    {"version": ${JSON.stringify(r.version)}, "date": ${JSON.stringify(r.date)}, "items": ${list}}`;
  });
  return `{\n  "releases": [\n${rel.join(',\n')}\n  ]\n}\n`;
}

function main(argv) {
  const here = join(dirname(fileURLToPath(import.meta.url)), '..');
  let repo = here;
  let out = null;
  let cap = 100;
  let check = false;
  let version = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo') repo = argv[++i];
    else if (a === '--out') out = argv[++i];
    else if (a === '--cap') cap = Number(argv[++i]);
    else if (a === '--check') check = true;
    else if (VERSION_RE.test(a)) version = a;
    else {
      console.error('usage: release-notes.mjs X.Y.Z | --check [--repo DIR] [--out FILE] [--cap N]');
      return 2;
    }
  }
  if (!Number.isInteger(cap) || cap < 1) { console.error('--cap needs a positive number'); return 2; }
  out ??= join(repo, 'source', 'release-notes.json');
  if (check) {
    // Versions without a tag (the unreleased tail of a dry run) are ignored.
    const tags = new Set(releaseTags(repo));
    const committed = JSON.parse(readFileSync(out, 'utf8'));
    if (!Array.isArray(committed.releases)) { console.error(`${out}: no "releases" array`); return 1; }
    const kept = committed.releases.filter((r) => tags.has(r.version));
    const want = formatNotes(buildNotes(repo, { cap, taggedOnly: true }).slice(0, kept.length || undefined));
    const have = formatNotes(kept);
    if (want !== have) {
      console.error(`${out} is not what git says; regenerate it with scripts/release-notes.mjs <version>`);
      return 1;
    }
    console.log(`${out}: ${kept.length} released versions match git`);
    return 0;
  }
  if (!version) { console.error('usage: release-notes.mjs X.Y.Z'); return 2; }
  const notes = buildNotes(repo, { version, cap });
  writeFileSync(out, formatNotes(notes));
  console.log(`${out}: ${notes.length} versions, newest ${notes[0]?.version ?? 'none'}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) process.exitCode = main(process.argv.slice(2));
export { main };
