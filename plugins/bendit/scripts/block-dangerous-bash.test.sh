#!/usr/bin/env bash
# Fixture test for block-dangerous-bash.py.
# Asserts BOTH the exit code and that a reason reached stderr — a guard can
# fail on each of those independently.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
HOOK="$D/block-dangerous-bash.py"
pass=0; fail=0

# Asserting "stderr was non-empty" proves a reason was printed, not that the
# reason is any good -- and the reason IS the product: it is what tells an agent
# why it was stopped and what to do instead. The snapshot puts every one of them
# under review.
. "$D/expect.sh"
expect_init "$D/block-dangerous-bash.expected"

# run <expected_exit> <label> <command-string>
run() {
  local want="$1" label="$2" cmd="$3" err code
  local payload; payload=$(python3 -c '
import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
  expect_capture "$label" python3 "$HOOK" <<<"$payload"
  # STDERR specifically. That is the channel Claude Code feeds back to the
  # agent, and it is what the header above promises. Asserting on a merged
  # stream let every `print(file=sys.stderr)` move to stdout with all 56
  # assertions and the snapshot still green -- "blocked, no reason given".
  err=$EXPECT_STDERR; code=$EXPECT_CODE
  if [ "$code" -ne "$want" ]; then
    printf '  FAIL  %-46s exit %s, wanted %s\n' "$label" "$code" "$want"; fail=$((fail+1)); return
  fi
  if [ "$want" -eq 2 ] && [ -z "$err" ]; then
    printf '  FAIL  %-46s blocked with empty stderr\n' "$label"; fail=$((fail+1)); return
  fi
  printf '  ok    %-46s\n' "$label"; pass=$((pass+1))
}

# run_raw <expected_exit> <label> <raw-stdin>
# Feeds stdin verbatim instead of wrapping a command in a payload, so the
# malformed-input branches can be pinned.
run_raw() {
  local want="$1" label="$2" raw="$3" err code
  expect_capture "$label" python3 "$HOOK" <<<"$raw"
  err=$EXPECT_STDERR; code=$EXPECT_CODE
  if [ "$code" -ne "$want" ]; then
    printf '  FAIL  %-46s exit %s, wanted %s\n' "$label" "$code" "$want"; fail=$((fail+1)); return
  fi
  if [ "$want" -eq 2 ] && [ -z "$err" ]; then
    printf '  FAIL  %-46s blocked with empty stderr\n' "$label"; fail=$((fail+1)); return
  fi
  printf '  ok    %-46s\n' "$label"; pass=$((pass+1))
}

echo "MUST BLOCK (exit 2, reason on stderr)"
run 2 "rm -rf /"                        'rm -rf /'
run 2 "rm -fr with reordered flags"     'rm -fr ./build'
run 2 "chained rm -rf"                  'cd /tmp && rm -rf node_modules'
run 2 "psql DROP TABLE"                 'psql $DB -c "DROP TABLE users"'
run 2 "supabase db push"                'supabase db push'
run 2 "supabase db reset"               'supabase db reset --linked'
run 2 "git push --force"                'git push --force origin main'
run 2 "git push -f, flag last"          'git push origin main -f'
run 2 "git -C dir push --force"         'git -C ../app push --force origin staging'
run 2 "stripe live key"                 'curl -H "Authorization: Bearer sk_live_51Hq9ZxAbCdEfGhIjKlMnOpQr"'
run 2 "supabase PAT"                    'export TOK=sbp_0123456789abcdef0123456789abcdef01234567'
run 2 "supabase secret key"             'echo sb_secret_9aZbYcXdWeVfUgThSiRjQk'
run 2 "github PAT"                      'gh auth login --with-token ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'

# Positive controls for the heredoc carve-out below: only the BODY of a QUOTED
# heredoc stops being read as commands. Everything else still blocks.
run 2 "rm -rf on the heredoc opener line" $'cat <<\'EOF\' > note.txt && rm -rf /tmp/x\nharmless\nEOF'
run 2 "rm -rf piped after heredoc ends"   $'cat > note.txt <<\'EOF\'\nharmless\nEOF\ncat note.txt | rm -rf /tmp/x'
run 2 "unquoted heredoc expands \$( )"    $'cat > note.txt <<EOF\n$(rm -rf /tmp/x)\nEOF'
run 2 "stripe live key in a heredoc"      $'cat > .env <<\'EOF\'\nSTRIPE=sk_live_51Hq9ZxAbCdEfGhIjKlMnOpQr\nEOF'

echo
echo "MUST ALLOW (exit 0) — these are the false positives that kill a gate"
run 0 "grep for the literal DROP TABLE"  'grep -r "DROP TABLE" supabase/migrations'
run 0 "branch named ...-main-..."        'git push origin fix/auth-main-redirect'
run 0 "force-with-lease"                 'git push --force-with-lease origin feat/x'
run 0 "ordinary push"                    'git push origin staging'
# git clean deletes untracked (and with -x, ignored: .env included) files with
# no undo. Found by the unprompted-deletion eval: the guard let it through.
run 2 "git clean -fdx"                   'git clean -fdx'
run 2 "git clean -f, split flags"        'git clean -f -d dist/'
run 2 "git clean --force"                'git clean --force'
run 2 "git -C dir clean -fd"             'git -C ../app clean -fd'
run 2 "git clean behind a wrapper"       'sudo git clean -fdx'
run 0 "git clean -n is a dry run"        'git clean -n -d'
run 0 "git clean --dry-run"              'git clean --dry-run -fdx'
run 0 "git clean with no force deletes nothing" 'git clean -d'
run 0 "a message mentioning git clean"   'git commit -m "docs: never run git clean -fdx here"'
run 0 "rm without recursive+force"       'rm ./tmp/output.log'
run 0 "supabase db diff"                 'supabase db diff -f add_policies'
run 0 "a test-mode stripe key"           'stripe listen --api-key sk_test_51Hq9ZxAbCdEfGhIjKlMnOpQr'
run 0 "filename containing rm -rf"       'cat docs/why-we-banned-rm-rf.md'
run 0 "pnpm install"                     'pnpm install --frozen-lockfile'
run 0 "empty command"                    ''
run 0 "whitespace-only command"          '   '

# Writing a file whose text mentions rm -rf must not be read as running it.
# The body of a QUOTED heredoc is data — bash expands nothing in it.
run 0 "heredoc with a backticked rm -rf"  $'cat > "$M/hooks/register.ts" <<\'EOF\'\n  // blocks `rm -rf /` and `rm -fr build`\nEOF'
run 0 "heredoc with an rm -rf regex"      $'cat > "$M/hooks/register.ts" <<\'EOF\'\n  { rx: /\\brm\\s+(-[a-zA-Z]*\\s+)*-?[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR])/,\n    what: \'a recursive force delete\' },\nEOF'
run 0 "indented <<- quoted heredoc"       $'\tcat <<-\'EOF\' > note.md\n\t`rm -rf /` is blocked\n\tEOF'
run 0 "two heredocs in one command"       $'cat <<\'A\' > a.txt; cat <<\'B\' > b.txt\n`rm -rf /`\nA\n`rm -fr .`\nB'

echo
echo "MALFORMED INPUT — parses as JSON but hides the command => BLOCK"
run_raw 2 "JSON object with no tool_input" '{"tool_name":"Bash"}'
run_raw 2 "tool_input without a command"   '{"tool_name":"Bash","tool_input":{}}'
run_raw 2 "command is not a string"        '{"tool_name":"Bash","tool_input":{"command":["rm","-rf","/"]}}'
run_raw 2 "JSON that is not an object"     'null'

echo
echo "MALFORMED INPUT — not a hook payload at all => PERMIT"
run_raw 0 "empty stdin"                    ''
run_raw 0 "whitespace-only stdin"          '   '
run_raw 0 "not JSON at all"                'this is not json'
run_raw 0 "truncated JSON"                 '{"tool_input":{"command":"ls"'

echo
echo "COMMAND SEPARATORS — a newline separates commands just as ; and | do"
# Replaying real agent transcripts showed an anchor without a newline missed
# more real destructive commands than it caught: multi-line commands are one of
# the most common shapes an agent sends.
run 2 "delete on the second line"          'echo hi
rm -rf /tmp/canary'
run 2 "delete on the third line"           'set -e
echo a
rm -rf /tmp/canary'
run 2 "DROP DATABASE on its own line"      'echo start
psql "$DSN" -c "DROP DATABASE scratch;"'
run 2 "supabase reset on its own line"     'cd repo
supabase db reset'
# Positive controls: a multi-line command with nothing destructive must pass,
# and the heredoc carve-out must still hold now that newlines are separators.
run 0 "multi-line with nothing destructive" 'set -e
echo one
ls -la
echo two'
run 0 "delete on its own line INSIDE a quoted heredoc" 'cat > note.md <<'"'"'EOF'"'"'
rm -rf /tmp/example
EOF'
run 2 "delete on its own line AFTER a heredoc ends"    'cat > note.md <<'"'"'EOF'"'"'
harmless text
EOF
rm -rf /tmp/canary'

echo
echo "rm FLAGS — recursive AND force, however they are spelled"
# Flags are read from flag TOKENS only, so a filename can never arm the rule,
# while split, reversed and long spellings all still count.
run 2 "rm -r -f (flags split across args)"  'rm -r -f /tmp/canary'
run 2 "rm -f -r (split, reversed)"          'rm -f -r /tmp/canary'
run 2 "rm --recursive --force"              'rm --recursive --force /tmp/canary'
run 2 "rm -rf (control, still blocks)"      'rm -rf /tmp/canary'
run 2 "rm -Rf (control, capital R)"         'rm -Rf /tmp/canary'
run 0 "rm -f on a filename holding f..r"    'rm -f features/scenarios/snap.json'
run 0 "rm -f foobar.txt"                    'rm -f foobar.txt'
run 0 "rm -r without force"                 'rm -r /tmp/dir'
run 0 "plain rm"                            'rm /tmp/file'

echo
echo "DELETING THE DIRECTORY YOU ENTER — the shape that wedged a whole session"
# Each of these leaves the shell with no cwd. The trap case is the subtle one:
# without this rule it passes every check, because a trap defers the delete
# past command position.
run 2 "trap deletes the dir we cd into"  'trap '"'"'rm -rf "$T"'"'"' EXIT; cd "$T"'
run 2 "cd then recursive delete, NO -f"  'cd "$T" && rm -r "$T"'
run 2 "mktemp, cd in, delete it"         'T=$(mktemp -d); cd "$T"; rm -rf "$T"'
run 2 "braces and quotes still match"    'cd "${TMP}" && rm -R ${TMP}'
run 2 "trailing slash still matches"     'cd "$T"/ && rm -r "$T"'

echo
echo "...and the controls it must NOT refuse"
# Without these the rule above could be refusing everything and still look
# green. A subdirectory delete leaves the shell valid; a different token is a
# different directory.
run 0 "deleting a SUBDIR of the cwd"     'cd "$R" && rm -r "$R/build"'
run 0 "deleting an unrelated directory"  'cd "$R" && rm -r "$OTHER"'
run 0 "cd with no delete at all"         'cd "$T" && ls -la'
run 0 "recursive delete with no cd"      'rm -r ./coverage'

echo
echo "ORDER MATTERS: an rm BEFORE the cd cannot strip the shell of its cwd"
# A real false positive in an earlier version: the rule matched the two tokens
# and never asked which ran first, so a scratch-dir setup was refused with "this enters
# $S and then deletes it" -- but the rm clears the directory BEFORE mkdir and
# cd enter the fresh one, so the shell is never left standing in something
# deleted.
#
# NOTE what is asserted. The two commands from the report contain `rm -rf`,
# which this guard refuses under a SEPARATE rule ("run it yourself
# if you mean it"). That rule is not weakened here. What was wrong was the
# REASON: the cwd rule fired and told the agent something untrue about its
# command. So the assertion is on which rule speaks, not merely on the exit.
reason_is_not_cwd() { # label command
  local err
  err=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" \
        | python3 "$HOOK" 2>&1 >/dev/null)
  case "$err" in
    *"enters"*"then deletes it"*)
      printf '  FAIL  %-46s still blamed on the cwd rule\n' "$1"; fail=$((fail+1));;
    *) printf '  ok    %-46s\n' "$1"; pass=$((pass+1));;
  esac
}
reason_is_not_cwd "reported cmd: not blamed on the cwd rule" 'S=/tmp/x; rm -rf "$S"; mkdir -p "$S" && cd "$S" && git init -q .'
reason_is_not_cwd "rm -rf then cd: not blamed on the cwd rule" 'rm -rf "$S" && mkdir "$S" && cd "$S"'
# With no -f there is no other rule in the way, so this one must be ALLOWED
# outright -- the cleanest proof the ordering fix works.
run 0 "rm -r then cd is allowed outright"  'rm -r "$S"; cd "$S"'
run 0 "rm -r then cd, && separated"        'rm -r "$S" && mkdir "$S" && cd "$S"'
run 0 "rm -r a scratch dir, then enter it" 'S=/tmp/x; rm -r "$S"; mkdir -p "$S" && cd "$S" && git init -q .'

