#!/usr/bin/env python3
"""Refuse parsing the output of `ls`, in a project where `ls` is not the real ls.

OFF BY DEFAULT. This guard runs only where the project's `.claude/bendit.json`
turns `ls-guard` on (/bendit:adopt does that when it finds `ls` is a shell alias or
function). Absent file or `"on": false` -> exit 0 at once. A malformed file is
never read as "off": the ls check still runs, and a command that would be
refused as ls-parsing is refused (exit 2) with a message naming the file.
Every other command passes: a broken file must not lock out `git status` or
the Edit tool that would fix it.

THE BUG: when `ls` is a function or alias that decorates its output (a table
with border rows, a header row, colour escapes around every field), anything
that counts or splits that output counts the decoration:

    find . -maxdepth 1 -mindepth 1 | wc -l   ->   N   (N entries: the truth)
    ls | wc -l                               ->   more than N (border, header rows)
    echo $(ls) | wc -w                       ->   far more than N (colour escapes)

Nothing fails. The pipeline exits 0 and returns a plausible wrong number, so the
error surfaces only if someone happens to know the real answer.

WHAT IT FIRES ON: an `ls` in command position whose output is CONSUMED -- piped
into a text tool (`|` or `|&`, through any redirect such as `2>&1`), captured
by `$( )` or backticks, read through process substitution `<( )`, or feeding a
`for ... in` list. A bare `ls` is never refused: rendering that output for a
human is what the decorated `ls` is for, and a guard that refused an
interactive `ls` would be uninstalled the same day.

THE ESCAPE HATCHES: `command ls` and an absolute path (`/bin/ls`) reach the real
binary. A leading backslash and quoting the name (`'ls'`) suppress only ALIAS
expansion, so when `ls` is a FUNCTION neither reaches the real binary. A
backslash-ls is therefore REFUSED like a bare `ls`; `'ls'` is a known gap,
because matching a quoted command name would also match `echo 'ls | wc -l'`,
which is ordinary text. An absolute path is always permitted: a path is never
the function, and a missing binary fails loudly, the opposite of this failure.
"""
import io
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Imported inside main(), under run()'s crash net: a broken features.py or
# shell_text.py must exit 2 (refuse), not exit 1 (a non-blocking error).
features = None
strip_quoted_heredocs = None

# The rule id each refusal is logged under (fire_log.py), and the list
# /bendit:guard-report reads -- by PARSING this file, so it stays a literal.
# A crash that refuses is logged as guard-error and kept out of the list.
RULES = ['parses-ls-output']

# `ls` in COMMAND POSITION: at the start, or after a separator, with only
# whitespace and an optional backslash between. Anchoring this way is what
# keeps `git ls-files`, `npm ls` and `/bin/ls` out of the match -- none of them
# has a separator immediately before the name, so no alternative can reach it.
#
# The trailing lookahead rejects a name that merely STARTS with ls: `lsof`,
# `ls-files`, `ls.txt`, `lsblk`. The optional `\\?` deliberately INCLUDES the
# backslash spelling, which does not escape a function (see the docstring).
LS = re.compile(
    r'(?:^|[;&|`\n(]|\$\(|\bthen\s|\bdo\s|\belse\s)\s*\\?(?P<ls>ls)(?![\w.\-/])')

# Things that read ls output as DATA. Each one turns the box-drawing border into
# rows, fields or words. `cat` is deliberately absent: it reproduces the table
# for a human to look at, which is not parsing.
CONSUMERS = {
    'wc', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'head', 'tail',
    'awk', 'gawk', 'mawk', 'sed', 'sort', 'uniq', 'cut', 'tr', 'nl',
    'column', 'xargs', 'jq', 'while', 'read',
    'python', 'python3', 'perl', 'ruby', 'node',
}

NEXT_WORD = re.compile(r'\s*([\w./-]+)')

MESSAGE = r'''BLOCKED by bendit: this parses the output of `ls`, and `ls` here is not the real ls.

`ls` here is a formatter (an alias or function), so its output has extra rows
and escape codes: counting its lines or splitting its words counts the
decoration. The pipeline still exits 0 and hands back a plausible wrong number.

Here, the ls output is {how}.

Use one of:
  command ls | ...     skips a function or alias
  /bin/ls | ...        the real binary
  find . -maxdepth 1 -mindepth 1 | wc -l     to COUNT entries
  git ls-files | ...                         for tracked files

A backslash before ls is NOT an escape hatch, and neither is quoting it: both
suppress alias expansion only, so a function still runs.

A bare `ls` with no pipe and no `$( )` is never refused.
(Turn this guard off: set "ls-guard" to off in .claude/bendit.json.)'''


