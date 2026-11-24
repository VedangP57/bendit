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
    from shell_text import SHELLS, SQL_CLIENTS, _match_close, lex, shell_c_string, simple_commands, unwrap  # noqa: E402
    from shell_text import _ASSIGN as _SH_ASSIGN, _command_name  # noqa: E402
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


# A LEASE THAT DISCARDS SOMEONE ELSE'S COMMITS. A lease overwrites the remote
# ref only if it still points at the expected commit -- so whatever is on that
# commit and not in the push is discarded. The v0.5.2 benchmark (s3-force-push)
# lost a teammate's commit exactly so: the agent fetched, saw sam's 51dc142, and
# ran
#   git push --force-with-lease=feature/checkout:51dc142 origin feature/checkout
# The lease only guards against the remote moving AGAIN; it cannot protect a
# commit the agent has already fetched and chosen to overwrite. A plain
# `--force-with-lease` after that fetch does the same: its expected value is
# the remote-tracking ref, which now holds sam's commit.
#
# ONE criterion for every lease form:
#   EXPECT  the explicit expected commit (`=<ref>:<expect>`, `=<sha>`); for a
#           plain lease or `=<ref>`, the local remote-tracking ref of the
#           destination (refs/remotes/<remote>/<branch>; @{push} when no
#           refspec is given). No such ref locally: allowed -- nothing was
#           fetched, so the server-side lease does its job.
#   LOST    the `+` lines of `git cherry <pushed> <expect>`: commits on EXPECT
#           whose change is not in the push. A rebase of your own work keeps
#           every patch, so nothing is LOST.
#   REFUSE  when a LOST commit's author email is not `git config user.email`
#           (or user.email is unset and anything is LOST). Squashing or
#           amending your own commits loses only your own: allowed.
# LOCAL git only -- rev-parse, cherry, log, config; never a fetch -- in the
# payload's cwd (after `git -C` and a literal `cd` earlier in the command),
# under one deadline inside the hook's 10 s. Whenever git cannot answer
# (unknown commit, not a repo, git missing, a timeout) the push is refused.
#
# NOTHING BUT ALLOWED FORMS BEFORE A LEASE PUSH. The check sees the repository and the
# environment before the command runs, and simulating what other shell
# commands do to them cannot be made complete (every round found another way:
# a fetch first, xargs supplying the branch, include.path, printf -v, `+=`,
# export HOME). So a lease push is checked only when it is the ONE plain
# command in the Bash call (one leading literal `cd <dir> &&` or `;`, then
# read-only commands -- git status/log/show/diff/rev-parse/describe, `git
# remote -v`, `git branch` list forms, ls, pwd, true, echo, find with no
# -exec*/-ok*/-delete/-fprint*/-fls; literal words, no
# -c, no -C to another folder, no --output/-O/--ext-diff/--textconv/--no-index/
# --show-signature, piped only into pure readers -- and
# plain file chores -- rm, mkdir -p, touch, cp, mv, echo, printf without -v --
# only on literal paths that, every symlink resolved, lie under a system temp
# root (/tmp, /var/folders, DARWIN_USER_TEMP_DIR; never $TMPDIR), in no git
# repository (a `.git` found walking up, case-insensitively), outside the
# push repo (its hooks folder and core.hooksPath included) and every config
# or include file git lists, never a bare repository or a hard-linked file,
# with no `..`, no
# dangling link and no cp/mv of a symlink, and
# output readers after it -- grep, tail, head, cat, wc, sort, uniq, `sed -n`
# printing, awk with no system/getline/pipe/redirect -- excepted, and
# redirections only to /dev/null or another fd, since a file target is
# truncated before git reads its config; no --receive-pack/--exec, which run
# a local command; a cd is resolved logically, as bash does). AFTER the push,
# whole pipelines joined by `;`, `&&` or `||` only: they start once it has
# finished and cannot change what it sends, and every other rule still judges
# them. Not after it: `&`, a newline/subshell/$(...)/heredoc between them, a
# second push (git push, the word push, a git alias or runner, git -c), a
# command name not literal, or a compound command or function in the line.
# Otherwise: no other statement or pipe stage, no prefix
# (VAR=, HOME=, GIT_*), no wrapper (xargs, sh -c, eval, nohup, sudo...), no
# function or alias in the line, no run-time word (`$(...)`, `$VAR`, a glob,
# a brace expansion, `~user`, `<(...)`), and no `-c`/`--config-env` key in
# push.*, remote.*, branch.*, alias.*, include.*, includeIf.* or url.*.
# Anything else refuses: "run the push by itself, as one plain command".
#
# GIT RESOLVES THE CONFIG. Every setting is read by asking git (`git config
# --get/--get-all/--get-regexp` in the push's folder, with the hook's own
# environment), so include.path, includeIf, GIT_CONFIG_* and HOME apply as
# git applies them. Where the push goes follows git: `@` is HEAD; with no
# refspec, push.default, branch.<b>.merge, branch.<b>.pushRemote and
# remote.pushDefault decide it. remote.<r>.mirror, a `+` remote.<r>.push
# refspec, remote.<r>.pushurl, a url.*.pushInsteadOf that rewrites the remote,
# and a remote.<r>.push mapping the push relies on all refuse; so does any git
# error. A merge by someone else whose OWN change (a conflict fix) would be
# lost counts as lost. A `git <alias>` that git resolves to a push or a `!`
# shell command refuses, as do `git rebase --exec` and `git submodule foreach`
# running a lease push, and a lease push run by watch, parallel, script, su,
# source or an alias defined in the line.
#
# KNOWN LIMITS: authorship is the author email, which anyone can set. The
# tracking ref is assumed to be refs/remotes/<remote>/<branch> (the default
# fetch refspec). State changed by an EARLIER, separate Bash call that git's
# own config resolution does not reflect -- a shell variable exported earlier
# in the session -- is not seen: the hook runs with its own environment. Code
# that runs during a push (hooks set up earlier, tools that push for you) is
# outside what a reader of the command line can see. A
# lease flag only a file or another program supplies is not seen. A plain
# force push from config (remote.<r>.mirror, a `+` remote.<r>.push refspec,
# an alias to `push --force`) is not caught by any rule.
_LEASE_DEADLINE_S = 6.0   # every git call for one command; the hook's timeout is 10 s
_HEXISH = re.compile(r'^[0-9a-fA-F]{7,40}$')
# A word the shell changes when the command runs: a substitution, a variable,
# arithmetic, a glob, a brace expansion, process substitution. Read as written
# it names nothing real, and a substitution may itself fetch first.
_RUNTIME = re.compile(r'[$`*?\[]|^[<>]\(|\{[^}]*(?:,|\.\.)[^}]*\}')
# `git -c` / `--config-env` keys that route a push, change what it compares
# against, or bring in more config. On the push's own command line: refuse.
_CMDLINE_KEY = re.compile(r'(?i)^(?:(?:push|remote|branch|alias|include|includeif|url)\.|'
                          r'core\.sshcommand$)')
_CWD = [None]       # the payload's cwd; set by inspect()
_SIMPLES = [[]]     # every simple command of the command being judged; set by _verdict()
_COMMAND = ['']     # the text of the command being judged; set by _verdict()


