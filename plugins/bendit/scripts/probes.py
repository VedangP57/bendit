"""The probe table: a known-bad and a known-good payload for every hook in
hooks/hooks.json. ONE definition, read by two callers:

  prove.sh      /adopt's proof -- feeds every probe marked `prove`, prints a table
  selfcheck.py  the SessionStart check -- fires ONE probe per hook (its refusal
                when it has one) to find a guard that can no longer run

Keyed by (script, args) as hook_key() reads them from a hooks.json command. A
hook with no entry here is a failure in both callers: neither can vouch for
what it never fed.

Each Probe is:
  expect   'refuses'  exit 2, reason on stderr that names bendit (PREFIXES)
           'allows'   exit 0
           'silent'   exit 0 and nothing on stdout
  label    the row prove.sh prints (its snapshot pins these words)
  build    build(probe_dir) -> the JSON payload for stdin; may write fixture
           files inside probe_dir, never anywhere else
  env      overrides for the hook's environment; None removes a variable
  prove    False: selfcheck only (prove.sh exercises that hook another way)

Standard library only; importable on Python 3.9.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features  # noqa: E402

PREFIXES = ('[bendit]', 'BLOCKED by bendit')

# `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/x.py" --flag` -> ('x.py', ('--flag',)).
# A trailing `|| <fallback>` (the SessionStart entry has one, so it can still
# speak when python3 cannot start) is not part of what runs the script.
_CMD = re.compile(r'/scripts/([\w.-]+)"?((?:\s+--?[\w-]+)*)\s*(?:\|\|.*)?$', re.S)


def hook_key(command):
    """(script, args) a hooks.json command runs, or None when it cannot be read."""
    m = _CMD.search(command or '')
    return (m.group(1), tuple(m.group(2).split())) if m else None


def hook_entries(kit):
    """Every hook in <kit>/hooks/hooks.json, in file order, as
    (event, matcher, command, timeout). Raises OSError / ValueError / KeyError /
    TypeError when the file cannot be read or is not the expected shape --
    callers report that, they never treat it as "no hooks"."""
    with open(os.path.join(kit, 'hooks', 'hooks.json')) as fh:
        hooks = json.load(fh)['hooks']
    out = []
    for event, groups in hooks.items():
        for g in groups:
            for h in g.get('hooks', []):
                out.append((event, g.get('matcher', ''), h.get('command', ''), h.get('timeout', 10)))
    return out


def prepare(w):
    """Make the probe and temp dirs under w; return (probe_dir, env). Guards
    may keep state (post-edit-review's pre-edit snapshot, the Stop gate's
    session index): all of it goes under w, never into a real cache or repo."""
    probe = os.path.join(w, 'probe')
    os.makedirs(probe, exist_ok=True)
    os.makedirs(os.path.join(w, 'tmp'), exist_ok=True)
    env = dict(os.environ, TMPDIR=os.path.join(w, 'tmp'),
               BENDIT_VERIFY_INDEX=os.path.join(w, 'index'),
               GIT_CEILING_DIRECTORIES=w, PYTHONDONTWRITEBYTECODE='1')
    return probe, env


HERE = object()  # in a probe's env: "the probe directory" (env_for fills it in)


def env_for(probe, base, probe_dir=None):
    """base with this probe's overrides applied (base itself when it has none).
    An override of HERE becomes probe_dir."""
    if not probe.env:
        return base
    env = dict(base)
    for k, v in probe.env.items():
        if v is None:
            env.pop(k, None)
        elif v is HERE:
            if probe_dir is None:
                raise ValueError('env_for: probe env uses HERE (the probe directory) but no probe_dir was given')
            env[k] = probe_dir
        else:
            env[k] = v
    return env


class Probe(object):
    __slots__ = ('expect', 'label', 'build', 'env', 'prove')

    def __init__(self, expect, label, build, env=None, prove=True):
        self.expect, self.label, self.build, self.env, self.prove = expect, label, build, env, prove


# --- payload builders ----------------------------------------------------------
def payload(d, event, tool, tool_input, **extra):
    p = {'session_id': 'bendit-prove', 'cwd': d,
         'hook_event_name': event, 'tool_name': tool, 'tool_input': tool_input}
    p.update(extra)
    return json.dumps(p)


def write_file(d, name, text):
    p = os.path.join(d, name)
    with open(p, 'w') as fh:
        fh.write(text)
    return p


def bash(cmd):
    return lambda d: payload(d, 'PreToolUse', 'Bash', {'command': cmd})


def bash_after(cmd, stdout):
    return lambda d: payload(d, 'PostToolUse', 'Bash', {'command': cmd},
                             tool_response={'stdout': stdout, 'stderr': '', 'interrupted': False})


def writing(name, content):
    return lambda d: payload(d, 'PreToolUse', 'Write', {'file_path': os.path.join(d, name), 'content': content})


def edited(name, content):
    return lambda d: payload(d, 'PostToolUse', 'Edit', {'file_path': write_file(d, name, content)})


# Active only when $SHELL is zsh and zshGuard is on: both forced here, so the
# probe proves the guard; whether it is live for THIS user is their shell.
ZSH = {'SHELL': '/bin/zsh', 'CLAUDE_PLUGIN_OPTION_ZSHGUARD': None}

# A feature-gated guard reads .claude/bendit.json from the project root, which
# features.project_root takes from CLAUDE_PROJECT_DIR before the payload's cwd.
# Inside a real Claude session that variable names the user's project, so the
# probe project must say where it lives or the probe would read the wrong file.
# Not a bypass: the probe's bendit.json is still written, and read, for real.
IN_PROBE_DIR = {'CLAUDE_PROJECT_DIR': HERE}


def feature_on(name, build):
    """Wrap a payload builder: write .claude/bendit.json with `name` on into
    the probe dir (features.write) before building the payload."""
    def go(d):
        features.write(d, {name: {'on': True, 'why': 'bendit probe'}})
        return build(d)
    return go


# --- the table, one entry per hooks.json entry -----------------------------------
PROBES = {
    ('block-dangerous-bash.py', ()): [
        Probe('refuses', 'block-dangerous-bash: refuses `git push --force`',
              bash('git push --force bendit-probe HEAD')),
        Probe('allows', 'block-dangerous-bash: allows `git status`', bash('git status')),
    ],
    ('block-zsh-wordsplit.py', ()): [
        Probe('refuses', 'block-zsh-wordsplit: refuses `for f in $files` (SHELL=zsh)',
              bash('for f in $files; do echo "$f"; done'), env=ZSH),
        Probe('allows', 'block-zsh-wordsplit: allows `for f in "${arr[@]}"`',
              bash('for f in "${arr[@]}"; do :; done'), env=ZSH),
    ],
    ('block-ls-parsing.py', ()): [
        Probe('refuses', 'block-ls-parsing: refuses `ls | wc -l` (ls-guard on)',
              feature_on('ls-guard', bash('ls | wc -l')), env=IN_PROBE_DIR),
        Probe('allows', 'block-ls-parsing: allows `ls -la` (ls-guard on)',
              feature_on('ls-guard', bash('ls -la')), env=IN_PROBE_DIR),
    ],
    ('path-contracts.py', ()): [
        Probe('refuses', 'path-contracts: refuses a write to x.gen.ts', writing('x.gen.ts', 'export const a = 1')),
        Probe('allows', 'path-contracts: allows a write to x.ts', writing('x.ts', 'export const a = 1')),
    ],
    # --pre only stashes the file's prior content; by design it never blocks.
    ('post-edit-review.py', ('--pre',)): [
        Probe('allows', 'post-edit-review --pre: allows a write (snapshot only)',
              writing('pre.ts', 'export const a = 1')),
    ],
    ('post-edit-review.py', ()): [
        Probe('refuses', 'post-edit-review: flags a catch that returns success (advice)',
              edited('bad.ts', 'try{ await go() }catch(e){ return NextResponse.json({ success: true, result: [] }) }')),
        Probe('allows', 'post-edit-review: silent on a clean edit',
              edited('good.ts', 'export const add = (a: number, b: number) => a + b;\n')),
    ],
    ('warn-suppressed-stderr.py', ()): [
        Probe('refuses', 'warn-suppressed-stderr: flags `2>/dev/null` with empty output (advice)',
              bash_after('ls bendit-probe-missing 2>/dev/null', '')),
        Probe('allows', 'warn-suppressed-stderr: silent without the redirect',
              bash_after('ls bendit-probe-missing', '')),
    ],
    # --pre only stamps when a Bash call began; a PreToolUse exit 2 would DENY
    # the command, so by design it never blocks.
    ('require-verification.py', ('--pre',)): [
        Probe('allows', 'require-verification --pre: allows a Bash call (stamp only)',
              lambda d: payload(d, 'PreToolUse', 'Bash', {'command': 'true'}, tool_use_id='bendit-prove')),
    ],
    # prove.sh exercises --mark and the Stop gate in its dry run (a scratch git
    # repo with a red and a green harness). selfcheck only needs to know they
    # still START: an edit outside any repo is marked as nothing, and a Stop
    # with nothing pending is allowed.
    ('require-verification.py', ('--mark',)): [
        Probe('allows', 'require-verification --mark: runs on an edit outside any repo',
              lambda d: payload(d, 'PostToolUse', 'Edit', {'file_path': os.path.join(d, 'a.py')}), prove=False),
    ],
    ('require-verification.py', ()): [
        Probe('allows', 'require-verification (Stop gate): allows a stop with nothing pending',
              lambda d: json.dumps({'session_id': 'bendit-prove', 'cwd': d, 'hook_event_name': 'Stop',
                                    'stop_hook_active': False}), prove=False),
    ],
    # The brief is advice and never refuses. With no bendit.json in the probe
    # dir (and CLAUDE_PROJECT_DIR pointed there, so a real session's project is
    # not read) it is off, and off must mean NO output at all.
    ('session-brief.py', ('--hook',)): [
        Probe('silent', 'session-brief --hook: silent with the feature off',
              lambda d: json.dumps({'session_id': 'bendit-prove', 'cwd': d, 'hook_event_name': 'SessionStart',
                                    'source': 'startup'}), env=IN_PROBE_DIR),
    ],
    # The self-check itself: on a working kit it must say NOTHING (exit 0 is not
    # enough -- it exits 0 even when it is shouting).
    ('selfcheck.py', ('--hook',)): [
        Probe('silent', 'selfcheck --hook: silent when every guard answers',
              lambda d: json.dumps({'session_id': 'bendit-prove', 'cwd': d, 'hook_event_name': 'SessionStart',
                                    'source': 'startup'})),
    ],
}
