#!/usr/bin/env bash
# Every refusal a PreToolUse guard makes is written to the project's
# .claude/.bendit-state/fires.jsonl, so /bendit:guard-report can say which rules
# fire and which never do.
#
# The log is BEST-EFFORT and comes AFTER the decision. What this suite pins
# hardest is the half that is easy to break: whatever happens to the log -- a
# file where its folder should be, a folder nobody may write, a read-only
# .claude/, a FIFO that would block a write forever, a fire_log.py that does not
# even import -- the guard still exits 2 and prints, byte for byte, what it
# prints when nothing is logged at all. A guard must never allow what it refused.
#
#   bash fire-log.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
# The project comes from CLAUDE_PROJECT_DIR first; unset it so each case names
# its project through the payload's cwd, as a hook run outside Claude would.
unset CLAUDE_PROJECT_DIR
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ -- $2}"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }

newproj() {   # newproj <dir> [noclaude]: a git repo, with .claude/ unless told not
  mkdir -p "$1" && git -C "$1" init -q && { [ "${2:-}" = noclaude ] || mkdir "$1/.claude"; }
}
P="$T/proj"; newproj "$P"
N="$T/bare"; newproj "$N" noclaude
LOG="$P/.claude/.bendit-state/fires.jsonl"

bash_payload() {   # bash_payload <command> <cwd>
  python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "$2"
}
write_payload() {  # write_payload <file_path> <content> <cwd>
  python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[3],"tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2" "$3"
}
# guard <script> <payload> <outfile-prefix>: run it, keep stdout/stderr apart,
# echo the exit code. `env` lines in GUARD_ENV apply to the run.
guard() {
  env ${GUARD_ENV:-} python3 "$1" <<<"$2" >"$3.out" 2>"$3.err"; echo $?
}
lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
field() {  # field <log> <key>: that key of the LAST line
  python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read().splitlines()[-1])[sys.argv[2]])' "$1" "$2" 2>&1
}

DB="$SD/block-dangerous-bash.py"
RM='rm -rf ./build'

echo "A REFUSAL IS RECORDED: ONE LINE, RIGHT GUARD, RIGHT RULE"
chk "rm -rf ./build is refused"            "$(guard "$DB" "$(bash_payload "$RM" "$P")" "$T/r1")" 2
chk "  exactly one line"                   "$(lines "$LOG")" 1
chk "  guard"                              "$(field "$LOG" guard)" block-dangerous-bash
chk "  rule"                               "$(field "$LOG" rule)" rm-recursive
chk "  preview is the command"             "$(field "$LOG" preview)" "$RM"
ts="$(field "$LOG" ts)"
case "$ts" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ok "  ts is ISO-8601 UTC ($ts)";; *) bad "  ts is ISO-8601 UTC" "$ts";; esac
chk "  the line has exactly ts/guard/rule/preview" \
    "$(python3 -c 'import json,sys;print(sorted(json.loads(open(sys.argv[1]).readline())))' "$LOG")" \
    "['guard', 'preview', 'rule', 'ts']"
chk "a second refusal appends (2 lines)"  "$(guard "$DB" "$(bash_payload 'git push --force origin main' "$P")" "$T/r2"; lines "$LOG")" "2
2"
chk "  its rule"                          "$(field "$LOG" rule)" force-push

echo; echo "THE ROOT: CLAUDE_PROJECT_DIR, ELSE THE PAYLOAD'S cwd, LIFTED TO THE GIT TOPLEVEL"
mkdir -p "$P/src/deep"; : >"$LOG"
guard "$DB" "$(bash_payload "$RM" "$P/src/deep")" "$T/r3" >/dev/null
chk "a refusal from a subfolder lands in the repo's log"  "$(lines "$LOG")" 1
chk "  and no .claude/ is made in the subfolder"         "$([ -e "$P/src/deep/.claude" ] && echo made || echo none)" none
: >"$LOG"
GUARD_ENV="CLAUDE_PROJECT_DIR=$P" guard "$DB" "$(bash_payload "$RM" "$N")" "$T/r4" >/dev/null
chk "CLAUDE_PROJECT_DIR wins over the payload's cwd"     "$(lines "$LOG")" 1
chk "  and nothing lands in the cwd's repo"              "$([ -e "$N/.claude" ] && echo made || echo none)" none

