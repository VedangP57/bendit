#!/usr/bin/env bash
# prove.sh is the check /adopt reports from, so it is held to the rule it
# enforces: seen to fail. Each case below breaks one thing in a COPY of the
# plugin or in a scratch repo -- a guard that waves everything through, a guard
# that refuses under another kit's name, a Stop gate that never refuses, a hook
# nobody wrote a probe for, a red harness -- and prove.sh must exit non-zero
# and name it. The table it prints is the snapshot (prove.expected).
#
# It must also write NOTHING inside the repo it proves: the adopt session that
# improvised these checks left a pending marker in the project, behind a
# permission wall it could not clear. That is asserted on every file, .git
# included.
#
#   bash prove.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

. "$SD/expect.sh"
expect_init "$SD/prove.expected"
expect_scrub_dir "$T" '<tmp>'
expect_scrub "$KIT" '<kit>'

# repo <dir> <harness-body or ""> [unapproved] -- a committed scratch project.
# BENDIT_JSON, if set, is the body of its .claude/bendit.json.
repo() {
  mkdir -p "$1"; git -C "$1" init -q
  printf 'x = 1\n' > "$1/app.py"; printf '# rules\n' > "$1/AGENTS.md"
  if [ -n "$2" ]; then mkdir -p "$1/.claude"; printf '# what verifies this repo\n%s\n' "$2" > "$1/.claude/verify-harness"; fi
  if [ -n "${BENDIT_JSON:-}" ]; then mkdir -p "$1/.claude"; printf '%s\n' "$BENDIT_JSON" > "$1/.claude/bendit.json"; fi
  git -C "$1" add -A && git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm init
  # A test repo's harness is approved, in a THROWAWAY approval list (below), so
  # each case tests what it names. "unapproved" opts out to test that row.
  [ -n "$2" ] && [ "${3:-}" != unapproved ] && approve "$1"
  return 0
}
# The person's approval list, redirected so no test reads or writes the real one.
export BENDIT_CONFIG_DIR="$T/trust"
approve() { python3 - "$KIT/scripts/require-verification.py" "$1" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("rv", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.trust_add(pathlib.Path(sys.argv[2]))
PY
}
# kitcopy <dir> -- a copy of this plugin to break one thing in
kitcopy() { mkdir -p "$1"; cp -R "$KIT/." "$1/"; rm -rf "$1/scripts/__pycache__"; }
# A tmp dir of prove.sh's own, so "it cleaned up" is checkable.
export TMPDIR="$T/tmpd"; mkdir -p "$TMPDIR"

echo "A WORKING KIT, A GREEN REPO"
G="$T/good"; repo "$G" 'exit 0'
# Every path under the repo, .git included, with its size and mtime in ns.
snap() { python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    for n in sorted(dirs + files):
        p = os.path.join(d, n); st = os.lstat(p)
        print(os.path.relpath(p, root), st.st_size, st.st_mtime_ns)
PY
}
# GIT_OPTIONAL_LOCKS=0: this test's own `git status` must not refresh .git/index
# either, or it would write the very file it is checking nobody wrote.
gst() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain --ignored; }
gst "$G" >/dev/null; before=$(gst "$G"; snap "$G"); touch "$T/marker"; sleep 1
expect_capture "green repo, working kit" bash "$SD/prove.sh" "$G"
chk "exit 0 when every check passed" "$EXPECT_CODE" "0"
has "  ...and says so" "passed" "$EXPECT_STDOUT"
newer=$(/usr/bin/find "$G" -newer "$T/marker" | head -3)
after=$(gst "$G"; snap "$G")
chk "NOTHING inside the repo changed (status, listing, sizes, mtimes)" "$([ "$before" = "$after" ] && echo same || echo changed)" same
chk "  ...and no file in it (.git included) is newer than the run's start" "$newer" ""
chk "prove.sh's temp dir is gone (trap cleanup)" "$(/bin/ls -A "$TMPDIR")" ""
# The guards must be fed from the plugin under test, not from the one on PATH.
has "every hook in hooks.json was probed: block-dangerous-bash" "block-dangerous-bash" "$EXPECT_STDOUT"
has "  ...warn-suppressed-stderr" "warn-suppressed-stderr" "$EXPECT_STDOUT"
has "  ...post-edit-review --pre" "post-edit-review --pre" "$EXPECT_STDOUT"

echo
echo "A RED HARNESS"
R="$T/red"; repo "$R" 'echo "2 tests failed" >&2; exit 1'
expect_capture "red harness" bash "$SD/prove.sh" "$R"
chk "a failing harness fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...naming the harness's own output" "2 tests failed" "$EXPECT_STDOUT"

echo
echo "NO HARNESS"
N="$T/none"; repo "$N" ''
expect_capture "no harness" bash "$SD/prove.sh" "$N"
chk "no .claude/verify-harness is a failure, not a skip" "$EXPECT_CODE" "1"

