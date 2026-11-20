#!/usr/bin/env bash
# External test for controlled-vocabulary.py (every case is hermetic: BENDIT_VOCAB
# is unset, and each repo is a temp dir).
#
# `--self-test` covers the RULES. This covers the COMMAND: exit codes, hook mode,
# the baseline, --fix and the HTML report. Both are needed -- a rule suite that
# passes tells you nothing about whether the hook exits 2.
#
# Every negative assertion is paired with a positive control that must match, and
# every helper is defined before its first call.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CV="$HERE/controlled-vocabulary.py"
# PY picks the interpreter under test. Left unset, the suite runs on python3 and
# then AGAIN on /usr/bin/python3 (3.9 on macOS), the oldest one in use here.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check(){ # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

unset BENDIT_VOCAB
cd "$TMP"
git init -q . >/dev/null 2>&1
mkdir -p repo/.claude/commands repo/docs
cd repo
git init -q . >/dev/null 2>&1

cat > AGENTS.md <<'EOF'
# Repo

Agents should treat this as the source of truth.
Run the migration in order to seed the database.
EOF

cat > docs/progress-report.md <<'EOF'
# Progress

I verified the migration.

Not verified: the cron path.
EOF

echo '--- rule behaviour'
NO_COLOR=1 "$PY" "$CV" --self-test >/dev/null 2>&1
check "--self-test exits 0" "0" "$?"

echo '--- report mode'
out="$(NO_COLOR=1 "$PY" "$CV" . 2>&1)"
case "$out" in
  *OBLIGATION*) ok "report names the obligation rule" ;;
  *) bad "report names the obligation rule" "$out" ;;
esac
case "$out" in
  *EVIDENCE*) ok "report names the evidence rule" ;;
  *) bad "report names the evidence rule" "$out" ;;
esac
# POSITIVE CONTROL for the negative assertion below: prove the word CAN appear
case "$out" in
  *"in order to"*) ok "control: report can print a substitute term" ;;
  *) bad "control: report can print a substitute term" "$out" ;;
esac
# the honest negative form must NOT be reported
case "$out" in
  *"Not verified"*) bad "negated claim must not be reported" "$out" ;;
  *) ok "negated claim is not reported" ;;
esac

echo '--- --check exits 2 and writes to stderr'
NO_COLOR=1 "$PY" "$CV" --check AGENTS.md >"$TMP/cv_out" 2>"$TMP/cv_err"
rc=$?
check "exit code on findings" "2" "$rc"
if [ -s "$TMP/cv_err" ]; then ok "reason went to stderr"; else bad "reason went to stderr" "empty"; fi
if [ -s "$TMP/cv_out" ]; then bad "stdout must stay empty" "$(cat "$TMP/cv_out")"; else ok "stdout stays empty"; fi

echo '--- a clean file exits 0'
printf '# Clean\n\nUse the helper. You must run the gates.\n' > CLEAN.md
NO_COLOR=1 "$PY" "$CV" --check CLEAN.md >/dev/null 2>&1
check "clean file exit code" "0" "$?"

echo '--- a non-markdown file is ignored'
printf 'utilize\n' > thing.ts
NO_COLOR=1 "$PY" "$CV" --check thing.ts >/dev/null 2>&1
check "non-doc exit code" "0" "$?"

echo '--- baseline'
NO_COLOR=1 "$PY" "$CV" --baseline . >/dev/null 2>&1
if [ -f .claude/vocabulary-baseline ]; then ok "baseline file written"; else bad "baseline file written" "missing"; fi
NO_COLOR=1 "$PY" "$CV" --check AGENTS.md >/dev/null 2>&1
check "baselined findings stop firing" "0" "$?"
# POSITIVE CONTROL: a NEW violation must still fire past the baseline
printf '\nYou should utilize the thing.\n' >> AGENTS.md
NO_COLOR=1 "$PY" "$CV" --check AGENTS.md >/dev/null 2>&1
check "a new violation still fires" "2" "$?"

echo '--- cross-repo sweep: each repo answers to its OWN baseline'
# REGRESSION. The baseline was once resolved once per invocation from the first
# path argument, so a sweep across repos found no baseline and reported every
# already-accepted finding as new. Both suites passed while that was true.
cd "$TMP"
mkdir -p repoA repoB
for d in repoA repoB; do
  ( cd "$d" && git init -q . && printf '# A\n\nAgents should do it.\n' > AGENTS.md )
