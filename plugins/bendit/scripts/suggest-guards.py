#!/usr/bin/env python3
"""Find the corrections you keep repeating, in THIS project's past sessions.

    suggest-guards.py [--root DIR] [--projects-dir DIR] [--min 2] [--json] [--git]

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

WHAT COUNTS AS A CANDIDATE CORRECTION. A message the person typed (not tool
output, not a subagent's prompt, not a meta line, not a /command wrapper)
with any sign of one. This is a WIDE filter, not a judge: each candidate is
`likely` (it opens with "no,", "don't", "stop", "undo", "wrong", or says "I
told you", "not what I asked", "you broke", "you didn't" ...) or `maybe` (a
habit or approval opener, a "no" answering the agent's own question, a
marker word later on). /bendit:suggest-guards has Claude read each example
and drop what is not a correction. It is paired with the last tool call the
agent made before it, if any.

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

HOW IT CLUSTERS. By the tool and command corrected -- for Bash, the first word
of the command (and the subcommand of git, npm, pnpm and the like, so it reads
`git push`), skipping `cd x &&` and VAR=value; for a file tool, the file's
extension -- then, within that, corrections sharing a keyword join one
cluster (two shared keywords when no tool call came before). Keywords match
by a crude stem (page, pages) but a label prints the whole word.

--git ALSO READS THIS REPO'S HISTORY. One read-only `git log` of the last
2 000 commits (subject, time and files changed). A commit is a candidate when
its subject starts with fix or revert, or when it touches a file again within
an hour of the last commit to it. Candidates group by file; each subject and
path is redacted before anything else, and only one example subject is
printed. Rows say `source: git` (transcript rows say `source: session`).

WHAT IT PRINTS. Each cluster seen at least --min times: its source, a pattern
label, the count, the tool and command (or the file), and ONE example of the person's words, folded and
cut to 160 characters. Nothing else from any transcript is printed. It never
writes anything (not even bytecode for its helper). Exit 0 on success, 2 on a
usage error, 1 on an internal error, whose message names only the error type.
"""
import sys
sys.dont_write_bytecode = True   # set before any import: this script writes nothing, not even a .pyc

import argparse  # noqa: E402
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
TEXT_CAP = 2000           # a longer message is a task, not a correction
# Hard caps applied BEFORE redaction, so redaction never runs on more than
# this. A longer message is dropped whole (never cut: a cut could split a
# secret so its pattern no longer matches); a command or path is cut, since
# only its first words or its extension are used and each must still pass
# as a plain name.
MSG_CAP = 8192
CMD_CAP = 4096
EXAMPLE_MAX = 160
NO_SESSIONS = 'No past sessions found for this project'

# The script is a WIDE filter: it finds candidate corrections, each marked
# `likely` or `maybe`, and Claude reads each quoted example and drops what is
# not a correction before anything is shown (commands/suggest-guards.md).
# Rules tuned for precision overfit whatever messages they were tuned on, so
# recall comes first here and the judgement is Claude's.
#
# LIKELY: the message anywhere says "I told you", "not what I asked", "I
# asked for", "why did you", "you broke", "you didn't", "you were supposed
# to", "the third time", "undo that", "put it back"; or its FIRST sentence
# opens with a negation or an order to stop or undo ("no,", "don't",
# "stop", "undo", "wrong") that is not a habit or approval ("no problem",
# "no, that's fine", "don't forget", "never mind", "stop here for today").
# MAYBE: everything else with a hint of one -- an excluded opener, a "no"
# answering the agent's own question, a change of mind ("stop -- actually
# continue"), a rename request, "why would you", or a marker word ("don't",
# "again", "wrong", "instead", "never") later in the message.
_OPEN_WORDS = (r"no\b|nope\b|nah\b|stop\b|don'?t\b|do not\b|dont\b|never\b"
               r"|undo\b|revert\b|wrong\b|not that\b|that'?s (?:wrong|not right|not it)\b")
