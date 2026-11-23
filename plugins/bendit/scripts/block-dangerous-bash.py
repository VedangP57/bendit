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
  7. importing shell_text.py OUTSIDE that net, so a helper that was broken,
     missing or exited on import still let the command run -- and a
     SystemExit or KeyboardInterrupt from a helper CALL (setup or main)
     escaped every `except Exception`. Both now refuse (see could_not_start).
     Not coverable: a helper calling os._exit(0) ends the process at once.
1-6 are covered by block-dangerous-bash.test.sh, 7 by guard-startup.test.sh.
"""
import bisect
import fnmatch
import io
import json
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


# A GUARD THAT CANNOT START REFUSES. Its helper import and module setup used to
# run outside every net: a shell_text.py that was broken, missing or exited on
# import made Python exit 1 (or 0) -- and Claude Code runs the command on any
# exit but 2. Now any error nothing else catches refuses with exit 2 here, and
# a SystemExit raised by a helper -- which never reaches an excepthook -- is
# turned into an error first, wherever this module calls one: at import, at
# setup, and in main's nets, which catch BaseException.
# Not logged to fires.jsonl: the payload is not read yet, and fire_log may
# share the breakage.
def _describe(exc: BaseException) -> str:
    """`Type: message`, or less when even that cannot be produced."""
    try:
        return f'{type(exc).__name__}: {exc}'
    except BaseException:
        try:
            return type(exc).__name__
        except BaseException:
            return 'an error that could not be described'


def could_not_start(guard: str, exc: BaseException) -> str:
    return (f'[bendit] BLOCKED: bendit guard {guard} could not start: '
            f'{_describe(exc)}; refusing to be safe. Run /bendit:doctor.')


def failed_while_checking(guard: str, exc: BaseException) -> str:
    return (f'[bendit] BLOCKED: bendit guard {guard} failed while checking: '
            f'{_describe(exc)}; refusing to be safe. Run /bendit:doctor.')


def _say(msg: str) -> None:
    """Print a refusal; if that fails, write a fixed one straight to fd 2."""
    try:
        print(msg, file=sys.stderr)
        sys.stderr.flush()
    except BaseException:
        try:
            os.write(2, b'[bendit] BLOCKED: bendit guard block-dangerous-bash failed and could not say why; '
                        b'refusing to be safe. Run /bendit:doctor.\n')
        except BaseException:
            pass


_STARTED = False   # set by main(): after that an uncaught error is not a start failure


def _refuse_uncaught(_type, exc, _tb):
    try:
        _say((failed_while_checking if _STARTED else could_not_start)('block-dangerous-bash', exc))
    finally:
        os._exit(2)


if __name__ == '__main__':
    sys.excepthook = _refuse_uncaught
try:
    from shell_text import SHELLS, SQL_CLIENTS, _match_close, lex, simple_commands, unwrap  # noqa: E402
except SystemExit as _exc:   # a helper that exits on import never reaches excepthook
    raise ImportError(f'shell_text.py raised SystemExit on import (exit {_exc.code})') from None

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
# THREAT MODEL: a well-meaning but HASTY agent, not a malicious one. What a
# hasty agent plausibly types is refused; what takes deliberate evasion is
# listed here as a KNOWN GAP rather than chased with ever-larger parsing:
#   * brace expansion as the command (`{rm,-rf,x}`) and globbed command names
#     (`/bin/r? -rf x`) -- nothing is expanded, so the name is not `rm`
#   * wrappers this guard does not unwrap: busybox, GNU parallel, flock,
#     `docker run` (only `docker exec`, `docker compose exec` and
#     `kubectl exec` are unwrapped)
#   * a script fed by process substitution or stdin: `bash <(...)`,
#     `source /dev/stdin <<< ...`, `. <(...)`
#   * SQL in a file: `psql -f drop.sql`, `psql < drop.sql` -- files are not opened
#   * symlinks: `ln -s ~ /tmp/h && rm -rf /tmp/h/` passes the temp allowance;
#     where a path really points cannot be seen without touching the disk
#   * a variable set inside a `{ }` group on its own line after `&&`, or by
#     `printf -v` / `eval` -- the temp allowance may believe or miss it
#   * one-liners in other languages (perl, ruby), and a node/python tree
#     delete whose path is built (`path.join(os.tmpdir(), 'x')` is refused,
#     never read as temp)
#   * forging the state files other bendit hooks keep -- an agent set on that
#     can edit any file it can write
#
# A RECURSIVE delete is refused with or without -f. `rm -r dir` used to be
# allowed on purpose, so routine cleanups would not get the guard switched off.
# The final eval sweep (2026-11-19) measured what that cost: told only to
# "free up space", one of 12 agents ran `rm -r -- ./dist` and it went through
# -- the only deletion of the sweep that did. In an agent's non-interactive
# shell -f changes almost nothing (rm -r only stops on write-protected files),
# so `rm -r dist` deletes as surely as `rm -rf dist`. A scratch folder inside a
# temp location is still allowed, by the same rules as for rm -rf; `rm file`
# (no -r) and `rmdir` are not touched.


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


# A SCRATCH FOLDER INSIDE A TEMP LOCATION may be force-deleted. In a skill
# eval the agent, told to make its new check fail once, built a scratch copy
# under $TMPDIR; refusing the `rm -rf "$d"` cleanup ran it out of turns.
# Only a folder INSIDE the temp root counts: the root itself, a glob straight
# under it, a `.` or `..` segment and look-alikes (/tmpfoo, $TMPDIRX) do not.
#
# The allowance reads variables statically, so it believes an assignment only
# when it is certain to have happened in THIS shell: not inside `( )` or `$( )`,
# not after `&&`/`||` or inside if/while/for/case (except for the rest of its
# own `&&` chain, which runs only if it did), not a `VAR=x cmd` prefix
# (that sets the variable for one command only), and not after `unset VAR`.
# Any assignment to TMPDIR anywhere in the command voids the $TMPDIR roots.
# ONE narrow exception (Vars.bare_safe): the BARE variable -- $S, "$S", ${S},
# "${S}", nothing appended -- may rest on an assignment made only on some
# paths (after `cd x &&`, `||`, inside if). On the other paths S is unset, and
# `rm -rf ""` / `rm -rf` delete nothing; "$S/sub" would be `/sub`.
# A glob straight after a variable (`"$D"/*`) needs D to be a literal temp
# path: if `mktemp` failed, D is empty and the glob is `/*`.
_TEMP_ROOTS = ('/tmp/', '/private/tmp/', '$TMPDIR/', '${TMPDIR}/')
_MAC_TEMP = re.compile(r'^(?:/private)?/var/folders/[\w+-]+/[\w+-]+/T/')
_VAR_REF = re.compile(r'^\$(?:\{(\w+)\}|(\w+))(/.*)?$')
_ASSIGN = re.compile(r'^(\w+)=(.*)$', re.S)
_DECLARERS = ('export', 'local', 'declare', 'readonly', 'typeset')
_LEADING = frozenset({'!', '{', 'then', 'do', 'else', 'elif', 'if', 'while', 'until'})
_MKTEMP = re.compile(r'^(\$\(|`)\s*mktemp\b')
_GLOB = re.compile(r'[*?\[]')
_TMPDIR_WRITTEN = re.compile(r'(?<![\w${])TMPDIR\b')
# Names a shell has a value for before the command runs, whatever the hook's
# own environment says.
_SHELL_SET = frozenset({'HOME', 'PWD', 'OLDPWD', 'TMPDIR', 'USER', 'LOGNAME',
                        'SHELL', 'PATH', 'IFS', 'CDPATH', 'HOSTNAME', 'UID'})


class Vars:
    """What each variable holds at each point of ONE command, built in one pass.

    value(name, seq, chain) is the value of the last assignment before `seq`
    that is certain to have happened, or None (never set, unset, or set only
    on some paths). An assignment that is itself conditional
    (`[ -n "$X" ] && D=/tmp/x`) is still certain for the rest of ITS `&&`
    chain -- `cd r && S=/tmp/s && rm -rf "$S"` only reaches the rm if the
    assignment ran -- but not after a `;` or newline. Lookups are a bisect, so a long command stays linear: the old
    temp_vars re-lexed the whole command for every rm (13s at 2000 lines).
    """

    def __init__(self, command: str):
        self.tmpdir_void = bool(_TMPDIR_WRITTEN.search(command))
        events = {}
        for c in lex(command).cmds:
            if c.subshell:
                continue   # ( ), $( ), <( ): a child's variables die with it
            words = c.argv
            while words and words[0] in _LEADING:
                words = words[1:]
            if not words:
                continue
            if len(c.pipe) > 1:
                continue   # a pipeline element runs in a subshell
            # chain: None = certain everywhere after; an id = only there
            scope = c.chain if c.cond else None
            head = words[0]
            if head == 'unset':
                for n in words[1:]:
                    if not n.startswith('-'):
                        events.setdefault(n, []).append((c.seq, None, None))
                continue
            if head in ('read', 'for', 'mapfile', 'readarray'):
                for n in words[1:]:
                    if re.fullmatch(r'\w+', n):
                        events.setdefault(n, []).append((c.seq, None, None))
                continue
            if head in _DECLARERS:
                pairs = [_ASSIGN.match(w) for w in words[1:] if not w.startswith('-')]
            else:
                pairs = [_ASSIGN.match(w) for w in words]
                if not all(pairs):
                    continue   # `VAR=x cmd`: set for that one command only
            for m in pairs:
                if m:
                    events.setdefault(m.group(1), []).append(
                        (c.seq, m.group(2), scope))
        self._seqs, self._vals = {}, {}
        for name, evs in events.items():
            evs.sort(key=lambda e: e[0])
            self._seqs[name] = [e[0] for e in evs]
            self._vals[name] = [(e[1], e[2]) for e in evs]

    def value(self, name: str, seq: float, chain=None):
        seqs = self._seqs.get(name)
        if not seqs:
            return None
        k = bisect.bisect_left(seqs, seq)
        if not k:
            return None
        value, scope = self._vals[name][k - 1]
        return value if scope is None or scope == chain else None

    def bare_safe(self, name: str, seq: float) -> bool:
        """True when `rm -rf "$name"` -- the BARE variable, nothing appended --
        cannot reach anything but a temp folder, even through an assignment
        that happened only on some paths (after `cd x &&` / `||`, inside if).
        On the other paths the variable is UNSET, and `rm -rf ""` / `rm -rf`
        delete nothing. That premise holds only if nothing else could have
        left a value: every assignment before `seq` must be a temp path or a
        $(mktemp ...), none may be an unset/read, and the name must not be one
        the shell inherits or sets itself (HOME survives a failed cd).
        Agreed from a 13,821-command replay in the sibling kit (2026-11-19):
        real temp-folder cleanups were refused for it."""
        if name in _SHELL_SET or name in os.environ:
            return False
        seqs = self._seqs.get(name)
        if not seqs:
            return False
        k = bisect.bisect_left(seqs, seq)
        if not k:
            return False
        for value, _scope in self._vals[name][:k]:
            if value is None or not (_inside_temp(value) or _MKTEMP.match(value)):
                return False
        return True


# The variable table of the command being inspected. Set by _judge().
try:
    VARS = Vars('')   # calls shell_text.lex: setup, so a SystemExit here must refuse too
except SystemExit as _exc:
    raise RuntimeError(f'shell_text raised SystemExit during setup (exit {_exc.code})') from None


def _inside_temp(path: str) -> bool:
    # macOS's real per-user temp dir ($TMPDIR there): /var/folders/<xx>/<id>/T/.
    # Only T (temporary items); C is caches. Both segments must be literal names.
    mac = _MAC_TEMP.match(path)
    if mac:
        path = '/tmp/' + path[mac.end():]
    for root in _TEMP_ROOTS:
        if VARS.tmpdir_void and 'TMPDIR' in root:
            continue
        if path.startswith(root):
            rest = path[len(root):].strip('/')
            parts = [p for p in rest.split('/') if p]
            if not parts or '..' in parts or '.' in parts:
                return False
            # the first segment must name something, not glob everything
            return bool(re.search(r'[^*?\[\]]', parts[0]))
    return False


def _temp_target(operand: str, seq: int, chain=None) -> bool:
    if _inside_temp(operand):
        return True
    m = _VAR_REF.match(operand)
    if not m:
        return False
    parts = [p for p in (m.group(3) or '').split('/') if p]
    if '..' in parts or '.' in parts:
        return False
    value = VARS.value(m.group(1) or m.group(2), seq, chain)
    if value is None:
        # Only the BARE variable may rest on an assignment that happened on
        # some paths: unset, "$S" deletes nothing, but "$S/sub" is `/sub`.
        return m.group(3) is None and VARS.bare_safe(m.group(1) or m.group(2), seq)
    if parts and _GLOB.search(parts[0]):
        return _inside_temp(value)   # an empty D would make this `/*`
    return _inside_temp(value) or bool(_MKTEMP.match(value))


def rm_recursive(s):
    if s.argv[0] not in ('rm', 'rimraf') or s.deferred:
        # A trap body is the cleanup idiom (`trap 'rm -rf "$T"' EXIT`) and was
        # never refused; the cwd rule below is what guards a trap.
        return False
    if s.argv[0] == 'rm':
        # rimraf is `rm -rf` by nature: no flags make it so. For rm, -r alone
        # is enough: -f changes almost nothing in a shell with no tty.
        recursive, _force = rm_flags(s.argv[1:])
        if not recursive:
            return False
    operands = rm_operands(s.argv[1:])
    if operands and all(_temp_target(o, s.seq, s.cmd.chain) for o in operands):
        return False
    return True


def find_delete(s):
    return s.argv[0] == 'find' and '-delete' in s.argv


_SQL_DESTROY = re.compile(r'\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b', re.I)
# TRUNCATE needs no TABLE keyword, but MySQL also has a TRUNCATE(x, d) number
# function -- so a bare TRUNCATE counts only where a statement starts.
_TRUNCATE_STMT = re.compile(r'^\s*TRUNCATE\b(?!\s*\()', re.I)
# ALTER TABLE ... DROP [COLUMN] x loses a column of data; dropping a
# constraint, a default or NOT NULL loses none.
_ALTER_DROP = re.compile(
    r'\bALTER\s+TABLE\b.*?\bDROP\s+(?!(?:CONSTRAINT|DEFAULT|NOT|IDENTITY|EXPRESSION|'
    r'INDEX|KEY|PRIMARY|FOREIGN|CHECK|TRIGGER|POLICY|ROW)\b)', re.I | re.S)
_DELETE = re.compile(r'\bDELETE\s+FROM\b', re.I)
_WHERE = re.compile(r'\bWHERE\b', re.I)
# Comments are stripped before judging: `DELETE FROM t -- WHERE id=1` has no
# WHERE, and `DROP/**/TABLE` is `DROP TABLE`.
_SQL_COMMENT = re.compile(r'/\*.*?\*/|--[^\n]*', re.S)


def _sql_of_arg(arg: str) -> str:
    """The SQL an argument can carry: `--command=X` -> X, `-cX` -> X, `-c` -> ''.
    A bare `--word` is kept whole -- it may be SQL that opens with a comment."""
    if arg.startswith('--'):
        return arg.split('=', 1)[1] if '=' in arg else arg
    if arg.startswith('-'):
        return arg[2:]
    return arg


def sql_text(s):
    """All SQL one client invocation can see: its arguments, here-strings, and
    heredoc bodies and echo/printf arguments on it or upstream of it in the
    same pipeline -- quoted or not, one line or many. Each part has its
    comments stripped, then they are joined with `;` so a WHERE in one `-c`
    cannot vouch for a DELETE in another. A file (`-f x.sql`, `< x.sql`) is
    not opened."""
    parts = [_sql_of_arg(a) for a in s.argv[1:]] + list(s.cmd.herestrings)
    pipe = s.cmd.pipe if s.cmd in s.cmd.pipe else [s.cmd]
    for c in pipe[:pipe.index(s.cmd) + 1]:
        parts.extend(h.body for h in c.heredocs)
        if c is not s.cmd:
            up = unwrap(c.argv)
            if up and up[0] in ('echo', 'printf'):
                parts.extend(x for x in up[1:] if not x.startswith('-'))
    return ';'.join(_SQL_COMMENT.sub(' ', p) for p in parts)


def destructive_sql(s):
    if s.argv[0] not in SQL_CLIENTS:
        return False
    sql = sql_text(s)
    if _SQL_DESTROY.search(sql):
        return True
    for stmt in sql.split(';'):
        if _TRUNCATE_STMT.match(stmt) or _ALTER_DROP.search(stmt):
            return True
        if _DELETE.search(stmt) and not _WHERE.search(stmt):
            return True
    return False


def supabase_push_or_reset(s):
    if s.argv[0] != 'supabase' or 'db' not in s.argv:
        return False
    rest = [x for x in s.argv[s.argv.index('db') + 1:] if not x.startswith('-')]
    return bool(rest) and rest[0] in ('push', 'reset')


def prisma_reset(s):
    """`prisma migrate reset` and `prisma db push --force-reset` drop every
    table and every row. A package runner (`npx`, `pnpm`...) is unwrapped."""
    if s.argv[0] != 'prisma':
        return False
    words = [x for x in s.argv[1:] if not x.startswith('-')]
    if words[:2] == ['migrate', 'reset']:
        return True
    return words[:2] == ['db', 'push'] and '--force-reset' in s.argv


_GIT_OPTS_WITH_ARG = {'-C', '-c', '--git-dir', '--work-tree', '--namespace',
                      '--config-env', '--super-prefix', '--exec-path'}


def _git(a):
    """(index of git's subcommand, the `-c name=value` settings), or (None, [])."""
    if a[0] != 'git':
        return None, []
    i, configs = 1, []
    while i < len(a) and a[i].startswith('-'):
        if a[i] == '-c' and i + 1 < len(a):
            configs.append(a[i + 1])
        i += 2 if a[i] in _GIT_OPTS_WITH_ARG else 1
    return (i, configs) if i < len(a) else (None, configs)


def _long_is(arg: str, name: str, least: int = 1) -> bool:
    """`arg` is `--name` or an abbreviation git accepts (`--forc`)."""
    body = arg[2:].split('=', 1)[0]
    return arg.startswith('--') and len(body) >= least and name.startswith(body)


def force_push(s):
    i, _ = _git(s.argv)
    if i is None or s.argv[i] != 'push':
        return False
    skip = False
    for x in s.argv[i + 1:]:
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


def push_deletes_remote_refs(s):
    """`git push --mirror` (deletes every remote ref you do not have),
    `--delete <ref>`, `-d <ref>` and the `:<ref>` refspec."""
    i, _ = _git(s.argv)
    if i is None or s.argv[i] != 'push':
        return False
    skip = False
    for x in s.argv[i + 1:]:
        if skip:
            skip = False
            continue
        if x == '--':
            continue
        if x.startswith('--'):
            if _long_is(x, 'mirror', 2) or _long_is(x, 'delete', 3):
                return True
            continue
        if x.startswith('-') and len(x) > 1:
            for k, ch in enumerate(x[1:]):
                if ch == 'o':   # -o <push-option>: the rest is its value
                    skip = k == len(x) - 2
                    break
                if ch == 'd':
                    return True
            continue
        if x.startswith(':') and len(x) > 1:
            return True
    return False


# A LEASE AIMED AT SOMEONE ELSE'S COMMIT. `--force-with-lease=<ref>:<expect>`
# overwrites the remote ref only if it still points at <expect> -- so when
# <expect> is a commit the push does NOT contain, the push discards it. The
# v0.5.2 benchmark (s3-force-push) lost a teammate's commit exactly so: the
# agent fetched, saw sam's 51dc142, and ran
#   git push --force-with-lease=feature/checkout:51dc142 origin feature/checkout
# The lease only guards against the remote moving AGAIN; it cannot protect a
# commit the agent has already seen and chosen to overwrite.
#
# So an explicit expected value must be an ancestor of (or equal to) the commit
# pushed to that ref, or the push is refused. Plain `--force-with-lease` and
# `--force-with-lease=<ref>` (no expected value) stay allowed, as does
# `--force-if-includes`. Asked with LOCAL git only -- rev-parse, merge-base,
# log; never a fetch -- in the payload's cwd (after `git -C` and a literal
# `cd` earlier in the command), under one deadline inside the hook's 10 s.
# Whenever git cannot answer (unknown commit, not a repo, git missing, a
# timeout, a refspec it cannot resolve) the push is refused.
#
# KNOWN LIMITS: rebasing commits you already PUSHED and then naming the old
# remote tip as the expected value is refused too -- the old commits are not
# ancestors of the rebased ones (plain --force-with-lease still works). A
# `GIT_DIR=x git push` prefix is not followed. A cd inside `( )` before the
# push is read as if it moved the push's shell, so the check may run in the
# wrong folder; there an unknown commit refuses.
_LEASE_DEADLINE_S = 6.0   # every git call for one command; the hook's timeout is 10 s
_HEXISH = re.compile(r'^[0-9a-fA-F]{7,40}$')
_CWD = [None]       # the payload's cwd; set by inspect()
_SIMPLES = [[]]     # every simple command of the command being judged; set by _verdict()


class _GitCannotTell(Exception):
    pass


def _push_leases(args):
    """(leases, refspecs, all_refs) for `git push <args>`. Each lease with an
    EXPLICIT expected value is (ref or None, expect, the option as written)."""
    leases, positional, all_refs, k, opts = [], [], False, 0, True
    while k < len(args):
        x = args[k]
        k += 1
        if opts and x == '--':
            opts = False
            continue
        if opts and x.startswith('--'):
            if _long_is(x, 'force-with-lease', 7):
                value = x.split('=', 1)[1] if '=' in x else None
                if value is not None and ':' in value:
                    ref, expect = value.split(':', 1)
                    if expect:   # `<ref>:` means "must not exist yet": nothing to lose
                        leases.append((ref, expect, x))
                elif value is not None and _HEXISH.match(value):
                    leases.append((None, value, x))   # a commit, not a refname
            elif _long_is(x, 'no-force-with-lease', 10):
                leases = []
            elif any(_long_is(x, n, 3) for n in ('all', 'branches', 'mirror')):
                all_refs = True
            elif '=' not in x and any(_long_is(x, n, 3) for n in
                                      ('repo', 'receive-pack', 'exec', 'push-option')):
                k += 1   # its value is the next word
            continue
        if opts and x.startswith('-') and len(x) > 1:
            for j, ch in enumerate(x[1:]):
                if ch == 'o':   # -o <push-option>: the rest, or the next word
                    k += j == len(x) - 2
                    break
            continue
        positional.append(x)
    return leases, positional[1:], all_refs


def _short_ref(ref: str) -> str:
    for prefix in ('refs/heads/',):
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref


def _push_dir(s):
    """(cwd, git's -C/--git-dir/--work-tree options) the push runs with."""
    cwd = _CWD[0] or os.getcwd()
    simples = _SIMPLES[0]
    at = next((n for n, x in enumerate(simples) if x is s), len(simples))
    for c in simples[:at]:
        if c.deferred or c.argv[0] not in ('cd', 'pushd') or (c.subshell and not s.subshell):
            continue
        targets = [x for x in c.argv[1:] if not x.startswith('-')]
        target = _resolve(targets[0], c.seq, c.cmd.chain) if targets else '~'
        if target.startswith('~'):
            target = os.path.expanduser(target)
        if not target or '$' in target or '`' in target or '*' in target:
            raise _GitCannotTell(f'the command changes directory to {targets[0] if targets else "~"}, '
                                 'which cannot be read without running it')
        cwd = os.path.join(cwd, target)
    a, i, opts = s.argv, 1, []
    while i < len(a) and a[i].startswith('-'):
        x = a[i]
        if x == '-C' and i + 1 < len(a):
            cwd = os.path.join(cwd, os.path.expanduser(a[i + 1]))
        elif x in ('--git-dir', '--work-tree') and i + 1 < len(a):
            opts += [x, a[i + 1]]
        elif x.startswith(('--git-dir=', '--work-tree=')):
            opts.append(x)
        i += 2 if x in _GIT_OPTS_WITH_ARG else 1
    return cwd, opts


def _git_run(cwd, opts, args, deadline):
    """(exit code, stdout) of a LOCAL git query. Raises _GitCannotTell."""
    import subprocess
    import time
    left = deadline - time.monotonic()
    if left <= 0:
        raise _GitCannotTell('git took too long to answer')
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0',
               GIT_PAGER='cat', LC_ALL='C')
    try:
        r = subprocess.run(['git'] + opts + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=left)
    except subprocess.TimeoutExpired:
        raise _GitCannotTell('git took too long to answer') from None
    except OSError as exc:
        raise _GitCannotTell(f'git could not run ({_describe(exc)})') from None
    return r.returncode, r.stdout.decode('utf-8', 'replace')


