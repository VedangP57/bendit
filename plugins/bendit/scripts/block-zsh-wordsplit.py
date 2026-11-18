#!/usr/bin/env python3
"""Refuse a loop that zsh will run once while you think it runs N times.

THE BUG, measured:

    zsh   for x in $v        1 iteration      ($v = "a b c")
    bash  for x in $v        3 iterations
    zsh   for x in $(cmd)    3 iterations     -- command substitution DOES split

zsh does not word-split a bare parameter expansion. bash does. When the user's
shell is zsh, Claude Code's Bash tool runs zsh, so a loop written with bash
habits iterates ONCE over the whole string -- or zero times when the variable
is empty.

That is not a loud failure. The loop body runs on garbage or not at all, the
command exits 0, and whatever the loop was checking reports success. Agents
repeat this across sessions, each time producing a check that passed while
testing nothing. A correction needed more than once belongs in a mechanism,
not in a memory.

WHEN IT IS ACTIVE: only when $SHELL names zsh (the Bash tool uses the user's
shell, so under bash the loop is correct and the guard stays silent), and only
when the plugin option `zshGuard` is not false. Claude Code hands a plugin's
userConfig values to its command hooks as CLAUDE_PLUGIN_OPTION_<KEY> (key
upper-cased), so the option arrives as CLAUDE_PLUGIN_OPTION_ZSHGUARD.

FAILS CLOSED: a crash inside the guard refuses (exit 2) rather than exiting 1,
which Claude Code treats as a non-blocking error and runs the command anyway.

Deliberately narrow. It fires on a bare scalar in a for-list and nothing else:
not `$(...)`, which splits correctly; not a quoted `"$v"`, which is an explicit
single item; not `${a[@]}`, which is already an array.

The known false positive is a real zsh array -- `for x in $arr` is correct
there, and no static check can tell an array from a scalar. The message says
so, and says how to proceed.
"""
import json
import re
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_text import code_mask, lex, shell_c_string, unwrap  # noqa: E402

# `for NAME in $VAR` / `${VAR}` / `${VAR:-default words}` -- a bare scalar
# expansion, first in the list. Not `$(`: command substitution splits. Not
# `[@]`/`[*]`: already an array. Not `${=v}` or `${(f)v}`: zsh's own split
# forms. The braced form is captured to its closing brace, so `${v:-a b}` is
# one expression -- capturing `${v:-a` put a syntax error in the advice below.
# The expansion must END the word: in `$dir/*.ts` the scalar is only part of a
# word whose literal glob zsh does expand, so it iterates per file.
LOOP = re.compile(r'\bfor\s+\w+\s+in\s+'
                  r'(\$\w+(?![\w\[])|\$\{\w+(?:[:\-+=?#%/^,~@][^}\n]*)?\})'
                  r'(?=[\s;&|)]|$)')


def find_loop(cmd: str, depth: int = 0):
    """The first bare-scalar for-list zsh will run, or None.

    Only text zsh reads as code counts (see main), plus any string handed to
    `zsh -c` -- quoted to this shell, but zsh code all the same.
    """
    mask = code_mask(cmd, keep_for={'zsh'})
    m = next((m for m in LOOP.finditer(cmd)
              if mask[m.start()] and mask[m.start(1)]), None)
    if m or depth > 4:
        return m
    for c in lex(cmd, {'zsh'}).cmds:
        argv = unwrap(c.argv)
        if argv and argv[0] == 'zsh':
            inner = shell_c_string(argv)
            if inner is not None:
                m = find_loop(inner, depth + 1)
                if m:
                    return m
    return None


def active() -> bool:
    """zsh is the user's shell, and the zshGuard option was not turned off."""
    shell = os.path.basename(os.environ.get('SHELL', '') or '')
    if shell != 'zsh':
        return False
    opt = os.environ.get('CLAUDE_PLUGIN_OPTION_ZSHGUARD', '').strip().lower()
    return opt not in ('false', '0', 'no', 'off')


def main() -> int:
    if not active():
        return 0
    try:
        payload = json.loads(sys.stdin.buffer.read().decode('utf-8', 'surrogateescape'))
    except ValueError:
        return 0
    # Not a hook payload at all (junk stdin, a different payload shape): there
    # is no command to read, so there is nothing this guard could refuse.
    if not isinstance(payload, dict):
        return 0
    tool_input = payload.get('tool_input')
    if not isinstance(tool_input, dict):
        return 0
    cmd = tool_input.get('command')
    if not isinstance(cmd, str) or not cmd:
        return 0
    # Only text this zsh runs as code counts. NOT inside quotes or a comment:
    # `bash -c '... for x in $v ...'` is this message's own advice, and a
    # commit message may quote a loop. NOT a quoted heredoc body either,
    # unless zsh itself reads it: a loop written INSIDE `<<'EOF'` is usually a
    # bash script being written to a file, where the loop is correct.
    # shell_text decides all of this, for every guard alike.
    m = find_loop(cmd)
    if not m:
        return 0
    expr = m.group(1)
    print(
        f'[bendit] BLOCKED: `for ... in {expr}` runs ONCE under zsh, not once per word.\n'
        f'This shell is zsh, which does not word-split a bare parameter. The loop\n'
        f'body would run on the whole string, or not at all if it is empty -- and\n'
        f'the command would still exit 0, so whatever it checks would report success.\n'
        f'\n'
        f'Use one of:\n'
        f'  bash -c \'...\'                      run the loop in bash, which splits\n'
        f'  for x in $(printf %s "{expr}"); do   command substitution DOES split\n'
        f'  while IFS= read -r x; do ... done <<< "{expr}"   ONE PER LINE only\n'
        f'  for x in "${{arr[@]}}"               if it is already an array\n'
        f'\n'
        f'The read loop splits on NEWLINES, not spaces: right for `git ls-files`\n'
        f'output, wrong for a space-separated string, where it gives one iteration\n'
        f'and reproduces this bug quietly. Measured, not assumed.\n'
        f'\n'
        f'If {expr} really is a zsh array, this is a false positive: say so and run\n'
        f'it under bash -c, or quote the expansion to show the single-item intent.\n'
        f'(Disable this guard with the plugin option zshGuard=false.)',
        file=sys.stderr)
    return 2


def run() -> int:
    try:
        return main()
    except Exception as exc:
        print(f'[bendit] BLOCKED: the zsh word-split guard itself failed '
              f'({type(exc).__name__}: {exc}), so the command could not be checked.',
              file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(run())
