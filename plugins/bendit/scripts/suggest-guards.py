#!/usr/bin/env python3
"""Find the corrections you keep repeating, in THIS project's past sessions.

    suggest-guards.py [--root DIR] [--projects-dir DIR] [--json] [--git] [--min 2]
                      [--confirm 'ID,ID,...' | 'label=ID,ID;label=ID']

TWO STEPS. The script does only deterministic work; a person's meaning is
read by Claude, never guessed from keywords.
  1. With no --confirm it LISTS every reply the person typed right after an
     agent tool call, each with a stable id, the tool, the command head and
     the redacted text cut to 160 characters: newest sessions first, those
     that look like corrections first (an ordering hint only), at most 200.
  2. Claude reads every listed reply and picks the ids that correct the
     agent. `--confirm <ids>` then clusters ONLY those ids, by the command
     they corrected, applies --min, and shows every example of each cluster.
     Claude may group them itself instead: `label=id,id;label=id` makes one
     cluster per label. An id that is not one of this project's replies, or
     one named in two groups, is refused (exit 2): nothing unconfirmed can
     count, and nothing counts twice.

Adapted from the `ruminate` idea in poteto's brainmaxxing (mine old
transcripts for repeated corrections, keep patterns, drop incidents). Here it
is a plain script that feeds /bendit:suggest-guards, which proposes the
cheapest layer for each repeat.

WHERE THE SESSIONS ARE. Claude Code keeps one folder of JSONL transcripts per
project under ~/.claude/projects/. The folder's name is the project's absolute
path with every character that is not an ASCII letter or digit turned into
`-` (so `/`, `.` and `_` all become `-`: /a/my_app/.git -> -a-my-app--git).
That rule was checked against the folder NAMES on a real machine, never their
contents. The project is --root (default $CLAUDE_PROJECT_DIR, else the current
folder: Claude Code names the folder after where it was started, not the git
top level). --projects-dir replaces ~/.claude/projects (for tests).

THIS PROJECT'S SESSIONS ONLY. Different projects can share one folder name
(/a/b-c and /a/b/c both become -a-b-c), and then Claude Code keeps both
projects' transcripts in that one folder. So the folder is not trusted: a line
is used only when its own `cwd`, normalised, is the root or a folder under it. A line with
no `cwd`, or another one, is skipped (counted as `skipped_other_project`), and
a file with no line of this project's is not counted as a session.

WHAT IT READS. Only `*.jsonl` files directly inside that ONE folder, never a
link (a link could point into another project), never a subfolder, and never
a sibling folder, even one whose name starts with this one's. Each file is
read line by line with a cap of 1 MiB a line: a longer line is skipped
without being held in memory, and so is a line that does not parse as a JSON
object for any reason (nesting too deep included).

WHAT IS LISTED. A message the person typed (not tool output, not a
subagent's prompt, not a meta line, not a /command wrapper) after the agent
made a tool call and before the person's next message. Its id is a short
hash of the session file's name and the message's line number, so it stays
the same between runs. It is paired with the last tool call before it.

ONE MESSAGE, ONE ROW. Claude Code can record the same message in more than
one session file (a resumed session copies its history). Copies are found by
the message's `uuid`, or, with none, by its sessionId, timestamp and text;
a line with neither is its own message. Each message is listed and counted
once, under the copy in the file named after its own session (else the
smallest id); every copy's id still resolves to it under --confirm, so an
id once listed keeps working, and confirming two copies counts one.

REDACTED FIRST. Every piece of text taken from a transcript -- the person's
words, the agent's command, a file path -- goes through fire_log.redact (the
one definition of redaction) before anything else touches it: before
lowercasing, keyword extraction, clustering or cutting. Only a hard size cap
comes first, so redaction never runs on megabytes: a message over 8 KB is
dropped whole, and a command or file path is cut to its first 4 KB. Keywords that look
like a token (16+ letters, digits, `_` or `-` with a digit in them) are
dropped. A command word or tool name that is not a plain name prints as `?`.
And every printed field passes through redact once more, with control
characters replaced, at render time.

HOW IT CLUSTERS. Only by the tool and command corrected, never by the words
used -- for Bash, the first word of the command (and the subcommand of git,
npm, pnpm and the like, so it reads `git push`), skipping `cd x &&` and
VAR=value; for a file tool, the file's name (not its folder). When that key
is too coarse or too fine, Claude passes its own groups as
`label=id,id;label=id`: each label is one cluster, its text kept to plain
characters, redacted, a token-like word shown as `?`, cut to 40 characters.
Shared keywords only decorate a command cluster's label (by a crude stem,
page and pages, printed as the whole word).

--git ALSO READS THIS REPO'S HISTORY. One read-only `git log` of the last
2 000 commits (subject, time and files changed). A commit is a candidate when
its subject starts with fix or revert, or when it touches a file again within
an hour of the last commit to it. Candidates group by file; each subject and
path is redacted before anything else, and only one example subject is
printed. Rows say `source: git` (transcript rows say `source: session`).

WHAT IT PRINTS. Listing: each reply's id, tool, command head and text, folded,
redacted and cut to 160 characters. --confirm: each cluster of confirmed
replies seen at least --min times, with its source, a pattern label, the
count, the tool and command (or the file), and EVERY example, each cut to
160 characters. Nothing else from any transcript is printed. It never writes
anything (not even bytecode for its helper). Exit 0 on success, 2 on a usage
error or a refused --confirm id, 1 on an internal error, whose message names
only the error type.
"""
import sys
sys.dont_write_bytecode = True   # set before any import: this script writes nothing, not even a .pyc

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import stat  # noqa: E402
import subprocess  # noqa: E402
from collections import Counter  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fire_log import redact  # noqa: E402