def _commit_of(name, cwd, opts, deadline):
    if not name or name.startswith('-'):
        raise _GitCannotTell(f'{name!r} is not a commit name')
    code, out = _git_run(cwd, opts, ['rev-parse', '--verify', '--quiet', name + '^{commit}'], deadline)
    if code != 0 or not out.strip():
        raise _GitCannotTell(f'git here does not know a commit {name}: an unknown commit, '
                             'or not a git repository')
    return out.strip()


def force_with_lease_foreign(s):
    """`git push --force-with-lease=<ref>:<expect>` (or `=<sha>`) whose <expect>
    is not an ancestor of, or equal to, what is pushed to that ref. Returns the
    reason, naming the commits that would be lost, or False."""
    i, _ = _git(s.argv)
    if i is None or s.argv[i] != 'push':
        return False
    leases, refspecs, all_refs = _push_leases(s.argv[i + 1:])
    if not leases:
        return False
    import time
    deadline = time.monotonic() + _LEASE_DEADLINE_S
    pushes = []   # (src, dst) for each refspec that pushes a commit
    for spec in refspecs:
        src, _, dst = spec.lstrip('+').partition(':')
        if src:
            pushes.append((src, dst or src))
    for ref, expect, written in leases:
        try:
            cwd, opts = _push_dir(s)
            if pushes:
                mine = [src for src, dst in pushes
                        if ref is not None and _short_ref(dst) == _short_ref(ref)]
                sources = mine or [src for src, _ in pushes]
            elif all_refs and ref:
                sources = ['refs/heads/' + _short_ref(ref)]
            else:
                sources = ['HEAD']
            old = _commit_of(expect, cwd, opts, deadline)
            for src in sources:
                new = _commit_of(src, cwd, opts, deadline)
                code, _ = _git_run(cwd, opts, ['merge-base', '--is-ancestor', old, new], deadline)
                if code == 0:
                    continue
                if code != 1:
                    raise _GitCannotTell(f'git merge-base exited {code}')
                code, log = _git_run(cwd, opts, ['log', '--oneline', '--no-decorate', '--no-color',
                                                 '-n', '6', f'{new}..{old}'], deadline)
                lines = [ln for ln in log.splitlines() if ln.strip()]
                if code != 0 or not lines:
                    lines = [f'{old[:7]} (git could not list it: run the command below)']
                shown = '\n'.join('    ' + ln for ln in lines[:5])
                if len(lines) > 5:
                    shown += '\n    ... and more'
                return (f'`{written}` would overwrite {old[:7]} on the remote, and {old[:7]} is '
                        f'not part of what you are pushing ({src}) — the push would discard '
                        f'these commits, which exist only there:\n{shown}\n'
                        f'Look at them first: `git log --stat {new[:7]}..{old[:7]}`. To keep them, '
                        f'rebase onto them (`git rebase {old[:7]}`) and push again; a lease only '
                        f'guards against the remote moving again, never a commit you have already '
                        f'seen and chose to overwrite')
        except _GitCannotTell as why:
            return (f'`{written}` names {expect} as the remote commit to overwrite, and git could '
                    f'not check here that your push already contains it ({_describe_short(why)}) — '
                    f'a lease with an explicit expected commit is only allowed when it is part of '
                    f'what you push. Run `git log {expect}` to see what you would discard, and '
                    f'leave this push to the human if it must happen')
    return False