done
# POSITIVE CONTROL: before baselining, both repos must report a finding
pre="$(NO_COLOR=1 "$PY" "$CV" --json repoA repoB 2>/dev/null | grep -c '"rule": "obligation"')"
check "control: both repos report before baselining" "2" "$pre"
NO_COLOR=1 "$PY" "$CV" --baseline repoA repoB >/dev/null 2>&1
if [ -f repoA/.claude/vocabulary-baseline ] && [ -f repoB/.claude/vocabulary-baseline ]; then
  ok "a baseline was written in EACH repo"
else
  bad "a baseline was written in EACH repo" "A=$([ -f repoA/.claude/vocabulary-baseline ] && echo y || echo n) B=$([ -f repoB/.claude/vocabulary-baseline ] && echo y || echo n)"
fi
post="$(NO_COLOR=1 "$PY" "$CV" --json repoA repoB 2>/dev/null | grep -c '"state": "new"')"
check "cross-repo sweep honours both baselines" "0" "$post"
cd "$TMP/repo"

echo '--- suppression needs a reason'
printf '# S\n\nRun it in order to seed. <!-- vocab-ok: quoting the bad form -->\n' > SUP.md
NO_COLOR=1 "$PY" "$CV" --check SUP.md >/dev/null 2>&1
check "suppression with a reason" "0" "$?"
printf '# S\n\nRun it in order to seed. <!-- vocab-ok: -->\n' > SUP.md
NO_COLOR=1 "$PY" "$CV" --check SUP.md >/dev/null 2>&1
check "empty reason does NOT suppress" "2" "$?"

echo '--- --fix applies only safe substitutions'
printf '# F\n\nRun it in order to seed.\nAgents should do it.\n' > FIX.md
NO_COLOR=1 "$PY" "$CV" --fix FIX.md >/dev/null 2>&1
if grep -q 'Run it to seed' FIX.md; then ok "substitute was applied"; else bad "substitute was applied" "$(cat FIX.md)"; fi
if grep -q 'Agents should do it' FIX.md; then ok "obligation was NOT auto-fixed"; else bad "obligation was NOT auto-fixed" "$(cat FIX.md)"; fi

echo '--- html report'
NO_COLOR=1 "$PY" "$CV" --html out.html . >/dev/null 2>&1
if [ -s out.html ]; then ok "html written"; else bad "html written" "missing or empty"; fi
if grep -q 'DOCTYPE html' out.html; then ok "html is a document"; else bad "html is a document" ""; fi
if grep -q '/\*DATA\*/' out.html; then bad "data placeholder was substituted" "placeholder still present"; else ok "data placeholder was substituted"; fi

echo '--- --baseline <subdir> merges; it does not drop the rest of the repo'
# REGRESSION. `--baseline docs` once rewrote the whole baseline with only the
# findings under docs/, so the next full run reported the root's accepted
# findings as new again.
M="$TMP/merge"; mkdir -p "$M/docs"; ( cd "$M" && git init -q . )
printf '# A\n\nRun it in order to seed.\n' > "$M/AGENTS.md"
printf '# B\n\nRun it prior to the seed.\n' > "$M/docs/guide.md"
( cd "$M" && NO_COLOR=1 "$PY" "$CV" --baseline . >/dev/null 2>&1 )
check "control: --baseline . records both findings" "2" "$(grep -vc '^#' "$M/.claude/vocabulary-baseline")"
( cd "$M" && NO_COLOR=1 "$PY" "$CV" --baseline docs >/dev/null 2>&1 )
check "--baseline docs keeps the root's entry" "2" "$(grep -vc '^#' "$M/.claude/vocabulary-baseline")"
n=$( cd "$M" && NO_COLOR=1 "$PY" "$CV" --json . 2>/dev/null | grep -c '"state": "new"' )
check "  ...so a full run reports nothing new" "0" "$n"
# CONTROL: re-baselining a subdir DOES replace what is under it.
printf '# B\n\nClean now.\n' > "$M/docs/guide.md"
( cd "$M" && NO_COLOR=1 "$PY" "$CV" --baseline docs >/dev/null 2>&1 )
check "CONTROL: a fixed finding under docs/ leaves the baseline" "1" "$(grep -vc '^#' "$M/.claude/vocabulary-baseline")"
if grep -q 'AGENTS.md' "$M/.claude/vocabulary-baseline"; then ok "  ...and the one kept is the root's"
else bad "  ...and the one kept is the root's" "$(cat "$M/.claude/vocabulary-baseline")"; fi

