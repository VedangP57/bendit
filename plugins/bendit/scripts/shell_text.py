#!/usr/bin/env python3
"""Shell text helpers shared by the PreToolUse guards.

One implementation, because guards reading the same command text must agree
about what counts as executable. block-zsh-wordsplit.py matched inside quoted
heredoc bodies while block-dangerous-bash.py did not, so writing a bash TEST
SCRIPT that legitimately contains an unquoted loop over a variable was refused
-- that text was destined for a file, not for this shell, and under bash it is
correct. Duplicating the stripper into the second guard would let the two
drift apart again.

This is a small shell LEXER rather than a line regex, because a regex over raw
text cannot do any of this:

  * `<<'X'` was honoured anywhere on a line, including inside a quoted string
    or a `#` comment, so `echo "<<'X'"` hid every line below it from all three
    guards.
  * a quoted heredoc body was always treated as data, even when it was fed to
    `bash`, `sh -s` or `psql` -- where it is the program.
  * a destructive command was only seen right after a separator, so `sudo rm`,
    `env rm`, `bash -c 'rm ...'`, `xargs rm` and a dozen other spellings passed.

What it understands: words and quoting ('...', "...", $'...', backslash),
separators (; & | && || |& newline), ( ) and { } groups, $( ), backticks,
<( ) / >( ), ${ }, $(( )), comments, redirections, here-strings and heredocs
(quoted or not, <<- included). It does NOT expand anything: `$T` stays the
literal text `$T`. Everything it cannot parse it treats as code, because
scanning more text can only refuse more -- the safe direction for a guard.

Known gaps, deliberately not chased: `case` patterns (a `)` there ends a
group early), `${ }` holding a `$( )`, nested backticks, aliases and
functions defined earlier in the same command, and commands hidden behind
variables (`$RM -rf x`) -- no static reader can see those.
"""
import re
import shlex
from typing import Iterable, Iterator, List, NamedTuple, Optional

SHELLS = frozenset({'sh', 'bash', 'zsh', 'dash', 'ksh', 'mksh', 'ash', 'fish'})
SQL_CLIENTS = frozenset({'psql', 'mysql', 'mariadb', 'sqlite3'})

# Words that open or continue a compound command. Stripped from the front of a
# simple command so `if rm -rf x; then` and `{ rm -rf x; }` are read as `rm`.
_RESERVED = frozenset({'!', '{', '}', 'then', 'do', 'else', 'elif', 'if',
                       'while', 'until', 'done', 'fi', 'esac', 'coproc'})
_ASSIGN = re.compile(r'[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=')
_FUNC_HEADER = re.compile(r'[\w.:-]+\(\)$')
_REDIR = re.compile(r'(\d+|\{\w+\})?(<<<|<<-|<<|&>>|&>|>>|>&|<&|>\||<>|>|<)')

# Commands that run the rest of their arguments as another command.
# name -> (options that take a separate argument, positional args to skip,
#          options that mean "do not run anything")
_WRAPPERS = {
    'sudo': ({'-u', '-g', '-h', '-p', '-C', '-D', '-r', '-t', '-T', '-U',
              '--user', '--group', '--host', '--prompt', '--chdir', '--role',
              '--type', '--close-from', '--other-user', '--command-timeout'},
             0, {'-e', '-l', '-v', '-V', '-K', '--edit', '--list', '--validate'}),
    'doas': ({'-u', '-C'}, 0, set()),
    'env': ({'-u', '-C', '-S', '--unset', '--chdir', '--split-string'}, 0, set()),
    'command': (set(), 0, {'-v', '-V'}),
    'builtin': (set(), 0, set()),
    'exec': ({'-a'}, 0, set()),
    'time': (set(), 0, set()),
    'nohup': (set(), 0, set()),
    'nice': ({'-n', '--adjustment'}, 0, set()),
    'ionice': ({'-c', '-n', '-p', '-P', '-u', '--class', '--classdata'}, 0, set()),
    'timeout': ({'-s', '-k', '--signal', '--kill-after'}, 1, set()),
    'gtimeout': ({'-s', '-k', '--signal', '--kill-after'}, 1, set()),
    'stdbuf': ({'-i', '-o', '-e'}, 0, set()),
    'xargs': ({'-I', '-L', '-n', '-P', '-s', '-d', '-E', '-a', '--arg-file',
               '--delimiter', '--max-args', '--max-procs', '--max-lines',
               '--max-chars', '--eof', '--process-slot-var'}, 0, set()),
    'noglob': (set(), 0, set()),
    'nocorrect': (set(), 0, set()),
    'chronic': (set(), 0, set()),
    'caffeinate': ({'-w', '-t'}, 0, set()),
    'npx': ({'-p', '--package', '-c', '--call'}, 0, set()),
    'pnpx': ({'-p', '--package'}, 0, set()),
    'bunx': ({'-p', '--package'}, 0, set()),
}

