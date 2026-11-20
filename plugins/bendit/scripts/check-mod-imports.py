#!/usr/bin/env python3
"""A name a sibling module exports, used in this file, never imported here.

That is the defect: a constant is exported by `roster.ts`, used in `index.ts`,
and the import list does not mention it. Every call throws `ReferenceError`
there, a `catch { /* never break the tick */ }` swallows it, and the feature
silently never runs while the unit tests stay green.

A type checker catches this (`tsc` reports `TS2304: Cannot find name 'X'`) and
catches everything this cannot: wrong shapes, wrong arity, and names no
heuristic here could resolve. This script is the fallback for when `tsc`
cannot run -- a plugin's type declarations are generated at load time and
git-ignored, so on a clean checkout or in unattended CI there is no `tsc` to
run. That gap is the whole reason this file exists.

HOW IT AVOIDS CRYING WOLF. A rule that fires on correct code gets the whole
check switched off, so the binder set is deliberately OVER-approximated: every
declaration, destructured name, function parameter, catch binding and imported
binding counts as bound, and so does anything that merely looks like one. That
trades recall for silence on purpose. It also means the check is not a type
checker and must not be read as one -- when `tsc` is available, run that.

Not a reference, and therefore never a finding: a name in a comment, in a
quoted string, in the prose of a template literal, as a property (`o.NAME`),
as an object key (`{ NAME: 1 }`), in an import, or in a re-export.
"""
import os
import re
import sys
from pathlib import Path

BLOCK = re.compile(r'/\*.*?\*/', re.S)
LINE = re.compile(r'//[^\n]*')
SQ = re.compile(r"'(?:[^'\\\n]|\\.)*'")
DQ = re.compile(r'"(?:[^"\\\n]|\\.)*"')
# An import, and a re-export, MENTION names without using them at runtime.
PORT_STMT = re.compile(r'(?:import|export)\s[^;]*?from\s*[\'"][^\'"]*[\'"]', re.S)
# `async` and `default` both sit between `export` and the name.
EXPORTED = re.compile(
    r'^export\s+(?:default\s+)?(?:async\s+)?(?:const|let|var|function|class|enum)\s+'
    r'([A-Za-z_$][\w$]*)', re.M)
DECLARED = re.compile(
    r'(?:const|let|var|function|class|enum|catch)\s*\(?\s*([A-Za-z_$][\w$]*)')
IDENT = re.compile(r'[A-Za-z_$][\w$]*')
# A use: not a property, not an object key or label.
USE = re.compile(r'(?<![.\w$])([A-Za-z_$][\w$]*)(?![\w$])(?!\s*:)')
# Anything that binds a list of names.
PARAMS = re.compile(r'\(([^()]*)\)\s*(?:=>|\{|:)')
PATTERN = re.compile(r'(?:const|let|var)\s*([{\[][^=;]*[}\]])\s*=')


def _blank(m: re.Match) -> str:
    """Replace a comment with its own newlines.

    Dropping them outright renumbers every line below, and this check reports
    `file:line` -- it cited 356 for a defect on line 402 the first time it ran.
    A check that points at the wrong line sends the reader to innocent code.
    """
    return '\n' * m.group(0).count('\n')


def _templates(src: str) -> str:
    """Keep only the `${...}` parts of a template literal.

    `${NAME}` is a real reference; the prose around it is not. A help string
    reading `tune SHOWN_LIMIT_MS to change this` was reported as a defect until
    this existed -- and the wider the name set, the likelier such a collision
    ("prune the roster" against an exported `prune`).
    """
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c != '`':
            out.append(c)
            i += 1
            continue
        i += 1
        while i < n and src[i] != '`':
            if src[i] == '\\':
                out.append('\n' if src[i:i + 2] == '\\\n' else ' ')
                i += 2
                continue
            if src[i:i + 2] == '${':
                depth = 1
                i += 2
                out.append(' ')
                while i < n and depth:
                    if src[i] == '{':
                        depth += 1
                    elif src[i] == '}':
                        depth -= 1
                        if not depth:
                            break
                    out.append(src[i])
                    i += 1
                i += 1
                out.append(' ')
                continue
            out.append('\n' if src[i] == '\n' else ' ')
            i += 1
        i += 1
    return ''.join(out)


# A regex literal, recognised only where a value may start -- after an operator,
# an opening bracket or a comma -- so `a / b / c` is left as division. Blanked
# before quotes are paired, because `s.replace(/'/g, "A")` puts a lone
# apostrophe in the source: two such literals on one line made SQ pair THEM and
# blank the real code between, which silently dropped a genuine finding.
REGEX_LIT = re.compile(
    r'(?<=[(,=:\[!&|?{};+\-*%<>~^])\s*'
    r'(/(?![*/])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\]|\\.)*\])+/[gimsuyd]*)')


def strip(src: str) -> str:
    # Order: regex literals, then comments, then quotes. Every one of these
    # removes candidates, never binders -- imports are read from the RAW text
    # (bound_in) -- so a stripper that takes too much costs recall and can
    # never invent a finding.
    no_regex = REGEX_LIT.sub(lambda m: ' ' * len(m.group(1)), src)
    no_comments = LINE.sub(_blank, BLOCK.sub(_blank, no_regex))
    return DQ.sub('""', SQ.sub("''", _templates(no_comments)))


