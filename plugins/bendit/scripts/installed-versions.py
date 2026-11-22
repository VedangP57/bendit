#!/usr/bin/env python3
"""Which bendit will each checkout of this repo load?

    installed-versions.py [--root DIR] [--plugins-file FILE] [--json]

WHY. On 2026-11-22 setup ran in a git worktree and installed bendit 0.5.0 for
the worktree's path. The reopened window ran 0.4.0: Claude Code's record of
installs still held 0.4.0 for the MAIN checkout's path, and updating the main
checkout fixed it, so a worktree seems to load the main checkout's project
install (seen once, not proven). Nothing said the two checkouts disagreed.

WHAT. Every checkout of the repo at --root (default: the current folder), from
`git worktree list --porcelain`, the main checkout first. For each, the bendit
and bendit-web versions installed for that exact path at project scope, read
from Claude Code's record of installs (--plugins-file, default
${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/installed_plugins.json), or "none".
Each is compared with the version of the bendit running this script (bendit
and bendit-web are released together, under one version).

It reads that file directly and never runs `claude plugin list`, which can
hang in a folder Claude Code has not seen yet. It changes nothing.

OUTPUT. `running: bendit <version>`, then one line per checkout. A checkout
whose version differs is said in plain words, and every checkout behind the
newest version seen (running or recorded) gets the exact command that updates
it, run from that checkout: `cd <path> && claude plugin update <id> --scope
project`. A checkout with nothing installed is "none": not a mismatch.

EXIT. 0 every recorded version matches the running one; 1 at least one
differs; 2 something could not be read (the record of installs, the running
version, git): never reported as "all fine".
"""
import json
import os
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features  # noqa: E402  (the one reader of the running version)

PLUGINS = ('bendit', 'bendit-web')


class CannotRead(Exception):
    pass


def default_plugins_file():
    base = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
    return os.path.join(base, 'plugins', 'installed_plugins.json')


def real(p):
    return os.path.realpath(os.path.abspath(p))


