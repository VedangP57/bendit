#!/usr/bin/env python3
"""One word, one meaning -- a controlled vocabulary for a repo's agent prose.

WHY THIS EXISTS
    Evidence is graded on a five-rung ladder: 1 said so, 2 pointed at the line,
    3 showed the bad case cannot happen, 4 ran it and read the output, 5
    reproduced it in the running app. Prose that then uses check / verify /
    prove / confirm / assert / settle for the single act of reaching a rung
    makes the agent infer which rung is meant.

    ASD-STE100 Section 1 is the fix: a word keeps one meaning. This applies
    that rule, with the dictionary in vocabulary.json.

WHY IT IS A SCRIPT AND NOT ADVICE
    A deterministic check beats a sentence in an instruction file: the sentence
    rots while the check holds.

WHY THE BASELINE EXISTS
    A rule with 130 violations is not a rule. `--baseline` records the findings
    already in a repo so a run reports only what you write next. Burn the
    baseline down when you feel like it; it is a plain sorted text file and it
    diffs cleanly.

NO HOOK IS WIRED
    hooks/hooks.json does not call this script, on purpose. `--check` is for a
    manual run or CI; nothing runs it after an edit unless you wire it.

DICTIONARY (first that exists wins)
    1. $BENDIT_VOCAB
    2. <repo>/.claude/vocabulary.json     (`--init` copies the starter here)
    3. the starter vocabulary.json beside this script
    The baseline is <repo>/.claude/vocabulary-baseline.

MODES
    --report [PATH ...]     human-readable report over a tree      (default)
    --check FILE            one file; exit 2 with findings on stderr (manual/CI)
    --fix [PATH ...]        apply ONLY the safe substitutions, in place
    --dict                  print the dictionary (and which file it came from)
    --init                  copy the starter dictionary to <repo>/.claude/vocabulary.json
                            (refuses to overwrite)
    --baseline [PATH ...]   record current findings as accepted
    --html FILE             write an HTML report
    --json                  machine-readable findings
    --strict                run every rule against every document, ignoring its class
    --self-test             falsify every rule against the starter dictionary (no corpus)

SUPPRESSION
    `<!-- vocab-ok: reason -->` on the offending line or the line above it.
    The reason is required and is printed in the report, so a suppression is
    visible rather than silent.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STARTER = HERE / 'vocabulary.json'
LOCAL_DICT = Path('.claude') / 'vocabulary.json'
BASELINE_NAME = str(Path('.claude') / 'vocabulary-baseline')
DOC_SUFFIXES = {'.md', '.mdc', '.mdx'}

C = dict(red='\033[31m', yel='\033[33m', cyn='\033[36m', dim='\033[2m',
         bold='\033[1m', off='\033[0m')
if not sys.stdout.isatty() or os.environ.get('NO_COLOR'):
    C = {k: '' for k in C}


# ---------------------------------------------------------------- redaction
# Line numbers must survive, so every mask replaces characters in place with
# spaces rather than deleting them. A mask that shortened the text would make
# every reported line number wrong below the first code fence.
def redact(text: str) -> str:
    out = list(text)

    def blank(m, keep_newlines=True):
        for i in range(m.start(), m.end()):
            if not (keep_newlines and out[i] == '\n'):
                out[i] = ' '

    for rx in (re.compile(r'^```.*?^```', re.S | re.M),   # fenced code
               re.compile(r'^~~~.*?^~~~', re.S | re.M),
               re.compile(r'`[^`\n]*`'),                   # inline code
               re.compile(r'^\s*\|.*\|\s*$', re.M),        # table rows
               re.compile(r'\]\([^)\s]*\)'),               # link targets
               re.compile(r'^\s{4,}\S.*$', re.M),          # indented code
               re.compile(r'<!--.*?-->', re.S)):           # html comments
        for m in rx.finditer(text):
            blank(m)
    return ''.join(out)


# The reason is REQUIRED: `(\S.*?)` forces a non-space first character. A lazy
# `(.+?)` here captured the single space in `<!-- vocab-ok: -->` and suppressed
# with no reason at all — a silent bypass, caught by --self-test.
SUPPRESS = re.compile(r'<!--\s*vocab-ok:\s*(\S.*?)\s*-->')


def suppression(src_lines, line_no):
    """The vocab-ok reason on line `line_no` (1-based) or the line above."""
    for i in (line_no - 1, line_no - 2):
        if 0 <= i < len(src_lines):
            m = SUPPRESS.search(src_lines[i])
            if m:
                return m.group(1)
    return None


# ------------------------------------------------------------------- rules
def _word_rx(term: str) -> str:
    r"""A multi-word term may be separated by any whitespace, including a newline.

    `(?<![\w-])` not `\b`: a hyphen is a word boundary, so `\btested\b` matched
    inside `least-tested`. A hyphenated compound is a different word.
    """
    return (r'(?<![\w-])' + r'\s+'.join(re.escape(p) for p in term.split())
            + r'(?![\w-])')


# ---------------------------------------------------------- document class
# Rules are routed by what a document IS FOR. An instruction file tells the agent
# what to do, so a weakened modal in it is a defect. A report file claims work was
# done, so an unevidenced claim in it is a defect. Applying either rule to the
# other class is pure noise, and noise is what gets a check switched off.
INSTRUCTION_NAMES = {'agents.md', 'claude.md', 'skill.md', 'gemini.md', 'agent.md'}
INSTRUCTION_DIRS = {'commands', 'skills', '.claude', 'rules'}
REPORT_HINT = re.compile(r'(progress|report|verification|handoff|status|summary|'
                         r'changelog|release-notes|postmortem|writeup)', re.I)
# Directories whose contents nobody here wrote, or that a tool generates.
# `.superpowers` holds ledgers and per-task reports written by an agent run.
# Grading generated reports against a vocabulary nobody will edit produces work
# that can never be finished.
#
# NOT excluded, deliberately: `.cursor`. It can hold a MIX -- published rule
# docs copied in verbatim (.md) alongside the project's OWN rules (.mdc). An
# exclusion wide enough to drop the vendored docs would drop the real rules too,
# so vendored ones are accepted with a baseline instead.
VENDOR = {'node_modules', '.git', '.next', 'dist', 'build', 'vendor', 'Pods',
          '.variants', 'results', 'coverage', '.venv', 'target', 'Carthage',
          '.superpowers'}


def doc_class(p: Path) -> str:
    """instruction | report | other

    `p` must be RELATIVE to the repo root: a repo checked out under a folder
    named `skills` would otherwise grade every report as an instruction file.
    """
    if p.name.lower() in INSTRUCTION_NAMES:
        return 'instruction'
    if any(part in INSTRUCTION_DIRS for part in p.parts):
        return 'instruction'
    if REPORT_HINT.search(p.name):
        return 'report'
    return 'other'


RULES_FOR = {'instruction': ('substitute', 'obligation', 'slop'),
             'report':      ('substitute', 'evidence', 'slop'),
             'other':       ('substitute', 'slop')}

# Advisory rules are listed in the report and nowhere else: --check, the exit
# code of a default run and --fix all ignore them. Plain writing is a matter of
# taste at the margin, and a rule that blocks on taste gets switched off.
ADVISORY = frozenset({'slop'})

# An evidence claim is acceptable when an OBSERVATION sits near it. These are the
# shapes an observation usually takes. Checked against the
# ORIGINAL text, not the redacted one -- a command in backticks is exactly the
# evidence we are asking for, so redacting it away would invert the rule.
# A negated claim is the honest form -- "Not verified: source maps" is exactly the
# reporting the evidence ladder asks for. Firing on it would punish the right practice,
# which is how a check gets switched off. Guarded, with a self-test case.
# Whole words only: a bare `\bun` once matched "unit", and a bare `still` waved
# through "we still verified it" -- both are claims, not negations.
NEGATED = re.compile(
    r'(?:\bnot\b|\bnever\b|\bno\b|\bn[\u2019\']t\b|\bcannot\b|\bcan[\u2019\']t\b'
    r'|\bwithout\b|\bunable\b|\byet to\b|\bremains?\b|\bstill to\b)[\s\w,\u2019\'-]{0,18}$',
    re.I)

OBSERVATION = re.compile(
    r'rung\s*[1-5]'                      # the ladder, named
    r'|`[^`\n]{3,}`'                     # a command, path or identifier
    r'|\bexit(?:ed|\s+code)?\s*[:=]?\s*\d'
    r'|\b\d+\s+(?:passed|failed|pass|fail|ok|tests?|rows?|errors?)\b'
    r'|\b(?:passed|failed)\s*[:=]\s*\d'
    r'|[\w./-]+\.[a-z]{1,4}:\d+'        # file:line
    r'|artifacts?/|screenshots?/|\.png\b|\.jpg\b'
    r'|\b[0-9a-f]{7,40}\b'                # a commit SHA is an observation
    r'|\b[a-z][a-z0-9]*_[a-z0-9_]+\b'     # a snake_case identifier (pg_indexes, user_orders)
    r'|[=<>]\s*-?\d'                      # an expression with a value: max(id)=13
    r'|https?://', re.I)

# A claim QUALIFIED at the point of the claim -- "VERIFIED via pg_indexes:",
# "confirmed by git log", "verified against the migrations" -- already names its
# observation. Checked AFTER the match, so it cannot be satisfied by the claim word.
QUALIFIED = re.compile(
    r'^\s*(?::|—|-|via|by|against|using|with|from|in|through)\b[^.\n]{0,80}'
    r'(?:[a-z][a-z0-9]*_[a-z0-9_]+|`[^`\n]+`|\d|\(|/|\.[a-z]{1,4}\b)', re.I)


class Finding:
    __slots__ = ('path', 'line', 'col', 'rule', 'term', 'use', 'why', 'text',
                 'suppressed', 'root')

    def __init__(self, path, line, col, rule, term, use, why, text,
                 suppressed=None, root=None):
        self.path, self.line, self.col = path, line, col
        self.rule, self.term, self.use, self.why = rule, term, use, why
        self.text, self.suppressed = text, suppressed
        self.root = root      # the repo this file lives in; its baseline governs it

    @property
    def fingerprint(self) -> str:
        # Deliberately excludes the line NUMBER so that inserting a paragraph
        # above a baselined finding does not resurrect it. Includes a normalized
        # slice of the line so that editing the sentence DOES resurrect it.
        norm = re.sub(r'\s+', ' ', self.text).strip().lower()[:120]
        raw = f'{self.path}|{self.rule}|{self.term}|{norm}'
        return hashlib.sha256(raw.encode()).hexdigest()[:16]

    def as_dict(self):
        return dict(file=self.path, line=self.line, col=self.col, rule=self.rule,
                    term=self.term, use=self.use, why=self.why,
                    text=self.text.strip()[:200], fingerprint=self.fingerprint,
                    suppressed=self.suppressed)


def resolve_dict(paths=()):
    """(path, label) of the dictionary in force: env, repo-local, else the starter."""
    env = os.environ.get('BENDIT_VOCAB')
    if env:
        return Path(env), '$BENDIT_VOCAB'
    anchor = Path(paths[0]) if paths else Path.cwd()
    if anchor.is_file():
        anchor = anchor.parent
    local = repo_root(anchor) / LOCAL_DICT
    if local.is_file():
        return local, 'repo-local'
    return STARTER, 'starter'


def load_dict(p: Path) -> dict:
    try:
        d = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f'controlled-vocabulary: cannot read {p}: {e}', file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(d, dict):
        print(f'controlled-vocabulary: cannot read {p}: top level must be an object',
              file=sys.stderr)
        raise SystemExit(1)
    return d


def scan_text(text: str, rel: str, voc: dict, strict: bool = False,
              klass: str = 'instruction') -> list[Finding]:
    src_lines = text.splitlines()
    red = redact(text)
    red_lines = red.splitlines()
    starts, acc = [], 0
    for ln in text.splitlines(keepends=True):
        starts.append(acc)
        acc += len(ln)

    def locate(pos):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1, pos - starts[lo] + 1

    def suppressed_at(line_no):
        return suppression(src_lines, line_no)

    active = set(RULES_FOR.get(klass, ('substitute', 'slop')))
    if strict:
        active |= {'obligation', 'evidence'}

    found: list[Finding] = []

    def add(pos, rule, term, use, why):
        line, col = locate(pos)
        raw = src_lines[line - 1] if line - 1 < len(src_lines) else ''
        found.append(Finding(rel, line, col, rule, term, use, why, raw,
                             suppressed_at(line)))

    # R1 — substitute: exact, one-for-one, no judgment
    for term, spec in (voc.get('substitute', {}) if 'substitute' in active else {}).items():
        if term.startswith('_'):
            continue
        for m in re.finditer(_word_rx(term), red, re.I):
            add(m.start(), 'substitute', term, spec['use'], spec['why'])

    # R3 — obligation: only when the modal is addressed to the agent, and not
    # inside a conditional ("if you can") where it is a real condition.
    # `[ \t]+` not `\s+`: with `\s+` the pattern bound across a newline, so
    # '## The rule' + '\nState which rung' matched as one phrase. Caught by
    # --self-test case `newline must not bind a modal to its subject`.
    AGENT = r'(?:agents?|you|claude|the model|the assistant|the agent)'
    for term, spec in (voc.get('obligation', {}) if 'obligation' in active else {}).items():
        if term.startswith('_'):
            continue
        if term in ('try to', 'where possible', 'if possible', 'as appropriate'):
            rx = re.compile(_word_rx(term), re.I)
        else:
            rx = re.compile(rf'(?<![\w-]){AGENT}[ \t]+{_word_rx(term)}', re.I)
        for m in rx.finditer(red):
            head = red[max(0, m.start() - 24):m.start()].lower()
            # Markdown emphasis must not break the guard: `*will*` is `will`.
            head = re.sub(r'[*_~`]+', '', head)
            if re.search(r'\b(if|unless|whether|when|that)\s*$', head):
                continue              # a condition, not a weakened instruction
            if re.search(r'\b(do not|don[\u2019\']t|never|will|would|may|might|can)\s*$', head):
                continue              # describing behaviour, or already a prohibition
            add(m.start(), 'obligation', term, spec['use'], spec['why'])

    # R4 — evidence: a claim of completion that names no observation.
    evidence_lines: set[int] = set()
    for term, spec in (voc.get('evidence', {}) if 'evidence' in active else {}).items():
        if term.startswith('_'):
            continue
        for m in re.finditer(_word_rx(term), red, re.I):
            line, _ = locate(m.start())
            if line in evidence_lines:
                continue          # one finding per line; the rewrite is the same one
            if NEGATED.search(red[max(0, m.start() - 40):m.start()]):
                continue          # "not verified" is the honest form, not a defect
            if QUALIFIED.match(red[m.end():m.end() + 100]):
                continue          # the claim names its own observation
            window = '\n'.join(src_lines[max(0, line - 4):line + 3])
            if OBSERVATION.search(window):
                continue          # an observation sits beside the claim; that is the ask
            evidence_lines.add(line)
            add(m.start(), 'evidence', term, spec['use'], spec['why'])

    # R5 -- slop: plain writing. Each entry is a regex; the reported term is the
    # text that matched. Code spans, fences and tables were blanked above. One
    # finding per position, so two entries naming the same word report it once.
    seen_slop: set[int] = set()
    for label, spec in (voc.get('slop', {}) if 'slop' in active else {}).items():
        if label.startswith('_') or not isinstance(spec, dict):
            continue
        pat = spec.get('pattern') or re.escape(label)
        if not spec.get('raw'):
            pat = r'(?<![\w-])(?:' + pat + r')(?![\w-])'
        for m in re.finditer(pat, red, re.I | re.M):
            if m.start() in seen_slop:
                continue
            seen_slop.add(m.start())
            add(m.start(), 'slop', ' '.join(m.group(0).split()),
                spec.get('use', ''), spec.get('why', label))

    found.sort(key=lambda f: (f.line, f.col))
    return found


# ------------------------------------------------------------------- corpus
def iter_docs(paths):
    for raw in paths:
        p = Path(raw)
        if p.is_file() and p.suffix in DOC_SUFFIXES:
            yield p
        elif p.is_dir():
            # VENDOR is matched against the path INSIDE the repo. Matched against
            # the absolute path, a repo checked out under .../results/ scanned
            # nothing and reported "0 new 0 total" -- a silent pass.
            root = repo_root(p)
            for q in sorted(p.rglob('*')):
                if (q.suffix in DOC_SUFFIXES and q.is_file()
                        and not any(part in VENDOR for part in rel_parts(q, root))):
                    yield q


def rel_parts(q: Path, root: Path) -> tuple:
    try:
        return q.resolve().relative_to(root).parts
    except ValueError:
        return q.parts


def repo_root(start: Path) -> Path:
    cur = start.resolve()
    for d in [cur, *cur.parents]:
        if (d / '.git').exists():
            return d
    return cur


class Baselines:
    """One baseline per repo, resolved from the file's own repo root.

    The first version loaded ONE baseline for the whole invocation, from the
    first path argument. For --check and the single-repo command that is right.
    For a sweep across several repos it silently found nothing and reported every
    baselined finding as new -- a check reporting the wrong answer confidently,
    which is the failure mode this plugin exists to prevent.
    """

    def __init__(self):
        self._cache: dict = {}

    def covers(self, f: 'Finding') -> bool:
        root = f.root or Path.cwd()
        if root not in self._cache:
            self._cache[root] = load_baseline(root / BASELINE_NAME)
        return f.fingerprint in self._cache[root]

    def __contains__(self, fp):            # back-compat for `fp in base`
        return any(fp in s for s in self._cache.values())

    def __len__(self):
        return sum(len(s) for s in self._cache.values())


def load_baseline(p: Path) -> set:
    if not p.is_file():
        return set()
    return {ln.split('  ')[0].strip() for ln in p.read_text().splitlines()
            if ln.strip() and not ln.startswith('#')}


def collect(paths, voc, strict):
    out = []
    for f in iter_docs(paths):
        try:
            text = f.read_text(errors='replace')
        except OSError:
            continue
        root = repo_root(f.parent)
        try:
            rel = str(f.resolve().relative_to(root))
        except ValueError:
            rel = str(f)
        for fd in scan_text(text, rel, voc, strict, doc_class(Path(rel))):
            fd.root = root
            out.append(fd)
    return out


# ------------------------------------------------------------------ output
RULE_BLURB = {
    'substitute': 'Register inflation with an exact approved equivalent. Safe to auto-fix with --fix. Runs on every document.',
    'obligation': 'A requirement addressed to the agent, stated as advice — so the agent treats it as advice. Instruction files only.',
    'evidence':   'A claim that work is done, with no observation within three lines: no rung, no command, no exit code, no file:line, no artifact. Report files only.',
    'slop':       'Phrasing that reads as machine-written (adapted from noodle\'s unslop list). Advisory: it never blocks and --fix never edits it. Runs on every document.',
}
RULE_ORDER = ('substitute', 'obligation', 'evidence', 'slop')


def report(findings, baseline, show_all, dict_note=''):
    new = [f for f in findings if not baseline.covers(f) and not f.suppressed]
    blocking = [f for f in new if f.rule not in ADVISORY]
    known = [f for f in findings if baseline.covers(f)]
    supp = [f for f in findings if f.suppressed]
    shown = findings if show_all else new

    by_rule = {}
    for f in shown:
        by_rule.setdefault(f.rule, []).append(f)

    if dict_note:
        print(f"{C['dim']}{dict_note}{C['off']}")
    if not shown:
        print(f"{C['cyn']}one word, one meaning{C['off']}  —  nothing new.")
    for rule in RULE_ORDER:
        hits = by_rule.get(rule)
        if not hits:
            continue
        print(f"\n{C['bold']}{rule.upper()}{C['off']}  {C['dim']}({len(hits)}) "
              f"{RULE_BLURB[rule]}{C['off']}")
        by_file = {}
        for f in hits:
            by_file.setdefault(f.path, []).append(f)
        for path, fs in by_file.items():
            print(f"  {C['cyn']}{path}{C['off']}")
            for f in fs:
                mark = f"{C['dim']}[baselined]{C['off']} " if baseline.covers(f) else ''
                print(f"    {mark}{path}:{f.line}:{f.col}  "
                      f"{C['yel']}{f.term}{C['off']} → {C['bold']}{f.use}{C['off']}")
                print(f"        {C['dim']}{f.why}{C['off']}")
                snippet = re.sub(r'\s+', ' ', f.text).strip()
                if len(snippet) > 116:
                    snippet = snippet[:113] + '...'
                print(f"        {C['dim']}| {snippet}{C['off']}")

    print(f"\n{C['bold']}{len(new)} new{C['off']}   "
          f"{len(known)} baselined   {len(supp)} suppressed   "
          f"{len(findings)} total")
    if len(blocking) != len(new):
        print(f"  {len(new) - len(blocking)} of the new are advisory (slop) and never block.")
    for f in supp:
        print(f"  {C['dim']}suppressed {f.path}:{f.line} {f.term} — {f.suppressed}{C['off']}")
    return len(blocking)


def to_html(findings, baseline, out: Path, root_label: str):
    rows = []
    for f in findings:
        state = ('suppressed' if f.suppressed
                 else 'baselined' if baseline.covers(f) else 'new')
        rows.append(dict(f.as_dict(), state=state))
    counts = {r: sum(1 for x in rows if x['rule'] == r) for r in RULE_BLURB}
    new_n = sum(1 for x in rows if x['state'] == 'new')
    payload = json.dumps(dict(rows=rows, counts=counts, blurb=RULE_BLURB,
                              root=root_label, new=new_n), indent=1)
    out.write_text(HTML.replace('/*DATA*/', payload))
    return out


HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Controlled Vocabulary</title>
<style>
:root{--bg:#fbfbfa;--fg:#1a1a18;--dim:#6b6b66;--line:#e3e3df;--card:#fff;
 --new:#b4341f;--base:#8a8a84;--supp:#2f6f4f;--accent:#1f4f8a;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#121211;--fg:#e8e8e4;
 --dim:#9a9a93;--line:#2b2b28;--card:#1a1a18;--new:#e8795f;--base:#7e7e78;--supp:#6fc79a;--accent:#7fb0e8}}
:root[data-theme=dark]{--bg:#121211;--fg:#e8e8e4;--dim:#9a9a93;--line:#2b2b28;--card:#1a1a18;
 --new:#e8795f;--base:#7e7e78;--supp:#6fc79a;--accent:#7fb0e8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
 font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",sans-serif;padding:0 16px 80px}
.wrap{max-width:1000px;margin:0 auto}
header{padding:40px 0 20px;border-bottom:1px solid var(--line)}
h1{font-size:26px;margin:0 0 4px;letter-spacing:-.02em}
.sub{color:var(--dim);font-size:13.5px}
.tiles{display:flex;flex-wrap:wrap;gap:10px;margin:22px 0 8px}
.tile{flex:1 1 150px;background:var(--card);border:1px solid var(--line);border-radius:9px;padding:12px 14px}
.tile b{display:block;font-size:24px;font-weight:600;letter-spacing:-.02em}
.tile span{color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:.07em}
.bar{margin:16px 0 0;display:flex;gap:8px;flex-wrap:wrap}
button{font:inherit;font-size:13px;padding:6px 12px;border-radius:7px;cursor:pointer;
 border:1px solid var(--line);background:var(--card);color:var(--fg)}
button[aria-pressed=true]{background:var(--fg);color:var(--bg);border-color:var(--fg)}
section{margin:30px 0 0}
h2{font-size:12.5px;text-transform:uppercase;letter-spacing:.09em;color:var(--dim);
 margin:0 0 4px;font-weight:600}
.blurb{color:var(--dim);font-size:13px;margin:0 0 12px;max-width:68ch}
.f{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--base);
 border-radius:7px;padding:11px 14px;margin:0 0 8px}
.f.new{border-left-color:var(--new)}.f.suppressed{border-left-color:var(--supp)}
.loc{font-family:var(--mono);font-size:12px;color:var(--accent);word-break:break-all}
.swap{margin:5px 0 3px;font-size:14.5px}
.swap .from{color:var(--new);text-decoration:line-through;text-decoration-thickness:1px}
.swap .to{font-weight:600}
.why{color:var(--dim);font-size:13px;max-width:72ch}
.snip{font-family:var(--mono);font-size:11.5px;color:var(--dim);margin-top:6px;
 padding:6px 9px;background:var(--bg);border-radius:5px;overflow-x:auto;white-space:pre-wrap}
.tag{font-size:10.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--dim);
 border:1px solid var(--line);border-radius:4px;padding:1px 5px;margin-left:6px}
.empty{color:var(--dim);padding:28px 0;text-align:center}
footer{margin-top:50px;padding-top:16px;border-top:1px solid var(--line);color:var(--dim);font-size:12.5px}
</style></head><body><div class="wrap">
<header>
 <h1>One word, one meaning</h1>
 <div class="sub" id="sub"></div>
 <div class="tiles" id="tiles"></div>
 <div class="bar">
  <button id="b-new" aria-pressed="true">New only</button>
  <button id="b-all" aria-pressed="false">Everything</button>
  <button id="b-theme" aria-pressed="false">Theme</button>
 </div>
</header>
<main id="main"></main>
<footer>ASD-STE100 Section 1, applied to this repo. Dictionary: <code>.claude/vocabulary.json</code>, else the starter.
Suppress one finding with <code>&lt;!-- vocab-ok: reason --&gt;</code> on the line or the line above.</footer>
</div><script>
const D = /*DATA*/;
const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
let onlyNew = true;
document.getElementById('sub').textContent =
  `${D.rows.length} findings across ${new Set(D.rows.map(r=>r.file)).size} files in ${D.root}`;
const tiles = [['new', D.new, 'new'], ...Object.entries(D.counts).map(([k,v])=>[k,v,k])];
document.getElementById('tiles').innerHTML = tiles
  .map(([l,v]) => `<div class="tile"><b>${v}</b><span>${esc(l)}</span></div>`).join('');
function render(){
  const rows = D.rows.filter(r => onlyNew ? r.state === 'new' : true);
  const m = document.getElementById('main');
  if(!rows.length){ m.innerHTML = '<p class="empty">Nothing to show.</p>'; return; }
  const order = ['substitute','obligation','evidence','slop'];
  m.innerHTML = order.map(rule => {
    const hits = rows.filter(r => r.rule === rule);
    if(!hits.length) return '';
    return `<section><h2>${rule} · ${hits.length}</h2>
      <p class="blurb">${esc(D.blurb[rule]||'')}</p>` + hits.map(r => `
      <div class="f ${r.state}">
        <div class="loc">${esc(r.file)}:${r.line}:${r.col}
          ${r.state!=='new'?`<span class="tag">${r.state}</span>`:''}</div>
        <div class="swap"><span class="from">${esc(r.term)}</span> &rarr;
          <span class="to">${esc(r.use)}</span></div>
        <div class="why">${esc(r.why)}</div>
        ${r.text?`<div class="snip">${esc(r.text)}</div>`:''}
        ${r.suppressed?`<div class="why">suppressed: ${esc(r.suppressed)}</div>`:''}
      </div>`).join('') + '</section>';
  }).join('');
}
function setMode(n){ onlyNew=n;
  document.getElementById('b-new').setAttribute('aria-pressed', n);
  document.getElementById('b-all').setAttribute('aria-pressed', !n); render(); }
document.getElementById('b-new').onclick = ()=>setMode(true);
document.getElementById('b-all').onclick = ()=>setMode(false);
document.getElementById('b-theme').onclick = ()=>{
  const d = document.documentElement;
  const cur = d.getAttribute('data-theme')
    || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark':'light');
  d.setAttribute('data-theme', cur==='dark'?'light':'dark');
};
render();
</script></body></html>
"""


