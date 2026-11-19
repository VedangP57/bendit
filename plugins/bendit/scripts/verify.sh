#!/usr/bin/env bash
# One command: bring up this repo's app, prove it is the right thing, run every
# scenario, report, tear down. With no app harness, run the repo's declared
# harness (.claude/verify-harness) instead.
#
# Exists because the good path used to be several remembered steps (pick a
# free port, start through the harness not a bare dev server, wait, doctor,
# then each scenario) while the bad path was one (`npm run dev`). A harness
# whose shortest path is not the best path does not get used.
#
# Exit 0 means EVERY scenario ran and passed (or the declared harness passed).
# Only then, and only on a full run, is the Stop gate's `verified` stamp written.
#
# Env:  BENDIT_APP_WAIT   seconds to wait for the app to serve (default 90)
#       BENDIT_CONFIG_DIR where the port registry lives (see ports.py)
#
# usage: verify.sh [scenario]      # omit to run all
set -uo pipefail

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[2m%s\033[0m\n' "$*"; }
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The pid listening on TCP port $1, or nothing. lsof is not installed on every
# Linux, so ss is the fallback; neither present means "unknown", never "free".
listener_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
  fi
}

stamp_verified() {
  mkdir -p "$ROOT/.claude/.verify-state" && : > "$ROOT/.claude/.verify-state/verified"
}

# --- locate repo + harness ------------------------------------------------
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "verify: not inside a git repo"
cd "$ROOT" || die "verify: cannot enter $ROOT"
# `-type l` too: a worktree's harness may be a symlink to a canonical copy, and
# `-type d` alone never matched one, so a correctly linked worktree was told it
# had no harness.
SK=$(find "$ROOT/.claude/skills" -maxdepth 1 \( -type d -o -type l \) -name 'verify-*' 2>/dev/null | head -1)
# IN A WORKTREE WITH NO HARNESS OF ITS OWN, LOOK AT THE MAIN CHECKOUT'S.
#
# A harness kept out of git leaves a new worktree with none. What happens next
# depends on what kind of harness the main checkout has:
#
#  1. SCAFFOLDED (current). It verifies the checkout you stand in, and refuses
#     unless that checkout's own .claude/skills/verify-<name> resolves to it.
#     Running main's copy from here can only be refused, so refuse HERE, name
#     the missing link and give the command. This script edits no tree.
#  2. REPO FROM ITS OWN PATH (hand-written). It would serve the MAIN checkout
#     while reporting this one. Refused.
#  3. REPO FROM `git rev-parse` with no link check. It honours the cwd set
#     above, so running main's copy against this tree is correct.
MAIN=""
if [ -z "$SK" ]; then
  GC=$(git rev-parse --git-common-dir 2>/dev/null)
  case "$GC" in /*) ;; *) GC="$ROOT/$GC" ;; esac
  MAIN=$(cd "$GC/.." 2>/dev/null && pwd -P)
  if [ -n "$MAIN" ] && [ "$MAIN" != "$(cd "$ROOT" && pwd -P)" ]; then
    SK=$(find "$MAIN/.claude/skills" -maxdepth 1 \( -type d -o -type l \) -name 'verify-*' 2>/dev/null | head -1)
    if [ -n "$SK" ]; then
      FBIN=$(find "$SK/bin" -type f -perm -u+x 2>/dev/null | head -1)
      if [ -n "$FBIN" ] && grep -qF '$REPO/.claude/skills/verify-' "$FBIN"; then
        die "verify: this worktree has no .claude/skills/$(basename "$SK"), so it has no harness.
$(basename "$MAIN")'s harness verifies the checkout you stand in, and only when that
checkout links it -- run from here it would refuse. Link it, then re-run:
  mkdir -p \"$ROOT/.claude/skills\" && ln -s \"$SK\" \"$ROOT/.claude/skills/$(basename "$SK")\""
      fi
      if [ -n "$FBIN" ] && ! grep -qE 'REPO="\$\(git rev-parse --show-toplevel' "$FBIN"; then
        die "verify: this worktree has no harness, and $(basename "$MAIN")'s would run against
ITS OWN checkout, not this one -- it sets REPO from its own path, so it would
serve $(basename "$MAIN") while reporting $(basename "$ROOT").
Fix the harness to take the repo from git:
  REPO=\"\$(git rev-parse --show-toplevel)\"
or re-scaffold it (create-verification-skill), which generates that form."
      fi
      say "· no harness in this worktree; using $(basename "$MAIN")'s, against this tree"
    fi
  fi
fi

# --- no app harness: the declared harness IS the verification -------------
if [ -z "$SK" ]; then
  DECL="$ROOT/.claude/verify-harness"
  [ -f "$DECL" ] || die "verify: no harness in $(basename "$ROOT")$([ -n "$MAIN" ] && printf ' or in %s' "$(basename "$MAIN")"): neither .claude/verify-harness nor .claude/skills/verify-*. Create one with the create-verification-skill skill."
  # The declared web harness calls this script. Reaching here from inside it
  # means its verify-* skill is gone, and running it again would loop forever.
  [ -z "${BENDIT_IN_VERIFY:-}" ] || die "verify: .claude/verify-harness asked for the app harness, but there is no .claude/skills/verify-* -- re-scaffold it, or make verify-harness a tests-only harness."
  [ $# -eq 0 ] || die "verify: '$1' is a scenario, but this repo has no app harness (.claude/skills/verify-*) to run scenarios with."
  # The same rule the Stop gate applies: a file of only comments verifies
  # nothing, and `sh` would exit 0 on it.
  grep -v '^[[:space:]]*#' "$DECL" | grep -q '[^[:space:]]' \
    || die "verify: $DECL holds no command, so nothing can verify $(basename "$ROOT")."
  say "· no app harness; running the declared harness .claude/verify-harness"
  BENDIT_IN_VERIFY=1 sh "$DECL"; rc=$?
  echo
  if [ "$rc" -eq 0 ]; then
    stamp_verified
    printf '\033[32mverified by .claude/verify-harness\033[0m\n'
    exit 0
  fi
  printf '\033[31m.claude/verify-harness FAILED (exit %s): not verified\033[0m\n' "$rc"
  exit 1
fi

BIN=$(find "$SK/bin" -type f -perm -u+x 2>/dev/null | head -1)
[ -n "$BIN" ] || die "verify: no runnable harness binary under $SK/bin"
NAME=$(basename "$SK")
# --- port, from the registry and nowhere else -----------------------------
# Harnesses that each default to 3000 mean only ONE verify can run on the
# machine, because the refusal below fires for the second. The registry gives
# each repo its own block and each worktree its own port inside it. A repo this
# machine has never seen (a fresh clone, a new laptop) is REGISTERED here, under
# the registry's lock, with one line saying which port and where -- never
# defaulted to a shared port. Only an allocation that genuinely fails (registry
# unwritable, no free block) refuses, and ports.py says why.
PORTS_PY="$KIT_SCRIPTS/ports.py"
[ -f "$PORTS_PY" ] || die "verify: no ports.py beside verify.sh; cannot assign a port"
PORT=$(python3 "$PORTS_PY" ensure "$ROOT") || exit 2
case "$PORT" in
  ''|*[!0-9]*) die "verify: the port registry did not return a number: '$PORT'" ;;
esac
# EXPORTED, or the harness falls back to its own default and the registry is
# decoration -- the app would come up elsewhere while this script waited here.
export PORT

printf '\033[1m%s\033[0m  %s  ·  app :%s\n\n' "$(basename "$ROOT")" "$NAME" "$PORT"

# --- teardown, armed BEFORE anything it undoes exists ----------------------
# With the trap set after the readiness loop, every `die` in that loop left the
# app running, the slot held and the log behind -- and the next run refused
# with "something is already on :PORT", blaming the machine for this script's
# own leftover.
APP_PID=""
SLOTS_SH="$KIT_SCRIPTS/verify-slots.sh"
SLOT_HELD=""
APP_LOG=""
teardown() {
  # The slot goes back first: a run that dies here must not hold a slot while
  # the rest of teardown runs.
  [ -n "$SLOT_HELD" ] && bash "$SLOTS_SH" release "$SLOT_HELD" 2>/dev/null
  if [ -n "$APP_PID" ]; then
    # The app runs in its OWN process group (see the launch below), so the
    # whole tree goes: `npm run dev` -> sh -> node puts the listener two levels
    # down, and killing the launcher plus its direct children left it holding
    # the port. TERM first, then KILL whatever ignored it.
    #
    # The shell's OWN stderr is parked for this block: bash prints a
    # "line N: PID Terminated: 15 ..." job notice whenever it notices the app
    # died, which can be at `wait` or at any command after the kill. A redirect
    # on `wait` alone still let it through on GitHub's macOS runners.
    exec 3>&2 2>/dev/null
    kill -TERM -- "-$APP_PID" || kill -TERM "$APP_PID"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 -- "-$APP_PID" || break
      sleep 0.3
    done
    kill -KILL -- "-$APP_PID"
    # Reaped, so the port is free when this script returns -- not a moment later.
    wait "$APP_PID"
    exec 2>&3 3>&-
  fi
  [ -n "$APP_LOG" ] && rm -f "$APP_LOG"
  return 0
}
trap teardown EXIT

# --- app ------------------------------------------------------------------
if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT"; then
  # Do NOT reuse it. "Something answers" does not mean "this repo answers", and
  # running this repo's scenarios against another app produces confident nonsense.
  who=$(curl -s --max-time 4 "http://localhost:$PORT" 2>/dev/null | grep -oiE '<title>[^<]{0,60}</title>' | head -1 | sed 's/<[^>]*>//g')
  proc=$(listener_pid "$PORT")
  die "verify: something is already on :$PORT and it was not started by this run.
  it says: ${who:-<no title>}
  pid:     ${proc:-unknown}
  Stop it first -- verifying against the wrong app is worse than not verifying."
fi
# --- concurrency slot ------------------------------------------------------
# Taken BEFORE the app starts and released in teardown, so a run past the
# machine's limit waits instead of starting and failing for the machine's reasons.
if [ -f "$SLOTS_SH" ]; then
  bash "$SLOTS_SH" acquire "$(basename "$ROOT")" "$$" || die "verify: could not take a verify slot"
  SLOT_HELD="$$"
fi

say "· starting app via the harness (never a bare dev server: that reads your real env)"
APP_LOG=$(mktemp "${TMPDIR:-/tmp}/verify-app.XXXXXX") || die "verify: cannot create a log file"
# The app leads its OWN process group (pgid == its pid), which is what lets
# teardown stop the whole tree with one signal. A tiny python3 shim calls
# setpgrp() and execs the harness, so the pid is unchanged. NOT `set -m`: job
# control also makes bash manage the terminal, and on GitHub's macOS runners
# every verify after the first then saw its app never answer (CI, 2026-11-18;
# fine on Linux and on a local Mac). setpgrp touches nothing but the group.
python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' \
  "$BIN" up >"$APP_LOG" 2>&1 &
APP_PID=$!
# READY MEANS SERVING, NOT MERELY ANSWERING.
#
# `curl -s -o /dev/null` exits 0 for ANY response, so a loop on it breaks out on
# the first 500 -- and a cold dev server answers 500 while it is still
# compiling. 000 is no connection yet, 5xx is the server saying it is not
# ready: both keep waiting. Anything else, a 404 or a redirect included, means
# the server is up and routing, which is all readiness claims.
# No `|| printf 000` fallback: curl ALREADY writes 000 when it cannot connect,
# and a fallback appended a second one, `000000`, which matched nothing and
# broke the loop on the first attempt.
app_code() {
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
           "http://localhost:$PORT" 2>/dev/null)
  printf '%s' "${c:-000}"
}
# Why an app that is running did not answer: its processes and their state
# (a T is a STOPPED process), what holds the port, and a verbose probe of both
# loopback names. "Never answered" alone left a CI failure undiagnosable.
why_silent() {
  printf '\n--- why it did not answer ---\n'
  printf 'app process group %s:\n' "$APP_PID"
  ps -A -o pid=,ppid=,pgid=,stat=,etime=,command= 2>&1 \
    | awk -v g="$APP_PID" '$3 == g { print "  " $0 }'
  printf 'listening on :%s: %s\n' "$PORT" "$(listener_pid "$PORT" || true)"
  local h
  for h in 127.0.0.1 localhost; do
    printf 'probe http://%s:%s -> ' "$h" "$PORT"
    curl -sS -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 3 \
      "http://$h:$PORT" 2>&1 | tr '\n' ' '
    printf '\n'
  done
  printf -- '--- end ---\n'
}
CODE=000
APP_WAIT="${BENDIT_APP_WAIT:-90}"
case "$APP_WAIT" in ''|*[!0-9]*|0) APP_WAIT=90 ;; esac
# A DEADLINE IN SECONDS, not a count of attempts: one attempt can take 3s
# (a 2s probe timeout plus the 1s pause), so "within 90s" meant up to 270s.
DEADLINE=$((SECONDS + APP_WAIT))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  CODE=$(app_code)
  case "$CODE" in ''|000|5??) ;; *) break ;; esac
  kill -0 "$APP_PID" 2>/dev/null || { cat "$APP_LOG"
    die "verify: app exited before it served (last status ${CODE:-none})"; }
  sleep 1
done
case "$CODE" in
  ''|000)
    cat "$APP_LOG"
    why_silent
    die "verify: app never answered on :$PORT within ${APP_WAIT}s.
If it is running on another port, its dev command ignores PORT: make '$BIN up' pass it." ;;
  5??)
    cat "$APP_LOG"
    die "verify: app on :$PORT is answering HTTP $CODE, not serving. It is up but
broken -- running the checks now would blame the app for a startup failure.
A stale build cache is a common cause; clear it and re-run." ;;
esac

# --- doctor ---------------------------------------------------------------
echo
if ! "$BIN" doctor; then
  echo
  die "verify: doctor failed -- fix that before trusting any scenario result"
fi

# --- scenarios --------------------------------------------------------------
echo
list=${1:-}
if [ -n "$list" ]; then scenarios="$list"
else scenarios=$(find "$SK/scenarios" -name '*.sh' -not -name '_*' -exec basename {} .sh \; 2>/dev/null | sort); fi
# No scenarios is a FAILURE. Exiting 0 here would let a fresh harness pass the
# Stop gate having exercised nothing but readiness.
[ -n "$scenarios" ] || die "verify: no scenarios in $SK/scenarios/, so nothing was verified. Write one."

pass=0; fail=0; failed=""
for s in $scenarios; do
  # --base EXPLICITLY, so a scenario never navigates to a port it hard-codes.
  #
  # The verdict is matched IN the shell, not with `printf | grep -q`: grep -q
  # exits at the first match, printf then takes SIGPIPE on anything past the
  # 64KB pipe buffer, and under pipefail a scenario that printed its verdict
  # early and its logs after it was reported as FAILED (exit 141).
  if out=$("$BIN" drive "$s" --base "http://localhost:$PORT" 2>&1) \
     && case "$out" in *'VERDICT: VERIFIED'*) true ;; *) false ;; esac; then
    printf '  \033[32m✓\033[0m %s\n' "$s"; pass=$((pass+1))
  else
    why=$(printf '%s\n' "$out" | grep -E '^(FAIL|VERDICT|refusing|drive:)' | head -1 | cut -c1-96)
    printf '  \033[31m✗\033[0m %s\n      %s\n' "$s" "${why:-no verdict returned}"
    fail=$((fail+1)); failed="$failed $s"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%s/%s verified\033[0m   evidence: %s\n' "$pass" "$((pass+fail))" "$SK/artifacts/"
  # Clears the Stop gate -- only on a clean FULL run. A run of one chosen
  # scenario is a partial pass, and a partial pass must not satisfy a gate
  # whose whole job is to insist the change was verified.
  if [ -z "$list" ]; then
    stamp_verified
  else
    printf '\033[2monly %s was run, so the Stop gate is NOT cleared -- run verify with no argument for that.\033[0m\n' "$list"
  fi
else
  printf '\033[31m%s/%s verified -- failed:%s\033[0m\n' "$pass" "$((pass+fail))" "$failed"
  printf '\033[2mA failing scenario is more often a wrong assertion than a defect. Check which.\033[0m\n'
fi
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
