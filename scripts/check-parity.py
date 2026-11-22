#!/usr/bin/env python3
"""Feature-parity check between the Rust crate and the D port.

The Rust test suite is the specification: each Rust test is one behaviour.
`parity/manifest.tsv` gives every Rust test a status:

  test     ported, and a D unittest carries a `// rust: FILE::NAME` marker
  claimed  ported according to PORTING.md, but no D test is linked yet
  gap      not ported (the note says what is missing)
  na       doesn't apply to the D port (the note says why)
  todo     not triaged yet

The check fails when
  * the Rust tree has a test the manifest doesn't list (a new Rust feature),
  * the manifest lists a test Rust no longer has,
  * a `test` row has no matching marker in source/, or a marker names a
    test the manifest doesn't mark `test`,
  * Rust commits touched src/ after parity/BASELINE (untriaged changes),
  * `todo` + `claimed` rows exceed parity/budget (a ratchet: lower it as
    rows are triaged or linked, never raise it).

Usage: scripts/check-parity.py [--ref REF] [--update]
--ref is the Rust ref to check against (default rust-final, where the Rust
code is frozen; main has been the D code since 1.0.0).
--update adds new Rust tests as `todo` and drops removed ones, then rewrites
the manifest sorted; it never changes an existing row's status.
"""
import os
import re
import subprocess
import sys

ROOT = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True,
                      check=True).stdout.strip()
D = ROOT
MANIFEST = os.path.join(D, 'parity', 'manifest.tsv')
BASELINE = os.path.join(D, 'parity', 'BASELINE')
BUDGET = os.path.join(D, 'parity', 'budget')
STATUSES = ['test', 'claimed', 'na', 'gap', 'todo']


def git(*args):
    return subprocess.run(['git', '-C', ROOT, *args], capture_output=True, text=True, check=True).stdout


def rust_tests(ref):
    """FILE::NAME for every #[test] / #[tokio::test] fn under src/ at `ref`."""
    out = set()
    for path in git('ls-tree', '-r', '--name-only', ref, 'src').split():
        if not path.endswith('.rs'):
            continue
        text = git('show', f'{ref}:{path}')
        rel = path[len('src/'):]
        for m in re.finditer(r'#\[(?:tokio::)?test[^\]]*\]\s*(?:#\[[^\]]*\]\s*)*(?:async\s+)?fn\s+([a-z0-9_]+)', text):
            out.add(f'{rel}::{m.group(1)}')
    return out


def d_markers():
    """`// rust: FILE::NAME` markers in source/ -> first location."""
    found = {}
    for dirpath, _, files in os.walk(os.path.join(D, 'source')):
        for f in sorted(files):
            if not f.endswith('.d'):
                continue
            p = os.path.join(dirpath, f)
            with open(p, encoding='utf-8') as fh:
                for i, line in enumerate(fh, 1):
                    for m in re.finditer(r'//\s*rust:\s*((?:[\w/.]+::\w+)(?:\s*,\s*[\w/.]+::\w+)*)', line):
                        for t in re.split(r'\s*,\s*', m.group(1)):
                            found.setdefault(t, f'{os.path.relpath(p, D)}:{i}')
    return found


def read_manifest():
    rows = {}
    with open(MANIFEST, encoding='utf-8') as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 2 or parts[1] not in STATUSES:
                sys.exit(f'{MANIFEST}:{n}: bad row: {line!r}')
            rows[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else '')
    return rows


def write_manifest(rows):
    with open(MANIFEST, 'w', encoding='utf-8') as f:
        f.write('# Rust test -> D port status; see scripts/check-parity.py. Columns: test, status, note\n')
        for k in sorted(rows):
            s, note = rows[k]
            f.write(f'{k}\t{s}\t{note}\n' if note else f'{k}\t{s}\n')


def main():
    ref = 'rust-final'
    if '--ref' in sys.argv:
        ref = sys.argv[sys.argv.index('--ref') + 1]
    rust = rust_tests(ref)
    rows = read_manifest() if os.path.exists(MANIFEST) else {}
    if '--update' in sys.argv:
        for t in rust - rows.keys():
            rows[t] = ('todo', '')
        for t in rows.keys() - rust:
            del rows[t]
        write_manifest(rows)
    errors = []
    errors += [f'new Rust test not in the manifest: {t}' for t in sorted(rust - rows.keys())]
    errors += [f'manifest lists a test Rust no longer has: {t}' for t in sorted(rows.keys() - rust)]
    markers = d_markers()
    for t, (s, _) in sorted(rows.items()):
        if s == 'test' and t not in markers:
            errors.append(f'{t} is marked test but no D unittest has `// rust: {t}`')
    for t, where in sorted(markers.items()):
        if rows.get(t, ('',))[0] != 'test':
            errors.append(f'{where}: marker for {t}, which the manifest does not mark test')
    with open(BASELINE) as fh:
        base = fh.read().split()[0]
    pending = git('log', '--oneline', f'{base}..{ref}', '--', 'src').strip()
    if pending:
        errors.append(f'Rust commits since the triaged baseline {base} (port or mark them n/a, then move '
                      'parity/BASELINE):\n  ' + pending.replace('\n', '\n  '))
    counts = {s: 0 for s in STATUSES}
    for s, _ in rows.values():
        counts[s] += 1
    open_rows = counts['todo'] + counts['claimed']
    with open(BUDGET) as fh:
        budget = int(fh.read().split()[0])
    if open_rows > budget:
        errors.append(f'todo + claimed = {open_rows}, over the budget of {budget}')
    print(f'parity vs {ref}: {len(rust)} Rust tests: ' + ', '.join(f'{k} {counts[k]}' for k in STATUSES)
          + f' (todo + claimed budget {budget})')
    for e in errors:
        print('error:', e)
    if open_rows < budget and not errors:
        print(f'note: todo + claimed is {open_rows}; lower parity/budget to {open_rows}')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