def do_fix(paths, voc):
    changed = 0
    for f in iter_docs(paths):
        text = f.read_text(errors='replace')
        red = redact(text)
        src_lines = text.splitlines()
        edits = []
        for term, spec in voc.get('substitute', {}).items():
            if term.startswith('_'):
                continue
            for m in re.finditer(_word_rx(term), red, re.I):
                # A `vocab-ok` line is an exception someone wrote down on
                # purpose; --fix rewriting it would erase the very form the
                # comment says is right.
                if suppression(src_lines, text.count('\n', 0, m.start()) + 1):
                    continue
                edits.append((m.start(), m.end(), spec['use']))
        if not edits:
            continue
        edits.sort(reverse=True)
        new = text
        for s, e, rep in edits:
            orig = text[s:e]
            # keep the original capitalisation of the first letter
            if orig[:1].isupper():
                rep = rep[:1].upper() + rep[1:]
            new = new[:s] + rep + new[e:]
        f.write_text(new)
        changed += len(edits)
        print(f'  fixed {len(edits):>3}  {f}')
    print(f'{changed} substitution(s) applied. Only the `substitute` rule is auto-fixed; '
          f'`obligation` and `evidence` need a human.')
    return 0


def print_dict(voc):
    for rule in RULE_ORDER:
        block = voc.get(rule, {})
        print(f"\n{C['bold']}{rule.upper()}{C['off']}")
        print(f"  {C['dim']}{block.get('_why','')}{C['off']}\n")
        for term, spec in block.items():
            if term.startswith('_'):
                continue
            use = spec.get('use') or spec.get('verb_use') or spec.get('noun_use') or ''
            pos = f" {C['dim']}[keep as {spec['pos']}]{C['off']}" if 'pos' in spec else ''
            print(f"  {C['yel']}{term:<22}{C['off']} → {C['bold']}{use}{C['off']}{pos}")
            print(f"  {'':22}   {C['dim']}{spec['why']}{C['off']}")


