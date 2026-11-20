#!/usr/bin/env python3
"""Lint implementation plans written by superpowers:writing-plans.

Plans land in `docs/superpowers/plans/YYYY-MM-DD-<name>.md` and get committed.
Nothing checked that one actually carries what makes it useful, so a plan could
pass human review while citing a spec that was never written, skipping an
Interfaces block the next task's implementer needs, or specifying only unit
tests -- the gap this exists for. "Run the test suite" is not evidence that the
thing works; see the checks-that-can-lie skill.

Every rule below is something `writing-plans/SKILL.md` mandates:

  header        the MUST-start-with header block (SKILL.md "Plan Document
                Header"): title, REQUIRED SUB-SKILL line, Goal, Architecture,
                Tech Stack, Spec, ## Global Constraints, ## Review Focus
  file-structure  "Before defining tasks, map out which files will be created
                or modified" (SKILL.md "File Structure")
  spec-exists   the header says the spec "travels with" the plan; a plan whose
                spec path is not on disk has already drifted apart from it
  task shape    **Files:** / **Interfaces:** blocks and `- [ ] **Step N:`
                checkbox steps (SKILL.md "Task Structure")
  commit        "Frequent commits"; every task's step list ends with Commit
  live          at least one step runs the real artifact (see LIVE below)
  placeholders  "Lines that decide nothing ... are the opposite failure"
  numbering     tasks are contiguous from 1, so none was dropped on an edit

LIVE is the one rule with no single line in SKILL.md behind it, so it is
defined mechanically here rather than by feel. A step is live when either:

  (a) it carries a RUN COMMAND -- a ```bash/sh/shell/zsh/console fence, or a
      `Run: <cmd>` line -- in which some command is neither a test runner
      (TEST_RUNNERS) nor shell housekeeping (HOUSEKEEPING: cd, echo, git,
      ...). Running `pytest` proves the tests pass; running the program is a
      different claim.
  (b) its prose tells the implementer to drive the real thing: "open a
      session", "in the browser", "navigate to", "screenshot", ...

(a) is the load-bearing half; (b) exists so a plan whose live step is honest
prose with no copy-pasteable command still counts.

Usage:
    check-plan.py [PATH ...]      # default: every file under
                                  # docs/superpowers/plans/

Exit 0 and silent when clean. Exit 1 with one `file:line: message` per problem.
"""
import re
import json
import sys
from pathlib import Path

# --- header requirements -------------------------------------------------
# (label, regex over the whole document, what to tell the person)
HEADER_RULES = [
    ('REQUIRED SUB-SKILL',
     re.compile(r'^>.*REQUIRED SUB-SKILL:.*superpowers:', re.MULTILINE),
     'add the agentic-worker line from writing-plans: "> **For agentic '
     'workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-'
     'development (recommended) or superpowers:executing-plans ..."'),
    ('**Goal:**', re.compile(r'^\*\*Goal:\*\*\s*\S', re.MULTILINE),
     'add "**Goal:** <one sentence describing what this builds>"'),
    ('**Architecture:**', re.compile(r'^\*\*Architecture:\*\*\s*\S', re.MULTILINE),
     'add "**Architecture:** <2-3 sentences about the approach>"'),
    ('**Tech Stack:**', re.compile(r'^\*\*Tech Stack:\*\*\s*\S', re.MULTILINE),
     'add "**Tech Stack:** <key technologies/libraries>"'),
    ('**Spec:**', re.compile(r'^\*\*Spec:\*\*\s*\S', re.MULTILINE),
     'add "**Spec:** <path to the spec this plan implements>" — executors '
     'read both, so the spec has to travel with the plan'),
    ('## Global Constraints', re.compile(r'^##\s+Global Constraints\s*$', re.MULTILINE),
     'add a "## Global Constraints" section with the spec\'s project-wide '
     'requirements, exact values copied verbatim, one line each'),
    ('## Review Focus', re.compile(r'^##\s+Review Focus\s*$', re.MULTILINE),
     'add a "## Review Focus" section naming the input classes the spec '
     'implies but no task tests (an empty section means you checked and '
     'found none)'),
    ('## File Structure', re.compile(r'^##\s+File Structure\s*$', re.MULTILINE),
     'add a "## File Structure" section mapping every file the plan creates '
     'or modifies to its one responsibility, before the tasks'),
]