echo; echo "NOTHING IS WRITTEN WHEN NOTHING IS REFUSED, OR THERE IS NO .claude/"
: >"$LOG"
chk "an allowed command exits 0"            "$(guard "$DB" "$(bash_payload 'git status' "$P")" "$T/a1")" 0
chk "  and writes nothing"                  "$(lines "$LOG")" 0
B="$T/fresh"; newproj "$B"
guard "$DB" "$(bash_payload 'ls' "$B")" "$T/a2" >/dev/null
chk "  nor makes the state folder"          "$([ -e "$B/.claude/.bendit-state" ] && echo made || echo none)" none
chk "a refusal where there is no .claude/ still exits 2" "$(guard "$DB" "$(bash_payload "$RM" "$N")" "$T/base")" 2
chk "  and never creates .claude/"          "$([ -e "$N/.claude" ] && echo made || echo none)" none
NG="$T/nogit"; mkdir -p "$NG/.claude"
chk "a refusal outside any git repo exits 2" "$(guard "$DB" "$(bash_payload "$RM" "$NG")" "$T/ng")" 2
chk "  and logs nothing (no project root)"  "$([ -e "$NG/.claude/.bendit-state" ] && echo made || echo none)" none
cp "$T/base.err" "$T/baseline.err"
[ -s "$T/baseline.err" ] && ok "the baseline refusal printed a reason" || bad "the baseline refusal printed a reason"

echo; echo "THE PREVIEW: SECRETS REDACTED FIRST, THEN CUT TO 120 CHARACTERS"
KEY="sk_live_$(printf 'a%.0s' {1..30})"
: >"$LOG"
chk "a live Stripe key is refused"          "$(guard "$DB" "$(bash_payload "curl -H 'Authorization: Bearer $KEY' https://api.example.test" "$P")" "$T/s1")" 2
chk "  rule"                                "$(field "$LOG" rule)" stripe-live-key
chk "  the key is not in the log"           "$(grep -c "sk_live_" "$LOG")" 0
chk "  the preview says it was redacted"    "$(field "$LOG" preview | grep -c '\[REDACTED\]')" 1
LONG="rm -rf ./build $(printf 'x%.0s' {1..95}) $KEY"
: >"$LOG"
guard "$DB" "$(bash_payload "$LONG" "$P")" "$T/s2" >/dev/null
chk "a long command is cut to 120"          "$(field "$LOG" preview | python3 -c 'import sys;print(len(sys.stdin.read().rstrip("\n")) <= 120)')" True
chk "  and a key straddling the cut leaks no part of itself" "$(grep -c 'sk_li' "$LOG")" 0
GH="ghp_$(printf 'B%.0s' {1..36})"
chk "redact() hides every live-key kind the guard refuses" \
    "$(cd "$SD" && python3 -c 'import fire_log,sys
t = fire_log.redact(" ".join(sys.argv[1:]))
print(t.count("[REDACTED]"), "sk_live" in t, "ghp_" in t, "PRIVATE KEY" in t)' "$KEY" "$GH" "-----BEGIN RSA PRIVATE KEY-----")" "3 False False False"

echo; echo "EVERY CREDENTIAL SHAPE IS REDACTED, NOT ONLY THE KEYS THE GUARD REFUSES"
# Each command below is REFUSED (so it is logged) and carries a secret of one
# family. The secret must not reach fires.jsonl in any part; the marker shows
# the redactor ran, rather than the preview being dropped.
secret_case() {  # secret_case <label> <command> <secret> <marker>
  : >"$LOG"
  local code; code="$(guard "$DB" "$(bash_payload "$2" "$P")" "$T/sc")"
  if [ "$code" != 2 ]; then bad "$1" "not refused (exit $code), so the case logs nothing"; return; fi
  local pv; pv="$(field "$LOG" preview)"
  if grep -qF -- "$3" "$LOG"; then bad "$1" "secret in the log: $pv"
  elif [ "${#pv}" -gt 120 ]; then bad "$1" "preview over 120: ${#pv}"
  else case "$pv" in *"$4"*) ok "$1";; *) bad "$1" "no [$4] in preview: $pv";; esac; fi
}
# The PEM armour is assembled, so this file's own text never holds a header
# that a guard reading it would take for a key.
D5='-----'
PEMBODY='MC4CAQAwBQYDK2VwBCIEIHq9cLhC2fG3Jx1Rk8mPj0e5Q2wZ7yT4uV6bN3sD1aKf'
secret_case "a whole PEM private key, BEGIN through END" \
  "printf '%s\n' '${D5}BEGIN PRIVATE KEY${D5}' '$PEMBODY' '${D5}END PRIVATE KEY${D5}' > k.pem" "$PEMBODY" '[REDACTED]'
secret_case "a PEM key with no END (cut short)" \
  "echo '${D5}BEGIN EC PRIVATE KEY${D5} $PEMBODY' > k.pem" "${PEMBODY:0:12}" '[REDACTED]'
secret_case "  ...and text after the END is kept" \
  "printf '%s\n' '${D5}BEGIN PRIVATE KEY${D5}' '$PEMBODY' '${D5}END PRIVATE KEY${D5}' > k.pem; echo done" "$PEMBODY" 'echo done'
# The `@` of a URL's userinfo is built at run time, so this file never holds
# an email-shaped string for the privacy scan to flag.
AT=@
secret_case "URL credentials: scheme://user:pass@host" \
  "supabase db push --db-url postgresql://postgres:hunter2pass${AT}db.abc.supabase.co:5432/postgres" hunter2pass 'postgresql://***@db.abc.supabase.co'