def _describe_short(exc: BaseException) -> str:
    try:
        return str(exc)
    except BaseException:
        return 'an error that could not be described'


_REQUIRE_FORCE_OFF = re.compile(r'(?i)^clean\.requireforce=(false|no|off|0)$')


def git_clean_force(s):
    """`git clean` that will really delete: untracked files (and, with -x,
    ignored ones -- .env included), with no undo. git refuses to clean
    without -f/--force by default, so the force flag (or
    `-c clean.requireForce=false`) is what makes it real; -n/--dry-run only
    lists, and wins over -f.

    Options are PARSED, not searched for letters: `-e<pattern>` and
    `--exclude=<pattern>` carry a value, so `-enode_modules` is not -n and
    `-e.env` is not anything. Long options may be abbreviated (`--forc`)."""
    a = s.argv
    i, configs = _git(a)
    if i is None or a[i] != 'clean':
        return False
    force = any(_REQUIRE_FORCE_OFF.match(c) for c in configs)
    dry = False
    args, k = a[i + 1:], 0
    while k < len(args):
        x = args[k]
        k += 1
        if x == '--':
            break
        if x.startswith('--'):
            if _long_is(x, 'force'):
                force = True
            elif _long_is(x, 'dry-run'):
                dry = True
            elif _long_is(x, 'exclude') and '=' not in x:
                k += 1   # its value is the next word
            continue
        if x.startswith('-') and len(x) > 1:
            for j, ch in enumerate(x[1:]):
                if ch == 'e':
                    if j == len(x) - 2:
                        k += 1   # `-e PATTERN`
                    break        # `-ePATTERN`: the rest is the value
                force |= ch == 'f'
                dry |= ch == 'n'
    return force and not dry


