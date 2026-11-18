#!/usr/bin/env bash
# The exact commands CI runs. ci.yml calls this file and nothing else, so what
# you run locally is what the runner runs: there is no second copy to drift.
#
#   bash .github/workflows/ci.sh                   all stages
#   bash .github/workflows/ci.sh shell privacy     just those
#
# Stages: shell  imports  privacy  validate
#
#   shell     every plugins/bendit/scripts/*.test.sh suite
#   imports   byte-compiles every scripts/*.py under python3, and again under
#             /usr/bin/python3 when it exists (3.9 on macOS: the oldest Python
#             the kit supports), so syntax or an annotation 3.9 rejects fails
#   privacy   scripts/privacy-scan.py over every file git would publish
#   validate  `claude plugin validate` on the plugin
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
PLUGIN=./plugins/bendit
OUT="$(mktemp -d)"
failed=()

fail() { echo "FAIL: $*" >&2; }

stage_shell() {
  local suites=() s rc=0 ran=0
  for s in "$PLUGIN"/scripts/*.test.sh; do [ -f "$s" ] && suites+=("$s"); done
  if [ "${#suites[@]}" -eq 0 ]; then fail "no $PLUGIN/scripts/*.test.sh found, so NOTHING was run"; return 1; fi
  for s in "${suites[@]}"; do
    echo "--- bash $s"
    if bash "$s"; then ran=$((ran+1)); else fail "$s exited non-zero"; rc=1; fi
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
  echo "--- claude plugin validate $PLUGIN"
  claude plugin validate "$PLUGIN" 2>&1 | tee "$OUT/validate.txt"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || { fail "validate exited $rc"; return 1; }
  grep -q 'Validation passed' "$OUT/validate.txt" || { fail "validate exited 0 but never said 'Validation passed'"; return 1; }
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
