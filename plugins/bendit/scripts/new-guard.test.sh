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
# Running a guard (or its tests) leaves __pycache__/ beside it; a live
# /bendit:new-guard run did exactly that. The hooks dir ignores it from the start.
chk "writes a .gitignore for __pycache__ in the hooks dir" \
    "$(grep -qx '__pycache__/' "$H/.gitignore" 2>/dev/null && echo yes || echo no)" yes
printf 'keep-me\n' > "$H/.gitignore"
bash "$NG" another-guard --project "$P" >/dev/null 2>&1
chk "  ...and leaves a .gitignore the project already has alone" "$(/bin/cat "$H/.gitignore")" "keep-me"
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

echo "--replay: a guard must refuse a real past command and allow ordinary ones"
# Adapted from poteto's pstack: prove each check catches a real past mistake
# before trusting it. These guards are tiny hand-written ones, so each case
# tests new-guard.sh's verdict, not a template rule.
mkguard() {  # mkguard <name> <python expression over `cmd`, True to refuse> [stderr text]
  cat > "$H/$1.py" <<EOF
import json, sys
try:
    cmd = json.load(sys.stdin)['tool_input']['command']
    if $2:
        print('${3-BLOCKED by $1: test rule.}', file=sys.stderr, end='')
        sys.exit(2)
except SystemExit:
    raise
except Exception:
    print('BLOCKED by $1: could not read the payload.', file=sys.stderr)
    sys.exit(2)
EOF
}
mkguard no-force-push "'--force' in cmd.split()"
mkguard blocks-all "True"
mkguard blocks-nothing "False"
mkguard blocks-git-push "cmd.startswith('git push')"
mkguard silent-block "'--force' in cmd.split()" ""
printf 'this is not python\n' > "$H/broken-guard.py"
cp "$P/.claude/settings.json" "$T/settings.before"
rp() { bash "$NG" "$1" --project "$P" "${@:2}" >/dev/null 2>&1; echo $?; }

expect_capture "replay: a guard that refuses the real command and allows the built-in list" \
  bash "$NG" no-force-push --project "$P" --replay "git push --force origin main"
chk "a guard that catches it and allows ordinary work is accepted" "$EXPECT_CODE" 0
expect_capture "replay: a guard that does not refuse the real command" \
  bash "$NG" blocks-nothing --project "$P" --replay "git push --force origin main"
chk "a guard that lets the real command through is rejected"       "$EXPECT_CODE" 1
expect_capture "replay: a guard that refuses everything" \
  bash "$NG" blocks-all --project "$P" --replay "git push --force origin main"
chk "a guard that refuses ordinary commands is rejected"           "$EXPECT_CODE" 1
chk "the template, before its rule is written, is rejected" \
    "$(rp no-skip-hooks --replay 'git push --force origin main')" 1
chk "the template proves itself on its own example mistake" \
    "$(rp no-skip-hooks --replay 'git commit --no-verify -m wip')" 0
chk "every replay must be refused, not just one" \
    "$(rp no-force-push --replay 'git push --force origin main' --replay 'git push origin main')" 1
chk "exit 2 with no reason on stderr is rejected (the agent retries blind)" \
    "$(rp silent-block --replay 'git push --force origin main')" 1
chk "a guard that crashes is rejected, never counted as a refusal" \
    "$(rp broken-guard --replay 'git push --force origin main')" 1

printf 'git status\n\n# a comment line is skipped\ngit push origin main\n' > "$T/ordinary.txt"
chk "--allow-file: an ordinary command it refuses rejects the guard" \
    "$(rp blocks-git-push --replay 'git push --force origin main' --allow-file "$T/ordinary.txt")" 1
printf 'git status\nls -la\n' > "$T/ordinary2.txt"
chk "--allow-file: replaces the built-in list"  \
    "$(rp blocks-git-push --replay 'git push --force origin main' --allow-file "$T/ordinary2.txt")" 0
chk "without --allow-file the built-in list catches the same guard" \
    "$(rp blocks-git-push --replay 'git push --force origin main')" 1
printf '\n# only comments\n' > "$T/empty.txt"
chk "--allow-file with no commands is bad usage (nothing allowed is no proof)" \
    "$(rp no-force-push --replay 'git push --force origin main' --allow-file "$T/empty.txt")" 2
chk "--allow-file that does not exist is bad usage" \
    "$(rp no-force-push --replay 'git push --force origin main' --allow-file "$T/nope.txt")" 2
chk "--allow-file without --replay is bad usage (no real command, no proof)" \
    "$(rp no-force-push --allow-file "$T/ordinary2.txt")" 2
chk "an empty --replay is bad usage"            "$(rp no-force-push --replay '')" 2
chk "--replay with no value is bad usage"       "$(rp no-force-push --replay)" 2
chk "--replay on a guard that does not exist is refused" \
    "$(rp not-scaffolded --replay 'git push --force origin main')" 1
chk "--replay scaffolds nothing" "$([ -e "$H/not-scaffolded.py" ] && echo wrote || echo none)" none
chk "settings.json is byte-identical after every replay" \
    "$(cmp -s "$P/.claude/settings.json" "$T/settings.before" && echo same || echo changed)" same

# The replayed text comes from logs and transcripts: it is printed redacted.
out="$(bash "$NG" blocks-nothing --project "$P" --replay 'git push --force https://bot:hunter2secretpw@10.0.0.1/r.git main' 2>&1)"
chk "a credential in a replayed command is never printed"  "$(printf '%s' "$out" | grep -c hunter2secretpw)" 0
chk "  ...and the command is still shown, redacted"        "$(printf '%s' "$out" | grep -c 'git push --force https://')" 1
printf 'curl -u admin:hunter2secretpw https://example.com\n' > "$T/secret.txt"
out="$(bash "$NG" blocks-all --project "$P" --replay 'x' --allow-file "$T/secret.txt" 2>&1)"
chk "a credential in an ordinary command is never printed" "$(printf '%s' "$out" | grep -c hunter2secretpw)" 0
chk "  ...and it is still shown, redacted"                 "$(printf '%s' "$out" | grep -c 'curl -u')" 1

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