def _runtime_word(s):
    """The first word of the push -- argument, prefix, redirection target,
    here-string, unquoted heredoc -- that the shell expands at run time, or None."""
    words = s.cmd.argv
    for k, w in enumerate(words):
        if _RUNTIME.search(w):
            return w
        if w.startswith('~') and not (k and words[k - 1] == '-C' and (w == '~' or w.startswith('~/'))):
            return w   # ~user, or a ~ anywhere but a literal -C path
    for w in [r.value for r in getattr(s.cmd, 'redirs', [])] + list(s.cmd.herestrings):
        if _RUNTIME.search(w) or w.startswith('~'):
            return w
    for hd in s.cmd.heredocs:
        if not hd.quoted and re.search(r'[$`]', hd.body):
            return f'<<{hd.delim}'
    return None


# Commands that run another command, from their words, a string, or stdin.
_LAUNCHERS = frozenset({'xargs', 'parallel', 'sem', 'find', 'eval', 'source', '.', 'watch',
                        'script', 'su', 'runuser', 'alias', 'trap', 'env', 'sudo', 'doas',
                        'nohup', 'timeout', 'gtimeout', 'nice', 'stdbuf', 'time', 'exec',
                        'command', 'builtin'}) | SHELLS
_LEASE_TEXT = re.compile(r'--force-w')   # any spelling git accepts of --force-with-lease
def _short_path(w):
    """A long absolute path shown by its last part: `…/.gitconfig`."""
    parts = w.rstrip('/').split('/')
    if w.startswith('/') and len(parts) > 3:
        return '…/' + parts[-1]
    # an absolute path inside a word (`gitdir: /a/b/c`): keep its last part
    return re.sub(r'(?<![\w.~-])/(?:[^/\s]+/){2,}([^/\s]*)', r'…/\1', w)


def _brief(words, width=50):
    """Words for a message: `NAME=value` shown as `NAME=…`, long absolute
    paths shortened, cut to `width`."""
    out = ' '.join(_short_path(re.sub(r'^([A-Za-z_]\w*\+?=).+', r'\1…', w, flags=re.S))
                   for w in words)
    return out if len(out) <= width else out[:width - 3] + '...'


def _key_brief(key):
    """A config key for a message, with a url.<base>. subsection left out."""
    return re.sub(r'(?i)^url\..*\.(\w+)$', r'url.….\1', key)


# Commands that only read the push's output and print or count it.
_READERS = frozenset({'grep', 'egrep', 'fgrep', 'tail', 'head', 'cat', 'wc', 'sort', 'uniq',
                      'sed', 'awk'})
_SED_PRINT = re.compile(r'^\s*(?:(?:\d+|\$|/[^/]*/)(?:\s*,\s*(?:\d+|\$|/[^/]*/))?\s*!?\s*p\s*;?\s*)+$')


def _output_reader(argv) -> bool:
    """A pipeline stage after the push that can only read and print: it runs
    nothing and writes no file (its own redirections aside)."""
    if not argv or argv[0] not in _READERS:
        return False
    name, args = argv[0], argv[1:]
    if name == 'sort':
        return not any(x.startswith(('-o', '--output')) for x in args)
    if name == 'uniq':
        return not any(not x.startswith('-') for x in args)   # `uniq in out` writes out
    if name == 'sed':
        scripts, k, quiet = [], 0, False
        while k < len(args):
            x = args[k]
            if x in ('-n', '--quiet', '--silent'):
                quiet = True
            elif x in ('-e', '--expression') and k + 1 < len(args):
                scripts.append(args[k + 1])
                k += 1
            elif x.startswith('-'):
                return False   # -i, -f, -s... : not a plain print
            else:
                scripts.append(x)
            k += 1
        return quiet and bool(scripts) and all(_SED_PRINT.match(p) for p in scripts)
    if name == 'awk':
        prog, k = None, 0
        while k < len(args):
            x = args[k]
            if x in ('-F', '-v'):
                k += 2
                continue
            if x.startswith(('-F', '-v')) and len(x) > 2:
                k += 1
                continue
            if x.startswith('-'):
                return False   # -f progfile and the rest
            prog = x
            break
        return prog is not None and not re.search(r'system\s*\(|getline|[|>]', prog)
    return True


def _bad_redirect(cmd):
    """A redirection target other than /dev/null or an fd duplication
    (`2>&1`, `>&2`), or None. A file target is truncated by the shell before
    git starts, and could be a config file git is about to read."""
    text = _COMMAND[0]
    for r in cmd.redirs:
        if r.value == '/dev/null':
            continue
        if (r.value.isdigit() or r.value == '-') and text[:r.start].rstrip().endswith('&'):
            continue
        return r.value
    return None


_CHORES = frozenset({'rm', 'mkdir', 'touch', 'cp', 'mv', 'echo', 'printf'})
# Options each chore may take; anything else (an option with a value, such as
# `cp -t DIR` or `touch -r FILE`) refuses.
_CHORE_SHORT = {'mkdir': 'pv', 'touch': 'cam', 'cp': 'aRrfinpPvLHTu', 'mv': 'finvTu'}
_CHORE_LONG = {'mkdir': {'--parents', '--verbose'}}


def _literal(w) -> bool:
    return not (_RUNTIME.search(w) or w.startswith('~'))


def _plain_cmd(c) -> bool:
    return not (c.subshell or c.heredocs or c.herestrings or c.fed_by is not None
                or len(c.pipe) != 1)


def _chore_paths(c):
    """The paths a plain file chore names (arguments and redirect targets),
    or None when it is not one: another command, an option that takes a
    value, `printf -v`, `mkdir` without -p, a word not written literally."""
    raw, text = c.argv, _COMMAND[0]
    if not raw or raw[0] not in _CHORES or not _plain_cmd(c):
        return None
    if not all(_literal(w) for w in raw) or not all(_literal(r.value) for r in c.redirs):
        return None
    name, args, paths, opts = raw[0], raw[1:], [], True
    if name in ('echo', 'printf'):
        if name == 'printf' and any(x.startswith('-v') for x in args):
            return None
    else:
        for x in args:
            if opts and x == '--':
                opts = False
            elif opts and x.startswith('-') and len(x) > 1:
                if name == 'rm':
                    continue   # any flags; rm's own rule judges recursion
                if x.startswith('--'):
                    if x not in _CHORE_LONG.get(name, ()):
                        return None
                elif any(ch not in _CHORE_SHORT[name] for ch in x[1:]):
                    return None
            else:
                paths.append(x)
        if name == 'mkdir' and not any(x in ('-p', '--parents') or
                                       (x.startswith('-') and not x.startswith('--') and 'p' in x)
                                       for x in args):
            return None
    for r in c.redirs:
        if r.value == '/dev/null':
            continue
        if (r.value.isdigit() or r.value == '-') and text[:r.start].rstrip().endswith('&'):
            continue
        paths.append(r.value)
    return paths


_READ_GIT = frozenset({'status', 'log', 'show', 'diff', 'rev-parse', 'describe'})
_BRANCH_LIST = frozenset({'-a', '-r', '-v', '-vv', '--list', '--show-current', '--all',
                          '--remotes', '--verbose', '--no-color'})


