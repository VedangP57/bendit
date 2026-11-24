#!/usr/bin/env bash
# Scaffold a new PreToolUse guard, with its test suite, into a project; then
# prove it on a real past command before anyone turns it on.
#
# usage: new-guard.sh <name> [--project <dir>] [--dir <dir>]
#        new-guard.sh <name> --replay "<real command>" [--replay ...] [--allow-file <file>]
#
#   <name>        lowercase letters, digits and hyphens, starting with a letter,
#                 2-48 characters (it becomes <name>.py and <name>.test.sh)
#   --project     the project to scaffold into (default: the git top level of
#                 the current directory, else the current directory)
#   --dir         where the guard goes (default: <project>/.claude/hooks)
#   --replay      a command the agent really ran (from /bendit:guard-report,
#                 /bendit:suggest-guards or the person): the guard must refuse it
#   --allow-file  ordinary commands, one per line (blank and # lines skipped):
#                 the guard must allow each (default: a built-in everyday list)
#
# Scaffolding writes <dir>/<name>.py and <dir>/<name>.test.sh from
# templates/guard/, plus the two helpers they need (shell_text.py, expect.sh)
# when <dir> lacks them. It REFUSES to overwrite an existing guard or test, and
# it NEVER edits settings: it prints the hooks snippet to add to
# .claude/settings.json, so turning a guard on stays a decision a person makes
# and can see in a diff.
#
# --replay scaffolds nothing. It feeds each command to the existing guard as a
# real PreToolUse Bash payload. Proven means every replay exits 2 with a reason
# on stderr AND every ordinary command exits 0; a crash or a timeout is never a
# refusal. Commands are printed redacted (fire_log.redact): they come from logs.
# Adapted from poteto's pstack: prove each check catches a real past mistake
# before you trust it.
#
# Exit 0 scaffolded (or proven), 1 refused (something already there, no such
# guard, or not proven), 2 bad usage.
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
TPL="$SD/../templates/guard"
usage() { sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

NAME=''; PROJECT=''; DIR=''; ALLOW_FILE=''; REPLAYS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; PROJECT="$2"; shift 2 ;;
    --dir)     [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    --replay)  [ $# -ge 2 ] || usage
               if [ -z "${2//[[:space:]]/}" ]; then echo "new-guard: --replay needs a real command, not an empty one" >&2; exit 2; fi
               REPLAYS+=("$2"); shift 2 ;;
    --allow-file) [ $# -ge 2 ] || usage; ALLOW_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*)        echo "new-guard: unknown option $1" >&2; usage ;;
    *)         if [ -n "$NAME" ]; then echo "new-guard: one name only" >&2; usage; fi
               NAME="$1"; shift ;;
  esac
done

if [ -z "$NAME" ]; then echo "new-guard: a guard name is required" >&2; usage; fi
# Validated before it touches a path or a sed expression.
if ! printf '%s' "$NAME" | grep -Eq '^[a-z][a-z0-9-]{1,47}$' || [ "${NAME%-}" != "$NAME" ]; then
  echo "new-guard: '$NAME' is not a valid guard name: use 2-48 lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen" >&2
  exit 2
fi
if [ -n "$ALLOW_FILE" ] && [ "${#REPLAYS[@]}" -eq 0 ]; then
  echo "new-guard: --allow-file needs at least one --replay: a guard is proven on a real past command it refuses, not only on what it allows" >&2
  exit 2
fi
if [ -n "$ALLOW_FILE" ] && { [ ! -r "$ALLOW_FILE" ] || [ -d "$ALLOW_FILE" ]; }; then
  echo "new-guard: --allow-file $ALLOW_FILE is not a readable file" >&2
  exit 2
fi

for f in guard.py guard.test.sh; do
  if [ ! -f "$TPL/$f" ]; then echo "new-guard: template $TPL/$f is missing, nothing was written" >&2; exit 2; fi
done
for f in shell_text.py expect.sh; do
  if [ ! -f "$SD/$f" ]; then echo "new-guard: $SD/$f is missing, nothing was written" >&2; exit 2; fi
done

if [ -z "$PROJECT" ]; then
  PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
