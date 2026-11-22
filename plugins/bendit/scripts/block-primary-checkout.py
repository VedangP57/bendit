#!/usr/bin/env python3
"""Refuse an edit in the primary checkout while it is on the integration branch.

OFF BY DEFAULT. This guard runs only where the project's `.claude/bendit.json`
turns `primary-checkout-guard` on (/bendit:adopt --detailed asks; quick mode
never turns it on). Inspired by the "Worktree First" rule in poteto's noodle.

THE BUG: an agent that edits the primary checkout while it sits on the
integration branch (main) mixes its work into the one checkout everyone treats
as "what main is". Two sessions share one working tree, uncommitted edits ride
along into an unrelated commit, and `git status` on main stops meaning
anything. A linked worktree (`git worktree add`) gives each piece of work its
own folder and branch, and main changes only by merge.

WHAT IT FIRES ON: an Edit, Write, MultiEdit or NotebookEdit of a file that is
  - in the same repository as the project (same git common dir), and
  - in its PRIMARY checkout (git dir == common dir; a linked worktree has a
    git dir of its own under .git/worktrees/), and
  - while that checkout is on the integration branch: the feature's
    `integrationBranch` in bendit.json, else `origin/HEAD`.

THE DECISIONS THAT KEEP IT SAFE:
  feature off / absent             allow, without running git
  project not in a git repo        allow, without running git (no `.git` above it)
  file outside any repo, or in
    another repo                   allow: not this guard's business
  no integration branch resolves   allow (it cannot tell; prove.sh's row says why)
  detached HEAD, another branch,
    a linked worktree              allow
  feature on and git fails         REFUSE: missing, erroring, a corrupt .git
  bendit.json malformed            REFUSE, naming the file -- except an edit to
                                   that file itself, which is how it is fixed
  this script cannot start/crashes REFUSE (exit 2)
  git slower than GIT_BUDGET       REFUSE (one budget for every call, < the 10 s hook timeout)

Paths are compared by IDENTITY, never by spelling: the file's realpath (its own
symlink included) and os.path.samefile for git dirs, so a case variant on a
case-insensitive filesystem or a link from outside the repo is the same file.
"""
import io
import json
import os
import re
import shlex
import subprocess
import sys
import time

_STARTED = time.monotonic()

# Imported inside main(), under run()'s crash net: a broken features.py must
# exit 2 (refuse), not exit 1 (a non-blocking error).
features = None

# The rule id each refusal is logged under (fire_log.py), and the list
# /bendit:guard-report reads -- by PARSING this file, so it stays a literal.
# A crash that refuses is logged as guard-error and kept out of the list.
RULES = ['edit-on-integration-branch', 'cannot-tell-checkout']

GUARD = 'block-primary-checkout'
# Every git call shares ONE budget, counted from process start, so the whole
# decision ends well inside the hook's 10 s timeout (hooks.json): a hook that
# times out is a non-blocking error, which would let the edit through. Running
# out of budget refuses.
# The fire log adds no git of its own (_log_root), so budget + Python start-up
# + logging stays under 8 s.
GIT_BUDGET = 7.0

# Git variables that would point git somewhere other than the file's folder.
_GIT_ENV_DROP = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                 'GIT_OBJECT_DIRECTORY', 'GIT_NAMESPACE', 'GIT_PREFIX')

MESSAGE = '''BLOCKED by bendit: this edit is in the primary checkout of {top}, on `{branch}`, the integration branch ({source}).
primary-checkout-guard is on in .claude/bendit.json: work in a worktree, so `{branch}` changes only by merge.
Make one, then make this edit there:

    {command}

The file is then {moved}. (If that folder or branch already exists, pick another name.)
Turning the guard off is the person's call (/bendit:adopt --detailed), not yours.'''


class GitError(Exception):
    pass


class Unsure(Exception):
    """The guard is on but cannot tell where the edit lands: refuse."""


