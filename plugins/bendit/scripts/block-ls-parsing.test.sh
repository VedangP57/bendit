#!/usr/bin/env bash
# Both halves, plus the feature gate. The "must stay silent" list is longer than
# the "must block" one, because a guard that fires on an ordinary `ls` gets
# uninstalled within a day -- and a bare `ls` is what a decorated `ls` is FOR.
#
# The guard runs only where .claude/bendit.json turns ls-guard on. Every case
# below uses a project with it on (the payload's cwd), except the gate section
# at the end. EVERY control passes against a permit-everything stub as well as
# the real guard; that is what keeps them from measuring the guard's absence.
#
#   bash block-ls-parsing.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/block-ls-parsing.py"
pass=0; fail=0
# The project root comes from CLAUDE_PROJECT_DIR first; unset it so these cases
# resolve the project from the payload's cwd like any hook run outside Claude.
unset CLAUDE_PROJECT_DIR
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/on" "$T/off" "$T/bad" "$T/none"
python3 "$SD/features.py" set "$T/on" ls-guard on "ls is a formatter" || exit 1
python3 "$SD/features.py" set "$T/off" ls-guard off "plain ls" || exit 1
mkdir -p "$T/bad/.claude"; printf '{"version": 1, "features": ' > "$T/bad/.claude/bendit.json"
. "$SD/expect.sh"
expect_init "$SD/block-ls-parsing.expected"
expect_scrub_dir "$T" '<tmp>'
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
pl() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "${2:-$T/on}"; }
run() { pl "$1" "${2:-$T/on}" | python3 "$H" >/dev/null 2>&1; echo $?; }

# --- must BLOCK: ls output CONSUMED by something -----------------------------
# The inflated count is never flagged: the pipeline exits 0 and the number is
# plausible. That is what makes it worth a hook.
chk "piped to wc"                     "$(run 'ls | wc -l')" "2"
chk "piped to grep"                   "$(run 'ls -la | grep foo')" "2"
chk "piped to head"                   "$(run 'ls /tmp | head -5')" "2"
chk "piped to tail"                   "$(run 'ls | tail -3')" "2"
chk "piped to awk"                    "$(run 'ls | awk NR==1')" "2"
chk "piped to sed"                    "$(run 'ls | sed -n 1p')" "2"
chk "piped to sort"                   "$(run 'ls | sort')" "2"
chk "piped to uniq"                   "$(run 'ls | uniq')" "2"
chk "piped to xargs"                  "$(run 'ls | xargs echo')" "2"
chk "piped through a while read"      "$(run 'ls | while read f; do :; done')" "2"
chk "second hop of the pipeline"      "$(run 'ls -1 | sort | wc -l')" "2"
chk "captured by \$( )"               "$(run 'n=$(ls)')" "2"
chk "captured by backticks"           "$(run 'n=`ls`')" "2"
chk "captured, then counted inside"   "$(run 'echo $(ls -1 /tmp | wc -l)')" "2"
chk "feeding a for ... in"            "$(run 'for f in $(ls); do echo $f; done')" "2"
chk "ls deeper inside a capture"      "$(run 'n=$(cd /tmp && ls)')" "2"
chk "on its own line"                 "$(run 'cd /tmp
ls | wc -l')" "2"
chk "after a semicolon"               "$(run 'cd /tmp; ls | wc -l')" "2"
chk "after &&"                        "$(run 'cd /tmp && ls | wc -l')" "2"
chk "inside a subshell"               "$(run '(ls | wc -l)')" "2"
# A leading backslash suppresses ALIAS expansion only; when `ls` is a FUNCTION,
# `\ls` still runs the formatter, so it is not an escape hatch.
chk "backslash-ls does NOT escape a function" "$(run '\ls | wc -l')" "2"