# Package managers run a bin when the next word is not one of their own
# subcommands -- `pnpm supabase db reset` runs supabase. `pnpm rm` is pnpm's
# REMOVE, so builtins are never unwrapped.
_PACKAGE_MANAGERS = frozenset({'pnpm', 'yarn', 'npm', 'bun'})
_PM_RUNNERS = frozenset({'exec', 'dlx', 'x'})
_PM_OPTS_WITH_ARG = frozenset({'-C', '--dir', '--filter', '-F', '--prefix',
                               '--cwd', '--workspace'})
_PM_BUILTINS = frozenset({
    'add', 'install', 'i', 'ci', 'remove', 'rm', 'uninstall', 'un', 'update',
    'up', 'upgrade', 'link', 'ln', 'unlink', 'run', 'run-script', 'test', 't',
    'start', 'stop', 'restart', 'publish', 'pack', 'init', 'create', 'why',
    'list', 'ls', 'outdated', 'audit', 'config', 'c', 'store', 'env', 'dedupe',
    'prune', 'rebuild', 'rb', 'import', 'patch', 'patch-commit', 'info',
    'view', 'global', 'cache', 'set', 'workspace', 'workspaces', 'licenses',
    'bin', 'root', 'help', 'login', 'logout', 'version', 'node', 'setup',
    'deploy', 'fetch', 'doctor', 'owner', 'tag', 'server', 'plugin', 'self-update',
})


class Word(NamedTuple):
    value: str   # quotes removed, nothing expanded
    start: int   # span in the lexed text
    end: int


class Heredoc:
    __slots__ = ('delim', 'quoted', 'dash', 'cmd', 'body', 'body_start',
                 'body_end', 'closed', 'is_code')

    def __init__(self, delim, quoted, dash, cmd):
        self.delim, self.quoted, self.dash, self.cmd = delim, quoted, dash, cmd
        self.body = ''
        self.body_start = self.body_end = -1
        self.closed = False
        self.is_code = True


class Cmd:
    """One simple command as written: its words and what is attached to it."""
    __slots__ = ('words', 'seq', 'subshell', 'pipe', 'heredocs', 'herestrings',
                 'cond', 'chain', 'redirs')

    def __init__(self, seq, subshell, pipe, cond=False, chain=0):
        self.words: List[Word] = []
        self.seq = seq
        self.subshell = subshell
        self.pipe = pipe
        # Runs only on some paths: after `&&`/`||` in its list, or inside an
        # if/while/until/for/case body. An assignment here may not happen.
        self.cond = cond
        # Commands joined only by `&&` share a chain id: each runs only if
        # every earlier one in the chain did.
        self.chain = chain
        self.heredocs: List[Heredoc] = []
        self.herestrings: List[str] = []
        # The target word of each redirection (`2>"$F"`), quotes removed,
        # nothing expanded. Heredoc delimiters are in heredocs instead.
        self.redirs: List[Word] = []

    @property
    def argv(self):
        return [w.value for w in self.words]


class Lexed(NamedTuple):
    text: str
    cmds: List[Cmd]
    heredocs: List[Heredoc]
    code: bytearray   # 1 where the character is shell code at THIS level


def _match_close(t, i, end, open_ch, close_ch):
    """Index just past the close matching t[i] == open_ch, skipping quotes."""
    depth = 0
    while i < end:
        c = t[i]
        if c == '\\':
            i += 2
            continue
        if c in '\'"':
            j = t.find(c, i + 1, end)
            i = end if j == -1 else j + 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return end