_PREFIX = r"^(?:(?:please|ugh|argh|hey|oh|wait|ok|okay)[\s,.!]+)*"
_OPENS_ANY = re.compile(_PREFIX + r"(?:" + _OPEN_WORDS + r")", re.I)
_OPENS = re.compile(
    _PREFIX +
    r"(?:no\b(?!\s+(?:problem|worries|rush|thanks|thank|issue|doubt|prob)\b)"
    r"(?![\s,.!]+(?:that'?s|thats|it'?s|its)\s+(?:fine|ok|okay|good|alright|all right)\b)"
    r"|nope\b|nah\b|stop\b(?!\s+(?:here|for\s+(?:today|now|the\s+day)|there)\b)"
    r"|(?:don'?t|do not|dont)\b(?!\s+(?:forget|worry|bother)\b)|never\b(?!\s+(?:mind|thought)\b)"
    r"|undo\b|revert\b|wrong\b|not that\b|that'?s (?:wrong|not right|not it)\b)", re.I)
_ANYWHERE = re.compile(
    r"\b(?:i (?:already )?told you|not what i (?:asked|said|wanted)|i (?:said|asked) (?:not|never|no|to|for)\b"
    r"|i asked you not|undo (?:that|this|it|those)|revert (?:that|this|it|those)"
    r"|put (?:it|them|that|this) back|why (?:did|are) you"
    r"|you (?:broke|deleted|removed|overwrote|ignored|wiped)"
    r"|you (?:didn'?t|did not|never)\s+\w+|you were (?:supposed|meant|told) to"
    r"|(?:second|third|fourth|fifth|\d+(?:st|nd|rd|th)) time|how many times"
    r"|you (?:shouldn'?t|should not) have)\b", re.I)
_WEAK = re.compile(r"\b(?:why would you|don'?t|do not|never|again|wrong|instead|stop|undo|revert"
                   r"|not what|supposed to)\b", re.I)
_CHANGED_MIND = re.compile(r"\b(?:actually|never ?mind)\b[^.?!]*\b(?:continue|go on|carry on|go ahead"
                           r"|keep going|fine)\b|\bi misread\b", re.I)
# A request that only renames or changes something, blaming no one.
_CHANGE_REQUEST = re.compile(r"\b(?:can|could|would) you (?:please )?(?:also )?(?:rename|change|update)\b", re.I)
_BLAME = re.compile(r"\bagain\b|\byou (?:did|changed|used|ran|added|forgot)\b", re.I)
_BARE_NO = re.compile(r"^(?:no|nope|nah)\b", re.I)
_UNDO_VERB = re.compile(r"\b(?:undo|revert|put|restore|remove|delete|roll)\b", re.I)
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
    """Yield each line of the open file `fd` as a parsed JSON object, line by
    line; a line over LINE_CAP is drained in chunks and skipped, never held
    whole, and a line that fails to parse for any reason is skipped. Closes
    `fd`."""
    with os.fdopen(fd, 'rb') as f:
        while True:
            line = f.readline(LINE_CAP + 1)
            if not line:
                return
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
            yield obj


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


def asks(obj):
    """For an assistant line with text: do its last words ask the person a
    question? None for a line with no text (thinking only, say)."""
    texts = [p.get('text') for p in message_parts(obj) or []
             if p.get('type') == 'text' and isinstance(p.get('text'), str) and p['text'].strip()]
    return texts[-1].rstrip().endswith('?') if texts else None


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
        ext = os.path.splitext(redact(path))[1] if isinstance(path, str) and len(path) <= CMD_CAP else ''
        return (name, '*' + ext if re.fullmatch(r'\.[A-Za-z0-9]{1,10}', ext) else '')
    return (name, '')


def first_sentence(text: str) -> str:
    m = _SENTENCE_END.search(text)
    return (text[:m.end()] if m else text).strip()


def classify(text: str, after_question: bool):
    """'likely', 'maybe' or None: is this (redacted) message a candidate
    correction of the agent's last action? See the rules above _OPEN_WORDS.
    A no right after the agent asked a question, with no undo verb in its
    first sentence and no blame, is only `maybe`: it is usually an answer
    ("No, go with the second option")."""
    if _ANYWHERE.search(text):
        return 'likely'
    first = first_sentence(text)
    if _OPENS_ANY.search(first):
        if first.endswith('?') or not _OPENS.search(first) or _CHANGED_MIND.search(text):
            return 'maybe'
        if _CHANGE_REQUEST.search(text) and not _BLAME.search(text):
            return 'maybe'
        if (after_question and _BARE_NO.match(first) and not _UNDO_VERB.search(first)
                and not _BLAME.search(text)):
            return 'maybe'
        return 'likely'
    return 'maybe' if _WEAK.search(text) else None


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