LINE_CAP = 1 << 20        # bytes per transcript line; longer lines are skipped
LIST_MAX = 200            # replies listed per run
# Hard caps applied BEFORE redaction, so redaction never runs on more than
# this. A longer message is dropped whole (never cut: a cut could split a
# secret so its pattern no longer matches); a command or path is cut, since
# only its first words or its extension are used and each must still pass
# as a plain name.
MSG_CAP = 8192
CMD_CAP = 4096
EXAMPLE_MAX = 160
NO_SESSIONS = 'No past sessions found for this project'

# ORDERING HINT ONLY. A reply that opens with a negation or an order to stop
# or undo, or says "I told you" or the like, is listed first. It decides
# nothing: every reply after a tool call is listed, and Claude judges each.
_OPENS = re.compile(
    r"^(?:(?:please|ugh|argh|hey|oh|wait|ok|okay)[\s,.!]+)*"
    r"(?:no\b(?!\s+(?:problem|worries|rush|thanks|thank)\b)|nope\b|stop\b|don'?t\b|do not\b"
    r"|never\b(?!\s+mind\b)|undo\b|revert\b|wrong\b|that'?s (?:wrong|not right|not it)\b)", re.I)
_ANYWHERE = re.compile(
    r"\b(?:i (?:already )?told you|not what i (?:asked|said|wanted)|i (?:said|asked) (?:not|never|no|to|for)\b"
    r"|undo (?:that|this|it)|revert (?:that|this|it)|put (?:it|them|that|this) back|why (?:did|are) you"
    r"|you (?:broke|deleted|removed|overwrote|ignored|didn'?t|were supposed to))\b", re.I)
_SENTENCE_END = re.compile(r'[.!?;\n](?=\s|$)|\n')
MARKER_WORDS = {'no', 'nope', 'nah', 'don', 'dont', "don't", 'do', 'not', 'stop', 'never',
                'again', 'told', 'asked', 'said', 'wrong', 'instead', 'undo', 'revert',
                'please', 'that', "that's", 'wait'}
STOPWORDS = set('''
a about above after all also am an and any are as at be been before being but
by can could did does doing done for from had has have having he her here hers
him his how i if in into is it its it's just me more most my myself now of off
on once only or other our ours out over own please same she should so some
such than that the their them then there these they this those through to too
under until up very was we were what when where which while who whom why will
with would you your yours yourself ok okay yes yeah use using used make made
want need like thing things time way said say tell already still even ever
let lets i'm you're that's there's it'll i've you've can't won't isn't
doesn't didn't wasn't aren't redacted
'''.split())
# Commands whose second word is what the person usually means (git PUSH).
SUBCOMMAND_TOOLS = {'git', 'npm', 'pnpm', 'yarn', 'npx', 'bun', 'docker', 'gh',
                    'kubectl', 'cargo', 'go', 'supabase', 'vercel', 'brew',
                    'pip', 'pip3', 'uv', 'poetry', 'terraform', 'prisma'}
FILE_TOOLS = {'Edit', 'Write', 'MultiEdit', 'Read', 'NotebookEdit'}
UNKNOWN = '?'

_TOKEN = re.compile(r'[A-Za-z0-9_-]{16,}')
# C0, DEL, C1, and the bidi marks, embeddings, overrides and isolates that
# can make an example read differently from what it holds.
_CONTROL = re.compile('[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]')


def looks_like_token(word: str) -> bool:
    """16+ characters of letters, digits, `_` or `-` with a digit among them,
    or anything redact() would change."""
    return bool((_TOKEN.fullmatch(word) and re.search(r'\d', word)) or redact(word) != word)


def plain(word, shape: str) -> str:
    """`word` if it fits `shape` and is not a token; else '?'."""
    if isinstance(word, str) and re.fullmatch(shape, word) and not looks_like_token(word):
        return word
    return UNKNOWN