if [ ! -d "$PROJECT" ]; then echo "new-guard: project $PROJECT is not a directory" >&2; exit 2; fi
PROJECT="$(cd "$PROJECT" && pwd -P)"
DIR="${DIR:-$PROJECT/.claude/hooks}"

if [ "${#REPLAYS[@]}" -gt 0 ]; then
  # Prove an existing guard; scaffold nothing, write nothing.
  if [ ! -f "$DIR/$NAME.py" ]; then
    echo "new-guard: there is no guard $DIR/$NAME.py to prove. Scaffold it first: new-guard.sh $NAME" >&2
    exit 1
  fi
  set +e
  python3 - "$SD" "$PROJECT" "$DIR/$NAME.py" "$NAME" "$ALLOW_FILE" "${REPLAYS[@]}" <<'PY'
import json, os, subprocess, sys

sd, project, guard, name, allow_file = sys.argv[1:6]
replays = sys.argv[6:]
try:
    sys.path.insert(0, sd)
    from fire_log import preview_of  # the one place a logged command is redacted
except Exception as exc:
    print(f'new-guard: cannot load fire_log.py to redact commands ({exc}); nothing was replayed', file=sys.stderr)
    sys.exit(2)

# Everyday commands no guard should refuse. A guard that refuses one of these
# would be uninstalled within a day; if one really is this project's mistake,
# pass --allow-file with the commands this person actually runs.
EVERYDAY = [
    'git status', 'git log --oneline -10', 'git diff', 'git diff --staged',
    'git add -A', 'git commit -m "fix: handle empty input"',
    'git push -u origin feature-branch', 'git pull --rebase',
    'git checkout -b feature-branch', 'git branch -a', 'git stash',
    'ls -la', 'cat README.md', 'grep -rn TODO src', 'npm test', 'npm run build',
    'pnpm install', 'pytest -q', 'python3 -m pytest tests', 'make test',
    'mkdir -p build', 'echo done',
]
if allow_file:
    with open(allow_file, encoding='utf-8', errors='surrogateescape') as fh:
        ordinary = [l.rstrip('\r\n') for l in fh]
    ordinary = [l for l in ordinary if l.strip() and not l.lstrip().startswith('#')]
    if not ordinary:
        print(f'new-guard: --allow-file {allow_file} has no commands in it; '
              'allowing nothing proves nothing', file=sys.stderr)
        sys.exit(2)
    source = f'from {allow_file}'
else:
    ordinary, source = EVERYDAY, 'built-in everyday list'

TIMEOUT = 10  # the hook timeout new-guard.sh prints in its settings snippet
env = dict(os.environ, CLAUDE_PROJECT_DIR=project)


