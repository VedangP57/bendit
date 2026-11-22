#!/usr/bin/env python3
"""Constraints encoded in the FILENAME, so the check costs nothing to run.

A rule that must work out whether a file is a hot path, or generated, needs to
understand the code -- which means an AST, a maintainer, and judgement that goes
stale. A rule keyed to the NAME needs a glob.

    foo.hot.ts    this runs every frame or every tick; do not allocate in it
    foo.gen.ts    a generator wrote this; edit the generator

That is the whole mechanism, and the elegance is that it is opt-in by rename.
Nothing here fires until somebody deliberately renames a file to claim the
contract, so an ordinary file can never be refused. INSIDE a file that claims
.hot.*, the allocation check is a set of regexes, not a parser, and it has both
kinds of error -- listed below rather than claimed away.

Measured in the kit this was extracted from: guidance that asks for a behaviour
moved it about one run in five, a hook that refuses moved it every time. The
filename is what makes the refusing version cheap enough to exist.

NAMES: matched case-insensitively. `.hot.` covers ts, tsx, js,
jsx, mts, cts, mjs, cjs; `.gen.` covers any extension chain, so
`types.gen.d.ts` is generated too.

WHAT COUNTS AS ALLOCATING in a .hot.* file: `new X`, closures (`=>`, a
function expression), object literals (`{ a: 1 }`, `{}`, `{ a, b }`,
`{ 'a': 1 }` in expression position), array literals in expression position,
spreads, template literals, string concatenation with a string literal, the
allocating array methods (map filter slice concat flat split join), and
Array.from/of, Object.assign/keys/values/entries/fromEntries.

WHAT DOES NOT: comments; type aliases and interfaces (erased); and the HEADER
of a top-level function declaration -- declaring the hot function is not an
allocation per tick. Its BODY is still checked, so a closure inside it is
refused.

KNOWN MISSES, deliberately not chased (each needs types or a parser):
  * concatenation of two string VARIABLES (`a + b`) -- indistinguishable from
    arithmetic without types;
  * string methods that return new strings (.replace, .trim, .toUpperCase,
    .substring, .padStart ...), and any call that allocates inside itself;
  * a named function declared inside an Edit fragment (the fragment's own
    top level may be inside the hot function, where it IS a closure);
  * an array literal after `:` (a ternary branch) -- `:` is also every type
    annotation, which would refuse tuple types;
  * a regex literal containing `//` reads as a comment and hides the rest of
    its line.
KNOWN FALSE POSITIVES: an inline object TYPE outside a declaration header
(`const p: { x: number } = q`), and a return type written with braces.

PreToolUse on Write|Edit|MultiEdit: exit 2 refuses the write, and the reason on
stderr goes back to the model.
"""
import io
import json
import os
import re
import sys
from pathlib import Path

# The rule id each refusal is logged under (fire_log.py), and the list
# /bendit:guard-report reads -- by PARSING this file, so it stays a literal.
# A crash that refuses is logged as guard-error and kept out of the list.
RULES = ['gen-file-edit', 'hot-file-allocation']

HOT = re.compile(r'\.hot\.(?:[cm]?[jt]s|[jt]sx)$', re.IGNORECASE)
GEN = re.compile(r'\.gen(?:\.[A-Za-z0-9]+)+$', re.IGNORECASE)

# Every one of these puts an object on the heap on the line it appears. In code
# that runs each frame, that is the garbage that makes a collector stutter.
# They run on the SKELETON (see below): comments blanked, string contents
# replaced, declarations removed.
# Expression position. A `{` at the start of a statement is a BLOCK, so the
# object-literal form leaves out start, `;` and `{`; an array cannot be a
# block, so the array form keeps them (`[a, b] = [b, a]` allocates).
_EXPR = r'(?:[=(,?&|!\[]|\breturn\b|\byield\b)\s*'
_STMT_START = r'(?:^|[;{])\s*'
ALLOCATES: tuple[tuple[str, str], ...] = (
    (r'\bnew\s+[A-Z]', 'new'),
    (r'=>', 'a closure (=>)'),
    (r'\bfunction\b', 'a closure (function)'),
    (r'(?<![\w$)\]])\{\s*\w+\s*:', 'an object literal'),
    (_EXPR + r'\{', 'an object literal'),
    (f'(?:{_EXPR}|{_STMT_START})' + r'\[', 'an array literal'),
    (r'\.(map|filter|slice|concat|flat|split|join)\s*\(', 'an allocating array method'),
    (r'\b(?:Array\.(?:from|of)|Object\.(?:assign|keys|values|entries|fromEntries))\s*\(',
     'an allocating builtin'),
    (r'\.\.\.', 'a spread'),
    (r'`', 'a template literal'),
    (r'[\'"]\s*\+|\+=?\s*[\'"]', 'string concatenation'),
)


