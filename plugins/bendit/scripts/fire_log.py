"""Record each guard refusal, so /bendit:guard-report can say what fires.

One JSON line per refusal, appended to <project>/.claude/.bendit-state/fires.jsonl
(the folder require-verification.py keeps its state in, git-ignored by
/bendit:adopt):

    {"ts": "2026-11-21T10:00:00Z", "guard": "block-dangerous-bash",
     "rule": "rm-recursive", "preview": "rm -rf ./build"}

BEST-EFFORT, AND AFTER THE DECISION. A guard calls this only once its exit code
and message are final, from inside a net that swallows everything (see
_record_fire in each guard), so nothing here can change what a guard decides or
prints. record() itself also swallows every exception, never prints, and gives
up after a second and a half -- a write that blocks (a FIFO in the log's place,
a hung network disk) would otherwise hold the guard past its hook timeout, and
a hook that times out does not refuse.

It never creates `.claude/` in a folder that has none: a project that was never
adopted gets no new folder because a guard fired there. Outside a git repo
there is no project root, and nothing is logged.

THE PREVIEW. Secrets are redacted FIRST, then the text is cut to 120
characters: cutting first could split a key so the pattern no longer matches,
and leave the first half of it in the log. redact() is the ONE place a
preview is scrubbed. It applies, in order:
  * a whole PEM private key, header to END line -- or to the end of the text
    when the END is missing -- so the body never survives the header;
  * the live keys block-dangerous-bash.py refuses (its MATERIAL_RULES, read
    from that file's source, so the guard's list stays the one definition);
  * REDACTIONS below: credential SHAPES the guard does not refuse on their own
    (URL userinfo, PASSWORD/SECRET/TOKEN/_KEY assignments and `NAME: value`
    headers, `setenv NAME value`, mysql -pPASSWORD, redis-cli -a, sshpass -p,
    curl -u user:password, GitLab and Slack tokens, an AWS secret or
    access key id, a bare JWT, a Bearer or Basic credential), and last any
    run of 32+ base64 characters that looks random (upper, lower and a
    digit, each case at least a quarter of the letters) -> `***`. Detection stays narrow;
    redaction is wide, because a refused command often carries a credential
    the refusal was not about (`PGPASSWORD=x psql -c "DROP TABLE t"`).
If the guard's patterns cannot be read, the preview is withheld rather than
written unredacted.

NEVER THROUGH A SYMLINK. `.claude`, `.claude/.bendit-state` and fires.jsonl
are each opened with O_NOFOLLOW (the folders with O_DIRECTORY, the next one
relative to the last), and each must be owned by this user, or nothing is
written. A new log is created owner-only (0600).

IGNORED BY GIT. The state folder gets a `.gitignore` of `*` when it has
none, so the log is never committed in a project /bendit:adopt did not set
up. A `.gitignore` there that is a link, or not this user's, means no log.
"""
import ast
import datetime
import json
import os
import re
import signal
import stat
import subprocess

PREVIEW_MAX = 120
LOG_NAME = 'fires.jsonl'
_HERE = os.path.dirname(os.path.abspath(__file__))
_PATTERNS = []   # compiled once per process, on first use


def _secret_patterns():
    """The live-key regexes from block-dangerous-bash.py's MATERIAL_RULES,
    parsed from its source (never imported: importing a guard runs it)."""
    if not _PATTERNS:
        with open(os.path.join(_HERE, 'block-dangerous-bash.py'), encoding='utf-8') as f:
            tree = ast.parse(f.read())
        for node in tree.body:
            if (isinstance(node, ast.Assign)
                    and any(getattr(t, 'id', None) == 'MATERIAL_RULES' for t in node.targets)):
                _PATTERNS.extend(re.compile(rule[0], re.IGNORECASE)
                                 for rule in ast.literal_eval(node.value))
        if not _PATTERNS:
            raise ValueError('no MATERIAL_RULES in block-dangerous-bash.py')
    return _PATTERNS


# A private key from its header to its END line, or to the end of the text.
_PEM = re.compile(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?'
                  r'(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)', re.S | re.I)
# A run of 32+ base64/base64url characters, whole (not part of a longer run).
_HIGH_ENTROPY_RUN = re.compile(r'(?<![A-Za-z0-9/+=_-])[A-Za-z0-9/+=_-]{32,}(?![A-Za-z0-9/+=_-])')


def _looks_random(run: str) -> bool:
    """Upper case, lower case and a digit, with each case at least a quarter
    of the letters. The balance is what keeps ordinary text: a mixed-case
    path (src/components/UserProfileCard2) or a camelCase name has far fewer
    capitals than a random key, and a hex git SHA has one case only."""
    letters = [c for c in run if c.isalpha()]
    upper = sum(c.isupper() for c in letters)
    lower = len(letters) - upper
    return (any(c.isdigit() for c in run) and upper and lower
            and upper * 4 >= len(letters) and lower * 4 >= len(letters))