# --------------------------------------------------------------- self-test
# Make every rule fail on purpose before trusting a pass.
# Each case is a (text, rule, must_fire) triple with a POSITIVE control beside
# every negative, so a scanner that returned [] for everything cannot score green.
SELF_CASES = [
    # (text, rule, must_fire, document class)
    ('Utilize the helper.',                      'substitute', True,  'instruction'),
    ('The file serves as the baseline.',        'slop',       True,  'report'),
    ('The file is the baseline.',                'slop',       False, 'report'),
    ('It works \u2014 mostly.',                   'slop',       True,  'other'),
    ('Use `a \u2014 b` as the separator.',        'slop',       False, 'other'),
    ('Use the helper.',                          'substitute', False, 'instruction'),
    ('Run it prior to the migration.',           'substitute', True,  'instruction'),
    ('Run it before the migration.',             'substitute', False, 'instruction'),
    ('`utilize` appears inside code.',           'substitute', False, 'instruction'),
    ('```\nutilize\n```\nClean prose.',         'substitute', False, 'instruction'),

    ('Agents should treat it as truth.',         'obligation', True,  'instruction'),
    ('A principal that should be denied.',       'obligation', False, 'instruction'),
    ('Make it unreachable if you can.',          'obligation', False, 'instruction'),
    ('Try to keep it short.',                    'obligation', True,  'instruction'),
    # routing: an obligation in a REPORT is not this rule's business
    ('Agents should treat it as truth.',         'obligation', False, 'report'),

    ('I verified the migration.',                'evidence',   True,  'report'),
    ('Verified: `pnpm test` exited 0.',          'evidence',   False, 'report'),
    ('Verified the redirect [rung 4].',          'evidence',   False, 'report'),
    ('It works.',                                'evidence',   True,  'report'),
    ('All tests pass.',                          'evidence',   True,  'report'),
    ('All tests pass: 128 passed, 0 failed.',    'evidence',   False, 'report'),
    # routing: an instruction file may discuss these words freely
    ('I verified the migration.',                'evidence',   False, 'instruction'),

    # REGRESSION: honest negative reporting must never be punished
    ('**Not verified:** source maps, dSYM upload.', 'evidence', False, 'report'),
    ('Demo account with test data not confirmed.',  'evidence', False, 'report'),
    ('The seed was never verified.',                'evidence', False, 'report'),
    ('We were unable to verify the seed.',          'evidence', False, 'report'),
    # REGRESSION: `\bun` matched "unit" and `still` is not a negation, so
    # these two unevidenced claims were silently waved through.
    ('Ran unit tests and verified the fix.',        'evidence', True,  'report'),
    ('We still verified it end to end.',            'evidence', True,  'report'),
    # REGRESSION: a hyphenated compound is a different word
    ('The least-tested path in the subsystem.',     'evidence', False, 'report'),
    ('I tested the path.',                          'evidence', True,  'report'),
    # REGRESSION: describing behaviour is not a weakened instruction
    ('Do not try to click it by role.',             'obligation', False, 'instruction'),
    ('The picker will try to decrypt it.',          'obligation', False, 'instruction'),
    ('The picker *will* try to decrypt it.',        'obligation', False, 'instruction'),
    # REGRESSION: a claim that names its own observation is the GOOD form
    ('FALSE. VERIFIED via pg_indexes: four exist.', 'evidence', False, 'report'),
    ('VERIFIED: max(id)=13, sequence untouched.',   'evidence', False, 'report'),
    ('CONFIRMED by controller on 85957bfc.',        'evidence', False, 'report'),
    ('Verified.',                                   'evidence', True,  'report'),
]