secret_case "URL with a token as the password" \
  "git push --force https://oauth2:glpat-AbCdEfGhIjKlMnOpQrSt${AT}gitlab.com/x/y.git main" glpat-AbCd 'https://***@gitlab.com'
secret_case "PGPASSWORD=" \
  'PGPASSWORD=hunter2 psql -h db -c "DROP TABLE users"' hunter2 'PGPASSWORD=***'
secret_case "*_PASSWORD= (quoted value with a space)" \
  'DB_PASSWORD="s3cr3t pass" rm -rf ./build' 's3cr3t' 'DB_PASSWORD=***'
secret_case "*_SECRET=" \
  'export CLIENT_SECRET=abcdef123456; rm -rf ./build' abcdef123456 'CLIENT_SECRET=***'
secret_case "*_TOKEN=" \
  "API_TOKEN='tok_9f8e7d6c' rm -rf ./build" tok_9f8e7d6c 'API_TOKEN=***'
secret_case "*_KEY=" \
  'OPENAI_API_KEY=sk-proj-abc123def456 rm -rf ./build' sk-proj-abc123 'OPENAI_API_KEY=***'
secret_case "a bare GitLab token (glpat-)" \
  'git push --force origin main # glpat-ZyXwVuTsRqPoNmLkJiHg' glpat-ZyXw '[REDACTED]'
secret_case "a Slack token (xoxb-)" \
  'rm -rf ./build && echo xoxb-1234567890-abcdefghijkl' xoxb-1234 '[REDACTED]'
secret_case "an AWS secret after aws_secret_access_key" \
  'aws configure set aws_secret_access_key wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY && rm -rf ./build' wJalrXUtn 'aws_secret_access_key ***'
secret_case "a Bearer token" \
  'curl -H "Authorization: Bearer eyJhbGciOi.payload.sig-123" https://api.example.test && rm -rf ./build' eyJhbGciOi 'Bearer ***'
secret_case "a secret past column 120 is redacted before the cut" \
  "rm -rf ./build $(printf 'y%.0s' {1..82}) DB_PASSWORD=late_secret_value_that_is_long" late_sec 'DB_PASSWORD=***'

secret_case "URL password containing @" \
  'supabase db push --db-url postgres://u:p@ss@word@db.host.test/db' 'ss@word' 'postgres://***@db.host.test/db'
secret_case "URL password containing : and @" \
  'supabase db push --db-url postgres://admin:pa:ss@w0rd@db.host.test/x' 'w0rd' 'postgres://***@db.host.test/x'
secret_case "Authorization: Basic <base64>" \
  'curl -H "Authorization: Basic dXNlcjpwYXNzd29yZA==" https://api.example.test && rm -rf ./build' dXNlcjpw 'Basic ***'
secret_case "a KEY: value header" \
  'curl -H "X-Api-Key: abc123secretvalue" https://api.example.test && rm -rf ./build' abc123secret 'X-Api-Key: ***'
secret_case "a *_TOKEN: value line" \
  'printf "GITHUB_TOKEN: tok_live_998877\n" > .env && rm -rf ./build' tok_live_998877 'GITHUB_TOKEN: ***'
secret_case "mysql -pPASSWORD" \
  'mysql -u root -phunter3pw -e "DROP TABLE t"' hunter3pw '-p***'
secret_case "an escaped quote inside a quoted value" \
  'DB_PASSWORD="ab\"cd_tail_secret" rm -rf ./build' cd_tail_secret 'DB_PASSWORD=***'
secret_case "a bare AWS access key id (AKIA...)" \
  'rm -rf ./build # AKIA''ABCDEFGHIJKLMNOP' AKIAABCDEFGH '[REDACTED]'
secret_case "a lowercased AWS access key id" \
  'rm -rf ./build # akia''abcdefghijklmnop' akiaabcdefgh '[REDACTED]'
secret_case "a lowercased JWT" \
  'rm -rf ./build # eyjhbgcioijiuzi1nij9.eyjzdwiioiixmjm0nty3odkwin0.c2lnbmf0dxjllxzhbhvl' eyjzdwiioiix '[REDACTED]'
secret_case "a bare AWS secret access key (no name beside it)" \
  'rm -rf ./build # wJalrXUtnFEMI/''K7MDENG/bPxRfiCYzqvwkeyQ12' bPxRfiCY '***'
secret_case "a lowercase PEM header and a lowercase body" \
  "printf '%s\n' '${D5}begin private key${D5}' '$(printf '%s' "$PEMBODY" | tr '[:upper:]' '[:lower:]')' '${D5}end private key${D5}' > k.pem" \
  "$(printf '%s' "${PEMBODY:0:16}" | tr '[:upper:]' '[:lower:]')" '[REDACTED]'
secret_case "a bare JWT (three base64url parts)" \
  'rm -rf ./build # eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl' eyJzdWIiOiIx '[REDACTED]'
secret_case "curl -u user:password" \
  'curl -u admin:hunter2pw https://api.example.test && rm -rf ./build' hunter2pw '-u admin:***'