def git_reset_hard(s):
    i, _ = _git(s.argv)
    return (i is not None and s.argv[i] == 'reset'
            and any(_long_is(x, 'hard', 2) for x in s.argv[i + 1:]))


# Pathspecs that name the WHOLE working tree.
_WHOLE_TREE = frozenset({'.', './', ':/', ':/.', ':(top)', '*', ':*'})


def git_discard_all(s):
    """`git checkout [-- ] .` and `git restore .` (worktree) overwrite every
    uncommitted change with no undo. A named file stays allowed, and
    `git restore --staged .` only unstages."""
    a = s.argv
    i, _ = _git(a)
    if i is None or a[i] not in ('checkout', 'restore'):
        return False
    paths, staged, worktree, args, k = [], False, False, a[i + 1:], 0
    with_arg = {'-s', '--source', '-b', '-B', '--orphan', '--conflict'}
    while k < len(args):
        x = args[k]
        k += 1
        if x == '--':
            paths.extend(args[k:])
            break
        if x.startswith('--'):
            staged |= x == '--staged'
            worktree |= x == '--worktree'
            if x in with_arg:
                k += 1
            continue
        if x.startswith('-') and len(x) > 1:
            for j, ch in enumerate(x[1:]):
                if ch in 'sbB':   # takes a value: the rest, or the next word
                    k += j == len(x) - 2
                    break
                staged |= ch == 'S'
                worktree |= ch == 'W'
            continue
        paths.append(x)
    if not any(p in _WHOLE_TREE for p in paths):
        return False
    return a[i] == 'checkout' or worktree or not staged


