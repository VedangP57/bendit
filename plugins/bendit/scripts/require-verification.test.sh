#!/usr/bin/env bash
# Fixtures for the Stop gate. A Stop hook that misfires wedges a session, and
# one that never fires is theatre -- both directions are tested here.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/require-verification.py"
T=$(mktemp -d); pass=0; fail=0

# This gate decides whether a turn can END. When it blocks, the reason it prints
# is the only thing telling the agent what to verify -- and the suite checked the
# exit code, printing the reason for a human to eyeball once and never again.
# The snapshot makes every reason a reviewed artifact.
. "$SD/expect.sh"
expect_init "$SD/require-verification.expected"
# Confine git discovery to the fixture repo: an earlier bug walked up to the
# real cwd and wrote this test's fixtures into the kit's own state.
export GIT_CEILING_DIRECTORIES="$(dirname "$T")"
git -C "$T" init -q 2>/dev/null
D="$T/.claude/.verify-state"
# The session index (every repo a session marked) normally lives in ~/.cache.
# A test must not write the real one.
export BENDIT_VERIFY_INDEX="$T/.session-index"
# Claude Code sets this for every hook it runs. A suite started from inside a
# session must not inherit the caller's value; the cases that need it set it.
unset CLAUDE_PROJECT_DIR
# A second repo, OUTSIDE $T, for the cross-repo and no-repo cases.
X=$(mktemp -d)
expect_scrub_dir "$T" '<tmp>'
expect_scrub_dir "$X" '<other>'

mark() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" | python3 "$H" --mark >/dev/null 2>&1; }
# $1 is the label the snapshot files this stop under; it doubles as the chk label.
stop() { expect_capture "${1:-stop}" python3 "$H" \
           <<<"$(printf '{"cwd":"%s","stop_hook_active":%s}' "$T" "${2:-false}")"
         echo "$EXPECT_CODE"; }
stops() { expect_capture "$2" python3 "$H" \
            <<<"$(printf '{"session_id":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$T")"
          echo "$EXPECT_CODE"; }
# want <label> <expected-exit> [stop_hook_active] -- one label, used for both
# the assertion and the snapshot entry.
want()  { chk "$1" "$(stop "$1" "${3:-false}")" "$2"; }
# wants <session-id> <label> <expected-exit>
wants() { chk "$2" "$(stops "$1" "$2")" "$3"; }
chk()  { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
         else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
# stopc <session> <cwd> <label> -- a stop from any cwd, under any session.
stopc() { expect_capture "$3" python3 "$H" \
            <<<"$(printf '{"session_id":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$2")"
          echo "$EXPECT_CODE"; }
