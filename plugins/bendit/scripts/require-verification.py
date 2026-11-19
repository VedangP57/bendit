#!/usr/bin/env python3
"""Refuse to end a turn that edited code without verifying it.

Commands are guidance: nothing makes the model run /bendit:verify, and
guidance alone is followed inconsistently. A Stop hook is the only place in
Claude Code that can actually require something -- exit 2 refuses the stop and
the reason goes back to the model.

WHAT VERIFIES A REPO, in order:
  1. a `verified` stamp newer than the edits (scripts/verify.sh writes it);
  2. a skip note newer than the edits, with a one-line reason (shown to the user);
  3. `.claude/verify-harness` in the project: a command the gate RUNS, exit 0
     verifying the change and anything else refusing the stop;
  4. otherwise the gate asks for a `verify-*` skill (/bendit:verify),
     or for one to be scaffolded, or for a recorded reason.

Two modes:
  --mark   PostToolUse(Edit|Write|MultiEdit|Bash): record that code changed, in
           the repo that holds the file, and index that repo under the session
  (none)   Stop: block if code changed in ANY repo this session marked and
           nothing verified it since

Escaping is deliberately possible but never silent: the model writes a one-line
reason into the skip file, and that reason is shown to the user. A gate you
cannot escape gets disabled; a gate whose bypass is invisible is theatre.

The same holds for the one let-through the gate grants on its own: a Stop that
arrives with `stop_hook_active` (this gate already refused once this turn) is
not refused again -- that would trap the session in a loop -- but it is shown
to the user and recorded, never waved through in silence.

CHANNELS. A refusal is exit 2 with the reason on stderr: that is the documented
block (`decision: "block"`, the reason handed back to the model). Anything said
while ALLOWING the stop -- a skip reason, which harness verified the change, a
let-through -- is printed as JSON `{"systemMessage": ...}` on stdout with exit 0,
because stderr on exit 0 reaches nobody in an ordinary session.

FAILS CLOSED. A crash in the Stop gate refuses the stop (exit 2, reason on
stderr) unless the gate already refused once this turn; a crash in --mark is
said on stderr with exit 2, so the agent knows the edit may be unrecorded.

Environment: BENDIT_HARNESS_TIMEOUT (seconds, the declared-harness budget),
BENDIT_VERIFY_INDEX (directory of the per-session repo index; default
${XDG_CACHE_HOME:-~/.cache}/bendit/verify-sessions).
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


# What counts as code. Deliberately broad: a narrower list (once just the JS/TS
# family plus .sql) exempted every Python or shell edit -- including this gate
# and the guards beside it -- from the gate.
CODE = {
    '.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs',
    '.vue', '.svelte', '.astro',
    '.sql',
    '.py', '.sh', '.bash', '.zsh',
    '.go', '.rs', '.rb', '.php', '.java', '.kt', '.kts', '.swift', '.dart',
    '.c', '.h', '.cc', '.cpp', '.hpp', '.m', '.mm', '.cs',
}
# Generated or vendored trees, matched against the path RELATIVE TO THE REPO.
# Matching any absolute path component skipped a whole repo that happened to sit
# under a directory called `build`.
SKIP_DIRS = {'node_modules', '.next', 'dist', 'build'}

STALE_AFTER = 7 * 24 * 60 * 60
# Long enough for a real suite, short enough that a hung command does not hold a
# turn open for ever. A timeout is a REFUSAL, never a pass.
#
# This is a budget for EVERY declared harness this Stop runs, and it must stay
# below the Stop hook's own `timeout` in hooks.json -- with margin for git and
# start-up. When the engine's timeout fires first the hook is killed and its
# verdict is lost; when this fires first the gate says so and refuses. A Stop
# timeout shorter than the harness means the gate can never finish at all.
# require-verification.test.sh asserts the ordering from hooks.json, so the
# two numbers cannot drift apart.
HARNESS_TIMEOUT = 300
# A git step and the edit it carries can arrive in ONE Bash call (`sed -i ... &&
# git commit -am ...`). A commit made by the command itself is recent; a commit
# a checkout or a pull brought in was made elsewhere, earlier. 600s is the Bash
# tool's own maximum foreground timeout, so no single command can commit
# earlier than this and still be the command being reported.
RECENT_COMMIT_WINDOW = 600


def harness_budget() -> float:
    raw = os.environ.get('BENDIT_HARNESS_TIMEOUT', '')
    try:
        v = float(raw)
        if v > 0:
            return v
    except ValueError:
        pass
    return float(HARNESS_TIMEOUT)


_ROOTS: dict = {}


def repo_root(start: Path):
    key = str(start)
    if key in _ROOTS:
        return _ROOTS[key]
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=start,
                             capture_output=True, text=True, timeout=5)
        root = Path(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None
    except Exception:
        root = None
    _ROOTS[key] = root
    return root


def state_dir(root: Path) -> Path:
    d = root / '.claude' / '.verify-state'
    d.mkdir(parents=True, exist_ok=True)
    return d


# Every hook payload carries `session_id` as a common field. With one global
# `pending` file, an edit made by a different session days earlier blocked this
# one, and the message blamed this session for an edit it had not made.
#
# `pending` and `skipped` are now per session -- a turn answers for its own work,
# and one session's skip does not excuse another's edits.
#
# `verified` stays GLOBAL on purpose. verify.sh writes it and is a shell script
# run as a command, not a hook, so it has no session id; and "the harness ran and
# passed on this repo at time T" is a fact about the repo, not about who ran it.
def session_of(payload) -> str:
    sid = payload.get('session_id') if isinstance(payload, dict) else None
    if not isinstance(sid, str) or not sid.strip():
        return 'nosession'
    safe = ''.join(c for c in sid if c.isalnum() or c in '-_')[:64]
    return safe or 'nosession'


# THE SESSION INDEX. Marks are written under the EDITED FILE's repo, but Stop
# used to read only the cwd's repo -- so an edit in a sibling repo was recorded
# and then never checked. Every repo a session marks is listed here, keyed by
# session, and Stop walks the list. It lives outside every repo because the
# session may have no repo of its own (cwd above several checkouts).
def index_dir() -> Path:
    override = os.environ.get('BENDIT_VERIFY_INDEX')
    if override:
        return Path(override)
    cache = os.environ.get('XDG_CACHE_HOME') or str(Path.home() / '.cache')
    return Path(cache) / 'bendit' / 'verify-sessions'


def _index_add(sid: str, roots) -> None:
    try:
        d = index_dir()
        d.mkdir(parents=True, exist_ok=True)
        f = d / sid
        have = f.read_text().splitlines() if f.is_file() else []
        new = [str(r) for r in roots if str(r) not in have]
        if new:
            f.write_text('\n'.join(have + new) + '\n')
        else:
            os.utime(f)
    except OSError:
        pass


def _index_roots(sid: str) -> list:
    try:
        d = index_dir()
        if d.is_dir():
            prune(d)
        f = d / sid
        return [Path(x) for x in f.read_text().splitlines() if x.strip()] if f.is_file() else []
    except OSError:
        return []


def prune(d: Path) -> None:
    """Drop state from sessions that ended long ago, so it cannot accumulate."""
    cutoff = time.time() - STALE_AFTER
    try:
        for f in d.iterdir():
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
    except OSError:
        pass


def _git(root: str, *args, stdin: str | None = None, timeout: int = 10):
    try:
        return subprocess.run(['git', '-C', root, *args], input=stdin,
                              capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def _dirty_in(root: str) -> set | None:
    """Absolute paths git reports as changed in `root`, or None if it cannot say.

    None means "do not filter" -- no repo, no git, a timeout. The gate must
    fail closed: dropping a file because the check itself failed is how a gate
    stops firing without anyone noticing.
    """
    r = _git(root, 'status', '--porcelain', '-z', '--untracked-files=all')
    if r is None or r.returncode != 0:
        return None
    out = set()
    # -z records are NUL-separated and never quoted. A rename/copy record is
    # followed by a SECOND record holding the source path, which must be
    # consumed or it would be read as a status line and dropped.
    parts = [x for x in r.stdout.split('\0') if x != '']
    i = 0
    while i < len(parts):
        rec = parts[i]
        i += 1
        if len(rec) < 4:
            continue
        xy, path = rec[:2], rec[3:]
        out.add(os.path.realpath(os.path.join(root, path)))
        if xy[0] in ('R', 'C') and i < len(parts):
            out.add(os.path.realpath(os.path.join(root, parts[i])))
            i += 1
    return out


def _ignored_in(root: str, rels: list) -> set | None:
    """The subset of `rels` (repo-relative) that git ignores, or None if unknown.

    `git status` does not list an ignored file at all, so a shell edit to one
    looked exactly like a clean file and was dropped. No checkout or pull ever
    writes an ignored file -- git does not manage it -- so if the command changed
    one, the command wrote it.
    """
    r = _git(root, 'check-ignore', '-z', '--stdin', stdin='\0'.join(rels) + '\0')
    # 0: some ignored, 1: none ignored. Anything else is git failing.
    if r is None or r.returncode not in (0, 1):
        return None
    return {x for x in r.stdout.split('\0') if x}


def _recently_committed(root: str) -> set | None:
    """Repo-relative paths touched by commits made within the window, or None."""
    since = int(time.time()) - RECENT_COMMIT_WINDOW
    r = _git(root, 'log', f'--since=@{since}', '--format=', '--name-only', '-z', 'HEAD')
    if r is None:
        return None
    if r.returncode != 0:
        # A repo with no commits has no HEAD: nothing was committed, recently or
        # otherwise. Any other failure is "cannot say".
        head = _git(root, 'rev-parse', '--verify', '-q', 'HEAD')
        return set() if head is not None and head.returncode == 1 else None
    return {x.strip('\n') for x in r.stdout.split('\0') if x.strip('\n')}


def only_dirty(paths: list) -> list:
    """Drop files a GIT STEP moved, keep files somebody edited.

    The shape that needs it: one Bash call runs
    `git stash push … && git checkout <branch> && git pull`, and the Stop hook
    would demand verification of every file the branch switch and the pull
    carried in. The Bash tool reports what the WORKING TREE
    changed, which is not the same question as what the agent edited, and
    Claude Code's own annotation on that call said as much.

    A file a checkout or a pull brought in matches the new HEAD, and the commit
    that put it there was made elsewhere, earlier. A file somebody edited does
    not match -- and neither does one restored by `git stash pop`, `git apply`,
    `git checkout <ref> -- <file>` or `git restore --source`. Those keep
    demanding verification, which is the half that must not regress.

    Two shapes LOOK clean and are still edits, so they are kept too:
      - a file the same command edited and then committed (`git commit -am`):
        clean against the new HEAD, but HEAD was made seconds ago;
      - a gitignored file: `git status` never lists it, and no git step writes it.
    """
    groups: dict = {}
    for raw in paths:
        anchor = Path(raw).parent
        while not anchor.exists() and anchor != anchor.parent:
            anchor = anchor.parent
        root = repo_root(anchor)
        groups.setdefault(str(root) if root else None, []).append(raw)
    kept = []
    for root, group in groups.items():
        if root is None:
            kept += group                 # not in a repo: cannot check, so keep
            continue
        dirty = _dirty_in(root)
        if dirty is None:
            kept += group
            continue
        rest = []
        for raw in group:
            (kept if os.path.realpath(raw) in dirty else rest).append(raw)
        if not rest:
            continue
        real_root = os.path.realpath(root)
        rels = {}
        for raw in rest:
            try:
                rels[raw] = os.path.relpath(os.path.realpath(raw), real_root)
            except ValueError:
                rels[raw] = None
        if any(v is None or v.startswith('..') for v in rels.values()):
            kept += rest                  # cannot place it in the repo: keep
            continue
        ignored = _ignored_in(root, list(rels.values()))
        recent = _recently_committed(root)
        for raw in rest:
            if ignored is None or recent is None:
                kept.append(raw)          # cannot say: fail closed
            elif rels[raw] in ignored or rels[raw] in recent:
                kept.append(raw)
    return kept


def mark(raw: str) -> int:
    try:
        payload = json.loads(raw)
    except ValueError:
        return 0
    # Not a hook payload of any shape this hook knows: nothing names a file.
    if not isinstance(payload, dict):
        return 0
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        ti = {}
    named = ti.get('file_path') or ti.get('path') or ''
    # Filter by suffix FIRST: every later step costs a git call, and a command
    # that touched 200 files of which three are code should not pay for 197.
    paths = [p for p in edited(payload) if Path(p).suffix in CODE]
    # An Edit/Write/MultiEdit NAMES its file: that is the agent editing, and no
    # amount of git state changes it. Only the shell's changed-file list, which
    # cannot tell an edit from a checkout, is filtered.
    if paths and not (isinstance(named, str) and named):
        paths = only_dirty(paths)
    by_root: dict = {}
    for path in paths:
        placed = _place(Path(path))
        if placed:
            by_root.setdefault(placed[0], []).append(placed[1])
    sid = session_of(payload)
    for root, rels in by_root.items():
        _record(root, sid, rels)
    if by_root:
        _index_add(sid, by_root.keys())
    return 0


def edited(payload) -> list:
    """Every file this call changed, whichever tool changed it.

    THE GATE WAS BLIND TO THE SHELL. Edit, Write and MultiEdit name their file
    in `tool_input`; a Bash command does not name anything. Without this, a
    shell loop that rewrites hundreds of tracked files marks nothing, and the
    turn ends with no verification demanded at all. In auto mode the shell is
    a usual way for an agent to edit files, so a gate blind to it misses the
    dominant path while looking exactly like a gate that passed.

    The Bash tool reports what it touched: `tool_response.changedFiles`, which
    the engine's own types describe as being there FOR PostToolUse Bash hooks.
    It is capped at 200 paths, so a very large command marks the first 200 --
    partial, and partial is the correct direction for a gate that blocks.
    """
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        ti = {}
    one = ti.get('file_path') or ti.get('path') or ''
    if isinstance(one, str) and one:
        return [one]
    # The REAL path is tool_response.bashEditDiff.changedFiles -- nested, not
    # top-level, per Claude Code's own type declarations. Reading it one level
    # too high is easy, and a unit test built from the same wrong assumption
    # passes: a fixture that encodes your belief tests your belief.
    resp = payload.get('tool_response')
    diff = resp.get('bashEditDiff') if isinstance(resp, dict) else None
    if not isinstance(diff, dict):
        return []
    changed = diff.get('changedFiles')
    if isinstance(changed, list):
        return [c for c in changed if isinstance(c, str)]
    # `changedFiles` is cut when it would be shorter than the rendered set, so
    # fall back to the per-file diffs, which name every file that WAS rendered.
    files = diff.get('files')
    if isinstance(files, list):
        return [f['filePath'] for f in files
                if isinstance(f, dict) and isinstance(f.get('filePath'), str)]
    return []


def _place(p: Path):
    """(repo root, path relative to it) for a code file worth verifying, or None."""
    if p.suffix not in CODE:
        return None
    # A new file sits in a directory that may not exist yet, so walk up to the
    # nearest ancestor that does. Falling back to cwd marks the wrong repo --
    # silently, which is how this gate first failed its own fixtures.
    anchor = p.parent
    while not anchor.exists() and anchor != anchor.parent:
        anchor = anchor.parent
    root = repo_root(anchor)
    if not root:
        return None
    # Compare RESOLVED paths. `git rev-parse --show-toplevel` returns a
    # resolved path, and on macOS a temp dir reaches us as /var/... while git
    # calls it /private/var/..., so a plain string prefix test fails and this
    # silently degraded to the bare filename -- "a.ts" instead of "src/a.ts"
    # in every message, on macOS only. Linux never shows it, because there the
    # two spellings happen to agree -- which is why CI runs on both.
    try:
        rel = p.resolve().relative_to(root.resolve())
    except (OSError, ValueError):
        return (root, p.name)
    # Exclusions are judged INSIDE the repo. `.claude` used to be skipped
    # anywhere in the absolute path, and a Claude Code worktree lives at
    # <repo>/.claude/worktrees/<name>/ -- so nothing edited in a worktree was
    # ever recorded. A worktree is its own git toplevel, so its files arrive
    # here relative to the worktree and are judged like any other checkout;
    # only the repo's OWN .claude/ (settings, skills, state) is skipped.
    parts = rel.parts
    if parts and parts[0] == '.claude':
        return None
    if any(part in SKIP_DIRS for part in parts):
        return None
    return (root, str(rel))


def _record(root: Path, sid: str, rels: list) -> None:
    try:
        f = state_dir(root) / f'pending-{sid}'
        prev = f.read_text().splitlines() if f.is_file() else []
        have = set(prev)
        for rel in rels:
            if rel not in have:
                prev.append(rel)
                have.add(rel)
        # No cap. The list used to keep the LAST 40, so a turn that changed
        # more forgot the rest -- and the "(+N more)" count it printed was
        # wrong. Each call adds at most what the tool reported (Bash caps that
        # at 200), and the file is deleted the moment the change is verified.
        f.write_text('\n'.join(prev))
    except OSError:
        pass


def _shown(files: list) -> str:
    return ', '.join(files[:6]) + (f' (+{len(files) - 6} more)' if len(files) > 6 else '')


def _run_harness(cmd: str, root: Path, budget: float):
    """(returncode or None on timeout, output). Kills the WHOLE process group.

    `subprocess.run(shell=True, timeout=...)` kills only the shell. Anything
    the harness started keeps the output pipes open, and run() then waits on
    them -- so a hung suite held the gate long past its own timeout, until the
    engine killed the hook. A new session puts every descendant in one group,
    and the group is what gets killed.
    """
    p = subprocess.Popen(cmd, shell=True, cwd=str(root), stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=budget)
        return p.returncode, out or ''
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            out, _ = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out = ''
        return None, out or ''


def _judge(root: Path, sid: str, cwd: Path, cwd_root, deadline: float):
    """Verdict for ONE repo: (code, text). code 0 allows, 2 refuses.

    `text` on a 0 is something the person should see (a skip reason, which
    harness verified it); on a 2 it is the refusal the model must act on.
    """
    d = root / '.claude' / '.verify-state'
    if d.is_dir():
        prune(d)
    # A bare `pending` predates session scoping and belongs to no session. It is
    # left for prune() to remove rather than blocking a turn that did not make it.
    pending = d / f'pending-{sid}'
    if not pending.is_file():
        return 0, '', []
    try:
        files = [x for x in pending.read_text().splitlines() if x.strip()]
        edited_at = pending.stat().st_mtime
    except OSError:
        return 0, '', []
    if not files:
        return 0, '', []

    verified = d / 'verified'
    if verified.is_file() and verified.stat().st_mtime >= edited_at:
        pending.unlink(missing_ok=True)
        return 0, '', []

    # THIS HOOK RUNS UNSANDBOXED; THE AGENT THAT MUST ESCAPE IT DOES NOT.
    #
    # `root` is the git toplevel, which can sit ABOVE the agent's workspace --
    # the agent's tools may be confined to cwd and below. A sandbox that
    # git-inits the PARENT of the workspace makes root resolve one level up:
    # this hook writes `pending-<sid>` there, and every attempt the agent makes
    # to write the skip file is denied. The agent ends up stuck, because the
    # only way out is a path it has no authority to create.
    #
    # The docstring above promises escape is always possible. It was not. So the
    # skip is accepted under cwd as well as under root, and the path printed is
    # the one the agent can definitely write. The same holds for a repo that is
    # not the cwd's at all: the skip under cwd covers it, because that is the
    # one path the agent is sure to reach.
    escapes = [d / f'skipped-{sid}']
    if cwd_root is not None and cwd_root != root:
        escapes.insert(0, cwd_root / '.claude' / '.verify-state' / f'skipped-{sid}')
    if cwd != root:
        escapes.insert(0, cwd / '.claude' / '.verify-state' / f'skipped-{sid}')
    for skipped in escapes:
        try:
            if skipped.is_file() and skipped.stat().st_mtime >= edited_at:
                reason = skipped.read_text().strip()[:200]
                pending.unlink(missing_ok=True)
                return 0, (f'[bendit] {root.name}: verification skipped: '
                           f'{reason or "no reason given"}'), files
        except OSError:
            continue

    # A REPO MAY DECLARE WHAT VERIFIES IT.
    #
    # This gate looks for a `verify-*` skill, which is right for an app: there
    # is something to launch and drive. For a plugin, a CLI or a library there
    # is no app, the suites ARE the harness, and the gate asked a question with
    # a permanent answer -- so the same skip note got written over and over.
    # A gate whose answer never changes is one people stop reading.
    #
    # `.claude/verify-harness` holds a command. It is committed, not a local
    # artifact, so it travels with the repo. The gate RUNS it rather than
    # trusting a sentence: a skip note is a claim, an exit code is evidence,
    # and this is the whole argument of the plugin applied to itself.
    declared = root / '.claude' / 'verify-harness'
    if declared.is_file():
        try:
            # `#` lines are comments, so the file can explain itself -- what it
            # runs, what it costs, and what to do if that cost grates. A
            # declaration nobody understands is one somebody deletes.
            cmd = '\n'.join(l for l in declared.read_text().splitlines()
                            if l.strip() and not l.lstrip().startswith('#')).strip()
        except OSError:
            cmd = ''
        if not cmd:
            return 2, (f'[bendit] {declared} is empty, so nothing can verify {root.name}.\n'
                       f'Put a command in it, or delete it to go back to asking for a '
                       f'verify-* skill.'), files
        budget = deadline - time.monotonic()
        if budget <= 0:
            return 2, (f'[bendit] no time was left to run {root.name}\'s declared harness '
                       f'(budget {harness_budget():.0f}s spent on other repos), so '
                       f'{_shown(files)} is NOT verified:\n  {cmd}'), files
        try:
            rc, out = _run_harness(cmd, root, budget)
        except OSError as e:
            return 2, (f'[bendit] the declared harness could not start ({e}), so '
                       f'{root.name} is NOT verified:\n  {cmd}'), files
        if rc is None:
            return 2, (f'[bendit] the declared harness did not finish in {budget:.0f}s, '
                       f'so {root.name} is NOT verified:\n  {cmd}'), files
        if rc == 0:
            # Say what ran. A gate that passes in silence teaches nothing, and
            # the next reader needs to know WHICH command answered for the code.
            pending.unlink(missing_ok=True)
            return 0, f'[bendit] verified by {root.name}\'s declared harness: {cmd}', files
        tail = out.strip()[-1500:]
        # No output (e.g. exit 127, command not found) gets no blank separator.
        return 2, (f'[bendit] {root.name}\'s declared harness FAILED (exit {rc}), '
                   f'so {_shown(files)} is not verified:\n  {cmd}'
                   + (f'\n\n{tail}' if tail else '')), files

    reachable = escapes[0]
    harness = list((root / '.claude' / 'skills').glob('verify-*')) if (root / '.claude' / 'skills').is_dir() else []
    shown = _shown(files)
    if harness:
        msg = (f'[bendit] You changed code in {root.name} and nothing has verified it: {shown}.\n'
               f'Run /bendit:verify before finishing.\n'
               f'If it genuinely does not apply, say why to the user and record it:\n'
               f'  echo "<one-line reason>" > {reachable}')
    else:
        # Everything the agent needs is IN this message. With three options
        # given in the abstract, a measured eval run spent its last turns
        # reading this hook's source to work out what to do.
        decl = root / '.claude' / 'verify-harness'
        cmd = suggest_harness(root)
        head = (f'[bendit] You changed code in {root.name} and it has no verification harness: {shown}.\n'
                f'The gate runs {decl} (one shell command per line; exit 0 means verified) '
                f'when a turn ends. Everything you need is in this message.\n')
        if cmd:
            how = (f'This project looks like it tests with `{cmd}`. To make that the check, run:\n'
                   f"  mkdir -p {root / '.claude'} && echo '{cmd}' > {decl}\n"
                   f'then end the turn again. For a fuller harness (launching the app), run /bendit:adopt.\n')
        else:
            how = (f'No test command was found here. Write the command that proves your change into {decl},\n'
                   f'or run /bendit:adopt to build a harness for this project.\n')
        msg = (head + how +
               f'If verification genuinely does not apply, say why to the user and record it:\n'
               f'  echo "<one-line reason>" > {reachable}')
    return 2, msg, files


def suggest_harness(root: Path):
    """The project's own test command, read from what is on disk, or None.
    Only signals that name a real test command count: npm's placeholder
    `echo "Error: no test specified"` script is not one."""
    pkg = root / 'package.json'
    if pkg.is_file():
        try:
            test = (json.loads(pkg.read_text()).get('scripts') or {}).get('test') or ''
        except (OSError, ValueError, AttributeError):
            test = ''
        if test and 'no test specified' not in test:
            if (root / 'pnpm-lock.yaml').is_file():
                return 'pnpm test'
            if (root / 'yarn.lock').is_file():
                return 'yarn test'
            if (root / 'bun.lockb').is_file() or (root / 'bun.lock').is_file():
                return 'bun run test'
            return 'npm test'
    pyproject = root / 'pyproject.toml'
    pytest_cfg = (root / 'pytest.ini').is_file() or (root / 'conftest.py').is_file()
    if not pytest_cfg and pyproject.is_file():
        try:
            pytest_cfg = 'pytest' in pyproject.read_text()
        except OSError:
            pass
    if pytest_cfg:
        return 'python3 -m pytest'
    tests = root / 'tests'
    if tests.is_dir() and any(tests.glob('test_*.py')):
        return 'python3 -m unittest discover -s tests'
    if (root / 'go.mod').is_file():
        return 'go test ./...'
    if (root / 'Cargo.toml').is_file():
        return 'cargo test'
    mk = root / 'Makefile'
    if mk.is_file():
        try:
            if re.search(r'^test\s*:', mk.read_text(), re.M):
                return 'make test'
        except OSError:
            pass
    return None


def _say(message: str) -> None:
    """Allow the stop and tell the PERSON. Exit-0 stderr reaches nobody."""
    print(json.dumps({'systemMessage': message}))


def _record_letthrough(roots_blocked, sid: str, text: str) -> None:
    stamp = time.strftime('%Y-%m-%dT%H:%M:%S')
    for root in roots_blocked:
        try:
            with open(state_dir(root) / f'let-through-{sid}', 'a') as fh:
                fh.write(f'{stamp}\t{text.splitlines()[0] if text else ""}\n')
        except OSError:
            pass


def _parse(raw: str) -> dict:
    """The Stop payload, or {} when it is unreadable. An unreadable payload is
    NOT a pass: the gate still judges the process cwd's repo."""
    try:
        payload = json.loads(raw)
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def check(payload: dict) -> int:
    cwd_raw = payload.get('cwd')
    cwd = Path(cwd_raw) if isinstance(cwd_raw, str) and cwd_raw else Path.cwd()
    cwd_root = repo_root(cwd)
    sid = session_of(payload)
    roots = []
    for r in ([cwd_root] if cwd_root else []) + _index_roots(sid):
        if r not in roots and r.is_dir():
            roots.append(r)
    if not roots:
        return 0

    # WHERE THE ESCAPE IS WRITTEN: the launch directory, not the shell's cwd.
    # The payload's `cwd` follows every `cd` the agent makes, so an agent that
    # cd-ed into a subfolder (a harness's artifacts/, say) was told to write a
    # skip file under a .claude/ that does not exist there. CLAUDE_PROJECT_DIR
    # is where the session started: always writable by the agent (it is the
    # workspace in a sandboxed eval too) and it does not move. Unset -> cwd.
    proj = os.environ.get('CLAUDE_PROJECT_DIR')
    here = Path(proj) if proj and Path(proj).is_dir() else cwd
    here_root = cwd_root if here == cwd else repo_root(here)

    deadline = time.monotonic() + harness_budget()
    notes, refusals, blocked_roots = [], [], []
    for root in roots:
        code, text, _files = _judge(root, sid, here, here_root, deadline)
        if code == 2:
            refusals.append(text)
            blocked_roots.append(root)
        elif text:
            notes.append(text)

    if not refusals:
        if notes:
            _say('\n'.join(notes))
        return 0

    # Already refused once this turn. Refusing again traps the session in a
    # loop, so the stop is allowed -- but NOT silently: the person is told what
    # is unverified, and the let-through is recorded beside the pending list,
    # which is kept, so the next turn still answers for it.
    if payload.get('stop_hook_active'):
        text = '\n\n'.join(refusals)
        _record_letthrough(blocked_roots, sid, text)
        _say('[bendit] the turn ended with code NOT verified -- the gate already '
             'refused once this turn and does not refuse twice:\n\n' + text +
             ('\n\n' + '\n'.join(notes) if notes else ''))
        return 0

    print('\n\n'.join(refusals + notes), file=sys.stderr)
    return 2


def run(argv) -> int:
    raw = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape')
    if '--mark' in argv:
        try:
            return mark(raw)
        except Exception as exc:
            print(f'[bendit] the verification gate could not record this edit '
                  f'({type(exc).__name__}: {exc}). The Stop gate may not know it '
                  f'happened: verify it yourself before finishing.', file=sys.stderr)
            return 2
    payload = _parse(raw)
    try:
        return check(payload)
    except Exception as exc:
        text = (f'[bendit] the verification gate itself failed '
                f'({type(exc).__name__}: {exc}), so whether this turn\'s code was '
                f'verified is UNKNOWN.')
        # Refusing again after a refusal this turn would trap the session in a
        # loop; the person is told instead, exactly as for any let-through.
        if payload.get('stop_hook_active'):
            _say(text)
            return 0
        print(text + ' Verify the change, or fix the gate.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(run(sys.argv[1:]))