def safe(text: str) -> str:
    """The last step before anything is printed: redact again, and replace
    control characters, so no escape sequence reaches a terminal."""
    return _CONTROL.sub('?', redact(str(text)))


def slug(path: str) -> str:
    return re.sub(r'[^A-Za-z0-9]', '-', path)


def session_dir(root: str, projects_dir: str) -> str:
    return os.path.join(projects_dir, slug(os.path.realpath(root)))


def read_lines(fd: int, stats: Counter):
    """Yield (line number, parsed JSON object) for each line of the open
    file `fd`, line by
    line; a line over LINE_CAP is drained in chunks and skipped, never held
    whole, and a line that fails to parse for any reason is skipped. Closes
    `fd`."""
    with os.fdopen(fd, 'rb') as f:
        lineno = 0
        while True:
            line = f.readline(LINE_CAP + 1)
            if not line:
                return
            lineno += 1
            if len(line) > LINE_CAP and not line.endswith(b'\n'):
                stats['oversized'] += 1
                while True:
                    chunk = f.readline(LINE_CAP)
                    if not chunk or chunk.endswith(b'\n'):
                        break
                continue
            try:
                obj = json.loads(line.decode('utf-8', 'replace'))
            except Exception:   # ValueError, RecursionError (deep nesting), ...
                stats['malformed'] += 1
                continue
            if not isinstance(obj, dict):
                stats['malformed'] += 1
                continue
            yield lineno, obj


def message_parts(obj):
    msg = obj.get('message')
    if not isinstance(msg, dict):
        return None
    content = msg.get('content')
    if isinstance(content, str):
        return [{'type': 'text', 'text': content}]
    if isinstance(content, list):
        return [p for p in content if isinstance(p, dict)]
    return None


def typed_text(obj):
    """The text the person typed in this line, REDACTED, or None if the line
    is not theirs (tool output, a subagent prompt, a meta line, a /command)."""
    if obj.get('type') != 'user' or obj.get('isSidechain') or obj.get('isMeta') \
            or obj.get('isCompactSummary'):
        return None
    parts = message_parts(obj)
    if not parts or any(p.get('type') == 'tool_result' for p in parts):
        return None
    text = ' '.join(p['text'] for p in parts
                    if p.get('type') == 'text' and isinstance(p.get('text'), str)).strip()
    if not text or text.startswith('<') or text.startswith('[Request interrupted'):
        return None
    if len(text) > MSG_CAP:
        return ''   # the person's turn, but nothing of it is used
    return redact(text)


def last_tool_call(obj):
    """(name, input) of the last tool call in an assistant line, or None."""
    if obj.get('type') != 'assistant' or obj.get('isSidechain'):
        return None
    found = None
    for p in message_parts(obj) or []:
        if p.get('type') == 'tool_use' and isinstance(p.get('name'), str):
            found = (p['name'], p.get('input') if isinstance(p.get('input'), dict) else {})
    return found


