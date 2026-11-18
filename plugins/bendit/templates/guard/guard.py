#!/usr/bin/env python3
"""__GUARD_NAME__: a PreToolUse guard. Exit 2 refuses the tool call.

Scaffolded by bendit's new-guard.sh. Edit RULES and check() below,
then edit __GUARD_NAME__.test.sh so it feeds a known-bad and a known-good
payload for every rule you add.

The contract every guard in bendit keeps:

  * Exit 2 + a reason on STDERR refuses the call. Claude Code shows stderr to
    the agent; a reason on stdout means "blocked, no reason given", and the
    agent retries blind.
  * Exit 0, silent, allows it.
  * FAIL CLOSED. Anything this guard cannot read or finish refuses: a crash,
    an unreadable payload, a missing helper. A Python traceback exits 1, which
    Claude Code treats as a NON-blocking error, so the command would run
    unguarded. main() turns every failure into exit 2.
  * Standard library only, no network, finishes well inside its hook timeout.

Shell commands are read with shell_text.py (a small shell lexer shipped with
bendit): it splits `a && sudo b; bash -c 'c'` into the commands that
would actually run, wrappers removed, so a rule asks about one command's argv
instead of regex-matching raw text. Quoted text is an argument, so
`git commit -m "never use --no-verify"` does not trip a rule about --no-verify.
"""
import json
import os
import sys
from typing import List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = '__GUARD_NAME__'


def refuse(reason: str) -> int:
    print(f'BLOCKED by {NAME}: {reason}.\n'
          'If this is genuinely required, ask the human to run it.',
          file=sys.stderr)
    return 2


# --- rules ------------------------------------------------------------------
# Each rule takes one command's argv (argv[0] is the bare command name, after
# sudo/env/VAR=x and similar wrappers are removed) and returns True to refuse.
# The example rule refuses skipping git hooks, which is how an agent routes
# around every commit-time check. Replace it with the mistake you are encoding.

def skips_git_hooks(argv: List[str]) -> bool:
    if not argv or argv[0] != 'git':
        return False
    args, i, sub = argv[1:], 0, ''
    while i < len(args):                      # skip git's own options: git -C dir push
        if args[i] in ('-C', '-c', '--git-dir', '--work-tree'):
            i += 2
        elif args[i].startswith('-'):
            i += 1
        else:
            sub = args[i]
            break
    if sub not in ('commit', 'push', 'merge', 'am', 'rebase'):
        return False
    return '--no-verify' in args or (sub == 'commit' and '-n' in args)


RULES = [
    (skips_git_hooks, 'skipping git hooks with --no-verify bypasses the checks they run'),
]


def check(tool_name: str, tool_input: dict) -> Optional[str]:
    """The reason to refuse, or None to allow."""
    if tool_name != 'Bash':
        return None
    command = tool_input.get('command')
    if not isinstance(command, str):
        return 'the hook payload carried no command string, so it could not be inspected'
    if not command.strip():
        return None
    from shell_text import simple_commands  # imported here so a missing file fails closed in main()
    for simple in simple_commands(command):
        for rule, reason in RULES:
            if rule(simple.argv):
                return reason
    return None


def main() -> int:
    try:
        sys.path.insert(0, HERE)
        raw = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape')
        try:
            payload = json.loads(raw)
        except ValueError:
            return refuse('the hook payload was not JSON, so the call could not be checked')
        if not isinstance(payload, dict):
            return refuse('the hook payload was not a JSON object, so the call could not be checked')
        tool_input = payload.get('tool_input')
        if not isinstance(tool_input, dict):
            return refuse('the hook payload had no tool_input, so the call could not be checked')
        reason = check(str(payload.get('tool_name', '')), tool_input)
        return refuse(reason) if reason else 0
    except Exception as exc:  # fail closed: a guard that cannot finish refuses
        return refuse(f'the guard itself failed ({type(exc).__name__}: {exc}), '
                      'so the call could not be checked')


if __name__ == '__main__':
    sys.exit(main())
