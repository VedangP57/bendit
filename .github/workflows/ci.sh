#!/usr/bin/env bash
# The exact commands CI runs. ci.yml calls this file and nothing else, so what
# you run locally is what the runner runs: there is no second copy to drift.
#
#   bash .github/workflows/ci.sh                   all stages
#   bash .github/workflows/ci.sh shell privacy     just those
#
# Stages: shell  imports  privacy  validate
#
#   shell     every plugins/bendit/scripts/*.test.sh suite (only bendit has
#             scripts; a plugin that gains some means changing $PLUGIN below),
#             several at once (BENDIT_CI_JOBS=1 runs them one at a time),
#             those that open ports one at a time after, each under a time
#             limit (BENDIT_CI_SUITE_TIMEOUT, default 240 s)
#   imports   byte-compiles every scripts/*.py under python3, and again under
#             /usr/bin/python3 when it exists (3.9 on macOS: the oldest Python
#             the kit supports), so syntax or an annotation 3.9 rejects fails
#   privacy   scripts/privacy-scan.py over every file git would publish
#   validate  for EVERY plugins/*/ : `claude plugin validate`, then
#             scripts/skill-budget.py over its skills and commands. A plugin with
#             no skills and no commands is skipped by the budget with a printed
#             note (an add-on that is still a skeleton); validate never skips.
#
# There is no `test` stage (`claude plugin test`): v1 ships no TypeScript mod,
# so it would run zero tests -- and a stage with nothing to run is a failure
# here, never a skip. Add the stage back with the first mod test.
#
# Every stage runs even if an earlier one failed (one red run shows every
# regression, not the first), and the exit status is non-zero if ANY did.
# Each stage asserts that it actually ran something (suites found, files
# compiled, files scanned), because a check that passes on an empty input is
# the defect this kit exists to prevent.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
PLUGIN=./plugins/bendit              # the plugin that has scripts/ (shell, imports, privacy)
PLUGINS=(./plugins/*/)               # every plugin: validate and budget
OUT="$(mktemp -d)"
failed=()
RUNNING=()                           # suite wrappers still running (cleanup kills them)

fail() { echo "FAIL: $*" >&2; }

# Ctrl-C, or the Stop gate killing the harness, must not orphan suites: they
# hold ports and app processes. Each wrapper (runsuite.py below) puts its
# suite in a session of its own and kills that whole group when it is
# signalled -- or when it sees this script is gone, which covers SIGKILL.
cleanup() {
  local p
  for p in "${RUNNING[@]+"${RUNNING[@]}"}"; do kill -TERM "$p" 2>/dev/null; done
  for p in "${RUNNING[@]+"${RUNNING[@]}"}"; do wait "$p" 2>/dev/null; done
  RUNNING=()
  rm -rf "$OUT"
}
trap cleanup EXIT
trap 'echo "ci.sh: interrupted, stopping every running suite" >&2; exit 130' INT
trap 'echo "ci.sh: terminated, stopping every running suite" >&2; exit 143' TERM

# Suites run CONCURRENTLY: each makes its own mktemp -d, so the only thing
# serial order bought was wall time (4:51 here, against the Stop gate's 300 s
# budget). Each suite's output goes to its own file and is printed whole, in
# suite order, so the log reads as it did serially.
# BENDIT_CI_JOBS caps the pool (default: half the CPUs, at least 2) -- not
# every core, because some suites assert that a hook answers within its time
# budget, and a fully loaded machine would test the machine, not the hook.
ci_jobs() {
  local n="${BENDIT_CI_JOBS:-}"
  case "$n" in ''|*[!0-9]*|0) n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"; n=$((n / 2)) ;; *) echo "$n"; return ;; esac
  [ "$n" -ge 2 ] || n=2
  echo "$n"
}

# The suites that open ports or start apps: ports.test.sh needs :3100 free,
# and the others bind or serve (drive.test.sh also runs Chrome). They run ONE
# AT A TIME, after the pool, so no two of them -- and no pool suite -- ever
# share a moment. ci.test.sh fails if a suite that binds is missing from this
# list.
SERIAL_SUITES=(drive install-route ports scaffold-verification-skill session-brief verify-readiness)
is_serial() { local n; for n in "${SERIAL_SUITES[@]}"; do [ "$(basename "$1" .test.sh)" = "$n" ] && return 0; done; return 1; }

# One suite per wrapper: its own session (so its whole process group can be
# killed), a time limit (BENDIT_CI_SUITE_TIMEOUT, default 240 s; the slowest
# suite takes about 60 s alone), exit 124 on timeout. Python, not timeout(1):
# macOS has no timeout(1), and python3 is already required by the imports stage.
cat > "$OUT/runsuite.py" <<'PY'
import os, signal, subprocess, sys, time
limit, log, suite, parent = float(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(log, "w") as out:
    p = subprocess.Popen(["bash", suite], stdin=subprocess.DEVNULL, stdout=out,
                         stderr=subprocess.STDOUT, start_new_session=True)
def kill_group():
    for sig, grace in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 0)):
        try:
            os.killpg(p.pid, sig)
        except OSError:
            return
        end = time.time() + grace
        while p.poll() is None and time.time() < end:
            time.sleep(0.1)
def on_signal(signum, _frame):
    kill_group(); sys.exit(128 + signum)
for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(s, on_signal)
end = time.time() + limit
while p.poll() is None:
    if time.time() > end:
        kill_group()
        with open(log, "a") as out:
            out.write("\nTIMEOUT: %s did not finish within %gs; its process group was killed\n" % (suite, limit))
        sys.exit(124)
    if os.getppid() != parent:   # ci.sh is gone (even SIGKILL): take the suite with it
        kill_group(); sys.exit(137)
    time.sleep(0.2)
try:
    os.killpg(p.pid, signal.SIGTERM)  # leftovers the suite started and did not stop
except OSError:
    pass
sys.exit(p.returncode if p.returncode >= 0 else 128 - p.returncode)
PY

stage_shell() {
  local suites=() s i rc=0 ran=0 jobs limit="${BENDIT_CI_SUITE_TIMEOUT:-240}"
  local -a pool=() lane=() idx=() codes=()
  for s in "$PLUGIN"/scripts/*.test.sh; do [ -f "$s" ] && suites+=("$s"); done
  if [ "${#suites[@]}" -eq 0 ]; then fail "no $PLUGIN/scripts/*.test.sh found, so NOTHING was run"; return 1; fi
  for i in "${!suites[@]}"; do if is_serial "${suites[$i]}"; then lane+=("$i"); else pool+=("$i"); fi; done
  jobs="$(ci_jobs)"
  echo "--- ${#suites[@]} suites: ${#pool[@]} up to $jobs at a time, then ${#lane[@]} one at a time (they open ports); ${limit}s limit each"
  # start <i> -- suite i in the background, under its wrapper
  start() {
    python3 "$OUT/runsuite.py" "$limit" "$OUT/suite-$1.log" "${suites[$1]}" "$$" </dev/null &
    RUNNING+=("$!"); idx+=("$1")
  }
  # reap -- wait until ANY running suite has finished, record its exit code and
  # free its slot. Bash 3.2 (macOS /bin/bash) has no `wait -n`, so it polls:
  # bash reaps a finished child itself, after which `kill -0` fails and `wait`
  # still returns the child's saved status. (Waiting on the oldest instead let
  # one long suite hold its slot's successors back.)
  reap() {
    local k
    while :; do
      for k in "${!RUNNING[@]}"; do
        if ! kill -0 "${RUNNING[$k]}" 2>/dev/null; then
          wait "${RUNNING[$k]}"; codes[${idx[$k]}]=$?
          unset "RUNNING[$k]" "idx[$k]"
          RUNNING=("${RUNNING[@]+"${RUNNING[@]}"}"); idx=("${idx[@]+"${idx[@]}"}")
          return
        fi
      done
      sleep 0.2
    done
  }
  for i in "${pool[@]+"${pool[@]}"}"; do
    while [ "${#RUNNING[@]}" -ge "$jobs" ]; do reap; done
    start "$i"
  done
  while [ "${#RUNNING[@]}" -gt 0 ]; do reap; done
  for i in "${lane[@]+"${lane[@]}"}"; do start "$i"; reap; done
  for i in "${!suites[@]}"; do
    s="${suites[$i]}"
    echo "--- bash $s"
    cat "$OUT/suite-$i.log"
    case "${codes[$i]}" in
      0) ran=$((ran+1)) ;;
      124) fail "$s timed out after ${limit}s (killed)"; rc=1 ;;
      *) fail "$s exited non-zero"; rc=1 ;;
    esac
  done
  echo "shell: ${ran}/${#suites[@]} suites passed"
  return $rc
}

stage_imports() {
  local files=() f py rc=0 compiled=0
  for f in "$PLUGIN"/scripts/*.py; do [ -f "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" -eq 0 ]; then fail "no $PLUGIN/scripts/*.py found, so NOTHING was compiled"; return 1; fi
  for py in python3 /usr/bin/python3; do
    # /usr/bin/python3 is optional (absent on some images); python3 is not.
    if [ "$py" = /usr/bin/python3 ] && [ ! -x "$py" ]; then echo "--- $py absent, skipped"; continue; fi
    echo "--- $py -m py_compile: ${#files[@]} files ($("$py" -V 2>&1))"
    # A throwaway cache prefix, so no __pycache__ lands in the tree.
    if PYTHONPYCACHEPREFIX="$OUT/pyc-$compiled" "$py" -m py_compile "${files[@]}"; then
      compiled=$((compiled+1))
    else
      fail "$py could not compile every script"; rc=1
    fi
  done
  if [ "$compiled" -eq 0 ] && [ "$rc" -eq 0 ]; then fail "no interpreter compiled anything"; return 1; fi
  return $rc
}

stage_privacy() {
  echo "--- python3 $PLUGIN/scripts/privacy-scan.py"
  # The scanner exits 2 when it scanned 0 files, so an empty pass cannot happen
  # here. A local, git-ignored .privacy-denylist is applied when present.
  python3 "$PLUGIN/scripts/privacy-scan.py"
}

stage_validate() {
  local p rc=0 validated=0 measured=0 n
  local -a plugins=()
  for p in "${PLUGINS[@]}"; do [ -d "$p" ] && plugins+=("${p%/}"); done
  if [ "${#plugins[@]}" -eq 0 ]; then fail "no plugin under plugins/, so NOTHING was validated"; return 1; fi
  for p in "${plugins[@]}"; do
    echo "--- claude plugin validate $p"
    claude plugin validate "$p" 2>&1 | tee "$OUT/validate.txt"
    n=${PIPESTATUS[0]}
    if [ "$n" -ne 0 ]; then fail "validate $p exited $n"; rc=1
    elif ! grep -q 'Validation passed' "$OUT/validate.txt"; then fail "validate $p exited 0 but never said 'Validation passed'"; rc=1
    else validated=$((validated+1)); fi

    # budget: skills and commands, per plugin. Nothing to measure is a printed
    # skip, not a failure -- but see below: skipping EVERY plugin is one.
    if ! compgen -G "$p/skills/*/SKILL.md" >/dev/null && ! compgen -G "$p/commands/*.md" >/dev/null; then
      echo "--- budget: $p has no skills and no commands, skipped"
      continue
    fi
    echo "--- skill-budget.py $p"
    if python3 "$PLUGIN/scripts/skill-budget.py" --dir "$p/skills" --commands "$p/commands"; then
      measured=$((measured+1))
    else
      fail "skill budget for $p"; rc=1
    fi
  done
  echo "validate: ${validated}/${#plugins[@]} plugins passed; budget measured ${measured}"
  if [ "$measured" -eq 0 ]; then fail "no plugin had a skill or command to budget, so NOTHING was measured"; rc=1; fi
  return $rc
}

stages=("$@"); [ "${#stages[@]}" -gt 0 ] || stages=(shell imports privacy validate)
for st in "${stages[@]}"; do
  case "$st" in shell|imports|privacy|validate) ;; *) echo "unknown stage: $st" >&2; exit 2 ;; esac
  echo "=== $st"
  if "stage_$st"; then echo "=== $st: ok"; else echo "=== $st: FAILED"; failed+=("$st"); fi
done
if [ "${#failed[@]}" -gt 0 ]; then echo "CI FAILED: ${failed[*]}" >&2; exit 1; fi
echo "CI passed: ${stages[*]}"