def hidden_and_captured(text):
    """Return (literal spans, capture spans) for one command string.

    literal: inside single quotes, where the shell runs nothing.
    capture: (start, end, kind) inside `$( )` or backticks, where stdout
             becomes the command's value -- the border rows become part of the
             string -- or inside `<( )`, where it becomes a file another
             command reads. kind is '$(', '`' or '<('.

    Only as much shell lexing as those two questions need. It fails toward
    scanning MORE text: an unterminated quote is treated as an ordinary
    character rather than swallowing the rest, and an unterminated backtick is
    assumed to capture to the end. Scanning more can only refuse more, which is
    the safe direction for a guard whose escape hatch is one word long.
    """
    literal, capture, stack = [], [], []
    in_dquote = False
    backtick = None
    i, n = 0, len(text)
    while i < n:
        char = text[i]
        if char == '\\':
            i += 2
            continue
        if char == "'" and not in_dquote:
            end = text.find("'", i + 1)
            if end == -1:
                i += 1
                continue
            literal.append((i, end))
            i = end + 1
            continue
        if char == '"':
            # Inside double quotes a single quote is ordinary text, but `$( )`
            # and backticks still run -- so only the quote handling is
            # suspended here, not the capture handling below.
            in_dquote = not in_dquote
            i += 1
            continue
        if text.startswith('$(', i) or text.startswith('<(', i):
            stack.append((i + 2, text[i:i + 2]))
            i += 2
            continue
        if text.startswith('>(', i):
            # Output process substitution: ls there writes to the terminal.
            stack.append((None, None))
            i += 2
            continue
        if char == '(' and stack:
            # A plain subshell nested inside a substitution. Pushed only to keep
            # the parens balanced; a TOP-LEVEL `( )` is not a capture, because
            # its output goes to the terminal like any other command's.
            stack.append((None, None))
            i += 1
            continue
        if char == ')' and stack:
            start, kind = stack.pop()
            if kind:
                capture.append((start, i, kind))
            i += 1
            continue
        if char == '`':
            if backtick is None:
                backtick = i + 1
            else:
                capture.append((backtick, i, '`'))
                backtick = None
            i += 1
            continue
        i += 1
    if backtick is not None:
        capture.append((backtick, n, '`'))
    for start, kind in stack:
        if kind:
            capture.append((start, n, kind))
    return literal, capture


def piped_consumer(text, start):
    """The first text tool ls output is piped into, or None.

    Walks the rest of the PIPELINE only. `;`, a newline, `&&`, `||`, a
    backgrounding `&` and a closing paren all end it -- past them the ls output
    is gone, so `ls; wc -l file` is not this bug. An `&` inside a redirect
    (`2>&1`, `&>f`, `>&2`) does NOT end it, and `|&` is a pipe, so
    `ls 2>&1 | wc -l` is caught. A hop that is not a consumer (`ls | cat | wc -l`)
    keeps the walk going, because the count at the far end is still wrong.
    """
    i, n = start, len(text)
    while i < n:
        char = text[i]
        if char == '\\':
            i += 2
            continue
        if char in '\'"':
            end = text.find(char, i + 1)
            i = end + 1 if end != -1 else i + 1
            continue
        if text.startswith('||', i) or text.startswith('&&', i):
            return None
        if char == '&':
            redirect = (i > 0 and text[i - 1] in '<>') or text.startswith('&>', i)
            if not redirect:
                return None
            i += 1
            continue
        if char in ';\n)':
            return None
        if char == '|':
            skip = 2 if text.startswith('|&', i) else 1
            match = NEXT_WORD.match(text, i + skip)
            if not match:
                return None
            # The basename, so `| /usr/bin/wc -l` is recognised too.
            word = match.group(1).rsplit('/', 1)[-1]
            if word in CONSUMERS:
                return word
            i = match.end()
            continue
        i += 1
    return None


def describe(text, pos, capture):
    """Say how this ls output is being consumed, or None if it is not."""
    for start, end, kind in capture:
        if start <= pos < end:
            if kind == '<(':
                return 'read through process substitution `<( )`'
            # The text before the opener, which is two characters for `$(`
            # and one for a backtick. Slicing both at -2 called a backtick
            # loop "captured by `$( )`".
            before = text[:start - len(kind)]
            how = 'captured by backticks' if kind == '`' else 'captured by `$( )`'
            if re.search(r'\bfor\s+\w+\s+in\s*$', before):
                return f'{how} to feed a `for ... in` list'
            return how
    consumer = piped_consumer(text, pos + 2)
    if consumer:
        return f'piped into `{consumer}`'
    return None