# Phrases that decide nothing. SKILL.md: "Lines that decide nothing ('TBD',
# 'handle edge cases', 'add appropriate validation', 'write tests for the
# above' ...) are the opposite failure".
PLACEHOLDERS = [
    (re.compile(r'\bTBD\b', re.IGNORECASE),
     'replace "TBD" with the decision the implementer cannot make alone'),
    (re.compile(r'\bTODOs?\b', re.IGNORECASE),
     'replace "TODO" with the decision the implementer cannot make alone'),
    (re.compile(r'\bimplement(ed)?\s+later\b', re.IGNORECASE),
     '"implement later" defers a decision the plan exists to make — either '
     'write the step or drop the task'),
    (re.compile(r'\bfill\s+in\s+(the\s+)?details?\b', re.IGNORECASE),
     '"fill in details" is the detail — name the signature, the file and the '
     'values'),
    (re.compile(r'\bsimilar\s+to\s+Task\b', re.IGNORECASE),
     '"similar to Task N" is not a step — state this task\'s own files, '
     'signatures and assertions, or reference that task\'s Interfaces block'),
    (re.compile(r'\badd\s+appropriate\s+error\s+handling\b', re.IGNORECASE),
     'name which errors, and what the program does with each'),
    (re.compile(r'\badd\s+appropriate\s+validation\b', re.IGNORECASE),
     'name what is validated, and what happens when it fails'),
    (re.compile(r'\bhandle\s+edge\s+cases\b', re.IGNORECASE),
     'name the edge cases and the expected behaviour for each'),
    (re.compile(r'\bwrite\s+tests?\s+for\s+the\s+above\b', re.IGNORECASE),
     'give the test names and their assertions, with the spec\'s exact '
     'values in them'),
]

# A command that runs tests. Proving the tests pass is not proving the thing
# works, so these never satisfy the live rule. `claude plugin test` is in here
# because a plugin's plans use it as their unit-test runner -- without it the
# live rule would be satisfied by every task and catch nothing.
TEST_RUNNERS = [
    re.compile(r'^(python\d?\s+-m\s+)?pytest\b'),
    re.compile(r'^(npx\s+|pnpm\s+|yarn\s+|bunx\s+)?(jest|vitest|mocha|ava|tap|karma)\b'),
    re.compile(r'^(npm|pnpm|yarn|bun)\s+(run\s+)?(test|tests|test:\S+)\b'),
    re.compile(r'^(go|cargo|bun|deno|dotnet|swift|mix)\s+test\b'),
    re.compile(r'^node\s+--test\b'),
    re.compile(r'^(rspec|phpunit|tox|nose2|unittest|ctest|gradle\s+test|mvn\s+test)\b'),
    re.compile(r'^claude\s+plugin\s+(test|validate)\b'),
]

# Shell housekeeping: moving around, writing files, staging a commit. Present
# in nearly every task, so it cannot be what makes a step live.
HOUSEKEEPING = {
    'cd', 'echo', 'printf', 'export', 'set', 'source', '.', 'ls', 'cat',
    'mkdir', 'touch', 'cp', 'mv', 'rm', 'git', 'pwd', 'true', 'false',
    'sleep', 'exit', 'chmod', 'then', 'fi', 'done', 'do', 'else',
}

# Prose that describes driving the real thing by hand.
LIVE_PROSE = re.compile(
    r'open\s+(a|the|two|another)\s+\w*\s*(session|app|browser|tab|page|window)'
    r'|in\s+the\s+browser'
    r'|navigate\s+to'
    r'|screenshot'
    r'|launch\s+the\s+(app|server|binary|program|cli)'
    r'|start\s+the\s+(app|server|dev\s+server)'
    r'|by\s+hand\b'
    r'|manually\b'
    r'|/bendit:verify',
    re.IGNORECASE)

RUN_LINE = re.compile(r'^\s*Run(?:\s+it)?:\s*(.+?)\s*$')
FENCE = re.compile(r'^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)')
SHELL_INFO = {'bash', 'sh', 'shell', 'zsh', 'console', 'shellsession', 'terminal'}

TASK_HEADING = re.compile(r'^###\s+Task\s+(\d+)\s*:\s*(\S.*)$')
LOOSE_TASK = re.compile(r'^#{1,4}\s*Task\b', re.IGNORECASE)
STEP = re.compile(r'^-\s+\[[\sxX]?\]\s+\*\*Step\s+(\d+)\s*:\s*(.*)$')
LOOSE_STEP = re.compile(r'^\s*(?:[-*+]\s*)?(?:\[[^\]]*\]\s*)?\**\s*Step\s+\d+\s*[:.]',
                        re.IGNORECASE)
ANY_HEADING = re.compile(r'^#{1,6}\s')
COMMIT_STEP = re.compile(r'\bcommit\b', re.IGNORECASE)


