#!/usr/bin/env python3
"""Which bendit will each checkout of this repo load?

    installed-versions.py [--root DIR] [--plugins-file FILE] [--json]

WHY. On 2026-11-22 setup ran in a git worktree and installed bendit 0.5.0 for
the worktree's path. The reopened window ran 0.4.0: Claude Code's record of
installs still held 0.4.0 for the MAIN checkout's path, and updating the main
checkout fixed it, so a worktree seems to load the main checkout's project
install (seen once, not proven). Nothing said the two checkouts disagreed.

WHAT. Every checkout of the repo at --root (default: the current folder), from
`git worktree list --porcelain`, the main checkout first. For each, every
bendit and bendit-web version installed for that path at PROJECT scope, then
the USER-scope version on its own line (what a folder with no project-scope
install loads; it changes no exit code; local scope is not read), read from Claude Code's record of installs
(--plugins-file, default
${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/installed_plugins.json), or "none".
Each is compared with the version of the bendit running this script (bendit
and bendit-web are released together, under one version). A recorded path is
the same folder when it is the same file on disk (so a path recorded in other
capitals on macOS still matches), else when its resolved path is equal.

It reads that file directly and never runs `claude plugin list`, which can
hang in a folder Claude Code has not seen yet. It changes nothing.

WORKTREES (v0.5.2). On 2026-11-23 a worktree ran 0.5.1, the main checkout
recorded 0.5.1 and the worktree's own record said 0.5.0; `claude plugin update`
in the worktree said "already at the latest version". Claude Code loads the
main checkout's project install in a worktree. So where the main checkout
records a plugin, a worktree's own record of it is never compared: when it
differs from main's it is printed as `note:` (no mismatch, no update command,
no reopen). Where main records none, the worktree's own record is compared as
before.

OUTPUT. `running: bendit <version>`, then one line per checkout. A checkout
whose version differs is said in plain words, and every checkout behind the
newest version seen (running or recorded) gets the exact command that updates
it, run from that checkout: `cd <path> && claude plugin update <id> --scope
project`. "none" everywhere is not a mismatch; "none" in the MAIN checkout
while another checkout has an install is one (a worktree loads the main
checkout's install), with the command that installs it there.

EXIT. 0 every recorded version matches the running one; 1 at least one
differs, or the main checkout has none while another has one; 2 something
could not be read (the record of installs, the running version, git): never
reported as "all fine".
"""
import json
import os
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True

PLUGINS = ('bendit', 'bendit-web')
SCOPE_NOTE = ('Only project-scope installs are compared between checkouts; a user-scope install is listed '
              'on its own line (local-scope installs are not read).')


class CannotRead(Exception):
    pass


def default_plugins_file():
    base = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
    return os.path.join(base, 'plugins', 'installed_plugins.json')


def real(p):
    return os.path.realpath(os.path.abspath(p))


def same_path(a, b):
    """Are <a> and <b> the same folder? The same file on disk when both exist
    (case-insensitive filesystems fold capitals there), else equal resolved paths."""
    try:
        return os.path.samefile(a, b)
    except OSError:
        return real(a) == real(b)