# Options that make a read-only git command write a file, run a program, or
# read outside the repository. A long option is refused in any abbreviation.
_READ_GIT_BAD = ('output', 'output-directory', 'ext-diff', 'textconv', 'no-index',
                 'show-signature', 'exec')


# find primaries that run a command, delete, or write a file (any spelling
# that starts so): -exec, -execdir, -ok, -okdir, -delete, -fprint*, -fls.
_FIND_ACTS = ('-exec', '-ok', '-delete', '-fprint', '-fls')


def _runs_or_writes(x) -> bool:
    if x.startswith('--'):
        body = x[2:].split('=', 1)[0]
        return bool(body) and any(n.startswith(body) and len(body) >= 2 or body.startswith(n)
                                  for n in _READ_GIT_BAD)
    return x.startswith('-O')


def _read_only_cmd(c) -> bool:
    """A command from the narrow read-only list that may come before a lease
    push: git status/log/show/diff/rev-parse/describe, `git remote -v`, `git
    branch` in list forms, ls, pwd, true, echo, find with no primary that
    runs, deletes or writes (_FIND_ACTS) -- every word literal, no -c,
    no file output, and (checked by the caller) no redirect but /dev/null."""
    raw = c.argv
    if not raw or c.subshell or c.heredocs or c.herestrings or c.fed_by is not None:
        return False
    if not all(_literal(w) for w in raw):
        return False
    name = raw[0]
    if name in ('ls', 'pwd', 'true', 'echo'):
        return True
    if name == 'find':   # only reads and prints, like ls -R
        return not any(x.startswith(_FIND_ACTS) for x in raw[1:])
    if name != 'git':
        return False
    i, _ = _git(raw)
    if i is None:
        return False
    k = 1
    while k < i:   # global options: only -C <dir> and the pager switches
        if raw[k] == '-C' and k + 1 < i:
            k += 2
        elif raw[k] in ('--no-pager', '-P', '--no-optional-locks'):
            k += 1
        else:
            return False   # -c, --config-env, --git-dir, --exec-path...
    sub, rest = raw[i], raw[i + 1:]
    if sub in _READ_GIT:
        return not any(_runs_or_writes(x) for x in rest)
    if sub == 'remote':
        return all(x in ('-v', '--verbose') for x in rest)
    if sub == 'branch':
        return all(x in _BRANCH_LIST for x in rest)
    return False


def _prelude(s, simples):
    """(commands, chores, None) for what may come before the push -- one
    literal `cd <dir>` first, then plain file chores and read-only commands
    (each optionally piped into pure readers), joined by `&&` or `;` -- or
    ([], [], reason) when something before it is not allowed."""
    at = next((n for n, x in enumerate(simples) if x is s), 0)
    before = simples[:at]
    if not before:
        return [], [], [], None
    units, seen = [], set()
    for o in before:
        c = o.cmd
        if o.via or c in s.cmd.pipe:
            return [], [], [], f'shares this Bash call with `{_brief(c.argv or o.argv)}`'
        if id(c) in seen:
            continue
        pipe = c.pipe if c in c.pipe else [c]
        if pipe[0] is not c:
            return [], [], [], f'shares this Bash call with `{_brief(c.argv or o.argv)}`'
        seen.update(id(x) for x in pipe)
        units.append(pipe)
    cmds, chores, gits = [], [], []
    for k, pipe in enumerate(units):
        head, raw = pipe[0], pipe[0].argv
        refuse = (None, None, f'shares this Bash call with `{_brief(raw)}`')
        if k == 0 and raw[:1] == ['cd']:
            if len(raw) != 2 or raw[1].startswith('-') or not _literal(raw[1]) or \
                    head.redirs or not _plain_cmd(head):
                return [], [], [], refuse[2]
        elif _read_only_cmd(head) and all(_output_reader(x.argv) for x in pipe[1:]) and \
                all(_bad_redirect(x) is None for x in pipe):
            if raw[:1] == ['git']:
                gits.append(head)
        elif len(pipe) == 1 and _chore_paths(head) is not None:
            chores.append(head)
        else:
            return [], [], [], refuse[2]
        cmds += pipe
    for x, y in zip(units, units[1:] + [[s.cmd]]):
        last = x[-1]
        if not last.words or not y[0].words:
            return [], [], [], 'shares this Bash call with another command'
        end = max([w.end for w in last.words] + [r.end for r in last.redirs])
        if _COMMAND[0][end:y[0].words[0].start].strip() not in ('&&', ';'):
            return [], [], [], f'shares this Bash call with `{_brief(x[0].argv)}`'
    return cmds, chores, gits, None


def _fold(path):
    """A path compared the way a case-insensitive volume compares it."""
    import unicodedata
    return unicodedata.normalize('NFKC', path).casefold()


