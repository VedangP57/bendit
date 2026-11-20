#!/usr/bin/env bash
# Fixture test for check-plan.py.
#
# Every rule gets a case that FAILS and a control that PASSES: a linter that
# cannot reject is decoration, and a linter that rejects everything gets turned
# off. The failing cases also assert WHICH message came out, because a fixture
# that exits 1 for an unrelated reason is a test that passes for the wrong
# reason -- the exact way this kind of check lies.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
LINT="$D/check-plan.py"
pass=0; fail=0

# `chk` asserts the exit code and, at most, that ONE phrase appears. The rest of
# what the linter says -- the part that has to teach an author how to fix the
# plan -- was never checked by anything. The snapshot records all of it.
. "$D/expect.sh"
expect_init "$D/check-plan.expected"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs/superpowers/plans" "$TMP/docs/superpowers/specs"
echo "# Word Count Spec" > "$TMP/docs/superpowers/specs/real-spec.md"
PLANS="$TMP/docs/superpowers/plans"
expect_scrub_dir "$TMP" '<tmp>'
# A plan that satisfies every rule. Each failing fixture below is this document
# with exactly one thing broken, so a failure can only be the thing that was
# broken.
good_plan() {
  cat <<'PLAN'
# Word Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A command-line tool that counts words in a UTF-8 text file.

**Architecture:** One pure counting function with no I/O, and a thin argv shim that reads the file and prints the count. The shim is the only part that touches the filesystem.

**Tech Stack:** Python 3, standard library only.

**Spec:** `docs/superpowers/specs/real-spec.md`

## Global Constraints

- Python **3.11** or later.
- No third-party imports.

## Review Focus

1. **An empty file** — the spec says "counts words" and is silent on zero. Expected: `0 words`. *(Task 1)*

---

## File Structure

| File | Responsibility |
| :- | :- |
| `src/wordcount.py` | **Create.** Pure `count_words`. |
| `src/cli.py` | **Create.** argv shim and printing. |

---

### Task 1: The counting function

**Files:**
- Create: `src/wordcount.py`
- Test: `tests/test_wordcount.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `count_words(text: str) -> int`.

- [ ] **Step 1: Write the failing test**

```python
def test_counts_words_separated_by_runs_of_space():
    assert count_words("a  b\tc\n") == 3

def test_empty_text_counts_zero():
    assert count_words("") == 0
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_wordcount.py -v`
Expected: FAIL with "NameError: count_words".

- [ ] **Step 3: Implement `count_words(text: str) -> int` in `src/wordcount.py`**

Split on arbitrary whitespace, which collapses runs.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pytest tests/test_wordcount.py -v`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add src/wordcount.py tests/test_wordcount.py
git commit -m "feat(wordcount): count words in a string"
```

---

### Task 2: The command-line shim, run for real

**Files:**
- Create: `src/cli.py`
- Test: `tests/test_cli.py`

**Interfaces:**
- Consumes: `count_words(text: str) -> int` from Task 1.
- Produces: `main(argv: list[str]) -> int`, the process exit code.

- [ ] **Step 1: Write the failing test**

```python
def test_main_prints_the_count(capsys, tmp_path):
    f = tmp_path / "s.txt"; f.write_text("a b c")
    assert main([str(f)]) == 0
    assert capsys.readouterr().out == "3 words\n"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/test_cli.py -v`
Expected: FAIL with "NameError: main".

- [ ] **Step 3: Implement `main(argv: list[str]) -> int` in `src/cli.py`**

Read the one path in `argv`, print `<n> words`, return 0.

- [ ] **Step 4: Run the real program on a real file**

```bash
printf 'the quick brown fox' > /tmp/sample.txt
python3 -m src.cli /tmp/sample.txt
```
Expected: prints `4 words` and exits 0. A passing unit test is evidence about the test; this is evidence about the program.

- [ ] **Step 5: Commit**

```bash
git add src/cli.py \
        tests/test_cli.py
git commit -m "feat(wordcount): command-line shim"
```
PLAN
}

# chk <want_exit> <label> <file> [must_contain]
# want_exit 0 also asserts the linter printed NOTHING -- the output contract.
chk() {
  local want="$1" label="$2" file="$3" needle="${4:-}" out code
  expect_capture "$label" python3 "$LINT" "$file"
  out=$EXPECT_OUT; code=$EXPECT_CODE
  if [ "$code" -ne "$want" ]; then
    printf '  FAIL  %-50s exit %s, wanted %s\n' "$label" "$code" "$want"
    printf '        output: %s\n' "${out:-<empty>}"
    fail=$((fail+1)); return
  fi
  if [ "$want" -eq 0 ] && [ -n "$out" ]; then
    printf '  FAIL  %-50s clean plan but printed: %s\n' "$label" "$out"
    fail=$((fail+1)); return
  fi
  if [ "$want" -eq 1 ] && [ -z "$out" ]; then
    printf '  FAIL  %-50s exit 1 with no explanation\n' "$label"
    fail=$((fail+1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    printf '  FAIL  %-50s rejected, but not for %s\n' "$label" "$needle"
    printf '        output: %s\n' "$out"
    fail=$((fail+1)); return
  fi
  printf '  ok    %-50s\n' "$label"; pass=$((pass+1))
}

# run_in <dir> <command...> -- a command that runs elsewhere.
# GNU/BSD `env -C` did this and is absent from coreutils < 8.28: green on macOS,
# "invalid option" on an older Linux. Same portability trap as scrubbing only one
# spelling of a temp path. A subshell cd is POSIX and works everywhere.
run_in() { local d="$1"; shift; ( cd "$d" && exec "$@" ); }

# mutate <name> <sed-expression...>  -> prints the fixture path
mutate() {
  local name="$1"; shift
  local p="$PLANS/2026-01-01-$name.md"
  good_plan | sed "$@" > "$p"
  printf '%s' "$p"
}

echo "CONTROLS — a plan that satisfies every rule is silent"
good_plan > "$PLANS/2026-01-01-wordcount.md"
chk 0 "the canonical good plan" "$PLANS/2026-01-01-wordcount.md"


echo
echo "HEADER BLOCK — each required line, deleted"
chk 1 "no REQUIRED SUB-SKILL line" \
  "$(mutate no-subskill '/REQUIRED SUB-SKILL/d')" "REQUIRED SUB-SKILL"
chk 1 "no **Goal:**"         "$(mutate no-goal '/^\*\*Goal:/d')"         "**Goal:**"
chk 1 "no **Architecture:**" "$(mutate no-arch '/^\*\*Architecture:/d')" "**Architecture:**"
chk 1 "no **Tech Stack:**"   "$(mutate no-stack '/^\*\*Tech Stack:/d')"  "**Tech Stack:**"
chk 1 "no **Spec:**"         "$(mutate no-spec '/^\*\*Spec:/d')"         "**Spec:**"
chk 1 "no ## Global Constraints" \
  "$(mutate no-constraints '/^## Global Constraints/d')" "## Global Constraints"
chk 1 "no ## Review Focus" \
  "$(mutate no-review '/^## Review Focus/d')" "## Review Focus"
chk 1 "no ## File Structure" \
  "$(mutate no-filestructure '/^## File Structure/d')" "## File Structure"
chk 1 "title is not an Implementation Plan heading" \
  "$(mutate bad-title '1s/.*/# Some Notes/')" "title heading"

echo
echo "SPEC PATH — the plan must cite a spec that is on disk"
chk 1 "Spec path does not exist" \
  "$(mutate ghost-spec 's|specs/real-spec.md|specs/never-written.md|')" "does not exist"
chk 1 "Spec is the template placeholder, not a path" \
  "$(mutate tmpl-spec 's|^\*\*Spec:\*\*.*|**Spec:** [path to the spec]|')" \
  "does not name a path"
# Control: the same plan with a spec that IS there is silent (above), and a
# spec reached through a markdown link resolves too.
chk 0 "Spec given as a markdown link to a real file" \
  "$(mutate link-spec 's|^\*\*Spec:\*\*.*|**Spec:** [the spec](docs/superpowers/specs/real-spec.md)|')"

echo
echo "TASK SHAPE — Files, Interfaces, checkbox steps"
chk 1 "a task with no **Files:** block" \
  "$(mutate no-files '/^\*\*Files:\*\*/d')" "has no **Files:** block"
chk 1 "a task with no **Interfaces:** block" \
  "$(mutate no-ifaces '/^\*\*Interfaces:\*\*/d')" "has no **Interfaces:** block"
chk 1 "a step that is not a checkbox step" \
  "$(mutate bare-step 's|^- \[ \] \*\*Step 3: Implement `main|**Step 3: Implement `main|')" \
  "not a checkbox step"
chk 1 "a task with no steps at all" \
  "$(mutate no-steps '/^- \[ \] \*\*Step/d')" "has no \"- [ ] **Step N:\" steps"
chk 1 "a task that does not end in a Commit step" \
  "$(mutate no-commit '/^- \[ \] \*\*Step 5: Commit\*\*/d')" "does not end in a Commit step"
chk 1 "a task heading that is not ### Task N:" \
  "$(mutate loose-task 's|^### Task 2:.*|### Task Two: the shim|')" \
  'required form "### Task N:'
# Control: a plan may write `**Files:** none changed.` inline
# rather than as a bulleted block, and that is a legitimate shape.
chk 0 "**Files:**/**Interfaces:** given inline on one line" \
  "$(mutate inline-blocks \
     -e 's|^\*\*Files:\*\*$|**Files:** none changed, this task is evidence.|' \
     -e 's|^\*\*Interfaces:\*\*$|**Interfaces:** Consumes the whole tool.|')"

echo
echo "LIVE STEP — a plan may not prove itself with unit tests alone"
# The live command is the ONLY difference; swap it for a test runner.
chk 1 "only unit assertions, no live step" \
  "$(mutate unit-only 's|^python3 -m src.cli /tmp/sample.txt$|pytest tests/ -v|')" \
  "no task has a step that runs the real thing"
# The same fixture still carries `git add a \` + continuation and a
# `printf > file` line. If continuation-joining broke, the bare filename would
# read as a command and this fixture would wrongly pass.
chk 1 "a staged-file continuation line is not a live step" \
  "$(mutate unit-only2 -e 's|^python3 -m src.cli /tmp/sample.txt$|pytest tests/ -v|' \
                       -e 's|^printf .the quick brown fox. > /tmp/sample.txt$|echo hello|')" \
  "no task has a step that runs the real thing"
# `claude plugin test` is this repo's unit runner, so it must not satisfy it.
chk 1 'claude plugin test does not count as live' \
  "$(mutate claude-test -e 's|^python3 -m src.cli /tmp/sample.txt$|claude plugin test plugins/bendit|' \
                        -e 's|^printf .the quick brown fox. > /tmp/sample.txt$|echo hello|')" \
  "no task has a step that runs the real thing"
# Controls: the live step may be prose with no command at all.
chk 0 "live step is prose — open a session and drive it" \
  "$(mutate prose-live -e 's|^python3 -m src.cli /tmp/sample.txt$|pytest tests/ -v|' \
                       -e 's|^printf .the quick brown fox. > /tmp/sample.txt$|echo hello|' \
                       -e 's|^Expected: prints .4 words. and exits 0.*|Open a session in the terminal and run the tool on a real file by hand.|')"
chk 0 "live step is a curl against the running app" \
  "$(mutate curl-live -e 's|^python3 -m src.cli /tmp/sample.txt$|curl -fsS localhost:8080/count|' \
                      -e 's|^printf .the quick brown fox. > /tmp/sample.txt$|echo hello|')"

echo
echo "PLACEHOLDERS — lines that decide nothing"
for phrase in "TBD" "TODO: decide the format" "implement later" \
              "fill in details" "similar to Task 1" \
              "add appropriate error handling" "add appropriate validation" \
              "handle edge cases" "write tests for the above"; do
  slug=$(printf '%s' "$phrase" | tr -cd '[:alnum:]')
  p="$PLANS/2026-01-01-ph-$slug.md"
  { good_plan; printf '\nSee the spec; %s.\n' "$phrase"; } > "$p"
  chk 1 "placeholder: $phrase" "$p" "decides nothing"
done
# Control: ordinary prose that merely resembles a placeholder is left alone.
p="$PLANS/2026-01-01-ph-control.md"
{ good_plan; printf '\nTask 2 consumes Task 1; the tests above are run by Step 4.\n'; } > "$p"
chk 0 "prose that merely mentions tasks and tests" "$p"
# A TICKED step is progress, not a malformed step. The format writes steps as
# `- [ ]` precisely so execution can tick them; rejecting `- [x]` meant a plan
# could not record progress, and ticking one in docs/ turned CI red.
chk 0 "ticked steps (- [x] and - [X]) are steps" \
  "$(mutate ticked -e 's|^- \[ \] \*\*Step 1:|- [x] **Step 1:|' -e 's|^- \[ \] \*\*Step 2:|- [X] **Step 2:|')"
# The mutation must actually have ticked something, or the case above is vacuous.
chk 1 "CONTROL: a malformed checkbox is still rejected" \
  "$(mutate badbox -e 's|^- \[ \] \*\*Step 1:|- [?] **Step 1:|')" "Step"
# A fenced block is quoted code or output, not the plan's own decision: a step
# that greps for TODOs, or a sample that prints "TBD", was reported as a
# placeholder. Structure already ignores fenced text; placeholders now do too.
p="$PLANS/2026-01-01-ph-fenced.md"
{ good_plan; printf '\n```bash\ngrep -rn "TODO" src/ && echo "TBD count above"\n```\n'; } > "$p"
chk 0 "TODO / TBD inside a fenced code block is not a placeholder" "$p"

echo
echo "TASK NUMBERING — contiguous from 1"
chk 1 "Task 1 and Task 3 (Task 2 renumbered)" \
  "$(mutate gap 's|^### Task 2:|### Task 3:|')" "task numbering jumps"
chk 1 "the plan starts at Task 2" \
  "$(mutate off-by-one -e 's|^### Task 1:|### Task 0:|' -e 's|^### Task 2:|### Task 1:|')" \
  "task numbering jumps"
# Control: a `### Task 9:` inside a fenced code sample is not a task.
p="$PLANS/2026-01-01-fenced-task.md"
{ good_plan; printf '\n```markdown\n### Task 9: an example heading\n```\n'; } > "$p"
chk 0 "a Task heading inside a code fence is not a task" "$p"

echo
echo "FILE HANDLING"
cp "$PLANS/2026-01-01-wordcount.md" "$PLANS/myplan.md"
chk 1 "filename is not YYYY-MM-DD-<name>.md" "$PLANS/myplan.md" "YYYY-MM-DD"
: > "$PLANS/2026-01-01-empty.md"
chk 1 "an empty file" "$PLANS/2026-01-01-empty.md" "the file is empty"
chk 1 "a path that does not exist" "$PLANS/2026-01-01-absent.md" "no such file"

echo
echo "NO ARGUMENTS — checks everything under docs/superpowers/plans/"
# A directory holding only the good plan: a bare run is clean.
CLEAN="$TMP/clean"   # under $TMP, so its path is already scrubbed
mkdir -p "$CLEAN/docs/superpowers/plans" "$CLEAN/docs/superpowers/specs"
echo "# Word Count Spec" > "$CLEAN/docs/superpowers/specs/real-spec.md"
good_plan > "$CLEAN/docs/superpowers/plans/2026-01-01-wordcount.md"
expect_capture "bare run over a directory of good plans" run_in "$CLEAN" python3 "$LINT"
out=$EXPECT_OUT; code=$EXPECT_CODE
if [ "$code" -eq 0 ] && [ -z "$out" ]; then
  printf '  ok    %-50s\n' "bare run over a directory of good plans is clean"; pass=$((pass+1))
else
  printf '  FAIL  %-50s exit %s: %s\n' "bare run over a directory of good plans" "$code" "$out"
  fail=$((fail+1))
fi
# And it must find a bad plan without being pointed at one.
cp "$PLANS/2026-01-01-ph-TBD.md" "$TMP/docs/superpowers/plans/2026-01-01-seeded.md"
expect_capture "bare run discovers plans it was not given" run_in "$TMP" python3 "$LINT"
out=$EXPECT_OUT; code=$EXPECT_CODE
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF 'decides nothing'; then
  printf '  ok    %-50s\n' "bare run discovers plans it was not given"; pass=$((pass+1))
else
  printf '  FAIL  %-50s exit %s: %s\n' "bare run discovers plans it was not given" "$code" "$out"
  fail=$((fail+1))
fi

# --- hook mode: the linter has to FIRE without anyone remembering to run it ---
# `chk` runs the linter on a FILE; the hook takes a payload on stdin, so it needs
# its own comparator rather than being bent through that one.
hchk() { # hchk <label> <got> <want>
  if [ "$2" = "$3" ]; then printf '  ok    %-50s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %-50s got [%s], wanted [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
hookpay() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }
HD="$TMP/docs/superpowers/plans"; mkdir -p "$HD"
printf '# Broken Implementation Plan\n\n**Goal:** TBD\n' > "$HD/2026-10-21-b.md"
printf 'not a plan\n' > "$TMP/NOTAPLAN.md"

expect_capture "hook mode: a bad plan" python3 "$LINT" --hook <<<"$(hookpay "$HD/2026-10-21-b.md")"
hout=$EXPECT_OUT; hcode=$EXPECT_CODE
hchk "hook is advisory: exits 0 even on a bad plan" "$hcode" 0
hchk "hook reports the bad plan" "$(printf '%s' "$hout" | grep -c 'plan check:')" 1
expect_capture "hook mode: not a plan" python3 "$LINT" --hook <<<"$(hookpay "$TMP/NOTAPLAN.md")"
hout=$EXPECT_OUT; hcode=$EXPECT_CODE
hchk "hook ignores a file that is not a plan" "$hcode" 0
hchk "and says nothing about it" "$(printf '%s' "$hout" | wc -c | tr -d ' ')" 0
expect_capture "hook mode: unparseable payload" python3 "$LINT" --hook <<<'not json'
hout=$EXPECT_OUT; hcode=$EXPECT_CODE
hchk "hook survives a payload it cannot parse" "$hcode" 0

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