def target_path(payload):
    """The absolute path the tool would write, or None for a shape this guard
    does not understand (ignored, like junk)."""
    if not isinstance(payload, dict):
        return None
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        return None
    p = ti.get('file_path')
    if not isinstance(p, str) or not p:
        p = ti.get('notebook_path')
    if not isinstance(p, str) or not p or '\0' in p:
        return None
    if not os.path.isabs(p):
        cwd = payload.get('cwd')
        if not isinstance(cwd, str) or not cwd:
            return None
        p = os.path.join(cwd, p)
    # NOT normpath: it folds `link/../x` to `x` as text, but the kernel follows
    # `link` first and then `..`. existing_dir's realpath resolves in that
    # order (each symlink before the `..` after it).
    return p


def existing_dir(p):
    """(the nearest existing folder above the file, the file's real path).
    realpath resolves every symlink on the way, the FILE's own included: a
    link outside the repo that points into it edits the repo's file. A Write
    may create folders, so the folder is the nearest one that exists."""
    real = os.path.realpath(p)
    d = os.path.dirname(real)
    while not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return d, real


def same(a, b):
    """True when a and b are the same folder, by identity (device, inode),
    never by spelling: on a case-insensitive filesystem (macOS by default)
    .../PROJ/.git and .../proj/.git are one folder that compares unequal."""
    try:
        return os.path.samefile(a, b)
    except OSError as e:
        raise GitError('cannot compare %s and %s: %s' % (a, b, e))


def has_dot_git(d):
    """True when d or a folder above it has a `.git` entry, stopping where git
    would (GIT_CEILING_DIRECTORIES: git never moves UP into one). A filesystem
    walk, so "not a git repo" is known without running git."""
    ceilings = set()
    for c in os.environ.get('GIT_CEILING_DIRECTORIES', '').split(':'):
        if c:
            ceilings.add(os.path.realpath(c))
    d = os.path.realpath(d)
    while True:
        if os.path.lexists(os.path.join(d, '.git')):
            return True
        parent = os.path.dirname(d)
        if parent == d or parent in ceilings:
            return False
        d = parent


