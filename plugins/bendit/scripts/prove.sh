#!/usr/bin/env bash
# Prove bendit works for a repo, and print the evidence as a table.
#
#   bash prove.sh <repo>
#
# What it runs -- every check is RUN and its output read, never inferred:
#   guards     every hook in this plugin's hooks/hooks.json is fed a known-bad
#              payload (must exit 2 with a reason on stderr that names
#              bendit, so a reader can tell WHICH kit refused) and a
#              known-good one (must exit 0); the probes live in probes.py,
#              shared with selfcheck.py. A hook with no probe there is a
#              FAILURE: this script cannot vouch for what it never fed.
#   stop gate  a dry run in a throwaway git repo under mktemp -d, with its own
#              session index: a harness that exits 1 must be refused (exit 2),
#              one that exits 0 must be allowed.
#   harness    <repo>/.claude/verify-harness, run as the Stop gate runs it
#              (non-comment lines, one sh script, from the repo root), with
#              BENDIT_KIT_ROOT pointing at this plugin. Missing is a FAIL.
#   privacy    the files bendit writes (AGENTS.md, CLAUDE.md, .claude/verify-harness,
#              .env.verify.example, .claude/bendit.json, .claude/skills/verify-*/)
#              carry no home path or email; only these can FAIL the row.
#              bendit.json is committed free text: each feature's `why` and the
#              session brief's config. Findings in any other .claude/skills/
#              file (another tool's) print as "notices (not failures)".
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
import json, os, shlex, shutil, signal, subprocess, sys, tempfile

kit, repo, w = sys.argv[1:4]
rows = []          # (check, state, rung, detail); state is PASS, FAIL or UNUSED
RUNG = '4'         # every row here was RUN and its output read


def row(check, state, detail=''):
    # state: 'PASS' / 'FAIL' for a check that ran; 'UNUSED' for a feature the
    # project does not use (not a failure, not a pass).
    assert state in ('PASS', 'FAIL', 'UNUSED'), state
    rows.append((check, state, RUNG, detail))


def short(text, n=300):
    text = ' | '.join(l for l in text.strip().splitlines() if l.strip())
    return text if len(text) <= n else text[:n] + '...'


# The probes and the env they run in are shared with selfcheck.py: one table.
sys.path.insert(0, os.path.join(kit, 'scripts'))
import probes as P  # noqa: E402
import features as F  # noqa: E402

probe, ENV = P.prepare(w)


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
        row(label, 'FAIL', f'exit {rc}, wanted 2 (a refusal){"; stderr: " + short(err) if err.strip() else ""}')
    elif not err.strip():
        row(label, 'FAIL', 'exit 2 but nothing on stderr: the agent is refused with no reason')
    elif not err.lstrip().startswith(P.PREFIXES):
        row(label, 'FAIL', 'refused, but stderr does not name bendit (it must begin '
                          '"[bendit]" or "BLOCKED by bendit"): ' + short(err, 160))
    else:
        row(label, 'PASS')


def allows(label, script, args, data, timeout, env=None):
    rc, _out, err = run_hook(script, args, data, timeout, env)
    if rc == 0:
        row(label, 'PASS')
    else:
        row(label, 'FAIL', f'exit {rc}, wanted 0{"; stderr: " + short(err) if err.strip() else ""}')


def silent(label, script, args, data, timeout, env=None):
    rc, out, err = run_hook(script, args, data, timeout, env)
    if rc == 0 and not out.strip():
        row(label, 'PASS')
    else:
        row(label, 'FAIL', f'exit {rc}, wanted 0 and no output'
            + (f'; stdout: {short(out)}' if out.strip() else '')
            + (f'; stderr: {short(err)}' if err.strip() else ''))


# --- the probes, one per hooks.json entry (scripts/probes.py) ----------------
# A hook without an entry there fails the run. Probes marked prove=False are
# selfcheck's: --mark and the Stop gate are proved by the dry run below.
CHECK = {'refuses': refuses, 'allows': allows, 'silent': silent}
try:
    entries = P.hook_entries(kit)
