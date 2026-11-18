#!/usr/bin/env bash
# Tests for verify-slots.sh.
#
# Each "it waits" assertion is paired with proof that it LATER proceeds, or a
# slot limiter that simply never granted anything would pass. Never cd's into
# $TMP: a cd into a directory the trap deletes wedges the shell.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
S="$D/verify-slots.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

LD="$TMP/slots"
slots() { BENDIT_VERIFY_LOCKDIR="$LD" "$@"; }
nslots() { local n=0 f; for f in "$LD"/*.slot; do [ -e "$f" ] && n=$((n+1)); done; printf '%s' "$n"; }

# Live pids to own slots with. `sleep` is a real process, so kill -0 succeeds.
sleep 60 & P1=$!
sleep 60 & P2=$!

echo "TAKING SLOTS UP TO THE LIMIT"
slots bash "$S" acquire repo-a "$P1"
check "first acquire succeeds" "1" "$(nslots)"
slots bash "$S" acquire repo-b "$P2"
check "second acquire succeeds (limit is 2)" "2" "$(nslots)"
out=$(slots bash "$S" list 2>&1)
case "$out" in *"2 of 2 taken"*repo-a*repo-b*) ok "list names both holders";;
                *) bad "list names both holders" "$out";; esac

echo
echo "A THIRD RUN WAITS"
sleep 60 & P3=$!
( BENDIT_VERIFY_LOCKDIR="$LD" bash "$S" acquire repo-c "$P3" >"$TMP/c.out" 2>"$TMP/c.err" ) &
ACQ=$!
sleep 3
check "it has NOT taken a slot" "2" "$(nslots)"
if kill -0 "$ACQ" 2>/dev/null; then ok "  ...and it is still blocked, not exited"
else bad "  ...and it is still blocked, not exited" "the acquire returned"; fi
case "$(cat "$TMP/c.err" 2>/dev/null)" in
  *"waiting for a verify slot"*) ok "  ...having said it is waiting";;
  *) bad "  ...having said it is waiting" "$(cat "$TMP/c.err" 2>/dev/null)";;
esac
case "$(cat "$TMP/c.err" 2>/dev/null)" in
  *repo-a*|*repo-b*) ok "  ...and named who holds the slots";;
  *) bad "  ...and named who holds the slots" "$(cat "$TMP/c.err" 2>/dev/null)";;
esac

echo
echo "...AND PROCEEDS ONCE A SLOT IS RELEASED"
# Without this the limiter could be refusing everything forever.
slots bash "$S" release "$P1"
waited=0
while kill -0 "$ACQ" 2>/dev/null && [ "$waited" -lt 15 ]; do sleep 1; waited=$((waited+1)); done
if kill -0 "$ACQ" 2>/dev/null; then bad "the waiter acquires after a release" "still blocked after ${waited}s"
else ok "the waiter acquires after a release (${waited}s)"; fi
check "  ...and the count is back at the limit" "2" "$(nslots)"

echo
echo "A DEAD PID'S SLOT IS RECLAIMED"
LD2="$TMP/slots2"; mkdir -p "$LD2"
# 999999 is not a live pid on macOS or Linux; the file is otherwise well-formed,
# so only the liveness check can clear it.
printf '999999\nghost-repo\n' > "$LD2/999999.slot"
printf '999998\nghost-two\n'  > "$LD2/999998.slot"
sleep 60 & P4=$!
BENDIT_VERIFY_LOCKDIR="$LD2" bash "$S" acquire repo-d "$P4"
if [ -e "$LD2/999999.slot" ] || [ -e "$LD2/999998.slot" ]; then
  bad "dead slots are removed" "a ghost slot survived"
else ok "dead slots are removed"; fi
if [ -e "$LD2/$P4.slot" ]; then ok "  ...and the live run got a slot"
else bad "  ...and the live run got a slot" "no slot file"; fi
# CONTROL: a LIVE pid's slot must survive a reclaim.
BENDIT_VERIFY_LOCKDIR="$LD2" bash "$S" list >/dev/null 2>&1
if [ -e "$LD2/$P4.slot" ]; then ok "CONTROL: a live pid's slot is NOT reclaimed"
else bad "CONTROL: a live pid's slot is NOT reclaimed" "it was removed"; fi
# A malformed slot file is also cleared, or it would hold a slot forever.
printf 'not-a-pid\nbroken\n' > "$LD2/bad.slot"
BENDIT_VERIFY_LOCKDIR="$LD2" bash "$S" list >/dev/null 2>&1
if [ -e "$LD2/bad.slot" ]; then bad "a malformed slot is cleared" "it survived"
else ok "a malformed slot is cleared"; fi

echo
echo "THE LIMIT COMES FROM BENDIT_VERIFY_SLOTS"
LD3="$TMP/slots3"
sleep 60 & P5=$!
sleep 60 & P6=$!
BENDIT_VERIFY_LOCKDIR="$LD3" BENDIT_VERIFY_SLOTS=1 bash "$S" acquire one "$P5"
out=$(BENDIT_VERIFY_LOCKDIR="$LD3" BENDIT_VERIFY_SLOTS=1 bash "$S" list 2>&1)
case "$out" in *"1 of 1 taken"*) ok "SLOTS=1 reports a limit of 1";;
                *) bad "SLOTS=1 reports a limit of 1" "$out";; esac
( BENDIT_VERIFY_LOCKDIR="$LD3" BENDIT_VERIFY_SLOTS=1 bash "$S" acquire two "$P6" >/dev/null 2>&1 ) &
A2=$!
disown "$A2" 2>/dev/null || true
sleep 2
if kill -0 "$A2" 2>/dev/null; then ok "  ...and a SECOND run waits under SLOTS=1"
else bad "  ...and a SECOND run waits under SLOTS=1" "it was granted"; fi
kill "$A2" 2>/dev/null
# CONTROL: raising the limit admits the run the lower limit refused.
LD4="$TMP/slots4"
BENDIT_VERIFY_LOCKDIR="$LD4" BENDIT_VERIFY_SLOTS=3 bash "$S" acquire a "$P5"
BENDIT_VERIFY_LOCKDIR="$LD4" BENDIT_VERIFY_SLOTS=3 bash "$S" acquire b "$P6"
sleep 60 & P7=$!
BENDIT_VERIFY_LOCKDIR="$LD4" BENDIT_VERIFY_SLOTS=3 bash "$S" acquire c "$P7"
n=0; for f in "$LD4"/*.slot; do [ -e "$f" ] && n=$((n+1)); done
check "CONTROL: SLOTS=3 admits three runs" "3" "$n"
# A nonsense value falls back to 2 rather than to unlimited or zero.
LD5="$TMP/slots5"
out=$(BENDIT_VERIFY_LOCKDIR="$LD5" BENDIT_VERIFY_SLOTS=abc bash "$S" list 2>&1)
case "$out" in *"of 2 taken"*) ok "a non-numeric SLOTS falls back to 2";;
                *) bad "a non-numeric SLOTS falls back to 2" "$out";; esac
out=$(BENDIT_VERIFY_LOCKDIR="$LD5" BENDIT_VERIFY_SLOTS=0 bash "$S" list 2>&1)
case "$out" in *"of 2 taken"*) ok "SLOTS=0 falls back to 2, never blocks forever";;
                *) bad "SLOTS=0 falls back to 2, never blocks forever" "$out";; esac

echo
echo "THE DEFAULT LOCATION IS PER-USER CACHE, NEVER THE PLUGIN FOLDER"
# With no explicit lock dir, slots go under XDG_CACHE_HOME. Pointed at a temp
# dir here so this suite never touches the real cache.
env -u BENDIT_VERIFY_LOCKDIR XDG_CACHE_HOME="$TMP/xdg" bash "$S" list >/dev/null 2>&1
if [ -d "$TMP/xdg/bendit/verify-slots" ]; then ok "slots default to \$XDG_CACHE_HOME/bendit/verify-slots"
else bad "slots default to \$XDG_CACHE_HOME/bendit/verify-slots" "no such directory"; fi
if [ -z "$(/usr/bin/find "$D/.." -name '*.slot' 2>/dev/null)" ]; then ok "  ...and no slot file exists anywhere in the plugin"
else bad "  ...and no slot file exists anywhere in the plugin" "found one"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
