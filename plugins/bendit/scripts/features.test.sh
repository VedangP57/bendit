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

echo; echo "RE-ADOPT"
# /bendit:adopt writes every feature with one chain of `set` calls; running /bendit:adopt
# again on an unchanged project must not churn the committed file.
readopt() {
  "$PY" "$F" set "$T/readopt" browser-driver on "package.json:5 next" &&
  "$PY" "$F" set "$T/readopt" ux-design-laws on "package.json:5 next" &&
  "$PY" "$F" set "$T/readopt" session-brief on "git project" &&
  "$PY" "$F" set "$T/readopt" ls-guard off "ls is the real ls"
}
proj readopt
readopt; chk "first adopt chain exits 0" "$?" "0"
cp "$T/readopt/.claude/bendit.json" "$T/readopt-first.json"
readopt; chk "second adopt chain exits 0" "$?" "0"
if cmp -s "$T/readopt-first.json" "$T/readopt/.claude/bendit.json"; then same=y; else same=n; fi
chk "the same set chain twice -> a byte-identical file" "$same" "y"

echo; echo "MALFORMED FILES FAIL CLOSED"
# A refusal is: exit 2, the "features: " prefix, the file named, the problem
# named, and nothing on stdout. Exit 2 alone proves nothing (python exits 2 for
# a missing script), so every check ties the code to the message.
refused() { # <label> <needle> -- judges the last cap
  chk "$1 -> exit 2" "$EXPECT_CODE" "2"
  case "$EXPECT_STDERR" in "features: "*) chk "  ...features: prefix" y y;; *) chk "  ...features: prefix (stderr: $EXPECT_STDERR)" n y;; esac
  has "  ...names the file" "$T/bad/.claude/bendit.json" "$EXPECT_STDERR"
  has "  ...names the problem" "$2" "$EXPECT_STDERR"
  chk "  ...prints nothing on stdout" "$EXPECT_STDOUT" ""
}
bad() { # <label> <content> <needle>
  proj bad; printf '%s' "$2" > "$T/bad/.claude/bendit.json"
  cap "$1" get "$T/bad" browser-driver
  refused "$1" "$3"
}
bad "unknown feature" '{"version":1,"features":{"lsguard":{"on":true,"why":"x"}}}' "lsguard"
bad "on is not a bool" '{"version":1,"features":{"ls-guard":{"on":"yes","why":"x"}}}' '"on"'
bad "on missing" '{"version":1,"features":{"ls-guard":{"why":"x"}}}' '"on"'
bad "invalid JSON" '{"version":1,' "not valid JSON"
bad "empty file" '' "not valid JSON"
bad "version is not 1" '{"version":2,"features":{}}' "version"
bad "version missing" '{"features":{}}' "version"
bad "version is true" '{"version":true,"features":{}}' "version"
bad "version is 1.0" '{"version":1.0,"features":{}}' "version"
bad "features missing" '{"version":1}' '"features"'
bad "features is not an object" '{"version":1,"features":[]}' '"features"'
bad "a feature entry is not an object" '{"version":1,"features":{"ls-guard":true}}' "ls-guard"
bad "why empty" '{"version":1,"features":{"ls-guard":{"on":true,"why":" "}}}' "why"
bad "why is not a string" '{"version":1,"features":{"ls-guard":{"on":true,"why":5}}}' "why"
bad "why missing" '{"version":1,"features":{"ls-guard":{"on":true}}}' "why"
bad "brief on a feature that has none" '{"version":1,"features":{"ls-guard":{"on":true,"why":"x","brief":{}}}}' "brief"
bad "brief is not an object" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":[1]}}}' "brief"
# The brief object is validated as strictly as the rest: a wrong type is a
# refusal naming the key, never a silent default.
bad "an unknown brief key" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"ports":[3000]}}}}' "'ports'"
bad "brief env_files is a string" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"env_files":".env"}}}}' "env_files"
bad "brief env_files holds a number" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"env_files":[".env",1]}}}}' "env_files"
bad "brief probe_env_vars is null" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"probe_env_vars":null}}}}' "probe_env_vars"
bad "brief local_ports holds a bool" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"local_ports":[true]}}}}' "local_ports"
bad "brief local_ports holds 0" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"local_ports":[0]}}}}' "local_ports"
bad "brief local_ports holds 65536" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"local_ports":[65536]}}}}' "local_ports"
bad "brief local_ports holds a string" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"local_ports":["3000"]}}}}' "local_ports"
bad "brief local_ports holds 3000.0" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"local_ports":[3000.0]}}}}' "local_ports"
bad "brief docs_glob is a number" '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"docs_glob":5}}}}' "docs_glob"
bad "an unknown key on a feature" '{"version":1,"features":{"ls-guard":{"on":true,"why":"x","colour":1}}}' "colour"
bad "extra top-level key" '{"version":1,"features":{},"extra":1}' "extra"
bad "top level is a list" '[]' "object"
printf '{"version":1,"features":{}}\xff\xfe' > "$T/bad/.claude/bendit.json"
cap "bad UTF-8" get "$T/bad" ls-guard; refused "bad UTF-8" "cannot be read"
proj bad; rmdir "$T/bad/.claude"; printf 'x' > "$T/bad/.claude"
cap ".claude is a file" get "$T/bad" ls-guard
chk ".claude is a file -> exit 2" "$EXPECT_CODE" "2"
has "  ...names the file" "$T/bad/.claude/bendit.json" "$EXPECT_STDERR"
has "  ...cannot be read" "cannot be read" "$EXPECT_STDERR"
rm -f "$T/bad/.claude"
# Deep nesting: json.loads raises RecursionError; it must still be exit 2.
proj bad; "$PY" -c 'import sys; sys.stdout.write("["*1000000 + "]"*1000000)' > "$T/bad/.claude/bendit.json"
cap "1000000 levels of nesting" get "$T/bad" ls-guard; refused "deep nesting" "nested too deeply"
# A NUL byte in the root path: ValueError from open().
nulrc=$("$PY" - "$SD" <<'PYE'
import sys
sys.path.insert(0, sys.argv[1])
import features
try:
    features.load('/tmp/a\0b')
    print('NO ERROR')
except features.FeaturesError as e:
    print('raised', '\x00' in str(e))
PYE
)
chk "NUL in the path -> FeaturesError (not ValueError), message has no raw NUL" "$nulrc" "raised False"
# set paths
proj bad '[]'
cap "set refuses to overwrite a malformed file" set "$T/bad" ls-guard on x; refused "set on a malformed file" "object"
chk "  ...and leaves it as it was" "$(cat "$T/bad/.claude/bendit.json")" "[]"
proj bad '{"version":1,"features":{},"extra":1}'
cap "set on a file with an extra top-level key" set "$T/bad" ls-guard on x; refused "set on extra top-level key" "extra"
chk "  ...file untouched (the key is not silently erased)" "$(cat "$T/bad/.claude/bendit.json")" '{"version":1,"features":{},"extra":1}'
cap "set unknown feature" set "$T/none" lsguard on x
chk "set of an unknown name -> exit 2" "$EXPECT_CODE" "2"; has "  ...names it" "lsguard" "$EXPECT_STDERR"
cap "get unknown feature" get "$T/none" lsguard
chk "get of an unknown name -> exit 2" "$EXPECT_CODE" "2"; has "  ...names it" "lsguard" "$EXPECT_STDERR"
cap "set with an empty why" set "$T/none" ls-guard on ""
chk "empty why -> exit 2" "$EXPECT_CODE" "2"; has "  ...names why" "why" "$EXPECT_STDERR"
cap "set with a bad on|off token" set "$T/none" ls-guard maybe x
chk "bad token -> exit 2" "$EXPECT_CODE" "2"; has "  ...says usage" "usage:" "$EXPECT_STDERR"
cap "no arguments"
chk "usage -> exit 2" "$EXPECT_CODE" "2"; has "  ...says usage" "usage:" "$EXPECT_STDERR"
proj bad '{"version":1,"features":{"lsguard":{"on":true,"why":"x"}}}'
cap "show on a malformed file" show "$T/bad"; refused "show on a malformed file" "lsguard"
proj full '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"env_files":[".env.local",".env"],"probe_env_vars":["APP_URL"],"local_ports":[1,3000,65535],"docs_glob":null}}}}'
cap "every brief key, each at an edge of its type" get "$T/full" session-brief
chk "a full, valid brief is accepted" "$EXPECT_CODE|$EXPECT_STDOUT" "0|on"
proj full '{"version":1,"features":{"session-brief":{"on":true,"why":"x","brief":{"docs_glob":"docs/**/*.md","env_files":[]}}}}'
cap "a docs_glob string and empty env_files" get "$T/full" session-brief
chk "a docs_glob string and an empty list are accepted" "$EXPECT_CODE|$EXPECT_STDOUT" "0|on"
ls_none=$(/usr/bin/find "$T/none" -name '*.tmp'); chk "no stray temp files after the refusals" "$ls_none" ""