secret_case "curl --user 'user:password' (quoted)" \
  "curl --user 'admin:hunter4pw' https://api.example.test && rm -rf ./build" hunter4pw 'admin:***'
secret_case "sshpass -p PASSWORD" \
  'sshpass -p hunter5pw ssh host && rm -rf ./build' hunter5pw 'sshpass -p ***'
secret_case "redis-cli ... -a PASSWORD" \
  'redis-cli -h cache -p 6379 -a hunter6pw FLUSHALL && rm -rf ./build' hunter6pw '-a ***'
secret_case "setenv PGPASSWORD value (space, no =)" \
  'setenv PGPASSWORD hunter7pw && rm -rf ./build' hunter7pw 'PGPASSWORD ***'
secret_case "a second mysql -p on one line" \
  'mysql -u a -phunterApw x mysql -u b -phunterBpw -e "DROP TABLE t"' hunterBpw '-p***'

echo; echo "ORDINARY LONG STRINGS ARE KEPT: A GIT SHA, PATHS, IDENTIFIERS"
# The high-entropy rule needs upper, lower and a digit, with each case at
# least a quarter of the letters: a mixed-case path or a camelCase name has
# far fewer capitals than a random key.
for keep in 11f6ad8ec52a2984abaafd7c3b516503785c2072 \
            11F6AD8EC52A2984ABAAFD7C3B516503785C2072 \
            a1fce4363854ff888cff4b8e7875d600c2682390412a8cf79b37d0b11148b0fa \
            /Users/example/Projects/App2/src/components/Button \
            src/components/UserProfile/UserProfileCard2/index \
            /home/runner/work/MyRepo2/MyRepo2/packages/CoreLib \
            useAuthenticatedUserProfileQuery2 \
            feature/ABC-1234-add-new-Login-flow \
            123e4567-e89b-12d3-a456-426614174000; do
  chk "kept: $keep" "$(cd "$SD" && python3 -c 'import fire_log,sys; print(fire_log.redact(sys.argv[1]))' "$keep")" "$keep"
done

echo; echo "THE LOG CANNOT BE WRITTEN: STILL EXIT 2, STDERR BYTE-IDENTICAL"
# The baseline is the same refusal where nothing is logged at all ($N).
broken_case() {  # broken_case <label> <project>
  local code
  code="$(guard "$DB" "$(bash_payload "$RM" "$2")" "$T/b")"
  if [ "$code" = 2 ] && cmp -s "$T/b.err" "$T/baseline.err" && [ ! -s "$T/b.out" ]; then ok "$1"
  else bad "$1" "exit $code, stderr $(cmp -s "$T/b.err" "$T/baseline.err" && echo same || echo DIFFERS), stdout $(wc -c <"$T/b.out" | tr -d ' ') bytes"; fi
}
F1="$T/f1"; newproj "$F1"; : >"$F1/.claude/.bendit-state"
broken_case ".bendit-state is a FILE" "$F1"
F2="$T/f2"; newproj "$F2"; mkdir "$F2/.claude/.bendit-state"; chmod 000 "$F2/.claude/.bendit-state"
broken_case ".bendit-state is a chmod-0 folder" "$F2"
chmod 755 "$F2/.claude/.bendit-state"
F3="$T/f3"; newproj "$F3"; chmod 555 "$F3/.claude"
broken_case ".claude/ is read-only (no state folder can be made)" "$F3"
chmod 755 "$F3/.claude"
F4="$T/f4"; newproj "$F4"; mkdir "$F4/.claude/.bendit-state"; mkfifo "$F4/.claude/.bendit-state/fires.jsonl"
start=$(python3 -c 'import time;print(time.time())')
broken_case "fires.jsonl is a FIFO nobody reads" "$F4"
chk "  and the guard did not hang on it (< 5 s)" \
    "$(python3 -c 'import sys,time;print(time.time() - float(sys.argv[1]) < 5)' "$start")" True
F5="$T/f5"; newproj "$F5"; mkdir "$F5/.claude/.bendit-state"; ln -s "$T/elsewhere" "$F5/.claude/.bendit-state/fires.jsonl"
broken_case "fires.jsonl is a symlink" "$F5"
chk "  and nothing was written through it" "$([ -e "$T/elsewhere" ] && echo written || echo none)" none