echo
echo "...but an rm AFTER the cd still wedges the shell, and still blocks"
# Without these the fix would simply have switched the rule off.
run 2 "cd then delete it"                   'cd "$S" && rm -r "$S"'
run 2 "cd, other work, then delete it"      'cd "$S"; echo hi; rm -r "$S"'
run 2 "trap deletes it: a trap runs at EXIT, which is after the cd" 'trap '"'"'rm -r "$S"'"'"' EXIT; cd "$S"'
run 2 "delete after a cd even with an earlier unrelated rm" 'rm -r /tmp/other; cd "$S" && rm -r "$S"'

echo
echo "AN rm ANYWHERE THE SHELL RUNS ONE -- not only right after a separator"
# An earlier version matched rm only straight after `;|&` or a newline,
# so every wrapper, prefix and nested shell walked past it. The guard now reads
# COMMAND WORDS (shell_text.simple_commands) and strips the wrappers.
run 2 "sudo rm -rf /"                       'sudo rm -rf /'
run 2 "sudo -u root rm -rf x"               'sudo -u root rm -rf x'
run 2 "env rm -rf build"                    'env rm -rf build'
run 2 "VAR=1 rm -rf build"                  'FOO=1 rm -rf build'
run 2 "command rm -rf build"                'command rm -rf build'
run 2 "backslash \\rm -rf build"            '\rm -rf build'
run 2 "/bin/rm -rf build"                   '/bin/rm -rf build'
run 2 "time rm -rf x"                       'time rm -rf x'
run 2 "nohup rm -rf x"                      'nohup rm -rf x'
run 2 "xargs rm -rf"                        'find . -name x | xargs rm -rf'
run 2 "xargs -0 -n 1 rm -rf"                'find . -print0 | xargs -0 -n 1 rm -rf'
run 2 "bash -c 'rm -rf build'"              "bash -c 'rm -rf build'"
run 2 "sh -c \"rm -rf build\""              'sh -c "rm -rf build"'
run 2 "bash -lc combined flags"             "bash -lc 'rm -rf build'"
run 2 "eval \"rm -rf build\""               'eval "rm -rf build"'
run 2 "( rm -rf build )"                    '( rm -rf build )'
run 2 "{ rm -rf build; }"                   '{ rm -rf build; }'
run 2 "if-then rm -rf"                      'if true; then rm -rf build; fi'
run 2 "find . -delete"                      'find . -name "*.tmp" -delete'
run 2 "find -exec rm -rf {} +"              'find . -exec rm -rf {} +'
run 2 "find -exec sh -c 'rm -rf'"           "find . -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"
run 2 "rm build -rf (flags after operand)"  'rm build -rf'
run 2 "rm -rf inside \$( )"                 'x=$(rm -rf build)'
run 2 "echo ... | bash"                     'echo "rm -rf build" | bash'
run 2 "bash <<< here-string"                "bash <<< 'rm -rf build'"
# Found by replaying 15,195 real commands old-vs-new: a runner this lexer does
# not know (`hc exec`, `docker exec`) handing `sh -c` a string. The old regex
# caught it only by accident, via a `;` inside the quotes.
run 2 "hc exec ... -- sh -c 'x; rm -rf'"    "hc exec --on box -i -- sh -c 'D=\$HOME/x; rm -rf \"\$D\"; mkdir -p \"\$D\"'"
run 2 "docker exec c sh -c 'rm -rf'"        "docker exec web sh -c 'rm -rf /srv/cache'"
run 0 "CONTROL: echo of sh -c text"         "echo sh -c 'rm -rf x'"
# Controls: the same words as TEXT, not as a command, must stay allowed.
run 0 "commit message mentioning rm -rf"    'git commit -m "explain rm -rf"'
run 0 "echo rm -rf as text"                 'echo rm -rf build'
run 0 "grep for rm -rf"                     "grep -rn 'rm -rf' docs/"
run 0 "comment mentioning rm -rf"           '# rm -rf build
echo ok'
run 0 "find without -delete"                'find . -name "*.tmp" -print'
run 0 "command -v rm is a lookup"           'command -v rm'
run 0 "pnpm rm is pnpm remove"              'pnpm rm -r lodash'
run 0 "bash script.sh"                      'bash ./scripts/clean.sh -rf'
run 0 "rm -rf in a trap stays the cleanup idiom" "T=\$(mktemp -d); trap 'rm -rf \"\$T\"' EXIT"

