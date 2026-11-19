#!/usr/bin/env bash
# features.py is the one reader of .claude/bendit.json, and every hook that
# depends on it must fail CLOSED on a malformed file. So each case below breaks
# the file one way and asserts exit 2 plus a message naming the file and the
# problem; the prose (features.expected) is the snapshot.
#
#   bash features.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
PY_GIVEN="${PY:-}"
PY="$(command -v "${PY:-python3}")"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

. "$SD/expect.sh"
expect_init "$SD/features.expected"
expect_scrub_dir "$T" '<tmp>'
F="$SD/features.py"
cap() { local l="$1"; shift; if [ -z "$PY_GIVEN" ]; then expect_capture "$l" "$PY" "$F" "$@"
        else EXPECT_STDOUT=$("$PY" "$F" "$@" 2>"$T/err"); EXPECT_CODE=$?; EXPECT_STDERR=$(cat "$T/err"); fi; }
proj() { rm -rf "$T/$1"; mkdir -p "$T/$1/.claude"; [ -n "${2:-}" ] && printf '%s' "$2" > "$T/$1/.claude/bendit.json"; return 0; }

echo "ABSENT FILE"
mkdir -p "$T/none"
cap "get on a project with no bendit.json" get "$T/none" browser-driver
chk "absent -> off" "$EXPECT_STDOUT" "off"; chk "  ...exit 0" "$EXPECT_CODE" "0"
cap "show on a project with no bendit.json" show "$T/none"
chk "show with no file exits 0" "$EXPECT_CODE" "0"
has "  ...lists every feature" "ls-guard" "$EXPECT_STDOUT"

echo; echo "ROUND TRIP, MERGE"
cap "set creates the file" set "$T/none" browser-driver on "package.json:14 next"
chk "set exits 0" "$EXPECT_CODE" "0"
cap "get after set" get "$T/none" browser-driver
chk "round trip -> on" "$EXPECT_STDOUT" "on"
cap "set off" set "$T/none" browser-driver off "declined"
cap "get after set off" get "$T/none" browser-driver
chk "set off -> off" "$EXPECT_STDOUT" "off"
proj merge '{"version":1,"features":{"session-brief":{"on":true,"why":"git project","brief":{"local_ports":[3000]}},"ls-guard":{"on":true,"why":"zsh"}}}'
cap "set another feature" set "$T/merge" ux-design-laws on "has UI"
cap "set an existing feature again (brief must survive)" set "$T/merge" session-brief on "still a git project"
got=$("$PY" - "$T/merge/.claude/bendit.json" <<'PYE'
import json, sys
d = json.load(open(sys.argv[1]))
f = d['features']
print(sorted(f), f['session-brief']['brief'], f['session-brief']['why'], f['ls-guard']['why'])
PYE
)
chk "other features and the brief object are kept; the why is updated" "$got" "['ls-guard', 'session-brief', 'ux-design-laws'] {'local_ports': [3000]} still a git project zsh"
fmt=$("$PY" -c 'import sys; t=open(sys.argv[1]).read(); print(t.startswith("{\n  \"features\""), t.endswith("}\n") and not t.endswith("\n\n"), t.index("ls-guard") < t.index("session-brief") < t.index("ux-design-laws"))' "$T/merge/.claude/bendit.json")
chk "file is sorted keys, 2-space indent, one trailing newline" "$fmt" "True True True"
cap "show after merges" show "$T/merge"
chk "no temp file left behind" "$(/usr/bin/find "$T/merge/.claude" -name '*.tmp')" ""