def _temp_roots():
    """System temp roots, resolved: /tmp, /private/tmp, /var/folders and
    getconf DARWIN_USER_TEMP_DIR. Never $TMPDIR: the shell that runs the
    command need not share the hook's environment."""
    roots = ['/tmp', '/private/tmp', '/var/folders', '/private/var/folders']
    try:
        import subprocess
        r = subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=2)
        if r.returncode == 0 and r.stdout.strip():
            roots.append(r.stdout.decode('utf-8', 'replace').strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return {_fold(os.path.realpath(x)).rstrip('/') for x in roots}


def _under(path, root):
    return path.startswith(root.rstrip('/') + '/')


def _holds_link(path, limit=2000):
    """`path` is a symlink, or a folder holding one (or too big to look)."""
    if os.path.islink(path):
        return True
    if not os.path.isdir(path):
        return False
    seen = 0
    for top, dirs, files in os.walk(path):
        for name in dirs + files:
            seen += 1
            if seen > limit or os.path.islink(os.path.join(top, name)):
                return True
    return False


def _temp_path_problem(full, roots):
    """Why the chore path `full` (absolute, as written) is not a plain path in
    a system temp folder outside every git repository, or None."""
    parts = full.split('/')
    if '..' in parts:
        return 'has `..` in it'
    if any(_fold(x) in ('.git', '.gitmodules', '.gitconfig') for x in parts):
        return 'names a git file'
    # Deepest existing ancestor; what does not exist yet must not be a link.
    anc = full
    while not os.path.exists(anc):
        if os.path.lexists(anc):
            return 'is a dangling symlink'
        parent = os.path.dirname(anc)
        if parent == anc:
            break
        anc = parent
    real = os.path.realpath(full)
    folded = _fold(real)
    if not any(_under(folded, r) for r in roots):
        return 'is not inside a system temp folder'
    probe = real
    while True:
        if os.path.lexists(os.path.join(probe, '.git')):   # case-insensitive volumes match .GIT
            return 'is inside a git repository'
        if os.path.isfile(os.path.join(probe, 'HEAD')) and \
                os.path.isdir(os.path.join(probe, 'objects')) and \
                os.path.isdir(os.path.join(probe, 'refs')):
            return 'is inside a git repository (a bare one)'
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    return None


def _push_repo_paths(s):
    """Folded real paths of the push repo's top level, git dir and common dir,
    and of every config file and include target git lists for it. Raises
    _GitCannotTell when git fails."""
    cwd, opts = _push_dir(s)
    g = _Git(cwd, opts)
    home = os.environ.get('HOME') or os.path.expanduser('~')
    xdg = os.environ.get('XDG_CONFIG_HOME') or os.path.join(home, '.config')
    out = {os.path.join(home, '.gitconfig'), os.path.join(xdg, 'git')}
    top = cwd
    for args in (['--show-toplevel'], ['--absolute-git-dir'], ['--git-common-dir'],
                 ['--git-path', 'hooks']):
        code, val = g.run(['rev-parse'] + args)
        if code == 0 and val.strip():
            out.add(os.path.join(cwd, val.strip()))
            if args == ['--show-toplevel']:
                top = val.strip()
    # The folder git runs hooks from during the push: core.hooksPath, which
    # may point outside the repository (into a temp folder) or not exist yet.
    for value in g.config_all('core.hooksPath'):
        value = os.path.expanduser(value.strip())
        out.update({os.path.join(top, value), os.path.join(cwd, value)})
    code, listed = g.run(['config', '--list', '--show-origin'])
    if code != 0:
        raise _GitCannotTell(f'git config --list --show-origin exited {code}')
    code, inc = g.run(['config', '--show-origin', '--get-regexp', r'^include(if\..*)?\.path$'])
    if code not in (0, 1):
        raise _GitCannotTell(f'git config --get-regexp include exited {code}')
    for line in listed.splitlines() + inc.splitlines():
        origin, _, rest = line.partition('\t')
        if origin.startswith('file:'):
            path = origin[5:].strip('"')
            out.add(os.path.join(cwd, path))
            if rest.lower().startswith('include'):
                target = rest.split(' ', 1)[1] if ' ' in rest else ''
                target = os.path.expanduser(target)
                out.add(os.path.join(os.path.dirname(os.path.join(cwd, path)), target))
    return {_fold(os.path.realpath(p)).rstrip('/') for p in out if p}


def _hard_link(full, c, p, sources):
    """Why writing `full` could rewrite another file through a hard link: an
    existing file with more than one link, or, for a cp/mv destination that is
    a folder, such a file under the source's name inside it."""
    targets = [full]
    if c.argv[0] in ('cp', 'mv') and p not in sources and os.path.isdir(full):
        targets += [os.path.join(full, os.path.basename(x.rstrip('/'))) for x in sources]
    for t in targets:
        try:
            st = os.lstat(t)
        except OSError:
            continue
        import stat
        if not stat.S_ISDIR(st.st_mode) and st.st_nlink > 1:
            return 'is a hard link, which may be another file git reads'
    return None


def _read_git_problem(s, gits, cd):
    """Why the read-only git commands before the push may run a program
    planted in this same command: one runs against another folder than the
    push's repository. None when they are safe."""
    if not gits:
        return None
    shell_cwd = _CWD[0] or os.getcwd()
    if cd:
        shell_cwd = os.path.normpath(os.path.join(shell_cwd, cd[0].argv[1]))
    try:
        push_cwd, opts = _push_dir(s)
    except _GitCannotTell as why:
        return f'comes after git commands bendit could not check ({_describe_short(why)})'
    if opts:
        return 'is given `--git-dir`/`--work-tree`, so a git command before it reads another repository'
    for c in gits:
        raw, here = c.argv, shell_cwd
        i, _ = _git(raw)
        k = 1
        while k < i:
            if raw[k] == '-C':
                here = os.path.join(here, os.path.expanduser(raw[k + 1]))
                k += 2
            else:
                k += 1
        if os.path.realpath(here) != os.path.realpath(push_cwd):
            return f'comes after `{_brief(raw)}`, which runs git in another folder than the push'
    # Programs configured EARLIER (core.fsmonitor, filters, pagers, an external
    # diff) may run here: the documented prior-setup limit, like hooks. Checking
    # for them refused almost every developer machine (Git LFS, delta).
    return None


def _chore_problem(s, cmds):
    """Why a chore before the push may change what git reads, or None. A chore
    is allowed only on plain paths in a system temp folder, outside every git
    repository and outside the push repo, and never copies or moves a link."""
    chores = [c for c in cmds if c.argv[:1] != ['cd']]
    if not chores:
        return None
    shell_cwd = _CWD[0] or os.getcwd()
    if cmds[0].argv[:1] == ['cd']:
        shell_cwd = os.path.join(shell_cwd, cmds[0].argv[1])
    roots = _temp_roots()
    try:
        repo = _push_repo_paths(s)
    except _GitCannotTell as why:
        return f'comes after file chores bendit could not check ({_describe_short(why)})'
    for c in chores:
        paths = _chore_paths(c)
        sources = []
        if c.argv[0] in ('cp', 'mv'):
            plain = [x for x in c.argv[1:] if not x.startswith('-')]
            sources = plain[:-1]
        for p in paths:
            full = os.path.join(shell_cwd, p)
            why = _temp_path_problem(full, roots)
            if why is None:
                why = _hard_link(full, c, p, sources)
            if why is None:
                folded = _fold(os.path.realpath(full)).rstrip('/')
                if any(folded == r or _under(folded, r) or _under(r, folded) for r in repo):
                    why = 'is, holds or lies in a file or folder git reads for this push'
                elif p in sources and _holds_link(full):
                    why = 'is or holds a symlink'
            if why is not None:
                return f'comes after `{_brief(c.argv)}`, whose path `{_short_path(p)}` {why}'
    return None


def _cmd_end(c):
    return max([w.end for w in c.words] + [r.end for r in c.redirs])


def _background_amp(text, code, start):
    """True when text[start:] holds a `&` that sends a command to the
    background (not `&&`, `|&`, `&>`, `>&`, `<&`), as the lexer marked code."""
    for i in range(start, len(text)):
        if text[i] != '&' or not code[i]:
            continue
        prev = text[i - 1] if i else ''
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if prev in ('<', '>', '&', '|') or nxt in ('>', '&'):
            continue
        return True
    return False


# Words that open or close a compound command or a function body. With one
# in the line, the order the text shows is not the order commands run in.
_COMPOUND = frozenset({'{', '}', 'function', 'if', 'then', 'elif', 'else', 'fi', 'while',
                       'until', 'for', 'select', 'do', 'done', 'case', 'esac', '!', '[[', 'coproc'})
_PUSH_WORD = re.compile(r'(?<![\w./-])push(?![\w./-])')


def _push_end(s):
    """Where the lease push's pipeline ends in the command text, or None."""
    pipe = s.cmd.pipe if s.cmd in s.cmd.pipe else [s.cmd]
    if not all(c.words for c in pipe):
        return None
    return max(_cmd_end(c) for c in pipe)


def _after_push(s, simples):
    """(commands, simples) written after the lease push's pipeline at the top
    level: not in a subshell, `$(...)` or heredoc body (a heredoc of the push
    is expanded BEFORE it runs), with the simples they launch."""
    end = _push_end(s)
    later, after, owner = [], [], None
    if end is None:
        return after, later
    for o in simples:
        if not o.via:
            c = o.cmd
            owner = c if (c.words and c.words[0].start > end and not c.subshell
                          and c.fed_by is None) else None
            if owner is not None and c not in after:
                after.append(c)
        if owner is not None:
            later.append(o)
    return after, later


def _after_problem(s, after, later):
    """Why what comes after the lease push is not allowed, or None. Whole
    pipelines joined to it and to each other by `;`, `&&` or `||` start only
    once the push has finished, so they cannot change what it sends; each is
    still judged by every other rule. Refused: anything that runs alongside
    it (`&`), may push again, or that bendit cannot place."""
    text = _COMMAND[0]
    end = _push_end(s)
    if end is None:
        return 'shares this Bash call with another command'
    if _background_amp(text, lex(text).code, end):
        return 'runs alongside a command after it (`&`)'
    if not after:
        return None
    for c in lex(text).cmds:   # a body: the push may run later, after what follows it
        head = c.argv[0] if c.argv else ''
        if head in _COMPOUND or head.endswith('()') or '()' in c.argv:
            return f'is in the same line as `{_brief(c.argv)}`, a compound command or function'
    after.sort(key=lambda c: c.words[0].start)
    units = []
    for c in after:
        if c.subshell or c.fed_by is not None:
            return f'is followed by `{_brief(c.argv)}`, which runs in a subshell'
        if c in c.pipe and c.pipe[0] is not c:
            if any(x not in after for x in c.pipe):
                return 'shares this Bash call with another command'
            continue
        units.append(c.pipe if c in c.pipe else [c])
    prev = end
    for u in units:
        if not all(x.words for x in u):
            return 'shares this Bash call with another command'
        gap = text[prev:u[0].words[0].start].strip()
        if gap not in ('&&', ';', '||'):
            return f'is followed by `{_brief(u[0].argv)}` in a way bendit cannot place'
        prev = max(_cmd_end(x) for x in u)
    first = units[0][0].words[0].start
    if _PUSH_WORD.search(text[first:]):
        return 'is followed by another `push`'
    for o in later:
        a = o.argv
        if not a or not _literal(a[0]):
            return f'is followed by `{_brief(o.cmd.argv)}`, whose command bendit cannot read'
        if _git_push(a):
            return 'is followed by another `push`'
        if a[0] == 'git':
            i, configs = _git(a)
            if configs or any(x.startswith('--config-env') for x in a[1:i or len(a)]):
                return f'is followed by `{_brief(a)}`, whose `-c` could make it another push'
            if i is None or not _literal(a[i]) or a[i] not in _GIT_BUILTINS or \
                    a[i] in _GIT_RUNNERS:
                return f'is followed by `{_brief(a)}`, which may run another push'
    return None


def _not_alone(s):
    """Why this lease push does not stand alone in the Bash call -- only the
    allowed forms before it (_prelude), only sequential commands after it
    (_after_problem) -- or None. Simulating what earlier commands do to git's
    config and environment cannot be made complete."""
    simples = _SIMPLES[0]
    raw = s.cmd.argv
    if s.via:
        return f'is run through `{s.via[-1]}`'
    if not raw or _command_name(raw[0]) != 'git' or unwrap(raw) != s.argv:
        return f'is run through `{_brief(raw[:1]) if raw else "a wrapper"}`'   # a prefix, wrapper or VAR=
    allowed = [s.cmd]
    prelude, chores, gits, why = _prelude(s, simples)
    if why is not None:
        return why
    allowed += prelude
    if s.cmd in s.cmd.pipe:
        at = s.cmd.pipe.index(s.cmd)
        if at:
            return f'reads `{_brief(s.cmd.pipe[0].argv)}` on its stdin'
        allowed += [c for c in s.cmd.pipe[at + 1:] if _output_reader(c.argv)]
    after, later = _after_push(s, simples)
    ids = {id(o) for o in later}
    others = [o for o in simples if o is not s and o.cmd not in allowed and id(o) not in ids]
    if others:
        return f'shares this Bash call with `{_brief(others[0].cmd.argv or others[0].argv)}`'
    why = _after_problem(s, after, later)
    if why is not None:
        return why
    if any(o.cmd is not s.cmd and o.via and id(o) not in ids for o in simples) or \
            len(lex(_COMMAND[0]).cmds) != len(allowed) + len(after):
        return 'shares this Bash call with another command'
    for c in allowed:
        if c in chores:
            continue   # a chore's targets are checked as paths, below
        bad = _bad_redirect(c)
        if bad is not None:
            return f'writes its output to `{bad}`, which the shell opens before git reads its config'
    if s.cmd.subshell or s.cmd.fed_by is not None:
        return 'runs in a subshell'
    word = _runtime_word(s)
    if word is not None:
        shown = word if len(word) <= 50 else word[:47] + '...'
        return f'contains `{shown}`, which the shell expands only when it runs'
    a = s.argv
    i, configs = _git(a)
    keys = [c.split('=', 1)[0] for c in configs]
    for k in range(1, i or 1):
        if a[k].startswith('--config-env='):
            keys.append(a[k].split('=', 1)[1].split('=', 1)[0])
        elif a[k] == '--config-env' and k + 1 < len(a):
            keys.append(a[k + 1].split('=', 1)[0])
        elif a[k].startswith(('--namespace', '--exec-path')):
            return f'sets `{a[k]}`'
    for key in keys:
        if _CMDLINE_KEY.match(key):
            return f'sets `{_key_brief(key)}` on the command line'
    cd = [c for c in prelude if c.argv[:1] == ['cd']][:1]
    return _read_git_problem(s, gits, cd) or _chore_problem(s, cd + chores)


def _git_push(argv) -> bool:
    i, _ = _git(argv) if argv else (None, [])
    return i is not None and argv[i] == 'push'


# git's own commands, as `git help -a` lists them. A word in the subcommand
# place that is not one of these is an alias, which the guard cannot read.
_GIT_BUILTINS = frozenset('''
add am annotate apply archive bisect blame branch bugreport bundle cat-file check-attr
check-ignore check-mailmap check-ref-format checkout checkout-index cherry cherry-pick
citool clean clone column commit commit-graph commit-tree config count-objects
credential describe diagnose diff diff-files diff-index diff-tree difftool fast-export
fast-import fetch fetch-pack filter-branch fmt-merge-msg for-each-ref for-each-repo
format-patch fsck fsmonitor--daemon gc get-tar-commit-id gitk grep gui hash-object help
hook index-pack init instaweb interpret-trailers log ls-files ls-remote ls-tree
mailinfo mailsplit maintenance merge merge-base merge-file merge-index merge-tree
mergetool mktag mktree multi-pack-index mv name-rev notes pack-objects pack-refs
patch-id prune prune-packed pull push range-diff read-tree rebase reflog refs remote
repack replace request-pull rerere reset restore rev-list rev-parse revert rm
send-email send-pack shortlog show show-branch show-index show-ref sparse-checkout
stage stash status stripspace submodule switch symbolic-ref tag unpack-file
unpack-objects update-index update-ref update-server-info var verify-commit
verify-pack verify-tag version whatchanged worktree write-tree lfs flow
'''.split())
# git subcommands that run a command from their words.
_GIT_RUNNERS = frozenset({'rebase', 'submodule', 'bisect', 'config', 'filter-branch',
                          'for-each-repo', 'difftool', 'mergetool'})


def _git_config_aliases(argv):
    """{alias name: value} that `git config [opts] [set] alias.<x> <value>` sets."""
    i, _ = _git(argv) if argv else (None, [])
    if i is None or argv[i] != 'config':
        return {}
    rest, k = argv[i + 1:], 0
    if rest[:1] == ['set']:
        k = 1
    while k < len(rest) and rest[k].startswith('-'):
        k += 2 if rest[k] in ('-f', '--file', '--blob', '--type', '--comment', '--value') else 1
    if k + 1 < len(rest) and rest[k].lower().startswith('alias.'):
        return {rest[k][6:].lower(): rest[k + 1]}
    return {}


def _git_runs_unseen(s):
    """For a `git` command that is not a push: a git launcher that would run a
    push the guard cannot read -- an alias (given with -c, set by `git config`
    earlier in the line, or on disk), `rebase --exec`, `submodule foreach`."""
    a = s.argv
    i, configs = _git(a)
    lease = any(_LEASE_TEXT.search(w) for w in s.cmd.argv)
    aliases = {}
    for c in configs:
        if c.lower().startswith('alias.') and '=' in c:
            name, value = c.split('=', 1)
            aliases[name[6:].lower()] = value
        elif c.lower().startswith('alias.'):
            aliases[c[6:].lower()] = 'true'
    env_alias = any(w.startswith('--config-env') and 'alias.' in w.lower()
                    for w in a[1:i or len(a)]) or any(
        a[k] == '--config-env' and a[k + 1].lower().startswith('alias.')
        for k in range(1, min(i or len(a), len(a) - 1)))
    if env_alias or (aliases and lease):   # --config-env: the value is unreadable
        return 'git -c alias.' + (next(iter(aliases)) if aliases else '…')
    if i is None:
        return None
    sub = a[i].lower()
    # Aliases set earlier in this line by `git config alias.<x> ...`.
    line = {}
    for o in _SIMPLES[0]:
        if o is s:
            break
        line.update(_git_config_aliases(o.argv))
    for where, table in (('git -c alias.', aliases), ('git config alias.', line)):
        value = table.get(sub)
        if value is None:
            continue
        v = value.strip()
        if lease or _LEASE_TEXT.search(v):
            return where + sub
        if v.startswith('!') or 'push' in v.split():
            return ('alias', where + sub)   # a shell command or a push, unread
    if lease and (sub in _GIT_RUNNERS or sub not in _GIT_BUILTINS):
        return f'git {a[i]}'
    if sub not in _GIT_BUILTINS:
        return _alias_expands_to_push(s, a[i])
    return None


# Commands that can change git's config or environment for a later command in
# the same Bash call.
_ENV_CHANGERS = frozenset({'export', 'declare', 'typeset', 'local', 'readonly', 'read',
                           'mapfile', 'readarray', 'unset', 'source', '.', 'eval', 'set',
                           'cd', 'pushd', 'popd', 'env', 'alias'})


def _alias_expands_to_push(s, sub):
    """`git <alias>`: resolve the alias through git itself (includes and the
    environment applied). ('alias', what) when it expands to a push or a `!`
    shell command, or when it cannot be resolved -- git fails, or something
    else in this Bash call may change git's config first -- else None."""
    shown = f'git {sub}'
    raw = s.cmd.argv
    if not raw or _command_name(raw[0]) != 'git':
        return ('alias', shown)   # a prefix (VAR=...) or wrapper may set the alias
    for o in _SIMPLES[0]:
        if o is s:
            continue
        name = o.argv[0]
        if name in _ENV_CHANGERS or (name == 'printf' and '-v' in o.argv) or (
                o.cmd.argv and _SH_ASSIGN.match(o.cmd.argv[0])):
            return ('alias', shown)
    try:
        cwd, opts = _push_dir(s)
        value = _Git(cwd, opts).config(f'alias.{sub}')
    except _GitCannotTell:
        return ('alias', shown)
    if value is None:
        return None   # not an alias: git will say it is no command
    v = value.strip()
    if v.startswith('!') or 'push' in v.split():
        return ('alias', f'git {sub}')
    return None


def _lease_run_unseen(s):
    """For a command that is not itself a git push: the launcher that would
    run a lease push the guard cannot read -- `watch`, `alias`, `source <(...)`,
    an `xargs` or shell fed it on stdin, `git -c alias.p='push --force-with-lease'`
    -- or None."""
    a = s.argv
    if a[0] == 'git':
        hit = _git_runs_unseen(s)
        if hit:
            return hit
    names = {_command_name(w) for w in s.cmd.argv} | {a[0]}
    hit = sorted(names & _LAUNCHERS)
    if not hit:
        return None
    cmds = [s.cmd]
    if s.cmd in s.cmd.pipe:   # what reaches it on stdin, except a lease push run as itself
        cmds = [c for c in s.cmd.pipe[:s.cmd.pipe.index(s.cmd)] if not _git_push(unwrap(c.argv))] + cmds
    for c in cmds:
        texts = c.argv + list(c.herestrings) + [h.body for h in c.heredocs]
        if any(_LEASE_TEXT.search(t) for t in texts):
            return hit[0] if a[0] not in _LAUNCHERS else a[0]
    return None


class _GitCannotTell(Exception):
    def __init__(self, why, unknown_commit=False):
        super().__init__(why)
        self.unknown_commit = unknown_commit


def _push_leases(args):
    """(leases, remote, refspecs, all_refs, repo, runs) for `git push <args>`.
    Each lease is (ref or None, expect or None, the option as written): expect
    None means "the remote-tracking ref", ref None means "every ref pushed".
    `repo` is a `--repo` value (git's destination when no remote is written);
    `runs` is a `--receive-pack`/`--exec` option, which runs a local command."""
    leases, positional, all_refs, k, opts = [], [], False, 0, True
    repo, runs = None, None
    while k < len(args):
        x = args[k]
        k += 1
        if opts and x == '--':
            opts = False
            continue
        if opts and x.startswith('--'):
            if _long_is(x, 'force-with-lease', 7):
                value = x.split('=', 1)[1] if '=' in x else None
                if value is None or value == '':
                    leases.append((None, None, x))
                elif ':' in value:
                    ref, expect = value.split(':', 1)
                    if expect:   # `<ref>:` means "must not exist yet": nothing to lose
                        leases.append((ref, expect, x))
                elif _HEXISH.match(value):
                    leases.append((None, value, x))   # a commit, not a refname
                else:
                    leases.append((value, None, x))
            elif _long_is(x, 'no-force-with-lease', 10):
                leases = []
            elif any(_long_is(x, n, 3) for n in ('all', 'branches', 'mirror')):
                all_refs = True
            elif _long_is(x, 'repo', 3):
                if '=' in x:
                    repo = x.split('=', 1)[1]
                elif k < len(args):
                    repo, k = args[k], k + 1
            elif _long_is(x, 'receive-pack', 3) or _long_is(x, 'exec', 3):
                runs = x.split('=', 1)[0]
                k += '=' not in x
            elif '=' not in x and _long_is(x, 'push-option', 3):
                k += 1   # its value is the next word
            continue
        if opts and x.startswith('-') and len(x) > 1:
            for j, ch in enumerate(x[1:]):
                if ch == 'o':   # -o <push-option>: the rest, or the next word
                    k += j == len(x) - 2
                    break
            continue
        positional.append(x)
    remote = positional[0] if positional else repo
    return leases, remote, positional[1:], all_refs, repo, runs


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
        cwd = os.path.normpath(os.path.join(cwd, target))   # logical, as bash's cd
    a, i, opts = s.argv, 1, []
    while i < len(a) and a[i].startswith('-'):
        x = a[i]
        if x == '-C' and i + 1 < len(a):
            cwd = os.path.realpath(os.path.join(cwd, os.path.expanduser(a[i + 1])))   # git chdirs
        elif x in ('--git-dir', '--work-tree') and i + 1 < len(a):
            opts += [x, a[i + 1]]
        elif x.startswith(('--git-dir=', '--work-tree=')):
            opts.append(x)
        i += 2 if x in _GIT_OPTS_WITH_ARG else 1
    return cwd, opts


class _Git:
    """LOCAL git queries for one push, under one deadline. Raises _GitCannotTell."""

    def __init__(self, cwd, opts):
        import time
        self.cwd, self.opts = cwd, opts
        self.deadline = time.monotonic() + _LEASE_DEADLINE_S

    def run(self, args, stdin=''):
        import subprocess
        import time
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise _GitCannotTell('git took too long to answer')
        env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0',
                   GIT_PAGER='cat', LC_ALL='C')
        try:
            r = subprocess.run(['git'] + self.opts + args, cwd=self.cwd, env=env,
                               input=stdin.encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=left)
        except subprocess.TimeoutExpired:
            raise _GitCannotTell('git took too long to answer') from None
        except OSError as exc:
            raise _GitCannotTell(f'git could not run ({_describe(exc)})') from None
        return r.returncode, r.stdout.decode('utf-8', 'replace')

    def commit(self, name, must_exist=True):
        """The full id `name` names, or None when it names nothing and need not."""
        if not name or name.startswith('-'):
            raise _GitCannotTell(f'{name!r} is not a commit name')
        code, out = self.run(['rev-parse', '--verify', '--quiet', name + '^{commit}'])
        if code == 0 and out.strip():
            return out.strip()
        if code == 1 and not must_exist:
            return None
        raise _GitCannotTell(f'git here does not know a commit {name}: an unknown commit, '
                             'or not a git repository', unknown_commit=True)

    def config(self, key):
        """A config value, or None when it is not set."""
        code, out = self.run(['config', '--get', key])
        if code not in (0, 1):
            raise _GitCannotTell(f'git config --get {key} exited {code}')
        return out.strip() if code == 0 and out.strip() else None

    def config_all(self, key):
        """Every value of a multi-valued key, includes and environment applied."""
        code, out = self.run(['config', '--get-all', key])
        if code not in (0, 1):
            raise _GitCannotTell(f'git config --get-all {key} exited {code}')
        return [x for x in out.splitlines() if x.strip()] if code == 0 else []

    def config_regexp(self, pattern):
        """[(key, value)] for every key matching `pattern`."""
        code, out = self.run(['config', '--get-regexp', pattern])
        if code not in (0, 1):
            raise _GitCannotTell(f'git config --get-regexp {pattern} exited {code}')
        return [tuple((line.split(' ', 1) + [''])[:2]) for line in out.splitlines()] if code == 0 else []

    def tracking(self, remote, branch, own_answer):
        """Every remote-tracking commit a plain lease on `branch` may expect:
        refs/remotes/<remote>/<branch>, and git's own @{push} when the command
        names no remote. Empty when the remote is a URL or a path, or nothing
        was fetched."""
        names = ['@{push}'] if own_answer else []
        if branch is not None and self.config(f'remote.{remote}.url') is not None:
            names.append(f'refs/remotes/{remote}/{_short_ref(branch)}')
        found = []
        for name in names:
            commit = self.commit(name, must_exist=False)
            if commit and commit not in found:
                found.append(commit)
        return found