# Credential shapes, as (pattern, replacement). Order matters: a URL's
# userinfo goes before the token patterns that could match inside it.
#
# LINEAR TIME, ALWAYS. redact() runs on whatever a transcript or a refused
# command holds, megabytes of it, so no pattern may rescan a run of
# characters from every position inside it: a 40 KB `a-a-a-...` once took
# 84 s, because `\b` matches before each `-` and each start rescanned the
# rest of the run. So a pattern that opens with a run of some character
# class starts only where that run starts (a lookbehind: no class character
# before it), or opens with a literal (mysql, redis-cli) whose scan stops at
# the next copy of that literal. Where the old pattern began at the first
# `\b` INSIDE the run, a lookahead finds that position; Python's re never
# re-enters a lookahead once it matched, so each run is scanned a fixed
# number of times. fire-log.test.sh times every shape on 64 KB of
# adversarial text.
#
# A quoted value taken whole, escaped quotes and spaces included (an unclosed
# quote runs to the end), else a bare word.
_VALUE = r'''(?:"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|[^\s;&|"']+)'''
# A name that says it holds a credential: a whole run of [A-Za-z0-9_-] (never
# the tail of one) with one of the keywords in it.
_SECRET_NAME = (r'(?<![A-Za-z0-9_-])(?=[A-Za-z0-9_-]*?(?:PASSWORD|PASSWD|SECRET|TOKEN|[_-]KEY|APIKEY))'
                r'[A-Za-z0-9_-]+')
_CURL_USER = r'''((?<!\S)(?:-u|--user)(?:=|[ \t]*)["']?[^\s:"';&|]+):[^\s;&|"']+'''
REDACTIONS = [
    # scheme://userinfo@host -> scheme://***@host. The userinfo runs to the
    # LAST `@` before the host (no `/` or space in between), so a password
    # holding `@` or `:` (u:p@ss@word@host) is hidden whole. The scheme starts
    # at the run's first letter that follows a word boundary (group 1 keeps
    # whatever comes before it in the run).
    (re.compile(r'(?<![A-Za-z0-9+.-])(?=([A-Za-z0-9+.-]*?)\b[A-Za-z])\1'
                r'([A-Za-z][A-Za-z0-9+.-]*://)[^\s/]*@'), r'\1\2***@'),
    # NAME=value and NAME: value (env assignments, .env lines, HTTP headers).
    (re.compile(r'(?i)(' + _SECRET_NAME + r')=' + _VALUE), r'\1=***'),
    (re.compile(r'(?i)(' + _SECRET_NAME + r'):[ \t]*' + _VALUE), r'\1: ***'),
    # setenv NAME value (csh), set -x NAME value (fish), ENV NAME value
    # (Dockerfile): a name, a space, the value.
    (re.compile(r'(?i)(\b(?:setenv|env|set(?:[ \t]+-[a-z]+)*)[ \t]+' + _SECRET_NAME + r')[ \t]+'
                + _VALUE), r'\1 ***'),
    (re.compile(r'(?i)(--(?:password|passwd|secret|token|api-key))[= ]' + _VALUE), r'\1=***'),
    # mysql/mysqldump/mysqladmin -pPASSWORD (the value is glued to -p). The
    # scan from one `mysql` stops at the next one, which then matches on its
    # own: a line of many is still linear.
    (re.compile(r'(\bmysql\w*\b(?:(?!mysql)[^|;&\n])*?\s)-p(?=[^\s])' + _VALUE), r'\1-p***'),
    # redis-cli ... -a PASSWORD, sshpass -p PASSWORD, and the password of
    # curl's -u / --user user:password.
    (re.compile(r'(\bredis-cli\b(?:(?!redis-cli)[^|;&\n])*?\s-a)[ \t]+' + _VALUE), r'\1 ***'),
    (re.compile(r'(\bsshpass[ \t]+-p)[ \t]*' + _VALUE), r'\1 ***'),
    (re.compile(_CURL_USER), r'\1:***'),
    (re.compile(r'(?i)\b(aws_secret_access_key)(["\':=\s]+)[A-Za-z0-9/+=]{16,}'), r'\1 ***'),
    (re.compile(r'\bglpat-[A-Za-z0-9_-]{16,}'), '[REDACTED]'),
    (re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{8,}'), '[REDACTED]'),
    (re.compile(r'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}'), r'\1 ***'),
    # An AWS access key id, and a bare JWT (header.payload.signature), which
    # carry no name that says what they are.
    # Case-insensitive: a lowercased key is still the key's characters.
    (re.compile(r'(?i)\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b'), '[REDACTED]'),
    # The JWT starts at the run's first eyJ that opens the run or follows a
    # `-` (group 1 keeps what comes before it).
    (re.compile(r'(?i)(?<![A-Za-z0-9_-])(?=([A-Za-z0-9_-]*?)(?<![A-Za-z0-9_])eyJ)\1'
                r'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'), r'\1[REDACTED]'),
    # Last: a high-entropy run with no name beside it (a bare AWS secret).
    (_HIGH_ENTROPY_RUN, lambda m: '***' if _looks_random(m.group(0)) else m.group(0)),
]


def redact(text: str) -> str:
    """`text` with every private key, live key and credential shape scrubbed
    (see the module docstring). If the live-key patterns cannot be loaded,
    the whole text is withheld: a preview is never written unredacted."""
    try:
        patterns = _secret_patterns()
    except Exception:
        return '[preview withheld: secret patterns unavailable]'
    text = _PEM.sub('[REDACTED]', text)
    for rx in patterns:
        text = rx.sub('[REDACTED]', text)
    for rx, repl in REDACTIONS:
        text = rx.sub(repl, text)
    return text


def preview_of(text: str) -> str:
    """Redacted, whitespace runs folded to one space, then cut to 120."""
    text = ' '.join(redact(str(text)).split())
    if len(text) > PREVIEW_MAX:
        text = text[:PREVIEW_MAX - 1] + '…'
    return text


def project_root(payload):
    """The git toplevel of CLAUDE_PROJECT_DIR, else of the payload's cwd, else
    None (the process cwd is never guessed at: a hook run by hand from some
    other folder must not write there)."""
    start = os.environ.get('CLAUDE_PROJECT_DIR')
    if not start:
        cwd = payload.get('cwd') if isinstance(payload, dict) else None
        start = cwd if isinstance(cwd, str) and cwd else None
    if not start or not os.path.isdir(start):
        return None
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=start,
                             capture_output=True, text=True, timeout=1)
    except Exception:
        return None
    top = out.stdout.strip()
    return top if out.returncode == 0 and top else None


