#!/usr/bin/env bash
# Fixture test for eval-freeze.py.
# The script resolves its root from its own location, so every case runs
# against a throwaway plugin-shaped tree in a temp dir, never against this repo.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/eval-freeze.py"
# PY picks the interpreter under test. Left unset, the suite runs on python3 and
# then AGAIN on /usr/bin/python3 (3.9 on macOS), the oldest one supported.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
pass=0; fail=0

chk() { # chk <label> <got> <want>
  if [ "$2" = "$3" ]; then printf '  ok    %-60s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %-60s got %s, wanted %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

T="$(mktemp -d)"
trap 'rm -r "$T"' EXIT
F="$PY $T/scripts/eval-freeze.py"
run() { $F "$@" >/dev/null 2>&1; echo $?; }
says() { $F verify "$1" 2>&1 | grep -c -- "$2"; }   # says <freeze> <line>

echo "AN EMPTY TREE IS REFUSED, NOT FROZEN"
mkdir -p "$T/scripts"
cp "$SRC" "$T/scripts/"
# scripts/*.py is watched, so the script would freeze itself. For this one case
# run it from one level deeper, where its root is a directory holding nothing.
mkdir -p "$T/scripts/__pycache__" && mv "$T/scripts/eval-freeze.py" "$T/scripts/__pycache__/"
F="$PY $T/scripts/__pycache__/eval-freeze.py"
# ROOT is the script's grandparent, i.e. $T/scripts here: an empty tree.
chk "freeze of an empty tree refuses"                 "$(run freeze e0)" 1
chk "  ...and writes no freeze file" "$([ -e "$T/scripts/evals/freezes/e0.json" ] && echo yes || echo no)" no
mv "$T/scripts/__pycache__/eval-freeze.py" "$T/scripts/"
rmdir "$T/scripts/__pycache__"
F="$PY $T/scripts/eval-freeze.py"

echo "THE BASIC CONTRACT"
mkdir -p "$T/skills/demo/references" "$T/evals/a-case" "$T/commands" "$T/hooks" "$T/.claude-plugin"
printf 'skill text\n'    > "$T/skills/demo/SKILL.md"
printf 'reference\n'     > "$T/skills/demo/references/more.md"
printf 'name: a-case\n'  > "$T/evals/a-case/case.yaml"
printf 'mkdir x\n'       > "$T/evals/a-case/fixture.sh"
printf '# cmd\n'         > "$T/commands/go.md"
printf '{}\n'            > "$T/hooks/hooks.json"
printf '{"name":"p"}\n'  > "$T/.claude-plugin/plugin.json"
printf 'print(1)\n'      > "$T/scripts/guard.py"
printf 'echo hi\n'       > "$T/scripts/grade.sh"

chk "verify with no freeze refuses"                   "$(run verify r1)" 1
chk "freeze records the tree"                         "$(run freeze r1)" 0
chk "the manifest exists" "$([ -f "$T/evals/freezes/r1.json" ] && echo yes || echo no)" yes
chk "freezing the same name twice refuses"            "$(run freeze r1)" 1
chk "verify straight after freeze is clean"           "$(run verify r1)" 0
chk "the freeze records its watch list and version" \
  "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(bool(d["watched"]), d["watch_version"])' "$T/evals/freezes/r1.json")" "True 1"
chk "outside a git repo the commit is 'unknown', not invented" \
  "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["commit"], d["dirty"])' "$T/evals/freezes/r1.json")" "unknown unknown"

echo "EVERY WATCHED KIND OF FILE TRIPS VERIFY WHEN EDITED"
# The case this exists for: something that can move a score is edited while
# the runs are happening. Hooks and scripts are on the list -- a freeze that
# hashes only skills says nothing about the guard the with-arm actually ran.
for f in skills/demo/SKILL.md skills/demo/references/more.md evals/a-case/case.yaml \
         evals/a-case/fixture.sh commands/go.md hooks/hooks.json .claude-plugin/plugin.json \
         scripts/guard.py scripts/grade.sh scripts/eval-freeze.py; do
  cp "$T/$f" "$T/$f.orig"; printf '\n# moved\n' >> "$T/$f"
  chk "an edited $f fails verification"               "$(run verify r1)" 1
  chk "  ...and names it as CHANGED"                  "$(says r1 "CHANGED  $f")" 1
  mv "$T/$f.orig" "$T/$f"
done
chk "restoring them all passes again"                 "$(run verify r1)" 0

echo "ADDED, REMOVED, AND WHAT IS NOT WATCHED"
printf 'name: b\n' > "$T/evals/b-case-notes.yaml"            # not a watched path
chk "an unwatched file does not trip it"              "$(run verify r1)" 0
mkdir -p "$T/evals/results/2026-01-01" && printf '{}\n' > "$T/evals/results/2026-01-01/case.yaml"
chk "run output under evals/results/ does not trip it" "$(run verify r1)" 0
mkdir -p "$T/skills/demo/__pycache__" && printf 'x' > "$T/skills/demo/__pycache__/c.pyc"
chk "a bytecode cache does not trip it"               "$(run verify r1)" 0
mkdir -p "$T/evals/b-case" && printf 'name: b\n' > "$T/evals/b-case/case.yaml"
chk "a NEW case trips it"                             "$(run verify r1)" 1
chk "  ...and it says ADDED"                          "$(says r1 'ADDED    evals/b-case/case.yaml')" 1
rm -r "$T/evals/b-case"
mv "$T/hooks/hooks.json" "$T/hooks.json.away"
chk "a REMOVED hooks.json trips it"                   "$(run verify r1)" 1
chk "  ...and it says REMOVED"                        "$(says r1 'REMOVED  hooks/hooks.json')" 1
mv "$T/hooks.json.away" "$T/hooks/hooks.json"
chk "CONTROL: back to clean"                          "$(run verify r1)" 0

echo "A FREEZE IS VERIFIED AGAINST THE WATCH LIST IT RECORDED"
# Widening WATCHED later must not turn an honest old freeze into a false
# failure. Simulate an older, narrower freeze: skills only.
"$PY" - "$T/evals/freezes/r1.json" "$T/evals/freezes/narrow.json" <<'MK'
import json, sys
d = json.load(open(sys.argv[1]))
d['watched'] = [['skills', '**/*']]
d['watch_version'] = 0
d['files'] = {k: v for k, v in d['files'].items() if k.startswith('skills/')}
json.dump(d, open(sys.argv[2], 'w'))
MK
chk "a narrower freeze verifies clean"                "$(run verify narrow)" 0
chk "  ...without a false ADDED for hooks or scripts" "$(says narrow ADDED)" 0
printf 'skill text, tweaked\n' > "$T/skills/demo/SKILL.md"
chk "CONTROL: it still catches what it DID watch"     "$(run verify narrow)" 1
printf 'skill text\n' > "$T/skills/demo/SKILL.md"
# A freeze carrying only a known version number uses that version's patterns.
"$PY" - "$T/evals/freezes/r1.json" "$T/evals/freezes/versioned.json" <<'MK'
import json, sys
d = json.load(open(sys.argv[1])); del d['watched']
json.dump(d, open(sys.argv[2], 'w'))
MK
chk "a freeze with only watch_version: 1 verifies"    "$(run verify versioned)" 0
printf '\n# moved\n' >> "$T/scripts/guard.py"
chk "CONTROL: ...and catches an edited hook script"   "$(run verify versioned)" 1
"$PY" -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("\n# moved\n",""))' "$T/scripts/guard.py"
chk "CONTROL: restored"                               "$(run verify versioned)" 0

echo "MALFORMED FREEZES ARE REFUSED, NEVER PASSED"
# Correct hashes, so the ONLY reason to refuse is the missing watch list.
"$PY" - "$T/evals/freezes/r1.json" "$T/evals/freezes/nolist.json" <<'MK'
import json, sys
d = json.load(open(sys.argv[1])); del d['watched']; del d['watch_version']
json.dump(d, open(sys.argv[2], 'w'))
MK
chk "no watch list and no known version: refused"     "$(run verify nolist)" 1
chk "  ...saying why"                                 "$(says nolist 'records neither a watch list')" 1
printf '{"watch_version": 1, "files": {}}\n' > "$T/evals/freezes/empty.json"
chk "a freeze of zero files: refused"                 "$(run verify empty)" 1
printf 'not json\n' > "$T/evals/freezes/garbage.json"
chk "a file that is not JSON: refused"                "$(run verify garbage)" 1
chk "no subcommand prints usage, exit 2"              "$(run)" 2

if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
