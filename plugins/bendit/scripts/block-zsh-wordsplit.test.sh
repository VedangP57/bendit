#!/usr/bin/env bash
# Both halves. A guard that fires on ordinary commands gets uninstalled within a
# day, so the "must stay silent" list is longer than the "must block" one.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/block-zsh-wordsplit.py"
pass=0; fail=0
# The guard is active only when the user's shell is zsh and the zshGuard plugin
# option is not false. Every case below runs as zsh with the option unset,
# whatever shell runs this suite; the gating itself is tested at the end.
export SHELL=/bin/zsh
unset CLAUDE_PLUGIN_OPTION_ZSHGUARD
. "$SD/expect.sh"
expect_init "$SD/block-zsh-wordsplit.expected"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
run() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
        | python3 "$H" >/dev/null 2>&1; echo $?; }

# --- must BLOCK: the measured bug, in its common spellings -------------------
chk "bare \$var in a for-list"        "$(run 'for f in $files; do echo $f; done')" "2"
chk "braced \${var}"                  "$(run 'for f in ${files}; do echo $f; done')" "2"
chk "on its own line"                 "$(run 'files=$(git ls-files)
for f in $files; do echo "$f"; done')" "2"
chk "inside a longer pipeline"        "$(run 'x=1; for n in $nums; do :; done; echo done')" "2"

# --- must STAY SILENT --------------------------------------------------------
# Command substitution DOES split in zsh -- measured, not assumed.
chk "command substitution is fine"    "$(run 'for f in $(ls); do echo $f; done')" "0"
chk "quoted scalar is explicit"       "$(run 'for f in "$v"; do :; done')" "0"
chk "array expansion is fine"         "$(run 'for f in "${arr[@]}"; do :; done')" "0"
chk "unquoted array is fine"          "$(run 'for f in ${arr[@]}; do :; done')" "0"
chk "literal list"                    "$(run 'for i in 1 2 3; do :; done')" "0"
chk "a glob"                          "$(run 'for f in *.ts; do :; done')" "0"
# A scalar that is only PART of a word, beside a literal glob: zsh does not
# split $P but does glob the literal `*`, so this iterates per file. Live false
# positive in an earlier version.
chk "\$dir/*.ext glob is fine"        "$(run 'for f in $P/*.patch; do echo $f; done')" "0"
chk "\${dir}/*.ext glob is fine"      "$(run 'for f in ${P}/*.ts; do :; done')" "0"
chk "CONTROL: bare \$v before ; still blocks" "$(run 'for f in $v;do :; done')" "2"
chk "CONTROL: bare \$v before newline blocks" "$(run 'for f in $v
do :; done')" "2"
chk "no loop at all"                  "$(run 'echo $v && grep -r $pattern .')" "0"
chk "the word for inside a string"    "$(run 'echo "waiting for $thing to finish"')" "0"
chk "a C-style loop"                  "$(run 'for ((i=0;i<3;i++)); do :; done')" "0"
chk "junk stdin is allowed"           "$(echo 'not json' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "no command field"                "$(echo '{"tool_name":"Bash","tool_input":{}}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

# The message is the only thing telling the author what to do instead.
expect_capture "blocked: bare scalar in a for-list" python3 "$H" \
  <<< '{"tool_name":"Bash","tool_input":{"command":"for f in $files; do echo $f; done"}}'
echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo
echo "--- a loop inside a QUOTED HEREDOC is written to a file, not run here ---"
# That body becomes a bash script, where an unquoted loop over a variable is
# correct, and refusing it blocks ordinary writes of bash test scripts.
# block-dangerous-bash.py stripped these bodies and this guard did not, so the
# two disagreed about what counts as executable text. They now share
# shell_text.py.
#
# NOTE the DOUBLE quotes: the heredoc delimiter carries single quotes, which
# would close a single-quoted argument and hand `run` a mangled command. That
# mistake made these two cases report 2 while the guard itself returned 0.
chk "loop inside a quoted heredoc body" "$(run "cat > t.sh <<'EOF'
for x in \$FILES; do :; done
EOF")" "0"
chk "two loops in that body" "$(run "cat > t.sh <<'EOF'
for x in \$A; do :; done
for x in \$B; do :; done
EOF")" "0"
# CONTROLS: without these the stripper could be blanking the whole command and
# every assertion above would still pass.
chk "CONTROL: loop BEFORE the heredoc blocks" "$(run "for x in \$FILES; do :; done
cat > t.sh <<'EOF'
hello
EOF")" "2"
chk "CONTROL: loop AFTER the heredoc blocks" "$(run "cat > t.sh <<'EOF'
hello
EOF
for x in \$FILES; do :; done")" "2"
chk "CONTROL: UNQUOTED heredoc body still scanned" "$(run "cat > t.sh <<EOF
for x in \$FILES; do :; done
EOF")" "2"

echo
echo "--- quoted text is not a loop this shell runs ---"
# The guard's own advice is `bash -c '...'`, and it refused that advice: it
# scanned inside single quotes. Text in quotes is an argument, not a loop.
chk "its own escape hatch: bash -c '...'" \
  "$(run 'bash -c '"'"'v="a b"; for x in $v; do echo $x; done'"'"'')" "0"
chk "echo of loop text in single quotes" "$(run "echo 'for x in \$v'")" "0"
chk "commit message quoting a loop"      "$(run 'git commit -m "fix: for x in $v ran once"')" "0"
chk "a loop in a comment"                "$(run '# for x in $v
echo ok')" "0"
chk "a heredoc opener inside quotes hides nothing" "$(run "echo \"<<'X'\"
for x in \$v; do :; done
X")" "2"
chk "CONTROL: a loop inside \$( ) in double quotes still blocks" \
  "$(run 'echo "$(for x in $v; do echo $x; done)"')" "2"
# Found replaying real agent commands: quoting must not hide a string that zsh
# itself is handed to run.
chk "CONTROL: zsh -c '...' IS zsh"       "$(run "zsh -c 'v=\"a b\"; for x in \$v; do :; done'")" "2"
chk "a body fed to bash is bash, where the loop splits" "$(run "bash <<'EOF'
for x in \$v; do :; done
EOF")" "0"
chk "CONTROL: a body fed to zsh is still zsh" "$(run "zsh <<'EOF'
for x in \$v; do :; done
EOF")" "2"
# zsh's own split forms are correct and must pass.
chk "\${=v} is zsh's explicit split"       "$(run 'for x in ${=v}; do :; done')" "0"
chk "\${(f)v} splits on lines"              "$(run 'for x in ${(f)v}; do :; done')" "0"

echo
echo "--- a default-valued expansion is captured whole ---"
# `${v:-a b}` was captured as `${v:-a`, and the message then suggested
# `$(printf %s "${v:-a")` -- a syntax error.
chk "\${v:-a b} blocks"                  "$(run 'for x in ${v:-a b}; do :; done')" "2"
msg=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' 'for x in ${v:-a b}; do :; done')" \
      | python3 "$H" 2>&1 >/dev/null)
case "$msg" in
  *'$(printf %s "${v:-a b}")'*) printf '  ok    %s\n' "suggestion quotes the whole expansion"; pass=$((pass+1));;
  *) printf '  FAIL  %s\n%s\n' "suggestion quotes the whole expansion" "$msg"; fail=$((fail+1));;