def names_in_import(stmt: str) -> set:
    """Every binding an import statement introduces: braces, default or star."""
    out = set()
    inner = re.search(r'\{(.*?)\}', stmt, re.S)
    if inner:
        for part in inner.group(1).split(','):
            part = part.strip().removeprefix('type ').strip()
            if part:
                out.add(part.split(' as ')[-1].strip())
    head = stmt.split('{')[0]
    for m in re.finditer(r'import\s+(?:type\s+)?([A-Za-z_$][\w$]*)', head):
        out.add(m.group(1))
    for m in re.finditer(r'\*\s+as\s+([A-Za-z_$][\w$]*)', stmt):
        out.add(m.group(1))
    return out


# `export { a, b as c }` -- a LOCAL export list (no `from`). Its names were
# invisible: only `export const|function|...` counted as an export.
EXPORT_LIST = re.compile(r'(?<![\w$])export\s*\{([^}]*)\}(?!\s*from)')
TYPE_EXPORTED = re.compile(
    r'^export\s+(?:declare\s+)?(?:type|interface|namespace|abstract\s+class)\s+([A-Za-z_$][\w$]*)',
    re.M)
STAR_EXPORT = re.compile(r'(?<![\w$])export\s*\*')
VALUE_DECL = r'(?:const|let|var|function\*?|class|enum)\s+{}(?![\w$])'


def exports_of(body: str):
    """(value exports, every export name, opaque) for one stripped file body.

    `opaque` is True when the file re-exports `*`: its full export set cannot be
    known from here, so nothing may be judged missing from it.
    """
    values = set(EXPORTED.findall(body))
    every = set(values) | set(TYPE_EXPORTED.findall(body))
    if re.search(r'^export\s+default\b', body, re.M):
        every.add('default')
    for m in EXPORT_LIST.finditer(body):
        for part in m.group(1).split(','):
            part = part.strip().removeprefix('type ').strip()
            if not part:
                continue
            local, _, public = part.partition(' as ')
            local, public = local.strip(), (public.strip() or local.strip())
            every.add(public)
            # Only a VALUE can be a ReferenceError; an exported type cannot.
            if re.search(VALUE_DECL.format(re.escape(local)), body):
                values.add(public)
    return values, every, bool(STAR_EXPORT.search(body))


# What opens a block or a condition rather than a parameter list.
NOT_PARAMS = re.compile(r'(?<![\w$.])(if|while|for|switch|with|catch|return|typeof|await)\s*$')


def _close(body: str, i: int) -> int:
    """Index just past the bracket that closes the one at `i` (or end of text)."""
    pairs = {'{': '}', '(': ')', '[': ']'}
    stack = []
    for j in range(i, len(body)):
        c = body[j]
        if c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return j + 1
    return len(body)


def _expr_end(body: str, i: int) -> int:
    """End of an arrow function's expression body starting at `i`."""
    depth, seen = 0, False
    for j in range(i, len(body)):
        c = body[j]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                return j
            depth -= 1
        elif depth == 0 and (c in ',;' or (c == '\n' and seen)):
            return j
        if not c.isspace():
            seen = True
    return len(body)


def param_scopes(body: str) -> list:
    """(names, start, end) for every parameter list: names bound only in [start, end).

    A parameter binds inside ITS function. Counting it file-wide meant a
    parameter called X in one function silenced an unimported X everywhere
    else. And `if (X > 1) {` is a condition, not a parameter list -- it used to
    bind X for the whole file.
    """
    out = []
    for m in PARAMS.finditer(body):
        if NOT_PARAMS.search(body[:m.start()]):
            continue
        names = set(IDENT.findall(m.group(1)))
        if not names:
            continue
        # The body begins at the `=>` or `{` the match ended on, or -- after a
        # return-type annotation `):` -- at the next one of those.
        j = m.end() - 1
        tail = m.group(0)
        if tail.endswith(':'):
            k = re.compile(r'=>|\{').search(body, m.end())
            if not k:
                out.append((names, m.start(), len(body)))
                continue
            j, tail = k.start(), k.group(0)
        if tail.endswith('{'):
            end = _close(body, j)
        else:                                   # `=>`
            k = j + 1
            while k < len(body) and body[k].isspace():
                k += 1
            end = _close(body, k) if k < len(body) and body[k] == '{' else _expr_end(body, k)
        out.append((names, m.start(), end))
    return out


def bound_in(raw: str, body: str, own: set) -> set:
    """Over-approximate every name this file binds for itself, FILE-WIDE.

    Parameters are not here: they bind only inside their own function, which
    param_scopes() records.
    """
    out = set(own) | set(DECLARED.findall(body))
    for stmt in PORT_STMT.findall(raw):
        out |= names_in_import(stmt)
    for grp in PATTERN.findall(body):         # destructuring
        out |= set(IDENT.findall(grp))
    return out