echo; echo "FILE MODE"
proj mode '{"version":1,"features":{"ls-guard":{"on":true,"why":"old"}}}'
chmod 664 "$T/mode/.claude/bendit.json"
cap "rewrite a 0664 file" set "$T/mode" ls-guard off new
chk "an existing file keeps its mode" "$("$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$T/mode/.claude/bendit.json")" "0o664"
proj fresh
( umask 022; "$PY" "$F" set "$T/fresh" ls-guard on new )
chk "a new file is 0666 & ~umask (umask 022 -> 0644)" "$("$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$T/fresh/.claude/bendit.json")" "0o644"
proj fresh2
( umask 002; "$PY" "$F" set "$T/fresh2" ls-guard on new )
chk "  ...and follows the umask (002 -> 0664)" "$("$PY" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$T/fresh2/.claude/bendit.json")" "0o664"

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
  has "  ...names the file" "$T/ro/.claude/bendit.json" "$EXPECT_STDERR"
fi
chmod u+w "$T/ro/.claude"
chk "old file intact after the refused write (nothing could be created)" "$(cat "$T/ro/.claude/bendit.json")" "$before"
# Hermetic equivalent, independent of file modes, and the only case that
# actually CREATES a temp file: the rename itself fails.
out=$("$PY" - "$SD" "$T/ro" <<'PYE'
import os, sys
sys.path.insert(0, sys.argv[1])
import features
root = sys.argv[2]
real = os.replace
seen = []
def boom(a, b):
    seen.append(os.path.exists(a))   # the temp file exists at the moment of failure
    raise OSError('simulated crash before the rename')
os.replace = boom
try:
    features.write(root, {'ls-guard': {'on': False, 'why': 'new'}})
    print('NO ERROR')
except features.FeaturesError as e:
    print('raised', seen)
PYE
)
chk "a failing os.replace raises FeaturesError, after a temp file existed" "$out" "raised [True]"
chk "  ...old file intact" "$(cat "$T/ro/.claude/bendit.json")" "$before"
chk "  ...temp file cleaned up" "$(/usr/bin/find "$T/ro/.claude" -name '*.tmp')" ""
# An unserialisable value: write must raise FeaturesError, not TypeError. (The
# strict brief check now refuses it before json.dumps sees it; the outcome is
# what is pinned.)
out=$("$PY" - "$SD" "$T/ro" <<'PYE'
import sys
sys.path.insert(0, sys.argv[1])
import features
try:
    features.write(sys.argv[2], {'session-brief': {'on': True, 'why': 'x', 'brief': {'p': object()}}})
    print('NO ERROR')
except features.FeaturesError:
    print('raised')
PYE
)
chk "an unserialisable value -> FeaturesError, file untouched" "$out $(cat "$T/ro/.claude/bendit.json" | head -c 0)$([ "$(cat "$T/ro/.claude/bendit.json")" = "$before" ] && echo same)" "raised same"