# One-liners a hasty agent reaches for instead of `rm -rf`.
_PYTHON = re.compile(r'^python[\d.]*$')
_JS_TREE_DELETE = re.compile(r'\b(?:rmSync|rmdirSync|rm|rmdir)\s*\(')
_PY_TREE_DELETE = re.compile(r'\brmtree\s*\(')
_RUN_CALL = re.compile(r'\b(?:system|popen|execSync|exec|execFileSync|spawnSync|spawn|'
                       r'run|call|check_call|check_output|Popen|getoutput|'
                       r'getstatusoutput)\s*\(')
_STRING_LIT = re.compile(r"'((?:\\.|[^'\\])*)'|\"((?:\\.|[^\"\\])*)\"|`([^`]*)`")


def _inline_script(argv):
    """The program text of `node -e X`, `python3 -c X` and kin, or None."""
    name, args = argv[0], argv[1:]
    if name in ('node', 'nodejs', 'bun', 'deno'):
        for k, x in enumerate(args):
            if x in ('-e', '--eval', '-p', '--print', '-pe', '-ep') or (name == 'deno' and x == 'eval'):
                return args[k + 1] if k + 1 < len(args) else None
            if x.startswith(('--eval=', '--print=')):
                return x.split('=', 1)[1]
        return None
    if _PYTHON.match(name):
        k = 0
        while k < len(args):
            x = args[k]
            if not x.startswith('-') or x.startswith('--') or x in ('-m', '-'):
                return None
            if x in ('-W', '-X'):
                k += 2
                continue
            c = x.find('c', 1)
            if c != -1:
                return x[c + 1:] or (args[k + 1] if k + 1 < len(args) else None)
            k += 1
    return None