class _Lexer:
    def __init__(self, text: str, keep_for: Iterable[str]):
        self.t = text
        self.n = len(text)
        self.code = bytearray(self.n)
        self.cmds: List[Cmd] = []
        self.heredocs: List[Heredoc] = []
        self.pending: List[Heredoc] = []
        self.seq = 0
        self.chains = 0
        self.keep_for = frozenset(keep_for)

    # -- words ---------------------------------------------------------------
    def _mark(self, a, b):
        for k in range(max(a, 0), min(b, self.n)):
            self.code[k] = 1

    def read_dquote(self, i, end):
        """From just past an opening `"`: (index past the close, value) or None."""
        t, buf = self.t, []
        while i < end:
            c = t[i]
            if c == '"':
                return i + 1, ''.join(buf)
            if c == '\\' and i + 1 < end:
                nxt = t[i + 1]
                if nxt == '\n':
                    pass
                elif nxt in '$`"\\':
                    buf.append(nxt)
                else:
                    buf.append('\\' + nxt)
                i += 2
                continue
            if t.startswith('$((', i):
                j = _match_close(t, i + 1, end, '(', ')')
                buf.append(t[i:j])
                i = j
                continue
            if t.startswith('$(', i):
                self._mark(i, i + 2)
                j = self.lex(i + 2, end, ')', True)
                buf.append(t[i:j])
                i = j
                continue
            if c == '`':
                j = self.backtick(i, end)
                buf.append(t[i:j])
                i = j
                continue
            if t.startswith('${', i):
                j = _match_close(t, i + 1, end, '{', '}')
                buf.append(t[i:j])
                i = j
                continue
            buf.append(c)
            i += 1
        return None

    def backtick(self, i, end):
        """t[i] is a backtick: lex up to the closing one, return index past it."""
        t = self.t
        j = i + 1
        while j < end and t[j] != '`':
            j += 2 if t[j] == '\\' else 1
        self._mark(i, i + 1)
        close = min(j, end)
        self.lex(i + 1, close, None, True)
        if close < end:
            self._mark(close, close + 1)
            return close + 1
        return end

    def read_word(self, i, end):
        """Read one shell word at i. Returns (value, index past it, quoted)."""
        t, buf, quoted, start = self.t, [], False, i
        while i < end:
            c = t[i]
            if c in ' \t\n;&|<>)':
                break
            if c == '(':
                if i == start:
                    break
                # `name()` or `arr=(a b)`: part of this word, not a subshell.
                j = _match_close(t, i, end, '(', ')')
                self._mark(i, j)
                buf.append(t[i:j])
                i = j
                continue
            if c == '\\':
                quoted = True
                if i + 1 < end and t[i + 1] != '\n':
                    buf.append(t[i + 1])
                self._mark(i, i + 2)
                i += 2
                continue
            if c == "'" or t.startswith("$'", i):
                q = i + (2 if c == '$' else 1)
                j = q
                while j < end and t[j] != "'":
                    j += 2 if (c == '$' and t[j] == '\\') else 1
                if j >= end:
                    # Unterminated: an ordinary character, so the rest is still
                    # scanned rather than swallowed.
                    self._mark(i, i + 1)
                    buf.append(c)
                    i += 1
                    continue
                buf.append(t[q:j])
                quoted = True
                i = j + 1
                continue
            if c == '"':
                got = self.read_dquote(i + 1, end)
                if got is None:
                    self._mark(i, i + 1)
                    buf.append(c)
                    i += 1
                    continue
                i, val = got
                buf.append(val)
                quoted = True
                continue
            if c == '`':
                j = self.backtick(i, end)
                buf.append(t[i:j])
                i = j
                continue
            if t.startswith('$((', i):
                j = _match_close(t, i + 1, end, '(', ')')
                self._mark(i, j)
                buf.append(t[i:j])
                i = j
                continue
            if t.startswith('$(', i):
                self._mark(i, i + 2)
                j = self.lex(i + 2, end, ')', True)
                buf.append(t[i:j])
                i = j
                continue
            if t.startswith('${', i):
                j = _match_close(t, i + 1, end, '{', '}')
                self._mark(i, j)
                buf.append(t[i:j])
                i = j
                continue
            self.code[i] = 1
            buf.append(c)
            i += 1
        return ''.join(buf), i, quoted

    # -- heredoc bodies ------------------------------------------------------
    def read_bodies(self, i, end):
        """At the start of the line after heredoc openers: consume each body."""
        t = self.t
        pending, self.pending = self.pending, []
        for hd in pending:
            ls = i
            term = None
            while ls < end:
                le = t.find('\n', ls, end)
                le = end if le == -1 else le
                line = t[ls:le]
                # Lenient terminator matching ends the body sooner, which scans
                # more text, not less -- the safe direction to be wrong in.
                cand = line.strip() if hd.dash else line.rstrip()
                if cand == hd.delim:
                    term = (ls, le)
                    break
                ls = le + 1
            if term is None:
                # Fails closed: no terminator, so the rest is lexed as code.
                return i
            hd.body_start, hd.body_end = i, term[0]
            hd.body = t[i:term[0]]
            hd.closed = True
            receivers = hd.cmd.pipe[hd.cmd.pipe.index(hd.cmd):] if hd.cmd in hd.cmd.pipe else [hd.cmd]
            fed_to = {(unwrap(c.argv) or [''])[0] for c in receivers}
            # A QUOTED delimiter means bash expands nothing in the body: it is
            # data -- unless the command reading it is itself an interpreter
            # the caller cares about, in which case it is the program.
            hd.is_code = (not hd.quoted) or bool(fed_to & self.keep_for)
            if hd.is_code:
                self.lex(i, term[0], None, True)
            i = term[1] + 1 if term[1] < end else end
        return i

    # -- commands ------------------------------------------------------------
    def lex(self, i, end, closer, subshell):
        """Lex t[i:end]. With closer ')', stop past the matching paren."""
        t = self.t
        self.chains += 1
        state = {'cur': None, 'pipe': [], 'andor': False, 'chain': self.chains}

        def cur():
            if state['cur'] is None:
                c = Cmd(self.seq, subshell, state['pipe'], state['andor'],
                        state['chain'])
                self.seq += 1
                state['pipe'].append(c)
                self.cmds.append(c)
                state['cur'] = c
            return state['cur']

        def end_cmd(new_pipe=True, andor=False, same_chain=False):
            state['cur'] = None
            if new_pipe:
                state['pipe'] = []
                state['andor'] = andor
                if not same_chain:
                    self.chains += 1
                    state['chain'] = self.chains

        while i < end:
            c = t[i]
            if c == '\\' and i + 1 < end and t[i + 1] == '\n':
                i += 2
                continue
            if c in ' \t\r':
                i += 1
                continue
            if c == '\n':
                end_cmd()
                i += 1
                if self.pending:
                    i = self.read_bodies(i, end)
                continue
            if c == '#':
                j = t.find('\n', i, end)
                i = end if j == -1 else j
                continue
            if c == ')':
                self.code[i] = 1
                end_cmd()
                if closer == ')':
                    return i + 1
                i += 1
                continue
            if c == '(':
                self.code[i] = 1
                if t.startswith('((', i):
                    j = _match_close(t, i, end, '(', ')')
                    self._mark(i, j)
                    i = j
                    continue
                end_cmd()
                i = self.lex(i + 1, end, ')', True)
                continue
            if t.startswith('&&', i) or t.startswith('||', i) or t.startswith(';;', i):
                self._mark(i, i + 2)
                end_cmd(andor=t[i] != ';', same_chain=t.startswith('&&', i))
                i += 2
                continue
            if t.startswith('|&', i):
                self._mark(i, i + 2)
                end_cmd(new_pipe=False)
                i += 2
                continue
            if c == '|':
                self.code[i] = 1
                end_cmd(new_pipe=False)
                i += 1
                continue
            if c == ';' or (c == '&' and not t.startswith('&>', i)):
                self.code[i] = 1
                end_cmd()
                i += 1
                continue
            if c in '<>' and i + 1 < end and t[i + 1] == '(':
                # Process substitution: a command whose output is an argument.
                self._mark(i, i + 2)
                start = i
                i = self.lex(i + 2, end, ')', True)
                cmd = cur()
                cmd.words.append(Word(t[start:i], start, i))
                continue
            m = _REDIR.match(t, i)
            if m and m.end() <= end and (m.group(1) is None or c in '0123456789{'):
                op = m.group(2)
                self._mark(i, m.end())
                cmd = cur()
                j = m.end()
                while j < end and t[j] in ' \t':
                    j += 1
                if j >= end or t[j] in '\n;&|)':
                    i = j
                    continue
                if t[j] in '<>' and j + 1 < end and t[j + 1] == '(':
                    i = j   # `2> >(cmd)`: the target is a process substitution, lexed next
                    continue
                val, j2, quoted = self.read_word(j, end)
                if op in ('<<', '<<-'):
                    hd = Heredoc(val, quoted, op == '<<-', cmd)
                    cmd.heredocs.append(hd)
                    self.heredocs.append(hd)
                    self.pending.append(hd)
                elif op == '<<<':
                    cmd.herestrings.append(val)
                else:
                    cmd.redirs.append(Word(val, j, j2))
                i = max(j2, j + 1) if j2 == j else j2
                continue
            start = i
            val, i, _quoted = self.read_word(i, end)
            if i == start:   # defensive: never loop without progress
                self.code[i] = 1
                i += 1
                continue
            cur().words.append(Word(val, start, i))
        return end