echo; echo "DUPLICATE KEYS, PROJECT ROOT, CATCH-ALL"
# json.loads keeps the LAST of a repeated key; a file saying ls-guard twice must
# be refused, not read as whichever came second.
proj dup '{"version":1,"features":{"ls-guard":{"on":true,"why":"a"},"ls-guard":{"on":false,"why":"b"}}}'
cap "get on a file with a duplicate feature key" get "$T/dup" ls-guard
chk "duplicate feature key -> exit 2" "$EXPECT_CODE" "2"
has "  ...features: prefix" "features: " "$EXPECT_STDERR"
has "  ...names the file" "$T/dup/.claude/bendit.json" "$EXPECT_STDERR"
has "  ...names the key" "duplicate key 'ls-guard'" "$EXPECT_STDERR"
proj dup '{"version":1,"version":1,"features":{}}'
cap "get on a file with a duplicate top-level key" get "$T/dup" ls-guard
chk "duplicate top-level key -> exit 2" "$EXPECT_CODE" "2"; has "  ...names the key" "duplicate key 'version'" "$EXPECT_STDERR"
roots=$(CLAUDE_PROJECT_DIR= "$PY" - "$SD" "$T" <<'PYE'
import os, sys
sys.path.insert(0, sys.argv[1])
import features
os.environ.pop('CLAUDE_PROJECT_DIR', None)
here = os.getcwd()
print(features.project_root({'cwd': 5}) == here, features.project_root({'cwd': ''}) == here,
      features.project_root({'cwd': ['x']}) == here, features.project_root('junk') == here,
      features.project_root(None) == here)
gone = os.path.join(sys.argv[2], 'gone')
os.mkdir(gone); os.chdir(gone); os.rmdir(gone)
os.environ['PWD'] = '/from/pwd'
print(features.project_root({}))
del os.environ['PWD']
print(features.project_root({'cwd': 7}))
PYE
)
chk "a non-string or empty payload cwd is ignored; a deleted cwd falls back to \$PWD, then '.'" "$roots" "True True True True True
/from/pwd
."
# The CLI's catch-all must exit 2 (exit 1 is non-blocking to a hook) with the prefix.
out=$("$PY" - "$SD" 2>&1 <<'PYE'
import sys
sys.path.insert(0, sys.argv[1])
import features
def boom(root):
    raise RuntimeError('simulated bug')
features.load = boom
print('exit', features._main(['features.py', 'show', '/x']))
PYE
)
chk "a bug inside the CLI -> exit 2, features: prefix, names the error" "$out" "features: unexpected RuntimeError: simulated bug
exit 2"

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
chk "path, FEATURES, project_root precedence, load/is_on" "$api" "/r/.claude/bendit.json ('browser-driver', 'ux-design-laws', 'session-brief', 'ls-guard', 'primary-checkout-guard')
/from/payload
/from/env
True
True False"