# What a stop told the PERSON: the systemMessage of the JSON on stdout, or
# nothing. Exit-0 stderr reaches nobody, so this is the channel that counts.
said() { python3 -c '
import json, sys
try: print(json.loads(sys.stdin.read()).get("systemMessage", ""))
except Exception: print("")' <<<"$1"; }
# Run a stop for its STDOUT only (the person-facing channel).
stdout_of() { python3 "$H" 2>/dev/null <<<"$1"; }

rm -rf "$D"
# These fixtures send no session_id, so the hook files them under
# `nosession` -- one consistent session, which is what this block tests.
want "clean tree -> allowed" 0

mark "$T/src/a.md"
want "edited a .md -> not code, allowed" 0

mark "$T/src/a.ts"
want "edited a .ts -> BLOCKED" 2

sleep 1; mkdir -p "$D"; : > "$D/verified"
want "verified after the edit -> allowed" 0

mark "$T/src/b.ts"
want "edited again after verifying -> BLOCKED" 2

sleep 1; echo "marketing copy only, no runtime path" > "$D/skipped-nosession"
want "skip recorded with a reason -> allowed" 0

mark "$T/src/c.ts"
want "stale skip does not cover a new edit" 2
# Refusing a second time in one turn traps the session in a loop, so the stop is
# allowed. But the docstring promises the gate is never silent, and this path
# was: exit 0, nothing said, nothing recorded -- the one bypass nobody saw.
want "second stop in the same turn -> allowed, not refused twice" 0 true
lt=$(stdout_of "$(printf '{"cwd":"%s","stop_hook_active":true}' "$T")")
chk "... but the PERSON is told the code is NOT verified" \
    "$(said "$lt" | grep -c 'NOT verified')" 1
chk "... naming the file" "$(said "$lt" | grep -c 'src/c.ts')" 1
chk "... and the let-through is recorded" \
    "$([ -s "$D/let-through-nosession" ] && echo recorded || echo missing)" recorded
chk "... and the change is still pending, so the next turn answers for it" \
    "$([ -f "$D/pending-nosession" ] && echo pending || echo cleared)" pending

mark "$T/node_modules/x.ts"
rm -f "$D"/pending-*
mark "$T/node_modules/x.ts"
want "node_modules ignored" 0

# The reason itself is asserted by the snapshot below, not eyeballed here.
mark "$T/src/d.ts"; sleep 1; echo "docs-only change" > "$D/skipped-nosession"
want "skip reason is surfaced, not silent" 0
# ...surfaced WHERE. It went to stderr with exit 0, which reaches nobody.
mark "$T/src/d2.ts"; sleep 1; echo "docs-only change two" > "$D/skipped-nosession"
sk=$(stdout_of "$(printf '{"cwd":"%s","stop_hook_active":false}' "$T")")
chk "the skip reason reaches the PERSON as a systemMessage" \
    "$(said "$sk" | grep -c 'docs-only change two')" 1

# --- what counts as code -------------------------------------------------------
# CODE was the JS/TS family and .sql, so an edit to a Python or shell hook --
# this very gate -- never triggered it.
marks() { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$H" --mark >/dev/null 2>&1; }
for ext in py sh go mts; do
  rm -f "$D"/pending-* "$D"/skipped-* "$D"/verified
  marks "code-$ext" "$T/src/hook.$ext"
  chk "an edited .$ext is code -> BLOCKED" "$(stopc "code-$ext" "$T" "edited a .$ext -> BLOCKED")" 2
done
rm -f "$D"/pending-*

# --- worktrees live under .claude/ ------------------------------------------
# Any path with a `.claude` component was skipped, and Claude Code puts its
# worktrees at <repo>/.claude/worktrees/<name>/ -- so nothing edited in a
# worktree was ever recorded. Only the repo's OWN .claude/ is configuration.
marks "cfg" "$T/.claude/hooks/settings-helper.ts"
chk "CONTROL: the repo's own .claude/ is not code to verify" \
    "$(stopc cfg "$T" "own .claude/ config -> allowed")" 0
WT="$T/.claude/worktrees/wt1"; mkdir -p "$WT/src"; git -C "$WT" init -q 2>/dev/null
marks "wt" "$WT/src/in-worktree.ts"
chk "an edit INSIDE a .claude/worktrees/ checkout is recorded -> BLOCKED" \
    "$(stopc wt "$WT" "edit in a Claude Code worktree -> blocked")" 2
rm -rf "$WT"

# --- another repo -------------------------------------------------------------
# Marks are written under the EDITED file's repo; Stop read only the cwd's. An
# edit in a sibling repo was recorded and then never checked.
git -C "$X" init -q 2>/dev/null
marks "xr" "$X/src/far.ts"
chk "an edit in ANOTHER repo is checked at Stop -> BLOCKED" \
    "$(stopc xr "$T" "edit in another repo -> blocked")" 2
sleep 1; mkdir -p "$T/.claude/.verify-state"; echo "other repo is docs" > "$T/.claude/.verify-state/skipped-xr"
chk "... and the skip under the cwd's repo covers it (the path the agent can reach)" \
    "$(stopc xr "$T" "other repo, skip under cwd -> allowed")" 0
rm -rf "$X/.claude" "$X/.git"
echo
echo "  SESSION SCOPE -- a turn answers only for its own session's edits"
# An old edit from ANOTHER session must not block this one, nor be blamed on it.
marks() { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$H" --mark >/dev/null 2>&1; }

rm -f "$D"/pending* "$D"/skipped* "$D"/verified 2>/dev/null
marks "sess-A" "$T/src/x.ts"
wants sess-B "THE BUG: session B is not blocked by A's edit" 0
wants sess-A "control: session A IS blocked by its own edit" 2

sleep 1; echo "A's reason" > "$D/skipped-sess-A"
wants sess-A "A's skip clears A" 0
marks "sess-B" "$T/src/y.ts"
wants sess-B "A's skip does NOT clear B" 2

# verify.sh has no session id, so `verified` stays global on purpose: the
# harness passing is a fact about the REPO, not about who ran it.
sleep 1; : > "$D/verified"
wants sess-B "global verified (verify.sh) still clears B" 0

# A pre-session-scope `pending` left by an older build belongs to no session.
rm -f "$D"/pending* "$D"/skipped* "$D"/verified 2>/dev/null
printf 'src/legacy.ts\n' > "$D/pending"
wants sess-C "legacy unscoped pending blocks nobody" 0

# Stale state from a session that ended long ago must not accumulate forever.
marks "sess-OLD" "$T/src/z.ts"
touch -t 202001010000 "$D/pending-sess-OLD"
: > "$D/pending-sess-NEW"; printf 'src/z.ts\n' > "$D/pending-sess-NEW"
wants sess-NEW "stale state is pruned, fresh state is kept" 2
if [ -f "$D/pending-sess-OLD" ]; then
  printf '  FAIL  stale file was not pruned\n'; fail=$((fail+1))
else
  printf '  ok    stale file was pruned\n'; pass=$((pass+1))
fi
rm -f "$D"/pending* "$D"/skipped* "$D"/verified 2>/dev/null

# --- the escape hatch must be writable by the AGENT, not just by the hook ----
# This hook runs unsandboxed and takes `root` from git, which can sit ABOVE the
# agent's workspace; the agent's tools may reach only cwd and below. Inside a
# sandbox that git-inits the workspace's parent, root resolves one level above
# the workspace, the hook writes `pending` there, and the skip file the message
# tells the agent to create is denied every time. A gate whose escape the
# subject cannot reach is a gate with no escape, which the docstring forbids.
W="$T/workspace"; mkdir -p "$W/src"
# Same payload shape as stop(), but cwd is the workspace BELOW the git root.
stopw() { expect_capture "$1" python3 "$H" \
            <<<"$(printf '{"cwd":"%s","stop_hook_active":false}' "$W")"
          echo "$EXPECT_CODE"; }
wantw() { chk "$1" "$(stopw "$1")" "$2"; }

rm -rf "$D" "$W/.claude"
mark "$T/src/deep.ts"
wantw "workspace below root, nothing recorded -> BLOCKED" 2

sleep 1
mkdir -p "$W/.claude/.verify-state"
echo "docs-only change, no runtime path" > "$W/.claude/.verify-state/skipped-nosession"
wantw "skip written INSIDE the workspace -> allowed" 0

# And the root location still works, so nothing that already escaped breaks.
rm -rf "$D" "$W/.claude"
mark "$T/src/deep2.ts"
sleep 1; mkdir -p "$D"; echo "recorded at the repo root" > "$D/skipped-nosession"
wantw "skip at the repo root still honoured -> allowed" 0
rm -rf "$D" "$W/.claude"

# --- the payload's `cwd` is the SHELL's cwd, and the shell wanders -----------
# An agent that `cd`s into a subfolder (say, a harness's artifacts/ to read a
# verdict) and ends its turn there was told to write
# artifacts/.claude/.verify-state/skipped-<sid> -- a directory that does not
# exist, inside the harness's evidence tree. The launch directory
# (CLAUDE_PROJECT_DIR) is what the agent can always write, and it does not move.
A="$T/sub/artifacts"; mkdir -p "$A"
# Called WITHOUT $(...) so EXPECT_CODE/EXPECT_STDERR survive for the asserts.
stopp() { CLAUDE_PROJECT_DIR="$1" expect_capture "$2" python3 "$H" \
            <<<"$(printf '{"cwd":"%s","stop_hook_active":false}' "$A")"; }
names() { case "$EXPECT_STDERR" in *"> $1"*) chk "$2" ok ok ;; *) chk "$2" "$EXPECT_STDERR" "a path of $1" ;; esac; }
mark "$T/src/wander.ts"
stopp "$T" 'shell in subdir, project dir at root -> blocked, names root path'
chk "shell cd-ed into a subdir, project dir is root -> BLOCKED" "$EXPECT_CODE" 2
names "$D/skipped-nosession" "... and the skip path it names is under the project dir, not the shell's cwd"
sleep 1; mkdir -p "$D"; echo "lint script only" > "$D/skipped-nosession"
stopp "$T" 'shell in subdir, skip at project dir -> allowed'
chk "... and a skip at that named path is honoured" "$EXPECT_CODE" 0
# The sandboxed workspace case above must not regress when the env IS set:
# there the launch directory is the workspace, below the git root.
rm -rf "$D" "$W/.claude"
mark "$T/src/deep3.ts"
CLAUDE_PROJECT_DIR="$W" expect_capture 'workspace is the project dir -> blocked' python3 "$H" \
  <<<"$(printf '{"cwd":"%s","stop_hook_active":false}' "$W")"
chk "workspace is the project dir -> BLOCKED" "$EXPECT_CODE" 2
names "$W/.claude/.verify-state/skipped-nosession" "... and names the workspace path"
rm -rf "$D" "$W/.claude" "$T/sub"

# --- THE SHELL EDITS TOO -----------------------------------------------------
# Edit/Write/MultiEdit name their file; a Bash command names nothing. A shell
# loop that rewrites hundreds of tracked files would mark nothing, and the gate
# would demand nothing -- blind to the path many edits take, and looking
# exactly like a gate that had passed.
# The payload shape is NOT invented here: `changedFiles` is nested inside
# `bashEditDiff`, per Claude Code's own type declarations. Reading it one
# level too high, with a fixture built the same wrong way, passes here while a
# live session marks nothing. A fixture that encodes your assumption only ever
# tests your assumption.
bashmark() { printf '{"session_id":"nosession","tool_name":"Bash","tool_response":{"bashEditDiff":{"files":[],"moreFiles":0,"changedFiles":[%s]}}}' "$1" \
             | python3 "$H" --mark >/dev/null 2>&1; }
# `changedFiles` is cut when short, so the per-file diffs are the other source.
filesmark() { printf '{"session_id":"nosession","tool_name":"Bash","tool_response":{"bashEditDiff":{"files":[{"filePath":%s,"hunks":[]}],"moreFiles":0}}}' "$1" \
             | python3 "$H" --mark >/dev/null 2>&1; }
q() { python3 -c 'import json,sys;print(",".join(json.dumps(a) for a in sys.argv[1:]))' "$@"; }
# The shell WROTE these files, so they exist. These fixtures used to name files
# that were never created, and passed only because the git-moved filter crashed
# on the missing directory and kept everything -- a fixture that is not the
# situation it names. A file the command reported but that is not on disk and
# not in `git status` has nothing left to verify.
mkdir -p "$T/src"
for f in shell1 viafiles m1 m2 m3; do printf 'export {};\n' > "$T/src/$f.ts"; done

rm -rf "$D" "$W/.claude"
bashmark "$(q "$T/src/shell1.ts")"
want "a shell edit is marked, so the turn is BLOCKED" 2

sleep 1; mkdir -p "$D"; : > "$D/verified"
want "and verifying it clears the block" 0

# Not everything a command touches is code.
rm -rf "$D"
bashmark "$(q "$T/README.md" "$T/notes.txt")"
want "a shell touching only non-code is not blocked" 0

# node_modules and friends are excluded on this path too, not just the Edit one.
rm -rf "$D"
bashmark "$(q "$T/node_modules/pkg/index.ts" "$T/dist/out.js")"
want "a shell touching only build output is not blocked" 0

# The flat shape is NOT what the engine sends. If this ever starts marking,
# someone has widened the reader and the nesting no longer means anything.
rm -rf "$D"
printf '{"session_id":"nosession","tool_name":"Bash","tool_response":{"changedFiles":["%s"]}}' "$T/src/flat.ts" \
  | python3 "$H" --mark >/dev/null 2>&1
want "the flat (wrong) shape marks nothing" 0

# When changedFiles is absent, the rendered per-file diffs still name the files.
rm -rf "$D"
filesmark "\"$T/src/viafiles.ts\""
want "bashEditDiff.files alone is enough to mark" 2

# Several files in one command all land on the pending list.
rm -rf "$D"
bashmark "$(q "$T/src/m1.ts" "$T/src/m2.ts" "$T/src/m3.ts")"
chk "all three shell-edited files are recorded" \
    "$(grep -c . "$D/pending-nosession" 2>/dev/null || echo 0)" "3"

# The Bash tool reports up to 200 files. The list kept only the LAST 40, so a
# big command forgot most of what it changed, and marking cost one git call
# per file (3.6s for 200, inside a 10s hook timeout).
rm -rf "$D"
many=(); for i in $(seq 1 200); do many+=("$T/src/many/f$i.ts"); done
mkdir -p "$T/src/many"; for f in "${many[@]}"; do : > "$f"; done
t0=$(python3 -c 'import time;print(time.time())')
bashmark "$(q "${many[@]}")"
t1=$(python3 -c 'import time;print(time.time())')
chk "all 200 shell-edited files are recorded, not the last 40" \
    "$(grep -c . "$D/pending-nosession" 2>/dev/null || echo 0)" "200"
chk "and marking 200 files takes well under the 10s hook timeout (<2s)" \
    "$(python3 -c "import sys;print('fast' if $t1-$t0 < 2 else 'slow: %.1fs' % ($t1-$t0))")" fast
rm -rf "$T/src/many"
rm -rf "$D" "$W/.claude"

# --- A REPO MAY DECLARE WHAT VERIFIES IT ------------------------------------
# The gate looks for a verify-* skill, which is right for an app. For a plugin
# or a library there is no app to drive, the suites ARE the harness, and the
# question had a permanent answer -- so the same skip note got written turn
# after turn. A gate whose answer never changes stops being read.
#
# `.claude/verify-harness` holds a command, and the gate RUNS it. A skip note is
# a claim; an exit code is evidence.
HARNESS="$T/.claude/verify-harness"
declare_harness() { mkdir -p "$T/.claude"; printf '%s' "$1" > "$HARNESS"; }

rm -rf "$D" "$W/.claude"; rm -f "$HARNESS"
mark "$T/src/declared.ts"
declare_harness 'true'
want "a declared harness that PASSES ends the turn" 0
chk "and it clears pending, so the next turn is quiet" \
    "$([ -f "$D/pending-nosession" ] && echo present || echo cleared)" "cleared"
mark "$T/src/declared1b.ts"
vb=$(stdout_of "$(printf '{"cwd":"%s","stop_hook_active":false}' "$T")")
chk "and the PERSON is told which command verified it (systemMessage)" \
    "$(said "$vb" | grep -c "declared harness: true")" 1

# THE GATE MUST BE ABLE TO FINISH. A Stop timeout in hooks.json shorter than the
# gate's own harness budget means the engine kills the hook before either
# finishes, and the gate can never complete. The gate's budget must sit BELOW
# the engine's timeout, so that a slow harness is reported by the gate as a
# refusal instead of the hook being killed mid-run.
stop_to=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]["Stop"]
print(max(x.get("timeout", 0) for e in h for x in e["hooks"] if "require-verification" in x["command"]))' "$SD/../hooks/hooks.json")
gate_to=$(python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("rv", sys.argv[1]); m = importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(m.HARNESS_TIMEOUT)' "$H")
chk "hooks.json's Stop timeout outlasts the gate's harness budget by >=30s" \
    "$([ "${stop_to:-0}" -ge $((gate_to + 30)) ] && echo ordered || echo "stop=$stop_to gate=$gate_to")" ordered

# A harness that outruns its budget is a REFUSAL -- and the gate must actually
# return. `subprocess.run(shell=True, timeout=)` killed only the shell; the
# suite's own children held the output pipe open and run() waited for them.
rm -rf "$D"; mark "$T/src/slow.ts"
declare_harness 'sleep 30; true'
s0=$SECONDS
export BENDIT_HARNESS_TIMEOUT=2
want "a harness that outruns its budget is refused" 2
unset BENDIT_HARNESS_TIMEOUT
chk "... and the gate returns promptly, not when the orphaned child exits" \
    "$([ $((SECONDS - s0)) -lt 15 ] && echo prompt || echo "took $((SECONDS - s0))s")" prompt

rm -rf "$D"; mark "$T/src/declared2.ts"
declare_harness 'echo "3 failed" >&2; exit 1'
want "a declared harness that FAILS blocks" 2

# An empty declaration is a misconfiguration, not a pass. A harness that cannot
# run must never be the reason a turn was allowed to end.
rm -rf "$D"; mark "$T/src/declared3.ts"
declare_harness ''
want "an EMPTY declaration blocks, it is not a pass" 2

# A command that cannot run is a refusal too. `exit 127` rather than a missing
# binary: under shell=True a missing binary IS just exit 127 from the shell, so
# the OSError branch is effectively unreachable and naming a path only bought
# platform-specific stderr -- macOS says "No such file or directory", Linux says
# "not found", and the snapshot could not match on both. Only CI on a second
# platform can find that.
rm -rf "$D"; mark "$T/src/declared4.ts"
declare_harness 'exit 127'
want "a harness exiting 127 blocks, like any non-zero" 2

# CONTROL: with no declaration the old behaviour is untouched, so every repo
# that has not opted in keeps working exactly as before.
rm -f "$HARNESS"
rm -rf "$D"; mark "$T/src/declared5.ts"
want "CONTROL: no declaration -> asks for a verify-* skill as before" 2
rm -rf "$D" "$W/.claude"

echo
echo "  CRASHES AND MALFORMED PAYLOADS -- the gate fails CLOSED"
# --mark with a payload of the wrong shape names no file: nothing to record,
# and no traceback (exit 1 would be an unreported, non-blocking error).
mk() { printf '%s' "$1" | python3 "$H" --mark >/dev/null 2>&1; echo $?; }
chk "--mark: payload is a list"            "$(mk '[1,2]')" 0
chk "--mark: tool_input is a string"       "$(mk '{"tool_input":"x"}')" 0
chk "--mark: tool_response is a string"    "$(mk '{"tool_name":"Bash","tool_response":"x"}')" 0
chk "--mark: bashEditDiff is a list"       "$(mk '{"tool_name":"Bash","tool_response":{"bashEditDiff":[1]}}')" 0
# A crash is forced by replacing an inner function with one that raises.
crashrv() { # <mode: mark|stop> <stop_hook_active> -> "<stderr-and-stdout> exit=N"
  printf '{"cwd":"%s","stop_hook_active":%s,"tool_input":{"file_path":"%s/src/c.ts"}}' "$T" "$2" "$T" \
  | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
def boom(*_a, **_k): raise RuntimeError("synthetic")
gate._judge = boom; gate.edited = boom
sys.exit(gate.run(["--mark"] if sys.argv[2] == "mark" else []))' "$H" "$1" 2>&1
  echo "exit=$?"
}
rm -rf "$D"; mark "$T/src/crash.ts"
case "$(crashrv stop false)" in
  *"gate itself failed"*"exit=2") printf '  ok    %s\n' "a crash in the Stop gate REFUSES the stop"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash in the Stop gate REFUSES the stop" "$(crashrv stop false | tail -2)"; fail=$((fail+1));;
