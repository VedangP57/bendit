#!/usr/bin/env bash
# Tests for __GUARD_NAME__.py. Scaffolded by bendit's new-guard.sh.
#
#   bash __GUARD_NAME__.test.sh            run it
#   bash __GUARD_NAME__.test.sh --accept   record the message snapshot, then READ
#                                          __GUARD_NAME__.expected and run again
#
# Three kinds of case, and every rule you add needs the first two:
#   BLOCK  a known-bad payload must exit 2 with its reason on stderr
#   ALLOW  near-misses must exit 0 -- a guard that fires on ordinary work gets
#          uninstalled, so keep this list longer than the BLOCK list
#   CRASH  anything the guard cannot read or finish must exit 2 (fail closed)
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/__GUARD_NAME__.py"
pass=0; fail=0

if [ ! -f "$SD/expect.sh" ]; then
  echo "FAIL  expect.sh is not beside this suite, so NOTHING was tested" >&2; exit 2
fi
. "$SD/expect.sh"
expect_init "$SD/__GUARD_NAME__.expected"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
expect_scrub_dir "$T" '<tmp>'

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
payload() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
run() { payload "$1" | python3 "$H" >/dev/null 2>&1; echo $?; }

echo "BLOCK"
chk "commit --no-verify"           "$(run 'git commit --no-verify -m wip')" 2
chk "push --no-verify"             "$(run 'git push --no-verify origin HEAD')" 2
chk "commit -n"                    "$(run 'git commit -n -m wip')" 2
chk "behind a wrapper and a ;"     "$(run 'cd x; sudo git -C . push --no-verify')" 2
chk "inside bash -c"               "$(run "bash -c 'git commit --no-verify'")" 2

echo "ALLOW"
chk "plain commit"                 "$(run 'git commit -m "add the thing"')" 0
chk "the flag inside a message"    "$(run 'git commit -m "never use --no-verify"')" 0
chk "a different command"          "$(run 'grep -r -- --no-verify docs/')" 0
chk "empty command"                "$(run '')" 0
chk "a non-Bash tool"              "$(printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | python3 "$H" >/dev/null 2>&1; echo $?)" 0

echo "CRASH (fail closed)"
chk "payload is not JSON"          "$(printf 'not json' | python3 "$H" >/dev/null 2>&1; echo $?)" 2
chk "no tool_input"                "$(printf '{"tool_name":"Bash"}' | python3 "$H" >/dev/null 2>&1; echo $?)" 2
chk "command is not a string"      "$(printf '{"tool_name":"Bash","tool_input":{"command":7}}' | python3 "$H" >/dev/null 2>&1; echo $?)" 2
# The guard alone, without the shell_text.py it imports: a real crash.
cp "$H" "$T/alone.py"
chk "helper missing -> refuses"    "$(payload 'git status' | python3 "$T/alone.py" >/dev/null 2>&1; echo $?)" 2

# What the agent is told is the product; snapshot it (stderr and stdout apart).
expect_capture "block: commit --no-verify" python3 "$H" <<<"$(payload 'git commit --no-verify -m wip')"
expect_capture "allow: plain commit" python3 "$H" <<<"$(payload 'git commit -m ok')"
expect_capture "crash: helper missing" python3 "$T/alone.py" <<<"$(payload 'git status')"
echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo
echo "$pass passed, $fail failed"
# Zero cases is never a pass.
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