def run(cmd):
    """(verdict, detail): verdict is 'refused', 'allowed' or 'other'."""
    payload = json.dumps({
        'session_id': 'bendit-new-guard-replay', 'cwd': project,
        'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
        'tool_input': {'command': cmd},
    })
    try:
        r = subprocess.run(['python3', guard], input=payload.encode('utf-8', 'surrogateescape'),
                           capture_output=True, cwd=project, env=env, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 'other', f'timed out after {TIMEOUT}s; a hook that times out does not refuse'
    err = r.stderr.decode('utf-8', 'replace').strip()
    reason = preview_of(err.splitlines()[0]) if err else ''
    if r.returncode == 2 and err:
        return 'refused', reason
    if r.returncode == 2:
        return 'other', 'exit 2 with no reason on stderr; the agent would retry blind'
    if r.returncode == 0:
        return 'allowed', ''
    return 'other', (f'exit {r.returncode}, a crash; Claude Code does not treat that as a refusal'
                     + (f': {reason}' if reason else ''))


print(f'Proving {name} ({guard})')
print(f'\nReal past commands ({len(replays)}): each must be refused (exit 2 with a reason)')
missed = 0
for cmd in replays:
    verdict, detail = run(cmd)
    if verdict == 'refused':
        print(f'  refused      {preview_of(cmd)}')
    else:
        missed += 1
        print(f'  NOT REFUSED  {preview_of(cmd)}')
        print(f'               {detail or "exit 0: the guard let it through"}')
print(f'\nOrdinary commands ({len(ordinary)}, {source}): each must be allowed (exit 0)')
blocked = 0
for cmd in ordinary:
    verdict, detail = run(cmd)
    if verdict == 'allowed':
        print(f'  allowed      {preview_of(cmd)}')
    else:
        blocked += 1
        print(f'  NOT ALLOWED  {preview_of(cmd)}')
        print(f'               {detail}')

print()
if missed or blocked:
    print(f'NOT PROVEN. Do not turn {name} on.')
    if missed:
        print(f'  {missed} of {len(replays)} real past command(s) got through: '
              f'the rule in {name}.py does not catch the mistake yet.')
    if blocked:
        print(f'  {blocked} of {len(ordinary)} ordinary command(s) were not allowed: '
              'a guard that fires on ordinary work gets uninstalled.')
        if not allow_file:
            print('  If one of those really is the mistake in this project, pass --allow-file '
                  'with the commands this person runs every day instead of the built-in list.')
    print(f'  Fix the rule in {name}.py, not the replay, and run this again.')
    sys.exit(1)
print(f'PROVEN: {name} refuses all {len(replays)} real past command(s) and allows '
      f'all {len(ordinary)} ordinary one(s).')
print('Not enabled. Nothing in settings was changed: show the person the snippet '
      'new-guard.sh printed when it scaffolded this guard, and add it only on a yes.')
PY
  rc=$?
  set -e
  exit "$rc"
fi

PY="$DIR/$NAME.py"; TEST="$DIR/$NAME.test.sh"; SNAP="$DIR/$NAME.expected"
existing=''
for f in "$PY" "$TEST" "$SNAP"; do
  if [ -e "$f" ]; then existing="$existing $f"; fi
done
if [ -n "$existing" ]; then
  echo "new-guard: refusing to overwrite:$existing" >&2
  echo "new-guard: pick another name, or delete those files yourself first" >&2
  exit 1
fi

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd -P)"
PY="$DIR/$NAME.py"; TEST="$DIR/$NAME.test.sh"
sed "s/__GUARD_NAME__/$NAME/g" "$TPL/guard.py" > "$PY"
sed "s/__GUARD_NAME__/$NAME/g" "$TPL/guard.test.sh" > "$TEST"
chmod +x "$PY" "$TEST"
echo "wrote $PY"
echo "wrote $TEST"

# Running a guard or its tests writes __pycache__/ beside it (seen in a live
# /bendit:new-guard run). Ignore it from the start; never touch an existing .gitignore.
if [ ! -e "$DIR/.gitignore" ]; then
  printf '__pycache__/\n' > "$DIR/.gitignore"
  echo "wrote $DIR/.gitignore (ignores __pycache__/)"
fi

for f in shell_text.py expect.sh; do
  if [ ! -e "$DIR/$f" ]; then
    cp "$SD/$f" "$DIR/$f"
    echo "wrote $DIR/$f (copied from bendit; shared by every guard in this directory)"
  elif ! cmp -s "$SD/$f" "$DIR/$f"; then
    echo "note: $DIR/$f differs from bendit's copy and was left alone"
  fi
done

# The command path, relative to the project when the guard is inside it, so
# the snippet works on every machine that checks the project out.
case "$PY" in
  "$PROJECT"/*) CMD_PATH="\$CLAUDE_PROJECT_DIR/${PY#"$PROJECT"/}" ;;
  *)            CMD_PATH="$PY" ;;
esac

cat <<EOF

Not enabled yet. Nothing in settings was changed. To turn it on, add this to
the "hooks" object in $PROJECT/.claude/settings.json (merge into an existing
"PreToolUse" array rather than adding a second one):

  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        { "type": "command", "command": "python3 \\"$CMD_PATH\\"", "timeout": 10 }
      ]
    }
  ]

Next:
  1. edit RULES in $NAME.py to encode the mistake, and the BLOCK/ALLOW cases in $NAME.test.sh
  2. bash "$TEST" --accept     (records $NAME.expected; read it)
  3. bash "$TEST"              (must pass with no --accept)
  4. prove it on the real command the agent ran, before turning it on:
     new-guard.sh $NAME --replay "<the real command>"
EOF