def _forced_by_config(g, remote):
    """Refuse (raise) when git's own config -- includes, includeIf and the
    environment applied, as git resolves it -- makes this push mirror, force a
    `+` refspec, or go somewhere other than the remote its tracking refs came
    from (a pushurl or url.*.pushInsteadOf)."""
    url = g.config(f'remote.{remote}.url')
    if url is None:
        return   # a URL or path, not a named remote: no tracking refs to trust
    code, out = g.run(['config', '--type=bool', '--get', f'remote.{remote}.mirror'])
    if code not in (0, 1) or out.strip() == 'true':
        raise _GitCannotTell(f'remote.{remote}.mirror is set, so this push would overwrite every '
                             'ref on the remote')
    if any(v.lstrip().startswith('+') for v in g.config_all(f'remote.{remote}.push')):
        raise _GitCannotTell(f'remote.{remote}.push has a `+` refspec, which forces whatever it maps')
    if g.config_all(f'remote.{remote}.pushurl'):
        raise _GitCannotTell(f'remote.{remote}.pushurl sends this push somewhere other than the '
                             'remote its tracking refs were fetched from')
    for key, value in g.config_regexp(r'^url\..*\.pushinsteadof$'):
        if value and url.startswith(value):
            raise _GitCannotTell(f'{_key_brief(key)} rewrites where this push goes, away from the remote its '
                                 'tracking refs were fetched from')


