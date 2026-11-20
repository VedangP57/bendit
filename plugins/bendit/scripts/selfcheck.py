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
older than 30 days are removed. No id, or no marker: never "live".

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

FIX_TCC = ('macOS is blocking access to the plugin folder: give your terminal app (Terminal, iTerm, '
           'your editor) Full Disk Access in System Settings > Privacy & Security, then restart it')
FIX_PERM = 'the file is not readable: reinstall (claude plugin install bendit@bendit) or restore its permissions'
FIX_PY = 'python3 is not on the PATH Claude Code runs hooks with: install Python 3.9+ or add it to that PATH'
FIX_MISSING = 'a file of the plugin is missing: reinstall (claude plugin install bendit@bendit)'
FIX_CRASH = 'the hook crashes: reinstall; if it persists, report it (SECURITY.md)'
FIX_OPEN = 'it runs but lets a known-bad call through: reinstall, or revert a local edit to it'
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
            if rc == 2 and err.lstrip().startswith(_probes.PREFIXES):
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
        print('fix: repair or delete .claude/bendit.json, then run /bendit:adopt')
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


def session_report():
    sid = os.environ.get('CLAUDE_CODE_SESSION_ID', '')
    name = marker_name(sid)
    if not name:
        print('window: unknown -- Claude Code did not say which window this is '
              '(CLAUDE_CODE_SESSION_ID is not set), so the marker cannot be looked up')
        return 3
    if os.path.isfile(os.path.join(live_dir(), name)):
        print(f"window: live -- bendit's hooks started in this Claude window (session {sid})")
        return 0
    print(f"window: not live -- bendit's hooks did not start in this Claude window (session {sid}): "
          'it was opened before bendit was set up, or bendit is not installed for this project')
    return 1


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