esac
case "$(crashrv stop true)" in
  *systemMessage*"gate itself failed"*"exit=0") printf '  ok    %s\n' "...but not twice in a turn: the person is told instead"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "...but not twice in a turn: the person is told instead" "$(crashrv stop true | tail -2)"; fail=$((fail+1));;
esac
case "$(crashrv mark false)" in
  *"could not record this edit"*"exit=2") printf '  ok    %s\n' "a crash in --mark is said, exit 2"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash in --mark is said, exit 2" "$(crashrv mark false | tail -2)"; fail=$((fail+1));;
esac
# An unreadable Stop payload is not a pass: the gate still judges the cwd repo.
rm -rf "$D"; mark "$T/src/junk.ts"
chk "a Stop payload that is not JSON still judges the cwd repo" \
    "$(cd "$T" && printf 'not json' | python3 "$H" >/dev/null 2>&1; echo $?)" 2
rm -rf "$D"

echo
echo "WHAT IT SAYS (snapshot)"
# --- git moved it, the agent did not -----------------------------------------
# The shape: ONE Bash call runs
#   git stash push -m ... && git checkout release && git pull
# and a naive Stop hook blocks with "You changed code in <repo> and nothing has
# verified it", listing every file the branch switch and the pull brought in.
# The agent edited none of them. Claude Code itself annotates such a call: "a
# git step in this command can move the working tree, so these may be its
# changes, not edits".
#
# A file a checkout or pull brought in is CLEAN against the new HEAD. A file the
# agent edited is not. That is the whole discriminator -- but it must not open a
# false negative, because `git stash pop`, `git apply`, `git checkout <ref> --
# <file>` and `git restore --source` all bring back REAL uncommitted work.
G="$T/gitaware"; mkdir -p "$G/src"
git -C "$G" init -q 2>/dev/null
git -C "$G" config user.email t@t; git -C "$G" config user.name t
printf 'export const a = 1;\n' > "$G/src/clean.ts"
printf 'export const b = 1;\n' > "$G/src/dirty.ts"
printf 'export const o = 1;\n' > "$G/src/other.ts"
printf 'gen/\n' > "$G/.gitignore"
git -C "$G" add -A >/dev/null 2>&1
# BACKDATED. A checkout or a pull brings in commits made elsewhere, earlier;
# the gate now keeps a clean file whose commit is RECENT (the same command
# edited and committed it). A fixture committed a second ago would be read as
# exactly that, so the "git moved it" fixture must look like what it stands for.
GIT_AUTHOR_DATE=2026-01-01T00:00:00 GIT_COMMITTER_DATE=2026-01-01T00:00:00 \
  git -C "$G" commit -qm init >/dev/null 2>&1