def command_of(tool):
    """What was corrected, as (tool name, command) -- command '' if none.
    Every part is taken from redacted text and must look like a plain name,
    or it is '?'."""
    if not tool:
        return ('-', '')
    raw_name, inp = tool
    name = plain(raw_name, r'[A-Za-z][A-Za-z0-9_.:-]{0,63}')
    if raw_name == 'Bash' and isinstance(inp.get('command'), str):
        for seg in re.split(r'&&|\|\||;|\||\n', redact(inp['command'][:CMD_CAP])):
            words = [w for w in seg.split() if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', w)]
            if words and words[0] in ('sudo', 'env', 'time', 'command', 'exec'):
                words = words[1:]
            if not words or words[0] == 'cd':
                continue
            head = plain(os.path.basename(words[0]), r'[A-Za-z0-9._+-]{1,40}')
            if head in SUBCOMMAND_TOOLS:
                sub = next((w for w in words[1:] if not w.startswith('-')), '')
                if sub:
                    head += ' ' + plain(sub, r'[a-z][a-z0-9:_-]{0,30}')
            return (name, head)
        return (name, '')
    if raw_name in FILE_TOOLS:
        path = inp.get('file_path') or inp.get('notebook_path') or ''
        if not isinstance(path, str) or not path or len(path) > CMD_CAP:
            return (name, '')
        return (name, plain(os.path.basename(redact(path)), r'[A-Za-z0-9._+-]{1,64}'))
    return (name, '')


def first_sentence(text: str) -> str:
    m = _SENTENCE_END.search(text)
    return (text[:m.end()] if m else text).strip()


def looks_like_correction(text: str) -> bool:
    """The ordering hint (see _OPENS). Never a filter."""
    first = first_sentence(text)
    return bool(_ANYWHERE.search(text) or (_OPENS.search(first) and not first.endswith('?')))


def stem(word: str) -> str:
    for suffix, keep in (('ing', 4), ('ed', 4), ('es', 4), ('s', 3)):
        if word.endswith(suffix) and len(word) - len(suffix) >= keep and not word.endswith('ss'):
            return word[:-len(suffix)]
    return word


_RAW_TOKEN = re.compile(r'[A-Za-z0-9/+=._-]{16,}')


def keywords(text: str):
    """Content words of already-redacted text, as {stem: whole word}. Each whitespace-separated
    chunk is judged WHOLE first: if it looks like a token (16+ characters of
    letters, digits and /+=._- with a digit) or redact() would change it,
    none of its pieces is used -- splitting a key on `/` must not turn it
    into innocent-looking words. A word is also judged in its ORIGINAL case
    (AKIA... is only a key in capitals), before it is lowercased."""
    words = []
    for chunk in text.split():
        bare = chunk.strip('\'"()[]{}<>,;:!?`')
        if (_RAW_TOKEN.fullmatch(bare) and re.search(r'\d', bare)) or redact(bare) != bare:
            continue
        words.extend(re.findall(r"[A-Za-z][A-Za-z0-9'_-]+", chunk))
    out = {}
    for w in words:
        if len(w) > 24 or looks_like_token(w):
            continue
        w = w.lower().strip("'_-")
        if len(w) >= 3 and w not in STOPWORDS and w not in MARKER_WORDS:
            # Matched by stem (page, pages), shown as the whole word.
            out.setdefault(stem(w), w)
    return out


def example_of(text: str) -> str:
    text = ' '.join(redact(text).split())
    if len(text) > EXAMPLE_MAX:
        text = text[:EXAMPLE_MAX - 1] + '…'
    return text


def under(cwd, roots) -> bool:
    """`cwd`, normalised (so /root/../other is not under /root), is a root
    or a folder under one."""
    if not isinstance(cwd, str) or not cwd:
        return False
    cwd = os.path.normpath(cwd)
    return any(cwd == r or cwd.startswith(r.rstrip(os.sep) + os.sep) for r in roots)


def reply_id(path: str, lineno: int) -> str:
    """Stable and plain: a hash of the session file's name, and the line."""
    name = os.path.basename(path).encode('utf-8', 'surrogateescape')
    return '%s:%d' % (hashlib.sha1(name).hexdigest()[:10], lineno)


_ID = re.compile(r'[0-9a-f]{10}:[0-9]{1,9}')


def message_key(obj, text: str, rid: str):
    """What makes two lines one message: its uuid; else its session, time
    and text; else (neither recorded) the line itself."""
    uid, sid, ts = obj.get('uuid'), obj.get('sessionId'), obj.get('timestamp')
    if isinstance(uid, str) and uid:
        return ('uuid', uid)
    if isinstance(sid, str) and sid and isinstance(ts, str) and ts:
        return ('stamp', sid, ts, hashlib.sha1(text.encode('utf-8', 'surrogateescape')).hexdigest())
    return ('line', rid)


def collect(folder: str, roots, stats: Counter):
    """(replies, alias). Replies: every message the person typed right
    after an agent tool call, in this project's transcripts (a line's cwd
    under one of `roots`), ONCE each however many files hold it, as dicts:
    id, age (0 = newest session), line, key (tool, command), kw, text
    (REDACTED), hint. Alias: every copy's id -> its message's id."""
    files = []
    for entry in os.scandir(folder):
        if entry.name.endswith('.jsonl') and entry.is_file(follow_symlinks=False):
            files.append((entry.stat(follow_symlinks=False).st_mtime, entry.path))
        elif entry.name.endswith('.jsonl') and entry.is_symlink():
            stats['links'] += 1
    replies = []
    for age, (_mtime, path) in enumerate(sorted(files, reverse=True)):
        try:
            # O_NOFOLLOW: a file swapped for a link since the listing is not followed.
            fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
        except OSError:
            stats['unreadable'] += 1
            continue
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            continue
        mine = False
        tool = None
        try:
            for lineno, obj in read_lines(fd, stats):
                if not under(obj.get('cwd'), roots):
                    if obj.get('type') in ('user', 'assistant'):
                        stats['other_project'] += 1
                    continue
                mine = True
                try:
                    call = last_tool_call(obj)
                    if call:
                        tool = call
                        continue
                    text = typed_text(obj)
                    if text is None:
                        continue
                    if tool and text:
                        rid = reply_id(path, lineno)
                        sid = obj.get('sessionId')
                        replies.append({'id': rid, 'age': age, 'line': lineno,
                                        'key': command_of(tool), 'kw': keywords(text), 'text': text,
                                        'hint': looks_like_correction(text),
                                        'msg': message_key(obj, text, rid),
                                        'own': isinstance(sid, str) and os.path.basename(path) == sid + '.jsonl'})
                    tool = None   # a new turn: the next reply is about what follows
                except Exception:
                    stats['malformed'] += 1
        except Exception:
            stats['unreadable'] += 1
        if mine:
            stats['sessions'] += 1
    return dedupe(replies, stats)


def dedupe(replies, stats: Counter):
    """One reply per message. The copy kept is the one in the file named
    after the message's own session, else the smallest id: neither depends
    on file times, so a copy appearing later never moves the id."""
    copies = {}
    for r in replies:
        copies.setdefault(r['msg'], []).append(r)
    kept, alias = [], {}
    for group in copies.values():
        keep = min(group, key=lambda r: (not r['own'], r['id']))
        kept.append(keep)
        for r in group:
            alias[r['id']] = keep['id']
        stats['duplicates'] += len(group) - 1
    return kept, alias


def listed(r):
    tool, command = r['key']
    return {'id': r['id'], 'tool': safe(tool), 'command': safe(command),
            'hint': 'likely' if r['hint'] else '', 'text': safe(example_of(r['text']))}


def new_cluster(key, label=None):
    return {'key': key, 'label': label, 'kw': Counter(), 'surface': {}, 'items': []}


def add(c, r):
    c['kw'].update(set(r['kw']))
    for st, word in r['kw'].items():
        c['surface'].setdefault(st, Counter())[word] += 1
    c['items'].append(r)


def cluster(groups):
    """`groups` from confirmed(): a labelled group is one cluster, as Claude
    grouped it; unlabelled replies cluster by (tool, command) alone. Words
    never decide membership."""
    clusters, by_key = [], {}
    for label, items in groups:
        if label is not None:
            c = new_cluster(None, label)
            clusters.append(c)
            for r in items:
                add(c, r)
            continue
        for r in items:
            if r['key'] not in by_key:
                by_key[r['key']] = new_cluster(r['key'])
                clusters.append(by_key[r['key']])
            add(by_key[r['key']], r)
    return clusters


def shared_words(c):
    """Up to four words seen at least twice in the cluster, most often first,
    each printed as the whole word people wrote most (never a stem)."""
    stems = [w for w, n in sorted(c['kw'].items(), key=lambda x: (-x[1], x[0])) if n >= 2][:4]
    return [sorted(c['surface'][st].items(), key=lambda x: (-x[1], len(x[0]), x[0]))[0][0]
            for st in stems]


def describe(c):
    if c['label'] is not None:
        # Claude's group: one tool or command only when every member shares it.
        tools = {r['key'][0] for r in c['items']}
        keys = {r['key'] for r in c['items']}
        tool = tools.pop() if len(tools) == 1 else ''
        command = keys.pop()[1] if len(keys) == 1 else ''
        pattern, grouped_by = c['label'], 'label'
    else:
        tool, command = c['key']
        shared = shared_words(c)
        label = ' '.join(x for x in (tool if tool != '-' else 'no tool call', command) if x)
        pattern, grouped_by = label + (': ' + ', '.join(shared) if shared else ''), 'command'
    return {'source': 'session', 'pattern': safe(pattern), 'count': len(c['items']),
            'grouped_by': grouped_by,
            'tool': safe(tool) if tool != '-' else '', 'command': safe(command), 'file': '',
            'ids': [r['id'] for r in c['items']],
            'examples': [safe(example_of(r['text'])) for r in c['items']]}


# ---- --git: this repo's own history --------------------------------------
# Adapted from pstack's `correct` skill (poteto): read recent commits and
# reverts, group the mistakes into classes, and a class counts once it has
# happened twice. A candidate commit is one whose subject starts with fix or
# revert, or one that touches a file again within GIT_WINDOW of the last
# commit to it (a quick follow-up: the first try was not right). Candidates
# are grouped by the file they touch.
GIT_MAX = 2000            # commits read, newest first
GIT_TIMEOUT = 20          # seconds
GIT_WINDOW = 3600         # seconds
FIX_FILES_MAX = 10        # a fix touching more files is a sweep, not one mistake
FOLLOWUP_FILES_MAX = 3    # a follow-up touches a few files, or it is new work
_FIX_SUBJECT = re.compile(r'^(?:fix(?:es|ed)?|revert(?:s|ed)?)\b', re.I)
_CONVENTIONAL = re.compile(r'^\s*(?:revert\s*"?\s*)?(?:[A-Za-z]+(?:\([^)]*\))?!?:\s*)?', re.I)
MERGE_JACCARD = 0.6       # files fixed by this much the same commits are one row
WEIGHT = {'revert': 3, 'fix': 2, 'follow-up': 1}
GIT_SHOWN = 8             # git rows printed in text mode; --json has all
GIT_WORDS = {'fix', 'fixes', 'fixed', 'revert', 'reverts', 'reverted', 'feat'}


def git_log(root):
    """[(time, subject, [files])] for the last GIT_MAX commits of the repo
    `root` is in, oldest first; or a reason string. Runs ONE read-only
    command, `git log`, with no pager, no signature check and no optional
    locks, limited to `root` itself (`-- .`): a project inside a bigger repo
    reads only its own folder's history."""
    git = shutil.which('git')
    if not git:
        return 'git not found'
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', LC_ALL='C')
    cmd = [git, '-C', root, '--no-pager', '-c', 'log.showSignature=false',
           '-c', 'core.quotePath=true', 'log', '-n', str(GIT_MAX), '--no-color',
           '--no-renames', '--name-only', '--format=%x1e%ct%x1f%s', '--', '.']
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=env, timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return 'git timed out'
    except OSError:
        return 'git not found'
    if p.returncode != 0:
        return 'no git history'
    commits = []
    for rec in p.stdout.decode('utf-8', 'replace').split('\x1e')[1:]:
        head, _, rest = rec.partition('\n')
        ts, _, subject = head.partition('\x1f')
        try:
            ts = int(ts)
        except ValueError:
            continue
        files = [f for f in rest.split('\n') if f]
        commits.append((ts, subject, files))
    commits.reverse()
    return commits


def git_candidates(commits):
    """(candidates, touches). candidates: (commit number, kind, files hit,
    keywords, subject), kind being 'revert', 'fix' or 'follow-up'.
    touches: {file: every commit number that touched it}. The subject and
    paths are cut and REDACTED before anything else."""
    last, touches, out = {}, {}, []
    for n, (ts, subject, files) in enumerate(commits):
        subject = redact(subject[:CMD_CAP])
        files = [redact(f[:CMD_CAP]) for f in files]
        hit = set()
        fix = _FIX_SUBJECT.match(subject)
        if fix and len(files) <= FIX_FILES_MAX:
            hit.update(files)
        if len(files) <= FOLLOWUP_FILES_MAX:
            hit.update(f for f in files if f in last and 0 <= ts - last[f] <= GIT_WINDOW)
        for f in files:
            last[f] = ts
            touches.setdefault(f, set()).add(n)
        if hit:
            kind = ('revert' if fix.group(0).lower().startswith('revert') else 'fix') if fix else 'follow-up'
            words = {st: w for st, w in keywords(_CONVENTIONAL.sub('', subject)).items()
                     if w not in GIT_WORDS}
            out.append((n, kind, sorted(hit), words, subject))
    return out, touches


def _main_file(path: str):
    """Sort key: the code a fix was about before its test or expected output."""
    base = os.path.basename(path).lower()
    return ('test' in base or base.endswith('.expected'), len(path), path)


def _jaccard(a, b) -> float:
    return len(a & b) / len(a | b) if a or b else 0.0


def git_rows(candidates, touches):
    """One row per group of files fixed by (nearly) the same commits: a
    script, its test and its expected output are one pattern, not three.
    A file joins the group whose commit set it shares MERGE_JACCARD of.

    Each row is scored 3 per revert, 2 per fix commit and 1 per quick
    follow-up, and ranked by that score times the share of the files'
    commits that were candidates: 10 fixes in 12 touches is a pattern, 10
    in 80 is churn. A row of only Markdown files ranks after the rest: a
    docs fix is rarely something a guard can hold."""
    commits_of, info = {}, {}
    for n, kind, files, kw, subject in candidates:
        info[n] = (kind, kw, subject)
        for f in files:
            commits_of.setdefault(f, set()).add(n)
    groups = []   # each: [files, commit set]
    for f in sorted(commits_of, key=lambda f: (-len(commits_of[f]), _main_file(f))):
        ns = commits_of[f]
        best = max(groups, key=lambda g: _jaccard(ns, g[1]), default=None)
        if best is not None and _jaccard(ns, best[1]) >= MERGE_JACCARD:
            best[0].append(f)
            best[1] |= ns
        else:
            groups.append([[f], set(ns)])
    rows = []
    for files, ns in groups:
        files.sort(key=_main_file)
        c = {'kw': Counter(), 'surface': {}}
        for n in sorted(ns):
            kw = info[n][1]
            c['kw'].update(set(kw))
            for st, word in kw.items():
                c['surface'].setdefault(st, Counter())[word] += 1
        score = sum(WEIGHT[info[n][0]] for n in ns)
        touched = set().union(*(touches.get(f, set()) for f in files)) | ns
        shared = shared_words(c)
        label = files[0] + (f' (+{len(files) - 1} more)' if len(files) > 1 else '')
        rows.append({'source': 'git', 'pattern': safe(label + (': ' + ', '.join(shared) if shared else '')),
                     'count': len(ns), 'score': score,
                     'weight': round(score * len(ns) / len(touched), 2),
                     'docs_only': all(f.lower().endswith('.md') for f in files),
                     'tool': '', 'command': '', 'file': safe(files[0]),
                     'files': [safe(f) for f in files],
                     'example': safe(example_of(info[min(ns)][2]))})
    return rows


class Refused(Exception):
    """A --confirm id that is not one of this project's listed replies."""


LABEL_MAX = 40


def clean_label(raw: str) -> str:
    """Claude's group label, safe to print: plain characters only, any
    token-like word as `?`, redacted, cut to LABEL_MAX."""
    text = re.sub(r"[^A-Za-z0-9 ._,'/:+-]", ' ', raw[:CMD_CAP])
    words = [UNKNOWN if looks_like_token(w) or re.search(r'[A-Za-z0-9_-]{16,}', w) and re.search(r'\d', w)
             else w for w in text.split()]
    return safe(' '.join(words))[:LABEL_MAX].strip()


def confirmed(replies, alias, spec: str):
    """[(label or None, replies)] for `spec`: groups split by `;`, each
    `id,id,...` or `label=id,id,...`. Every id must be well formed and one
    of THIS project's replies (any copy's id names its message), and no
    message may sit in two groups, or the whole run is refused: an unknown
    id never silently drops, nothing else counts, nothing counts twice."""
    groups, seen = [], set()
    known = {r['id']: r for r in replies}
    for seg in spec.split(';'):
        if not seg.strip():
            continue
        label = None
        if '=' in seg:
            raw, seg = seg.split('=', 1)
            label = clean_label(raw)
            if not label:
                raise Refused('a group has an empty label; write label=id,id')
        ids = [x.strip() for x in seg.split(',') if x.strip()]
        if label is not None and not ids:
            raise Refused('a labelled group names no ids')
        bad = [x for x in ids if not _ID.fullmatch(x)]
        if bad:
            raise Refused(f'{len(bad)} malformed id(s); an id looks like 0123456789:42')
        unknown = [x for x in ids if x not in alias]
        if unknown:
            raise Refused(f"{len(unknown)} id(s) are not replies in this project's sessions: "
                          + ', '.join(unknown[:5]))
        want = {alias[x] for x in ids}
        twice = want & seen
        if twice:
            raise Refused(f'{len(twice)} message(s) named in two groups: ' + ', '.join(sorted(twice)[:5]))
        seen |= want
        # Oldest first, so a cluster's examples read in the order they happened.
        groups.append((label, sorted((known[x] for x in want), key=lambda r: (-r['age'], r['line']))))
    return groups


def git_section(args, root):
    """(state, commits read, candidate commits, ranked rows at --min)."""
    if not args.git:
        return None, 0, 0, []
    log = git_log(root)
    if isinstance(log, str):
        return log, 0, 0, []
    candidates, touches = git_candidates(log)
    rows = sorted((d for d in git_rows(candidates, touches) if d['count'] >= args.min),
                  key=lambda d: (d['docs_only'], -d['weight'], -d['count'], d['pattern']))
    for i, d in enumerate(rows, 1):
        d['rank'] = i
    return 'ok', len(log), len({c[0] for c in candidates}), rows


def print_git(args, state, commits_read, n_candidates, rows):
    if state == 'ok':
        print(f'{commits_read} commits read (the last {GIT_MAX} at most), '
              f'{n_candidates} fix, revert or quick follow-up commits.')
    else:
        print(f'Git history: {state}.')
    if not rows:
        print(f'No pattern repeats {args.min} or more times in the git history.')
    for d in rows[:GIT_SHOWN]:
        print()
        print(f"[git {d['rank']}] {d['pattern']}  ({d['count']} commits)")
        print(f"    source: git   file: {d['file']}")
        print(f'    e.g. "{d["example"]}"')
    if len(rows) > GIT_SHOWN:
        print()
        print(f'{len(rows) - GIT_SHOWN} more git rows (--json for all).')


def run(args) -> int:
    root = args.root
    roots = sorted({os.path.realpath(root), os.path.abspath(root)})
    folder = session_dir(root, args.projects_dir)
    stats = Counter()
    replies, alias = [], {}
    if os.path.isdir(folder) and not os.path.islink(folder):
        replies, alias = collect(folder, roots, stats)
    if args.confirm is not None:
        try:
            groups = confirmed(replies, alias, args.confirm)
            chosen = [r for _label, items in groups for r in items]
        except Refused as e:
            print(safe(f'suggest-guards: refused: {e}. Nothing was clustered.'), file=sys.stderr)
            return 2
    if not stats['sessions'] and not args.git and args.confirm is None:
        if args.json:
            print(json.dumps({'sessions': 0, 'message': NO_SESSIONS,
                              'skipped_other_project': stats['other_project'], 'clusters': []}))
        else:
            print(safe(f'{NO_SESSIONS} (looked in {folder}).'))
            if stats['other_project']:
                print(f"Skipped {stats['other_project']} lines from another project "
                      'that shares this folder name.')
        return 0

    state, commits_read, n_candidates, git_found = git_section(args, root)
    head = {'sessions': stats['sessions'], 'min': args.min,
            'skipped_malformed': stats['malformed'], 'skipped_oversized': stats['oversized'],
            'skipped_links': stats['links'], 'unreadable': stats['unreadable'],
            'skipped_other_project': stats['other_project'], 'duplicates': stats['duplicates']}
    if not stats['sessions']:
        head['message'] = NO_SESSIONS
    if args.git:
        head.update({'git': state, 'commits_read': commits_read, 'git_candidates': n_candidates})
    skipped = [f'{stats[k]} {label}' for k, label in
               (('malformed', 'malformed lines'), ('oversized', 'lines over 1 MiB'),
                ('links', 'linked files'), ('unreadable', 'unreadable files'),
                ('other_project', "lines from another project's sessions"),
                ('duplicates', 'copies of a message already read (counted once)')) if stats[k]]

    if args.confirm is None:
        # STEP 1: list every reply after a tool call, for Claude to read.
        order = sorted(replies, key=lambda r: (not r['hint'], r['age'], r['line']))
        shown = [listed(r) for r in order[:LIST_MAX]]
        more = len(order) - len(shown)
        if args.json:
            head.update({'replies': len(replies), 'listed': len(shown), 'more': more,
                         'candidates': shown, 'clusters': git_found})
            print(json.dumps(head, ensure_ascii=False, indent=1))
            return 0
        if stats['sessions']:
            print(f"{stats['sessions']} sessions read; {len(replies)} replies came right after a "
                  f'tool call. Listing {len(shown)}: newest sessions first, those that look '
                  'like corrections first.')
        else:
            print(safe(f'{NO_SESSIONS} (looked in {folder}).'))
        if skipped:
            print('Skipped: ' + ', '.join(skipped) + '.')
        for d in shown:
            print()
            print(f"[{d['id']}] {d['tool']} {d['command'] or '-'}"
                  + ('   (looks like a correction)' if d['hint'] else ''))
            print(f'    "{d["text"]}"')
        if more:
            print()
            print(f'{more} more (only the first {LIST_MAX} are listed).')
        if args.git:
            print()
            print_git(args, state, commits_read, n_candidates, git_found)
        return 0

    # STEP 2: cluster only what Claude confirmed. Session rows first, always.
    found = sorted((d for d in (describe(c) for c in cluster(groups)) if d['count'] >= args.min),
                   key=lambda d: (-d['count'], d['pattern']))
    if args.json:
        head.update({'confirmed': len(chosen), 'clusters': found + git_found})
        print(json.dumps(head, ensure_ascii=False, indent=1))
        return 0
    print(f'{len(chosen)} confirmed corrections, {len(found)} patterns seen at least '
          f'{args.min} times.')
    if skipped:
        print('Skipped: ' + ', '.join(skipped) + '.')
    if not found:
        print(f'No correction repeats {args.min} or more times.')
    for i, d in enumerate(found, 1):
        print()
        print(f"[{i}] {d['pattern']}  ({d['count']} times)")
        print(f"    source: session   tool: {d['tool'] or '-'}   command: {d['command'] or '-'}"
              f"   grouped by: {'your label' if d['grouped_by'] == 'label' else 'command'}")
        for rid, ex in zip(d['ids'], d['examples']):
            print(f'    {rid}: "{ex}"')
    if args.git:
        print()
        print_git(args, state, commits_read, n_candidates, git_found)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description='Find corrections you keep repeating '
                                 "in this project's past Claude Code sessions.")
    ap.add_argument('--root', default=os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd(),
                    help='the project folder (default: $CLAUDE_PROJECT_DIR, else the current folder)')
    ap.add_argument('--projects-dir', default=os.path.join(os.path.expanduser('~'), '.claude', 'projects'),
                    help='where Claude Code keeps per-project transcript folders')
    ap.add_argument('--min', type=int, default=2, help='show clusters seen at least this often (default 2)')
    ap.add_argument('--confirm', metavar='ID,ID,...|LABEL=ID,ID;LABEL=ID',
                    help='cluster ONLY these listed replies (the ones Claude confirmed as corrections): '
                         'by command, or one cluster per label')
    ap.add_argument('--json', action='store_true', help='print JSON')
    ap.add_argument('--git', action='store_true',
                    help="also mine this repo's last %d commits (fix, revert and quick follow-up commits)" % GIT_MAX)
    args = ap.parse_args(argv)
    if args.min < 1:
        ap.error('--min must be at least 1')
    try:
        return run(args)
    except Exception as e:
        # The type only: an exception's message can quote transcript text.
        print(f'suggest-guards: internal error ({type(e).__name__}); nothing from the '
              'transcripts is shown.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
