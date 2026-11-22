#!/usr/bin/env python3
"""Find the corrections you keep repeating, in THIS project's past sessions.

    suggest-guards.py [--root DIR] [--projects-dir DIR] [--min 2] [--json]

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

WHAT COUNTS AS A CORRECTION. A message the person typed (not tool output, not
a subagent's prompt, not a meta line, not a /command wrapper) that says so:
"no,", "don't", "stop", "never", "again", "I told you", "not what I asked",
"wrong", "instead". It is paired with the last tool call the agent made
before it, if any.

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
cluster (two shared keywords when no tool call came before).

WHAT IT PRINTS. Each cluster seen at least --min times: a pattern label, the
count, the tool and command, and ONE example of the person's words, folded and
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
import stat  # noqa: E402
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

MARKERS = re.compile(
    r"(?:^\s*no\b[\s,.!]|\bdon'?t\b|\bdo not\b|\bstop\b|\bnever\b|\bagain\b|"
    r"\bi told you\b|\bnot what i asked\b|\bwrong\b|\binstead\b)", re.I)
MARKER_WORDS = {'no', 'don', 'dont', "don't", 'do', 'not', 'stop', 'never', 'again',
                'told', 'asked', 'wrong', 'instead'}
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


def stem(word: str) -> str:
    for suffix, keep in (('ing', 4), ('ed', 4), ('es', 4), ('s', 3)):
        if word.endswith(suffix) and len(word) - len(suffix) >= keep and not word.endswith('ss'):
            return word[:-len(suffix)]
    return word


_RAW_TOKEN = re.compile(r'[A-Za-z0-9/+=._-]{16,}')


def keywords(text: str):
    """Content words of already-redacted text. Each whitespace-separated
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
    out = set()
    for w in words:
        if len(w) > 24 or looks_like_token(w):
            continue
        w = w.lower()
        if len(w) >= 3 and w not in STOPWORDS and w not in MARKER_WORDS:
            out.add(stem(w))
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
                        continue
                    text = typed_text(obj)
                    if text is None:
                        continue
                    if len(text) <= TEXT_CAP and MARKERS.search(text):
                        corrections.append((command_of(tool), keywords(text), text))
                    tool = None   # a new turn: the next correction is about what follows
                except Exception:
                    stats['malformed'] += 1
        except Exception:
            stats['unreadable'] += 1
        if mine:
            stats['sessions'] += 1
    return corrections


def cluster(corrections):
    clusters = []   # each: {'key', 'words', 'kw' (Counter), 'items'}
    for key, kw, text in corrections:
        need = 2 if key[0] == '-' else 1
        home = None
        for c in clusters:
            if c['key'] != key:
                continue
            if key[0] != '-' and (not kw or not c['words']):
                home = c
                break
            if len(kw & c['words']) >= need:
                home = c
                break
        if home is None:
            home = {'key': key, 'words': set(), 'kw': Counter(), 'items': []}
            clusters.append(home)
        home['words'] |= kw
        home['kw'].update(kw)
        home['items'].append(text)
    return clusters


def describe(c):
    tool, command = c['key']
    shared = [w for w, n in sorted(c['kw'].items(), key=lambda x: (-x[1], x[0])) if n >= 2][:4]
    label = ' '.join(x for x in (tool if tool != '-' else 'no tool call', command) if x)
    pattern = label + (': ' + ', '.join(shared) if shared else '')
    return {'pattern': safe(pattern), 'count': len(c['items']),
            'tool': safe(tool) if tool != '-' else '', 'command': safe(command),
            'example': safe(example_of(c['items'][0]))}


def run(args) -> int:
    root = args.root
    roots = sorted({os.path.realpath(root), os.path.abspath(root)})
    folder = session_dir(root, args.projects_dir)
    stats = Counter()
    corrections = []
    if os.path.isdir(folder) and not os.path.islink(folder):
        corrections = collect(folder, roots, stats)
    if not stats['sessions']:
        if args.json:
            print(json.dumps({'sessions': 0, 'message': NO_SESSIONS,
                              'skipped_other_project': stats['other_project'], 'clusters': []}))
        else:
            print(safe(f'{NO_SESSIONS} (looked in {folder}).'))
            if stats['other_project']:
                print(f"Skipped {stats['other_project']} lines from another project "
                      'that shares this folder name.')
        return 0

    found = [describe(c) for c in cluster(corrections)]
    found = sorted((d for d in found if d['count'] >= args.min),
                   key=lambda d: (-d['count'], d['pattern']))
    if args.json:
        print(json.dumps({'sessions': stats['sessions'], 'corrections': len(corrections),
                          'min': args.min, 'skipped_malformed': stats['malformed'],
                          'skipped_oversized': stats['oversized'],
                          'skipped_links': stats['links'], 'unreadable': stats['unreadable'],
                          'skipped_other_project': stats['other_project'],
                          'clusters': found}, ensure_ascii=False, indent=1))
        return 0
    print(f"{stats['sessions']} sessions read, {len(corrections)} corrections found, "
          f"{len(found)} seen at least {args.min} times.")
    skipped = [f'{stats[k]} {label}' for k, label in
               (('malformed', 'malformed lines'), ('oversized', 'lines over 1 MiB'),
                ('links', 'linked files'), ('unreadable', 'unreadable files'),
                ('other_project', "lines from another project's sessions")) if stats[k]]
    if skipped:
        print('Skipped: ' + ', '.join(skipped) + '.')
    if not found:
        print(f'No correction repeats {args.min} or more times.')
    for i, d in enumerate(found, 1):
        print()
        print(f"[{i}] {d['pattern']}  ({d['count']} times)")
        print(f"    tool: {d['tool'] or '-'}   command: {d['command'] or '-'}")
        print(f'    e.g. "{d["example"]}"')
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