def lex(text: str, keep_for: Iterable[str] = SHELLS) -> Lexed:
    """Lex a command. A quoted heredoc body is lexed as code only when the
    command reading it is in keep_for; an unquoted body always is."""
    lx = _Lexer(text, keep_for)
    lx.lex(0, len(text), None, False)
    _mark_compound_bodies(lx.cmds)
    return Lexed(text, lx.cmds, lx.heredocs, lx.code)


_OPENERS = frozenset({'if', 'while', 'until', 'for', 'select', 'case'})
_CLOSERS = frozenset({'fi', 'done', 'esac'})


def _mark_compound_bodies(cmds):
    """Set .cond on every command inside an if/while/until/for/case: whether
    it runs depends on a test. Read from each command's first word, which is
    where this lexer leaves a reserved word (`then D=1` is one Cmd)."""
    depth = 0
    for c in cmds:
        argv = c.argv
        first = argv[0] if argv else ''
        if first in _OPENERS:
            depth += 1
            c.cond = True
            continue
        if depth:
            c.cond = True
        if first in _CLOSERS:
            depth = max(depth - 1, 0)


def strip_quoted_heredocs(command: str, keep_for: Iterable[str] = SHELLS) -> str:
    """Remove the body of every quoted heredoc that is data, keeping every other line.

    Why: `cat > notes.ts <<'EOF'` whose body held the markdown span
    `rm -rf /` was once blocked -- the backtick in the body satisfied a separator.
    Only lines strictly between the opener's line and the terminator are
    dropped, so a command on the opener line, on the terminator's line, or
    after the heredoc ends is still scanned.

    Openers are found by the lexer, so `<<'X'` inside quotes or a
    comment is not one; and a body fed to a command in keep_for (by default
    any shell) is the program, so it is kept.

    Fails closed: if no terminator is found the rest is left intact.
    """
    lexed = lex(command, keep_for)
    cuts = sorted((h.body_start, h.body_end) for h in lexed.heredocs
                  if h.closed and not h.is_code)
    if not cuts:
        return command
    out, prev = [], 0
    for a, b in cuts:
        out.append(command[prev:a])
        prev = b
    out.append(command[prev:])
    return ''.join(out)


