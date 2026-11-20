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
#             several at once (BENDIT_CI_JOBS=1 runs them one at a time)
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

fail() { echo "FAIL: $*" >&2; }

# Suites run CONCURRENTLY: each makes its own mktemp -d and touches nothing
# shared, so the only thing serial order bought was wall time (4:51 here,
# against the Stop gate's 300 s budget). Each suite's output goes to its own file and is
# printed whole, in suite order, so the log reads as it did serially.
# BENDIT_CI_JOBS caps the pool (default: half the CPUs, at least 2) -- not
# every core, because some suites assert that a hook answers within its time
# budget, and a fully loaded machine would test the machine, not the hook.
ci_jobs() {
  local n="${BENDIT_CI_JOBS:-}"
  case "$n" in ''|*[!0-9]*|0) n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"; n=$((n / 2)) ;; *) echo "$n"; return ;; esac
  [ "$n" -ge 2 ] || n=2
  echo "$n"
}

stage_shell() {
  local suites=() s i rc=0 ran=0 jobs
  local -a pids=() idx=() codes=()
  for s in "$PLUGIN"/scripts/*.test.sh; do [ -f "$s" ] && suites+=("$s"); done
  if [ "${#suites[@]}" -eq 0 ]; then fail "no $PLUGIN/scripts/*.test.sh found, so NOTHING was run"; return 1; fi
  jobs="$(ci_jobs)"
  echo "--- ${#suites[@]} suites, up to $jobs at a time"
  # reap -- wait until ANY running suite has finished, record its exit code and
  # free its slot. Bash 3.2 (macOS /bin/bash) has no `wait -n`, so it polls:
  # bash reaps a finished child itself, after which `kill -0` fails and `wait`
  # still returns the child's saved status. (Waiting on the oldest instead let
  # one long suite hold its slot's successors back.)
  reap() {
    local k
    while :; do
      for k in "${!pids[@]}"; do
        if ! kill -0 "${pids[$k]}" 2>/dev/null; then
          wait "${pids[$k]}"; codes[${idx[$k]}]=$?
          unset "pids[$k]" "idx[$k]"; pids=("${pids[@]+"${pids[@]}"}"); idx=("${idx[@]+"${idx[@]}"}")
          return
        fi
      done
      sleep 0.2
    done
  }
  for i in "${!suites[@]}"; do
    while [ "${#pids[@]}" -ge "$jobs" ]; do reap; done
    bash "${suites[$i]}" </dev/null >"$OUT/suite-$i.log" 2>&1 &
    pids+=("$!"); idx+=("$i")
  done
  while [ "${#pids[@]}" -gt 0 ]; do reap; done
  for i in "${!suites[@]}"; do
    s="${suites[$i]}"
    echo "--- bash $s"
    cat "$OUT/suite-$i.log"
    if [ "${codes[$i]}" -eq 0 ]; then ran=$((ran+1)); else fail "$s exited non-zero"; rc=1; fi
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
rm -rf "$OUT"
if [ "${#failed[@]}" -gt 0 ]; then echo "CI FAILED: ${failed[*]}" >&2; exit 1; fi
echo "CI passed: ${stages[*]}"
