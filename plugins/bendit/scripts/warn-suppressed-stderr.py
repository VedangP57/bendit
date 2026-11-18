#!/usr/bin/env python3
"""Warn when a command hid its errors and then returned nothing.

THE MISTAKE THIS CATCHES. `cmd 2>/dev/null` that prints nothing looks exactly
like `cmd` that ran fine and found nothing. They mean opposite things, and an
agent will read the first as the second:

    /opt/tool/bin/find . -name 'verify-*' 2>/dev/null  -> empty, read as "none exist"
    ls -1 .cursor/rules/ 2>/dev/null                   -> empty, read as "it is empty"

when the real result was `no such file or directory` -- a binary that is not
at that path, a directory that does not exist -- swallowed by the redirect.
Often only a second check happening to disagree catches it.

WHY THIS WARNS AND NEVER BLOCKS. Suppressing stderr is legitimate constantly:
`git check-ignore`, `docker ps` on a machine without docker, probing for an
optional tool. A gate refusing it would fire on ordinary commands and be
uninstalled within a day, which is worse than no gate. The danger is not the
redirect, it is reading EMPTY OUTPUT as an answer -- and that is detectable
exactly, after the fact, when the output really is empty. So this is a
PostToolUse note at the one moment the mistake is available to make.

It is deliberately not clever about whether the output was going to be parsed.
A warning costs one line; a wrong conclusion can cost an hour.

A bare `0` counts as empty: `find x 2>/dev/null | wc -l` prints 0
when find failed, and a count of nothing is the same non-answer.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_text import code_mask  # noqa: E402

# Shapes that send stderr nowhere. `>/dev/null` alone is NOT here: that hides
# stdout, which is visible in the result anyway, and says nothing about errors.
# Nor is `2>&1 >/dev/null`, which sends stderr to where stdout WAS.
SUPPRESSED = re.compile(
    r'(?:(?<![\w$])2|&)\s*>>?\s*(?:/dev/null|&\s*-)'  # 2>/dev/null 2>>… 2>&- &>… &>>…
    r'|>\s*&\s*/dev/null'                         # >& /dev/null (both streams)
    r'|>\s*/dev/null\s+2\s*>\s*&\s*1'              # >/dev/null 2>&1, 1>/dev/null 2>&1
)

ZERO = re.compile(r'0+')


def suppresses_stderr(command: str) -> bool:
    """A suppressing redirect in text this shell runs: not inside quotes, a
    comment, or a quoted heredoc body headed for a file. Same lexer the other
    guards use, so they cannot drift about what counts as executable text."""
    mask = code_mask(command)
    return any(mask[m.start()] for m in SUPPRESSED.finditer(command))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    tool_input = payload.get('tool_input')
    if not isinstance(tool_input, dict):
        return 0   # a shape this hook does not understand: ignored, like junk
    command = tool_input.get('command')
    if not isinstance(command, str) or not command.strip():
        return 0
    if not suppresses_stderr(command):
        return 0

    resp = payload.get('tool_response')
    if not isinstance(resp, dict):
        return 0
    # The tool itself says when a command is not expected to print anything.
    if resp.get('noOutputExpected') is True:
        return 0
    if resp.get('interrupted') is True:
        return 0
    stdout = resp.get('stdout')
    if not isinstance(stdout, str):
        return 0
    if stdout.strip() == '':
        returned, result = 'returned nothing', 'An empty result'
    elif ZERO.fullmatch(stdout.strip()):
        returned, result = 'returned only a count of 0', 'A 0'
    else:
        return 0

    print(
        f'[bendit] that command hid its errors and {returned}, so it has '
        'told you nothing.\n'
        f'{result} here means EITHER "ran fine, found none" OR "failed, '
        'and you cannot see why" — the two look identical and mean opposite '
        'things.\n'
        'Before using this as an answer, re-run it without the redirect:\n'
        '  drop 2>/dev/null and read stderr\n'
        'A binary at a path where it does not exist, or a directory that is '
        'not there, fails silently this way.',
        file=sys.stderr)
    return 2


def run() -> int:
    # Advisory, so it cannot block -- but a crash is still SAID, never a
    # silent exit 1 that reads as "nothing to warn about".
    try:
        return main()
    except Exception as exc:
        print(f'[bendit] the suppressed-stderr check itself failed '
              f'({type(exc).__name__}: {exc}); treat empty output from that '
              f'command as unverified.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(run())