def code_mask(command: str, keep_for: Iterable[str] = SHELLS) -> bytearray:
    """1 for every character this shell reads as code: not inside quotes, a
    comment, or a heredoc body that is data. `$( )` inside double quotes IS
    code. Positions match `command`."""
    return lex(command, keep_for).code


# -- what actually runs -------------------------------------------------------

def _command_name(word: str) -> str:
    name = word.rsplit('/', 1)[-1] if '/' in word.rstrip('/') else word
    # `supabase@latest` from a package runner names the bin `supabase`.
    return re.sub(r'(?<=.)@[^/]*$', '', name)


def _skip_options(a, i, with_arg, stop=frozenset()):
    """From a[i], step over options. Returns the new index, or None to stop."""
    while i < len(a):
        x = a[i]
        if x == '--':
            return i + 1
        if not x.startswith('-') or x == '-':
            return i
        if x in stop:
            return None
        i += 2 if x in with_arg else 1
    return i


def unwrap(argv: List[str]) -> List[str]:
    """The command that actually runs, with wrappers and prefixes removed.

    `sudo -u x env FOO=1 nohup /bin/rm -rf y` -> ['rm', '-rf', 'y'].
    Returns [] for a bare assignment. A wrapper used in a way that runs nothing
    (`command -v rm`, `sudo -l`) is returned as itself.
    """
    a = list(argv)
    for _ in range(32):
        if not a:
            return a
        w = a[0]
        if w in _RESERVED or _FUNC_HEADER.fullmatch(w):
            a = a[1:]
            continue
        if w == 'function':
            a = a[2:]
            continue
        if _ASSIGN.match(w):
            a = a[1:]
            continue
        name = _command_name(w)
        if name == 'env':
            split = _env_split_string(a)
            if split is not None:
                a = split
                continue
        if name in ('docker', 'podman', 'nerdctl', 'docker-compose', 'kubectl', 'oc'):
            inner = _container_exec(name, a)
            if inner is None:
                return [name] + a[1:]
            a = inner
            continue
        if name in _WRAPPERS:
            with_arg, positional, stop = _WRAPPERS[name]
            i = _skip_options(a, 1, with_arg, stop)
            if i is None:
                return [name] + a[1:]
            a = a[i + positional:]
            continue
        if name in _PACKAGE_MANAGERS:
            i = _skip_options(a, 1, _PM_OPTS_WITH_ARG)
            if i is None or i >= len(a):
                return [name] + a[1:]
            sub = a[i]
            if sub in _PM_RUNNERS:
                j = _skip_options(a, i + 1, {'-p', '--package', '-c', '--call'})
                a = a[j:] if j is not None else []
                continue
            if name in ('pnpm', 'yarn') and sub not in _PM_BUILTINS:
                a = a[i:]
                continue
            return [name] + a[1:]
        return [name] + a[1:]
    return a