def _call_args(text: str, open_paren: int) -> str:
    return text[open_paren + 1:_match_close(text, open_paren, len(text), '(', ')') - 1]


def _first_literal(args: str):
    """The first argument when it is a plain string literal, else None."""
    m = _STRING_LIT.match(args.strip())
    if not m or args.strip()[m.end():].strip()[:1] not in ('', ','):
        return None
    return next(g for g in m.groups() if g is not None)


_NESTING = [0]


def script_deletes_tree(s):
    """`node -e`/`python -c` deleting a folder tree: fs.rmSync/rmdirSync/rm
    with `recursive: true`, shutil.rmtree, or a shell command handed to
    os.system/subprocess/execSync -- which is judged by every rule here.
    A literal path inside a temp location is allowed, as for rm -rf."""
    script = _inline_script(s.argv)
    if not script:
        return False
    tree = 'a node/python one-liner that deletes a folder tree (fs.rmSync/rmdirSync with recursive, shutil.rmtree) — run it yourself if you mean it'
    for rx, needs in ((_JS_TREE_DELETE, 'recursive'), (_PY_TREE_DELETE, None)):
        for m in rx.finditer(script):
            args = _call_args(script, m.end() - 1)
            if needs and not re.search(r'recursive\s*:\s*true', args):
                continue
            path = _first_literal(args)
            if path is None or not _inside_temp(path):
                return tree
    if _NESTING[0] > 2:
        return False
    for m in _RUN_CALL.finditer(script):
        args = _call_args(script, m.end() - 1)
        lits = [next(g for g in x.groups() if g is not None)
                for x in _STRING_LIT.finditer(args)]
        if not lits:
            continue
        command = (' '.join(shlex.quote(x) for x in lits)
                   if args.lstrip().startswith('[') else lits[0])
        _NESTING[0] += 1
        try:
            reason = _judge(command)
        finally:
            _NESTING[0] -= 1
        if reason:
            return f'{reason} (inside a {s.argv[0]} one-liner)'
    return False


