#!/usr/bin/env bash
# primary-checkout-guard: with the feature on, an Edit/Write in the PRIMARY
# checkout (git dir == common dir, not a linked worktree) on the integration
# branch is refused, with the exact `git worktree add` command to use instead.
#
# Both halves are tested, plus the edges that decide whether it is safe:
#   - off (absent or "on": false) and "not a git repo" must allow WITHOUT
#     running git: a stub git on PATH leaves a marker if it is ever called;
#   - on and git cannot answer (missing, failing, a corrupt .git) must REFUSE;
#   - a malformed bendit.json must refuse and name the file (features.py's
#     reader contract), except an edit to that file itself, which is the fix;
#   - a linked worktree, another branch, a detached HEAD, a file outside the
#     repo or in another repo, and no resolvable integration branch all allow.
#
#   bash block-primary-checkout.test.sh [--accept]     (PY=/usr/bin/python3 for 3.9)
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/block-primary-checkout.py"
PY_GIVEN="${PY:-}"
PY="$(command -v "${PY:-python3}")"
GIT="$(command -v git)"
pass=0; fail=0
unset CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

. "$SD/expect.sh"
expect_init "$SD/block-primary-checkout.expected"
expect_scrub_dir "$T" '<tmp>'

g() { "$GIT" -c user.email=t@example.com -c user.name=t "$@"; }
# repo <dir>: a committed repo on `main`, whose origin/HEAD names main.
repo() {
  mkdir -p "$1"; g -C "$1" init -q; g -C "$1" symbolic-ref HEAD refs/heads/main
  printf 'x = 1\n' > "$1/app.py"; g -C "$1" add -A; g -C "$1" commit -qm init
  g -C "$1" update-ref refs/remotes/origin/main HEAD
  g -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
on()  { "$PY" "$SD/features.py" set "$1" primary-checkout-guard on "guard test" || exit 1; }
off() { "$PY" "$SD/features.py" set "$1" primary-checkout-guard off "guard test" || exit 1; }
# pl <tool> <file> <cwd>: a PreToolUse payload.
pl() { "$PY" -c '
import json, sys
tool, f, cwd = sys.argv[1:4]
key = "notebook_path" if tool == "NotebookEdit" else "file_path"
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "cwd": cwd,
                  "tool_input": {key: f, "old_string": "x", "new_string": "y", "content": "y"}}))' "$1" "$2" "$3"; }
# run <file> <cwd> [env...]: exit code of an Edit of <file>.
run() { local f="$1" c="$2"; shift 2; pl Edit "$f" "$c" | env "$@" "$PY" "$H" >/dev/null 2>"$T/err"; echo $?; }
cap() { local l="$1" t="$2" f="$3" c="$4"; shift 4
        pl "$t" "$f" "$c" > "$T/payload"
        if [ -z "$PY_GIVEN" ]; then expect_capture "$l" env "$@" "$PY" "$H" < "$T/payload"
        else EXPECT_STDOUT=$(env "$@" "$PY" "$H" < "$T/payload" 2>"$T/err"); EXPECT_CODE=$?; EXPECT_STDERR=$(cat "$T/err"); fi; }

# A git that records every call: proves "allow WITHOUT running git".
STUB="$T/stubbin"; mkdir -p "$STUB"
printf '#!/bin/sh\necho "$@" >> "%s/git-was-called"\nexit 1\n' "$T" > "$STUB/git"; chmod +x "$STUB/git"
called() { if [ -e "$T/git-was-called" ]; then echo yes; else echo no; fi; }
NOGIT="$T/nogit"; mkdir -p "$NOGIT"   # a PATH with no git at all

R="$T/proj"; repo "$R"

echo "FEATURE OFF: ALLOW, AND NEVER RUN GIT"
chk "no bendit.json, on main in the primary checkout -> allow" "$(run "$R/app.py" "$R")" 0
rm -f "$T/git-was-called"
chk "  ...with a git that fails on PATH, still allow"   "$(run "$R/app.py" "$R" PATH="$STUB:$PATH")" 0
chk "  ...and git was never run"                          "$(called)" no
off "$R"
chk "\"on\": false -> allow"                             "$(run "$R/app.py" "$R" PATH="$STUB:$PATH")" 0
chk "  ...and git was never run"                          "$(called)" no
OTHERF="$T/other-feature"; repo "$OTHERF"; "$PY" "$SD/features.py" set "$OTHERF" ls-guard on "x" >/dev/null
chk "bendit.json with only another feature -> allow"     "$(run "$OTHERF/app.py" "$OTHERF" PATH="$STUB:$PATH")" 0
chk "  ...and git was never run"                          "$(called)" no