def git(d, *args, ok_codes=(0,)):
    """(exit code, stdout) of `git -C d args`; GitError when git cannot run or
    exits with a code not in ok_codes."""
    env = {k: v for k, v in os.environ.items() if k not in _GIT_ENV_DROP}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    left = GIT_BUDGET - (time.monotonic() - _STARTED)
    late = GitError('git did not answer within this guard\'s %gs budget (the hook is killed at 10 s, '
                    'which would let the edit through); stuck at `git %s`' % (GIT_BUDGET, ' '.join(args)))
    if left <= 0.05:
        raise late
    try:
        p = subprocess.run(['git', '-C', d] + list(args), capture_output=True, text=True,
                           timeout=left, env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise GitError('git is not installed (or not on PATH)')
    except subprocess.TimeoutExpired:
        raise late
    except (OSError, ValueError) as e:
        raise GitError('git could not run: %s' % e)
    if p.returncode not in ok_codes:
        err = ' '.join(p.stderr.split())[:200] or 'no message'
        raise GitError('`git %s` exited %d in %s: %s' % (' '.join(args), p.returncode, d, err))
    return p.returncode, p.stdout


def git_dirs(d):
    """(git dir, common dir), both real absolute paths, for the repo holding d."""
    _rc, out = git(d, 'rev-parse', '--git-dir', '--git-common-dir')
    lines = out.splitlines()
    if len(lines) != 2 or not all(lines):
        raise GitError('`git rev-parse --git-dir --git-common-dir` gave %r in %s' % (out[:200], d))
    return tuple(os.path.realpath(os.path.join(d, x)) for x in lines)


def integration_branch(entry, d):
    """(branch, where it came from), or (None, None) when nothing says."""
    b = entry.get('integrationBranch')
    if b:
        return b, 'integrationBranch in .claude/bendit.json'
    # Full ref names, never --short: --short turns origin/main into
    # remotes/origin/main when a tag or branch named origin/main exists.
    rc, out = git(d, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD', ok_codes=(0, 1))
    name = out.strip()
    prefix = 'refs/remotes/origin/'
    if rc == 1 or not name.startswith(prefix) or name == prefix:
        return None, None
    return name[len(prefix):], 'origin/HEAD'


def worktree_command(top, f):
    stem = os.path.splitext(os.path.basename(f))[0]
    slug = re.sub(r'[^a-z0-9]+', '-', stem.lower()).strip('-')[:30].strip('-') or 'work'
    branch = 'edit-' + slug
    wt = top + '-' + branch
    rel = os.path.relpath(f, top)
    cmd = 'git -C %s worktree add %s -b %s' % (shlex.quote(top), shlex.quote(wt), branch)
    return cmd, shlex.quote(os.path.join(wt, rel))


def decide(payload, root, entry):
    """The refusal message, or None to allow. Raises Unsure when it must refuse
    because git cannot answer."""
    f = target_path(payload)
    if f is None:
        return None
    if not has_dot_git(root):
        return None                      # the project is not a git repo
    d, real_f = existing_dir(f)
    if not has_dot_git(d):
        return None                      # the file is outside any repo
    try:
        gitdir, common = git_dirs(d)
        _g, root_common = git_dirs(root)
        if not same(common, root_common):
            return None                  # another repository
        if not same(gitdir, common):
            return None                  # a linked worktree
        # Full ref name: --short says heads/main when a tag named main exists,
        # which would never equal the integration branch (an allow).
        rc, out = git(d, 'symbolic-ref', '--quiet', 'HEAD', ok_codes=(0, 1))
        ref = out.strip()
        if rc == 1 or not ref.startswith('refs/heads/') or ref == 'refs/heads/':
            return None                  # detached HEAD
        branch = ref[len('refs/heads/'):]
        integ, source = integration_branch(entry, d)
        if integ is None or branch != integ:
            return None
        if os.path.basename(common) == '.git':
            top = os.path.dirname(common)
        else:
            _rc, out = git(d, 'rev-parse', '--show-toplevel')
            top = os.path.realpath(out.strip())
    except GitError as e:
        raise Unsure(str(e))
    command, moved = worktree_command(top, real_f)
    return MESSAGE.format(top=shlex.quote(top), branch=branch, source=source,
                          command=command, moved=moved)


def no_bendit_json(payload):
    """True only when the project certainly has no .claude/bendit.json: one
    stat before anything is imported, since this runs on every edit. Anything
    unclear returns False and takes the full path, which fails closed."""
    root = os.environ.get('CLAUDE_PROJECT_DIR')
    if not root:
        cwd = payload.get('cwd') if isinstance(payload, dict) else None
        root = cwd if isinstance(cwd, str) and cwd else None
    if not root:
        return False
    try:
        os.stat(os.path.join(root, '.claude', 'bendit.json'))
    except FileNotFoundError:
        return True
    except (OSError, ValueError):
        return False
    return False


def _describe(exc):
    try:
        return '%s: %s' % (type(exc).__name__, exc)
    except BaseException:
        try:
            return type(exc).__name__
        except BaseException:
            return 'an error that could not be described'


def could_not_start(exc):
    return ('[bendit] BLOCKED: bendit guard %s could not start: %s; refusing to be safe. '
            'Run /bendit:doctor.' % (GUARD, _describe(exc)))


def _say(msg):
    """Print a refusal; if that fails, write a fixed one straight to fd 2."""
    try:
        print(msg, file=sys.stderr)
        sys.stderr.flush()
    except BaseException:
        try:
            os.write(2, b'[bendit] BLOCKED: bendit guard block-primary-checkout failed and could not '
                        b'say why; refusing to be safe. Run /bendit:doctor.\n')
        except BaseException:
            pass


def main():
    global features
    try:
        payload = json.loads(sys.stdin.buffer.read().decode('utf-8', 'surrogateescape'))
    except ValueError:
        payload = None
    if no_bendit_json(payload):
        return 0
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    # This guard's own helper. A helper that exits on import raises SystemExit
    # (exit 0: the edit goes through), so this net catches everything.
    try:
        import features as _features
    except BaseException as exc:  # noqa: B036 -- SystemExit from a helper included
        _say(could_not_start(exc))
        _record_fire(payload, 'guard-error', '')
        return 2
    features = _features
    root = features.project_root(payload)
    try:
        data = features.load(root)
    except features.FeaturesError as e:
        f = target_path(payload)
        if f is not None and os.path.realpath(f) == os.path.realpath(features.path(root)):
            return 0                     # editing the broken file is how it gets fixed
        _say('BLOCKED by bendit: `.claude/bendit.json` is unreadable: %s\n'
             'primary-checkout-guard cannot tell whether it is on, so edits are refused until the '
             'file is fixed: fix .claude/bendit.json itself (that edit is allowed), or ask the person.' % e)
        _record_fire(payload, 'cannot-tell-checkout', target_path(payload) or '')
        return 2
    entry = (data or {'features': {}})['features'].get('primary-checkout-guard')
    if not entry or not entry['on']:
        return 0
    try:
        msg = decide(payload, root, entry)
    except Unsure as e:
        _say('BLOCKED by bendit: primary-checkout-guard is on, but git could not say whether this edit is '
             'in the primary checkout on the integration branch: %s\nRefusing rather than guessing. '
             'Fix git here (or ask the person), then retry.' % e)
        _record_fire(payload, 'cannot-tell-checkout', target_path(payload) or '')
        return 2
    if msg is None:
        return 0
    _say(msg)
    _record_fire(payload, 'edit-on-integration-branch', target_path(payload) or '')
    return 2


def run():
    try:
        return main()
    # Exit 1 is non-blocking to a hook, and a SystemExit or KeyboardInterrupt
    # from a helper exits 0 or 130: every one of them refuses instead.
    except BaseException as e:
        _say('BLOCKED by bendit: %s crashed (%s); refusing rather than letting the edit '
             'through unchecked.' % (GUARD, _describe(e)))
        _record_fire(None, 'guard-error', '')
        return 2


def _log_root(payload):
    """Where the fire log goes: the folder holding `.git` (a dir, or a
    worktree's .git file) at or above CLAUDE_PROJECT_DIR, else the payload's
    cwd -- what fire_log.project_root gets from `git rev-parse --show-toplevel`,
    found without running git, so logging cannot spend time past GIT_BUDGET.
    None (no log) when there is no start or no .git above it."""
    start = os.environ.get('CLAUDE_PROJECT_DIR')
    if not start:
        cwd = payload.get('cwd') if isinstance(payload, dict) else None
        start = cwd if isinstance(cwd, str) and cwd else None
    if not start or not os.path.isdir(start):
        return None
    d = os.path.realpath(start)
    while True:
        if os.path.lexists(os.path.join(d, '.git')):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _record_fire(payload, rule, preview):
    """Log this refusal (fire_log.py). Called only AFTER the decision is
    printed, inside a net that catches everything, with stdout and stderr
    held, so the exit code and every byte printed are the same whether or not
    the log was written."""
    saved = sys.stdout, sys.stderr
    try:
        sys.stderr.flush()
        sys.stdout.flush()
        sys.stdout = sys.stderr = io.StringIO()
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fire_log
        fire_log.record(_log_root(payload), GUARD, rule, preview)
    except BaseException:
        pass
    finally:
        sys.stdout, sys.stderr = saved


if __name__ == '__main__':
    try:
        _code = run()
    except BaseException:   # last resort: the net itself failed
        os._exit(2)
    sys.exit(_code)
