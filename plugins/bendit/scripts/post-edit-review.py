#!/usr/bin/env python3
"""PostToolUse(Edit|Write|MultiEdit): flag specific, recurring agent mistakes.

PostToolUse CANNOT block -- the edit already happened. Exit 2 surfaces stderr to
the agent as a system reminder so it can react in the same turn, which is the
point: a CI failure arrives minutes later, after the reasoning that produced the
mistake has left the context window.

Deliberately regex-based, not a linter run. It must cost milliseconds, or it gets
disabled. Full lint belongs in CI.

Every rule here traces to a defect seen in real projects. A rule that fires on
correct code is worse than no rule, so each is anchored tightly and the whole
thing stays silent unless it has something specific to say.

A crash in the review is SAID (exit 2, reason on stderr), never a silent exit 1
that reads as "nothing to report". `--pre` is different: it only stashes the
file's prior content, and if it fails the post pass judges the whole file
instead of the diff -- more findings, never fewer -- so it never blocks a write.
"""
import difflib
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

# Write carries no old_string/new_string, so a whole-file rewrite hides the very
# shape the band-aid rule looks for -- measured: identical content fires on Edit
# and is silent on Write. `--pre` stashes the prior content so the post pass has
# something to diff.
SNAP = Path(tempfile.gettempdir()) / 'bendit-snap'
# A snapshot whose post pass never ran (the tool call was denied, the session
# died) is dropped after this long, so the directory cannot grow without bound.
SNAP_STALE = 24 * 60 * 60


def _sid(payload) -> str:
    sid = payload.get('session_id') if isinstance(payload, dict) else None
    if not isinstance(sid, str) or not sid.strip():
        return 'nosession'
    return ''.join(c for c in sid if c.isalnum() or c in '-_')[:64] or 'nosession'


def _snap_path(p: str, sid: str) -> Path:
    # Keyed by SESSION and path. Path alone let two sessions editing one file
    # share a snapshot: the second --pre overwrote the first one's "before",
    # and the first one's band-aid was judged against the wrong text.
    return SNAP / hashlib.sha256(f'{sid}\0{p}'.encode()).hexdigest()[:32]


def _prune_snaps() -> None:
    cutoff = time.time() - SNAP_STALE
    try:
        for f in SNAP.iterdir():
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
    except OSError:
        pass


def _payload():
    """(payload, tool_input, path) -- or None for anything that is not a hook
    payload naming a file. Such a payload has nothing to review."""
    try:
        payload = json.loads(sys.stdin.buffer.read().decode('utf-8', 'surrogateescape'))
    except ValueError:
        return None
    if not isinstance(payload, dict):
        return None
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        return None
    path = ti.get('file_path') or ti.get('path') or ''
    if not isinstance(path, str):
        return None
    return payload, ti, path


def pre() -> int:
    got = _payload()
    if got is None:
        return 0
    payload, ti, path = got
    suffix = Path(path).suffix
    if not path or (suffix not in CODE_SUFFIXES and suffix not in SHELL_SUFFIXES):
        return 0
    try:
        SNAP.mkdir(parents=True, exist_ok=True)
        _prune_snaps()
        src = Path(path)
        _snap_path(path, _sid(payload)).write_text(
            src.read_text(errors='replace') if src.is_file() else '')
    except OSError:
        pass
    return 0