echo; echo "FEATURE ON, PRIMARY CHECKOUT, ON THE INTEGRATION BRANCH: REFUSE"
on "$R"; g -C "$R" add -A; g -C "$R" commit -qm features   # committed: worktrees share it
cap "Edit on main in the primary checkout (origin/HEAD)" Edit "$R/app.py" "$R"
chk "refused (exit 2)" "$EXPECT_CODE" 2
case "$EXPECT_STDERR" in "BLOCKED by bendit"*) chk "  ...names bendit first" y y;; *) chk "  ...names bendit first ($EXPECT_STDERR)" n y;; esac
has "  ...gives the exact worktree command" "git -C $R worktree add $R-edit-app -b edit-app" "$EXPECT_STDERR"
has "  ...says where the file will be"        "$R-edit-app/app.py" "$EXPECT_STDERR"
has "  ...says where the branch came from"    "origin/HEAD" "$EXPECT_STDERR"
chk "  ...nothing on stdout" "$EXPECT_STDOUT" ""
chk "Write of a NEW file in a new folder -> refuse" "$(pl Write "$R/src/deep/new.py" "$R" | "$PY" "$H" >/dev/null 2>&1; echo $?)" 2
chk "MultiEdit -> refuse"     "$(pl MultiEdit "$R/app.py" "$R" | "$PY" "$H" >/dev/null 2>&1; echo $?)" 2
chk "NotebookEdit -> refuse"  "$(pl NotebookEdit "$R/nb.ipynb" "$R" | "$PY" "$H" >/dev/null 2>&1; echo $?)" 2
chk "a relative path, resolved from cwd -> refuse" "$(run "app.py" "$R")" 2
chk "cwd a subfolder, CLAUDE_PROJECT_DIR the repo -> refuse" "$(mkdir -p "$R/sub"; run "$R/sub/a.py" "$R/sub" CLAUDE_PROJECT_DIR="$R")" 2
SP="$T/with space"; repo "$SP"; on "$SP"
cap "a repo path with a space: the command is quoted" Edit "$SP/my file.py" "$SP"
chk "refused (exit 2)" "$EXPECT_CODE" 2
has "  ...quotes the paths" "git -C '$SP' worktree add '$SP-edit-my-file' -b edit-my-file" "$EXPECT_STDERR"

echo; echo "OTHER SPELLINGS OF THE SAME FILE: STILL REFUSE"
# A case-variant path names the same file on a case-insensitive filesystem
# (macOS default). Only meaningful there: on a case-sensitive one it is SKIPPED,
# never counted as a pass.
RU="$(printf '%s' "$R" | sed 's#/proj$#/PROJ#')"
if [ -e "$RU/app.py" ]; then
  chk "a case-variant path (…/PROJ/app.py) -> refuse" "$(run "$RU/app.py" "$R")" 2
  chk "  ...a new file in a case-variant subfolder -> refuse" "$(mkdir -p "$R/sub"; run "$RU/SUB/new.py" "$R")" 2
else
  printf '  SKIPPED  case-variant path: %s is case-sensitive here\n' "$T"
fi
mkdir -p "$T/links"; ln -s "$R/app.py" "$T/links/link.py"
chk "a symlink OUTSIDE the repo pointing at its file -> refuse" "$(run "$T/links/link.py" "$R")" 2
# `..` after a symlinked folder: the kernel resolves the link FIRST, then `..`,
# so links/sub/../app.py is the repo's app.py. Normalising the text first would
# read it as links/app.py (outside) and allow.
mkdir -p "$R/sub"; ln -s "$R/sub" "$T/links/sub"
chk "outside/link-to-repo-sub/../app.py -> refuse" "$(run "$T/links/sub/../app.py" "$R")" 2
chk "  ...and a relative one, from cwd outside" "$(run "links/sub/../app.py" "$T" CLAUDE_PROJECT_DIR="$R")" 2

echo; echo "FEATURE ON, BUT NOT THIS GUARD'S BUSINESS: ALLOW"
g -C "$R" worktree add -q "$T/wt" -b feature-x
chk "an edit inside a linked worktree (session in the worktree) -> allow" "$(run "$T/wt/app.py" "$T/wt")" 0
chk "an edit inside a linked worktree (session in the primary) -> allow"  "$(run "$T/wt/app.py" "$R")" 0
chk "an edit in the PRIMARY from a session in the worktree -> refuse"     "$(run "$R/app.py" "$T/wt")" 2
g -C "$R" checkout -q -b other
chk "primary checkout on another branch -> allow" "$(run "$R/app.py" "$R")" 0
g -C "$R" checkout -q --detach main
chk "primary checkout, detached HEAD -> allow" "$(run "$R/app.py" "$R")" 0
g -C "$R" checkout -q main
chk "back on main -> refuse again (control)" "$(run "$R/app.py" "$R")" 2
mkdir -p "$T/outside"
chk "a file outside any repo -> allow"   "$(run "$T/outside/x.txt" "$R")" 0
chk "  ...even when its folder does not exist yet" "$(run "$T/nowhere/deep/x.txt" "$R")" 0
O="$T/another"; repo "$O"
chk "a file in ANOTHER repo, on its main -> allow" "$(run "$O/app.py" "$R")" 0
N="$T/notgit"; mkdir -p "$N"; on "$N"
rm -f "$T/git-was-called"
chk "feature on, not a git repo -> allow" "$(run "$N/a.py" "$N" PATH="$STUB:$PATH")" 0
chk "  ...and git was never run"          "$(called)" no