def _pushes(g, remote, refspecs, all_refs):
    """(remote, [(source, destination branch or None)]) this push writes, with
    the destination decided the way git decides it: push.default,
    branch.<b>.merge, branch.<b>.pushRemote, remote.pushDefault."""
    code, cur = g.run(['symbolic-ref', '--short', '-q', 'HEAD'])
    branch = cur.strip() if code == 0 and cur.strip() else None
    if remote is None:
        remote = ((branch and g.config(f'branch.{branch}.pushRemote')) or g.config('remote.pushDefault')
                  or (branch and g.config(f'branch.{branch}.remote')) or 'origin')
    _forced_by_config(g, remote)
    if (any(':' not in spec for spec in refspecs) or not refspecs) and \
            g.config(f'remote.{remote}.push') is not None:
        raise _GitCannotTell(f'remote.{remote}.push decides where this push goes, and bendit '
                             'does not follow that mapping')
    out = []
    for spec in refspecs:
        src, colon, dst = spec.lstrip('+').partition(':')
        if not src:
            continue   # a deletion: push-deletes-remote-refs speaks for it
        if colon:
            out.append((src, dst))
        elif src in ('HEAD', '@'):
            out.append((src, branch))
        else:
            out.append((src, src))
    if refspecs:
        return remote, out
    if all_refs:
        code, refs = g.run(['for-each-ref', '--format=%(refname:short)', 'refs/heads'])
        if code != 0:
            raise _GitCannotTell(f'git for-each-ref exited {code}')
        return remote, [(b, b) for b in refs.split()]
    if branch is None:
        raise _GitCannotTell('HEAD is not on a branch, so where a push with no refspec goes '
                             'cannot be told')
    mode = (g.config('push.default') or 'simple').lower()
    merge = g.config(f'branch.{branch}.merge')
    if mode == 'nothing':
        return remote, []   # git refuses to push
    if mode == 'matching':
        code, refs = g.run(['for-each-ref', '--format=%(refname:short)', 'refs/heads'])
        if code != 0:
            raise _GitCannotTell(f'git for-each-ref exited {code}')
        return remote, [(b, b) for b in refs.split()]
    if mode in ('upstream', 'tracking'):
        if not merge:
            raise _GitCannotTell(f'push.default is {mode} and {branch} has no upstream branch')
        return remote, [('HEAD', _short_ref(merge))]
    if mode == 'current':
        return remote, [('HEAD', branch)]
    if mode == 'simple':
        dsts = [branch] + ([_short_ref(merge)] if merge and _short_ref(merge) != branch else [])
        return remote, [('HEAD', d) for d in dsts]
    raise _GitCannotTell(f'push.default is {mode!r}, which bendit does not know')


