#!/usr/bin/env bash
# A budget that cannot fail is not a budget. Every case below drives the real
# script against a fixture directory and checks the exit code it reports.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
B="$SD/skill-budget.py"
# PY picks the interpreter under test. Left unset, the suite runs on python3 and
# then AGAIN on /usr/bin/python3 (3.9 on macOS), the oldest Python the kit supports.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
T=$(mktemp -d); pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

skill() { mkdir -p "$T/$1"; printf -- '---\nname: %s\ndescription: %s\n---\n\n# x\n' "$1" "$2" > "$T/$1/SKILL.md"; }
# --commands points at a directory that does not exist: these fixtures are about
# skills, and must not pick up whatever sits beside the temp dir.
run()   { "$PY" "$B" --dir "$T" --commands "$T/no-commands" >/dev/null 2>&1; echo $?; }

# 300 chars each: six fit under 2800, ten do not.
LONG=$(printf 'x%.0s' $(seq 1 300))
for i in 1 2 3 4 5 6; do skill "s$i" "$LONG"; done
chk "six skills of 300 are under the total cap" "$(run)" "0"

for i in 7 8 9 10; do skill "s$i" "$LONG"; done
chk "ten of 300 exceeds the total cap -> fails"  "$(run)" "1"

rm -r "$T"; T=$(mktemp -d)
HUGE=$(printf 'y%.0s' $(seq 1 601))
skill "one-fat-skill" "$HUGE"
chk "a single description over the per-skill cap fails" "$(run)" "1"

rm -r "$T"; T=$(mktemp -d)
skill "modest" "a short description"
chk "a modest suite passes"                      "$(run)" "0"

# A check that cannot look must never report a pass.
chk "a directory with no SKILL.md is exit 2, not 0" \
    "$("$PY" "$B" --dir "$T/nothing-here" >/dev/null 2>&1; echo $?)" "2"
mkdir -p "$T/empty"
chk "an empty skills dir is exit 2, not 0" \
    "$("$PY" "$B" --dir "$T/empty" >/dev/null 2>&1; echo $?)" "2"

# A SKILL.md whose frontmatter does not parse once counted as 0 characters and
# PASSED -- a leading BOM was enough. Not being able to read a description is
# not a cheap description.
rm -r "$T"; T=$(mktemp -d)
skill "modest" "a short description"
mkdir -p "$T/bom"; printf '\xef\xbb\xbf---\nname: bom\ndescription: hidden cost\n---\n' > "$T/bom/SKILL.md"
chk "a SKILL.md with a BOM before its frontmatter fails, not 0" "$(run)" "2"
rm -r "$T/bom"; mkdir -p "$T/nodesc"; printf -- '---\nname: nodesc\n---\n# x\n' > "$T/nodesc/SKILL.md"
chk "a SKILL.md with no description fails, not 0" "$(run)" "2"
rm -r "$T/nodesc"
chk "CONTROL: the same dir without them passes" "$(run)" "0"

# Commands are in the same listing, and so is each entry's `<plugin>:<name>`.
rm -r "$T"; T=$(mktemp -d)
for i in 1 2 3 4 5 6; do skill "s$i" "$LONG"; done
mkdir -p "$T/cmds"
for i in 1 2 3 4; do printf -- '---\ndescription: %s\n---\nbody\n' "$LONG" > "$T/cmds/c$i.md"; done
chk "CONTROL: the six skills alone are under the cap" "$(run)" "0"
chk "skills plus 4 commands of 300 exceed it" \
    "$("$PY" "$B" --dir "$T" --commands "$T/cmds" >/dev/null 2>&1; echo $?)" "1"
out=$("$PY" "$B" --dir "$T" --commands "$T/cmds" 2>&1)
case "$out" in *":c1"*) printf '  ok    %s\n' "commands are listed by their listing name"; pass=$((pass+1));;
  *) printf '  FAIL  %s\n%s\n' "commands are listed by their listing name" "$out"; fail=$((fail+1));; esac
# The prefix counts. Its length is read from the script itself (one skill
# "s1" with a 1-char description is listed as len("<plugin>:s1") + 1), then 9
# skills are sized to list at 2799 together; one more of 3 chars is under the
# cap bare but over it listed.
rm -r "$T"; T=$(mktemp -d)
skill "s1" "a"
LISTED1=$("$PY" "$B" --dir "$T" --commands "$T/no-commands" 2>/dev/null | awk '/s1$/ {print $1}')
NAMED=$((LISTED1 - 1))                 # len("<plugin>:sN")
L=$((311 - NAMED))                     # 9 * (L + NAMED) = 2799
rm -r "$T"; T=$(mktemp -d)
LD=$(printf 'z%.0s' $(seq 1 "$L"))
for i in 1 2 3 4 5 6 7 8 9; do skill "s$i" "$LD"; done
chk "CONTROL: nine skills listed at 2799 are under the cap" "$(run)" "0"
skill "sx" "abc"
chk "the <plugin>:<name> prefix is counted" "$(run)" "1"

# The listing prefix is the MEASURED plugin's name (its plugin.json beside the
# --dir skills folder), not bendit's. "xy" is shorter than "bendit", so the
# wrong prefix changes the printed row.
rm -r "$T"; T=$(mktemp -d)
mkdir -p "$T/x/.claude-plugin" "$T/x/skills/s"
printf '{"name":"xy","version":"0.0.1"}\n' > "$T/x/.claude-plugin/plugin.json"
printf -- '---\nname: s\ndescription: a\n---\n' > "$T/x/skills/s/SKILL.md"
row="$("$PY" "$B" --dir "$T/x/skills" --commands "$T/no-commands" 2>&1 | awk '/xy:s$|bendit:s$/ {print $1, $2}')"
chk "the prefix is the measured plugin's own name (xy:s, 4+1 chars)" "$row" "5 xy:s"

# The real suite must be under budget, or CI is red for a reason nobody chose.
chk "the SHIPPED skills are within budget" \
    "$("$PY" "$B" >/dev/null 2>&1; echo $?)" "0"

rm -r "$T"
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
