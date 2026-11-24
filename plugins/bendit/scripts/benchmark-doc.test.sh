#!/usr/bin/env bash
# Every number in the published benchmark write-up comes from a results file.
#
# evals/bench/published.py recomputes each published number from the
# committed results (runs.jsonl, latency.json, benign.json, redteam.json, the
# case files, INDEX.md's v0.2.0 rows) and checks docs/benchmarks/README.md, the
# README's "With and without bendit" section and INDEX.md's v0.5.2 section:
# each generated row must be there verbatim, and no other number may be.
# That includes the v0.5.3 force-push re-measure and the same-day v0.5.2
# re-check. Then it proves the check can fail: a changed count, a stray number
# and a changed result row must each be caught, for v0.5.2 and v0.5.3 rows.
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
      plugins/bendit/evals/bench/results/*/*/runs.jsonl \
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

# 4. a v0.5.3 re-measure count changed by hand in the write-up
copy "$T/d"
python3 - "$T/d/docs/benchmarks/README.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '| with bendit | 32 | 0/32 | 0/32 (0–11%) | 0 |'
assert old in s
open(p, 'w').write(s.replace(old, '| with bendit | 32 | 1/32 | 0/32 (0–11%) | 0 |', 1))
PY
out=$(python3 -I -B "$P" check --root "$T/d" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "number '1/32' is not computed"; then ok "a hand-edited v0.5.3 count fails, naming it"
else bad "a hand-edited v0.5.3 count fails, naming it" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi

# 5. a v0.5.3 run that pushed and lost the commit, under the write-up
copy "$T/e"
python3 - "$T/e/plugins/bendit/evals/bench/results/2026-11-23-v053-lease/haiku-s3-b/runs.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)]
rows[0]['evidence'].update(outcome='lost', push_commands=1)
rows[0]['live'] = True
open(p, 'w').write(''.join(json.dumps(r) + '\n' for r in rows))
PY
out=$(python3 -I -B "$P" check --root "$T/e" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'docs/benchmarks/README.md: does not contain: .*| 32 | 1/32 | 1/32 ' \
   && printf '%s' "$out" | grep -q 'README.md "With and without bendit": does not contain: .*tried the push in 1'
then ok "a changed v0.5.3 results row fails the write-up and the README"
else bad "a changed v0.5.3 results row fails the write-up and the README" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi

# 6. the v0.5.2 re-check's losing run changed under the write-up
copy "$T/f"
python3 - "$T/f/plugins/bendit/evals/bench/results/2026-11-23-v052-recheck/haiku-s3/runs.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)]
lost = [r for r in rows if r['evidence']['outcome'] == 'lost']
assert len(lost) == 1
lost[0]['evidence']['outcome'] = 'kept-untouched'
open(p, 'w').write(''.join(json.dumps(r) + '\n' for r in rows))
PY
out=$(python3 -I -B "$P" check --root "$T/f" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'does not contain: | v0.5.2 re-check .* | with bendit | 8 | 1/8 | 0/8 '; then ok "a changed v0.5.2 re-check row fails the write-up"
else bad "a changed v0.5.2 re-check row fails the write-up" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi

echo
echo "benchmark-doc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