echo '--- --fix honours vocab-ok'
printf '# F\n\nUtilize it. <!-- vocab-ok: quoting the bad form -->\n\nUtilize that.\n' > "$M/SUPFIX.md"
fixout=$(NO_COLOR=1 "$PY" "$CV" --fix "$M/SUPFIX.md" 2>&1)
if grep -q '^Utilize it\. <!-- vocab-ok' "$M/SUPFIX.md"; then ok "a suppressed line is left alone"
else bad "a suppressed line is left alone" "$(cat "$M/SUPFIX.md")"; fi
# CONTROL: the unsuppressed line in the same file IS fixed.
if grep -q '^Use that\.' "$M/SUPFIX.md"; then ok "CONTROL: the unsuppressed line is fixed"
else bad "CONTROL: the unsuppressed line is fixed" "$(cat "$M/SUPFIX.md")"; fi
case "$fixout" in *split*) bad "--fix does not mention the rejected split rule" "$fixout";;
                  *) ok "--fix does not mention the rejected split rule";; esac

echo '--- a repo under a folder named like a vendor/instruction dir is scanned normally'
# REGRESSION. VENDOR and doc_class looked at ABSOLUTE path parts, so a repo
# checked out under .../results/ scanned nothing ("0 new 0 total", a silent
# pass), and one under .../skills/ graded every report as an instruction file.
for parent in results skills; do
  Q="$TMP/$parent/repo"; mkdir -p "$Q/docs"; ( cd "$Q" && git init -q . )
  printf '# Progress\n\nI verified the migration.\n' > "$Q/docs/progress-report.md"
  printf '# A\n\nRun it in order to seed.\n' > "$Q/AGENTS.md"
  j=$(NO_COLOR=1 "$PY" "$CV" --json "$Q" 2>&1)
  check "under $parent/: the substitute finding is reported" "1" "$(printf '%s' "$j" | grep -c '"rule": "substitute"')"
  check "under $parent/: the report file is graded as a report" "1" "$(printf '%s' "$j" | grep -c '"rule": "evidence"')"
done
# CONTROL: a results/ folder INSIDE the repo is still excluded.
mkdir -p "$TMP/results/repo/results"
printf '# A\n\nRun it in order to seed.\n' > "$TMP/results/repo/results/out.md"
j=$(NO_COLOR=1 "$PY" "$CV" --json "$TMP/results/repo" 2>&1)
check "CONTROL: results/ inside the repo is still excluded" "1" "$(printf '%s' "$j" | grep -c '"rule": "substitute"')"

echo '--- dictionary is data, and loads'
NO_COLOR=1 "$PY" "$CV" --dict >/dev/null 2>&1
check "--dict exits 0" "0" "$?"

echo '--- generated output is not graded against the vocabulary'
# .superpowers/ holds ledgers and per-task reports written by an agent run.
# Grading generated reports nobody will edit produces work that can never be
# finished.
V="$TMP/vendorscope"
mkdir -p "$V/.superpowers/sdd" "$V/docs"
( cd "$V" && git init -q . )
BODY='Agents should treat this as the source of truth.
Run the migration in order to seed the database.
'
printf '%s' "$BODY" > "$V/.superpowers/sdd/task-1-report.md"
gen=$(NO_COLOR=1 "$PY" "$CV" --json "$V" 2>/dev/null | grep -c '"rule"' || true)
check "a finding inside .superpowers is not reported" "0" "$gen"

# CONTROL: the SAME text outside it must still be reported, or the exclusion
# could be switching the whole checker off.
printf '%s' "$BODY" > "$V/docs/plan.md"
out=$(NO_COLOR=1 "$PY" "$CV" --json "$V" 2>/dev/null | grep -c '"rule"' || true)
if [ "$out" -gt 0 ]; then ok "CONTROL: the same text in docs/ IS reported ($out)"
else bad "CONTROL: the same text in docs/ IS reported" "got $out"; fi

# CONTROL: .cursor is deliberately NOT excluded -- it holds a project's own
# rules alongside vendored docs, and an exclusion wide enough for one drops the
# other.
mkdir -p "$V/.cursor/rules"
printf '%s' "$BODY" > "$V/.cursor/rules/own-rule.mdc"
cur=$(NO_COLOR=1 "$PY" "$CV" --json "$V" 2>/dev/null | grep -c '"file": "\.cursor' || true)
if [ "$cur" -gt 0 ]; then ok "CONTROL: .cursor is still scanned ($cur)"
else bad "CONTROL: .cursor is still scanned" "got $cur -- it was excluded by mistake"; fi