echo; echo "MALFORMED FILES FAIL CLOSED"
bad() { # <label> <content> <needle>
  proj bad "$2"
  cap "$1" get "$T/bad" browser-driver
  chk "$1 -> exit 2" "$EXPECT_CODE" "2"
  has "  ...names the file" "$T/bad/.claude/bendit.json" "$EXPECT_STDERR"
  has "  ...names the problem" "$3" "$EXPECT_STDERR"
  chk "  ...prints no on/off" "$EXPECT_STDOUT" ""
}
bad "unknown feature" '{"version":1,"features":{"lsguard":{"on":true,"why":"x"}}}' "lsguard"
bad "on is not a bool" '{"version":1,"features":{"ls-guard":{"on":"yes","why":"x"}}}' '"on"'
bad "invalid JSON" '{"version":1,' "not valid JSON"
bad "version is not 1" '{"version":2,"features":{}}' "version"
bad "version missing" '{"features":{}}' "version"
bad "why empty" '{"version":1,"features":{"ls-guard":{"on":true,"why":" "}}}' "why"
bad "an unknown key on a feature" '{"version":1,"features":{"ls-guard":{"on":true,"why":"x","brief":{}}}}' "brief"
bad "top level is a list" '[]' "object"
cap "set refuses to overwrite a malformed file" set "$T/bad" ls-guard on x
chk "set on a malformed file -> exit 2" "$EXPECT_CODE" "2"
chk "  ...and leaves it as it was" "$(cat "$T/bad/.claude/bendit.json")" "[]"
cap "set unknown feature" set "$T/none" lsguard on x
chk "set of an unknown name -> exit 2" "$EXPECT_CODE" "2"
cap "no arguments" 
chk "usage -> exit 2" "$EXPECT_CODE" "2"

echo; echo "INTERRUPTED WRITE LEAVES THE OLD FILE INTACT"
proj ro '{"version":1,"features":{"ls-guard":{"on":true,"why":"old"}}}'
before=$(cat "$T/ro/.claude/bendit.json")
chmod a-w "$T/ro/.claude"
if [ -w "$T/ro/.claude" ]; then
  printf '  skip  .claude is still writable (running as root); the os.replace case below covers it\n'
else
  cap "write into a read-only .claude" set "$T/ro" ls-guard off new
  chk "read-only .claude -> exit 2" "$EXPECT_CODE" "2"
  has "  ...says the old file is untouched" "untouched" "$EXPECT_STDERR"
fi
chmod u+w "$T/ro/.claude"
chk "old file intact after the refused write" "$(cat "$T/ro/.claude/bendit.json")" "$before"
chk "no temp file left" "$(/usr/bin/find "$T/ro/.claude" -name '*.tmp')" ""
# Hermetic equivalent that does not depend on file modes: the rename itself fails.
out=$("$PY" - "$SD" "$T/ro" <<'PYE'
import os, sys
sys.path.insert(0, sys.argv[1])
import features
root = sys.argv[2]
def boom(a, b): raise OSError('simulated crash before the rename')
os.replace = boom
try:
    features.write(root, {'ls-guard': {'on': False, 'why': 'new'}})
    print('NO ERROR')
except features.FeaturesError as e:
    print('raised')
PYE
)
chk "a failing os.replace raises FeaturesError" "$out" "raised"
chk "  ...old file intact" "$(cat "$T/ro/.claude/bendit.json")" "$before"
chk "  ...no temp file left" "$(/usr/bin/find "$T/ro/.claude" -name '*.tmp')" ""

echo; echo "MODULE API"
api=$(CLAUDE_PROJECT_DIR= "$PY" - "$SD" "$T" <<'PYE'
import os, sys
sys.path.insert(0, sys.argv[1])
import features
t = sys.argv[2]
print(features.path('/r'), features.FEATURES)
os.environ.pop('CLAUDE_PROJECT_DIR', None)
print(features.project_root({'cwd': '/from/payload'}))
os.environ['CLAUDE_PROJECT_DIR'] = '/from/env'
print(features.project_root({'cwd': '/from/payload'}))
del os.environ['CLAUDE_PROJECT_DIR']
os.chdir(t)
print(features.project_root({}) == os.getcwd())
print(features.load(t + '/none') is not None, features.is_on(t + '/nowhere', 'ls-guard'))
PYE
)
chk "path, FEATURES, project_root precedence, load/is_on" "$api" "/r/.claude/bendit.json ('browser-driver', 'ux-design-laws', 'session-brief', 'ls-guard')
/from/payload
/from/env
True
True False"

if [ -z "$PY_GIVEN" ]; then
  echo; echo "WHAT IT SAYS (snapshot)"
  expect_verify || fail=$((fail+1))
fi
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo; echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
