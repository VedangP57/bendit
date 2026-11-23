#!/usr/bin/env bash
# prove.sh is the check /bendit:adopt reports from, so it is held to the rule it
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
# The running version changes every release; the snapshot must not.
expect_scrub "$(python3 "$SD/features.py" version)" '<running>'

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
chk "  ...five features read UNUSED" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -c '^feature: .*| UNUSED ')" "5"
has "  ...saying why" "UNUSED  not set up by /bendit:adopt yet" "$EXPECT_STDOUT"
has "  ...and the summary counts them" "checks passed (5 unused)" "$EXPECT_STDOUT"
has "  ...readable row passes" "features: .claude/bendit.json readable" "$EXPECT_STDOUT"

BENDIT_JSON='{"version":1,"features":{"browser-driver":{"on":false,"why":"you declined Chrome"}}}'
F1="$T/feat-off"; repo "$F1" 'exit 0'
expect_capture "feature declined" bash "$SD/prove.sh" "$F1"
chk "a declined feature is UNUSED with its reason, exit 0" "$EXPECT_CODE" "0"
has "  ...the reason is shown" "UNUSED  you declined Chrome" "$EXPECT_STDOUT"

BENDIT_JSON='{"version":1,"features":{"browser-driver":{"on":true,"why":"Chrome"}}}'
F2="$T/feat-browser"; repo "$F2" 'exit 0'
K0="$T/kit-nocheck"; kitcopy "$K0"
sed -i.bak "/^    'browser-driver': _check_browser_driver,\$/d" "$K0/scripts/prove.sh"
chk "  (the copy really lost its browser-driver check)" "$(grep -c "'browser-driver': _check_browser_driver" "$K0/scripts/prove.sh")" "0"
expect_capture "browser-driver on, no registered check" bash "$K0/scripts/prove.sh" "$F2"
chk "an ON feature with no registered check fails prove" "$EXPECT_CODE" "1"
has "  ...naming it" "no check for browser-driver" "$EXPECT_STDOUT"
# browser-driver: ON means Playwright is installed (drive-setup.sh --check) AND
# the driver passes its own selftest page. Both are stand-ins in a kit copy
# here, so this pins what the check runs and reads; drive.test.sh drives the
# real browser.
K6="$T/kit-noplaywright"; kitcopy "$K6"
printf '#!/usr/bin/env bash\necho "drive-setup: Playwright is not installed"\nexit 1\n' > "$K6/scripts/drive-setup.sh"
expect_capture "browser-driver on, Playwright not installed" bash "$K6/scripts/prove.sh" "$F2"
chk "browser-driver on with no Playwright fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...giving the command that installs it" "drive-setup.sh" "$(printf '%s\n' "$EXPECT_STDOUT" | sed -n '/^failures:/,$p')"
# fakedrive <kit> <exit code>: a drive.mjs that checks it was handed the selftest,
# writes into its --out like the real one, and exits as told.
fakedrive() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/scripts/drive-setup.sh"
  cat > "$1/lib/drive/drive.mjs" <<EOF
import { mkdirSync, writeFileSync } from 'node:fs';
const a = process.argv.slice(2), v = (n) => a[a.indexOf(n) + 1];
const ok = a[0].endsWith('/lib/drive/selftest/pass.json') && String(v('--base')).startsWith('file://') && a.includes('--out');
mkdirSync(v('--out'), { recursive: true }); writeFileSync(v('--out') + '/verdict.md', 'x');
console.log(!ok ? 'VERDICT: NOT VERIFIED -- unexpected args ' + a.join(' ')
  : $2 === 0 ? 'VERDICT: VERIFIED' : 'FAIL  5  expectText  — "Saved"\nVERDICT: NOT VERIFIED');
process.exit(ok ? $2 : 3);
EOF
}
K7="$T/kit-drivefails"; kitcopy "$K7"; fakedrive "$K7" 1
expect_capture "browser-driver on, selftest fails" bash "$K7/scripts/prove.sh" "$F2"
chk "a driver that fails its selftest fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying the selftest failed" "selftest" "$(printf '%s\n' "$EXPECT_STDOUT" | sed -n '/^failures:/,$p')"
K8="$T/kit-drivepasses"; kitcopy "$K8"; fakedrive "$K8" 0
gst "$F2" >/dev/null; before=$(gst "$F2"; snap "$F2")
expect_capture "browser-driver on, selftest passes" bash "$K8/scripts/prove.sh" "$F2"
chk "browser-driver: installed and the selftest passes -> prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: browser-driver +\| PASS ')" "1"
chk "  ...and the selftest's evidence went nowhere near the repo" "$([ "$before" = "$(gst "$F2"; snap "$F2")" ] && echo same || echo changed)" same
chk "  ...nor stayed in the temp dir" "$(/bin/ls -A "$TMPDIR")" ""