echo
echo "supabase db push/reset THROUGH A PACKAGE RUNNER"
run 2 "npx supabase db push"                'npx supabase db push'
run 2 "npx supabase@latest db reset"        'npx supabase@latest db reset'
run 2 "pnpm supabase db reset"              'pnpm supabase db reset'
run 2 "pnpm exec supabase db push"          'pnpm exec supabase db push'
run 2 "pnpm dlx supabase db push"           'pnpm dlx supabase db push'
run 2 "yarn supabase db push"               'yarn supabase db push'
run 2 "bunx supabase db reset"              'bunx supabase db reset'
run 2 "supabase --debug db push"            'supabase --debug db push'
run 0 "npx supabase db diff"                'npx supabase db diff -f x'
run 0 "pnpm supabase status"                'pnpm supabase status'

echo
echo "HEREDOC BODIES FED TO AN INTERPRETER ARE CODE, NOT DATA"
run 2 "bash <<'EOF' rm -rf"                 $'bash <<\'EOF\'\nrm -rf build\nEOF'
run 2 "sh -s <<'EOF' rm -rf"                $'sh -s <<\'EOF\'\nrm -rf build\nEOF'
run 2 "cat <<'EOF' | bash"                  $'cat <<\'EOF\' | bash\nrm -rf build\nEOF'
run 2 "psql <<'SQL' DROP TABLE"             $'psql "$DB" <<\'SQL\'\nDROP TABLE users;\nSQL'
run 2 "psql <<SQL unquoted, multi-line"     $'psql "$DB" <<SQL\nBEGIN;\nDROP\n  TABLE users;\nSQL'
run 0 "cat <<'EOF' > file stays data"       $'cat > x.sh <<\'EOF\'\nrm -rf build\nEOF'
run 0 "psql heredoc with a safe query"      $'psql "$DB" <<\'SQL\'\nselect count(*) from users;\nSQL'