def split_fences(lines):
    """Classify every line as outside a fence, a fence marker, or fenced code.

    Returns (info, markers): `info[i]` is None outside any fence, otherwise the
    enclosing fence's language tag (possibly ''); `markers` holds the indexes of
    the ``` lines themselves.

    Structural parsing (headings, steps, Files/Interfaces) must ignore anything
    inside a fence, or a `### Task` inside an example code block invents a task.
    The language tag is kept because the live rule reads ```bash blocks as
    commands and must not read a ```ts block the same way.
    """
    info = [None] * len(lines)
    markers = set()
    closer = None
    lang = None
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if closer is None:
            if m:
                closer = m.group(1)
                lang = m.group(2).lower()
                info[i] = lang
                markers.add(i)
            continue
        info[i] = lang
        if m and m.group(1)[0] == closer[0] and len(m.group(1)) >= len(closer):
            markers.add(i)
            closer = None
            lang = None
    return info, markers


def plan_root(path: Path) -> Path:
    """The directory a plan's **Spec:** path is relative to.

    Prefer the conventional layout (`<root>/docs/superpowers/plans/x.md`), then
    the enclosing git checkout, then the plan's own directory. The last fallback
    keeps a plan outside any repository checkable rather than silently resolving
    its spec against whatever directory the linter happened to run in.
    """
    parts = path.resolve().parts
    for i in range(len(parts) - 3):
        if parts[i:i + 3] == ('docs', 'superpowers', 'plans'):
            return Path(*parts[:i]) if i else Path(path.anchor or '.')
    for parent in path.resolve().parents:
        if (parent / '.git').exists():
            return parent
    return path.resolve().parent


def spec_target(value: str) -> str:
    """Pull the path out of a **Spec:** value, however it is marked up."""
    value = value.strip()
    link = re.match(r'^\[[^\]]*\]\(([^)]+)\)', value)
    if link:
        return link.group(1).strip()
    value = value.strip('`').strip()
    value = value.lstrip('[').rstrip(']')
    token = value.split()[0] if value.split() else ''
    return token.strip('`').rstrip('.,;:')


def commands_in(body):
    """Every shell command line inside a step body, continuations joined.

    `body` is a list of (lineno, text, lang, is_marker). Commands come from two
    places: a `Run: <cmd>` line outside any fence, and the lines of a shell
    fence. A `git add a \\` / `b` pair is ONE command: without joining, the
    second line reads as a command named after a file path, and every commit
    step in a real plan would count as live.
    """
    out = []
    pending = None
    for lineno, text, lang, is_marker in body:
        if is_marker:
            pending = None
            continue
        if lang is None:
            m = RUN_LINE.match(text)
            cmd = m.group(1) if m else None
        elif lang in SHELL_INFO:
            cmd = text
        else:
            cmd = None  # a ```ts/```json sample is not a command
        if cmd is None:
            pending = None
            continue
        cmd = cmd.strip()
        if pending is not None:
            cmd = pending + ' ' + cmd
            pending = None
        if cmd.endswith('\\'):
            pending = cmd[:-1].rstrip()
            continue
        if cmd:
            out.append((lineno, cmd))
    if pending:
        out.append((body[-1][0], pending))
    return out


def is_live_command(cmd: str) -> bool:
    """True when some segment of `cmd` runs the artifact, not the test suite."""
    cmd = cmd.strip().strip('`').strip()
    if cmd.startswith('#'):
        return False
    for seg in re.split(r'&&|\|\||[|;]', cmd):
        seg = seg.strip()
        # Drop leading `VAR=value` env assignments and `$ ` prompt markers.
        seg = re.sub(r'^\$\s+', '', seg)
        while re.match(r'^[A-Za-z_][A-Za-z0-9_]*=\S*\s+\S', seg):
            seg = seg.split(None, 1)[1].strip()
        if not seg or seg.startswith('#'):
            continue
        if any(rx.match(seg) for rx in TEST_RUNNERS):
            continue
        word = seg.split()[0].lstrip('!')
        if word in HOUSEKEEPING:
            continue
        return True
    return False