echo; echo "PRIMARY-CHECKOUT-GUARD AND ITS integrationBranch"
# The guard's one setting: the integration branch, when origin/HEAD cannot say.
# It lives on the feature's own entry, is a plain branch name, and survives `set`.
proj ib
cap "integration-branch before the feature is set" integration-branch "$T/ib" main
chk "integration-branch with no primary-checkout-guard entry -> exit 2" "$EXPECT_CODE" "2"
has "  ...says to set the feature first" "primary-checkout-guard" "$EXPECT_STDERR"
"$PY" "$F" set "$T/ib" primary-checkout-guard on "chosen in /bendit:adopt --detailed"
cap "integration-branch develop" integration-branch "$T/ib" develop
chk "integration-branch exits 0" "$EXPECT_CODE" "0"
"$PY" "$F" set "$T/ib" primary-checkout-guard on "chosen again"
got=$("$PY" -c 'import json,sys; e=json.load(open(sys.argv[1]))["features"]["primary-checkout-guard"]; print(e["on"], e["why"], e["integrationBranch"])' "$T/ib/.claude/bendit.json")
chk "set keeps integrationBranch; on and why updated" "$got" "True chosen again develop"
cap "integration-branch with a bad name" integration-branch "$T/ib" "-x"
chk "a name starting with - -> exit 2" "$EXPECT_CODE" "2"; has "  ...names the key" "integrationBranch" "$EXPECT_STDERR"
chk "  ...file untouched" "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["features"]["primary-checkout-guard"]["integrationBranch"])' "$T/ib/.claude/bendit.json")" "develop"
bad "integrationBranch on another feature" '{"version":1,"features":{"ls-guard":{"on":true,"why":"x","integrationBranch":"main"}}}' "integrationBranch"
bad "integrationBranch empty" '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x","integrationBranch":""}}}' "integrationBranch"
bad "integrationBranch is a number" '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x","integrationBranch":5}}}' "integrationBranch"
bad "integrationBranch has a space" '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x","integrationBranch":"a b"}}}' "integrationBranch"
bad "integrationBranch has .." '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x","integrationBranch":"a..b"}}}' "integrationBranch"
proj ibok '{"version":1,"features":{"primary-checkout-guard":{"on":false,"why":"x","integrationBranch":"release/2.x"}}}'
cap "a valid integrationBranch with a slash" get "$T/ibok" primary-checkout-guard
chk "release/2.x is accepted" "$EXPECT_CODE|$EXPECT_STDOUT" "0|off"

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