echo
echo "A HEREDOC OPENER INSIDE QUOTES OR A COMMENT IS NOT AN OPENER"
run 2 "<<'X' inside double quotes"          $'echo "<<\'X\'"\nrm -rf build\nX'
run 2 "<<'X' inside a comment"              $'# see <<\'X\'\nrm -rf build\nX'
run 2 "<<'X' inside single quotes"          $'echo \'<<"X"\'\nrm -rf build\nX'

echo
echo "FORCE PUSH, however it is spelled -- and only when git is the command"
run 2 "+refspec forces"                     'git push origin +main'
run 2 "-uf combined short flags"            'git push -uf origin main'
run 2 "git -c x=y push --force"             'git -c x=y push --force'
run 2 "git --no-pager push -f"              'git --no-pager push -f origin main'
run 0 "commit message mentioning force push" 'git commit -m "never git push --force here"'
run 0 "--force-if-includes with lease"      'git push --force-with-lease --force-if-includes origin x'
run 0 "push -u is not force"                'git push -u origin feat/x'

echo
echo "DESTRUCTIVE SQL"
run 2 "DELETE without WHERE"                'psql "$DB" -c "DELETE FROM users"'
run 2 "lowercase delete without where"      'psql "$DB" -c "delete from users;"'
run 0 "DELETE with WHERE"                   'psql "$DB" -c "DELETE FROM users WHERE id = 3"'
run 2 "second -c is unbounded"              'psql "$DB" -c "DELETE FROM users" -c "select 1 where true"'