def collect(folder: str, roots, stats: Counter):
    """Every correction in the folder's transcripts made in this project
    (a line's cwd under one of `roots`), oldest file first."""
    files = []
    for entry in os.scandir(folder):
        if entry.name.endswith('.jsonl') and entry.is_file(follow_symlinks=False):
            files.append((entry.stat(follow_symlinks=False).st_mtime, entry.path))
        elif entry.name.endswith('.jsonl') and entry.is_symlink():
            stats['links'] += 1
    corrections = []
    for _mtime, path in sorted(files):
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
        asked = False
        try:
            for obj in read_lines(fd, stats):
                if not under(obj.get('cwd'), roots):
                    if obj.get('type') in ('user', 'assistant'):
                        stats['other_project'] += 1
                    continue
                mine = True
                try:
                    call = last_tool_call(obj)
                    if call:
                        tool = call
                        asked = False
                        continue
                    if obj.get('type') == 'assistant':
                        q = None if obj.get('isSidechain') else asks(obj)
                        asked = asked if q is None else q
                        continue
                    text = typed_text(obj)
                    if text is None:
                        continue
                    conf = classify(text, asked) if len(text) <= TEXT_CAP else None
                    if conf:
                        corrections.append((command_of(tool), keywords(text), text, conf))
                    tool = None   # a new turn: the next correction is about what follows
                    asked = False
                except Exception:
                    stats['malformed'] += 1
        except Exception:
            stats['unreadable'] += 1
        if mine:
            stats['sessions'] += 1
    return corrections


def cluster(corrections):
    clusters = []   # each: {'key', 'words', 'kw' (Counter of stems), 'surface', 'items'}
    for key, kw, text, conf in corrections:
        stems = set(kw)
        need = 2 if key[0] == '-' else 1
        home = None
        for c in clusters:
            if c['key'] != key:
                continue
            if key[0] != '-' and (not stems or not c['words']):
                home = c
                break
            if len(stems & c['words']) >= need:
                home = c
                break
        if home is None:
            home = {'key': key, 'words': set(), 'kw': Counter(), 'surface': {}, 'items': []}
            clusters.append(home)
        home['words'] |= stems
        home['kw'].update(stems)
        for st, word in kw.items():
            home['surface'].setdefault(st, Counter())[word] += 1
        home['items'].append((text, conf))
    return clusters


def shared_words(c):
    """Up to four words seen at least twice in the cluster, most often first,
    each printed as the whole word people wrote most (never a stem)."""
    stems = [w for w, n in sorted(c['kw'].items(), key=lambda x: (-x[1], x[0])) if n >= 2][:4]
    return [sorted(c['surface'][st].items(), key=lambda x: (-x[1], len(x[0]), x[0]))[0][0]
            for st in stems]


def describe(c):
    tool, command = c['key']
    shared = shared_words(c)
    label = ' '.join(x for x in (tool if tool != '-' else 'no tool call', command) if x)
    pattern = label + (': ' + ', '.join(shared) if shared else '')
    likely = [t for t, conf in c['items'] if conf == 'likely']
    return {'source': 'session', 'pattern': safe(pattern), 'count': len(c['items']),
            'confidence': 'likely' if likely else 'maybe', 'likely': len(likely),
            'tool': safe(tool) if tool != '-' else '', 'command': safe(command), 'file': '',
            'example': safe(example_of(likely[0] if likely else c['items'][0][0]))}


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