def _resolve(p: Path, spec: str, known: dict):
    """The scanned file a relative import specifier names, or None."""
    if not spec.startswith('.'):
        return None
    base = (p.parent / spec)
    stem = base
    if base.suffix in {'.js', '.mjs', '.cjs', '.jsx'}:
        stem = base.with_suffix('')
    cands = [base] + [stem.with_name(stem.name + s) for s in ('.ts', '.tsx', '.mts', '.cts')]
    cands += [base / f'index{s}' for s in ('.ts', '.tsx', '.mts', '.cts')]
    for c in cands:
        try:
            r = c.resolve()
        except OSError:
            continue
        if r in known:
            return r
    return None


IMPORT_FROM = re.compile(r'(?<![\w$.])import\s+(?!\()([^;]*?)\s*from\s*[\'"]([^\'"]+)[\'"]', re.S)


def _dirs(target: Path, recurse: bool) -> list:
    if not recurse:
        return [target]
    out = []
    for d, subdirs, _files in os.walk(target):
        subdirs[:] = sorted(s for s in subdirs if s not in {'node_modules', '.git'})
        out.append(Path(d))
    return out


def check(d: Path, recurse: bool = True) -> list:
    files = []
    for sub in _dirs(d, recurse):
        files += sorted(p for p in sub.iterdir()
                        if p.is_file() and p.suffix in {'.ts', '.tsx', '.mts', '.cts'})
    raws = {p: p.read_text(errors='replace') for p in files}
    bodies = {p: strip(raws[p]) for p in files}
    # Read exports from the STRIPPED body: an `export const` sitting inside a
    # block comment is not an export, and counting it made every file that
    # mentioned the name a suspect.
    info = {p: exports_of(bodies[p]) for p in files}
    by_real = {p.resolve(): p for p in files}
    # Siblings are the files of ONE directory. A recursive run checks each
    # directory as its own group; a parent's export is not a sibling export.
    groups: dict = {}
    for p in files:
        groups.setdefault(p.parent, []).append(p)
    findings = []
    for p in files:
        siblings = {n: q for q in groups[p.parent] if q != p for n in info[q][0]}
        label = p.relative_to(d).as_posix() if recurse else p.name
        # 1. A sibling export used here and never imported.
        if siblings:
            bound = bound_in(raws[p], bodies[p], info[p][0])
            scopes = param_scopes(bodies[p])
            scan = PORT_STMT.sub(_blank, bodies[p])
            seen = set()
            for m in USE.finditer(scan):
                name = m.group(1)
                if name in bound or name not in siblings or name in seen:
                    continue
                if any(name in ns and s <= m.start() < e for ns, s, e in scopes):
                    continue
                seen.add(name)
                findings.append(
                    f'{label}:{scan[:m.start()].count(chr(10)) + 1}  {name} is used '
                    f'here and exported by {siblings[name].name}, but this file never '
                    f'imports it. At runtime that is a ReferenceError.')
        # 2. An import of a name the module it names does not export. Read from
        # the text with comments blanked but strings intact: the specifier IS a
        # string.
        nocom = LINE.sub(_blank, BLOCK.sub(_blank, raws[p]))
        for m in IMPORT_FROM.finditer(nocom):
            target = _resolve(p, m.group(2), by_real)
            if target is None:
                continue
            _values, every, opaque = info[by_real[target]]
            if opaque:
                continue
            # A type-only import is erased before runtime: it cannot fail at
            # load, and only tsc can judge it. Only VALUE imports are checked.
            if re.match(r'\s*type\s', m.group(1)):
                continue
            inner = re.search(r'\{(.*?)\}', m.group(1), re.S)
            wanted = []
            if inner:
                for part in inner.group(1).split(','):
                    part = part.strip()
                    if part and not part.startswith('type '):
                        wanted.append(part.split(' as ')[0].strip())
            head = m.group(1).split('{')[0]
            dm = re.match(r'\s*(?:type\s+)?([A-Za-z_$][\w$]*)\s*(?:,|$)', head)
            if dm and dm.group(1) != 'type':
                wanted.append('default')
            for name in wanted:
                if name not in every:
                    findings.append(
                        f'{label}:{nocom[:m.start()].count(chr(10)) + 1}  imports '
                        f'{name} from {m.group(2)}, but {by_real[target].name} does not '
                        f'export it. Under ESM that fails at load time.')
    return findings


def main() -> int:
    args = sys.argv[1:]
    recurse = '--no-recurse' not in args
    targets = [Path(a) for a in args if a != '--no-recurse'] or [Path('.')]
    found, bad = [], []
    for t in targets:
        if t.is_dir():
            found += check(t, recurse)
        else:
            # Exiting 0 for a path that is not there made every caller's
            # "the real mod is clean" case unfalsifiable: rename the directory
            # and it still passed, having scanned nothing.
            bad.append(str(t))
    if bad:
        print('mod import check: not a directory: ' + ', '.join(bad), file=sys.stderr)
        return 2
    if not found:
        return 0
    print('mod import check:\n  ' + '\n  '.join(found), file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