echo
echo "MORE CREDENTIALS"
run 2 "fine-grained GitHub PAT"             'echo github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ'
run 2 "Stripe restricted live key"          'export K=rk_live_51Hq9ZxAbCdEfGhIjKlMnOpQr'

echo
echo "NOT BLAMED ON THE cwd RULE when the cd cannot strand the shell"
# A cd inside ( ) changes a SUBSHELL's directory, and a cd inside a quoted
# string is not a cd at all. Both still hit the rm -rf rule -- what is asserted
# is that the reason given is the true one.
reason_is_not_cwd "cd only inside a subshell"       '(cd "$T" && make); rm -rf "$T"'
reason_is_not_cwd "cd only inside a quoted string"  'echo "cd $T" ; rm -rf "$T"'
run 0 "cd in a subshell, then rm -r"                '(cd "$T" && make); rm -r "$T"'
run 2 "CONTROL: cd in a { } group DOES move the shell" '{ cd "$T"; }; rm -r "$T"'

echo
echo "A PAYLOAD IT CANNOT DECODE"
# Non-UTF-8 bytes used to raise a traceback and exit 1, which Claude Code treats
# as a non-blocking error: the command ran, unguarded.
run_raw 2 "non-UTF-8 bytes in a JSON payload" $'{"tool_input":{"command":"rm -rf build \xff"}}'
run_raw 0 "non-UTF-8 junk that is not JSON"   $'\xff\xfe not json'
# A crash anywhere past the decode must REFUSE, not exit 1. Forced by replacing
# the lexer with one that raises; the command itself is harmless.
crash() {
  printf '{"tool_input":{"command":"ls"}}' | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(_text): raise RuntimeError("synthetic")
guard.simple_commands = boom
sys.exit(guard.main())' "$HOOK" 2>&1 >/dev/null
  echo "exit=$?"
}
case "$(crash)" in
  *"guard itself failed"*"exit=2") printf '  ok    %-46s\n' "a crash inside the guard refuses"; pass=$((pass+1));;
  *) printf '  FAIL  %-46s %s\n' "a crash inside the guard refuses" "$(crash | tail -1)"; fail=$((fail+1));;
esac

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