def _mine(fd: int, kind) -> bool:
    st = os.fstat(fd)
    return kind(st.st_mode) and st.st_uid == os.geteuid()


def _ignored(state: int) -> bool:
    """The state folder holds a `.gitignore`, so the log cannot be committed
    in a project /bendit:adopt never set up. If there is none, one of `*` is
    created (O_EXCL and O_NOFOLLOW: never through a link). One already there
    is left as it is, and counts only if it is a regular file this user owns.
    False means: do not write the log."""
    try:
        fd = os.open('.gitignore', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o644, dir_fd=state)
    except FileExistsError:
        st = os.stat('.gitignore', dir_fd=state, follow_symlinks=False)
        return stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid()
    try:
        os.write(fd, b'*\n')
    finally:
        os.close(fd)
    return True


def _write(project_root: str, line: bytes) -> None:
    """Append `line`, never through a symlink and only into folders and a file
    this user owns. Each step is opened relative to the last (dir_fd), so a
    folder swapped for a link between a check and the write is not followed.
    Any failure raises, and record() swallows it."""
    nofollow = os.O_NOFOLLOW            # no O_NOFOLLOW, no logging (AttributeError)
    dirflags = os.O_RDONLY | os.O_DIRECTORY | nofollow
    fds = []
    try:
        try:
            claude = os.open(os.path.join(project_root, '.claude'), dirflags)
        except FileNotFoundError:
            return   # never create .claude/ where there is none
        fds.append(claude)
        if not _mine(claude, stat.S_ISDIR):
            return
        try:
            os.mkdir('.bendit-state', 0o755, dir_fd=claude)
        except FileExistsError:
            pass
        state = os.open('.bendit-state', dirflags, dir_fd=claude)
        fds.append(state)
        if not _mine(state, stat.S_ISDIR) or not _ignored(state):
            return
        # O_NONBLOCK: a FIFO with no reader fails at once instead of blocking.
        log = os.open(LOG_NAME, os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow
                      | getattr(os, 'O_NONBLOCK', 0), 0o600, dir_fd=state)
        fds.append(log)
        if not _mine(log, stat.S_ISREG):
            return
        os.write(log, line)   # one write of one short line: appends stay whole
    finally:
        for fd in fds:
            os.close(fd)


class _Timeout(Exception):
    pass


def _on_alarm(_signum, _frame):
    raise _Timeout()


def record(project_root, guard: str, rule: str, command_preview: str) -> None:
    """Append one refusal to the project's fires.jsonl. Swallows every
    exception, never prints, gives up after 1.5 s."""
    if not project_root:
        return
    old = None
    try:
        if hasattr(signal, 'setitimer'):
            old = signal.signal(signal.SIGALRM, _on_alarm)
            signal.setitimer(signal.ITIMER_REAL, 1.5)
        entry = {
            'ts': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'guard': str(guard),
            'rule': str(rule),
            'preview': preview_of(command_preview or ''),
        }
        _write(str(project_root), (json.dumps(entry, ensure_ascii=False) + '\n')
               .encode('utf-8', 'replace'))
    except BaseException:
        pass
    finally:
        if old is not None:
            try:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, old)
            except BaseException:
                pass
