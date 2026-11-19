#!/usr/bin/env python3
"""PreToolUse guard for Bash. Exit 2 blocks the call; the reason must go to stderr.

Bugs earlier versions of guards like this one had, each now pinned by a test:
  1. reading payload["command"]; Claude Code sends payload["tool_input"]["command"]
  2. printing the reason to stdout, which PreToolUse does not surface
  3. reading the body of a quoted heredoc as commands, so writing a file whose
     text mentions `rm -rf` was blocked as if it ran one
  4. permitting the call, unguarded, when the payload could not be read
  5. matching rules only right after a separator, so every wrapper (`sudo rm`,
     `bash -c 'rm ...'`, `xargs rm`, `npx supabase db push`...) passed
  6. non-UTF-8 input, or any crash inside the guard, raising a traceback and
     exited 1 -- which Claude Code treats as a non-blocking error, so the
     command ran. A crash now refuses (see main).
All are covered by block-dangerous-bash.test.sh.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_text import SQL_CLIENTS, simple_commands  # noqa: E402

# HOW COMMANDS ARE FOUND. An earlier version made every rule a regex anchored
# at a command boundary (start, newline, `;|&`, backtick, `$(`, then/do/else).
# Replaying a large sample of real agent commands showed an offset-0 anchor
# missed more destructive commands than it caught. But an anchor can only ask
# what comes straight after a separator, and a review walked past it with
# `sudo rm`, `env rm`, `FOO=1 rm`, `\rm`,
# `/bin/rm`, `xargs rm`, `bash -c '...'`, `eval`, `( )`, `{ }`, `find -delete`
# and `npx supabase db push` -- while `git commit -m "never git push --force"`
# was refused, because the force-push regex had no anchor at all.
#
# The rules now read COMMAND WORDS from shell_text.simple_commands, which lexes
# the text, strips wrappers (sudo, env, command, nohup, time, xargs, package
# runners, VAR=value) and descends into `sh -c`, eval, find -exec, shell-fed
# heredocs and here-strings, `echo ... | sh`, and trap bodies. Each rule asks a
# question of one command's argv. Quoted text is an ARGUMENT, so
# `git commit -m "explain rm -rf"` never arms one.
#
# Still invisible, and no static reader can fix it: a command behind a variable
# (`$RM -rf x`), a script file (`bash clean.sh`), and remote shells (`ssh h 'rm'`).
#
# Allowed ON PURPOSE, and what that costs: `rm -r dir` without -f. In an
# agent's non-interactive shell -f changes little (rm -r only stops on
# write-protected files), so `rm -r dist` deletes as surely as `rm -rf dist`.
# It stays allowed because routine cleanups (`rm -r node_modules`, a scratch
# dir) are common and a guard that blocks normal work gets switched off. The
# cd-then-delete rule below still catches `cd X && rm -r X`.


def rm_flags(args):
    """(recursive, force) for rm's arguments, GNU-style: flags may follow
    operands (`rm build -rf`), and only `--` ends them.

    Flags are read from tokens that START with `-`, so a filename can never arm
    the rule: `rm -f features/x.json` is neither recursive nor a match. Split
    flags (`rm -r -f`) and long ones (`--recursive --force`) are read too; all
    three are pinned in the suite.
    """
    recursive = force = False
    for x in args:
        if x == '--':
            break
        if x.startswith('--'):
            body = x[2:]
            recursive |= bool(body) and 'recursive'.startswith(body)
            force |= bool(body) and 'force'.startswith(body)
        elif x.startswith('-') and len(x) > 1:
            recursive |= 'r' in x or 'R' in x
            force |= 'f' in x
    return recursive, force


def rm_operands(args):
    out, done = [], False
    for x in args:
        if not done and x == '--':
            done = True
        elif done or not x.startswith('-'):
            out.append(x)
    return out


def rm_recursive_force(s):
    if s.argv[0] != 'rm' or s.deferred:
        # A trap body is the cleanup idiom (`trap 'rm -rf "$T"' EXIT`) and was
        # never refused; the cwd rule below is what guards a trap.
        return False
    recursive, force = rm_flags(s.argv[1:])
    return recursive and force


def find_delete(s):
    return s.argv[0] == 'find' and '-delete' in s.argv


_SQL_DESTROY = re.compile(r'\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b', re.I)
_DELETE = re.compile(r'\bDELETE\s+FROM\b', re.I)
_WHERE = re.compile(r'\bWHERE\b', re.I)


def sql_text(s):
    """All SQL one client invocation can see: its arguments, here-strings, and
    heredoc bodies on it or upstream of it in the same pipeline -- quoted or
    not, one line or many. Joined with `;` so a WHERE in one `-c` cannot vouch
    for a DELETE in another."""
    parts = list(s.argv[1:]) + list(s.cmd.herestrings)
    pipe = s.cmd.pipe if s.cmd in s.cmd.pipe else [s.cmd]
    for c in pipe[:pipe.index(s.cmd) + 1]:
        parts.extend(h.body for h in c.heredocs)
    return ';'.join(parts)


def destructive_sql(s):
    if s.argv[0] not in SQL_CLIENTS:
        return False
    sql = sql_text(s)
    if _SQL_DESTROY.search(sql):
        return True
    return any(_DELETE.search(stmt) and not _WHERE.search(stmt)
               for stmt in sql.split(';'))


def supabase_push_or_reset(s):
    if s.argv[0] != 'supabase' or 'db' not in s.argv:
        return False
    rest = [x for x in s.argv[s.argv.index('db') + 1:] if not x.startswith('-')]
    return bool(rest) and rest[0] in ('push', 'reset')


_GIT_OPTS_WITH_ARG = {'-C', '-c', '--git-dir', '--work-tree', '--namespace',
                      '--config-env', '--super-prefix', '--exec-path'}


def force_push(s):
    a = s.argv
    if a[0] != 'git':
        return False
    i = 1
    while i < len(a) and a[i].startswith('-'):
        i += 2 if a[i] in _GIT_OPTS_WITH_ARG else 1
    if i >= len(a) or a[i] != 'push':
        return False
    skip = False
    for x in a[i + 1:]:
        if skip:
            skip = False
            continue
        if x == '--force':
            return True
        if x.startswith('--'):
            continue   # --force-with-lease, --force-if-includes, ...
        if x.startswith('-o'):
            skip = x == '-o'   # -o <push-option> takes a value
            continue
        if x.startswith('-') and 'f' in x[1:]:
            return True   # -f, -uf, -fu
        if x.startswith('+') and len(x) > 1:
            return True   # +refspec forces that one ref
    return False


def git_clean_force(s):
    """`git clean` that will really delete: untracked files (and, with -x,
    ignored ones -- .env included), with no undo. git refuses to clean
    without -f/--force by default, so the force flag is what makes it real;
    -n/--dry-run only lists, and wins over -f."""
    a = s.argv
    if a[0] != 'git':
        return False
    i = 1
    while i < len(a) and a[i].startswith('-'):
        i += 2 if a[i] in _GIT_OPTS_WITH_ARG else 1
    if i >= len(a) or a[i] != 'clean':
        return False
    force = dry = False
    for x in a[i + 1:]:
        if x == '--':
            break
        if x in ('--force',):
            force = True
        elif x in ('--dry-run',):
            dry = True
        elif x.startswith('-') and not x.startswith('--'):
            force |= 'f' in x[1:]
            dry |= 'n' in x[1:]
    return force and not dry


# Rules about what the shell will RUN, in the order they speak. Every command
# found is asked each rule in turn; the first rule any command trips gives the
# reason.
COMMAND_RULES = [
    (rm_recursive_force, 'recursive force delete — run it yourself if you mean it'),
    (find_delete, '`find -delete` removes everything it matches — run it yourself if you mean it'),
    (destructive_sql, 'destructive SQL through a database client (DROP/TRUNCATE, or DELETE with no WHERE)'),
    (supabase_push_or_reset, 'supabase db push/reset — use `supabase db diff` and let the human push'),
    (force_push, 'force push — use --force-with-lease, and never on a shared branch'),
    (git_clean_force, '`git clean -f` deletes untracked (and with -x, ignored, .env included) files with no undo — run `git clean -n` to see the list, then run it yourself if you mean it'),
]

# A command must not leave the shell standing in a directory it deleted.
#
# This is not hypothetical; a whole session can be lost to exactly this:
# `trap 'rm -rf "$T"' EXIT` passes every rule above (a trap DEFERS the delete),
# `cd "$T"` moves the persistent shell into the doomed directory, and the trap
# fires. From then on `getcwd` returns EPERM, so every hook spawned from that
# shell cannot open its own script -- including the guard that would be asked
# to permit the `cd` that could escape. A fail-closed guard wedged on a
# dangling cwd.
#
# Two conditions have to be correlated on the SAME token, so this is a function
# rather than a per-command rule.


def _norm_path_token(token: str) -> str:
    """Compare `"$T"`, `'$T'`, `${T}` and `$T/` as one token."""
    # The lexer has already removed shell quoting; quotes are still stripped
    # WHEREVER they sit in case a token arrives raw.
    token = re.sub(r'[\'"]', '', token.strip())
    token = re.sub(r'\$\{(\w+)\}', r'$\1', token)
    return token.rstrip('/')


def deletes_the_directory_it_enters(simples):
    """Return the token entered and then deleted, else None.

    ORDER IS THE WHOLE QUESTION. A version that matched the two tokens and
    never asked which ran first refused an ordinary scratch-dir setup:

        S=/tmp/x; rm -rf "$S"; mkdir -p "$S" && cd "$S" && git init

    The rm clears the directory BEFORE anything enters it; the shell is never
    left standing in something deleted. Only an rm that can run after the cd
    can strip the shell of its cwd. A trap body runs at EXIT, so its rm is
    always after.

    WHICH cd COUNTS. Only one that moves THIS shell: a cd inside
    `( )`, `$( )` or `bash -c` moves a child, and one inside a quoted string is
    not a cd at all. The old text scan refused `(cd "$T" && make); rm -rf "$T"`
    and `echo "cd $T"; rm -rf "$T"` with an untrue EPERM explanation.
    """
    entered = []
    for s in simples:
        if s.subshell or s.deferred or s.argv[0] not in ('cd', 'pushd'):
            continue
        targets = [x for x in s.argv[1:] if not x.startswith('-')]
        if targets and _norm_path_token(targets[0]):
            entered.append((s.seq, _norm_path_token(targets[0])))
    if not entered:
        return None
    for s in simples:
        if s.argv[0] != 'rm' or not rm_flags(s.argv[1:])[0]:
            continue
        for operand in rm_operands(s.argv[1:]):
            normalised = _norm_path_token(operand)
            for cd_at, cd_tok in entered:
                # An exact match only. Deleting a SUBDIRECTORY of the cwd leaves
                # the shell valid, so `cd "$R" && rm -rf "$R/build"` is fine and
                # must stay allowed -- a prefix test would refuse it.
                if normalised and cd_tok == normalised and (s.deferred or s.seq > cd_at):
                    return normalised
    return None


# Rules about MATERIAL present anywhere in the call. A live key is just as
# leaked when it is written into a file by a heredoc, so these see the raw text.
MATERIAL_RULES = [
    (r'sk_live_[A-Za-z0-9]{20,}', 'Stripe LIVE secret key in the command'),
    (r'\brk_live_[A-Za-z0-9]{20,}', 'Stripe LIVE restricted key in the command'),
    (r'\bsbp_[A-Za-z0-9]{30,}', 'Supabase personal access token in the command'),
    (r'\bsb_secret_[A-Za-z0-9_-]{20,}', 'Supabase secret key in the command'),
    (r'\bghp_[A-Za-z0-9]{36}', 'GitHub personal access token in the command'),
    (r'\bgithub_pat_[A-Za-z0-9_]{22,}', 'GitHub fine-grained personal access token in the command'),
    (r'-----BEGIN [A-Z ]*PRIVATE KEY-----', 'private key material in the command'),
]


def block(reason: str) -> int:
    print(
        f'BLOCKED by bendit safety hook: {reason}.\n'
        f'If this is genuinely required, ask the human to run it.',
        file=sys.stderr,
    )
    return 2


def inspect(raw: str) -> int:
    # Not a hook payload at all (tests, a shell pipeline, a future payload
    # shape). Blocking here would break every Bash call everywhere, so permit.
    if not raw.strip():
        return 0
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return 0

    # Past this point the payload IS JSON, so the hook was invoked properly.
    # If we still cannot see the command, we are guarding something we cannot
    # read — that is the bypass-shaped case, and it blocks.
    if not isinstance(payload, dict):
        return block('hook payload was JSON but not an object, so the command could not be read')
    tool_input = payload.get('tool_input')
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get('command', payload.get('command'))
    if command is None:
        return block('hook payload carried no command to inspect')
    if not isinstance(command, str):
        return block('hook payload command was not a string, so it could not be inspected')
    # An empty command runs nothing, so there is nothing to guard. This is a
    # permit, not a bypass: the command WAS extracted, it is just empty.
    if not command.strip():
        return 0

    simples = simple_commands(command)
    doomed = deletes_the_directory_it_enters(simples)
    if doomed is not None:
        return block(
            f'this enters {doomed} and then deletes it, which leaves the shell '
            'with no working directory — every later command, and every hook, '
            'then fails with EPERM. Delete it from a subshell, or cd out first'
        )
    for rule, reason in COMMAND_RULES:
        if any(rule(s) for s in simples):
            return block(reason)
    for pattern, reason in MATERIAL_RULES:
        if re.search(pattern, command, re.IGNORECASE):
            return block(reason)
    return 0


def main() -> int:
    # Bytes, decoded leniently: a payload that is JSON apart from one bad byte
    # is still a payload, and its command is still inspected.
    raw = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape')
    try:
        return inspect(raw)
    except Exception as exc:
        # Exit 1 from a traceback is a NON-blocking error to Claude Code: the
        # command would run unguarded. A guard that cannot finish refuses.
        return block(f'the guard itself failed ({type(exc).__name__}: {exc}), '
                     'so the command could not be checked')


if __name__ == '__main__':
    sys.exit(main())