echo
echo "A HARNESS THE PERSON HAS NOT APPROVED"
# The Stop gate refuses to run an unapproved harness, so adoption is not done
# until the person approves it -- in their own terminal, never via the agent.
U="$T/unapproved"; repo "$U" 'exit 0' unapproved
expect_capture "unapproved harness" bash "$SD/prove.sh" "$U"
chk "an unapproved harness fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...on the approval row" "harness: approved by you for the Stop gate" "$EXPECT_STDOUT"
has "  ...giving the person the exact command" "--trust" "$EXPECT_STDOUT"
has "  ...and saying it is theirs to run" "YOUR OWN terminal" "$EXPECT_STDOUT"
approve "$U"
expect_capture "approved harness" bash "$SD/prove.sh" "$U"
chk "CONTROL: once approved, the same repo passes (exit 0)" "$EXPECT_CODE" "0"
printf 'exit 0 # edited\n' >> "$U/.claude/verify-harness"
expect_capture "harness changed after approval" bash "$SD/prove.sh" "$U"
chk "a harness changed after approval fails again (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying it changed" "changed since you approved it" "$EXPECT_STDOUT"

echo
echo "PER-PROJECT FEATURES"
expect_capture "no bendit.json" bash "$SD/prove.sh" "$G"
chk "no bendit.json: exit 0 (UNUSED is not a failure)" "$EXPECT_CODE" "0"
chk "  ...four features read UNUSED" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -c '^feature: .*| UNUSED ')" "4"
has "  ...saying why" "UNUSED  not set up by /adopt yet" "$EXPECT_STDOUT"
has "  ...and the summary counts them" "checks passed (4 unused)" "$EXPECT_STDOUT"
has "  ...readable row passes" "features: .claude/bendit.json readable" "$EXPECT_STDOUT"

BENDIT_JSON='{"version":1,"features":{"browser-driver":{"on":false,"why":"you declined Chrome"}}}'
F1="$T/feat-off"; repo "$F1" 'exit 0'
expect_capture "feature declined" bash "$SD/prove.sh" "$F1"
chk "a declined feature is UNUSED with its reason, exit 0" "$EXPECT_CODE" "0"
has "  ...the reason is shown" "UNUSED  you declined Chrome" "$EXPECT_STDOUT"

BENDIT_JSON='{"version":1,"features":{"browser-driver":{"on":true,"why":"Chrome"}}}'
F2="$T/feat-nocheck"; repo "$F2" 'exit 0'
expect_capture "browser-driver on, no registered check" bash "$SD/prove.sh" "$F2"
chk "an ON feature with no registered check fails prove" "$EXPECT_CODE" "1"
has "  ...naming it" "no check for browser-driver" "$EXPECT_STDOUT"

BENDIT_JSON='{"version":1,"features":{"ls-guard":{"on":true,"why":"ls is a formatter"}}}'
F2b="$T/feat-ls"; repo "$F2b" 'exit 0'
expect_capture "ls-guard on" bash "$SD/prove.sh" "$F2b"
chk "ls-guard on: the check runs the hook and prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: ls-guard +\| PASS ')" "1"

BENDIT_JSON='{"version":1,'
F3="$T/feat-bad"; repo "$F3" 'exit 0'
expect_capture "malformed bendit.json" bash "$SD/prove.sh" "$F3"
chk "a malformed bendit.json fails prove" "$EXPECT_CODE" "1"
has "  ...on the readable row" "features: .claude/bendit.json readable" "$EXPECT_STDOUT"

