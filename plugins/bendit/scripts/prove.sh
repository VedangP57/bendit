#!/usr/bin/env bash
# Prove bendit works for a repo, and print the evidence as a table.
#
#   bash prove.sh <repo>
#
# What it runs -- every check is RUN and its output read, never inferred:
#   guards     every hook in this plugin's hooks/hooks.json is fed a known-bad
#              payload (must exit 2 with a reason on stderr that names
#              bendit, so a reader can tell WHICH kit refused) and a
#              known-good one (must exit 0). A hook with no probe here is a
#              FAILURE: this script cannot vouch for what it never fed.
#   stop gate  a dry run in a throwaway git repo under mktemp -d, with its own
#              session index: a harness that exits 1 must be refused (exit 2),
#              one that exits 0 must be allowed.
#   harness    <repo>/.claude/verify-harness, run as the Stop gate runs it
#              (non-comment lines, one sh script, from the repo root), with
#              BENDIT_KIT_ROOT pointing at this plugin. Missing is a FAIL.
#   privacy    the agent-layer files (AGENTS.md, CLAUDE.md, .claude/verify-harness,
#              .env.verify.example, .claude/skills/) carry no home path or email.
#
# It writes NOTHING inside <repo>: probes, the scratch repo and every temp file
# live under one mktemp -d, removed by a trap. Its own git reads take no
# optional locks, so not even .git/index is refreshed. The one thing it runs IN
# the repo is the repo's harness, which does what it always does -- and if that
# leaves the working tree different (git status), the harness row FAILS.
#
# Not checked here, because a script cannot: that Claude Code actually RUNS the
# hooks (the live wiring check in skills/adopt-bendit/references/prove.md).
#
# exit: 0 every check passed · 1 a check failed · 2 usage (no repo, not git)
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 1 ] && [ -n "$1" ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; echo "prove: give exactly one repo path" >&2; exit 2; }
[ -d "$1" ] || { echo "prove: no such directory: $1" >&2; exit 2; }
export GIT_OPTIONAL_LOCKS=0
REPO="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "prove: $1 is not inside a git repository -- the Stop gate finds harnesses through git" >&2; exit 2; }

