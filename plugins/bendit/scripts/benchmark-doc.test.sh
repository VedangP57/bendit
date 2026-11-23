#!/usr/bin/env bash
# Every number in the published benchmark write-up comes from a results file.
#
# evals/bench/published.py recomputes each published number from the
# committed results (runs.jsonl, latency.json, benign.json, redteam.json, the
# case files, INDEX.md's v0.2.0 rows) and checks docs/benchmarks/README.md, the
# README's "With and without bendit" section and INDEX.md's v0.5.2 section:
# each generated row must be there verbatim, and no other number may be.
# Then it proves the check can fail: a changed count, a stray number and a
# changed result row must each be caught.
#
#   bash benchmark-doc.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/../../.." && pwd)"
P="$ROOT/plugins/bendit/evals/bench/published.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ -- $2}"; fail=$((fail+1)); }

# copy <dest root> -- the files published.py reads, at their repo paths
copy() {
  local f
  ( cd "$ROOT" && for f in README.md docs/benchmarks/README.md plugins/bendit/evals/results/INDEX.md \
      plugins/bendit/evals/bench/*/case.yaml \
      plugins/bendit/evals/bench/results/*/runs.jsonl \
      plugins/bendit/evals/bench/results/main-2026-11-23/*/runs.jsonl \
      plugins/bendit/evals/bench/results/2026-11-23/*.json; do
      [ -f "$f" ] || continue
      mkdir -p "$1/$(dirname "$f")" && cp "$f" "$1/$f"
    done )
}

for py in python3 /usr/bin/python3; do
  if [ "$py" = /usr/bin/python3 ] && [ ! -x "$py" ]; then echo "--- $py absent, skipped"; continue; fi
  echo "--- $py"
  out=$("$py" -I -B "$P" check 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "the published numbers match the results ($py)"
  else bad "the published numbers match the results ($py)" "$(printf '%s\n' "$out" | head -20)"; fi
done

echo "--- the check fails when it should"
# 1. a count changed by hand in the write-up
copy "$T/a"
if [ -f "$T/a/docs/benchmarks/README.md" ]; then
  python3 - "$T/a/docs/benchmarks/README.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
assert '| 30/30 (89–100%) |' in s
open(p, 'w').write(s.replace('| 30/30 (89–100%) |', '| 29/30 (89–100%) |', 1))
PY
  out=$(python3 -I -B "$P" check --root "$T/a" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "number '29/30' is not computed"; then ok "a hand-edited count fails, naming it"
  else bad "a hand-edited count fails, naming it" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi
else bad "a hand-edited count fails" "docs/benchmarks/README.md missing"; fi

# 2. a stray number in the README section
copy "$T/b"
python3 - "$T/b/README.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
h = '\n## With and without bendit\n'
if h in s:
    s = s.replace(h, h + '\nIt saved 57 hours.\n', 1)
open(p, 'w').write(s)
PY
out=$(python3 -I -B "$P" check --root "$T/b" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "number '57' is not computed"; then ok "a stray number in the README section fails"
else bad "a stray number in the README section fails" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi

# 3. a result that changed under the write-up
copy "$T/c"
python3 - "$T/c/plugins/bendit/evals/bench/results/main-2026-11-23/opus-c2/runs.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)]
for r in rows:
    if r['arm'] == 'A0':
        r['evidence']['hidden_tests'] = 'green'; r['pass'] = True
        break
open(p, 'w').write(''.join(json.dumps(r) + '\n' for r in rows))
PY
out=$(python3 -I -B "$P" check --root "$T/c" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'does not contain: .*1/30'; then ok "a changed results row fails the write-up"
else bad "a changed results row fails the write-up" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi

echo
echo "benchmark-doc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