gstop() { expect_capture "$1" python3 "$H" \
            <<<"$(printf '{"session_id":"git-%s","cwd":"%s","stop_hook_active":false}' "$2" "$G")"
          echo "$EXPECT_CODE"; }
gmark() { printf '{"session_id":"git-%s","tool_name":"Bash","tool_response":{"bashEditDiff":{"files":[],"moreFiles":0,"changedFiles":[%s]}}}' "$1" "$2" \
          | python3 "$H" --mark >/dev/null 2>&1; }
rm -rf "$G/.claude"

echo
echo "GIT MOVED IT, THE AGENT DID NOT"
# A tracked file that matches HEAD was not edited by the agent -- a checkout or
# a pull put it there.
gmark a "$(q "$G/src/clean.ts")"
chk "a file CLEAN against HEAD does not demand verification" "$(gstop 'clean against HEAD -> allowed' a)" "0"

# CONTROLS. Without these the filter could be dropping everything, which is a
# gate that never fires -- the exact failure this hook was written to end.
printf 'export const b = 2;  // edited\n' > "$G/src/dirty.ts"
gmark b "$(q "$G/src/dirty.ts")"
chk "CONTROL: a MODIFIED file still demands verification" "$(gstop 'dirty against HEAD -> blocked' b)" "2"

