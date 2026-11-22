#!/usr/bin/env bash
# guard-report.py: which guard rules fired in the last N days, and which never
# did. A log it cannot read is named and exits 2 -- never reported as "0 fires",
# which would read as "nothing needed refusing".
#
#   bash guard-report.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
R="$SD/guard-report.py"
pass=0; fail=0
unset CLAUDE_PROJECT_DIR
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
. "$SD/expect.sh"
expect_init "$SD/guard-report.expected"
expect_scrub_dir "$T" '<tmp>'

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ -- $2}"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "no [$3] in: $2";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] found in: $2";; *) ok "$1";; esac; }

P="$T/proj"; mkdir -p "$P/.claude/.bendit-state" "$P/sub"; git -C "$P" init -q
LOG="$P/.claude/.bendit-state/fires.jsonl"
# fixture <days-ago> <guard> <rule>: one line, timestamped relative to now so
# the --days window is stable whatever day the suite runs.
fixture() {
  python3 -c '
import datetime, json, sys
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(sys.argv[1]))
print(json.dumps({"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "guard": sys.argv[2], "rule": sys.argv[3], "preview": "x"}))' "$@" >>"$LOG"
}

echo "NO LOG YET"
expect_capture "no log: says so, exit 0" python3 "$R" --root "$P"
chk "no log exits 0"                          "$EXPECT_CODE" 0
has "  and says no refusals recorded yet"     "$EXPECT_OUT" "no refusals recorded yet"

echo; echo "A FIXTURE LOG: COUNTS, AND THE RULES THAT NEVER FIRED"
fixture 1 block-dangerous-bash rm-recursive
fixture 2 block-dangerous-bash rm-recursive
fixture 3 block-dangerous-bash rm-recursive
fixture 5 block-dangerous-bash force-push
fixture 6 path-contracts gen-file-edit
fixture 7 block-dangerous-bash guard-error
fixture 40 block-dangerous-bash git-reset-hard
expect_capture "fixture: 30-day table" python3 "$R" --root "$P"
chk "exit 0"                                  "$EXPECT_CODE" 0
OUT="$EXPECT_STDOUT"
has "rm-recursive counted 3"                  "$OUT" "rm-recursive"
chk "  with count 3"                          "$(printf '%s\n' "$OUT" | awk '$2=="rm-recursive"{print $3}')" 3
chk "force-push counted 1"                    "$(printf '%s\n' "$OUT" | awk '$2=="force-push"{print $3}')" 1
chk "a refusal outside RULES (guard-error) still shows" "$(printf '%s\n' "$OUT" | awk '$2=="guard-error"{print $3}')" 1
NEVER="$(printf '%s\n' "$OUT" | sed -n 's/^never fired in 30 days: //p')"
has "never-fired names a quiet rule"          "$NEVER" "block-dangerous-bash/find-delete"
has "  and the 40-day-old one, outside the window" "$NEVER" "block-dangerous-bash/git-reset-hard"
has "  and other guards' rules"               "$NEVER" "block-zsh-wordsplit/zsh-bare-scalar-loop"
hasnt "  but not a rule that fired"           "$NEVER" "rm-recursive"
hasnt "  nor path-contracts/gen-file-edit"    "$NEVER" "gen-file-edit"
expect_capture "fixture: --days 50 takes in the old one" python3 "$R" --root "$P" --days 50
chk "--days 50 counts git-reset-hard"         "$(printf '%s\n' "$EXPECT_STDOUT" | awk '$2=="git-reset-hard"{print $3}')" 1
(cd "$P/sub" && python3 "$R") >"$T/sub.out" 2>&1
chk "with no --root, the cwd's git toplevel is used" "$(awk '$2=="rm-recursive"{print $3}' "$T/sub.out")" 3

echo; echo "CORRUPT LINES ARE SKIPPED, AND COUNTED"
printf '%s\n' '{not json' '["a list"]' '{"ts": "yesterday", "guard": "g", "rule": "r"}' >>"$LOG"
expect_capture "corrupt lines: skipped and counted" python3 "$R" --root "$P"
chk "exit 0"                                  "$EXPECT_CODE" 0
has "says how many were skipped"              "$EXPECT_OUT" "skipped 3 unreadable lines"
chk "  and still counts the good ones"        "$(printf '%s\n' "$EXPECT_STDOUT" | awk '$2=="rm-recursive"{print $3}')" 3

echo; echo "A LOG IT CANNOT READ: NAMED, EXIT 2, NEVER '0 fires'"
U="$T/unreadable"; mkdir -p "$U/.claude/.bendit-state/fires.jsonl"; git -C "$U" init -q
expect_capture "log is a folder: named, exit 2" python3 "$R" --root "$U"
chk "a folder where the log should be exits 2" "$EXPECT_CODE" 2
has "  and names the log"                     "$EXPECT_STDERR" "fires.jsonl"
hasnt "  and never says no refusals"          "$EXPECT_OUT" "no refusals recorded"
if [ "$(id -u)" != 0 ]; then
  U2="$T/unreadable2"; mkdir -p "$U2/.claude/.bendit-state"; git -C "$U2" init -q
  echo '{}' >"$U2/.claude/.bendit-state/fires.jsonl"; chmod 000 "$U2/.claude/.bendit-state/fires.jsonl"
  python3 "$R" --root "$U2" >"$T/u2.out" 2>&1
  chk "a chmod-0 log exits 2"                 "$?" 2
else
  echo "  skip  a chmod-0 log exits 2 (running as root, which can read it anyway)"
fi

echo; echo "A LOG FROM A CLONED REPO CANNOT DRIVE THE TERMINAL"
# fires.jsonl in a repo someone else made is their text: escape sequences,
# C1 controls and bidi overrides in guard or rule print as '?'.
E="$T/escapes"; mkdir -p "$E/.claude/.bendit-state"; git -C "$E" init -q
python3 -c '
import datetime, json
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"ts": ts, "guard": "evil\x1b]0;pwned\x07guard", "rule": "r\x1b[31m\x9bred\u202eltr", "preview": "x"}))' \
  >"$E/.claude/.bendit-state/fires.jsonl"
python3 "$R" --root "$E" >"$T/esc.out" 2>&1
chk "exit 0"                                  "$?" 0
chk "  no ESC, BEL, C1 or bidi character in the output" \
    "$(python3 -c 'import sys; print(sum(1 for c in open(sys.argv[1], encoding="utf-8").read() if ord(c) in (0x1b, 0x07) or 0x80 <= ord(c) <= 0x9f or 0x202a <= ord(c) <= 0x202e or 0x2066 <= ord(c) <= 0x2069))' "$T/esc.out")" 0
has "  the row still shows, made safe"       "$(cat "$T/esc.out")" "evil?]0;pwned?guard"

echo; echo "BAD ARGUMENTS"
python3 "$R" --days nope --root "$P" >/dev/null 2>&1
chk "--days must be a whole number of days" "$?" 2

echo; echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo; echo "guard-report.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