# Container runners: `docker exec [opts] CTR cmd...`, `docker compose exec
# [opts] SVC cmd...`, `kubectl exec [opts] POD -- cmd...`. The inner argv is
# a command like any other -- `docker exec db psql -c "DROP TABLE x"` drops the
# table -- so every rule must see it. Only `exec` is unwrapped: `docker run`
# has too many options taking values to find its command reliably.
_DOCKER_GLOBAL_WITH_ARG = frozenset({'-H', '--host', '--context', '-c', '--config',
                                     '-l', '--log-level', '--tlscacert',
                                     '--tlscert', '--tlskey'})
_COMPOSE_GLOBAL_WITH_ARG = frozenset({'-f', '--file', '-p', '--project-name',
                                      '--profile', '--env-file', '--ansi',
                                      '--project-directory', '--parallel',
                                      '--progress'})
_EXEC_WITH_ARG = frozenset({'-e', '--env', '--env-file', '-u', '--user', '-w',
                            '--workdir', '--detach-keys', '--index'})
_KUBECTL_WITH_ARG = frozenset({'-n', '--namespace', '--context', '--cluster',
                               '--kubeconfig', '-s', '--server', '--user',
                               '-c', '--container', '-f', '--filename',
                               '--pod-running-timeout', '--as', '--token'})


def _container_exec(name, a):
    """The argv a container runner executes, or None if it runs nothing we
    can name (not `exec`, or no command after the target)."""
    if name in ('docker', 'podman', 'nerdctl', 'docker-compose'):
        if name == 'docker-compose':
            i = _skip_options(a, 1, _COMPOSE_GLOBAL_WITH_ARG)
        else:
            i = _skip_options(a, 1, _DOCKER_GLOBAL_WITH_ARG)
            if i is not None and i < len(a) and a[i] == 'compose':
                i = _skip_options(a, i + 1, _COMPOSE_GLOBAL_WITH_ARG)
        if i is None or i >= len(a) or a[i] != 'exec':
            return None
        i = _skip_options(a, i + 1, _EXEC_WITH_ARG)
        if i is None or i + 1 >= len(a):
            return None
        return a[i + 1:]   # past the container / service name
    if name in ('kubectl', 'oc'):
        i = _skip_options(a, 1, _KUBECTL_WITH_ARG)
        if i is None or i >= len(a) or a[i] != 'exec':
            return None
        rest = a[i + 1:]
        if '--' in rest:
            return rest[rest.index('--') + 1:] or None
        j = _skip_options(rest, 0, _KUBECTL_WITH_ARG)
        if j is None or j + 1 >= len(rest):
            return None
        return rest[j + 1:]
    return None


def _env_split_string(a):
    """`env -S 'rm -rf x'` / `env --split-string=...`: the argv env runs, with
    the split string in front of whatever follows it. None without -S."""
    i = 1
    while i < len(a):
        x = a[i]
        if x in ('-S', '--split-string'):
            if i + 1 >= len(a):
                return None
            text, i = a[i + 1], i + 2
        elif x.startswith('--split-string='):
            text, i = x.split('=', 1)[1], i + 1
        elif x.startswith('-S'):
            text, i = x[2:], i + 1
        elif x.startswith('-') and x != '-' and x != '--':
            i += 2 if x in ('-u', '-C', '--unset', '--chdir') else 1
            continue
        else:
            return None
        try:
            words = shlex.split(text)
        except ValueError:
            words = text.split()
        return words + a[i:]
    return None