printf 'export const c = 3;\n' > "$G/src/brand-new.ts"
gmark c "$(q "$G/src/brand-new.ts")"
chk "CONTROL: an UNTRACKED new file still demands verification" "$(gstop 'untracked -> blocked' c)" "2"

# The four shapes named in the report: each leaves REAL uncommitted work, so
# each must still be verified. `stash pop` is the one that would hurt most if
# dropped -- it restores exactly the edits a branch switch was parked for.
git -C "$G" stash push -q -m t -- src/dirty.ts >/dev/null 2>&1
git -C "$G" stash pop -q >/dev/null 2>&1
gmark d "$(q "$G/src/dirty.ts")"
chk "CONTROL: after git stash pop it is still demanded" "$(gstop 'stash pop -> blocked' d)" "2"

# Edited AND committed in one command (`sed -i … && git commit -am …`): the file
# is clean against the new HEAD, which is exactly what a checkout looks like --
# and it was dropped. A change committed in the same command is still an
# unverified change.
printf 'export const a = 2;  // edited, then committed\n' > "$G/src/clean.ts"
git -C "$G" commit -qam 'same command' >/dev/null 2>&1
gmark f "$(q "$G/src/clean.ts")"
chk "edited and committed in ONE command is still demanded" "$(gstop 'commit -am in the same command -> blocked' f)" "2"

