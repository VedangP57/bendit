#!/usr/bin/env bash
# new-guard.sh: name validation, refusal to overwrite, never touching settings,
# and -- the case that matters -- a scaffolded guard whose own suite passes and
# which refuses a known-bad payload, allows a known-good one and fails closed.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
NG="$SD/new-guard.sh"
pass=0; fail=0
. "$SD/expect.sh"
expect_init "$SD/new-guard.expected"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
expect_scrub_dir "$T" '<tmp>'

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
ng() { bash "$NG" "$@" >/dev/null 2>&1; echo $?; }
payload() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

P="$T/proj"; mkdir -p "$P/.claude"
printf '{\n  "permissions": {}\n}\n' > "$P/.claude/settings.json"
cp "$P/.claude/settings.json" "$T/settings.before"

echo "names"
chk "no name is a usage error"        "$(ng --project "$P")" 2
chk "uppercase is refused"            "$(ng Bad-Name --project "$P")" 2
chk "a slash is refused"              "$(ng ../escape --project "$P")" 2
chk "a leading hyphen is an option"   "$(ng -x --project "$P")" 2
chk "a trailing hyphen is refused"    "$(ng name- --project "$P")" 2
chk "one character is refused"        "$(ng a --project "$P")" 2
chk "49 characters is refused"        "$(ng "a$(printf 'b%.0s' $(seq 1 48))" --project "$P")" 2
chk "two names is a usage error"      "$(ng one two --project "$P")" 2
chk "a missing project is refused"    "$(ng ok-name --project "$T/nope")" 2
chk "nothing was written by refusals" "$(/usr/bin/find "$P" -type f | wc -l | tr -d ' ')" 1

echo "scaffold"
expect_capture "scaffold no-skip-hooks" bash "$NG" no-skip-hooks --project "$P"
chk "scaffold exits 0"                "$EXPECT_CODE" 0
H="$P/.claude/hooks"
for f in no-skip-hooks.py no-skip-hooks.test.sh shell_text.py expect.sh; do
  chk "wrote $f"                      "$([ -s "$H/$f" ] && echo yes || echo no)" yes
done
chk "no placeholder left behind"      "$(grep -l '__GUARD_NAME__' "$H"/no-skip-hooks.* | wc -l | tr -d ' ')" 0
chk "settings.json is byte-identical" "$(cmp -s "$P/.claude/settings.json" "$T/settings.before" && echo same || echo changed)" same
chk "snippet names the project path"  "$(printf '%s' "$EXPECT_STDOUT" | grep -c 'CLAUDE_PROJECT_DIR/.claude/hooks/no-skip-hooks.py')" 1

echo "refuses to overwrite"
echo '# edited by hand' >> "$H/no-skip-hooks.py"
cp "$H/no-skip-hooks.py" "$T/guard.before"
expect_capture "second scaffold of the same name" bash "$NG" no-skip-hooks --project "$P"
chk "second run exits 1"              "$EXPECT_CODE" 1
chk "the existing guard is untouched" "$(cmp -s "$H/no-skip-hooks.py" "$T/guard.before" && echo same || echo changed)" same

echo "a helper that differs is left alone"
echo '# local change' >> "$H/expect.sh"
cp "$H/expect.sh" "$T/expect.before"
chk "second guard scaffolds"          "$(ng other-guard --project "$P")" 0
chk "the local expect.sh is kept"     "$(cmp -s "$H/expect.sh" "$T/expect.before" && echo same || echo changed)" same
cp "$SD/expect.sh" "$H/expect.sh"

echo "--dir outside the project uses an absolute path"
expect_capture "scaffold into --dir outside the project" bash "$NG" outside-guard --project "$P" --dir "$T/elsewhere"
chk "exits 0"                         "$EXPECT_CODE" 0

echo "the scaffolded guard itself"
G="$H/no-skip-hooks.py"
sed -i.bak '/^# edited by hand$/d' "$G" && rm -f "$G.bak"
chk "known-bad payload exits 2"       "$(payload 'git commit --no-verify -m x' | python3 "$G" >/dev/null 2>&1; echo $?)" 2
chk "known-good payload exits 0"      "$(payload 'git commit -m x' | python3 "$G" >/dev/null 2>&1; echo $?)" 0
chk "junk payload fails closed"       "$(printf 'junk' | python3 "$G" >/dev/null 2>&1; echo $?)" 2
# Its own suite: first run records the snapshot (and must FAIL, by design),
# the second compares against it and must pass.
chk "its suite: --accept run fails"   "$(bash "$H/no-skip-hooks.test.sh" --accept >/dev/null 2>&1; echo $?)" 1
chk "its suite: second run passes"    "$(bash "$H/no-skip-hooks.test.sh" >/dev/null 2>&1; echo $?)" 0
# Falsify the suite: a guard that allows everything must turn it red.
cp "$G" "$T/guard.good"
sed -i.bak "s/return '--no-verify' in args/return False and '--no-verify' in args/" "$G" && rm -f "$G.bak"
chk "falsified: mutation was applied" "$(grep -c 'return False and' "$G")" 1
chk "its suite fails on a dead rule"  "$(bash "$H/no-skip-hooks.test.sh" >/dev/null 2>&1; echo $?)" 1
cp "$T/guard.good" "$G"

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