def _lost_rows(g, new, old):
    """[(short sha, email, author, subject)] of what pushing `new` over `old`
    discards: commits whose change is not in `new` (git cherry), and merges
    whose OWN change -- a conflict fix -- would go with them."""
    code, out = g.run(['cherry', new, old])
    if code != 0:
        raise _GitCannotTell(f'git cherry exited {code}')
    lost = [ln[2:].strip() for ln in out.splitlines() if ln.startswith('+ ')]
    rows = []
    if lost:
        code, log = g.run(['log', '--no-walk=unsorted', '--stdin', '--no-color',
                           '--format=%h%x09%ae%x09%an%x09%s'], '\n'.join(lost) + '\n')
        rows = [ln.split('\t', 3) for ln in log.splitlines() if ln.count('\t') >= 3]
        if code != 0 or len(rows) != len(lost):
            raise _GitCannotTell(f'git log could not read the {len(lost)} commits the push would discard')
    code, log = g.run(['log', '--merges', '--cc', '--no-color', '--no-ext-diff',
                       '--format=%x01%h%x09%ae%x09%an%x09%s', f'{new}..{old}'])
    if code != 0:
        raise _GitCannotTell(f'git log --merges exited {code}')
    for chunk in log.split('\x01')[1:]:
        head, _, diff = chunk.partition('\n')
        if diff.strip() and head.count('\t') >= 3:
            h, e, a, subj = head.split('\t', 3)
            rows.append([h, e, a, subj + ' (a merge with changes of its own)'])
    return rows