# A gitignored file never appears in `git status`, so it looked clean and was
# dropped. No checkout or pull writes an ignored file: the command did.
mkdir -p "$G/gen"; printf 'export const g = 1;\n' > "$G/gen/out.ts"
gmark g "$(q "$G/gen/out.ts")"
chk "a gitignored code file the shell wrote is still demanded" "$(gstop 'gitignored -> blocked' g)" "2"

# When git cannot answer, nothing may be dropped. The old case for this ran in
# $T/nogit -- INSIDE $T, which is a git repo, so it exercised the ordinary
# untracked-file branch and passed for the wrong reason. Here git really fails:
# a shim makes `git status` exit 128 while every other git call is real.
SHIM="$T/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = status ] && exit 128; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
PATH="$SHIM:$PATH" gmark h "$(q "$G/src/other.ts")"
chk "when git status FAILS, a clean file is kept (fails closed)" "$(gstop 'git status fails -> blocked' h)" "2"
# CONTROL for the shim: the same clean file, git working, is dropped.
gmark h2 "$(q "$G/src/other.ts")"
chk "CONTROL: with git working, that clean file is dropped" "$(gstop 'same file, git working -> allowed' h2)" "0"

# Outside every repo the filter cannot ask git anything, so it keeps the file.
# (Marking then has no repo to hold state in, so such a file is not gated; that
# is _place's rule, not this filter's.) $X is outside $T and outside any repo.
mkdir -p "$X/src"; printf 'x\n' > "$X/src/loose.ts"
kept=$(python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("rv", sys.argv[1]); m = importlib.util.module_from_spec(s)
s.loader.exec_module(m); print(len(m.only_dirty([sys.argv[2]])))' "$H" "$X/src/loose.ts")
chk "outside any git repo the git-moved filter keeps the file" "$kept" "1"

# An Edit/Write names its file outright. That is the agent editing, whatever
# git thinks afterwards, so it is never filtered.
git -C "$G" checkout -q -- src/dirty.ts 2>/dev/null
printf '{"session_id":"git-e","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$G/src/clean.ts" \
  | python3 "$H" --mark >/dev/null 2>&1
estop() { expect_capture "$1" python3 "$H" \
            <<<"$(printf '{"session_id":"git-e","cwd":"%s","stop_hook_active":false}' "$G")"
          echo "$EXPECT_CODE"; }
chk "an Edit of a clean file is NOT filtered" "$(estop 'Edit of clean file -> blocked')" "2"

expect_verify || fail=$((fail+1))

rm -rf "$T" "$X"
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
