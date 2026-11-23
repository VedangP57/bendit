#!/usr/bin/env python3
"""Can every bendit hook still run? Fire each one's known-bad probe and see.

    selfcheck.py --hook       SessionStart: silent when all is well, loud when not
    selfcheck.py [--verbose]  a table, one row per hook (/bendit:doctor)
    selfcheck.py --features <root>
                              the project's features table, and a warning when
                              the bendit-web add-on is enabled at user scope
    selfcheck.py --session    did bendit's hooks start in THIS Claude window?
                              (/bendit:doctor; exit 0 live, 1 not live, 3 unknown)

WHY. A hook that cannot start is a guard that is OFF, and nothing says so.
macOS revoked a terminal's access to the folder the plugin lived in; every hook
then failed with `python3: can't open file ...: Operation not permitted`, and
the session ran on with no guard at all. python3 missing from PATH, a half
written install and a syntax error after an update fail the same silent way.

WHAT. Every hook in hooks/hooks.json is run as Claude Code runs it (`/bin/sh -c`
on its command, CLAUDE_PLUGIN_ROOT set, the payload on stdin) with ONE probe
from probes.py, in parallel, in a temp dir removed afterwards:
  - a guard with a refusing probe must refuse it: exit 2, reason naming bendit;
  - a hook that never blocks (--pre, --mark, the Stop gate with nothing
    pending) must start and exit 0.
Anything else is that hook OFF: named, with its first error line, and a fix.

CHANNELS (--hook). Healthy: no output at all. Broken: one JSON object on stdout,
`systemMessage` for the person and `hookSpecificOutput.additionalContext` for
the model. Exit 0 ALWAYS: a failed self-check must not stop a session starting,
and an internal error is reported in the same JSON, never raised. hooks.json
runs this as `python3 ... || echo '<fallback JSON>'`, so even a selfcheck that
cannot start (no python3, an unreadable plugin folder) still speaks.

THIS WINDOW (--session). Every check above runs the hook scripts by hand; none
shows that Claude Code loaded them into the window the person is typing in. A
window opened before bendit was installed has none of its hooks, and nothing
said so. So --hook, which only runs when Claude Code started bendit's hooks,
leaves a marker named after the payload's `session_id`, and --session looks for
the one named after CLAUDE_CODE_SESSION_ID, which Claude Code sets in its Bash
tool's environment. Both are the same id: checked on Claude Code 2.1.329 with a
headless session, on startup and on --resume. The markers live outside every
project (one window may visit several), in
${BENDIT_LIVE_DIR:-${XDG_CACHE_HOME:-~/.cache}/bendit/live-sessions}; markers
older than 30 days are removed. No id, or no marker: never "live"; a marker
folder that cannot be written is named ("can't write <folder>"). A second line,
`live test: run|skip`, says whether `git push --force bendit-probe HEAD` is
harmless here: only while no git remote, file or folder is named bendit-probe.
Between those two, `copy: installed|installer copy|other copy (...)` says
whether the bendit running is the one Claude Code recorded for THIS project at
project scope (installPath the same folder, same version) -- the only copy a
reopened window is known to run -- or the installer's download (under
${BENDIT_CACHE:-${XDG_CACHE_HOME:-~/.cache}/bendit}/, loaded with --plugin-dir
as bendit@inline) or any folder outside Claude's plugin cache (`installer
copy`), or some other copy in that cache (`other copy`). In a git worktree the
main checkout's project install is the one Claude Code loads; the worktree's own
differing record is printed as a `note:` line under it.

Exit (table mode): 0 every hook answered, 1 something is OFF or unchecked.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PER_HOOK = 3.0     # seconds; a healthy guard answers in well under 0.2
SELF = ('selfcheck.py', ('--hook',))

# What a guard prints when its own helper modules will not load (it then exits 2
# on every call). Literal in each guard; guard-startup.test.sh pins both ends.
STARTUP_FAILED = 'could not start: '

FIX_TCC = ('macOS is blocking access to the plugin folder: give your terminal app (Terminal, iTerm, '
           'your editor) Full Disk Access in System Settings > Privacy & Security, then restart it')
FIX_PERM = 'the file is not readable: reinstall (claude plugin install bendit@bendit) or restore its permissions'
FIX_PY = 'python3 is not on the PATH Claude Code runs hooks with: install Python 3.9+ or add it to that PATH'
FIX_MISSING = 'a file of the plugin is missing: reinstall (claude plugin install bendit@bendit)'
FIX_CRASH = 'the hook crashes: reinstall; if it persists, report it (SECURITY.md)'
FIX_OPEN = 'it runs but lets a known-bad call through: reinstall, or revert a local edit to it'
FIX_START = ('its own code did not load, so it refuses EVERY call it sees: reinstall '
             '(claude plugin install bendit@bendit), or revert a local edit to its helper modules')
FIX_HANG = 'it did not answer in time: check the machine is not overloaded, then reinstall'


def first_line(text, n=300):
    """The line that says what went wrong: the first, or for a traceback the
    last (`SyntaxError: ...`), which is the one that names the error."""
    lines = [l.strip() for l in (text or '').splitlines() if l.strip()]
    if not lines:
        return ''
    line = lines[0]
    if len(lines) > 1 and re.match(r'^[\w.]+(Error|Exception)\b', lines[-1]):
        line = lines[-1]
    # `/long/path/to/Python: can't open file ...` -> `Python: can't open file ...`
    line = re.sub(r'^/\S*/([\w.-]+): ', r'\1: ', line)
    # Too long: keep the END, where the reason is (`[Errno 1] Operation not permitted`).
    return line if len(line) <= n else '...' + line[-n:]


def name_of(key):
    return ' '.join((key[0],) + key[1])


def fix_for(err, rc):
    low = err.lower()
    if 'operation not permitted' in low:
        return FIX_TCC
    if 'permission denied' in low:
        return FIX_PERM
    if rc == 127 or ('python3' in low and 'not found' in low):
        return FIX_PY
    if 'no such file' in low:
        return FIX_MISSING
    return FIX_CRASH


def run_one(key, event, matcher, cmd, timeout, probe, work):
    """One hook, one probe. Returns a result dict; never raises."""
    res = {'hook': name_of(key), 'event': event + (f' {matcher}' if matcher else ''), 'ok': False,
           'error': '', 'fix': ''}
    try:
        d, base = _probes.prepare(work)
        env = _probes.env_for(probe, base, d)
        env['CLAUDE_PLUGIN_ROOT'] = KIT
        data = probe.build(d)
        t = min(float(timeout or 10), PER_HOOK)
        try:
            p = subprocess.run(['/bin/sh', '-c', cmd], input=data, capture_output=True, text=True,
                               env=env, cwd=d, timeout=t)
        except subprocess.TimeoutExpired:
            res.update(error=f'no answer within {t:g}s', fix=FIX_HANG)
            return res
        rc, out, err = p.returncode, p.stdout, p.stderr
        if probe.expect == 'refuses':
            if rc == 2 and STARTUP_FAILED in err:
                # Refused, but not because of the probe: a guard whose helpers
                # did not load refuses everything. That is not a working guard.
                res.update(error=first_line(err), fix=FIX_START)
            elif rc == 2 and err.lstrip().startswith(_probes.PREFIXES):
                res['ok'] = True
            elif rc == 0:
                res.update(error='exit 0 on its known-bad probe: it no longer '
                                 + probe.label.split(': ', 1)[-1], fix=FIX_OPEN)
            else:
                res.update(error=first_line(err) or f'exit {rc}, no output', fix=fix_for(err, rc))
        else:
            if rc == 0:
                res['ok'] = True
            else:
                res.update(error=first_line(err) or f'exit {rc}, no output', fix=fix_for(err, rc))
    except Exception as e:  # report, never raise: this runs at every session start
        res.update(error=f'selfcheck could not probe it: {type(e).__name__}: {e}', fix=FIX_CRASH)
    return res


def check():
    """[(result dict)], or raises only for hooks.json itself (the caller reports it)."""
    entries = _probes.hook_entries(KIT)
    jobs, seen, results = [], set(), []
    for event, matcher, cmd, timeout in entries:
        key = _probes.hook_key(cmd)
        if key is None:
            results.append({'hook': first_line(cmd, 60), 'event': event, 'ok': False,
                            'error': 'selfcheck cannot read which script this hook runs', 'fix': FIX_MISSING})
            continue
        if key == SELF or key in seen:
            continue
        seen.add(key)
        table = _probes.PROBES.get(key)
        if not table:
            results.append({'hook': name_of(key), 'event': event, 'ok': False, 'unknown': True,
                            'error': 'selfcheck has no probe for it in scripts/probes.py',
                            'fix': 'add a probe for it to scripts/probes.py'})
            continue
        probe = next((p for p in table if p.expect == 'refuses'), table[0])
        jobs.append((key, event, matcher, cmd, timeout, probe))
    if not jobs and not results:    # checked nothing is never a pass
        return internal('hooks/hooks.json declares no hook to check')
    root = tempfile.mkdtemp(prefix='bendit-selfcheck.')
    try:
        with ThreadPoolExecutor(max_workers=max(1, len(jobs))) as pool:
            futs = [pool.submit(run_one, *j, os.path.join(root, str(i))) for i, j in enumerate(jobs)]
            results.extend(f.result() for f in futs)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return results


def messages(broken, total):
    """(for the person, for the model). A hook that ran and failed is OFF; a
    hook selfcheck could not check (no probe, its own failure) is UNKNOWN --
    said as such, never dressed up as a measured OFF."""
    off = [r for r in broken if not r.get('unknown')]
    unk = [r for r in broken if r.get('unknown')]
    lines = []
    if off:
        lines.append(f'bendit: {len(off)} of {total} hooks {"is" if len(off) == 1 else "are"} OFF -- '
                     f'{"it" if len(off) == 1 else "they"} could not run, or let a known-bad call through, '
                     f'so {"that check is" if len(off) == 1 else "those checks are"} not protecting you this session. '
                     'The rest still work.' if len(off) < total else
                     f'bendit: ALL {total} hooks are OFF -- none could run or refuse, so nothing is protecting you this session.')
    if unk:
        lines.append(('bendit: also ' if off else 'bendit: ') + 'its self-check could not check everything; '
                     'treat what it could not check as OFF.')
    for r in broken:
        where = f' ({r["event"]})' if r.get('event') else ''
        lines.append(f'  - {r["hook"]}{where}: {r["error"]}')
        lines.append('    ' + ('whether it works is UNKNOWN' if r.get('unknown') else 'this guard is OFF')
                     + f'. Fix: {r["fix"]}.')
    lines.append('After fixing, start a new session or run /bendit:doctor to re-check.')
    person = '\n'.join(lines)
    model = ('bendit self-check at session start: the hooks below are OFF (or could not be checked) this '
             'session, so their protection is NOT active:\n'
             + '\n'.join(f'  - {r["hook"]}: {r["error"]} -- fix: {r["fix"]}' for r in broken)
             + '\nTell the user in your first reply, and do not rely on these guards: run nothing destructive '
             'without their explicit go-ahead. /bendit:doctor re-checks.')
    return person, model


def internal(what):
    """selfcheck could not check at all: every guard's state is UNKNOWN."""
    return [{'hook': 'selfcheck', 'event': '', 'ok': False, 'unknown': True,
             'error': what + '; NO guard was checked',
             'fix': 'reinstall (claude plugin install bendit@bendit)'}]