def check(path: Path):
    """Return a sorted list of (lineno, message) for one plan file."""
    problems = []

    def bad(lineno, msg):
        problems.append((lineno, msg))

    try:
        text = path.read_text(encoding='utf-8')
    except OSError as exc:
        return [(1, f'cannot be read ({exc.strerror}) — the linter checks files '
                    f'on disk, so make sure the path is right')]

    lines = text.split('\n')
    info, markers = split_fences(lines)
    # Only text outside fences counts as structure.
    outside = '\n'.join(l if info[i] is None else '' for i, l in enumerate(lines))

    # --- filename -------------------------------------------------------
    if not re.match(r'^\d{4}-\d{2}-\d{2}-.+\.md$', path.name):
        bad(1, f'filename "{path.name}" is not YYYY-MM-DD-<feature-name>.md — '
               f'writing-plans saves plans under that name so they sort by date')

    # --- title ----------------------------------------------------------
    first = next(((i, l) for i, l in enumerate(lines) if l.strip()), None)
    if first is None:
        return [(1, 'the file is empty — a plan starts with "# <Feature Name> '
                    'Implementation Plan" and the writing-plans header block')]
    idx, head = first
    if not re.match(r'^#\s+\S', head) or 'implementation plan' not in head.lower():
        bad(idx + 1, 'the first line must be the title heading '
                     '"# <Feature Name> Implementation Plan"')

    # --- header block ---------------------------------------------------
    for label, rx, fix in HEADER_RULES:
        if not rx.search(outside):
            bad(1, f'the header block has no {label} line — {fix}')

    # --- the spec has to exist -------------------------------------------
    for i, line in enumerate(lines):
        if info[i] is not None:
            continue
        m = re.match(r'^\*\*Spec:\*\*\s*(.+)$', line)
        if not m:
            continue
        target = spec_target(m.group(1))
        root = plan_root(path)
        if not target or '/' not in target and not target.endswith('.md'):
            bad(i + 1, f'**Spec:** does not name a path ({m.group(1).strip()!r}) '
                       f'— point it at the spec file this plan implements, '
                       f'relative to the repository root')
        elif not (root / target).is_file():
            bad(i + 1, f'**Spec:** points at "{target}", which does not exist '
                       f'under {root} — write the spec, or fix the path; a plan '
                       f'whose spec is missing has already drifted from it')
        break

    # --- tasks ------------------------------------------------------------
    tasks = []  # (lineno_index, number, [body line indexes])
    for i, line in enumerate(lines):
        if info[i] is not None:
            continue
        m = TASK_HEADING.match(line)
        if m:
            tasks.append([i, int(m.group(1)), []])
        elif LOOSE_TASK.match(line) and not re.match(r'^###\s+Task\s+\d+\s*:', line):
            bad(i + 1, f'task heading {line.strip()!r} is not in the required '
                       f'form "### Task N: <Component Name>"')

    if not tasks:
        bad(1, 'the plan has no tasks — a plan is a numbered list of '
               '"### Task N: <Component Name>" sections, each ending in an '
               'independently testable deliverable')

    for t, task in enumerate(tasks):
        start = task[0] + 1
        end = len(lines)
        for j in range(start, len(lines)):
            if info[j] is None and ANY_HEADING.match(lines[j]):
                end = j
                break
        task[2] = list(range(start, end))

    # numbering is contiguous from 1
    for pos, task in enumerate(tasks):
        want = pos + 1
        if task[1] != want:
            bad(task[0] + 1, f'task numbering jumps: this is "Task {task[1]}" but '
                             f'it is task {want} in the file — number tasks '
                             f'contiguously from 1, or a dropped task reads as '
                             f'a task nobody wrote')

    any_live = False
    for task in tasks:
        tno, body_idx = task[1], task[2]
        src = [(j + 1, lines[j]) for j in body_idx if info[j] is None]

        for label, rx in (('**Files:**', re.compile(r'^\*\*Files:\*\*')),
                          ('**Interfaces:**', re.compile(r'^\*\*Interfaces:\*\*'))):
            if not any(rx.match(l) for _, l in src):
                detail = ('list "Create:"/"Modify:"/"Test:" with exact paths'
                          if label == '**Files:**' else
                          'state "Consumes:" what this uses from earlier tasks '
                          'and "Produces:" the exact signatures later tasks rely '
                          'on — the implementer sees only this task')
                bad(task[0] + 1, f'Task {tno} has no {label} block — add one and '
                                 f'{detail}')

        # steps
        steps = []  # (lineno, title, [body (lineno, text, info)])
        for k, j in enumerate(body_idx):
            if info[j] is not None:
                continue
            m = STEP.match(lines[j])
            if m:
                steps.append([j + 1, m.group(2), []])
            elif LOOSE_STEP.match(lines[j]) and lines[j].strip():
                bad(j + 1, f'Task {tno} has a step that is not a checkbox step: '
                           f'{lines[j].strip()[:60]!r} — write it as '
                           f'"- [ ] **Step N: <one action with a checkable '
                           f'result>**" so execution can track it')

        if not steps:
            bad(task[0] + 1, f'Task {tno} has no "- [ ] **Step N:" steps — a task '
                             f'is a list of checkbox steps, each one action with '
                             f'a checkable result')
            continue

        starts = [s[0] for s in steps] + [body_idx[-1] + 2 if body_idx else 0]
        for si, step in enumerate(steps):
            lo, hi = step[0], starts[si + 1]
            step[2] = [(j + 1, lines[j], info[j], j in markers) for j in body_idx
                       if lo <= j + 1 < hi]

        if not COMMIT_STEP.search(steps[-1][1]):
            bad(steps[-1][0], f'Task {tno} does not end in a Commit step — '
                              f'writing-plans asks for frequent commits, so the '
                              f'last step of every task is '
                              f'"- [ ] **Step N: Commit**" with the git commands')

        for step in steps:
            if any_live:
                break
            prose = '\n'.join(t for _, t, lang, _ in step[2] if lang is None)
            if LIVE_PROSE.search(prose):
                any_live = True
                break
            for lineno, cmd in commands_in(step[2]):
                if is_live_command(cmd):
                    any_live = True

                    break

    if tasks and not any_live:
        bad(tasks[0][0] + 1,
            'no task has a step that runs the real thing — every step either '
            'runs the test suite or stages a commit. Add a step that exercises '
            'the built artifact end to end: a `Run:` line or a ```bash block '
            'whose command is not a test runner (pytest/jest/vitest/'
            '`claude plugin test`/...) and not shell housekeeping '
            '(cd/echo/git/...), or a step that says to drive it by hand '
            '("open a session ...", "in the browser ...", "navigate to ..."). '
            'Passing unit tests are evidence about the tests, not about the '
            'program.')

    # --- placeholders -----------------------------------------------------
    # Fenced text is quoted code or output, not the plan's own decision -- a
    # step that greps for TODOs is not a TODO. Structure already ignores it.
    for i, line in enumerate(lines):
        if info[i] is not None or i in markers:
            continue
        for rx, fix in PLACEHOLDERS:
            m = rx.search(line)
            if m:
                bad(i + 1, f'placeholder {m.group(0)!r} decides nothing — {fix}')

    seen = set()
    ordered = []
    for lineno, msg in sorted(problems, key=lambda p: p[0]):
        if (lineno, msg) in seen:
            continue
        seen.add((lineno, msg))
        ordered.append((lineno, msg))
    return ordered