echo; echo "WHICH BRANCH IS THE INTEGRATION BRANCH"
NB="$T/noorigin"; repo "$NB"; g -C "$NB" symbolic-ref --delete refs/remotes/origin/HEAD; on "$NB"
chk "no origin/HEAD and no integrationBranch -> allow (cannot tell)" "$(run "$NB/app.py" "$NB")" 0
"$PY" "$SD/features.py" integration-branch "$NB" main >/dev/null || exit 1
chk "integrationBranch main in bendit.json -> refuse" "$(run "$NB/app.py" "$NB")" 2
has "  ...says where the branch came from" "integrationBranch in .claude/bendit.json" "$(cat "$T/err")"
"$PY" "$SD/features.py" integration-branch "$R" develop >/dev/null || exit 1
chk "integrationBranch develop beats origin/HEAD main: on main -> allow" "$(run "$R/app.py" "$R")" 0
g -C "$R" checkout -q -b develop
chk "  ...on develop -> refuse" "$(run "$R/app.py" "$R")" 2
g -C "$R" checkout -q main
on "$R"   # `set` keeps the integrationBranch
chk "re-running set keeps integrationBranch (still allows main)" "$(run "$R/app.py" "$R")" 0
AMB="$T/ambiguous"; repo "$AMB"; on "$AMB"; g -C "$AMB" tag main; g -C "$AMB" tag origin/main
chk "a tag also named main (git --short would say heads/main) -> still refuse" "$(run "$AMB/app.py" "$AMB")" 2
R2="$T/proj2"; repo "$R2"; on "$R2"

echo; echo "FEATURE ON AND GIT CANNOT ANSWER: REFUSE"
cap "git is not installed" Edit "$R2/app.py" "$R2" PATH="$NOGIT"
chk "no git on PATH -> refuse" "$EXPECT_CODE" 2
has "  ...says git could not run" "git" "$EXPECT_STDERR"
case "$EXPECT_STDERR" in "BLOCKED by bendit"*) chk "  ...names bendit first" y y;; *) chk "  ...names bendit first" n y;; esac
rm -f "$T/git-was-called"
chk "a git that fails -> refuse" "$(run "$R2/app.py" "$R2" PATH="$STUB:$PATH")" 2
chk "  ...and it was run" "$(called)" yes
C="$T/corrupt"; repo "$C"; on "$C"; printf 'garbage\n' > "$C/.git/HEAD"
cap "a corrupt .git (HEAD is garbage)" Edit "$C/app.py" "$C"
chk "corrupt .git -> refuse" "$EXPECT_CODE" 2

echo; echo "GIT TIME IS BOUNDED BELOW THE HOOK'S 10 s TIMEOUT"
chk "the whole decision's git budget is at most 8 s" \
    "$("$PY" -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("g",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(0 < m.GIT_BUDGET <= 8)' "$H")" True
