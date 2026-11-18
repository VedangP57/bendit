#!/usr/bin/env python3
"""Freeze an eval's inputs before the first run, and verify them after.

An eval answers "does this rule change what the agent does". That answer is
worth nothing if the hook, the skill text, the case or the grader moved while
the runs were happening -- and the way that happens is not fraud, it is
tinkering: a grader that looked wrong gets adjusted on run 7 and nobody writes
it down.

    eval-freeze.py freeze  <name> [--note "the exact eval command, and why"]
    eval-freeze.py verify  <name>

`freeze` records the sha256 of every file that can move a score (see WATCHED:
the plugin manifest, hooks/hooks.json, scripts/*.py and *.sh, everything under
skills/ and commands/, every case.yaml and fixture.sh under evals/), plus the
git commit, whether the tree was dirty, and the watch list itself, into
evals/freezes/<name>.json.

`verify` re-hashes and fails if any watched file changed, appeared or vanished.
It uses the watch list the FREEZE recorded, not today's, so widening WATCHED
later never turns an old, honest freeze into a false failure.

Run freeze, then the eval, then verify, and quote the number only if verify
passed. The root is the plugin directory this script sits in, so a copy of the
plugin (an ablation arm) is frozen by running the copy's own script.

Both commands refuse rather than pass on an empty manifest: a freeze of nothing
would verify forever.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent      # the plugin directory
FREEZES = ROOT / 'evals' / 'freezes'

# Everything whose contents could change a score. A file added or removed is a
# change too, so the manifest is a set of paths, not just a bag of hashes.
#
# Versioned: each freeze records the version AND the patterns it used. Never
# edit a published version -- add a new one and point WATCH_VERSION at it.
WATCH_VERSIONS = {
    1: (
        ('.claude-plugin', 'plugin.json'),   # userConfig defaults, component paths
        ('hooks', 'hooks.json'),             # which hooks run, on what, how long
        ('scripts', '*.py'),                 # the hooks themselves, and graders
        ('scripts', '*.sh'),
        ('skills', '**/*'),                  # SKILL.md and its references
        ('commands', '**/*'),
        ('evals', '**/case.yaml'),           # prompts, graders, controls
        ('evals', '**/fixture.sh'),          # the workspace the agent sees
    ),
}
WATCH_VERSION = 1
WATCHED = WATCH_VERSIONS[WATCH_VERSION]

# Never inputs: caches, run output, and the freezes themselves.
SKIP_PARTS = {'__pycache__', 'node_modules', '.DS_Store', 'results', 'freezes'}


def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def manifest(watched) -> dict:
    out = {}
    for sub, pattern in watched:
        base = ROOT / sub
        if not base.is_dir():
            continue
        for p in sorted(base.glob(pattern)):
            rel = p.relative_to(ROOT)
            if p.is_file() and not SKIP_PARTS.intersection(rel.parts):
                out[rel.as_posix()] = digest(p)
    return out


def git(*args: str):
    try:
        r = subprocess.run(['git', *args], cwd=ROOT, capture_output=True,
                           text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def provenance() -> dict:
    head = git('rev-parse', 'HEAD')
    status = git('status', '--porcelain', '--', '.')
    return {
        'commit': head.strip() if head else 'unknown',
        # A commit pins only committed files. Dirty means the hashes, not the
        # commit, are the record of what ran.
        'dirty': 'unknown' if status is None else bool(status.strip()),
    }


def freeze(name: str, note: str) -> int:
    f = FREEZES / f'{name}.json'
    if f.exists():
        print(f'{f.relative_to(ROOT)} already exists.')
        print('  A freeze is a record of one run. Delete it only if that run was abandoned.')
        return 1
    files = manifest(WATCHED)
    if not files:
        print(f'nothing to freeze under {ROOT}: no watched file exists.')
        print('  Refusing: a freeze of nothing would verify forever.')
        return 1
    FREEZES.mkdir(parents=True, exist_ok=True)
    prov = provenance()
    f.write_text(json.dumps({'name': name, 'note': note, **prov,
                             'watch_version': WATCH_VERSION,
                             'watched': [list(w) for w in WATCHED],
                             'files': files}, indent=2, sort_keys=True) + '\n')
    dirty = ' (tree dirty: the hashes are the record)' if prov['dirty'] is True else ''
    print(f'froze {len(files)} files at {prov["commit"][:8]}{dirty} -> {f.relative_to(ROOT)}')
    return 0


def recorded_watch_list(rec: dict):
    if isinstance(rec.get('watched'), list):
        return tuple(tuple(w) for w in rec['watched'])
    return WATCH_VERSIONS.get(rec.get('watch_version'))


def verify(name: str) -> int:
    f = FREEZES / f'{name}.json'
    if not f.is_file():
        print(f'no freeze named {name!r}. Run `eval-freeze.py freeze {name}` BEFORE the eval.')
        return 1
    try:
        rec = json.loads(f.read_text())
        before = dict(rec['files'])
    except (ValueError, KeyError, TypeError) as e:
        print(f'{f.relative_to(ROOT)} is not a freeze this script can read ({e!r}).')
        return 1
    watched = recorded_watch_list(rec)
    if watched is None:
        print(f'{f.relative_to(ROOT)} records neither a watch list nor a known '
              'watch_version, so there is nothing sound to compare against. Refusing.')
        return 1
    if not before:
        print(f'{f.relative_to(ROOT)} froze zero files. Refusing: it would verify anything.')
        return 1
    after = manifest(watched)
    moved = sorted(k for k in before.keys() & after.keys() if before[k] != after[k])
    gone = sorted(before.keys() - after.keys())
    added = sorted(after.keys() - before.keys())
    for k in moved:
        print(f'CHANGED  {k}')
    for k in gone:
        print(f'REMOVED  {k}')
    for k in added:
        print(f'ADDED    {k}')
    if moved or gone or added:
        print()
        print('These moved while the eval was running, so the result does not answer')
        print('the question it was set up to answer. Re-freeze and run it again.')
        return 1
    print(f'unchanged since the freeze ({len(after)} files, watch list '
          f'v{rec.get("watch_version", "?")})')
    return 0


def main(argv: list) -> int:
    if len(argv) < 3 or argv[1] not in ('freeze', 'verify'):
        print(__doc__)
        return 2
    note = ''
    if '--note' in argv:
        i = argv.index('--note')
        note = argv[i + 1] if i + 1 < len(argv) else ''
    return freeze(argv[2], note) if argv[1] == 'freeze' else verify(argv[2])


if __name__ == '__main__':
    sys.exit(main(sys.argv))