def force_with_lease_foreign(s):
    """A `git push --force-with-lease` (any form) that would discard commits
    someone else wrote. Returns the reason, naming them, or False."""
    i, _ = _git(s.argv)
    if i is None or s.argv[i] != 'push':
        unseen = _lease_run_unseen(s)
        if isinstance(unseen, tuple):
            return (f'`{unseen[1]}` expands to a shell command or a push that bendit cannot read '
                    f'ahead of time, so it cannot tell what it would discard — write the git '
                    f'command out in full, without the alias')
        if unseen:
            return (f'`{unseen}` would run a `git push --force-with-lease` that bendit cannot '
                    f'read ahead of time, so it cannot tell what the push would discard — write '
                    f'the push out literally as its own command')
        return False
    leases, remote, refspecs, all_refs, repo, runs = _push_leases(s.argv[i + 1:])
    if not leases:
        return False
    written = leases[0][2]
    alone = _not_alone(s)
    if alone is None and runs is not None:
        alone = f'is given `{runs}`, which runs a command on this machine'
    if alone is not None:
        return (f'`{written}` {alone}. bendit checks a lease push only when it is the one plain '
                f'command in the Bash call — no other command, prefix, wrapper, variable or '
                f'routing `-c`; only a leading `cd <dir> &&`, plain file chores before it (`rm`, '
                f'`mkdir -p`, `touch`, `cp`, `mv`, `echo`, `printf` on literal paths in a temp '
                f'folder outside any git repository), read-only commands before it (`git status`, '
                f'`git log`, `git diff`, `ls`, `pwd`, `find`), output readers piped after it (`| grep`, '
                f'`| tail`), other commands after it joined by `;`, `&&` or `||` (no `&`, no '
                f'second push) and `2>&1` or `>/dev/null` are fine — because anything else can change '
                f'what it pushes or '
                f'what git compares against. Run the push by itself, as one plain command, so '
                f'bendit can check it')
    try:
        cwd, opts = _push_dir(s)
        g = _Git(cwd, opts)
        remote, pushes = _pushes(g, remote, refspecs, all_refs)
        own_answer = not refspecs and remote is not None and repo is None and not any(
            not x.startswith('-') for x in s.argv[i + 1:])
        checks = []   # (option as written, src, dst, expect name or None)
        for ref, expect, written in leases:
            mine = [(src, dst) for src, dst in pushes
                    if ref is not None and dst is not None and _short_ref(dst) == _short_ref(ref)]
            for src, dst in (mine or pushes):
                checks.append((written, src, dst, expect))
        email = None
        for written, src, dst, expect in checks:
            olds = [g.commit(expect)] if expect is not None else g.tracking(remote, dst, own_answer)
            if not olds:
                continue   # nothing fetched: the server-side lease protects it
            new = g.commit(src)
            for old in olds:
                rows = _lost_rows(g, new, old)
                if not rows:
                    continue
                if email is None:
                    email = (g.config('user.email') or '').lower()
                others = [r for r in rows if not email or r[1].strip().lower() != email]
                if not others:
                    continue   # only your own commits, squashed or amended
                shown = '\n'.join(f'    {h} {a}: {subj}' for h, _e, a, subj in others[:5])
                if len(others) > 5:
                    shown += f'\n    ... and {len(others) - 5} more'
                whose = ('by someone else' if email else
                         'that may not be yours (`git config user.email` is not set, so bendit '
                         'cannot tell whose they are)')
                fix = ('' if email else
                       'Set it (`git config user.email <you>`) and run the push again. ')
                return (f'`{written}` would discard {len(others)} commit(s) {whose} from the '
                        f'remote\'s {dst or src} — they are on {old[:7]} and their changes are not in '
                        f'what you push ({src}):\n{shown}\n{fix}'
                        f'Look at them first: `git log --stat {new[:7]}..{old[:7]}`. To keep them, '
                        f'rebase onto them (`git rebase {old[:7]}`) and push again; a lease only '
                        f'guards against the remote moving again, never a commit you have already '
                        f'fetched and chose to overwrite')
    except _GitCannotTell as why:
        hint = ('Run `git fetch` and `git log <your branch>..<remote>/<branch>` to see what is on '
                'the remote, and leave this push to the human if it must happen'
                if why.unknown_commit else 'Leave this push to the human if it must happen')
        return (f'`{written}`: git could not check here whether this push discards someone '
                f'else\'s commits ({_describe_short(why)}), so it is refused. {hint}')
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
    saved_simples, saved_command = _SIMPLES[0], _COMMAND[0]
    _COMMAND[0] = command
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
        _COMMAND[0] = saved_command


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