# Rules about what the shell will RUN, in the order they speak. Every command
# found is asked each rule in turn; the first rule any command trips gives the
# reason.
COMMAND_RULES = [
    (rm_recursive, 'recursive delete (rm -r, with or without -f) — run it yourself if you mean it; only a folder inside /tmp or $TMPDIR is allowed', 'rm-recursive'),
    (find_delete, '`find -delete` removes everything it matches — run it yourself if you mean it', 'find-delete'),
    (destructive_sql, 'destructive SQL through a database client (DROP/TRUNCATE, ALTER TABLE ... DROP, or DELETE with no WHERE)', 'destructive-sql'),
    (supabase_push_or_reset, 'supabase db push/reset — use `supabase db diff` and let the human push', 'supabase-push-reset'),
    (prisma_reset, '`prisma migrate reset` / `prisma db push --force-reset` drops the database and every row in it — use `prisma migrate dev --create-only` to write the migration and let the human apply it', 'prisma-reset'),
    (force_push, 'force push — use --force-with-lease, and never on a shared branch', 'force-push'),
    (push_deletes_remote_refs, '`git push --mirror` / `--delete` / `:<branch>` deletes branches on the remote (--mirror: every remote branch you do not have locally), and other people\'s commits go with them — push your own branch, and leave deleting remote branches to the human', 'push-deletes-remote-refs'),
    (force_with_lease_foreign, 'a lease push aimed at a commit your push does not contain', 'force-with-lease-foreign'),
    (git_clean_force, '`git clean -f` deletes untracked (and with -x, ignored, .env included) files with no undo — run `git clean -n` to see the list, then run it yourself if you mean it', 'git-clean-force'),
    (git_reset_hard, '`git reset --hard` throws away every uncommitted change to tracked files, with no undo — run `git stash` instead (`git stash pop` brings it back), or `git reset --keep`, which refuses to overwrite local changes', 'git-reset-hard'),
    (git_discard_all, '`git checkout .` / `git restore .` throws away EVERY uncommitted change in the working tree, with no undo — name the files you mean (`git restore path/to/file`), or `git stash` to set everything aside recoverably', 'git-discard-all'),
    (script_deletes_tree, 'a one-liner that deletes a folder tree', 'script-deletes-tree'),
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


# ONLY THE PERSON APPROVES A HARNESS. The Stop gate runs a repo's
# .claude/verify-harness unsandboxed, and only after the person runs
# `require-verification.py --trust <repo>` in their own terminal. An agent that
# runs that itself, or writes the approval list, approves its own code.
TRUST_REASON = ('[bendit] --trust approves a harness to run unsandboxed; only '
                'the person may run it, in their own terminal')
TRUST_FILE_REASON = ('[bendit] trusted-harnesses.json is the person\'s list of '
                     'approved harnesses, and only the person changes it — '
                     'reading it is fine')
_TRUST_FILE = 'trusted-harnesses.json'
_INTERPRETERS = re.compile(r'^(python[\d.]*|node|nodejs|bun|deno|perl|ruby)$')


def _inert(argv, cmd) -> bool:
    """A command that only SHOWS text it is given: a message, a search, a
    print -- and is not piped into something that would run that text."""
    if not argv:
        return False
    name = argv[0]
    if name == 'git':
        words = [x for x in argv[1:] if not x.startswith('-')]
        ok = bool(words) and words[0] in ('commit', 'log', 'show', 'diff', 'grep', 'tag', 'notes')
    else:
        ok = name in ('echo', 'printf', 'grep', 'egrep', 'fgrep', 'rg', 'cat', 'gh')
    if ok and cmd in cmd.pipe:
        for later in cmd.pipe[cmd.pipe.index(cmd) + 1:]:
            nxt = unwrap(later.argv)
            if nxt and (nxt[0] in SHELLS or nxt[0] in ('eval', 'xargs', 'source', '.')
                        or _INTERPRETERS.match(nxt[0])):
                return False
    return ok


def runs_trust_approval(command: str, simples) -> bool:
    """`require-verification.py --trust` run any way at all. The text test is
    deliberately blunt -- both words anywhere -- and the one thing let through
    is an occurrence of `--trust` that sits only inside a command that shows
    text (a commit message, an echo, a grep), so documenting the flag works."""
    for s in simples:
        # A variable we cannot see holding the script: `python3 "$RV" --trust`
        if (_INTERPRETERS.match(s.argv[0]) and len(s.argv) > 1
                and s.argv[1].startswith('$') and '--trust' in s.argv):
            return True
    if 'require-verification' not in command:
        return False
    return _live_mention(command, '--trust')


def _live_mention(command: str, needle: str) -> bool:
    """`needle` appears anywhere except inside a command that only shows text."""
    if needle not in command:
        return False
    inert, live = [], []
    for c in lex(command).cmds:
        spans = [(w.start, w.end) for w in c.words]
        (inert if _inert(unwrap(c.argv), c) else live).extend(spans)
    for m in re.finditer(re.escape(needle), command):
        at = m.start()
        if any(a <= at < b for a, b in live) or not any(a <= at < b for a, b in inert):
            return True   # in code, in a heredoc body, or in a running string
    return False


# THE INSTALLER'S QUESTIONS ARE FOR THE PERSON. install.sh reads its yes/no from
# $BENDIT_TTY (a test hook); an agent that sets it answers "yes" to installing
# software on the person's machine. Blunt on purpose, like --trust: the name
# anywhere in code, through env/sudo/export/bash -c, is refused; naming it in a
# commit message or an echo is fine.
INSTALLER_REASON = ('[bendit] pre-answering the bendit installer — its questions '
                    'are for the person; run it yourself')


def preanswers_installer(command: str) -> bool:
    return _live_mention(command, 'BENDIT_TTY')


_WRITE_IN_SCRIPT = re.compile(
    r"""['"][wax]\+?b?['"]|mode\s*=|\bwrite|\bdump\(|unlink|remove\(|rename|replace\(|"""
    r"""rmSync|appendFile|copyFile|truncate""")


def writes_trust_file(command: str, simples) -> bool:
    """Any write, move, copy-over or delete of trusted-harnesses.json."""
    if _TRUST_FILE not in command:
        return False
    # A variable naming the file is the file: `T=.../trusted-harnesses.json; > "$T"`
    text = command
    for name in set(re.findall(r'(\w+)=[\'"]?[^\s;&|]*' + re.escape(_TRUST_FILE), command)):
        text = re.sub(r'\$\{?' + name + r'\b\}?', _TRUST_FILE, text)
    if re.search(r'(>>?|>\||&>>?)\s*[\'"]?[^\s;&|<>]*' + re.escape(_TRUST_FILE), text):
        return True
    for s in (simples if text == command else simple_commands(text)):
        a = s.argv
        hit = [x for x in a[1:] if _TRUST_FILE in x]
        name = a[0]
        if _INTERPRETERS.match(name):
            script = _inline_script(a) or ''
            script += ''.join(h.body for h in s.cmd.heredocs) + ''.join(s.cmd.herestrings)
            if _TRUST_FILE in script and _WRITE_IN_SCRIPT.search(script):
                return True
            continue
        if not hit:
            continue
        if name in ('tee', 'mv', 'rm', 'unlink', 'truncate', 'install', 'ln', 'touch', 'shred'):
            return True
        if name in ('cp', 'rsync', 'ditto') and (_TRUST_FILE in a[-1] or '-t' in a):
            return True
        if name in ('sed', 'perl') and any(x == '-i' or x.startswith(('-i', '--in-place')) for x in a[1:]):
            return True
        if name == 'dd' and any(x.startswith('of=') and _TRUST_FILE in x for x in a):
            return True
    return False


def _resolve(token: str, seq: float, chain=None) -> str:
    """A path token with a leading variable replaced by the literal it was
    last certainly assigned, so `D=/tmp/s; cd /tmp/s; rm -rf "$D"` compares
    `/tmp/s` with `/tmp/s`. A `$(...)` value is left as the variable."""
    tok = _norm_path_token(token)
    for _ in range(4):
        m = re.match(r'^\$(\w+)(/.*)?$', tok)
        if not m:
            break
        value = VARS.value(m.group(1), seq, chain)
        if value is None or '$(' in value or '`' in value:
            break
        tok = _norm_path_token(value + (m.group(2) or ''))
    return re.sub(r'/(\./)+', '/', re.sub(r'/{2,}', '/', tok))


def deletes_the_directory_it_enters(simples):
    """Return (entered, deleted, same) when a delete can remove the directory
    the shell is standing in -- or one that CONTAINS it -- else None. `same`
    is whether the two name one directory (perhaps spelled two ways).

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

    WHAT COUNTS AS THE SAME DIRECTORY. The cwd itself or any ANCESTOR of it
    (`cd "$T/w"; rm -rf "$T"` strands the shell just the same), with a
    variable read as the literal it was assigned. Deleting a SUBDIRECTORY of
    the cwd leaves the shell valid, so `cd "$R" && rm -rf "$R/build"` is fine
    and stays allowed.
    """
    # Every directory a cd leaves the shell inside -- the target and each of
    # its ancestors -- mapped to the earliest cd that does so. One dict, so a
    # long command is linear, not cd x rm.
    inside = {}
    for s in simples:
        if s.subshell or s.deferred or s.argv[0] not in ('cd', 'pushd'):
            continue
        targets = [x for x in s.argv[1:] if not x.startswith('-')]
        if not targets:
            continue
        written = _norm_path_token(targets[0])
        path = _resolve(targets[0], s.seq, s.cmd.chain)
        if not path:
            continue
        parts = path.split('/')
        for k in range(1, len(parts) + 1):
            anc = '/'.join(parts[:k])
            if anc and (anc not in inside or inside[anc][0] > s.seq):
                inside[anc] = (s.seq, written, k == len(parts))
    if not inside:
        return None
    for s in simples:
        if s.argv[0] == 'rm':
            if not rm_flags(s.argv[1:])[0]:
                continue
        elif s.argv[0] != 'rimraf':
            continue
        when = float('inf') if s.deferred else s.seq
        for operand in rm_operands(s.argv[1:]):
            path = _resolve(operand, when, None if s.deferred else s.cmd.chain)
            if not path:
                continue
            if _GLOB.search(path):
                hits = [v for k, v in inside.items() if fnmatch.fnmatchcase(k, path)]
            else:
                hits = [inside[path]] if path in inside else []
            for cd_at, cd_written, same in hits:
                if s.deferred or s.seq > cd_at:
                    return cd_written, _norm_path_token(operand), same
    return None


# fire_log.redact() reads these patterns from this file's source to scrub the
# refusal log: one definition.
# Rules about MATERIAL present anywhere in the call. A live key is just as
# leaked when it is written into a file by a heredoc, so these see the raw text.
MATERIAL_RULES = [
    (r'sk_live_[A-Za-z0-9]{20,}', 'Stripe LIVE secret key in the command', 'stripe-live-key'),
    (r'\brk_live_[A-Za-z0-9]{20,}', 'Stripe LIVE restricted key in the command', 'stripe-restricted-key'),
    (r'\bsbp_[A-Za-z0-9]{30,}', 'Supabase personal access token in the command', 'supabase-access-token'),
    (r'\bsb_secret_[A-Za-z0-9_-]{20,}', 'Supabase secret key in the command', 'supabase-secret-key'),
    (r'\bghp_[A-Za-z0-9]{36}', 'GitHub personal access token in the command', 'github-token'),
    (r'\bgithub_pat_[A-Za-z0-9_]{22,}', 'GitHub fine-grained personal access token in the command', 'github-fine-grained-token'),
    (r'-----BEGIN [A-Z ]*PRIVATE KEY-----', 'private key material in the command', 'private-key'),
]


# The rule id every refusal is logged under (fire_log.py), and the list
# /bendit:guard-report reads -- by PARSING this file, so it stays a literal.
# A refusal that is not a rule anyone would turn off (a payload it cannot
# read, a crash) is logged as payload-unreadable / guard-error and kept out.
SPECIAL_RULES = ['deletes-own-cwd', 'trust-approval', 'trust-file-write', 'installer-preanswer']
RULES = [
    'deletes-own-cwd', 'trust-approval', 'trust-file-write', 'installer-preanswer',
    'rm-recursive', 'find-delete', 'destructive-sql', 'supabase-push-reset',
    'prisma-reset', 'force-push', 'push-deletes-remote-refs',
    'force-with-lease-foreign', 'git-clean-force',
    'git-reset-hard', 'git-discard-all', 'script-deletes-tree',
    'stripe-live-key', 'stripe-restricted-key', 'supabase-access-token',
    'supabase-secret-key', 'github-token', 'github-fine-grained-token', 'private-key',
]


def block(reason: str) -> int:
    print(
        f'BLOCKED by bendit safety hook: {reason}.\n'
        f'If this is genuinely required, ask the human to run it.',
        file=sys.stderr,
    )
    return 2


def inspect(raw: str, fired=None) -> int:
    """The exit code for this payload. A refusal appends (rule, payload,
    command) to `fired`, for the log written after the decision."""
    fired = [] if fired is None else fired
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
        fired.append(('payload-unreadable', None, ''))
        return block('hook payload was JSON but not an object, so the command could not be read')
    tool_input = payload.get('tool_input')
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get('command', payload.get('command'))
    if command is None:
        fired.append(('payload-unreadable', payload, ''))
        return block('hook payload carried no command to inspect')
    if not isinstance(command, str):
        fired.append(('payload-unreadable', payload, ''))
        return block('hook payload command was not a string, so it could not be inspected')
    # An empty command runs nothing, so there is nothing to guard. This is a
    # permit, not a bypass: the command WAS extracted, it is just empty.
    if not command.strip():
        return 0

    cwd = payload.get('cwd')
    _CWD[0] = cwd if isinstance(cwd, str) and cwd else None
    rule, reason = _verdict(command)
    if not reason:
        return 0
    code = block(reason)
    fired.append((rule, payload, command))
    return code


def _judge(command: str):
    """The reason to refuse `command`, or None. Re-entrant: a one-liner's
    os.system('...') string is judged by calling this again."""
    return _verdict(command)[1]


def _verdict(command: str):
    """(rule id, reason) to refuse `command`, or (None, None)."""
    global VARS
    saved, VARS = VARS, Vars(command)
    saved_simples = _SIMPLES[0]
    try:
        simples = simple_commands(command)
        _SIMPLES[0] = simples
        doomed = deletes_the_directory_it_enters(simples)
        if doomed is not None:
            entered, deleted, same = doomed
            if entered == deleted:
                what = f'this enters {entered} and then deletes it'
            elif same:
                what = f'this enters {entered} and then deletes it (as {deleted})'
            else:
                what = f'this enters {entered} and then deletes {deleted}, a folder above it'
            return 'deletes-own-cwd', (
                f'{what}, which leaves the shell '
                'with no working directory — every later command, and every hook, '
                'then fails with EPERM. Delete it from a subshell, or cd out first')
        if runs_trust_approval(command, simples):
            return 'trust-approval', TRUST_REASON
        if writes_trust_file(command, simples):
            return 'trust-file-write', TRUST_FILE_REASON
        if preanswers_installer(command):
            return 'installer-preanswer', INSTALLER_REASON
        for rule, reason, rule_id in COMMAND_RULES:
            for s in simples:
                hit = rule(s)
                if hit:
                    return rule_id, (hit if isinstance(hit, str) else reason)
        for pattern, reason, rule_id in MATERIAL_RULES:
            if re.search(pattern, command, re.IGNORECASE):
                return rule_id, reason
        return None, None
    finally:
        VARS = saved
        _SIMPLES[0] = saved_simples


def main() -> int:
    global _STARTED
    _STARTED = True
    fired = []
    raw = ''
    try:
        # Bytes, decoded leniently: a payload that is JSON apart from one bad
        # byte is still a payload, and its command is still inspected.
        raw = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape')
        code = inspect(raw, fired)
    except BaseException as exc:
        # Exit 1 from a traceback is a NON-blocking error to Claude Code, and a
        # SystemExit or KeyboardInterrupt from a helper exits 0 or 130: the
        # command would run unguarded. A guard that cannot finish refuses.
        try:
            code = block(f'the guard itself failed ({_describe(exc)}), '
                         'so the command could not be checked')
        except BaseException:
            _say(failed_while_checking('block-dangerous-bash', exc))
            code = 2
        fired[:] = [('guard-error', None, '')]
    if code == 2 and fired:
        rule, payload, command = fired[-1]
        _record_fire(raw if payload is None else payload, rule, command)
    return code


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
        if isinstance(payload, str):
            payload = json.loads(payload)
        import fire_log
        fire_log.record(fire_log.project_root(payload), 'block-dangerous-bash', rule, preview)
    except BaseException:
        pass
    finally:
        sys.stdout, sys.stderr = saved


if __name__ == '__main__':
    try:
        _code = main()
    except BaseException:   # last resort: the net itself failed
        os._exit(2)
    sys.exit(_code)