# ux-design-laws: ON means the add-on is installed for THIS project. The check
# asks `claude plugin list --json`; here `claude` is a stub on PATH that prints
# fixture JSON (the real fields: id, scope, enabled, projectPath).
BENDIT_JSON='{"version":1,"features":{"ux-design-laws":{"on":true,"why":"a web app"}}}'
UX="$T/feat-ux"; repo "$UX" 'exit 0'; UXREAL=$(cd "$UX" && pwd -P)
unset BENDIT_JSON
STUB="$T/stub"; mkdir -p "$STUB"
# stub <json-file | ERROR> -- a `claude` that prints the file, or fails.
stub() {
  if [ "$1" = ERROR ]; then printf '#!/bin/sh\necho "boom: not logged in" >&2\nexit 1\n' > "$STUB/claude"
  else # Like the real CLI, the answer depends on the cwd: from anywhere but the
  # project root it lists nothing, so a check run from elsewhere cannot pass.
  printf '#!/bin/sh\n[ "$(pwd -P)" = "%s" ] || { echo "[]"; exit 0; }\ncat "%s"\n' "$UXREAL" "$1" > "$STUB/claude"; fi
  chmod +x "$STUB/claude"
}
with_stub() { PATH="$STUB:$PATH" expect_capture "$@"; }
# Every fixture carries both fields, as the real CLI emits them: `enabled` is
# true for any installed entry; `projectEnabled` is the per-project signal.
ux_json() { printf '[{"id":"bendit-web@bendit","scope":"%s","enabled":%s,"projectEnabled":%s,"projectPath":"%s"}]\n' "$1" "$2" "$3" "$4"; }
ux_json project true true "$UXREAL/" > "$T/ux-match.json"
ux_json project true true "$T/elsewhere" > "$T/ux-other.json"
printf '[{"id":"bendit-web@bendit","scope":"user","enabled":true,"projectEnabled":false}]\n' > "$T/ux-user.json"
ux_json project true false "$UXREAL" > "$T/ux-disabled.json"
stub "$T/ux-match.json"
with_stub "ux-design-laws installed here" bash "$SD/prove.sh" "$UX"
chk "ux-design-laws: add-on enabled at project scope for this repo passes (exit 0)" "$EXPECT_CODE" "0"
has "  ...on its own feature row, as PASS" "feature: ux-design-laws" "$EXPECT_STDOUT"
chk "  ...with no failure listed" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -c '^failures:')" "0"
stub "$T/ux-other.json"
with_stub "ux-design-laws installed for another project" bash "$SD/prove.sh" "$UX"
chk "a project-scope entry for a DIFFERENT project fails (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying it is not installed here" "bendit-web is not installed here" "$EXPECT_STDOUT"
stub "$T/ux-user.json"
with_stub "ux-design-laws user scope only" bash "$SD/prove.sh" "$UX"
chk "user scope alone fails: it does not prove THIS project has it (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying user scope only" "installed at user scope only" "$EXPECT_STDOUT"
stub "$T/ux-disabled.json"
with_stub "ux-design-laws installed but disabled" bash "$SD/prove.sh" "$UX"
chk "installed (enabled) but projectEnabled false fails (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying disabled" "installed for this project but disabled" "$EXPECT_STDOUT"
stub ERROR
with_stub "claude plugin list errors" bash "$SD/prove.sh" "$UX"
chk "a claude CLI error fails (exit 1), never passes by silence" "$EXPECT_CODE" "1"
has "  ...saying it could not check" "could not check (claude plugin list failed:" "$EXPECT_STDOUT"
printf 'not json\n' > "$T/ux-junk.json"; stub "$T/ux-junk.json"
with_stub "claude plugin list prints junk" bash "$SD/prove.sh" "$UX"
chk "unparseable output fails (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying it could not check" "could not check" "$EXPECT_STDOUT"
unset BENDIT_JSON

echo
echo "A BROKEN GUARD"
K1="$T/kit-open"; kitcopy "$K1"
printf 'import sys\nsys.exit(0)\n' > "$K1/scripts/block-dangerous-bash.py"
expect_capture "block-dangerous-bash replaced by exit 0" bash "$K1/scripts/prove.sh" "$G"
chk "a guard that allows everything fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...naming that guard" "block-dangerous-bash: refuses" "$EXPECT_STDOUT"

K2="$T/kit-anon"; kitcopy "$K2"
sed -i.bak 's/\[bendit\]/[some-kit]/' "$K2/scripts/path-contracts.py"
expect_capture "path-contracts refuses under another name" bash "$K2/scripts/prove.sh" "$G"
chk "a refusal that does not name bendit fails prove" "$EXPECT_CODE" "1"
has "  ...saying why" "does not name bendit" "$EXPECT_STDOUT"

K3="$T/kit-nostop"; kitcopy "$K3"
printf 'import sys\nsys.exit(0)\n' > "$K3/scripts/require-verification.py"
expect_capture "Stop gate that never refuses" bash "$K3/scripts/prove.sh" "$G"
chk "a Stop gate that lets a red harness through fails prove" "$EXPECT_CODE" "1"

K4="$T/kit-unprobed"; kitcopy "$K4"
python3 - "$K4/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['hooks']['PreToolUse'][0]['hooks'].append(
    {'type': 'command', 'command': 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/new-guard-nobody-probed.py"', 'timeout': 10})
json.dump(d, open(p, 'w'), indent=2)
PY
expect_capture "a hook prove.sh has no probe for" bash "$K4/scripts/prove.sh" "$G"
chk "a hook with no probe fails prove: it cannot vouch for what it never fed" "$EXPECT_CODE" "1"
chk "every broken-kit run cleaned up after itself" "$(/bin/ls -A "$TMPDIR")" ""

echo
echo "USAGE"
expect_capture "no argument" bash "$SD/prove.sh"
chk "no repo argument -> exit 2" "$EXPECT_CODE" "2"
mkdir -p "$T/plain"
expect_capture "not a git repo" bash "$SD/prove.sh" "$T/plain"
chk "a folder outside git -> exit 2" "$EXPECT_CODE" "2"

expect_verify || fail=$((fail+1))
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
