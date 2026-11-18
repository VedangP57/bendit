#!/usr/bin/env bash
# A command that hides its errors and returns nothing has told you nothing --
# but it looks exactly like a command that ran fine and found nothing.
#
# The shape of the wrong conclusion:
#   /opt/tool/bin/find ... 2>/dev/null  -> empty, read as "no harnesses exist"
#   ls -1 missing-dir 2>/dev/null       -> empty, read as "the directory is empty"
# Both were `no such file or directory`, swallowed by the redirect.
#
# This WARNS, it never blocks. Suppressing stderr is legitimate constantly, so
# a gate that refuses it would be uninstalled within a day. The warning fires
# only when stdout is ALSO empty, which is the moment the mistake is made.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/warn-suppressed-stderr.py"
pass=0; fail=0
. "$SD/expect.sh"
expect_init "$SD/warn-suppressed-stderr.expected"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# run <command> <stdout> [noOutputExpected]
run() {
  python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},
 "tool_response":{"stdout":sys.argv[2],"stderr":"",
 "noOutputExpected":sys.argv[3]=="1","interrupted":False}}))' "$1" "$2" "${3:-0}" \
  | python3 "$H" >/dev/null 2>&1; echo $?
}

echo "MUST WARN: stderr hidden AND nothing came back"
chk "2>/dev/null with empty output"      "$(run 'find . -name x 2>/dev/null' '')" "2"
chk "spaced 2> /dev/null"                "$(run 'find . 2> /dev/null' '')" "2"
chk "&>/dev/null"                        "$(run 'ls dir &>/dev/null' '')" "2"
chk "2>&- closes the stream"             "$(run 'grep x f 2>&-' '')" "2"
chk "piped, output still empty"          "$(run 'find . 2>/dev/null | wc -l' '')" "2"
chk "whitespace-only output counts as empty" "$(run 'find . 2>/dev/null' '
  ')" "2"

chk ">& /dev/null (both streams)"        "$(run 'grep x f >& /dev/null' '')" "2"
chk "&>/dev/null with no space before"   "$(run 'grep x f&>/dev/null' '')" "2"
chk "&>> /dev/null"                      "$(run 'grep x f &>> /dev/null' '')" "2"
chk "2>>/dev/null appends to nowhere"    "$(run 'find . -name x 2>>/dev/null' '')" "2"
chk "1>/dev/null 2>&1"                   "$(run 'grep x f 1>/dev/null 2>&1' '')" "2"
# A count of nothing is the same non-answer as no output at all: `wc -l` on an
# empty, failed find prints 0.
chk "piped into wc, printed 0"           "$(run 'find x 2>/dev/null | wc -l' '       0')" "2"
chk "grep -c printed 0"                  "$(run 'grep -c x f 2>/dev/null' '0')" "2"

echo
echo "MUST STAY SILENT -- the half that keeps this installed"
chk "a NON-zero count came back"         "$(run 'find x 2>/dev/null | wc -l' '3')" "0"
chk "2>&1 >/dev/null keeps stderr"       "$(run 'grep x f 2>&1 >/dev/null' '')" "0"
chk ">&2 moves stdout to stderr"         "$(run 'echo hi >&2' '')" "0"
chk "redirect text inside quotes"        "$(run 'echo "use 2>/dev/null sparingly" >/dev/null' '')" "0"
# Each of these is an ordinary command. If any warns, the hook is noise.
chk "stderr hidden but output CAME BACK"  "$(run 'find . 2>/dev/null' 'a
b')" "0"
chk "empty output but stderr NOT hidden"  "$(run 'find . -name zzz' '')" "0"
chk "neither"                             "$(run 'echo hi' 'hi')" "0"
chk "a command that expects no output"    "$(run 'mkdir -p x 2>/dev/null' '' 1)" "0"
chk "redirecting STDOUT only"             "$(run 'noisy >/dev/null' '')" "0"
chk "the text appears inside a quoted heredoc" "$(run "cat > t.sh <<'EOF'
find . 2>/dev/null
EOF" 'wrote')" "0"
# CONTROL for the heredoc case: the same text OUTSIDE one must still warn, or
# the stripper could be blanking every command.
chk "CONTROL: same text outside a heredoc warns" "$(run 'find . 2>/dev/null' '')" "2"

echo
echo "A PAYLOAD OF THE WRONG SHAPE IS IGNORED, NOT A CRASH"
chk "tool_input is a string" "$(echo '{"tool_input":"x 2>/dev/null","tool_response":{"stdout":""}}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "tool_input is a list"   "$(echo '{"tool_input":["x"]}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

echo
echo "A CRASH INSIDE THE CHECK IS SAID, NOT SWALLOWED"
# Forced by replacing the detector with one that raises. Exit 1 with a
# traceback would read to the agent as "nothing to warn about".
crash() {
  printf '{"tool_input":{"command":"find . 2>/dev/null"},"tool_response":{"stdout":""}}' | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(_text): raise RuntimeError("synthetic")
guard.suppresses_stderr = boom
sys.exit(guard.run())' "$H" 2>&1 >/dev/null
  echo "exit=$?"
}
case "$(crash)" in
  *"check itself failed"*"exit=2") printf '  ok    %s\n' "a crash inside the check exits 2 with a reason"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash inside the check exits 2 with a reason" "$(crash | tail -1)"; fail=$((fail+1));;
esac

echo
echo "WHAT IT SAYS (snapshot)"
expect_capture "warning text" python3 "$H" <<< "$(python3 -c '
import json
print(json.dumps({"tool_name":"Bash","tool_input":{"command":"find . -name x 2>/dev/null"},
 "tool_response":{"stdout":"","stderr":"","noOutputExpected":False,"interrupted":False}}))')"
expect_capture "warning text: a count of zero" python3 "$H" <<< "$(python3 -c '
import json
print(json.dumps({"tool_name":"Bash","tool_input":{"command":"find x 2>/dev/null | wc -l"},
 "tool_response":{"stdout":"       0\n","stderr":"","noOutputExpected":False,"interrupted":False}}))')"
expect_verify && pass=$((pass+1)) || fail=$((fail+1))

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
