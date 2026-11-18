#!/usr/bin/env bash
# Fixtures for expect.sh -- the snapshot mechanism every other suite depends on.
#
# It had no suite of its own: it was exercised only through the five suites that
# use it, which means a defect in it shows up as those suites quietly agreeing
# with whatever it recorded. That is the failure this file exists to prevent,
# and it is the same shape as the ones expect.sh was written to catch.
#
# Four of these pin properties that were broken at some point in its history.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# Each case runs in its own bash so one expect_init cannot leak into the next.
run() { bash -c "set -uo pipefail; cd '$D'; . ./expect.sh; $1" 2>&1; }

echo "STREAMS"
both='expect_init '"$T"'/a.snap
expect_capture one python3 -c "
import sys
print(\"E1\", file=sys.stderr)
print(\"O1\")
"'
chk "stderr is captured on its own"  "$(run "$both"'; printf %s "$EXPECT_STDERR"')" "E1"
chk "stdout is captured on its own"  "$(run "$both"'; printf %s "$EXPECT_STDOUT"')" "O1"
# Plain concatenation glued the last stderr line to the first stdout line, so a
# line-anchored grep over EXPECT_OUT found neither.
chk "the merged form keeps them on separate lines" \
  "$(run "$both"'; printf %s "$EXPECT_OUT" | grep -c "^O1$"')" "1"
chk "and does not glue them"         "$(run "$both"'; printf %s "$EXPECT_OUT" | grep -c "E1O1"')" "0"
chk "the exit code is the command's" \
  "$(run 'expect_init '"$T"'/b.snap; expect_capture x sh -c "exit 7"; printf %s "$EXPECT_CODE"')" "7"

echo
echo "SCRUBBING"
chk "scrub applied when the snapshot is recorded" \
  "$(run 'expect_init '"$T"'/d.snap; expect_scrub SECRET "<x>"; expect_capture x echo SECRET; EXPECT_ACCEPT=1 expect_verify >/dev/null 2>&1; grep -c "<x>" '"$T"'/d.snap')" "1"
chk "and the raw value never reaches the file" \
  "$(run 'expect_init '"$T"'/e.snap; expect_scrub SECRET "<x>"; expect_capture x echo SECRET; EXPECT_ACCEPT=1 expect_verify >/dev/null 2>&1; grep -c SECRET '"$T"'/e.snap')" "0"
# A scrub registered after a capture used to be dropped with a FAIL line that
# changed no exit code, leaving earlier cases carrying machine-specific paths.
chk "a late scrub makes expect_verify FAIL" \
  "$(run 'expect_init '"$T"'/f.snap; expect_capture x echo hi; expect_scrub hi "<y>" >/dev/null 2>&1; expect_verify >/dev/null 2>&1; echo $?')" "1"

echo
echo "ACCEPTING"
# --accept comes from argv. Reading it from the environment meant one exported
# variable rewrote every committed baseline and reported success.
chk "an exported EXPECT_ACCEPT does NOT accept" \
  "$(EXPECT_ACCEPT=1 bash -c "set -uo pipefail; cd '$D'; . ./expect.sh; expect_init $T/g.snap; expect_capture x echo hi; expect_verify >/dev/null 2>&1; echo \$?")" "1"
chk "and writes no snapshot" "$([ -f "$T/g.snap" ] && echo yes || echo no)" "no"

chk "accepting EXITS NON-ZERO so a run that recorded cannot pass" \
  "$(bash -c "set -uo pipefail; cd '$D'; . ./expect.sh; expect_init $T/h.snap; expect_capture x echo hi; expect_verify >/dev/null 2>&1; echo \$?" -- --accept)" "1"
chk "--accept in argv records one" \
  "$([ -f "$T/h.snap" ] && echo recorded || echo no)" "recorded"
chk "the second run, without --accept, then passes" \
  "$(run 'expect_init '"$T"'/h.snap; expect_capture x echo hi; expect_verify >/dev/null 2>&1; echo $?')" "0"

echo
echo "FAILING CLOSED"
chk "a missing snapshot fails" \
  "$(run 'expect_init '"$T"'/nope.snap; expect_capture x echo hi; expect_verify >/dev/null 2>&1; echo $?')" "1"
chk "a changed message fails" \
  "$(run 'expect_init '"$T"'/h.snap; expect_capture x echo CHANGED; expect_verify >/dev/null 2>&1; echo $?')" "1"
# A suite whose captures never ran must not pass by comparing nothing.
chk "an empty transcript fails" \
  "$(run 'expect_init '"$T"'/h.snap; expect_verify >/dev/null 2>&1; echo $?')" "1"
# ...including against an EMPTY snapshot, where the diff is empty too and the
# old code reported "matches (0 cases)".
: > "$T/empty.snap"
chk "zero cases against an empty snapshot fails" \
  "$(run 'expect_init '"$T"'/empty.snap; expect_verify >/dev/null 2>&1; echo $?')" "1"
chk "and accepting zero cases fails too" \
  "$(bash -c "set -uo pipefail; cd '$D'; . ./expect.sh; expect_init $T/zero.snap; expect_verify 2>&1" -- --accept | grep -c 'no cases')" "1"

echo
echo "TRAILING NEWLINES"
# $( ) strips every trailing newline, so a message that grew a blank line, or
# lost its last newline, recorded identically to the old one.
bash -c "set -uo pipefail; cd '$D'; . ./expect.sh; expect_init $T/nl.snap; expect_capture x printf 'a\n'; expect_verify >/dev/null 2>&1" -- --accept
chk "CONTROL: the same output still matches" \
  "$(run 'expect_init '"$T"'/nl.snap; expect_capture x printf "a\n"; expect_verify >/dev/null 2>&1; echo $?')" "0"
chk "an extra trailing newline is a change" \
  "$(run 'expect_init '"$T"'/nl.snap; expect_capture x printf "a\n\n"; expect_verify >/dev/null 2>&1; echo $?')" "1"
chk "a missing final newline is a change" \
  "$(run 'expect_init '"$T"'/nl.snap; expect_capture x printf a; expect_verify >/dev/null 2>&1; echo $?')" "1"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