# --- must STAY SILENT: controls ----------------------------------------------
# A bare `ls` is what the formatter is FOR. Refusing it would make the hook
# worse than useless.
chk "bare ls"                         "$(run 'ls')" "0"
chk "ls with flags"                   "$(run 'ls -la')" "0"
chk "ls with a path"                  "$(run 'ls -la /tmp/foo')" "0"
chk "ls then an unrelated command"    "$(run 'ls; echo done')" "0"
chk "ls redirected to a file"         "$(run 'ls > /tmp/out')" "0"
# The escape hatches the message names.
chk "ESCAPE: /bin/ls is the real binary"   "$(run '/bin/ls | wc -l')" "0"
chk "ESCAPE: command ls skips the function" "$(run 'command ls | wc -l')" "0"
# An absolute path is never the formatter, and a missing binary fails LOUDLY,
# which is the opposite of the silent miscount this hook exists for.
chk "ESCAPE: /usr/bin/ls spelling"    "$(run '/usr/bin/ls | wc -l')" "0"
# Letters "ls", not the command.
chk "git ls-files is not ls"          "$(run 'git ls-files | wc -l')" "0"
chk "npm ls is not ls"                "$(run 'npm ls --depth 0 | wc -l')" "0"
chk "lsof is not ls"                  "$(run 'lsof -i | wc -l')" "0"
chk "a word containing ls"            "$(run 'echo results | wc -l')" "0"
chk "ls inside a single-quoted string" "$(run "echo 'ls | wc -l'")" "0"
chk "a variable named controls"       "$(run 'controls=5; echo $controls')" "0"
chk "no ls at all"                    "$(run 'git status --short | wc -l')" "0"
chk "junk stdin is allowed"           "$(echo 'not json' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "no command field"                "$(echo '{"tool_name":"Bash","tool_input":{}}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

# The message is the only thing telling the author what to run instead.
expect_capture "blocked: ls piped into wc" python3 "$H" <<< "$(pl 'ls | wc -l')"
expect_capture "blocked: ls captured by \$( )" python3 "$H" <<< "$(pl 'for f in $(ls); do echo $f; done')"
echo
echo "--- the feature gate: ls-guard must be ON, in this project's bendit.json ---"
# CONTROL for everything below: the same command blocks where the feature is on.
chk "CONTROL: ls | wc -l blocks with ls-guard on"      "$(run 'ls | wc -l' "$T/on")" "2"
chk "no bendit.json at all allows"                     "$(run 'ls | wc -l' "$T/none")" "0"
chk "ls-guard off allows"                              "$(run 'ls | wc -l' "$T/off")" "0"
python3 "$SD/features.py" set "$T/off" browser-driver on "another feature on, ls-guard still off" || exit 1
chk "another feature on, ls-guard off, allows"         "$(run 'ls | wc -l' "$T/off")" "0"
# FAIL CLOSED: a malformed file is never read as "off".
chk "a malformed bendit.json refuses"                  "$(run 'ls | wc -l' "$T/bad")" "2"
# ...but only a command the ls check refuses: a broken file must not lock out
# git status, or the Edit tool that would fix it.
chk "  ...a command with no ls still runs"             "$(run 'echo hi' "$T/bad")" "0"
chk "  ...git status still runs"                       "$(run 'git status' "$T/bad")" "0"
chk "  ...cat of the file itself still runs"           "$(run 'cat .claude/bendit.json' "$T/bad")" "0"
chk "  ...a bare ls still runs"                        "$(run 'ls -la' "$T/bad")" "0"
expect_capture "blocked: malformed bendit.json" python3 "$H" <<< "$(pl 'ls | wc -l' "$T/bad")"
printf '{"version": 1, "features": {"ls-guard": {"on": true, "why": "x"}, "ls-guard": {"on": false, "why": "y"}}}' > "$T/bad/.claude/bendit.json"
chk "a duplicate key refuses (fail closed)"            "$(run 'ls | wc -l' "$T/bad")" "2"
# A file from a newer bendit: its unknown feature written OFF is read past (the
# guard still gates on ls-guard); one written ON refuses, like any malformed file.
mkdir -p "$T/newer/.claude"
printf '{"version":1,"features":{"ls-guard":{"on":true,"why":"x"},"teleport-guard":{"on":false,"why":"later"}}}' > "$T/newer/.claude/bendit.json"
chk "newer bendit.json, unknown feature off: ls-guard still refuses" "$(run 'ls | wc -l' "$T/newer")" "2"
chk "  ...and a plain command runs"                    "$(run 'echo hi' "$T/newer")" "0"
printf '{"version":1,"features":{"ls-guard":{"on":false,"why":"x"},"teleport-guard":{"on":false,"why":"later"}}}' > "$T/newer/.claude/bendit.json"
chk "newer bendit.json, unknown feature off, ls-guard off: allows" "$(run 'ls | wc -l' "$T/newer")" "0"
printf '{"version":1,"features":{"ls-guard":{"on":false,"why":"x"},"teleport-guard":{"on":true,"why":"chosen"}}}' > "$T/newer/.claude/bendit.json"
chk "newer bendit.json, unknown feature ON: refuses (fail closed)" "$(run 'ls | wc -l' "$T/newer")" "2"
# Review I1: the message says update bendit, and never to edit the file.
NEWER_ERR="$(pl 'ls | wc -l' "$T/newer" | python3 "$H" 2>&1 >/dev/null)"
case "$NEWER_ERR" in *"claude plugin update bendit@bendit --scope project"*) chk "  ...giving the update command" y y;; *) chk "  ...giving the update command ($NEWER_ERR)" n y;; esac
case "$NEWER_ERR" in *"Do not edit or delete .claude/bendit.json"*) chk "  ...saying plainly not to edit or delete the file" y y;; *) chk "  ...saying not to edit the file ($NEWER_ERR)" n y;; esac
case "$NEWER_ERR" in *"Edit tool"*|*"fix it"*) chk "  ...and never to fix it with the Edit tool ($NEWER_ERR)" n y;; *) chk "  ...and never to fix it with the Edit tool" y y;; esac
# An import failure is inside the crash net: exit 2, never exit 1 (fail open).
mkdir -p "$T/broken"; cp "$H" "$SD/shell_text.py" "$T/broken/"
printf 'raise RuntimeError("broken features module")\n' > "$T/broken/features.py"
chk "a broken features.py refuses (exit 2, not 1)"     "$(pl 'echo hi' | python3 "$T/broken/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" "2"
printf 'def broken(:\n' > "$T/broken/features.py"
chk "an unparseable features.py refuses (exit 2)"      "$(pl 'echo hi' | python3 "$T/broken/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" "2"
# No bendit.json: the guard exits 0 before it imports anything of its own (it
# runs on every Bash call). Proven with the broken features.py above: it is
# never imported where there is no file, and still refuses where there is one.
chk "no bendit.json: a broken features.py is never imported (exit 0)" "$(pl 'ls | wc -l' "$T/none" | python3 "$T/broken/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" "0"
chk "  ...CONTROL: with a bendit.json it is (exit 2)" "$(pl 'ls | wc -l' "$T/on" | python3 "$T/broken/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" "2"
chk "  ...a malformed bendit.json still takes the full path" "$(pl 'echo hi' "$T/bad" | python3 "$T/broken/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" "2"
chk "  ...CLAUDE_PROJECT_DIR with no file, on cwd: exits 0" "$(CLAUDE_PROJECT_DIR="$T/none" run 'ls | wc -l' "$T/on")" "0"
chk "  ...CLAUDE_PROJECT_DIR on, cwd with no file: still blocks" "$(CLAUDE_PROJECT_DIR="$T/on" run 'ls | wc -l' "$T/none")" "2"
# CLAUDE_PROJECT_DIR wins over the payload's cwd, like features.project_root says.
chk "CLAUDE_PROJECT_DIR (off) beats an on cwd"         "$(CLAUDE_PROJECT_DIR="$T/off" run 'ls | wc -l' "$T/on")" "0"
chk "CLAUDE_PROJECT_DIR (on) beats an off cwd"         "$(CLAUDE_PROJECT_DIR="$T/on" run 'ls | wc -l' "$T/off")" "2"
# A crash inside the guard refuses (exit 1 would let the command run).
chk "a crash in the guard refuses"                     "$(pl 'ls | wc -l' | PYTHONPATH="$SD" python3 -c 'import sys,runpy; sys.argv=[sys.argv[1]]; import json; import features; features.is_on=lambda *a: 1/0; runpy.run_path(sys.argv[0], run_name="__main__")' "$H" >/dev/null 2>&1; echo $?)" "2"

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo
echo "--- an ls pipeline inside a QUOTED HEREDOC is written to a file ---"
# That body becomes a script run somewhere else, under some other shell, where
# `ls` is the real binary and the pipeline is correct. block-dangerous-bash.py
# and block-zsh-wordsplit.py both strip these bodies via shell_text.py; a third
# guard that did not would make the three disagree about what counts as
# executable text, which is the drift shell_text.py exists to prevent.
chk "ls pipeline inside a quoted heredoc body" "$(run "cat > t.sh <<'EOF'
ls | wc -l
EOF")" "0"
chk "two of them in that body" "$(run "cat > t.sh <<'EOF'
ls | wc -l
n=\$(ls)
EOF")" "0"
# CONTROLS: without these the stripper could be blanking the whole command and
# every assertion above would still pass.
chk "CONTROL: pipeline BEFORE the heredoc blocks" "$(run "ls | wc -l
cat > t.sh <<'EOF'
hello
EOF")" "2"
chk "CONTROL: pipeline AFTER the heredoc blocks" "$(run "cat > t.sh <<'EOF'
hello
EOF
ls | wc -l")" "2"
chk "CONTROL: UNQUOTED heredoc body still scanned" "$(run "cat > t.sh <<EOF
ls | wc -l
EOF")" "2"

