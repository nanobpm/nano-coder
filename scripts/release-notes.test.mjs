// Tests for release-notes.mjs on a fixture git history (run by scripts/ci.sh):
//   node --test scripts/release-notes.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildNotes, compareVersions, formatNotes, main, parseCommit } from './release-notes.mjs';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'release-notes-'));
  const env = { ...process.env, GIT_AUTHOR_DATE: '2026-01-02T03:04:05Z', GIT_COMMITTER_DATE: '2026-01-02T03:04:05Z' };
  for (const k of Object.keys(env)) if (k.startsWith('GIT_') && !k.endsWith('_DATE')) delete env[k];
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8', env });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 't@example.com');
  git('config', 'user.name', 't');
  git('config', 'commit.gpgsign', 'false');
  git('config', 'tag.gpgsign', 'false');
  let n = 0;
  const commit = (msg) => {
    writeFileSync(join(dir, 'f'), String(n++));
    git('add', 'f');
    git('commit', '-q', '-m', msg);
  };
  return { dir, git, commit, done: () => rmSync(dir, { recursive: true, force: true }) };
}

test('compareVersions orders numerically, releases after pre-releases', () => {
  assert.equal(compareVersions('1.10.0', '1.9.2'), 1);
  assert.equal(compareVersions('1.0.0', '1.0.0'), 0);
  assert.equal(compareVersions('1.0.0-rc.1', '1.0.0'), -1);
  assert.equal(compareVersions('0.9.0', '0.10.0'), -1);
});

test('parseCommit keeps feat/fix/perf and breaking changes, drops the rest', () => {
  assert.deepEqual(parseCommit('feat(ui): a thing (#12)'), { type: 'feat', scope: 'ui', title: 'a thing', pr: 12 });
  assert.deepEqual(parseCommit('fix: b'), { type: 'fix', scope: '', title: 'b', pr: null });
  assert.equal(parseCommit('perf: faster (#3)').type, 'perf');
  for (const t of ['chore', 'docs', 'test', 'ci', 'refactor', 'build', 'style']) assert.equal(parseCommit(`${t}: x (#1)`), null, t);
  assert.equal(parseCommit('not conventional'), null);
  assert.deepEqual(parseCommit('refactor(api)!: rename (#9)'), { type: 'feat', scope: 'api', title: 'rename', pr: 9, breaking: true });
  assert.equal(parseCommit('chore: drop x', 'details\n\nBREAKING CHANGE: x is gone').breaking, true);
  assert.equal(parseCommit('feat!: big').breaking, true);
});

test('buildNotes reads multiple versions, the unreleased tail and the cap', () => {
  const f = fixture();
  try {
    f.commit('feat: first (#1)');
    f.git('tag', 'v0.1.0');
    f.commit('fix(core): second (#2)');
    f.commit('docs: words (#3)');
    f.commit('chore(release): 0.1.1 [skip ci]');
    f.git('tag', 'v0.1.1');
    f.commit('ci: nothing (#4)');
    f.git('tag', 'v0.2.0');
    f.commit('perf: quick (#5)');
    f.commit('chore: tidy\n\nBREAKING CHANGE: config moved');
    const notes = buildNotes(f.dir, { version: '0.3.0' });
    assert.deepEqual(notes.map((r) => r.version), ['0.3.0', '0.2.0', '0.1.1', '0.1.0']);
    assert.deepEqual(notes[0].items, [
      { type: 'feat', scope: '', title: 'tidy', pr: null, breaking: true },
      { type: 'perf', scope: '', title: 'quick', pr: 5 },
    ]);
    assert.deepEqual(notes[1].items, [], 'a version with no user-facing change is still listed');
    assert.deepEqual(notes[2].items, [{ type: 'fix', scope: 'core', title: 'second', pr: 2 }]);
    assert.equal(notes[3].items[0].pr, 1);
    assert.equal(notes[0].date, '2026-01-02');
    // The cap keeps the newest versions; the oldest kept still starts at its predecessor.
    const capped = buildNotes(f.dir, { version: '0.3.0', cap: 2 });
    assert.deepEqual(capped.map((r) => r.version), ['0.3.0', '0.2.0']);
    // A tagged version adds no tail.
    assert.deepEqual(buildNotes(f.dir, { version: '0.2.0' }).map((r) => r.version), ['0.2.0', '0.1.1', '0.1.0']);
    // Deterministic: the same history gives the same bytes.
    assert.equal(formatNotes(buildNotes(f.dir, { version: '0.3.0' })), formatNotes(notes));
    JSON.parse(formatNotes(notes));
  } finally {
    f.done();
  }
});

test('releaseTags ignores tags that are not ancestors of HEAD', () => {
  const f = fixture();
  try {
    f.commit('feat: first (#1)');
    f.git('tag', 'v0.1.0');
    f.git('checkout', '-q', '-b', 'other');
    f.commit('feat: elsewhere (#2)');
    f.git('tag', 'v0.2.0');
    f.git('checkout', '-q', 'main');
    f.commit('fix: here (#3)');
    const notes = buildNotes(f.dir, { version: '0.1.1' });
    assert.deepEqual(notes.map((r) => r.version), ['0.1.1', '0.1.0']);
    assert.deepEqual(notes[0].items, [{ type: 'fix', scope: '', title: 'here', pr: 3 }]);
  } finally {
    f.done();
  }
});

test('--check accepts the generated file and ignores the unreleased tail, rejects a change', () => {
  const f = fixture();
  const log = console.log;
  const err = console.error;
  console.log = console.error = () => {};
  try {
    f.commit('feat: one (#1)');
    f.git('tag', 'v1.0.0');
    f.commit('fix: two (#2)');
    const out = join(f.dir, 'notes.json');
    assert.equal(main(['1.0.1', '--repo', f.dir, '--out', out]), 0);
    assert.equal(main(['--check', '--repo', f.dir, '--out', out]), 0);
    const j = JSON.parse(readFileSync(out, 'utf8'));
    j.releases[1].items[0].title = 'edited';
    writeFileSync(out, formatNotes(j.releases));
    assert.equal(main(['--check', '--repo', f.dir, '--out', out]), 1);
    // Deleting the oldest tagged release is caught.
    f.commit('feat: three (#3)');
    f.git('tag', 'v1.0.1');
    assert.equal(main(['1.0.2', '--repo', f.dir, '--out', out]), 0);
    assert.equal(main(['--check', '--repo', f.dir, '--out', out]), 0);
    const full = JSON.parse(readFileSync(out, 'utf8')).releases;
    writeFileSync(out, formatNotes(full.slice(0, -1)));
    assert.equal(main(['--check', '--repo', f.dir, '--out', out]), 1, 'oldest release deleted');
    // An untagged entry that is not the newest is rejected.
    writeFileSync(out, formatNotes([full[1], full[0], full[2]]));
    assert.equal(main(['--check', '--repo', f.dir, '--out', out]), 1, 'untagged in the middle');
  } finally {
    console.log = log;
    console.error = err;
    f.done();
  }
});