CODE_SUFFIXES = {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'}
SHELL_SUFFIXES = {'.sh', '.bash', '.zsh'}

# Shell checks that report success when the thing they check failed. Each of
# these produced a false PASS in practice, which is worse than no check: the
# conclusion built on top of it is wrong and nothing signals it.
SHELL_RULES = [
    (re.compile(r'\|\s*(tail|head|grep|sed|awk)\b[^\n|]*&&'),
     "Exit status after a pipe belongs to the LAST command, so this reports "
     "success even when the piped-from command failed. Use `set -o pipefail`, "
     "check PIPESTATUS/pipestatus, or don't pipe the thing you are testing."),
    (re.compile(r'^\s*\[\s[^]]*\]\s*&&\s*[A-Za-z_][A-Za-z0-9_]*='),
     "`[ test ] && VAR=x` returns non-zero when the test is false. Under "
     "`set -e` that exits the script silently, mid-way, often with no output. "
     "Use if/then/fi."),
    (re.compile(r'-c\s+"[^"\n]*\x27"\x27"\x27'),
     "The '\"'\"' idiom escapes a quote inside a SINGLE-quoted string. Inside "
     "the double-quoted -c argument a single quote is already literal, so this "
     "injects garbage into the command."),
    (re.compile(r'\btimeout\s+\d'),
     "`timeout` is GNU coreutils and is absent on macOS: the command never "
     "runs and whatever you assert afterwards passes unchanged. Use gtimeout, "
     "or a bounded retry loop."),
]

# (regex, message) -- checked per line
LINE_RULES = [
    (re.compile(r'^\s*(//|/\*).*\b(for now|temporar|workaround|hack|band-?aid|safety net|revisit later)\b', re.I),
     "This comment explains a workaround rather than a non-obvious why. It is the "
     "artifact that makes a band-aid permanent -- the next agent reads it as "
     "precedent. Fix the cause, or record it as a TODO with a condition (greppable) "
     "rather than prose (not)."),
    (re.compile(r'@ts-ignore'),
     "@ts-ignore silences the next line entirely, including errors you did not "
     "anticipate. Use @ts-expect-error, which fails when the error goes away."),
    # `[^)]`, not `[^,]`. A character class that stops at the first comma cannot
    # reach past the FIRST argument, and `createClient(url, key)` is the only
    # signature Supabase has -- the key is always second. So that branch could
    # never fire on real code, while `.rpc(` and SUPABASE_SECRET_KEY beside it
    # always did, which is why the rule looked alive. Found by checking every
    # rule message against the snapshot and finding this one absent from every
    # case.
    (re.compile(r'\.rpc\(|createClient\(\s*[^)]*SERVICE_ROLE|SUPABASE_SECRET_KEY'),
     "This touches an RLS-bypassing credential. Confirm the module is server-only "
     "(`import 'server-only'` at the top) and that the route checks authorization."),
]

# whole-file checks
# `[^{}]` cannot match through `NextResponse.json({`, which is exactly the shape
# this is looking for. Bound by length instead of by brace-freedom.
CATCH_SWALLOW = re.compile(
    r'catch\s*\([^)]*\)\s*\{.{0,300}?(success\s*:\s*true|status\s*:\s*200\b)', re.S)

# A NEXT_PUBLIC_* value is public by design; flagging every one is noise. The
# defect is a NEXT_PUBLIC_* value used to AUTHORIZE something -- so require the
# file to be doing credential checking, and exempt names that are meant to ship
# to the browser.
AUTH_CONTEXT = re.compile(r'x-api-key|authorization|Bearer |validApiKeys|allowedKeys|apiKeys\b', re.I)
PUBLIC_BY_DESIGN = re.compile(
    r'NEXT_PUBLIC_[A-Z0-9_]*(PUBLISHABLE|ANON|PUBLIC_KEY|MAPS|POSTHOG|CLARITY|GTM|GA_|RECAPTCHA_SITE)')
NEXT_PUBLIC_READ = re.compile(r'process\.env\.(NEXT_PUBLIC_[A-Z0-9_]+)')


# A literal default after `??`. The quotes are spelled out with a non-raw
# string: `''` written INSIDE an r'...' literal is two adjacent Python strings,
# so this once compiled to `(\{\}|\[\]|0||""|null)` -- an empty alternative that
# matched every `??` -- and `?? ''` itself was never in the class at all.
NULLISH_DEFAULT = re.compile(
    r'\?\?\s*(\{\}|\[\]|0(?![\w.])|' + "''" + r'|""|``|null\b|undefined\b|false\b)')

BAND_AID = [
    (re.compile(r'\?\.'),                      'optional chaining'),
    (NULLISH_DEFAULT,                           'a nullish default'),
    (re.compile(r'\|\|\s*(\{\}|\[\])'),        'an || fallback'),
    (re.compile(r'\btry\s*\{'),                 'a try/catch'),
]


def _skeleton(t: str) -> str:
    """The text with every guard construct removed, for "did anything else change".

    The guard is removed WHOLE -- `?? ''` including its default, `catch (e)`
    including its binding. Stripping only punctuation and keywords left the
    `0`, the `''` and the `e` behind, so `?? 0`, `?? ''` and
    `try {…} catch (e) {}` always looked like real logic and never fired.
    """
    t = NULLISH_DEFAULT.sub('', t)
    t = re.sub(r'\|\|\s*(\{\}|\[\])', '', t)
    t = re.sub(r'\bcatch\s*\(\s*[A-Za-z_$][\w$]*\s*(:\s*[A-Za-z_$][\w$]*\s*)?\)', 'catch', t)
    return re.sub(r'[\s?.!|{}\[\]();]|\btry\b|\bcatch\b|\bnull\b|\bundefined\b|\breturn\b', '', t)


def _band_aid_edit(ti):
    """Flag an edit whose only substantive change is adding a guard."""
    old, new = ti.get('old_string'), ti.get('new_string')
    if not isinstance(old, str) or not isinstance(new, str) or not old.strip():
        return None
    added = []
    for rx, label in BAND_AID:
        if len(rx.findall(new)) > len(rx.findall(old)):
            added.append(label)
    if not added:
        return None
    # If the edit also changed real logic, it is probably a genuine fix.
    if _skeleton(new) != _skeleton(old):
        return None
    return ('This edit adds ' + ' and '.join(added) + ' and changes nothing else. '
            'That silences the symptom without establishing why the bad state is '
            'reachable. Name the cause -- or say explicitly that this is a stopgap '
            'and what the real fix is.')


def _plan_notes(raw: str) -> list:
    """Lint a superpowers plan as it is written. Returns the note lines.

    Folded in here rather than given a hook of its own: this one already runs
    on the same matcher with the same payload, and a second python process on
    every edit is cost bought for files written a few times a month. The linter
    is loaded only when the path names a plan, so every other edit pays one
    substring test.

    Advisory: it never touches this hook's exit code, and any failure yields no
    note. Blocking the write would mean a half-written plan cannot be saved, and
    a plan is written in passes.
    """
    try:
        if 'docs/superpowers/plans/' not in raw.replace(os.sep, '/'):
            return []
        import importlib.util
        src = Path(__file__).with_name('check-plan.py')
        spec = importlib.util.spec_from_file_location('check_plan', src)
        if spec is None or spec.loader is None:
            return []
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return [str(x) for x in (mod.advise(Path(raw)) or [])]
    except Exception:
        return []    # a reporter must never break the thing it reports on


def _mod_import_notes(raw: str) -> list:
    """Check a mod's directory for a sibling export a module forgot to import.

    Folded in here for the same reason as `_plan_notes`. Scoped to a directory
    that holds a `hooks.json`, because that is what makes a directory a plugin
    mod -- a directory merely called `hooks` (a React convention) is none of
    this check's business. Nothing type-checks a mod on a clean checkout: its
    type declarations are generated once the plugin has loaded, so there is no
    `tsc` to run. Advisory: it reports, it never changes this hook's exit code,
    and any failure yields no note.
    """
    try:
        p = Path(raw)
        if p.suffix not in {'.ts', '.tsx', '.mts', '.cts'}:
            return []
        if not any((d / 'hooks.json').is_file()
                   for d in (p.parent, p.parent.parent)):
            return []
        import subprocess
        out = subprocess.run(
            [sys.executable, str(Path(__file__).with_name('check-mod-imports.py')),
             '--no-recurse', str(p.parent)],
            capture_output=True, text=True, timeout=10)
        # Only the checker's own report counts: an uncaught crash also exits 1,
        # and its traceback is not advice.
        if out.returncode == 1 and out.stderr.startswith('mod import check:'):
            return out.stderr.rstrip().splitlines()
    except Exception:
        pass    # a reporter must never break the thing it reports on
    return []


def _ranges(a: list, b: list, offset: int = 0) -> set:
    """1-based line numbers in `b` (shifted by `offset`) that are new against `a`."""
    out = set()
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    for tag, _i1, _i2, j1, j2 in sm.get_opcodes():
        if tag in ('replace', 'insert'):
            out.update(range(offset + j1 + 1, offset + j2 + 1))
    return out


def _added_lines(text: str, ti: dict, before):
    """Line numbers this edit ADDED to `text`, or None when that is unknowable.

    The per-line rules judged the whole file, so an unrelated one-line edit to a
    file that already carried a @ts-ignore exited 2 and told the agent to fix
    code it had not touched -- on every edit to that file. A rule that fires on
    code the agent did not write is noise, and noise gets a hook switched off.

    None (judge everything) only when there is neither a snapshot nor an
    old/new pair: a judgement on too much beats silence on an edit.
    """
    lines = text.splitlines()
    if before is not None:
        return _ranges(before.splitlines(), lines)
    old, new = ti.get('old_string'), ti.get('new_string')
    if not isinstance(old, str) or not isinstance(new, str):
        return None
    at = text.find(new) if new else -1
    if at < 0:
        return None
    occurrences = [at]
    if ti.get('replace_all'):
        while True:
            nxt = text.find(new, occurrences[-1] + len(new))
            if nxt < 0:
                break
            occurrences.append(nxt)
    out = set()
    for pos in occurrences:
        # The new string may begin mid-line; its first line is that line.
        out |= _ranges(old.splitlines(), new.splitlines(), text[:pos].count('\n'))
    return out


def _review(path: str, ti: dict, before, edit_note):
    """(exit code, message) for one edited file. Never prints."""
    suffix = Path(path).suffix
    if not path or (suffix not in CODE_SUFFIXES and suffix not in SHELL_SUFFIXES):
        return 0, ''
    p = Path(path)
    if not p.is_file() or any(part in {'node_modules', '.next', 'dist', 'build'} for part in p.parts):
        return 0, ''
    try:
        text = p.read_text(errors='replace')
    except OSError:
        return 0, ''
    if len(text) > 400_000:
        return 0, ''

    added = _added_lines(text, ti, before)

    def fresh(n: int) -> bool:
        return added is None or n in added

    lines = text.splitlines()
    findings = []

    if suffix in SHELL_SUFFIXES:
        # A test file contains the bad patterns on purpose, as fixtures.
        # Flagging them there is pure noise, and noise is what gets a hook
        # switched off.
        if p.name.endswith(('.test.sh', '_test.sh')) or 'fixtures' in p.parts:
            return 0, ''
        has_set_e = bool(re.search(r'^\s*set\s+-[a-z]*e', text, re.M))
        has_pipefail = 'pipefail' in text
        for n, line in enumerate(lines, 1):
            if not fresh(n) or line.lstrip().startswith('#'):
                continue
            for rx, msg in SHELL_RULES:
                if rx.search(line):
                    if 'set -e' in msg and not has_set_e:
                        continue
                    if 'after a pipe' in msg and has_pipefail:
                        continue   # pipefail makes the pipeline's status honest
                    findings.append(f'{p.name}:{n}  {msg}')
                    break
        if not findings:
            return 0, ''
        return 2, ('[bendit] post-edit review:\n  ' + '\n  '.join(findings[:6]) +
                   '\n\nA check that can pass for the wrong reason is worse than no check.')

    is_client = bool(re.match(r'^\s*[\'"]use client[\'"]', text))

    for n, line in enumerate(lines, 1):
        if len(line) > 500 or not fresh(n):
            continue
        for rx, msg in LINE_RULES:
            if rx.search(line):
                findings.append(f'{p.name}:{n}  {msg}')
                break

    # File-level rules fire only when the edit touched what they are about.
    cred = re.compile(r'SUPABASE_SECRET_KEY|SERVICE_ROLE|adminSupabase|adminClient')
    if is_client and cred.search(text) and (
            added is None or 1 in added
            or any(cred.search(lines[n - 1]) for n in added if 0 < n <= len(lines))):
        findings.append(
            f"{p.name}  This is a 'use client' module that references a service-role "
            f"credential or RLS-bypassing client. Anything it reads is compiled into "
            f"the browser bundle.")

    if AUTH_CONTEXT.search(text):
        for n, line in enumerate(lines, 1):
            if not fresh(n):
                continue
            m = NEXT_PUBLIC_READ.search(line)
            if m and not PUBLIC_BY_DESIGN.search(m.group(1)):
                findings.append(
                    f"{p.name}:{n}  {m.group(1)} is used in a file that performs "
                    f"credential checks. NEXT_PUBLIC_* is inlined into the browser "
                    f"bundle at build time, so it is public in every build that "
                    f"ships and cannot authorize anything.")

    for m in CATCH_SWALLOW.finditer(text):
        first = text[:m.start()].count('\n') + 1
        last = first + m.group(0).count('\n')
        if any(fresh(n) for n in range(first, last + 1)):
            findings.append(
                f"{p.name}  A catch block appears to return a success shape. That turns a "
                f"loud failure into a quiet wrong answer -- the caller cannot tell the "
                f"difference between 'no rows' and 'it broke'.")
            break

    if edit_note:
        findings.insert(0, f'{p.name}  {edit_note}')

    if not findings:
        return 0, ''

    seen, out = set(), []
    for f in findings:
        if f not in seen:
            seen.add(f)
            out.append(f)

    return 2, ('[bendit] post-edit review:\n  ' + '\n  '.join(out[:6]) +
               ('\n  ...' if len(out) > 6 else '') +
               '\n\nAddress these now or say explicitly why each does not apply.')


def main() -> int:
    got = _payload()
    if got is None:
        return 0
    payload, ti, path = got
    notes = _plan_notes(path) + _mod_import_notes(path)

    # The PreToolUse snapshot of this file, if --pre ran, is CONSUMED here
    # whatever the tool. Only the Write/MultiEdit branch used to delete it, so
    # every Edit left one behind for good.
    before = None
    sp = _snap_path(path, _sid(payload)) if path else None
    if sp is not None and sp.is_file():
        try:
            before = sp.read_text()
        except OSError:
            pass
        try:
            os.unlink(sp)
        except OSError:
            pass

    # An Edit carries old_string/new_string -- the diff. That is the only way to
    # see that a change ADDED a guard, which is what distinguishes papering over
    # a bad state from legitimately handling an optional value. The rule runs
    # here, deterministically, rather than being left to skill guidance.
    edit_note = _band_aid_edit(ti)
    if edit_note is None and not isinstance(ti.get('old_string'), str) and before is not None:
        # Neither Write nor MultiEdit carries old_string/new_string: Write sends
        # the whole new file, MultiEdit sends an `edits` ARRAY, and neither shape
        # reaches _band_aid_edit. Without this branch the band-aid rule would
        # never apply to a MultiEdit, although hooks.json matches it.
        #
        # The PreToolUse snapshot already holds what was there before, and
        # PostToolUse runs after the write, so the file on disk is the new
        # content. One path now serves every tool that rewrites a file, instead
        # of one branch per payload shape.
        try:
            after = ti.get('content')
            if not isinstance(after, str):
                src = Path(path)
                after = src.read_text(errors='replace') if src.is_file() else ''
            edit_note = _band_aid_edit({'old_string': before, 'new_string': after})
        except OSError:
            pass

    code, msg = _review(path, ti, before, edit_note)
    # CHANNELS. Exit 2 puts stderr in front of the model: the documented
    # PostToolUse block. On exit 0 stderr reaches nobody, so the advisory notes
    # travel as `additionalContext`, the field PostToolUse reads for text handed
    # to the model. When the hook already exits 2 they ride along on stderr.
    if code == 2:
        print(msg + ('\n\n' + '\n'.join(notes) if notes else ''), file=sys.stderr)
        return 2
    if notes:
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': '\n'.join(notes)}}, ensure_ascii=False))
    return 0


def run(argv) -> int:
    if '--pre' in argv:
        try:
            return pre()
        except Exception:
            return 0   # see the module docstring: --pre never blocks a write
    try:
        return main()
    except Exception as exc:
        print(f'[bendit] post-edit review itself failed '
              f'({type(exc).__name__}: {exc}), so this edit was NOT reviewed.',
              file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(run(sys.argv[1:]))