def self_test() -> int:
    voc = load_dict(STARTER)      # the cases are written against the starter terms
    fails = []
    for text, rule, must, klass in SELF_CASES:
        got = [f for f in scan_text(text, 't.md', voc, klass=klass)
               if f.rule == rule]
        if bool(got) != must:
            fails.append((f'[{klass}] {text}', rule, must, [f.term for f in got]))
    # A scanner that fires on everything, or nothing, must not pass the suite.
    pos = sum(1 for _, _, m, _k in SELF_CASES if m)
    neg = len(SELF_CASES) - pos
    print(f'{len(SELF_CASES)} cases: {pos} must fire, {neg} must stay silent '
          f'(a scanner that always fires, or never fires, fails both halves)')
    # REGRESSION: a modal must not bind to a subject across a line break.
    # '## The rule' + newline + 'State which rung' once matched as one phrase.
    nl = scan_text('## The rule\n\nYou should not see this as one phrase.\n',
                   't.md', voc, klass='instruction')
    if len([f for f in nl if f.line == 1]) != 0:
        fails.append(('newline must not bind a modal to its subject', 'regex',
                      False, [f.term for f in nl if f.line == 1]))

    # line numbers survive redaction
    txt = '```\nx\n```\n\nUtilize it.\n'
    ln = [f.line for f in scan_text(txt, 't.md', voc) if f.rule == 'substitute']
    if ln != [5]:
        fails.append(('line number after a code fence', 'redact', 5, ln))
    # suppression works, and only with a reason
    s1 = scan_text('Utilize it. <!-- vocab-ok: quoting the bad form -->', 't.md', voc)
    if not (s1 and s1[0].suppressed):
        fails.append(('suppression comment', 'suppress', True, []))
    s2 = scan_text('Utilize it. <!-- vocab-ok: -->', 't.md', voc)
    if s2 and s2[0].suppressed:
        fails.append(('empty suppression reason must NOT suppress', 'suppress', False, []))
    # fingerprint is stable across a line move, unstable across an edit
    a = scan_text('Utilize it here.', 'x.md', voc)[0].fingerprint
    b = scan_text('\n\n\nUtilize it here.', 'x.md', voc)[0].fingerprint
    c = scan_text('Utilize it there.', 'x.md', voc)[0].fingerprint
    if a != b:
        fails.append(('fingerprint must survive a line move', 'baseline', True, [a, b]))
    if a == c:
        fails.append(('fingerprint must change when the sentence changes', 'baseline', False, [a, c]))

    for text, rule, must, got in fails:
        print(f"  {C['red']}FAIL{C['off']} [{rule}] expected fire={must} got={got}  «{text}»")
    if fails:
        print(f"\n{C['red']}{len(fails)} self-test failure(s){C['off']}")
        return 1
    print(f"{C['cyn']}all self-tests pass{C['off']} — every rule fired on its positive "
          f"case and stayed silent on its negative control")
    return 0