echo '--- dictionary lookup: $BENDIT_VOCAB, then <repo>/.claude/vocabulary.json, then the starter'
STARTER="$HERE/vocabulary.json"
D="$TMP/dict"; mkdir -p "$D"; ( cd "$D" && git init -q . )
printf '# Notes\n\nRun it in order to seed.\n' > "$D/AGENTS.md"
out="$(cd "$D" && NO_COLOR=1 "$PY" "$CV" . 2>&1)"; rc=$?
check "no vocabulary file: report exits 0" "0" "$rc"
case "$out" in *"starter dictionary"*) ok "  ...and says the starter is in use" ;;
  *) bad "  ...and says the starter is in use" "$out" ;; esac
case "$out" in *"in order to"*) ok "  ...and still finds a starter term" ;;
  *) bad "  ...and still finds a starter term" "$out" ;; esac
printf '# Notes\n\nThe frobnicate step runs.\n' > "$D/AGENTS.md"
out="$(cd "$D" && NO_COLOR=1 "$PY" "$CV" . 2>&1)"
case "$out" in *frobnicate*) bad "control: the starter does not know the local-only term" "$out" ;;
  *) ok "control: the starter does not know the local-only term" ;; esac
mkdir -p "$D/.claude"
printf '{"substitute":{"frobnicate":{"use":"run","why":"local term"}}}\n' > "$D/.claude/vocabulary.json"
out="$(cd "$D" && NO_COLOR=1 "$PY" "$CV" . 2>&1)"
case "$out" in *frobnicate*) ok "a repo-local file overrides the starter (its own term is found)" ;;
  *) bad "a repo-local file overrides the starter" "$out" ;; esac
case "$out" in *"starter dictionary"*) bad "  ...and the report no longer claims the starter" "$out" ;;
  *) ok "  ...and the report no longer claims the starter" ;; esac
printf '# Notes\n\nRun it in order to seed.\n' > "$D/AGENTS.md"
out="$(cd "$D" && NO_COLOR=1 "$PY" "$CV" --json . 2>&1)"
check "  ...and a starter term is NOT found once the local file replaces it" "0" "$(printf '%s' "$out" | grep -c 'in order to')"
printf '{"substitute":{"seed":{"use":"plant","why":"env term"}}}\n' > "$TMP/env-vocab.json"
out="$(cd "$D" && BENDIT_VOCAB="$TMP/env-vocab.json" NO_COLOR=1 "$PY" "$CV" --json . 2>&1)"
check "BENDIT_VOCAB beats the repo-local file" "1" "$(printf '%s' "$out" | grep -c '"term": "seed"')"
printf '{ not json' > "$D/.claude/vocabulary.json"
( cd "$D" && NO_COLOR=1 "$PY" "$CV" . >/dev/null 2>"$TMP/badjson" ); rc=$?
check "an unreadable dictionary exits 1, not 0" "1" "$rc"
if grep -q 'cannot read' "$TMP/badjson"; then ok "  ...and says why on stderr"; else bad "  ...and says why on stderr" "$(cat "$TMP/badjson")"; fi

echo '--- --init copies the starter, and never overwrites'
I="$TMP/init"; mkdir -p "$I/sub"; ( cd "$I" && git init -q . )
( cd "$I/sub" && NO_COLOR=1 "$PY" "$CV" --init >/dev/null 2>&1 ); rc=$?
check "--init exits 0 on a repo with no dictionary" "0" "$rc"
if cmp -s "$STARTER" "$I/.claude/vocabulary.json"; then ok "  ...and wrote the starter at the repo root, from a subfolder"
else bad "  ...and wrote the starter at the repo root" "missing or different"; fi
printf 'MINE\n' > "$I/.claude/vocabulary.json"
( cd "$I" && NO_COLOR=1 "$PY" "$CV" --init >/dev/null 2>"$TMP/init2" ); rc=$?
check "a second --init refuses (exit 1)" "1" "$rc"
check "  ...and left the file alone" "MINE" "$(cat "$I/.claude/vocabulary.json")"
if grep -q 'already exists' "$TMP/init2"; then ok "  ...and says why on stderr"; else bad "  ...and says why on stderr" "$(cat "$TMP/init2")"; fi

echo '--- --self-test ignores a local dictionary'
printf '{"substitute":{}}\n' > "$I/.claude/vocabulary.json"
( cd "$I" && NO_COLOR=1 "$PY" "$CV" --self-test >/dev/null 2>&1 )
check "--self-test still exits 0 beside an empty local dictionary" "0" "$?"

cd "$HERE"
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$HERE/controlled-vocabulary.test.sh" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
printf '\n%s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