def checkouts(root):
    """[(path, is_main)] for the repo at <root>, the main checkout first; a
    folder that is not in a git repository is its only checkout."""
    root = real(root)
    try:
        p = subprocess.run(['git', '-C', root, 'rev-parse', '--is-inside-work-tree'],
                           capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return [(root, False)]           # no git at all: this folder only
    except (OSError, subprocess.SubprocessError) as e:
        raise CannotRead('git could not be asked about %s: %s' % (root, e))
    if p.returncode != 0:
        if 'not a git repository' in p.stderr:
            return [(root, False)]
        raise CannotRead('git rev-parse in %s exited %d: %s' % (root, p.returncode, p.stderr.strip()))
    try:
        p = subprocess.run(['git', '-C', root, 'worktree', 'list', '--porcelain'],
                           capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise CannotRead('git worktree list in %s failed: %s' % (root, e))
    if p.returncode != 0:
        raise CannotRead('git worktree list in %s exited %d: %s' % (root, p.returncode, p.stderr.strip()))
    out, cur = [], None
    for line in p.stdout.splitlines() + ['']:
        if line.startswith('worktree '):
            cur = {'path': line[len('worktree '):], 'bare': False}
        elif line == 'bare' and cur is not None:
            cur['bare'] = True
        elif line == '' and cur is not None:
            if not cur['bare']:
                out.append((real(cur['path']), not out))
            cur = None
    if not out:
        raise CannotRead('git worktree list in %s named no checkout' % root)
    return out


def load_installs(path):
    """{(plugin name, real project path): [(plugin id, version)]} for project
    scope. Any surprise in the file is CannotRead, never an empty answer."""
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise CannotRead('%s: could not read it: %s' % (path, e))
    plugins = data.get('plugins') if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        raise CannotRead('%s: no "plugins" object in it' % path)
    found = {}
    for pid, entries in plugins.items():
        name = str(pid).split('@')[0]
        if name not in PLUGINS:
            continue
        if not isinstance(entries, list):
            raise CannotRead('%s: %r is not a list' % (path, pid))
        for e in entries:
            if not isinstance(e, dict):
                raise CannotRead('%s: an entry of %r is not an object' % (path, pid))
            if e.get('scope') != 'project':
                continue
            proj, ver = e.get('projectPath'), e.get('version')
            if not isinstance(proj, str) or not isinstance(ver, str) or not ver:
                raise CannotRead('%s: an entry of %r has no projectPath or version string' % (path, pid))
            found.setdefault((name, real(proj)), []).append((pid, ver))
    return found


def vkey(v):
    """A sortable key for a dotted version; None when it is not one."""
    m = re.match(r'^(\d+(?:\.\d+)*)', v)
    return tuple(int(x) for x in m.group(1).split('.')) if m else None


def compare(a, b):
    """'older', 'newer' or 'different' (a against b), when a != b."""
    ka, kb = vkey(a), vkey(b)
    if ka is None or kb is None or ka == kb:
        return 'different'
    return 'older' if ka < kb else 'newer'


def report(root, plugins_file):
    try:
        running = features.plugin_version()
    except features.FeaturesError as e:
        raise CannotRead(str(e))
    here = real(root)
    try:
        top = subprocess.run(['git', '-C', here, 'rev-parse', '--show-toplevel'], capture_output=True,
                             text=True, timeout=30, stdin=subprocess.DEVNULL).stdout.strip()
        here = real(top) if top else here
    except (OSError, subprocess.SubprocessError):
        pass
    installs = load_installs(plugins_file)
    rows = []
    for path, is_main in checkouts(root):
        row = {'path': path, 'main': is_main, 'here': path == here}
        for name in PLUGINS:
            got = installs.get((name, path), [])
            row[name] = got[0][1] if got else None
            row[name + ' id'] = got[0][0] if got else name + '@bendit'
        rows.append(row)
    # The newest version anywhere: a checkout behind it gets its update command.
    seen = [running] + [r[n] for r in rows for n in PLUGINS if r[n]]
    newest = max(seen, key=lambda v: vkey(v) or ())
    mismatch = False
    for r in rows:
        r['notes'], r['update'] = [], []
        for name in PLUGINS:
            v = r[name]
            if v is None:
                continue
            if v != running:
                mismatch = True
                how = {'older': 'older than', 'newer': 'newer than'}.get(compare(v, running), 'different from')
                r['notes'].append('%s %s is %s the running %s' % (name, v, how, running))
            if v != newest and (vkey(v) or ()) < (vkey(newest) or ()):
                r['update'].append('cd %s && claude plugin update %s --scope project'
                                   % (shlex.quote(r['path']), r[name + ' id']))
    return running, rows, mismatch


def text(running, rows, mismatch):
    out = ['running: bendit %s' % running]
    for r in rows:
        tags = [t for t, on in (('main checkout', r['main']), ('this folder', r['here'])) if on]
        label = r['path'] + ''.join(' (%s)' % t for t in tags)
        vers = ', '.join('%s %s' % (n, r[n] or 'none') for n in PLUGINS)
        state = '; '.join(r['notes']) if r['notes'] else (
            'matches' if any(r[n] for n in PLUGINS) else 'bendit is not installed for this path')
        out.append('%s: %s -- %s' % (label, vers, state))
        for cmd in r['update']:
            out.append('  to update it: %s' % cmd)
    if mismatch:
        out.append('Checkouts of one repo can load each other\'s install (a worktree has been seen loading the '
                   'main checkout\'s), so every checkout should have the same version.')
    return '\n'.join(out)


def main(argv):
    root, pfile, as_json = '.', None, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('--root', '--plugins-file') and i + 1 < len(argv):
            if a == '--root':
                root = argv[i + 1]
            else:
                pfile = argv[i + 1]
            i += 2
        elif a == '--json':
            as_json, i = True, i + 1
        else:
            print('usage: installed-versions.py [--root DIR] [--plugins-file FILE] [--json]', file=sys.stderr)
            return 2
    try:
        running, rows, mismatch = report(root, pfile or default_plugins_file())
    except CannotRead as e:
        if as_json:
            print(json.dumps({'error': str(e)}))
        else:
            print('installed versions: could not check -- %s' % e)
        return 2
    if as_json:
        print(json.dumps({'running': running, 'ok': not mismatch, 'checkouts': [
            {'path': r['path'], 'main': r['main'], 'here': r['here'], 'bendit': r['bendit'],
             'bendit-web': r['bendit-web'], 'notes': r['notes'], 'update': r['update']} for r in rows]}))
    else:
        print(text(running, rows, mismatch))
    return 1 if mismatch else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # noqa: BLE001 -- a crash is "could not check", never "all fine"
        print('installed versions: could not check -- %s: %s' % (type(e).__name__, e))
        sys.exit(2)
