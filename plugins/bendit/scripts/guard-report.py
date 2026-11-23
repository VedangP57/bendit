#!/usr/bin/env python3
"""Which guard rules fired in the last N days, and which never did.

    python3 guard-report.py [--days N] [--root DIR]

Reads <root>/.claude/.bendit-state/fires.jsonl, the log every PreToolUse guard
appends to when it refuses (fire_log.py). The root is the git toplevel of
--root, else of CLAUDE_PROJECT_DIR, else of the current folder (the folder
itself when it is not in a git repo).

Prints a table of guard, rule, count and the most recent example for the
window, then one line: "never fired in N days: <guard>/<rule>, ...".

THE EXAMPLE is the preview of the newest line for that rule in the window. It
was redacted when it was written (fire_log.record), and is redacted again here
with fire_log.preview_of -- the same redact() and the same 120-character cut --
because the log may come from an older bendit or a cloned repo. Then control
characters are made safe. bendit's own self-tests (prove.sh, selfcheck, the
live `bendit-probe` push) are never written to the log, so they are never
counted here.

THE RULE INVENTORY is each guard's RULES list, read by PARSING the guard's
source (ast.literal_eval), never by importing it: importing a guard runs its
module code (it edits sys.path and imports shell_text), and a guard that cannot
import would hide its rules exactly when the report matters most. The guards
are the PreToolUse scripts in hooks/hooks.json that define RULES.

Exit 0, or 2 when the log exists but cannot be read -- named, and never
reported as "0 fires", which would read as "nothing needed refusing". A line
that is not a valid record is skipped and counted, never silently dropped.
"""
import argparse
import ast
import datetime
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PLUGIN = os.path.dirname(HERE)
TS_FORMAT = '%Y-%m-%dT%H:%M:%SZ'
# C0, DEL, C1 and bidi controls: a log in a cloned repo is someone else's
# text, and none of it may reach the terminal as an escape sequence.
_CONTROL = re.compile('[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]')


def safe(text: str) -> str:
    return _CONTROL.sub('?', text)


def example(preview) -> str:
    """A log line's preview, redacted again, cut, and made safe to print."""
    if not isinstance(preview, str):
        return '(none)'
    try:
        import fire_log
        text = fire_log.preview_of(preview)
    except Exception:
        return '(preview withheld: could not redact it)'
    return safe(text) or '(none)'


def git_toplevel(start: str) -> str:
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=start,
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return start


def rules_of(path: str):
    """The literal RULES list a guard defines, or None."""
    with open(path, encoding='utf-8') as f:
        tree = ast.parse(f.read())
    for node in tree.body:
        if (isinstance(node, ast.Assign)
                and any(getattr(t, 'id', None) == 'RULES' for t in node.targets)):
            return list(ast.literal_eval(node.value))
    return None


def inventory():
    """[(guard, rule)] for every PreToolUse guard in hooks.json that has RULES."""
    with open(os.path.join(PLUGIN, 'hooks', 'hooks.json'), encoding='utf-8') as f:
        hooks = json.load(f)
    seen, out = set(), []
    for entry in hooks.get('hooks', {}).get('PreToolUse', []):
        for hook in entry.get('hooks', []):
            m = re.search(r'scripts/([\w.-]+\.py)', hook.get('command', ''))
            if not m or m.group(1) in seen:
                continue
            seen.add(m.group(1))
            rules = rules_of(os.path.join(HERE, m.group(1)))
            for rule in rules or []:
                out.append((m.group(1)[:-3], rule))
    return out


def read_log(path: str, since: datetime.datetime):
    """({(guard, rule): n}, {(guard, rule): newest raw preview}, lines
    skipped). Of two lines with the same time, the later one in the file is
    the newer. Raises OSError when the log cannot be read."""
    counts, latest, skipped = {}, {}, 0
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
                guard, rule = rec['guard'], rec['rule']
                ts = datetime.datetime.strptime(rec['ts'], TS_FORMAT).replace(
                    tzinfo=datetime.timezone.utc)
                if not (isinstance(guard, str) and isinstance(rule, str)):
                    raise ValueError('guard and rule must be text')
            except (ValueError, KeyError, TypeError):
                skipped += 1
                continue
            if ts >= since:
                guard, rule = safe(guard), safe(rule)
                counts[(guard, rule)] = counts.get((guard, rule), 0) + 1
                if (guard, rule) not in latest or ts >= latest[(guard, rule)][0]:
                    latest[(guard, rule)] = (ts, rec.get('preview'))
    return counts, {k: v[1] for k, v in latest.items()}, skipped


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog='guard-report.py',
                                 description='Which bendit guard rules fired, and which never did.')
    ap.add_argument('--days', type=int, default=30, help='the window, in days (default 30)')
    ap.add_argument('--root', help='the project (default: CLAUDE_PROJECT_DIR, else this folder)')
    args = ap.parse_args(argv)
    if args.days < 1:
        ap.error('--days must be 1 or more')
    start = args.root or os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd()
    root = git_toplevel(start)
    path = os.path.join(root, '.claude', '.bendit-state', 'fires.jsonl')

    if not os.path.lexists(path):
        print(f'no refusals recorded yet (no log at {path}).')
        print('Guards record each refusal from now on; run this again after some work.')
        return 0
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.days)
    try:
        counts, latest, skipped = read_log(path, since)
    except (OSError, UnicodeError) as exc:
        print(f'guard-report: cannot read the refusal log {path}: '
              f'{type(exc).__name__}: {exc}. Fires are UNKNOWN, not zero.', file=sys.stderr)
        return 2
    try:
        rules = inventory()
    except Exception as exc:
        rules = []
        print(f'guard-report: could not read the guards\' rule lists '
              f'({type(exc).__name__}: {exc}), so "never fired" is unknown.', file=sys.stderr)

    print(f'refusals in the last {args.days} days ({path}):')
    if counts:
        rows = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
        w0 = max(len('guard'), *(len(g) for (g, _r), _n in rows))
        w1 = max(len('rule'), *(len(r) for (_g, r), _n in rows))
        print(f'{"guard":<{w0}}  {"rule":<{w1}}  {"count":<5}  most recent')
        for (g, r), n in rows:
            print(f'{g:<{w0}}  {r:<{w1}}  {n:<5}  {example(latest.get((g, r)))}')
    else:
        print(f'none in the last {args.days} days.')
    never = [f'{g}/{r}' for g, r in rules if (g, r) not in counts]
    if rules:
        print(f'never fired in {args.days} days: {", ".join(never) if never else "(none: every rule fired)"}')
    if skipped:
        print(f'skipped {skipped} unreadable line{"s" if skipped != 1 else ""} in the log.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