def gather():
    global _probes
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import probes as _probes  # noqa: F811
    except BaseException as e:  # the table is code too: it can be unreadable or broken
        return internal(f'the probe table (scripts/probes.py) did not load: {type(e).__name__}: {e}'), 0
    try:
        results = check()
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        return internal(f'hooks/hooks.json could not be read: {type(e).__name__}: {e}'), 0
    except BaseException as e:
        return internal(f'selfcheck failed: {type(e).__name__}: {e}'), 0
    return results, sum(1 for r in results if not r.get('unknown'))


_probes = None

ADDON = 'bendit-web'
ADDON_WARNING = f'{ADDON} is installed for every project, not only this one'


def addon_scope_line():
    """One line on whether the add-on is enabled at USER scope (every project).
    `claude plugin list --json` is a list of {id, scope, enabled, ...}. When the
    CLI is missing, errors or prints something else, say "could not check":
    neither fine nor a problem."""
    def cannot(why):
        return f'add-on scope: could not check whether {ADDON} is installed for every project ({why})'
    try:
        p = subprocess.run(['claude', 'plugin', 'list', '--json'], capture_output=True, text=True,
                           timeout=30, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return cannot('the claude CLI is not on PATH')
    except (OSError, subprocess.SubprocessError) as e:
        return cannot(f'{type(e).__name__}: {e}')
    if p.returncode != 0:
        return cannot(f'claude plugin list exited {p.returncode}: {first_line(p.stderr) or "no output"}')
    try:
        entries = json.loads(p.stdout)
        if not isinstance(entries, list):
            raise ValueError('not a list')
        user = [e for e in entries if isinstance(e, dict) and e.get('scope') == 'user'
                and e.get('enabled') is True and str(e.get('id', '')).split('@')[0] == ADDON]
    except (ValueError, TypeError, AttributeError) as e:
        return cannot(f'claude plugin list --json was not the expected list: {e}')
    if user:
        return f'add-on scope: {ADDON_WARNING}. Fix: claude plugin uninstall {user[0]["id"]} --scope user, then run /bendit:adopt per project'
    return f'add-on scope: ok ({ADDON} is not enabled at user scope)'


def project_root(given):
    """The project root for an explicit <given>: its git toplevel, else <given>
    itself. Never $CLAUDE_PROJECT_DIR: a path the caller named must not yield to
    the session's project (the env var is the default only when no path is given,
    see main). Absolute."""
    given = os.path.abspath(given)
    try:
        p = subprocess.run(['git', '-C', given, 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        top = p.stdout.strip()
        if p.returncode == 0 and top:
            return top
    except (OSError, subprocess.SubprocessError):
        pass
    return given


def features_fix(root):
    """The `fix:` line for a bendit.json features.py refused. A newer bendit's
    guard that is on is not a broken file: update bendit, never edit or delete
    the file (that turns a teammate's guard off). Anything else: repair it."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import features
        features.load(root)
    except Exception as e:  # noqa: BLE001 -- classify only; the error is already printed
        if type(e).__name__ == 'UnknownFeatureOn':
            return (f'fix: update bendit: {features.UPDATE_COMMAND}, then close Claude and open it again. '
                    'Do not edit or delete .claude/bendit.json to get past this: a teammate turned that '
                    'guard on, and changing the file turns it off for everyone.')
    return 'fix: repair .claude/bendit.json (the error above names the problem), then run /bendit:adopt'


def features_report(given):
    """The features table for the project root of <given>, then the add-on
    scope line. 1 when bendit.json is unreadable (reported, never read as
    everything off)."""
    root = project_root(given)
    path = os.path.join(root, '.claude', 'bendit.json')
    p = subprocess.run([sys.executable, os.path.join(KIT, 'scripts', 'features.py'), 'show', root],
                       capture_output=True, text=True)
    if p.returncode != 0:
        msg = first_line(p.stderr) or f'{path}: could not read it'
        print(msg if msg.startswith('features:') else f'features: {msg}')
        print(features_fix(root))
        print()
        print(addon_scope_line())
        return 1
    print(f'bendit features: {path}')
    print()
    print(p.stdout.rstrip('\n'))
    print()
    print(addon_scope_line())
    return 0


LIVE_STALE = 30 * 86400


def live_dir():
    explicit = os.environ.get('BENDIT_LIVE_DIR')
    if explicit:
        return explicit
    cache = os.environ.get('XDG_CACHE_HOME') or os.path.join(os.path.expanduser('~'), '.cache')
    return os.path.join(cache, 'bendit', 'live-sessions')


def marker_name(sid):
    """A session id is data from outside: keep it to one safe file name."""
    if not isinstance(sid, str):
        return ''
    return ''.join(c for c in sid.strip() if c.isalnum() or c in '-_')[:64]


def mark_live(payload_text):
    """--hook: Claude Code started bendit's hooks in this session. Never raises:
    a marker that cannot be written only makes --session say "not live"."""
    try:
        payload = json.loads(payload_text or '')
        name = marker_name(payload.get('session_id') if isinstance(payload, dict) else None)
        if not name:
            return
        d = live_dir()
        os.makedirs(d, exist_ok=True)
        cutoff = time.time() - LIVE_STALE
        for old in os.listdir(d):
            p = os.path.join(d, old)
            try:
                if os.path.isfile(p) and os.path.getmtime(p) < cutoff:
                    os.remove(p)
            except OSError:
                pass
        with open(os.path.join(d, name), 'w') as f:
            f.write(str(payload.get('source', '')) + '\n')
    except Exception:  # noqa: BLE001 -- this runs at every session start
        pass


def unwritable(d):
    """The nearest folder that exists at or above <d>, when the start-up check
    could not create its marker there; else ''."""
    cur = os.path.abspath(d)
    while not os.path.exists(cur):
        parent = os.path.dirname(cur)
        if parent == cur:
            return ''
        cur = parent
    return '' if os.access(cur, os.W_OK | os.X_OK) else cur


PROBE = 'bendit-probe'


def live_test_line():
    """Is `git push --force bendit-probe HEAD` harmless HERE? Only while that
    name reaches nothing: no git remote of that name, no file or folder, and
    no git url rule (insteadOf, pushInsteadOf; local or global) rewriting it."""
    try:
        p = subprocess.run(['git', 'remote', 'get-url', PROBE], capture_output=True, text=True,
                           timeout=10, stdin=subprocess.DEVNULL)
        if p.returncode == 0:
            return (f'live test: skip -- this project has a git remote named {PROBE}, '
                    'so the test push could reach it')
    except FileNotFoundError:
        pass    # no git: the push cannot run either
    except (OSError, subprocess.SubprocessError) as e:
        return f'live test: skip -- could not check for a git remote named {PROBE} ({type(e).__name__})'
    if os.path.lexists(PROBE):
        return (f'live test: skip -- there is a file or folder named {PROBE} in this folder, '
                'so the test push could reach it')
    # A url.<base>.insteadOf rule (this repo's config or the global one) can
    # turn the name into a real address: git then pushes THERE. ls-remote
    # --get-url applies those rules, so anything but the bare name means skip.
    # It does not apply pushInsteadOf, which only pushes use: read those
    # rules directly. Both match by prefix, so a rule for `bendit` counts.
    try:
        p = subprocess.run(['git', 'ls-remote', '--get-url', PROBE], capture_output=True, text=True,
                           timeout=10, stdin=subprocess.DEVNULL)
        if p.returncode != 0:
            return (f'live test: skip -- git could not say where {PROBE} points '
                    f'(exit {p.returncode}), so the test push might reach something')
        if p.stdout.strip() != PROBE:
            return (f'live test: skip -- a git url rule (insteadOf) turns {PROBE} into a real address, '
                    'so the test push could reach it')
        p = subprocess.run(['git', 'config', '--get-regexp', r'^url\..*\.pushinsteadof$'], capture_output=True,
                           text=True, timeout=10, stdin=subprocess.DEVNULL)
        if p.returncode not in (0, 1):
            return (f'live test: skip -- could not read git\'s url rules (exit {p.returncode}), '
                    'so the test push might reach something')
        for line in p.stdout.splitlines():
            value = line.split(' ', 1)[1] if ' ' in line else ''
            if PROBE.startswith(value):
                return (f'live test: skip -- a git url rule (pushInsteadOf) turns {PROBE} into a real '
                        'address for pushes, so the test push could reach it')
    except FileNotFoundError:
        pass    # no git: the push cannot run either
    except (OSError, subprocess.SubprocessError) as e:
        return f'live test: skip -- could not check where {PROBE} points ({type(e).__name__})'
    return f'live test: run -- nothing here is named {PROBE}, so the test push cannot reach anything'


def _under(path, folder):
    """Is <path> inside <folder>, comparing whole path components after
    resolving symlinks (so `cache-other` is not inside `cache`)?"""
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder.rstrip(os.sep) + os.sep)


def _this_project():
    """The project folder this window is about: $CLAUDE_PROJECT_DIR, else the
    git toplevel of the current folder, else the current folder."""
    env = os.environ.get('CLAUDE_PROJECT_DIR', '')
    if env and os.path.isdir(env):
        return env
    try:
        p = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True,
                           timeout=10, stdin=subprocess.DEVNULL)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def copy_line():
    """Which copy of bendit is running. `installed` ONLY when it is the very
    copy Claude Code recorded for THIS project at project scope (the entry's
    installPath is the same folder as the running root) and that entry's
    version is the running version: that is what a reopened window runs.
    Also `installed` (user scope) when this project records NO project-scope
    bendit and the running root is the recorded user-scope install at the
    running version: Claude Code loads that one here too. A project-scope
    install always wins, so with one recorded the user install never counts.
    Anything else keeps "reopen Claude": `installer copy` (the installer's
    download, which `bendit` starts with `claude --plugin-dir`, loading as
    bendit@inline, or any folder outside Claude's plugin cache) or `other copy`
    (in Claude's plugin cache, but not what this project loads: a user-scope
    copy where a project install exists, another project's, another version,
    or the record could not be read).
    In a linked git worktree whose MAIN checkout records bendit at project
    scope, "this project" is the main checkout: Claude Code loads its install
    there. The worktree's own record, when it differs, is a `note:` line (never
    a reason to update or reopen). Main recording none: the worktree's own."""
    root = os.environ.get('CLAUDE_PLUGIN_ROOT') or KIT
    home = os.path.expanduser('~')
    claude_dir = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(home, '.claude')
    installed = os.path.join(claude_dir, 'plugins', 'cache')
    installer = os.environ.get('BENDIT_CACHE') or os.path.join(
        os.environ.get('XDG_CACHE_HOME') or os.path.join(home, '.cache'), 'bendit')
    reopen = ('this window is not running the bendit installed for this project; '
              'close Claude and open it again to run that one')
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import features
        running = features.plugin_version()
        version = 'bendit ' + running
    except Exception as e:  # noqa: BLE001 -- the line still says which copy
        running, version = None, f'bendit, version unreadable ({type(e).__name__})'
    if _under(root, installer):
        return f"copy: installer copy ({version}, the installer's download at {root}) -- {reopen}"
    if not _under(root, installed):
        return f"copy: installer copy ({version}, loaded from {root}, not from Claude's plugin folder) -- {reopen}"
    project = _this_project()
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            '_installed_versions', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'installed-versions.py'))
        iv = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(iv)
        everything = iv.load_all(iv.default_plugins_file())
        projects = [e for e in everything if e['scope'] == 'project']
        mine = iv.installs_for(projects, project, 'bendit')
        users = [e for e in everything if e['scope'] == 'user' and e['name'] == 'bendit']
        # A linked worktree loads the MAIN checkout's project install (2026-11-23:
        # main 0.5.1 ran, the worktree's own record said 0.5.0, and `claude plugin
        # update` there said "already at the latest version"). Where main records
        # bendit, that is this window's install; the worktree's own record is a note.
        main = next((p for p, is_main in iv.checkouts(project) if is_main), None)
        own, via_main, main_none = [], None, None
        if main and not iv.same_path(main, project):
            mains = iv.installs_for(projects, main, 'bendit')
            if mains:
                own, mine, via_main = mine, mains, main
            elif mine:
                main_none = main
    except Exception as e:  # noqa: BLE001 -- unreadable: never "installed"
        return (f'copy: other copy ({version}, {root}; which bendit this project records could not be read: '
                f'{type(e).__name__}) -- {reopen}')
    note = ''
    if own and sorted(e['version'] for e in own) != sorted(e['version'] for e in mine):
        note = ('\nnote: this worktree (%s) also records bendit %s for its own folder; Claude Code loads the main '
                'checkout\'s install in a worktree, so that record is not used and needs no update'
                % (project, ', '.join(sorted({e['version'] for e in own}))))
    if main_none:
        # Unverified which install Claude Code loads here; installed-versions
        # says main is missing it (exit 1) with this same command.
        note = ("\nnote: the main checkout (%s) has no bendit install; Claude Code may load the main checkout's "
                'install for worktrees, so install it there too: cd %s && claude plugin install %s --scope project'
                % (main_none, iv.shlex.quote(main_none), mine[0]['id']))
    for e in mine:
        if e['install'] and running and e['version'] == running and iv.same_path(e['install'], root):
            if via_main:
                return (f"copy: installed ({version}, {root}; project scope: the main checkout's install "
                        f'({via_main}), which Claude Code loads in this worktree)') + note
            return f'copy: installed ({version}, {root}; project scope)' + note
    # No project-scope install here: Claude Code loads the user-scope one, so
    # a reopened window runs this same copy. A project install always wins.
    if not mine:
        for e in users:
            if e['install'] and running and e['version'] == running and iv.same_path(e['install'], root):
                return (f'copy: installed ({version}, {root}; user scope: this project ({project}) records no '
                        f'project-scope bendit, so a reopened window runs this same copy)')
    recorded = ', '.join(sorted({e['version'] for e in mine})) or 'none'
    whose = (f'the main checkout ({via_main}), whose install this worktree loads,' if via_main
             else f'this project ({project})')
    return (f'copy: other copy ({version}, {root}; {whose} records bendit {recorded} at '
            f'project scope) -- {reopen}') + note


def session_report():
    sid = os.environ.get('CLAUDE_CODE_SESSION_ID', '')
    name = marker_name(sid)
    rc = 1
    if not name:
        print('window: unknown -- Claude Code did not say which window this is '
              '(CLAUDE_CODE_SESSION_ID is not set), so the marker cannot be looked up')
        rc = 3
    elif os.path.isfile(os.path.join(live_dir(), name)):
        print(f"window: live -- bendit's hooks started in this Claude window (session {sid})")
        rc = 0
    else:
        bad = unwritable(live_dir())
        if bad:
            print(f"window: not live (can't write {bad}) -- no marker for this Claude window "
                  f'(session {sid}), and the start-up check could not have left one there')
        else:
            print(f"window: not live -- bendit's hooks did not start in this Claude window (session {sid}): "
                  'it was opened before bendit was set up, or bendit is not installed for this project')
    print(copy_line())
    print(live_test_line())
    return rc


def main(argv):
    if '--session' in argv:
        return session_report()
    if '--features' in argv:
        i = argv.index('--features')
        if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
            return features_report(argv[i + 1])
        env = os.environ.get('CLAUDE_PROJECT_DIR', '')
        if env and os.path.isdir(env):  # no path given: the session's project
            return features_report(env)
        print('usage: selfcheck.py --features <root>', file=sys.stderr)
        return 2
    hook = '--hook' in argv
    if hook:
        try:
            if not sys.stdin.isatty():
                # The SessionStart payload: nothing in it changes the check; its
                # session_id names this window's marker.
                mark_live(sys.stdin.read())
        except (OSError, ValueError):
            pass
    results, total = gather()
    broken = [r for r in results if not r['ok']]
    if hook:
        if broken:
            person, model = messages(broken, total)
            print(json.dumps({'systemMessage': person,
                              'hookSpecificOutput': {'hookEventName': 'SessionStart',
                                                     'additionalContext': model}}))
        return 0
    width = max([len('hook')] + [len(r['hook']) for r in results])
    ew = max([len('event')] + [len(r['event']) for r in results])
    print(f'bendit selfcheck: {KIT}')
    print()
    print(f'{"hook".ljust(width)} | {"event".ljust(ew)} | result')
    print(f'{"-" * width}-+-{"-" * ew}-+-------')
    for r in results:
        print(f'{r["hook"].ljust(width)} | {r["event"].ljust(ew)} | {"ok" if r["ok"] else "OFF"}')
    print()
    for r in broken:
        print(f'{r["hook"]}: {r["error"]}')
        print(f'  fix: {r["fix"]}')
    if broken:
        print(f'selfcheck: {len(broken)} problem(s) -- see above; the guards named are OFF or unchecked')
    else:
        print(f'selfcheck: all {total} hooks answered their probe')
    return 1 if broken else 0


if __name__ == '__main__':
    try:
        code = main(sys.argv[1:])
    except BaseException as e:  # last resort: still never a failed session start
        if '--hook' in sys.argv[1:]:
            print(json.dumps({'systemMessage': f'bendit: its self-check crashed ({type(e).__name__}: {e}); '
                                               'whether its guards work is UNKNOWN. Run /bendit:doctor.',
                              'hookSpecificOutput': {'hookEventName': 'SessionStart',
                                                     'additionalContext': 'bendit self-check crashed at session '
                                                     'start; treat its guards as OFF and tell the user.'}}))
            code = 0
        else:
            code = 2
    sys.exit(code)
