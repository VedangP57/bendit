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

# repo <dir> <harness-body or ""> -- a committed scratch project
repo() {
  mkdir -p "$1"; git -C "$1" init -q
  printf 'x = 1\n' > "$1/app.py"; printf '# rules\n' > "$1/AGENTS.md"
  if [ -n "$2" ]; then mkdir -p "$1/.claude"; printf '# what verifies this repo\n%s\n' "$2" > "$1/.claude/verify-harness"; fi
  git -C "$1" add -A && git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm init
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
