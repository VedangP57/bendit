#!/usr/bin/env bash
# Scaffold a new PreToolUse guard, with its test suite, into a project.
#
# usage: new-guard.sh <name> [--project <dir>] [--dir <dir>]
#
#   <name>      lowercase letters, digits and hyphens, starting with a letter,
#               2-48 characters (it becomes <name>.py and <name>.test.sh)
#   --project   the project to scaffold into (default: the git top level of the
#               current directory, else the current directory)
#   --dir       where the guard goes (default: <project>/.claude/hooks)
#
# Writes <dir>/<name>.py and <dir>/<name>.test.sh from templates/guard/, plus
# the two helpers they need (shell_text.py, expect.sh) when <dir> lacks them.
# It REFUSES to overwrite an existing guard or test, and it NEVER edits
# settings: it prints the hooks snippet to add to .claude/settings.json, so
# turning a guard on stays a decision a person makes and can see in a diff.
#
# Exit 0 scaffolded, 1 refused (something already there), 2 bad usage.
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
TPL="$SD/../templates/guard"
usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

NAME=''; PROJECT=''; DIR=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; PROJECT="$2"; shift 2 ;;
    --dir)     [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
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
EOF