def running_version():
    """The running bendit's version, from features.py (the one reader of it)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import features
        return features.plugin_version()
    except Exception as e:  # noqa: BLE001 -- unreadable is CannotRead, never a mismatch
        raise CannotRead('the running version could not be read: %s: %s' % (type(e).__name__, e))


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
    """[{name, id, project, version, install}] for every PROJECT-scope bendit or
    bendit-web entry. Any surprise in the file is CannotRead, never an empty
    answer."""
    return [e for e in load_all(path) if e['scope'] == 'project']


def load_user(path):
    """[{name, id, version, install}] for every USER-scope bendit or bendit-web
    entry: what a folder with no project-scope install loads."""
    return [e for e in load_all(path) if e['scope'] == 'user']


def load_all(path):
    """Every project- and user-scope bendit or bendit-web entry, each with its
    'scope'. Local scope is not read. Any surprise is CannotRead."""
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise CannotRead('%s: could not read it: %s' % (path, e))
    plugins = data.get('plugins') if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        raise CannotRead('%s: no "plugins" object in it' % path)
    found = []
    for pid, entries in plugins.items():
        name = str(pid).split('@')[0]
        if name not in PLUGINS:
            continue
        if not isinstance(entries, list):
            raise CannotRead('%s: %r is not a list' % (path, pid))
        for e in entries:
            if not isinstance(e, dict):
                raise CannotRead('%s: an entry of %r is not an object' % (path, pid))
            scope = e.get('scope')
            if scope not in ('project', 'user'):
                continue
            proj, ver = e.get('projectPath'), e.get('version')
            if not isinstance(ver, str) or not ver or (scope == 'project' and not isinstance(proj, str)):
                raise CannotRead('%s: a %s-scope entry of %r has no %sversion string'
                                 % (path, scope, pid, 'projectPath or ' if scope == 'project' else ''))
            inst = e.get('installPath')
            found.append({'name': name, 'id': str(pid), 'scope': scope,
                          'project': proj if scope == 'project' else None, 'version': ver,
                          'install': inst if isinstance(inst, str) else None})
    return found


def installs_for(installs, folder, name=None):
    """The project-scope entries recorded for <folder> (optionally one plugin)."""
    return [e for e in installs if (name is None or e['name'] == name) and same_path(e['project'], folder)]


def vkey(v):
    """A sortable key for a dotted version; () when it is not one."""
    m = re.match(r'^(\d+(?:\.\d+)*)', v)
    return tuple(int(x) for x in m.group(1).split('.')) if m else ()


def compare(a, b):
    """'older than', 'newer than' or 'different from' (a against b), when a != b."""
    ka, kb = vkey(a), vkey(b)
    if not ka or not kb or ka == kb:
        return 'different from'
    return 'older than' if ka < kb else 'newer than'


def report(root, plugins_file):
    running = running_version()
    here = real(root)
    try:
        top = subprocess.run(['git', '-C', here, 'rev-parse', '--show-toplevel'], capture_output=True,
                             text=True, timeout=30, stdin=subprocess.DEVNULL).stdout.strip()
        here = real(top) if top else here
    except (OSError, subprocess.SubprocessError):
        pass
    everything = load_all(plugins_file)
    installs = [e for e in everything if e['scope'] == 'project']
    user = {n: [e['version'] for e in everything if e['scope'] == 'user' and e['name'] == n] for n in PLUGINS}
    rows = []
    for path, is_main in checkouts(root):
        row = {'path': path, 'main': is_main, 'here': same_path(path, here)}
        for name in PLUGINS:
            row[name] = [(e['id'], e['version']) for e in installs_for(installs, path, name)]
        rows.append(row)
    # A linked worktree loads the MAIN checkout's project install (2026-11-23:
    # running 0.5.1, main 0.5.1, the worktree's own record 0.5.0, and `claude
    # plugin update` in the worktree said "already at the latest version"). So
    # where main records a plugin, a worktree's own record of it is not what
    # loads: a note, never a mismatch and never an update command.
    main_row = next((r for r in rows if r['main']), None)
    for r in rows:
        r['shadowed'] = [n for n in PLUGINS if not r['main'] and main_row is not None and main_row[n]]
    # The newest version that loads somewhere: a checkout behind it gets its update command.
    seen = [running] + [v for r in rows for n in PLUGINS if n not in r['shadowed'] for _, v in r[n]]
    newest = max(seen, key=vkey)
    mismatch = False
    for r in rows:
        r['notes'], r['update'], r['info'] = [], [], []
        q = shlex.quote(r['path'])
        for name in PLUGINS:
            if name in r['shadowed']:
                if r[name] and sorted(v for _, v in r[name]) != sorted(v for _, v in main_row[name]):
                    r['info'].append('%s %s (%s) is recorded for this worktree\'s own folder, but a worktree '
                                     'loads the main checkout\'s install (%s %s), so this record is not used: '
                                     'nothing to update here, no need to reopen Claude'
                                     % (name, '/'.join(v for _, v in r[name]), r[name][0][0], name,
                                        '/'.join(v for _, v in main_row[name])))
                continue
            if not r[name]:
                # A worktree loads the main checkout's install: none there, while
                # another checkout has one, is the incident itself.
                others = [pid for o in rows if o is not r for pid, _ in o[name]]
                if r['main'] and others:
                    mismatch = True
                    r['notes'].append('%s is not installed here, but another checkout has it, and a worktree '
                                      'may load the main checkout\'s install' % name)
                    r['update'].append('cd %s && claude plugin install %s --scope project' % (q, others[0]))
                continue
            for pid, v in r[name]:
                if v != running:
                    mismatch = True
                    r['notes'].append('%s %s (%s) is %s the running %s' % (name, v, pid, compare(v, running), running))
                if v != newest and vkey(v) < vkey(newest):
                    r['update'].append('cd %s && claude plugin update %s --scope project' % (q, pid))
    return running, rows, mismatch, user


def text(running, rows, mismatch, user):
    out = ['running: bendit %s' % running]
    for r in rows:
        tags = [t for t, on in (('main checkout', r['main']), ('this folder', r['here'])) if on]
        label = r['path'] + ''.join(' (%s)' % t for t in tags)
        vers = ', '.join('%s %s' % (n, '/'.join(v for _, v in r[n]) or 'none') for n in PLUGINS)
        if r['notes']:
            state = '; '.join(r['notes'])
        elif r['info']:
            state = "loads the main checkout's install (its line above)"
        else:
            state = 'matches' if any(r[n] for n in PLUGINS) else 'no project-scope install recorded for this path'
        out.append('%s: %s -- %s' % (label, vers, state))
        for note in r['info']:
            out.append('  note: %s' % note)
        for cmd in r['update']:
            out.append('  to fix it: %s' % cmd)
    for name in PLUGINS:
        if name != 'bendit' and not user[name]:
            continue
        vs = user[name]
        if not vs:
            out.append('user scope: %s none' % name)
            continue
        state = ', '.join('matches' if v == running else '%s the running %s' % (compare(v, running), running)
                          for v in vs)
        out.append('user scope: %s %s -- %s; a folder with no project-scope install loads it '
                   '(a project-scope install wins)' % (name, '/'.join(vs), state))
    if mismatch:
        out.append('A worktree loads the main checkout\'s install, so the main checkout\'s version is the one '
                   'that has to match.')
    out.append(SCOPE_NOTE)
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
        running, rows, mismatch, user = report(root, pfile or default_plugins_file())
    except CannotRead as e:
        if as_json:
            print(json.dumps({'error': str(e)}))
        else:
            print('installed versions: could not check -- %s' % e)
        return 2
    if as_json:
        print(json.dumps({'running': running, 'ok': not mismatch, 'checkouts': [
            {'path': r['path'], 'main': r['main'], 'here': r['here'],
             'bendit': '/'.join(v for _, v in r['bendit']) or None,
             'bendit-web': '/'.join(v for _, v in r['bendit-web']) or None,
             'notes': r['notes'], 'info': r['info'], 'update': r['update']} for r in rows],
            'user': {n: '/'.join(user[n]) or None for n in PLUGINS}}))
    else:
        print(text(running, rows, mismatch, user))
    return 1 if mismatch else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # noqa: BLE001 -- a crash is "could not check", never "all fine"
        print('installed versions: could not check -- %s: %s' % (type(e).__name__, e))
        sys.exit(2)