W="$(mktemp -d)" || { echo "prove: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM
export PYTHONDONTWRITEBYTECODE=1

python3 - "$KIT" "$REPO" "$W" <<'PY'
import json, os, re, signal, subprocess, sys

kit, repo, w = sys.argv[1:4]
rows = []          # (check, ok, rung, detail)
RUNG = '4'         # every row here was RUN and its output read
PREFIXES = ('[bendit]', 'BLOCKED by bendit')


def row(check, ok, detail=''):
    rows.append((check, ok, RUNG, detail))


def short(text, n=300):
    text = ' | '.join(l for l in text.strip().splitlines() if l.strip())
    return text if len(text) <= n else text[:n] + '...'


probe = os.path.join(w, 'probe')
os.makedirs(probe)
os.makedirs(os.path.join(w, 'tmp'))
# Guards may keep state (post-edit-review's pre-edit snapshot, the Stop gate's
# session index). All of it goes under w, never into a real cache or repo.
ENV = dict(os.environ, TMPDIR=os.path.join(w, 'tmp'),
           BENDIT_VERIFY_INDEX=os.path.join(w, 'index'),
           GIT_CEILING_DIRECTORIES=w, PYTHONDONTWRITEBYTECODE='1')


def payload(event, tool, tool_input, **extra):
    d = {'session_id': 'bendit-prove', 'cwd': probe,
         'hook_event_name': event, 'tool_name': tool, 'tool_input': tool_input}
    d.update(extra)
    return json.dumps(d)


def run_hook(script, args, data, timeout, env=None, cwd=probe):
    try:
        p = subprocess.run(['python3', os.path.join(kit, 'scripts', script), *args],
                           input=data, capture_output=True, text=True,
                           env=env or ENV, cwd=cwd, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, '', f'did not finish within its hooks.json timeout ({timeout}s)'
    except OSError as e:
        return None, '', f'could not start: {e}'


def refuses(label, script, args, data, timeout, env=None):
    rc, _out, err = run_hook(script, args, data, timeout, env)
    if rc != 2:
        row(label, False, f'exit {rc}, wanted 2 (a refusal){"; stderr: " + short(err) if err.strip() else ""}')
    elif not err.strip():
        row(label, False, 'exit 2 but nothing on stderr: the agent is refused with no reason')
    elif not err.lstrip().startswith(PREFIXES):
        row(label, False, 'refused, but stderr does not name bendit (it must begin '
                          '"[bendit]" or "BLOCKED by bendit"): ' + short(err, 160))
    else:
        row(label, True)


def allows(label, script, args, data, timeout, env=None):
    rc, _out, err = run_hook(script, args, data, timeout, env)
    if rc == 0:
        row(label, True)
    else:
        row(label, False, f'exit {rc}, wanted 0{"; stderr: " + short(err) if err.strip() else ""}')


def write_file(name, text):
    p = os.path.join(probe, name)
    with open(p, 'w') as fh:
        fh.write(text)
    return p


def bash(cmd):
    return payload('PreToolUse', 'Bash', {'command': cmd})


def bash_after(cmd, stdout):
    return payload('PostToolUse', 'Bash', {'command': cmd},
                   tool_response={'stdout': stdout, 'stderr': '', 'interrupted': False})


def writing(path, content):
    return payload('PreToolUse', 'Write', {'file_path': path, 'content': content})


def edited(path):
    return payload('PostToolUse', 'Edit', {'file_path': path})


# --- the probes, one per hooks.json entry ------------------------------------
# key: (script, args). A new hook without an entry here fails the run.
def p_dangerous(t):
    s = 'block-dangerous-bash.py'
    refuses('block-dangerous-bash: refuses `git push --force`', s, [], bash('git push --force bendit-probe HEAD'), t)
    allows('block-dangerous-bash: allows `git status`', s, [], bash('git status'), t)


def p_zsh(t):
    # Active only when $SHELL is zsh and zshGuard is on: both forced here, so
    # this proves the guard; whether it is live for THIS user is their shell.
    env = dict(ENV, SHELL='/bin/zsh')
    env.pop('CLAUDE_PLUGIN_OPTION_ZSHGUARD', None)
    s = 'block-zsh-wordsplit.py'
    refuses('block-zsh-wordsplit: refuses `for f in $files` (SHELL=zsh)', s, [],
            bash('for f in $files; do echo "$f"; done'), t, env)
    allows('block-zsh-wordsplit: allows `for f in "${arr[@]}"`', s, [],
           bash('for f in "${arr[@]}"; do :; done'), t, env)


def p_paths(t):
    s = 'path-contracts.py'
    refuses('path-contracts: refuses a write to x.gen.ts', s, [],
            writing(os.path.join(probe, 'x.gen.ts'), 'export const a = 1'), t)
    allows('path-contracts: allows a write to x.ts', s, [],
           writing(os.path.join(probe, 'x.ts'), 'export const a = 1'), t)


def p_review_pre(t):
    # --pre only stashes the file's prior content; by design it never blocks.
    allows('post-edit-review --pre: allows a write (snapshot only)', 'post-edit-review.py', ['--pre'],
           writing(os.path.join(probe, 'pre.ts'), 'export const a = 1'), t)


def p_review(t):
    s = 'post-edit-review.py'
    bad = write_file('bad.ts', 'try{ await go() }catch(e){ return NextResponse.json({ success: true, result: [] }) }')
    good = write_file('good.ts', 'export const add = (a: number, b: number) => a + b;\n')
    refuses('post-edit-review: flags a catch that returns success (advice)', s, [], edited(bad), t)
    allows('post-edit-review: silent on a clean edit', s, [], edited(good), t)


def p_stderr(t):
    s = 'warn-suppressed-stderr.py'
    refuses('warn-suppressed-stderr: flags `2>/dev/null` with empty output (advice)', s, [],
            bash_after('ls bendit-probe-missing 2>/dev/null', ''), t)
    allows('warn-suppressed-stderr: silent without the redirect', s, [],
           bash_after('ls bendit-probe-missing', ''), t)


def p_mark(t):
    pass    # exercised by the Stop gate dry run below, which needs its marks


def p_stamp(t):
    # --pre only stamps when a Bash call began; a PreToolUse exit 2 would DENY
    # the command, so by design it never blocks.
    allows('require-verification --pre: allows a Bash call (stamp only)', 'require-verification.py',
           ['--pre'], payload('PreToolUse', 'Bash', {'command': 'true'}, tool_use_id='bendit-prove'), t)


def p_stop(t):
    pass    # the dry run below


PROBES = {
    ('block-dangerous-bash.py', ()): p_dangerous,
    ('block-zsh-wordsplit.py', ()): p_zsh,
    ('path-contracts.py', ()): p_paths,
    ('post-edit-review.py', ('--pre',)): p_review_pre,
    ('post-edit-review.py', ()): p_review,
    ('warn-suppressed-stderr.py', ()): p_stderr,
    ('require-verification.py', ('--pre',)): p_stamp,
    ('require-verification.py', ('--mark',)): p_mark,
    ('require-verification.py', ()): p_stop,
}

try:
    hooks = json.load(open(os.path.join(kit, 'hooks', 'hooks.json')))['hooks']
except (OSError, ValueError, KeyError) as e:
    hooks = {}
    row('hooks.json is readable', False, f'{type(e).__name__}: {e}')
timeouts, seen = {}, []
for event, groups in hooks.items():
    for g in groups:
        for h in g.get('hooks', []):
            cmd = h.get('command', '')
            m = re.search(r'/scripts/([\w.-]+)"?((?:\s+--?[\w-]+)*)\s*$', cmd)
            if not m:
                row(f'{event} hook `{cmd[:50]}`', False, 'prove.sh cannot read which script this runs')
                continue
            key = (m.group(1), tuple(m.group(2).split()))
            timeouts[key] = h.get('timeout', 10)
            if key not in seen:
                seen.append(key)
for key in seen:
    fn = PROBES.get(key)
    if fn is None:
        row(f'{" ".join((key[0],) + key[1])}: has a probe', False,
            'hooks.json runs it, but prove.sh has no known-bad/known-good payload for it -- add one')
        continue
    fn(timeouts[key])

# --- the Stop gate, dry run -----------------------------------------------------
if ('require-verification.py', ()) in seen:
    t_stop = timeouts[('require-verification.py', ())]
    t_mark = timeouts.get(('require-verification.py', ('--mark',)), 10)
    s = os.path.join(w, 'stop-repo')
    os.makedirs(os.path.join(s, '.claude'))
    subprocess.run(['git', 'init', '-q', s], env=ENV, check=False)
    app = os.path.join(s, 'app.py')
    with open(app, 'w') as fh:
        fh.write('x = 1\n')
    sid = 'bendit-prove-stop'

    def harness(body):
        with open(os.path.join(s, '.claude', 'verify-harness'), 'w') as fh:
            fh.write(body + '\n')

    def mark():
        return run_hook('require-verification.py', ['--mark'],
                        json.dumps({'session_id': sid, 'cwd': s, 'hook_event_name': 'PostToolUse',
                                    'tool_name': 'Edit', 'tool_input': {'file_path': app}}), t_mark, cwd=s)

    def stop():
        return run_hook('require-verification.py', [],
                        json.dumps({'session_id': sid, 'cwd': s, 'hook_event_name': 'Stop',
                                    'stop_hook_active': False}), t_stop, cwd=s)

    harness('exit 1')
    rc, _o, err = mark()
    pending = os.path.join(s, '.claude', '.verify-state', f'pending-{sid}')
    if rc == 0 and os.path.isfile(pending):
        row('Stop gate: --mark records a code edit', True)
    else:
        row('Stop gate: --mark records a code edit', False,
            f'exit {rc}, pending record {"present" if os.path.isfile(pending) else "NOT written"}'
            + (f'; stderr: {short(err)}' if err.strip() else ''))
    rc, _o, err = stop()
    label = 'Stop gate: refuses when the harness exits 1'
    if rc != 2:
        row(label, False, f'exit {rc}, wanted 2' + (f'; stderr: {short(err)}' if err.strip() else ''))
    elif not err.lstrip().startswith(PREFIXES):
        row(label, False, 'refused, but stderr does not name bendit: ' + short(err, 160))
    else:
        row(label, True)
    harness('exit 0')
    mark()
    rc, out, err = stop()
    label = 'Stop gate: allows when the harness exits 0'
    if rc == 0 and 'verified by' in out:
        row(label, True)
    else:
        row(label, False, f'exit {rc}, wanted 0 and "verified by ..." on stdout'
            + (f'; stdout: {short(out)}' if out.strip() else '')
            + (f'; stderr: {short(err)}' if err.strip() else ''))

# --- the repo's own harness -------------------------------------------------------
def status():
    p = subprocess.run(['git', '-C', repo, 'status', '--porcelain', '--untracked-files=all'],
                       capture_output=True, text=True)
    return p.stdout


declared = os.path.join(repo, '.claude', 'verify-harness')
label = 'harness: .claude/verify-harness exits 0'
if not os.path.isfile(declared):
    row(label, False, 'no .claude/verify-harness: the Stop gate has nothing to run for this repo')
else:
    cmd = '\n'.join(l for l in open(declared, errors='replace').read().splitlines()
                    if l.strip() and not l.lstrip().startswith('#')).strip()
    if not cmd:
        row(label, False, '.claude/verify-harness holds only comments: it would verify nothing')
    else:
        try:
            budget = float(os.environ.get('BENDIT_HARNESS_TIMEOUT') or 300)
        except ValueError:
            budget = 300.0
        env = dict(os.environ)
        env.setdefault('BENDIT_KIT_ROOT', kit)
        before = status()
        p = subprocess.Popen(cmd, shell=True, cwd=repo, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            out, _ = p.communicate(timeout=budget)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            out, rc = (p.communicate()[0] or ''), None
        after = status()
        tail = ' | '.join(l for l in (out or '').strip().splitlines()[-4:])
        if rc is None:
            row(label, False, f'did not finish in {budget:.0f}s (the Stop gate would refuse every turn)')
        elif rc != 0:
            row(label, False, f'exit {rc}: {tail[-400:]}' if tail else f'exit {rc}, no output')
        elif before != after:
            row(label, False, 'exit 0, but it changed the working tree: '
                + short('\n'.join(sorted(set(after.splitlines()) ^ set(before.splitlines())))))
        else:
            row(label, True)

# --- the files adoption writes carry no personal data -------------------------------
cands = [f for f in ('AGENTS.md', 'CLAUDE.md', '.claude/verify-harness', '.env.verify.example')
         if os.path.isfile(os.path.join(repo, f))]
ls = subprocess.run(['git', '-C', repo, 'ls-files', '--cached', '--others', '--exclude-standard',
                     '--', '.claude/skills'], capture_output=True, text=True)
cands += [f for f in ls.stdout.splitlines() if f and os.path.isfile(os.path.join(repo, f))]
label = 'privacy: agent-layer files carry no home path or email'
if not cands:
    row(label, False, 'no agent-layer files to scan (no AGENTS.md, CLAUDE.md, .claude/verify-harness)')
else:
    p = subprocess.run(['python3', os.path.join(kit, 'scripts', 'privacy-scan.py'), *cands],
                       cwd=repo, capture_output=True, text=True, env=ENV)
    row(label, p.returncode == 0,
        '' if p.returncode == 0 else f'exit {p.returncode}: {short(p.stdout + p.stderr, 400)}')

# --- the table ------------------------------------------------------------------------
width = max([len('check')] + [len(r[0]) for r in rows])
print(f'bendit prove: {os.path.basename(repo)}')
print(f'kit:  {kit}')
print(f'repo: {repo}')
print()
print(f'{"check".ljust(width)} | result | evidence rung')
print(f'{"-" * width}-+--------+--------------')
for i, (check, ok, rung, _d) in enumerate(rows, 1):
    print(f'{check.ljust(width)} | {"PASS" if ok else "FAIL"}   | {rung}')
failed = [(i, r) for i, r in enumerate(rows, 1) if not r[1]]
print()
if failed:
    print('failures:')
    for i, (check, _ok, _r, detail) in failed:
        print(f'  {check}')
        print(f'    {detail}')
    print()
    print(f'prove: {len(failed)} of {len(rows)} checks FAILED -- adoption is NOT complete')
else:
    print(f'prove: all {len(rows)} checks passed')
print('not proved by this script: live wiring -- that Claude Code runs these hooks in a real')
print('session. Do the in-session check in references/prove.md (a refused force push whose')
print('message names bendit).')
sys.exit(1 if failed else 0)
PY