echo; echo "NEVER WRITTEN THROUGH A SYMLINK: A CANARY OUTSIDE THE PROJECT STAYS AS IT WAS"
mkdir -p "$T/canary-dir/.bendit-state"
printf 'canary\n' >"$T/canary-dir/fires.jsonl"; printf 'canary\n' >"$T/canary-dir/.bendit-state/fires.jsonl"
printf 'canary\n' >"$T/canary-file"
cp -R "$T/canary-dir" "$T/canary-dir.orig"; cp "$T/canary-file" "$T/canary-file.orig"
canary_same() { diff -r "$T/canary-dir" "$T/canary-dir.orig" >/dev/null && cmp -s "$T/canary-file" "$T/canary-file.orig" && echo same || echo CHANGED; }
S1="$T/s1"; newproj "$S1"; ln -s "$T/canary-dir" "$S1/.claude/.bendit-state"
broken_case ".bendit-state is a symlink to a folder outside" "$S1"
chk "  the canary is unchanged" "$(canary_same)" same
S2="$T/s2"; newproj "$S2" noclaude; ln -s "$T/canary-dir" "$S2/.claude"
broken_case ".claude itself is a symlink to a folder outside" "$S2"
chk "  the canary is unchanged" "$(canary_same)" same
S3="$T/s3"; newproj "$S3"; mkdir "$S3/.claude/.bendit-state"; ln -s "$T/canary-file" "$S3/.claude/.bendit-state/fires.jsonl"
broken_case "fires.jsonl is a symlink to a file outside" "$S3"
chk "  the canary is unchanged" "$(canary_same)" same
mv "$LOG" "$T/old-log"
guard "$DB" "$(bash_payload "$RM" "$P")" "$T/m" >/dev/null
chk "a new fires.jsonl is created owner-only (0600)" \
    "$(python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$LOG" 2>&1)" 0o600

