#!/usr/bin/env bash
# Machine-wide concurrency limit for verify runs.
#
# WHY. Several dev servers plus their probes running at once can exceed what a
# laptop sustains, and an app that starts under that load answers HTTP 500 --
# which looks exactly like a defect in the app. Starting a run that will fail
# for the machine's reasons is worse than making it wait.
#
# Slots are files named for the holder's pid, so a crashed run cannot hold one
# forever: any slot whose pid is gone is reclaimed by the next caller. The
# count-then-create step runs under a mkdir mutex, which is atomic on every
# filesystem that matters, because two runs that both read "1 of 2 taken" would
# both take the last slot.
#
# Env:  BENDIT_VERIFY_SLOTS    how many runs at once (default 2)
#       BENDIT_VERIFY_LOCKDIR  where slots live
#                                   (default ${XDG_CACHE_HOME:-~/.cache}/bendit/verify-slots)
#
# usage: verify-slots.sh acquire <repo> <pid>   # blocks until a slot is free
#        verify-slots.sh release <pid>
#        verify-slots.sh list
set -uo pipefail

DIR="${BENDIT_VERIFY_LOCKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/bendit/verify-slots}"
SLOTS="${BENDIT_VERIFY_SLOTS:-2}"
case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=2 ;; esac
MUTEX="$DIR/.mutex"

mkdir -p "$DIR" 2>/dev/null || { echo "verify-slots: cannot create $DIR" >&2; exit 2; }

# reclaim: drop every slot whose pid is no longer alive. Returns nothing; the
# caller re-counts afterwards.
reclaim() {
  local f pid
  for f in "$DIR"/*.slot; do
    [ -e "$f" ] || continue
    pid=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')
    case "$pid" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
}

holders() {
  local f out="" who
  for f in "$DIR"/*.slot; do
    [ -e "$f" ] || continue
    who=$(sed -n '2p' "$f" 2>/dev/null)
    [ -n "$out" ] && out="$out, "
    out="$out${who:-?}"
  done
  printf '%s' "$out"
}

count() {
  local f n=0
  for f in "$DIR"/*.slot; do [ -e "$f" ] && n=$((n+1)); done
  printf '%s' "$n"
}

with_mutex() {
  # Bounded: a crashed holder of the mutex must not wedge the machine. The
  # mutex is held for a few file operations, so 10s is already generous.
  local waited=0
  until mkdir "$MUTEX" 2>/dev/null; do
    waited=$((waited+1))
    if [ "$waited" -gt 100 ]; then
      rmdir "$MUTEX" 2>/dev/null
      waited=0
    fi
    sleep 0.1
  done
  "$@"; local rc=$?
  rmdir "$MUTEX" 2>/dev/null
  return $rc
}

try_take() { # repo pid -> 0 if taken
  reclaim
  [ "$(count)" -lt "$SLOTS" ] || return 1
  printf '%s\n%s\n' "$2" "$1" > "$DIR/$2.slot"
  return 0
}

case "${1:-}" in
  acquire)
    repo="${2:?usage: acquire <repo> <pid>}"; pid="${3:?usage: acquire <repo> <pid>}"
    announced=0
    while ! with_mutex try_take "$repo" "$pid"; do
      if [ "$announced" -eq 0 ]; then
        printf 'waiting for a verify slot (%s running: %s)\n' \
          "$(count)" "$(holders)" >&2
        announced=1
      fi
      sleep 1
    done
    ;;
  release)
    pid="${2:?usage: release <pid>}"
    rm -f "$DIR/$pid.slot"
    ;;
  list)
    reclaim
    printf '%s of %s taken: %s\n' "$(count)" "$SLOTS" "$(holders)"
    ;;
  *)
    sed -n '2,24p' "$0" >&2; exit 2 ;;
esac