# A git that hangs: with the budget shortened (in-process, so the test is fast),
# the guard refuses and says it ran out of time.
SLOW="$T/slowbin"; mkdir -p "$SLOW"; printf '#!/bin/sh\nsleep 30\n' > "$SLOW/git"; chmod +x "$SLOW/git"
out=$(pl Edit "$R2/app.py" "$R2" | PATH="$SLOW:$PATH" "$PY" -c '
import importlib.util, sys, time
s = importlib.util.spec_from_file_location("g", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.GIT_BUDGET = 1.0
t = time.monotonic(); rc = m.run(); print("rc", rc, "fast", time.monotonic() - t < 2.5)' "$H" 2>"$T/err")
chk "a hanging git -> refuse, within the budget" "$out" "rc 2 fast True"
# The WHOLE run, the fire log included: logging the refusal must not start a
# git of its own (fire_log.project_root's would add up to 1 s past the budget).
out=$(pl Edit "$R2/app.py" "$R2" | PATH="$SLOW:$PATH" "$PY" -c '
import importlib.util, sys, time
s = importlib.util.spec_from_file_location("g", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.GIT_BUDGET = 1.0
t = time.monotonic(); rc = m.run(); print("rc", rc, "within", time.monotonic() - t < 1.5)' "$H" 2>"$T/err")
chk "a hanging git: the run, fire log included, ends within budget + 0.5 s" "$out" "rc 2 within True"
# The same, where the hang is a GRANDCHILD holding git's output pipe open: killing
# git alone would leave the guard waiting for that pipe to close.
printf '#!/bin/sh\nsleep 30 &\nwait\n' > "$SLOW/git"
out=$(pl Edit "$R2/app.py" "$R2" | PATH="$SLOW:$PATH" "$PY" -c '
import importlib.util, sys, time
s = importlib.util.spec_from_file_location("g", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.GIT_BUDGET = 1.0
t = time.monotonic(); rc = m.run(); print("rc", rc, "fast", time.monotonic() - t < 2.5)' "$H" 2>"$T/err")
chk "a git whose child hangs holding the pipe -> refuse, within the budget" "$out" "rc 2 fast True"
has "  ...saying git ran out of time" "did not answer" "$(cat "$T/err")"

echo; echo "MALFORMED bendit.json: REFUSE, NAMING THE FILE"
M="$T/malformed"; repo "$M"; mkdir -p "$M/.claude"; printf '{"version": 1, "features": ' > "$M/.claude/bendit.json"
cap "malformed bendit.json" Edit "$M/app.py" "$M"
chk "refused (exit 2)" "$EXPECT_CODE" 2
has "  ...names the file" "$M/.claude/bendit.json" "$EXPECT_STDERR"
chk "  ...even off main (it cannot tell whether it is on)" "$(g -C "$M" checkout -q -b side; run "$M/app.py" "$M")" 2
chk "an edit to the malformed bendit.json itself -> allow (that is the fix)" "$(run "$M/.claude/bendit.json" "$M")" 0
printf '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x","integrationBranch":"-x"}}}' > "$M/.claude/bendit.json"
chk "an integrationBranch that is not a branch name -> refuse" "$(run "$M/app.py" "$M")" 2

# A file from a newer bendit: an unknown feature written OFF is read past; one
# written ON is a guard this bendit cannot run, so edits are refused.
NW="$T/newer"; repo "$NW"; mkdir -p "$NW/.claude"
printf '{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"x"},"teleport-guard":{"on":false,"why":"later"}}}' > "$NW/.claude/bendit.json"
chk "newer bendit.json, unknown feature off: the guard still refuses on main" "$(run "$NW/app.py" "$NW")" 2
has "  ...for the checkout, not the file" "worktree add" "$(cat "$T/err")"
printf '{"version":1,"features":{"primary-checkout-guard":{"on":false,"why":"x"},"teleport-guard":{"on":false,"why":"later"}}}' > "$NW/.claude/bendit.json"
chk "newer bendit.json, unknown feature off, guard off -> allow" "$(run "$NW/app.py" "$NW")" 0
printf '{"version":1,"features":{"primary-checkout-guard":{"on":false,"why":"x"},"teleport-guard":{"on":true,"why":"chosen"}}}' > "$NW/.claude/bendit.json"
chk "newer bendit.json, unknown feature ON -> refuse" "$(run "$NW/app.py" "$NW")" 2
has "  ...giving the update command" "claude plugin update bendit@bendit --scope project" "$(cat "$T/err")"

echo; echo "JUNK AND SHAPES IT DOES NOT HANDLE"
chk "not JSON, feature on -> allow (no path to judge)" "$(cd "$R2" && printf 'nope' | "$PY" "$H" >/dev/null 2>&1; echo $?)" 0
chk "no file_path, feature on -> allow" "$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{}}' "$R2" | "$PY" "$H" >/dev/null 2>&1; echo $?)" 0

echo; echo "THE REFUSAL IS LOGGED (fire_log), AFTER THE DECISION"
LOG="$R2/.claude/.bendit-state/fires.jsonl"; rm -f "$LOG"
run "$R2/app.py" "$R2" >/dev/null
chk "one line in fires.jsonl, guard and rule named" \
    "$("$PY" -c 'import json,sys; l=[json.loads(x) for x in open(sys.argv[1])]; print(len(l), l[0]["guard"], l[0]["rule"])' "$LOG" 2>&1)" \
    "1 block-primary-checkout edit-on-integration-branch"

if [ -z "$PY_GIVEN" ]; then
  echo; echo "WHAT IT SAYS (snapshot)"
  expect_verify || fail=$((fail+1))
fi
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo; echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
printf '\nblock-primary-checkout: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