def default_targets():
    root = Path.cwd().resolve()
    for parent in [root, *root.parents]:
        if (parent / '.git').exists():
            root = parent
            break
    plans = root / 'docs' / 'superpowers' / 'plans'
    if not plans.is_dir():
        return []
    return sorted(p for p in plans.rglob('*') if p.is_file())


def advise(path: Path) -> list:
    """The advisory note for a plan file, as lines; empty when there is none.

    The single spelling of "lint a plan as it is written". Both the `--hook`
    entry point and post-edit-review.py call this, so there is no second copy
    of the filter or the wording to drift away from the first. It RETURNS the
    note instead of printing it: the caller owns the channel, and the channel
    matters -- stderr on a hook's exit 0 reaches nobody.
    """
    # Only plan files. Anything else is none of this script's business.
    if path.suffix != '.md' or 'superpowers/plans' not in path.as_posix():
        return []
    if not path.is_file():
        return []
    problems = [f'{path.name}:{n}: {m}' for n, m in check(path)]
    if not problems:
        return []
    return (['plan check:'] + [f'  {line}' for line in problems] +
            ['  (advisory — a plan is written in passes; fix these before it '
             'is executed)'])


def from_hook() -> int:
    """PostToolUse mode: lint a plan the moment it is written.

    A linter nobody remembers to run is prose with extra steps; this gets the
    effect of "run it and fix every line it prints" without anyone having to
    remember.

    Advisory on purpose -- it always exits 0. Blocking a write would mean a
    half-written plan cannot be saved, and a plan is written in passes.
    """
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    raw = (payload.get('tool_input') or {}).get('file_path') or ''
    note = advise(Path(raw))
    if note:
        # additionalContext, not stderr: on exit 0 stderr reaches nobody.
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PostToolUse', 'additionalContext': '\n'.join(note)}}, ensure_ascii=False))
    return 0


def main(argv) -> int:
    if '--hook' in argv:
        return from_hook()
    args = [a for a in argv if not a.startswith('-')]
    targets = [Path(a) for a in args] if args else default_targets()

    found = 0
    for path in targets:
        if not path.exists():
            print(f'{path}:1: no such file — check-plan.py checks plan files on '
                  f'disk; with no arguments it checks everything under '
                  f'docs/superpowers/plans/')
            found += 1
            continue
        if path.is_dir():
            continue
        for lineno, msg in check(path):
            print(f'{path}:{lineno}: {msg}')
            found += 1
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