esac

echo
echo "--- a payload of the wrong shape is ignored, not a crash ---"
chk "tool_input is a string"  "$(echo '{"tool_input":"for x in $v"}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "tool_input is a list"    "$(echo '{"tool_input":["x"]}' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"
chk "payload is a list"       "$(echo '[1,2]' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

echo
echo "--- active only under zsh, and only when the zshGuard option allows ---"
LOOPCMD='for f in $files; do echo $f; done'
gated() { # <SHELL value or -unset> <option value or -unset>
  local payload
  payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$LOOPCMD")")
  ( if [ "$1" = -unset ]; then unset SHELL; else export SHELL="$1"; fi
    if [ "$2" = -unset ]; then unset CLAUDE_PLUGIN_OPTION_ZSHGUARD
    else export CLAUDE_PLUGIN_OPTION_ZSHGUARD="$2"; fi
    printf '%s' "$payload" | python3 "$H" >/dev/null 2>&1; echo $? )
}
chk "SHELL=/bin/zsh, option unset: blocks"          "$(gated /bin/zsh -unset)" "2"
chk "SHELL=/usr/local/bin/zsh: blocks"              "$(gated /usr/local/bin/zsh -unset)" "2"
chk "option true: blocks"                           "$(gated /bin/zsh true)" "2"
chk "SHELL=/bin/bash: silent, bash splits"          "$(gated /bin/bash -unset)" "0"
chk "SHELL unset: silent"                           "$(gated -unset -unset)" "0"
chk "SHELL=/bin/zshrc-ish name is not zsh"          "$(gated /opt/zsh-tools/notzsh -unset)" "0"
chk "option false: silent"                          "$(gated /bin/zsh false)" "0"
chk "option FALSE (any case): silent"               "$(gated /bin/zsh FALSE)" "0"
chk "option 0: silent"                              "$(gated /bin/zsh 0)" "0"
chk "option empty string: still active (default)"   "$(gated /bin/zsh '')" "2"

echo
echo "--- a crash inside the guard REFUSES ---"
# Exit 1 from a traceback is non-blocking to Claude Code: the command would run
# unchecked. Forced by replacing the loop finder with one that raises.
crash() {
  printf '{"tool_input":{"command":"ls"}}' | SHELL=/bin/zsh python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(*_a): raise RuntimeError("synthetic")
guard.find_loop = boom
sys.exit(guard.run())' "$H" 2>&1 >/dev/null
  echo "exit=$?"
}
case "$(crash)" in
  *"guard itself failed"*"exit=2") printf '  ok    %s\n' "a crash inside the guard refuses"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash inside the guard refuses" "$(crash | tail -1)"; fail=$((fail+1));;
esac
chk "non-UTF-8 junk that is not JSON is ignored" "$(printf '\377\376 nope' | python3 "$H" >/dev/null 2>&1; echo $?)" "0"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