BENDIT_JSON='{"version":1,"features":{"ls-guard":{"on":true,"why":"ls is a formatter"}}}'
F2b="$T/feat-ls"; repo "$F2b" 'exit 0'
expect_capture "ls-guard on" bash "$SD/prove.sh" "$F2b"
chk "ls-guard on: the check runs the hook and prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: ls-guard +\| PASS ')" "1"

echo
echo "PROVE'S OWN PROBES ARE NOT REFUSALS"
# Inside Claude Code, CLAUDE_PROJECT_DIR names the project being proved, and
# every probe's refusal used to land in ITS fires.jsonl: /bendit:guard-report
# then showed bendit's self-test as the project's refusals. This project has a
# .claude/ (bendit.json), so a guard that logs would write there.
FL="$F2b/.claude/.bendit-state/fires.jsonl"
CLAUDE_PROJECT_DIR="$F2b" bash "$SD/prove.sh" "$F2b" >"$T/pl.out" 2>&1
chk "prove.sh run as a session runs it: still exit 0" "$?" "0"
chk "  ...and the project's refusal log has no line from it" \
    "$(if [ -f "$FL" ]; then wc -l <"$FL" | tr -d ' '; else echo 0; fi)" "0"
chk "  ...so guard-report says nothing was refused" \
    "$(python3 "$SD/guard-report.py" --root "$F2b" | head -1 | cut -c1-27)" "no refusals recorded yet (n"

# primary-checkout-guard: PASS means the guard, run as hooks.json runs it, refused
# an edit in a scratch primary checkout on THIS repo's integration branch, and
# allowed the same edit from a linked worktree. No branch resolvable: not PASS.
BENDIT_JSON='{"version":1,"features":{"primary-checkout-guard":{"on":true,"why":"chosen in --detailed"}}}'
F2d="$T/feat-pcg"; repo "$F2d" 'exit 0'
git -C "$F2d" update-ref refs/remotes/origin/trunk HEAD
git -C "$F2d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
expect_capture "primary-checkout-guard on (origin/HEAD)" bash "$SD/prove.sh" "$F2d"
chk "primary-checkout-guard on, origin/HEAD set: prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: primary-checkout-guard +\| PASS ')" "1"
git -C "$F2d" symbolic-ref --delete refs/remotes/origin/HEAD
expect_capture "primary-checkout-guard on, no integration branch" bash "$SD/prove.sh" "$F2d"
chk "on, but no integration branch resolves: prove fails (exit 1)" "$EXPECT_CODE" "1"
chk "  ...its row says FAIL, not PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: primary-checkout-guard +\| FAIL ')" "1"
has "  ...saying why" "no integration branch" "$(printf '%s\n' "$EXPECT_STDOUT" | sed -n '/^failures:/,$p')"
python3 "$SD/features.py" integration-branch "$F2d" release >/dev/null
expect_capture "primary-checkout-guard on (integrationBranch)" bash "$SD/prove.sh" "$F2d"
chk "on, integrationBranch recorded: prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: primary-checkout-guard +\| PASS ')" "1"
BENDIT_JSON='{"version":1,"features":{"primary-checkout-guard":{"on":false,"why":"you said no"}}}'
F2e="$T/feat-pcg-off"; repo "$F2e" 'exit 0'
expect_capture "primary-checkout-guard off" bash "$SD/prove.sh" "$F2e"
chk "off: its row says UNUSED" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: primary-checkout-guard +\| UNUSED ')" "1"

BENDIT_JSON='{"version":1,"features":{"session-brief":{"on":true,"why":"git project","brief":{"local_ports":[]}}}}'
F2c="$T/feat-brief"; repo "$F2c" 'exit 0'
git -C "$F2c" checkout -q -b brief-branch   # not the init default: that differs per machine
expect_capture "session-brief on" bash "$SD/prove.sh" "$F2c"
chk "session-brief on: the brief runs on the repo and prove passes" "$EXPECT_CODE" "0"
chk "  ...its row says PASS" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^feature: session-brief +\| PASS ')" "1"
# A brief that prints valid JSON but does not name the branch must FAIL the
# row: the check reads the context, not just the exit code. (It stays silent
# for --hook, so only the feature row can catch it.)
K5="$T/kit-blindbrief"; kitcopy "$K5"
printf 'import sys, json\nif "--cwd" in sys.argv: print(json.dumps({"context": "nothing", "toast": ""}))\n' > "$K5/scripts/session-brief.py"
expect_capture "session-brief that names no branch" bash "$K5/scripts/prove.sh" "$F2c"
chk "a brief that does not name the branch fails prove (exit 1)" "$EXPECT_CODE" "1"
has "  ...saying what is missing" "the brief does not name the checked-out branch" "$EXPECT_STDOUT"