echo
echo "--- shapes the pipeline walk missed ---"
# `&` ended the walk, so a redirect spelled with `&` hid the pipe after it.
chk "ls 2>&1 | wc -l"                 "$(run 'ls 2>&1 | wc -l')" "2"
chk "ls |& wc -l"                     "$(run 'ls |& wc -l')" "2"
# Process substitution hands ls output to the reader as a file.
chk "wc -l < <(ls)"                   "$(run 'wc -l < <(ls)')" "2"
chk "diff <(ls a) <(ls b)"            "$(run 'diff <(ls a) <(ls b)')" "2"
chk "CONTROL: ls in the background, then wc" "$(run 'ls & wc -l f')" "0"
chk "CONTROL: <(/bin/ls) is the real binary"  "$(run 'diff <(/bin/ls a) <(/bin/ls b)')" "0"
# A heredoc opener inside quotes hid every line below it.
chk "a heredoc opener inside quotes hides nothing" "$(run "echo \"<<'X'\"
ls | wc -l
X")" "2"
chk "an ls pipeline in a body fed to bash is real ls" "$(run "bash <<'EOF'
ls | wc -l
EOF")" "0"

echo
echo "--- what the message says the ls output is ---"
how() { pl "$1" | python3 "$H" 2>&1 >/dev/null | sed -n 's/^Here, the ls output is \(.*\)\.$/\1/p'; }
chk "backticks feeding a for say backticks" "$(how 'for f in `ls`; do :; done')" 'captured by backticks to feed a `for ... in` list'
chk "\$( ) feeding a for says \$( )"        "$(how 'for f in $(ls); do :; done')" 'captured by `$( )` to feed a `for ... in` list'
chk "process substitution says so"         "$(how 'wc -l < <(ls)')" 'read through process substitution `<( )`'

echo
echo "--- a payload of the wrong shape is ignored, not a crash ---"
chk "tool_input is a string"  "$(echo '{"tool_input":"ls | wc -l"}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "tool_input is a list"    "$(echo '{"tool_input":["x"]}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "an on project with a junk-shaped payload" "$(echo '{"cwd":"'"$T"'/on","tool_input":["x"]}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