class Simple(NamedTuple):
    argv: List[str]       # after unwrap(); argv[0] is a bare command name
    cmd: Cmd              # the lexed command it came from
    seq: int              # execution order at the top level
    subshell: bool        # runs in a child: a cd here moves nothing
    deferred: bool        # inside a trap body: runs at exit


def shell_c_string(argv: List[str]) -> Optional[str]:
    """The string `bash -c STRING` runs, or None."""
    i = 1
    while i < len(argv):
        x = argv[i]
        if x in ('-o', '+o', '-O', '+O', '--init-file', '--rcfile'):
            i += 2
            continue
        if x.startswith('-') and not x.startswith('--') and 'c' in x[1:]:
            # `bash -c -- 'script'`: `--` ends the options; the string follows.
            j = i + 2 if argv[i + 1:i + 2] == ['--'] else i + 1
            return argv[j] if j < len(argv) else None
        if x.startswith('-') or x.startswith('+'):
            i += 1
            continue
        return None
    return None


def _reads_stdin_script(argv):
    """A shell with no -c and no script file runs what arrives on stdin."""
    i = 1
    while i < len(argv):
        x = argv[i]
        if x in ('-o', '+o', '-O', '+O'):
            i += 2
            continue
        if x.startswith('-') or x.startswith('+'):
            i += 1
            continue
        return False
    return shell_c_string(argv) is None


def _exec_groups(argv):
    i = 1
    while i < len(argv):
        if argv[i] in ('-exec', '-execdir', '-ok', '-okdir'):
            j = i + 1
            while j < len(argv) and argv[j] not in (';', '+'):
                j += 1
            yield argv[i + 1:j]
            i = j + 1
            continue
        i += 1


def _expand(cmd, words, seq, subshell, deferred, depth) -> Iterator[Simple]:
    argv = unwrap(words)
    if not argv:
        return
    yield Simple(argv, cmd, seq, subshell, deferred)
    if depth > 6:
        return
    name = argv[0]

    def nested(text, sub, dfr=deferred):
        yield from simple_commands(text, _seq=seq, _subshell=sub,
                                   _deferred=dfr, _depth=depth + 1)

    if name in SHELLS:
        s = shell_c_string(argv)
        if s is not None:
            yield from nested(s, True)
        for hs in cmd.herestrings:
            yield from nested(hs, True)
        if _reads_stdin_script(argv) and cmd in cmd.pipe:
            for up in cmd.pipe[:cmd.pipe.index(cmd)]:
                up_argv = unwrap(up.argv)
                if up_argv and up_argv[0] in ('echo', 'printf'):
                    args = [x for x in up_argv[1:] if not x.startswith('-')]
                    yield from nested('\n'.join(args), True)
    elif name == 'eval':
        yield from nested(' '.join(argv[1:]), subshell)
    elif name == 'trap' and len(argv) > 1 and not argv[1].startswith('-'):
        yield from nested(argv[1], subshell, True)
    elif name == 'find':
        for group in _exec_groups(argv):
            yield from _expand(cmd, group, seq, True, deferred, depth + 1)
    elif name not in ('echo', 'printf'):
        # A runner this module does not know (`docker exec c sh -c ...`,
        # `hc exec -- sh -c ...`) handing a shell a string: the string is code.
        for i in range(1, len(argv)):
            if _command_name(argv[i]) in SHELLS:
                s = shell_c_string(argv[i:])
                if s is not None:
                    yield from nested(s, True)
                    break


def simple_commands(text: str, *, _seq=None, _subshell=False, _deferred=False,
                    _depth=0) -> List[Simple]:
    """Every command this text would run, wrappers removed, nested shells,
    eval, trap bodies, find -exec, xargs and shell-fed heredocs included."""
    lexed = lex(text, SHELLS)
    out: List[Simple] = []
    for cmd in lexed.cmds:
        seq = cmd.seq if _seq is None else _seq
        out.extend(_expand(cmd, cmd.argv, seq, cmd.subshell or _subshell,
                           _deferred, _depth))
    return out