def _skeleton(text: str) -> str:
    """Comments become spaces; string contents become `x`. Quotes, newlines
    and every position are kept, so a `{` or `//` inside a string is not
    structure, and `'http://x'` does not start a comment."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j == -1 else j
            out[i:j] = ' ' * (j - i)
            i = j
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j == -1 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        if c in '\'"`':
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == '\\':
                    j += 1
                elif text[j] == '\n' and c != '`':
                    break
                j += 1
            for k in range(i + 1, min(j, n)):
                if out[k] != '\n':
                    out[k] = 'x'
            i = j + 1
            continue
        i += 1
    return ''.join(out)


_STMT = r'(?:^|(?<=[;{}\n]))[ \t]*(?:export\s+)?(?:default\s+)?(?:declare\s+)?'
_FN_DECL = re.compile(_STMT + r'(?:async\s+)?function\s*\*?\s*[\w$]+\s*(?:<[^>()]*>)?\s*\(', re.M)
_TYPE_DECL = re.compile(_STMT + r'type\s+[\w$]+\s*(?:<[^=]*?>)?\s*=', re.M)
_INTERFACE = re.compile(_STMT + r'interface\s+[\w$]+[^{]*\{', re.M)


def _close(sk, i, open_ch, close_ch):
    """Index past the bracket matching sk[i]."""
    depth = 0
    for k in range(i, len(sk)):
        if sk[k] == open_ch:
            depth += 1
        elif sk[k] == close_ch:
            depth -= 1
            if depth == 0:
                return k + 1
    return len(sk)


def _statement_end(sk, i):
    depth = 0
    for k in range(i, len(sk)):
        ch = sk[k]
        if ch in '({[':
            depth += 1
        elif ch in ')}]':
            depth -= 1
        elif depth <= 0 and ch in ';\n':
            return k
    return len(sk)


def _without_declarations(sk: str) -> str:
    out = list(sk)
    depth, d = [], 0
    for ch in sk:
        depth.append(d)
        if ch == '{':
            d += 1
        elif ch == '}':
            d = max(0, d - 1)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    for m in _INTERFACE.finditer(sk):
        blank(m.start(), _close(sk, m.end() - 1, '{', '}'))
    for m in _TYPE_DECL.finditer(sk):
        blank(m.start(), _statement_end(sk, m.end()))
    for m in _FN_DECL.finditer(sk):
        if depth[m.start()] != 0:
            continue   # nested: a closure allocated on every call
        end = _close(sk, m.end() - 1, '(', ')')
        ret = re.match(r'\s*:[^{;]*', sk[end:])
        if ret:
            end += ret.end()
        blank(m.start(), end)
    return ''.join(out)


def allocations(text: str):
    code = _without_declarations(_skeleton(text))
    return [why for rx, why in ALLOCATES if re.search(rx, code, re.M)]


def written(ti: dict) -> str:
    """The text this call puts INTO the file, whatever tool shape carried it.

    Write sends `content`, Edit sends `new_string`, MultiEdit sends an `edits`
    ARRAY and carries neither -- a rule that assumes one shape is silently
    dead for the others, so all three are handled here and none is assumed.
    """
    if isinstance(ti.get('edits'), list):
        return '\n'.join(str(e.get('new_string', '')) for e in ti['edits'] if isinstance(e, dict))
    for key in ('new_string', 'content'):
        if isinstance(ti.get(key), str):
            return ti[key]
    return ''


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    # A shape this hook does not understand is ignored, exactly as junk stdin
    # is: the contract is "never crash a turn", and a traceback did.
    if not isinstance(payload, dict):
        return 0
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        return 0
    path = ti.get('file_path') or ti.get('path') or ''
    if not isinstance(path, str) or not path:
        return 0
    name = Path(path).name

    if GEN.search(name):
        print(f'[bendit] {name} is generated (.gen.*): edit the generator, not its output.\n'
              f'If this file is no longer generated, rename it.', file=sys.stderr)
        _record_fire(payload, 'gen-file-edit', path)
        return 2

    if HOT.search(name):
        found = allocations(written(ti))
        if found:
            shown = ', '.join(dict.fromkeys(found))
            print(f'[bendit] {name} is marked .hot.*: it runs every frame or every tick, '
                  f'and this allocates — {shown}.\n'
                  f'Hoist it out of the hot path, reuse a preallocated object, or rename '
                  f'the file if it is not hot after all.', file=sys.stderr)
            _record_fire(payload, 'hot-file-allocation', path)
            return 2
    return 0


def run() -> int:
    # A crash must REFUSE: exit 1 from a traceback is a non-blocking error to
    # Claude Code, so the write would go through unchecked.
    # A SystemExit or KeyboardInterrupt would exit 0 or 130: it refuses too.
    try:
        return main()
    except BaseException as exc:  # noqa: B036
        try:
            why = f'{type(exc).__name__}: {exc}'
        except BaseException:
            why = 'an error that could not be described'
        print(f'[bendit] BLOCKED: the path-contracts guard itself failed '
              f'({why}), so this write could not be checked.',
              file=sys.stderr)
        _record_fire(None, 'guard-error', '')
        return 2


def _record_fire(payload, rule: str, preview: str) -> None:
    """Log this refusal (fire_log.py). Called only AFTER the decision is
    printed, inside a net that catches everything -- a fire_log.py that is
    missing, will not import, raises, exits or prints -- with stdout and
    stderr held, so the exit code and every byte the guard printed are the
    same whether or not the log was written."""
    saved = sys.stdout, sys.stderr
    try:
        sys.stderr.flush()
        sys.stdout.flush()
        sys.stdout = sys.stderr = io.StringIO()
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fire_log
        fire_log.record(fire_log.project_root(payload), 'path-contracts', rule, preview)
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