echo; echo "fire_log.py ITSELF IS BROKEN: STILL EXIT 2, STDERR BYTE-IDENTICAL"
# A copy of the plugin's scripts with fire_log.py replaced. The guards import it
# inside a net, after the decision, with stdout and stderr held.
copy_with() {  # copy_with <dir> <fire_log body>
  mkdir -p "$1" && cp "$SD"/*.py "$1/" && printf '%s' "$2" >"$1/fire_log.py"
}
copy_with "$T/syntax" $'def record(:\n'
copy_with "$T/noisy"  $'import sys\nsys.stderr.write("noise on stderr\\n")\nprint("noise on stdout")\ndef record(*a):\n    print("more noise"); raise SystemExit(0)\ndef project_root(*a):\n    return "/"\n'
copy_with "$T/exits"  $'raise SystemExit(0)\n'
python3 "$SD/features.py" set "$P" ls-guard on "ls is a formatter" >/dev/null || bad "features.py set"
python3 "$SD/features.py" set "$NG" ls-guard on "ls is a formatter" >/dev/null || bad "features.py set"
# Each guard's refusal, payload built for a project; baseline in $NG (no git
# repo, so nothing is logged), broken copies in $P (where logging would happen).
refusal() {  # refusal <guard> <project>
  case "$1" in
    block-dangerous-bash) bash_payload "$RM" "$2" ;;
    block-zsh-wordsplit)  bash_payload 'for f in $files; do echo "$f"; done' "$2" ;;
    block-ls-parsing)     bash_payload 'ls | wc -l' "$2" ;;
    path-contracts)       write_payload "$2/src/types.gen.ts" 'export type A = 1' "$2" ;;
  esac
}
for g in block-dangerous-bash block-zsh-wordsplit block-ls-parsing path-contracts; do
  GUARD_ENV="SHELL=/bin/zsh" guard "$SD/$g.py" "$(refusal $g "$NG")" "$T/base-$g" >/dev/null
  for v in syntax noisy exits; do
    : >"$LOG"
    code="$(GUARD_ENV="SHELL=/bin/zsh" guard "$T/$v/$g.py" "$(refusal $g "$P")" "$T/v")"
    if [ "$code" = 2 ] && [ -s "$T/v.err" ] && cmp -s "$T/v.err" "$T/base-$g.err" && [ ! -s "$T/v.out" ] && [ "$(lines "$LOG")" = 0 ]
    then ok "$g, fire_log.py that $v: exit 2, same stderr, empty stdout, no log"
    else bad "$g, fire_log.py that $v" "exit $code; stderr: $(head -c 200 "$T/v.err")"; fi
  done
done

echo; echo "block-primary-checkout: fire_log.py BROKEN, STILL EXIT 2, STDERR BYTE-IDENTICAL"
# Its baseline is the real guard in a project of its own (it allows outside a
# git repo, so the no-log baseline the loop above uses does not apply).
PC="$T/pcg"; newproj "$PC"; git -C "$PC" symbolic-ref HEAD refs/heads/main
python3 "$SD/features.py" set "$PC" primary-checkout-guard on "fire-log test" >/dev/null || bad "features.py set"
python3 "$SD/features.py" integration-branch "$PC" main >/dev/null || bad "features.py integration-branch"
PCLOG="$PC/.claude/.bendit-state/fires.jsonl"
guard "$SD/block-primary-checkout.py" "$(write_payload "$PC/app.py" 'x = 1' "$PC")" "$T/base-pcg" >/dev/null
for v in syntax noisy exits; do
  rm -f "$PCLOG"
  code="$(guard "$T/$v/block-primary-checkout.py" "$(write_payload "$PC/app.py" 'x = 1' "$PC")" "$T/v")"
  if [ "$code" = 2 ] && [ -s "$T/v.err" ] && cmp -s "$T/v.err" "$T/base-pcg.err" && [ ! -s "$T/v.out" ] && [ "$(lines "$PCLOG")" = 0 ]
  then ok "block-primary-checkout, fire_log.py that $v: exit 2, same stderr, empty stdout, no log"
  else bad "block-primary-checkout, fire_log.py that $v" "exit $code; stderr: $(head -c 200 "$T/v.err")"; fi
done

echo; echo "EVERY GUARD IN SCOPE RECORDS ITS OWN RULE"
gcase() {  # gcase <label> <script> <payload> <rule>
  : >"$LOG"
  local code; code="$(guard "$2" "$3" "$T/g")"
  chk "$1: refused"           "$code" 2
  chk "$1: one line, rule $4" "$(lines "$LOG") $(field "$LOG" guard) $(field "$LOG" rule)" "1 $(basename "$2" .py) $4"
}
GUARD_ENV="SHELL=/bin/zsh" gcase "zsh word-split" "$SD/block-zsh-wordsplit.py" \
    "$(bash_payload 'for f in $files; do echo "$f"; done' "$P")" zsh-bare-scalar-loop
gcase "ls parsing" "$SD/block-ls-parsing.py" "$(bash_payload 'ls | wc -l' "$P")" parses-ls-output
gcase "path-contracts .gen" "$SD/path-contracts.py" "$(write_payload "$P/src/types.gen.ts" 'export type A = 1' "$P")" gen-file-edit
gcase "path-contracts .hot" "$SD/path-contracts.py" "$(write_payload "$P/src/p.hot.ts" 'const v = new Vec3()' "$P")" hot-file-allocation
LOG_SAVED="$LOG"; LOG="$PCLOG"
gcase "primary checkout on main" "$SD/block-primary-checkout.py" "$(write_payload "$PC/app.py" 'x = 1' "$PC")" edit-on-integration-branch
LOG="$LOG_SAVED"
: >"$LOG"
GUARD_ENV="SHELL=/bin/zsh" guard "$SD/block-zsh-wordsplit.py" "$(bash_payload 'for f in "$files"; do :; done' "$P")" "$T/z0" >/dev/null
chk "zsh: an allowed loop writes nothing" "$(lines "$LOG")" 0

echo; echo "A CRASH THAT REFUSES IS RECORDED TOO"
: >"$LOG"
bash_payload 'git status' "$P" | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(_text): raise RuntimeError("synthetic")
guard.simple_commands = boom
sys.exit(guard.main())' "$DB" >/dev/null 2>&1
chk "a crash refuses (exit 2)"     "$?" 2
chk "  and is logged as guard-error" "$(field "$LOG" rule)" guard-error

echo; echo "RULES: EACH GUARD NAMES THE RULE IDS ITS REFUSALS USE"
chk "every rule id block-dangerous-bash can log is in its RULES (and no stale ones)" \
    "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
used = {r[2] for r in g.COMMAND_RULES} | {r[2] for r in g.MATERIAL_RULES} | set(g.SPECIAL_RULES)
print(sorted(used ^ set(g.RULES)) or "match")' "$DB" 2>&1)" match
for g in block-zsh-wordsplit block-ls-parsing path-contracts block-dangerous-bash block-primary-checkout; do
  chk "$g: RULES is a literal list of unique ids (guard-report parses it, never runs it)" \
      "$(python3 -c '
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
vals = [ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
        and any(getattr(t, "id", "") == "RULES" for t in n.targets)]
print("ok" if len(vals) == 1 and vals[0] and len(set(vals[0])) == len(vals[0]) else vals)' "$SD/$g.py" 2>&1)" ok
done

echo; echo "REDACTION RUNS IN LINEAR TIME: 64 KB OF ADVERSARIAL TEXT, UNDER A SECOND"
# Each input repeats the shape that once made a pattern rescan the rest of
# the run from every start: hyphen runs (`\b` before each `-`), a name with
# the keyword many times, eyJ after each `-`, mysql/redis-cli many times on
# one line, dotted scheme runs, base64 runs, and runs of `@`, `=` and `:`.
timing_names() {  # timing_names <python>: the inputs redact() took >= 1 s on
  (cd "$SD" && "$1" -c '
import sys, time, fire_log
N = 64 * 1024
def rep(s): return (s * (N // len(s) + 1))[:N]
cases = ["a-", "foo-bar-baz-", "PASSWORD-", "x-TOKEN-", "eyJ-", "eyJxx-", "a.", "a+b-",
         "x-y.", "mysql ", "mysql -x ", "redis-cli ", "redis-cli -a", "sshpass ", "setenv ",
         " -u a:", "-u ", "Ab3+/x9Z", "Ab3_-x9Z", "@", "a@", "=", "a=", ":", "a:", "x://",
         "h://u@", "Bearer ", "\"", "TOKEN=\"", "-----BEGIN ", "glpat-", "xoxb-", "AKIA"]
fire_log.redact("warm up")
slow = []
for c in cases:
    t = time.time(); fire_log.redact(rep(c)); d = time.time() - t
    if d >= 1: slow.append("%r %.1fs" % (c, d))
print(", ".join(slow))' 2>&1)
}
for py in python3 /usr/bin/python3; do
  command -v "$py" >/dev/null 2>&1 || continue
  chk "every adversarial input under 1 s ($("$py" -V 2>&1))" "$(timing_names "$py")" ""
done

echo; echo "A SLOW LOG GIVES UP AT 1.5 s: THE REFUSAL STANDS, WELL INSIDE THE 10 s HOOK TIMEOUT"
# fire_log.py as shipped, with preview_of made slow: one variant sleeps, one
# spins in Python. record()'s alarm must cut both off.
copy_with "$T/sleeps" "$(cat "$SD/fire_log.py")"$'\nimport time\ndef preview_of(_t):\n    time.sleep(30)\n'
copy_with "$T/spins"  "$(cat "$SD/fire_log.py")"$'\ndef preview_of(_t):\n    while True:\n        pass\n'
for v in sleeps spins; do
  : >"$LOG"
  t0=$(python3 -c 'import time;print(time.time())')
  code="$(guard "$T/$v/block-dangerous-bash.py" "$(bash_payload "$RM" "$P")" "$T/v")"
  el=$(python3 -c 'import sys,time;print("%.1f" % (time.time() - float(sys.argv[1])))' "$t0")
  if [ "$code" = 2 ] && cmp -s "$T/v.err" "$T/base-block-dangerous-bash.err" && [ ! -s "$T/v.out" ] \
     && python3 -c 'import sys; sys.exit(not float(sys.argv[1]) < 4)' "$el"
  then ok "a fire_log whose preview $v: exit 2, same stderr, in ${el}s (< 4 s)"
  else bad "a fire_log whose preview $v" "exit $code in ${el}s; stderr $(cmp -s "$T/v.err" "$T/base-block-dangerous-bash.err" && echo same || echo DIFFERS)"; fi
  chk "  and nothing was logged" "$(lines "$LOG")" 0
done
: >"$LOG"
HY="git push --force origin main # $(python3 -c 'print("a-" * 10240)')"
t0=$(python3 -c 'import time;print(time.time())')
code="$(guard "$DB" "$(bash_payload "$HY" "$P")" "$T/hy")"
el=$(python3 -c 'import sys,time;print("%.1f" % (time.time() - float(sys.argv[1])))' "$t0")
chk "a refused 20 KB a-a-... command: exit 2 in under 3 s (took ${el}s)" \
    "$code $(python3 -c 'import sys; print(float(sys.argv[1]) < 3)' "$el")" "2 True"
case "$(cat "$T/hy.err")" in *"BLOCKED by bendit safety hook"*) ok "  with its message intact";; *) bad "  with its message intact" "$(head -c 200 "$T/hy.err")";; esac
chk "  and it is logged (redaction finished inside the limit)" "$(lines "$LOG") $(field "$LOG" rule)" "1 force-push"

echo; echo "THE STATE FOLDER IGNORES ITSELF: fires.jsonl CANNOT BE COMMITTED BY ACCIDENT"
G1="$T/gi1"; newproj "$G1"
guard "$DB" "$(bash_payload "$RM" "$G1")" "$T/gi" >/dev/null
chk "a new .bendit-state gets a .gitignore of '*'" "$(cat "$G1/.claude/.bendit-state/.gitignore" 2>&1)" '*'
chk "  git sees nothing to add in the state folder" \
    "$(git -C "$G1" status --porcelain --untracked-files=all -- .claude/.bendit-state)" ""
chk "  but the log is there" "$(lines "$G1/.claude/.bendit-state/fires.jsonl")" 1
G2="$T/gi2"; newproj "$G2"; mkdir "$G2/.claude/.bendit-state"   # made earlier by another hook
guard "$DB" "$(bash_payload "$RM" "$G2")" "$T/gi" >/dev/null
chk "an existing state folder with no .gitignore gets one with its first log" \
    "$(cat "$G2/.claude/.bendit-state/.gitignore" 2>&1)" '*'
G3="$T/gi3"; newproj "$G3"; mkdir "$G3/.claude/.bendit-state"; printf 'mine\n' >"$G3/.claude/.bendit-state/.gitignore"
guard "$DB" "$(bash_payload "$RM" "$G3")" "$T/gi" >/dev/null
chk "a .gitignore already there is left as it was" "$(cat "$G3/.claude/.bendit-state/.gitignore")" mine
chk "  and the log is written" "$(lines "$G3/.claude/.bendit-state/fires.jsonl")" 1
G4="$T/gi4"; newproj "$G4"; mkdir "$G4/.claude/.bendit-state"
printf 'canary\n' >"$T/gi-canary"; ln -s "$T/gi-canary" "$G4/.claude/.bendit-state/.gitignore"
broken_case ".gitignore is a symlink: still exit 2, same stderr" "$G4"
chk "  nothing written through it" "$(cat "$T/gi-canary")" canary
chk "  and no log either (a log git might not ignore is not written)" "$(lines "$G4/.claude/.bendit-state/fires.jsonl")" 0

echo; echo "BENDIT'S OWN SELF-TESTS ARE NOT REFUSALS: THE DECISION STAYS, ONLY THE LOG IS SKIPPED"
# prove.sh and selfcheck.py set BENDIT_PROBE=1 for every probe they fire, and
# the live test (/bendit:doctor, /bendit:adopt) pushes to the reserved name
# `bendit-probe`. Neither may change what a guard DECIDES or PRINTS: a payload
# carrying either is refused exactly as before; only the log line is skipped.
LIVE='git push --force bendit-probe HEAD'
: >"$LOG"
chk "the live test's push is refused"          "$(guard "$DB" "$(bash_payload "$LIVE" "$P")" "$T/lt")" 2
case "$(cat "$T/lt.err")" in "BLOCKED by bendit"*) ok "  by bendit, with its message";; *) bad "  by bendit, with its message" "$(head -c 200 "$T/lt.err")";; esac
chk "  and it is not logged"                   "$(lines "$LOG")" 0
: >"$LOG"
chk "git push -f bendit-probe (no refspec): refused, not logged" \
    "$(guard "$DB" "$(bash_payload 'git push -f bendit-probe' "$P")" "$T/lt2") $(lines "$LOG")" "2 0"
# Anything that could reach something other than bendit-probe is a real refusal.
for c in 'git push --force origin bendit-probe' \
         'git push --force bendit-probe HEAD && git push --force origin main' \
         'git push --force bendit-probe HEAD; rm -rf ./build' \
         'git push --force bendit-probe main:main' \
         'git push --force --repo=origin bendit-probe HEAD' \
         'git -C elsewhere push --force bendit-probe HEAD' \
         "git push --force \$(echo origin) bendit-probe"; do
  : >"$LOG"
  code="$(guard "$DB" "$(bash_payload "$c" "$P")" "$T/lt3")"
  chk "still logged: $c" "$code $(lines "$LOG")" "2 1"
done

# The same refusal with and without BENDIT_PROBE=1: same exit, same bytes.
same_decision() {  # same_decision <label> <command>
  : >"$LOG"
  local a b
  a="$(guard "$DB" "$(bash_payload "$2" "$P")" "$T/np")"
  chk "$1: refused and logged without BENDIT_PROBE" "$a $(lines "$LOG")" "2 1"
  : >"$LOG"
  b="$(GUARD_ENV="BENDIT_PROBE=1" guard "$DB" "$(bash_payload "$2" "$P")" "$T/wp")"
  chk "  with BENDIT_PROBE=1: still exit 2"     "$b" 2
  chk "  ...stderr byte for byte the same"      "$(cmp -s "$T/np.err" "$T/wp.err" && echo same || echo differs)" same
  chk "  ...stdout byte for byte the same"      "$(cmp -s "$T/np.out" "$T/wp.out" && echo same || echo differs)" same
  chk "  ...and not logged"                     "$(lines "$LOG")" 0
}
same_decision "a real force-push to origin main" 'git push --force origin main'
same_decision "rm -rf ./build" "$RM"
: >"$LOG"
chk "a real rm -rf ./build after a probe run is still logged" \
    "$(guard "$DB" "$(bash_payload "$RM" "$P")" "$T/real") $(lines "$LOG") $(field "$LOG" rule)" "2 1 rm-recursive"

# Every guard's own refusal probe (probes.py, the table prove.sh and selfcheck
# fire): BENDIT_PROBE=1 changes neither the exit code nor a byte of output.
chk "every refusing probe decides the same with BENDIT_PROBE=1" "$(cd "$SD" && python3 - "$SD/.." "$T/pd" <<'PY'
import os, subprocess, sys
kit, top = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(kit, 'scripts'))
import probes as P
diffs, n = [], 0
for (script, args), table in sorted(P.PROBES.items()):
    for i, pr in enumerate(table):
        if pr.expect != 'refuses':
            continue
        runs = []
        for flag in ('unset', '1'):
            w = os.path.join(top, '%s-%d-%s' % (script, i, flag))
            d, base = P.prepare(w)
            env = P.env_for(pr, base, d)
            env.pop('BENDIT_PROBE', None)
            if flag == '1':
                env['BENDIT_PROBE'] = '1'
            p = subprocess.run(['python3', os.path.join(kit, 'scripts', script), *args], input=pr.build(d),
                               capture_output=True, text=True, env=env, cwd=d, timeout=30)
            runs.append((p.returncode, p.stdout.replace(w, '<w>'), p.stderr.replace(w, '<w>')))
        n += 1
        if runs[0] != runs[1] or runs[0][0] != 2:
            diffs.append('%s %s: %r vs %r' % (script, pr.label, runs[0], runs[1]))
print('ok' if n >= 5 and not diffs else '%d probes; differ: %s' % (n, '; '.join(diffs)))
PY
)" ok

echo; echo "fire-log.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