# -------------------------------------------------------------------- main
def main(argv) -> int:
    args = [a for a in argv if not a.startswith('--')]
    flags = {a for a in argv if a.startswith('--')}

    if '--self-test' in flags:
        return self_test()

    # /bendit:vocabulary pre-approves the read forms (`--report *` and the like), so
    # a read flag must never carry a write: `--report --init .` would
    # otherwise run --init with no question asked.
    reads = sorted(flags & {'--report', '--dict', '--check', '--json'})
    writes = sorted(flags & {'--init', '--fix', '--baseline', '--html'})
    if reads and writes:
        print(f'controlled-vocabulary: {" ".join(reads)} is read-only and cannot be combined '
              f'with {" ".join(writes)}; run the write on its own.', file=sys.stderr)
        return 2

    strict = '--strict' in flags
    paths = args or ['.']

    if '--init' in flags:
        anchor = Path(paths[0])
        root = repo_root(anchor.parent if anchor.is_file() else anchor)
        dest = root / LOCAL_DICT
        if dest.exists():
            print(f'controlled-vocabulary: {dest} already exists; not overwriting it. '
                  f'Edit it, or delete it first.', file=sys.stderr)
            return 1
        if not STARTER.is_file():
            print(f'controlled-vocabulary: the starter {STARTER} is missing', file=sys.stderr)
            return 1
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(STARTER.read_text())
        print(f'wrote {dest} (a copy of the starter). Edit it to grow your vocabulary.')
        return 0

    # --check: one file, exit 2, reasons on stderr. For a manual run or CI --
    # hooks.json does NOT wire it (see NO HOOK IS WIRED above). With no file
    # argument it reads a hook-shaped payload (tool_input.file_path) on stdin,
    # so a person can wire it as a PostToolUse hook unchanged. Taking the path
    # only from argv would make such a hook check the cwd and pass every time.
    if '--check' in flags and not args:
        try:
            payload = json.load(sys.stdin)
        except Exception:
            return 0
        ti = payload.get('tool_input') or {}
        got = ti.get('file_path') or ti.get('path') or ''
        if not got:
            return 0
        paths = [got]

    dict_path, dict_label = resolve_dict(paths)
    voc = load_dict(dict_path)

    if '--dict' in flags:
        print(f"{C['dim']}dictionary: {dict_path} ({dict_label}){C['off']}")
        print_dict(voc)
        return 0

    if '--check' in flags:
        target = Path(paths[0])
        if target.suffix not in DOC_SUFFIXES or not target.is_file():
            return 0
        base = Baselines()
        fs = [f for f in collect([target], voc, strict)
              if not base.covers(f) and not f.suppressed
              and f.rule not in ADVISORY]
        if not fs:
            return 0
        head = (f'[bendit] controlled vocabulary — {len(fs)} new in {target.name}:')
        body = '\n'.join(
            f'  {f.path}:{f.line}  {f.term} → {f.use}\n      {f.why}' for f in fs[:6])
        tail = ('\n  ...' if len(fs) > 6 else '')
        print(f'{head}\n{body}{tail}\n\n'
              f'One word, one meaning (ASD-STE100 §1). Rewrite, or record the exception '
              f'inline:\n  <!-- vocab-ok: why this one is right -->',
              file=sys.stderr)
        return 2

    findings = collect(paths, voc, strict)

    if '--baseline' in flags:
        # Group by the repo each finding lives in. A sweep across several repos
        # must write one baseline per repo, not one file at the first repo
        # holding every other repo's findings.
        #
        # MERGE, not overwrite: only entries under the scanned paths are
        # replaced. `--baseline docs` once rewrote the whole file with docs/
        # alone, and the next full run reported the rest of the repo as new.
        by_root: dict = {}
        for f in findings:
            by_root.setdefault(f.root or Path.cwd(), set()).add(
                f'{f.fingerprint}  {f.path}:{f.rule}:{f.term}')
        scopes: dict = {}
        for raw in paths:
            anchor = Path(raw).resolve()
            root = repo_root(anchor.parent if anchor.is_file() else anchor)
            try:
                rel = anchor.relative_to(root).as_posix()
            except ValueError:
                continue
            scopes.setdefault(root, []).append(
                ('', False) if rel == '.' else (rel, anchor.is_file()))
            by_root.setdefault(root, set())

        def in_scope(entry_path, root):
            for rel, is_file in scopes.get(root, [('', False)]):
                if rel == '' or entry_path == rel or (
                        not is_file and entry_path.startswith(rel + '/')):
                    return True
            return False

        wrote = False
        for root, entries in sorted(by_root.items()):
            bp = root / BASELINE_NAME
            kept = set()
            if bp.is_file():
                for ln in bp.read_text().splitlines():
                    if not ln.strip() or ln.startswith('#'):
                        continue
                    _, _, where = ln.partition('  ')
                    entry_path = where.rsplit(':', 2)[0] if where.count(':') >= 2 else ''
                    if entry_path and not in_scope(entry_path, root):
                        kept.add(ln.strip())
            merged = kept | entries
            if not merged:
                # A repo that is now clean should not keep an empty baseline.
                if bp.is_file():
                    bp.unlink()
                    print(f'removed empty baseline → {bp}')
                continue
            bp.parent.mkdir(parents=True, exist_ok=True)
            bp.write_text('# bendit controlled-vocabulary baseline\n'
                          '# Findings accepted as-is. Delete a line to make it fire again.\n'
                          + '\n'.join(sorted(merged)) + '\n')
            wrote = True
            print(f'baselined {len(entries)} finding(s), kept {len(kept)} from '
                  f'outside the scanned paths → {bp}')
        if not wrote and not findings:
            print('nothing to baseline; no file written')
        return 0

    base = Baselines()

    if '--json' in flags:
        print(json.dumps([dict(f.as_dict(),
                               state=('suppressed' if f.suppressed
                                      else 'baselined' if base.covers(f) else 'new'))
                          for f in findings], indent=2))
        return 0

    if '--fix' in flags:
        return do_fix(paths, voc)

    html_out = None
    for i, a in enumerate(argv):
        if a == '--html' and i + 1 < len(argv):
            html_out = Path(argv[i + 1])
            if str(html_out) in paths:
                paths.remove(str(html_out))
    if html_out is not None:
        findings = collect(paths or ['.'], voc, strict)
        to_html(findings, base, html_out, str(Path(paths[0] if paths else '.').resolve().name))
        print(f'wrote {html_out}  ({len(findings)} findings, '
              f'{sum(1 for f in findings if not base.covers(f) and not f.suppressed)} new)')
        return 0

    note = ''
    if dict_label == 'starter':
        note = (f'dictionary: the starter dictionary ({dict_path}). '
                f'--init copies it to {LOCAL_DICT} so you can edit it.')
    elif dict_label == '$BENDIT_VOCAB':
        note = f'dictionary: {dict_path} ($BENDIT_VOCAB)'
    new = report(findings, base, show_all='--all' in flags, dict_note=note)
    if '--report' in flags or not flags:
        return 0
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