except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
    entries = []
    row('hooks.json is readable', 'FAIL', f'{type(e).__name__}: {e}')
timeouts, seen = {}, []
for event, _matcher, cmd, timeout in entries:
    key = P.hook_key(cmd)
    if key is None:
        row(f'{event} hook `{cmd[:50]}`', 'FAIL', 'prove.sh cannot read which script this runs')
        continue
    timeouts[key] = timeout
    if key not in seen:
        seen.append(key)
for key in seen:
    table = P.PROBES.get(key)
    if table is None:
        row(f'{" ".join((key[0],) + key[1])}: has a probe', 'FAIL',
            'hooks.json runs it, but scripts/probes.py has no known-bad/known-good payload for it -- add one')
        continue
    for pr in table:
        if pr.prove:
            CHECK[pr.expect](pr.label, key[0], list(key[1]), pr.build(probe), timeouts[key], P.env_for(pr, ENV, probe))
            # A probe that turned a feature on must not leave it on for the next probe.
            try:
                os.remove(F.path(probe))
            except FileNotFoundError:
                pass

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
    # The gate runs a harness only once the person has approved its exact
    # content. This dry-run harness is ours, in a throwaway repo, so it is
    # approved in a throwaway approval list -- never the person's real one.
    # Without this, "refuses when the harness exits 1" would pass because the
    # harness was NOT APPROVED, not because it failed.
    STOP_ENV = dict(ENV, BENDIT_CONFIG_DIR=os.path.join(w, 'trust'))
    gate_py = os.path.join(kit, 'scripts', 'require-verification.py')

    def harness(body):
        with open(os.path.join(s, '.claude', 'verify-harness'), 'w') as fh:
            fh.write(body + '\n')
        subprocess.run(['python3', '-c',
                        'import importlib.util, pathlib, sys\n'
                        'spec = importlib.util.spec_from_file_location("rv", sys.argv[1])\n'
                        'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
                        'm.trust_add(pathlib.Path(sys.argv[2]))',
                        gate_py, s], env=STOP_ENV, cwd=s, check=False,
                       capture_output=True, text=True)

    def mark():
        return run_hook('require-verification.py', ['--mark'],
                        json.dumps({'session_id': sid, 'cwd': s, 'hook_event_name': 'PostToolUse',
                                    'tool_name': 'Edit', 'tool_input': {'file_path': app}}), t_mark,
                        env=STOP_ENV, cwd=s)

    def stop():
        return run_hook('require-verification.py', [],
                        json.dumps({'session_id': sid, 'cwd': s, 'hook_event_name': 'Stop',
                                    'stop_hook_active': False}), t_stop, env=STOP_ENV, cwd=s)

    harness('exit 1')
    rc, _o, err = mark()
    pending = os.path.join(s, '.claude', '.bendit-state', f'pending-{sid}')
    if rc == 0 and os.path.isfile(pending):
        row('Stop gate: --mark records a code edit', 'PASS')
    else:
        row('Stop gate: --mark records a code edit', 'FAIL',
            f'exit {rc}, pending record {"present" if os.path.isfile(pending) else "NOT written"}'
            + (f'; stderr: {short(err)}' if err.strip() else ''))
    rc, _o, err = stop()
    label = 'Stop gate: refuses when the harness exits 1'
    if rc != 2:
        row(label, 'FAIL', f'exit {rc}, wanted 2' + (f'; stderr: {short(err)}' if err.strip() else ''))
    elif not err.lstrip().startswith(P.PREFIXES):
        row(label, 'FAIL', 'refused, but stderr does not name bendit: ' + short(err, 160))
    else:
        row(label, 'PASS')
    harness('exit 0')
    mark()
    rc, out, err = stop()
    label = 'Stop gate: allows when the harness exits 0'
    if rc == 0 and 'verified by' in out:
        row(label, 'PASS')
    else:
        row(label, 'FAIL', f'exit {rc}, wanted 0 and "verified by ..." on stdout'
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
    row(label, 'FAIL', 'no .claude/verify-harness: the Stop gate has nothing to run for this repo')
else:
    cmd = '\n'.join(l for l in open(declared, errors='replace').read().splitlines()
                    if l.strip() and not l.lstrip().startswith('#')).strip()
    if not cmd:
        row(label, 'FAIL', '.claude/verify-harness holds only comments: it would verify nothing')
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
            row(label, 'FAIL', f'did not finish in {budget:.0f}s (the Stop gate would refuse every turn)')
        elif rc != 0:
            row(label, 'FAIL', f'exit {rc}: {tail[-400:]}' if tail else f'exit {rc}, no output')
        elif before != after:
            row(label, 'FAIL', 'exit 0, but it changed the working tree: '
                + short('\n'.join(sorted(set(after.splitlines()) ^ set(before.splitlines())))))
        else:
            row(label, 'PASS')

    # The Stop gate runs this harness only once the PERSON has approved its exact
    # content. Read-only here: prove.sh never approves anything for the person.
    label = 'harness: approved by you for the Stop gate'
    chk = subprocess.run(
        ['python3', '-c',
         'import importlib.util, pathlib, sys\n'
         'spec = importlib.util.spec_from_file_location("rv", sys.argv[1])\n'
         'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
         'root = pathlib.Path(sys.argv[2]).resolve()\n'
         'print(m._trust_state(root, (root / ".claude" / "verify-harness").read_bytes()))\n'
         'print(m.trust_command(root))',
         os.path.join(kit, 'scripts', 'require-verification.py'), repo],
        capture_output=True, text=True, env=dict(os.environ))
    state, _, how = (chk.stdout.strip() + '\n\n').partition('\n')
    how = how.strip()
    if chk.returncode != 0:
        row(label, 'FAIL', 'could not read the approval list: ' + short(chk.stderr))
    elif state == 'trusted':
        row(label, 'PASS')
    else:
        why = {'never': 'never approved', 'changed': 'changed since you approved it'}.get(state, state)
        row(label, 'FAIL', f'{why}: the gate will refuse instead of running it. '
            f'In YOUR OWN terminal (not through the agent), run: {how}')

# --- the files adoption writes carry no personal data -------------------------------
# Only files bendit WRITES can fail this row. Another tool's skills in
# .claude/skills/ are scanned too, but a finding there is a notice: adoption is
# not "incomplete" for something bendit did not write.
owned = [f for f in ('AGENTS.md', 'CLAUDE.md', '.claude/verify-harness', '.env.verify.example',
                     '.claude/bendit.json')
         if os.path.isfile(os.path.join(repo, f))]
ls = subprocess.run(['git', '-C', repo, 'ls-files', '--cached', '--others', '--exclude-standard',
                     '--', '.claude/skills'], capture_output=True, text=True)
others = []
for f in ls.stdout.splitlines():
    if not f or not os.path.isfile(os.path.join(repo, f)):
        continue
    # .claude/skills/verify-*/** is the generated verification skill (bendit's)
    if f.startswith('.claude/skills/verify-'):
        owned.append(f)
    else:
        others.append(f)
label = 'privacy: agent-layer files carry no home path or email'
notices = []


def scan(files):
    return subprocess.run(['python3', os.path.join(kit, 'scripts', 'privacy-scan.py'), *files],
                          cwd=repo, capture_output=True, text=True, env=ENV)


if others:
    q = scan(others)
    if q.returncode != 0:
        notices = [l for l in q.stdout.splitlines() if l.strip() and not l.startswith('privacy-scan:')]
        if not notices:  # an unreadable file etc.: still say so
            notices = [l for l in q.stderr.splitlines() if l.strip()]
if not owned:
    row(label, 'FAIL', 'no agent-layer files to scan (no AGENTS.md, CLAUDE.md, .claude/verify-harness)')
else:
    p = scan(owned)
    row(label, 'PASS' if p.returncode == 0 else 'FAIL',
        '' if p.returncode == 0 else f'exit {p.returncode}: {short(p.stdout + p.stderr, 400)}')

# --- the project's features (.claude/bendit.json) ---------------------------------
# FEATURE_CHECKS maps a feature name to callable(repo, kit) -> (ok, detail): the
# check that proves the feature works when it is ON. Plan 3 fills it. A feature
# that is on with no check here is a FAIL: prove.sh will not vouch for what it
# cannot run.
def _check_ux_design_laws(repo, kit):
    """ON means the bendit-web add-on is installed for THIS project: an entry of
    `claude plugin list --json` with id bendit-web@bendit, project scope,
    enabled and projectEnabled (the per-project signal; `enabled` only means
    installed, and the list depends on the cwd, so it runs in the repo), and a
    projectPath that is this repo (realpaths compared). A
    project-scope entry for another project, or user scope alone, proves
    nothing about this one."""
    def norm(path):
        return os.path.realpath(path).rstrip('/')
    try:
        p = subprocess.run(['claude', 'plugin', 'list', '--json'], capture_output=True,
                           text=True, timeout=60, stdin=subprocess.DEVNULL, cwd=repo)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not check (claude plugin list failed: {type(e).__name__}: {e})'
    if p.returncode != 0:
        return False, f'could not check (claude plugin list failed: exit {p.returncode}: {short(p.stderr or p.stdout, 200)})'
    try:
        listed = json.loads(p.stdout)
        if not isinstance(listed, list):
            raise ValueError('not a list')
        mine = [e for e in listed if isinstance(e, dict) and e.get('id') == 'bendit-web@bendit']
    except ValueError as e:
        return False, f'could not check (claude plugin list failed: unreadable output: {e})'
    here = norm(repo)
    for e in mine:
        pp = e.get('projectPath')
        if e.get('scope') == 'project' and e.get('enabled') is True and e.get('projectEnabled') is True and isinstance(pp, str) and norm(pp) == here:
            return True, 'installed for this project'
    if any(e.get('scope') == 'project' and isinstance(e.get('projectPath'), str)
           and norm(e['projectPath']) == here for e in mine):
        return False, 'bendit-web is installed for this project but disabled'
    if any(e.get('scope') == 'user' for e in mine):
        return False, 'bendit-web is installed at user scope only, not for this project'
    return False, 'bendit-web is not installed here'


def _check_ls_guard(repo, kit):
    """ON means block-ls-parsing.py refuses a parsed `ls` with THIS project's
    settings: run the hook as hooks.json does, with the refusal payload, in a
    scratch project holding a copy of this repo's .claude/bendit.json, and read
    exit 2 plus a message naming bendit."""
    # Run in a throwaway copy of the project's settings, never in the project:
    # the refusal is prove's own test, and the guard logs every refusal to
    # its project's fires.jsonl. The guard reads only .claude/bendit.json.
    proj = os.path.join(w, 'ls-guard-project')
    try:
        os.makedirs(os.path.join(proj, '.claude'), exist_ok=True)
        shutil.copyfile(F.path(repo), F.path(proj))
    except OSError as e:
        return False, f'could not copy .claude/bendit.json to a scratch project: {type(e).__name__}: {e}'
    payload = json.dumps({'session_id': 'bendit-prove', 'cwd': proj, 'hook_event_name': 'PreToolUse',
                          'tool_name': 'Bash', 'tool_input': {'command': 'ls | wc -l'}})
    env = dict(ENV, CLAUDE_PROJECT_DIR=proj)
    try:
        p = subprocess.run(['python3', os.path.join(kit, 'scripts', 'block-ls-parsing.py')], input=payload,
                           capture_output=True, text=True, timeout=10, env=env, cwd=proj)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not run the hook: {type(e).__name__}: {e}'
    if p.returncode == 2 and p.stderr.lstrip().startswith(P.PREFIXES):
        return True, 'refuses `ls | wc -l` in this project'
    return False, f'exit {p.returncode} on `ls | wc -l`, wanted 2 with a message naming bendit' + (f'; stderr: {short(p.stderr, 200)}' if p.stderr.strip() else '')


def _check_session_brief(repo, kit):
    """ON means the brief, run on THIS repo in its manual mode (--cwd, the
    same code path the SessionStart hook builds with), prints exactly one valid
    JSON line whose context names the branch git says is checked out."""
    try:
        b = subprocess.run(['git', '-C', repo, 'branch', '--show-current'], capture_output=True,
                           text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not read the branch: {type(e).__name__}: {e}'
    branch = b.stdout.strip()
    if b.returncode != 0:
        return False, f'could not read the branch: git exited {b.returncode}: {short(b.stderr, 200)}'
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    env.pop('CLAUDE_PROJECT_DIR', None)
    try:
        p = subprocess.run(['python3', os.path.join(kit, 'scripts', 'session-brief.py'), '--cwd', repo],
                           capture_output=True, text=True, timeout=10, env=env, cwd=repo)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not run the brief: {type(e).__name__}: {e}'
    lines = p.stdout.splitlines()
    if p.returncode != 0 or len(lines) != 1:
        return False, f'exit {p.returncode}, {len(lines)} stdout lines, wanted exit 0 and one JSON line'
    try:
        ctx = json.loads(lines[0])['context']
    except (ValueError, KeyError, TypeError) as e:
        return False, f'its line is not the brief JSON: {type(e).__name__}: {e}'
    want = f'[git] Branch: {branch} ' if branch else '[git] Branch: detached at '
    if want not in ctx:
        return False, f'the brief does not name the checked-out branch ({want.strip()!r} missing): {short(ctx, 200)}'
    return True, f'briefs this repo on {branch or "a detached HEAD"}'


def _check_browser_driver(repo, kit):
    """ON means the browser driver runs on THIS machine: Playwright is installed
    where drive.mjs loads it from (drive-setup.sh --check), and the driver passes
    its own selftest -- a real browser filling and reading lib/drive/selftest's
    local page, compared with its committed baseline. No app is needed, and
    nothing is written in the repo: the run's cwd, evidence and temp files are
    all in a temp dir of its own, removed after."""
    setup = os.path.join(kit, 'scripts', 'drive-setup.sh')
    selftest = os.path.join(kit, 'lib', 'drive', 'selftest')
    try:
        c = subprocess.run(['bash', setup, '--check'], capture_output=True, text=True, timeout=30,
                           stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not run drive-setup.sh --check: {type(e).__name__}: {e}'
    if c.returncode != 0:
        return False, (f'Playwright is not installed for the browser driver (drive-setup.sh --check exit {c.returncode}). '
                       f'Install it with: bash {setup}')
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, TMPDIR=tmp)
        env.pop('PORT', None)
        try:
            p = subprocess.run(['node', os.path.join(kit, 'lib', 'drive', 'drive.mjs'),
                                os.path.join(selftest, 'pass.json'), '--base', 'file://' + selftest,
                                '--out', os.path.join(tmp, 'evidence')],
                               capture_output=True, text=True, timeout=120, env=env, cwd=tmp,
                               stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, f'could not run the driver selftest: {type(e).__name__}: {e}'
    if p.returncode == 0 and 'VERDICT: VERIFIED' in p.stdout:
        return True, 'Playwright installed; the driver passes its selftest in a real browser'
    out = (p.stdout + p.stderr).strip().splitlines()
    why = next((l for l in out if l.startswith(('FAIL', 'drive:'))), out[-1] if out else 'no output')
    return False, f'the driver selftest failed (exit {p.returncode}): {short(why, 300)}'


def _check_primary_checkout_guard(repo, kit):
    """ON means block-primary-checkout.py, run as hooks.json runs it, REFUSES an
    edit in a primary checkout on THIS repo's integration branch and ALLOWS the
    same edit from a linked worktree. The branch is resolved as the guard
    resolves it (integrationBranch in bendit.json, else origin/HEAD); none is
    not a PASS, because then the guard allows every edit. The two edits are
    made in a scratch repo under the temp dir on that branch, so the person's
    checkout is never touched and need not be on the branch right now."""
    entry = (F.load(repo) or {'features': {}})['features'].get('primary-checkout-guard') or {}
    branch, source = entry.get('integrationBranch'), 'integrationBranch in .claude/bendit.json'
    if not branch:
        source = 'origin/HEAD'
        try:
            r = subprocess.run(['git', '-C', repo, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'],
                               capture_output=True, text=True, timeout=10, env=ENV)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, f'could not read origin/HEAD: {type(e).__name__}: {e}'
        if r.returncode == 1 or (r.returncode == 0 and not r.stdout.strip()):
            return False, ('no integration branch: origin/HEAD is unset and .claude/bendit.json has no '
                           'integrationBranch, so the guard cannot tell main from any other branch and allows '
                           'every edit. Record one: python3 '
                           + shlex.quote(os.path.join(kit, 'scripts', 'features.py'))
                           + ' integration-branch ' + shlex.quote(repo) + ' <branch>')
        if r.returncode != 0:
            return False, f'could not read origin/HEAD: git exited {r.returncode}: {short(r.stderr, 200)}'
        ref = r.stdout.strip()   # the full name, as the guard reads it (never --short)
        if not ref.startswith('refs/remotes/origin/') or ref == 'refs/remotes/origin/':
            return False, f'origin/HEAD points at {ref!r}, not a branch of origin: the guard cannot use it'
        branch = ref[len('refs/remotes/origin/'):]
    s, wt = os.path.join(w, 'pcg-primary'), os.path.join(w, 'pcg-worktree')

    def git(*args):
        p = subprocess.run(['git', '-c', 'user.email=probe@bendit.invalid', '-c', 'user.name=bendit probe',
                            '-C', s, *args], capture_output=True, text=True, timeout=10, env=ENV)
        if p.returncode != 0:
            raise RuntimeError(f'git {" ".join(args)}: exit {p.returncode}: {short(p.stderr, 200)}')
    try:
        os.makedirs(s)
        git('init', '-q')
        git('symbolic-ref', 'HEAD', f'refs/heads/{branch}')
        probe_entry = {'on': True, 'why': 'bendit probe'}
        if source != 'origin/HEAD':
            probe_entry['integrationBranch'] = branch
        F.write(s, {'primary-checkout-guard': probe_entry})
        git('add', '-A')
        git('commit', '-qm', 'probe')
        if source == 'origin/HEAD':
            git('update-ref', f'refs/remotes/origin/{branch}', 'HEAD')
            git('symbolic-ref', 'refs/remotes/origin/HEAD', f'refs/remotes/origin/{branch}')
        git('worktree', 'add', '-q', wt, '-b', 'bendit-probe-worktree')
    except (OSError, RuntimeError, subprocess.TimeoutExpired, F.FeaturesError) as e:
        return False, f'could not build the scratch repo: {type(e).__name__}: {e}'

    def hook(where):
        data = json.dumps({'session_id': 'bendit-prove', 'cwd': where, 'hook_event_name': 'PreToolUse',
                           'tool_name': 'Edit', 'tool_input': {'file_path': os.path.join(where, 'app.py'),
                                                              'old_string': 'a', 'new_string': 'b'}})
        return subprocess.run(['python3', os.path.join(kit, 'scripts', 'block-primary-checkout.py')], input=data,
                              capture_output=True, text=True, timeout=10, cwd=where,
                              env=dict(ENV, CLAUDE_PROJECT_DIR=where))
    try:
        no, yes = hook(s), hook(wt)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f'could not run the hook: {type(e).__name__}: {e}'
    if no.returncode != 2 or not no.stderr.lstrip().startswith(P.PREFIXES) or 'worktree add' not in no.stderr:
        return False, (f'exit {no.returncode} on an edit in the primary checkout on {branch}, wanted 2 with a '
                       f'message naming bendit and `git worktree add`'
                       + (f'; stderr: {short(no.stderr, 200)}' if no.stderr.strip() else ''))
    if yes.returncode != 0:
        return False, (f'exit {yes.returncode} on the same edit from a linked worktree, wanted 0'
                       + (f'; stderr: {short(yes.stderr, 200)}' if yes.stderr.strip() else ''))
    return True, f'refuses an edit on {branch} ({source}) in a primary checkout; allows it in a worktree'


FEATURE_CHECKS = {
    'browser-driver': _check_browser_driver,
    'ux-design-laws': _check_ux_design_laws,
    'ls-guard': _check_ls_guard,
    'session-brief': _check_session_brief,
    'primary-checkout-guard': _check_primary_checkout_guard,
}
label = 'features: .claude/bendit.json readable'
feature_note = ''
try:
    feats = F.load(repo)
    row(label, 'PASS')
    feature_note = F.ignored_note(feats)
except F.FeaturesError as e:
    feats = None
    row(label, 'FAIL', str(e))
else:
    for name in F.FEATURES:
        label = f'feature: {name}'
        if feats is None:
            row(label, 'UNUSED', 'not set up by /bendit:adopt yet')
            continue
        entry = feats['features'].get(name)
        if entry is None:
            row(label, 'UNUSED', 'not listed in .claude/bendit.json')
        elif not entry['on']:
            row(label, 'UNUSED', entry['why'])
        elif name not in FEATURE_CHECKS:
            row(label, 'FAIL', f'no check for {name}')
        else:
            try:
                ok, detail = FEATURE_CHECKS[name](repo, kit)
            except Exception as e:  # a crashing check is a failed check
                ok, detail = False, f'check crashed: {type(e).__name__}: {e}'
            row(label, 'PASS' if ok else 'FAIL', detail)

# --- the table ------------------------------------------------------------------------
width = max([len('check')] + [len(r[0]) for r in rows])
print(f'bendit prove: {os.path.basename(repo)}')
print(f'kit:  {kit}')
print(f'repo: {repo}')
print()
print(f'{"check".ljust(width)} | result | evidence rung')
print(f'{"-" * width}-+--------+--------------')
for i, (check, state, rung, _d) in enumerate(rows, 1):
    print(f'{check.ljust(width)} | {state.ljust(6)} | {rung}')
failed = [(i, r) for i, r in enumerate(rows, 1) if r[1] == 'FAIL']
unused = [r for r in rows if r[1] == 'UNUSED']
print()
if unused:
    print('unused features (not failures):')
    for check, _s, _r, detail in unused:
        print(f'  {check}')
        print(f'    UNUSED  {detail}')
    print()
if feature_note:  # a newer bendit's feature, off: read past, said here
    print('notes (not failures):')
    print(f'  {feature_note}')
    print()
if notices:
    print('notices (not failures):')
    print("  in files bendit did not write (other tools' skills); they do not change the result")
    for line in notices:
        print(f'  {line}')
    print()
if failed:
    print('failures:')
    for i, (check, _s, _r, detail) in failed:
        print(f'  {check}')
        print(f'    {detail}')
    print()
    print(f'prove: {len(failed)} of {len(rows)} checks FAILED -- adoption is NOT complete')
else:
    print(f'prove: all {len(rows)} checks passed' + (f' ({len(unused)} unused)' if unused else ''))
print('not proved by this script: live wiring -- that Claude Code runs these hooks in a real')
print('session. Do the in-session check in references/prove.md (a refused force push whose')
print('message names bendit).')
sys.exit(1 if failed else 0)
PY