def refusal(payload):
    """The message for a command that parses `ls` output, else None."""
    tool_input = payload.get('tool_input') if isinstance(payload, dict) else None
    if not isinstance(tool_input, dict):
        return None   # a shape this hook does not understand: ignored, like junk
    cmd = tool_input.get('command')
    if not isinstance(cmd, str) or not cmd:
        return None
    # Quoted heredoc bodies are written to a file and run later by some other
    # shell, so they are not scanned. keep_for is EMPTY on purpose: a body fed
    # to `bash`/`sh`/`zsh` runs non-interactively, where a shell function from
    # the user's rc file is not defined. The other guards read the same text
    # through shell_text.py, so all of them agree on what counts as executable.
    cmd = strip_quoted_heredocs(cmd, keep_for=())
    literal, capture = hidden_and_captured(cmd)
    for match in LS.finditer(cmd):
        pos = match.start('ls')
        if any(start <= pos < end for start, end in literal):
            continue
        how = describe(cmd, pos, capture)
        if how is not None:
            return MESSAGE.format(how=how)
    return None


def no_bendit_json(payload) -> bool:
    """True only when the project certainly has no .claude/bendit.json.

    This hook runs on every Bash call, and almost every project has no file:
    answering that from one stat, before features.py and shell_text.py are
    imported, is most of the hook's cost. The root is features.project_root's
    first two choices (CLAUDE_PROJECT_DIR, then the payload's cwd); anything
    else -- no root, a NUL byte, a stat that fails for another reason --
    returns False and takes the full path, which fails closed.
    """
    root = os.environ.get('CLAUDE_PROJECT_DIR')
    if not root:
        cwd = payload.get('cwd') if isinstance(payload, dict) else None
        root = cwd if isinstance(cwd, str) and cwd else None
    if not root:
        return False
    try:
        os.stat(os.path.join(root, '.claude', 'bendit.json'))
    except FileNotFoundError:
        return True
    except (OSError, ValueError):
        return False
    return False


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


def _say(msg: str) -> None:
    """Print a refusal; if that fails, write a fixed one straight to fd 2."""
    try:
        print(msg, file=sys.stderr)
        sys.stderr.flush()
    except BaseException:
        try:
            os.write(2, b'[bendit] BLOCKED: bendit guard block-ls-parsing failed and could not say why; '
                        b'refusing to be safe. Run /bendit:doctor.\n')
        except BaseException:
            pass


def main() -> int:
    global features, strip_quoted_heredocs
    try:
        payload = json.loads(sys.stdin.buffer.read().decode('utf-8', 'surrogateescape'))
    except ValueError:
        payload = None
    if no_bendit_json(payload):
        return 0
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    # This guard's own helpers. run() catches Exception, but a helper that
    # exits on import raises SystemExit -- exit 0, the command runs. So this
    # net catches everything, and refuses.
    try:
        import features as _features
        from shell_text import strip_quoted_heredocs as _strip
    except BaseException as exc:  # noqa: B036 -- SystemExit from a helper included
        _say(could_not_start('block-ls-parsing', exc))
        _record_fire(payload, 'guard-error', '')
        return 2
    features, strip_quoted_heredocs = _features, _strip
    # The feature gate comes first: off or absent -> nothing else runs. A
    # malformed bendit.json is never read as "off", but it must not block
    # every command either (a file from a newer bendit would lock out older
    # teammates): run the ls check anyway and refuse only what it refuses.
    unreadable = None
    try:
        if not features.is_on(features.project_root(payload), 'ls-guard'):
            return 0
    except features.FeaturesError as e:
        unreadable = e
    msg = refusal(payload)
    if msg is None:
        return 0
    if isinstance(unreadable, getattr(features, 'UnknownFeatureOn', ())):
        msg = ('BLOCKED by bendit: %s\nls-guard cannot tell whether it is on, so a command that '
               'parses `ls` output is refused until bendit is updated.' % unreadable)
    elif unreadable is not None:
        msg = ('BLOCKED by bendit: `.claude/bendit.json` is unreadable: %s\n'
               'ls-guard cannot tell whether it is on, so a command that parses `ls` output '
               'is refused until the file is fixed: fix it with the Edit tool, or ask the person.'
               % unreadable)
    print(msg, file=sys.stderr)
    _record_fire(payload, 'parses-ls-output', payload['tool_input']['command'])
    return 2


def run() -> int:
    try:
        return main()
    # Exit 1 is non-blocking to a hook, and a SystemExit or KeyboardInterrupt
    # from a helper exits 0 or 130: every one of them refuses instead.
    except BaseException as e:
        _say('BLOCKED by bendit: block-ls-parsing crashed (%s); refusing rather '
             'than letting the command through unchecked.' % _describe(e))
        _record_fire(None, 'guard-error', '')
        return 2


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
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fire_log
        fire_log.record(fire_log.project_root(payload), 'block-ls-parsing', rule, preview)
    except BaseException:
        pass
    finally:
        sys.stdout, sys.stderr = saved


if __name__ == '__main__':
    try:
        _code = run()
    except BaseException:   # last resort: the net itself failed
        os._exit(2)
    sys.exit(_code)