# bendit.json is committed free text (each why, the brief config), so the
# privacy row scans it. The home path is assembled at run time so this file
# itself carries none, and the feature is ON so prove.sh never echoes the why
# (an UNUSED row prints it) into the committed snapshot.
U="/Us""ers"
BENDIT_JSON="{\"version\":1,\"features\":{\"ls-guard\":{\"on\":true,\"why\":\"seen in $U/alice/proj\"}}}"
FP="$T/feat-private"; repo "$FP" 'exit 0'
expect_capture "home path in a bendit.json why" bash "$SD/prove.sh" "$FP"
chk "a home path in .claude/bendit.json fails prove (exit 1)" "$EXPECT_CODE" "1"
chk "  ...on the privacy row" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^privacy: .*\| FAIL ')" "1"
has "  ...naming the file" ".claude/bendit.json" "$(printf '%s\n' "$EXPECT_STDOUT" | sed -n '/^failures:/,$p')"

# Privacy FAILS only for files bendit writes; another tool's skills are notices.
unset BENDIT_JSON   # the case above left a home path in it; these repos must start clean
# plantskill <repo> <skill-dir> -- a committed skill file carrying a home path.
plantskill() {
  mkdir -p "$1/.claude/skills/$2"; printf 'see %s/bob/x\n' "$U" > "$1/.claude/skills/$2/SKILL.md"
  git -C "$1" add -A && git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm skill
}
PO="$T/priv-other"; repo "$PO" 'exit 0'; plantskill "$PO" other-tool
expect_capture "finding only in another tool's skill" bash "$SD/prove.sh" "$PO"
chk "another tool's skill finding does not fail prove (exit 0)" "$EXPECT_CODE" "0"
chk "  ...privacy row PASSes" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^privacy: .*\| PASS ')" "1"
has "  ...with a notices block" "notices (not failures):" "$EXPECT_STDOUT"
has "  ...naming the file and line" ".claude/skills/other-tool/SKILL.md:1:" "$(printf '%s\n' "$EXPECT_STDOUT" | sed -n '/^notices/,$p')"
PA="$T/priv-agents"; repo "$PA" 'exit 0'; printf 'see %s/bob/x\n' "$U" >> "$PA/AGENTS.md"
git -C "$PA" add -A && git -C "$PA" -c user.email=t@example.com -c user.name=t commit -qm leak
expect_capture "finding in AGENTS.md" bash "$SD/prove.sh" "$PA"
chk "a finding in AGENTS.md fails prove (exit 1)" "$EXPECT_CODE" "1"
chk "  ...on the privacy row" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^privacy: .*\| FAIL ')" "1"
PV="$T/priv-verify"; repo "$PV" 'exit 0'; plantskill "$PV" verify-x
expect_capture "finding in the generated verify-x skill" bash "$SD/prove.sh" "$PV"
chk "a finding in .claude/skills/verify-x fails prove (exit 1)" "$EXPECT_CODE" "1"
chk "  ...on the privacy row" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^privacy: .*\| FAIL ')" "1"

# A file from a newer bendit: its feature written OFF is read past with a note;
# one written ON fails the readable row (a chosen guard must never silently not run).
BENDIT_JSON='{"version":1,"features":{"ls-guard":{"on":false,"why":"plain ls"},"teleport-guard":{"on":false,"why":"later"}}}'
FN="$T/feat-newer"; repo "$FN" 'exit 0'
expect_capture "bendit.json from a newer bendit, unknown feature off" bash "$SD/prove.sh" "$FN"
chk "an unknown feature that is off: prove exits 0" "$EXPECT_CODE" "0"
chk "  ...the readable row PASSES" "$(printf '%s\n' "$EXPECT_STDOUT" | grep -cE '^features: \.claude/bendit\.json readable +\| PASS ')" "1"
has "  ...with a note naming the feature" "note: ignored feature teleport-guard" "$EXPECT_STDOUT"
BENDIT_JSON='{"version":1,"features":{"teleport-guard":{"on":true,"why":"chosen"}}}'
FO="$T/feat-newer-on"; repo "$FO" 'exit 0'
expect_capture "bendit.json from a newer bendit, unknown feature ON" bash "$SD/prove.sh" "$FO"
chk "an unknown feature that is ON: prove fails" "$EXPECT_CODE" "1"
has "  ...giving the update command" "claude plugin update bendit@bendit --scope project" "$EXPECT_STDOUT"

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