def run(args) -> int:
    root = args.root
    roots = sorted({os.path.realpath(root), os.path.abspath(root)})
    folder = session_dir(root, args.projects_dir)
    stats = Counter()
    corrections = []
    if os.path.isdir(folder) and not os.path.islink(folder):
        corrections = collect(folder, roots, stats)
    if not stats['sessions'] and not args.git:
        if args.json:
            print(json.dumps({'sessions': 0, 'message': NO_SESSIONS,
                              'skipped_other_project': stats['other_project'], 'clusters': []}))
        else:
            print(safe(f'{NO_SESSIONS} (looked in {folder}).'))
            if stats['other_project']:
                print(f"Skipped {stats['other_project']} lines from another project "
                      'that shares this folder name.')
        return 0

    # Session rows first, always: they are a person's own corrections.
    found = sorted((d for d in (describe(c) for c in cluster(corrections)) if d['count'] >= args.min),
                   key=lambda d: (-d['count'], d['pattern']))
    git_state, commits_read, candidates, git_found = None, 0, [], []
    if args.git:
        log = git_log(root)
        if isinstance(log, str):
            git_state = log
        else:
            git_state, commits_read = 'ok', len(log)
            candidates, touches = git_candidates(log)
            git_found = sorted((d for d in git_rows(candidates, touches) if d['count'] >= args.min),
                               key=lambda d: (d['docs_only'], -d['weight'], -d['count'], d['pattern']))
            for i, d in enumerate(git_found, 1):
                d['rank'] = i
    found += git_found
    if args.json:
        out = {'sessions': stats['sessions'], 'corrections': len(corrections),
               'likely': sum(1 for c in corrections if c[3] == 'likely'),
               'min': args.min, 'skipped_malformed': stats['malformed'],
               'skipped_oversized': stats['oversized'],
               'skipped_links': stats['links'], 'unreadable': stats['unreadable'],
               'skipped_other_project': stats['other_project']}
        if not stats['sessions']:
            out['message'] = NO_SESSIONS
        if args.git:
            out.update({'git': git_state, 'commits_read': commits_read,
                        'git_candidates': len({c[0] for c in candidates})})
        out['clusters'] = found
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0
    if stats['sessions']:
        likely = sum(1 for c in corrections if c[3] == 'likely')
        print(f"{stats['sessions']} sessions read, {len(corrections)} candidate corrections found "
              f"({likely} likely, {len(corrections) - likely} maybe).")
    else:
        print(safe(f'{NO_SESSIONS} (looked in {folder}).'))
    if args.git:
        if git_state == 'ok':
            print(f'{commits_read} commits read (the last {GIT_MAX} at most), '
                  f"{len({c[0] for c in candidates})} fix, revert or quick follow-up commits.")
        else:
            print(f'Git history: {git_state}.')
    print(f'{len(found)} patterns seen at least {args.min} times.')
    skipped = [f'{stats[k]} {label}' for k, label in
               (('malformed', 'malformed lines'), ('oversized', 'lines over 1 MiB'),
                ('links', 'linked files'), ('unreadable', 'unreadable files'),
                ('other_project', "lines from another project's sessions")) if stats[k]]
    if skipped:
        print('Skipped: ' + ', '.join(skipped) + '.')
    if not found:
        print(f"No {'pattern' if args.git else 'correction'} repeats {args.min} or more times.")
    hidden = max(0, len(git_found) - GIT_SHOWN)
    if hidden:
        found = found[:len(found) - hidden]
    for i, d in enumerate(found, 1):
        print()
        if d['source'] == 'git':
            print(f"[{i}] {d['pattern']}  ({d['count']} commits)")
            print(f"    source: git   file: {d['file']}")
        else:
            print(f"[{i}] {d['pattern']}  ({d['count']} times, {d['likely']} likely)")
            print(f"    source: session   confidence: {d['confidence']}   "
                  f"tool: {d['tool'] or '-'}   command: {d['command'] or '-'}")
        print(f'    e.g. "{d["example"]}"')
    if hidden:
        print()
        print(f'{hidden} more git rows (--json for all).')
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description='Find corrections you keep repeating '
                                 "in this project's past Claude Code sessions.")
    ap.add_argument('--root', default=os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd(),
                    help='the project folder (default: $CLAUDE_PROJECT_DIR, else the current folder)')
    ap.add_argument('--projects-dir', default=os.path.join(os.path.expanduser('~'), '.claude', 'projects'),
                    help='where Claude Code keeps per-project transcript folders')
    ap.add_argument('--min', type=int, default=2, help='show clusters seen at least this often (default 2)')
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
