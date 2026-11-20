#!/usr/bin/env bash
# selfcheck.py: the SessionStart check that every guard can still run.
#
# Why it exists: a guard that cannot run is a guard that is OFF, and nothing
# says so. macOS revoked a terminal's access to the folder the plugin lived in,
# every hook failed with `python3: can't open file ...: Operation not
# permitted`, and the session carried on with no guard on at all. The same
# silence follows python3 missing from PATH, a half-written install, a guard
# with a syntax error after an update.
#
# So the check is held to two rules, each a case below:
#   1. healthy kit -> SILENT (a check that talks every session gets ignored);
#   2. anything broken -> LOUD, naming the hook, its error line, "OFF", a fix --
#      and never a failed session start: exit 0 whatever happens, including
#      when selfcheck itself cannot run (the hooks.json fallback).
#
# Every broken case breaks a COPY of the plugin under mktemp -d. The real repo
# is never chmod-ed or edited.
#
#   bash selfcheck.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
# PY picks the interpreter under test. Left unset, the suite runs on python3,
# then AGAIN on /usr/bin/python3 (3.9 on macOS) when it exists. The snapshot is
# recorded once, under python3; the rerun checks the same assertions.
PY_GIVEN="${PY:-}"
PY="$(command -v "${PY:-python3}")"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
# A tmp dir of the suite's own, so "it cleaned up" is checkable.
export TMPDIR="$T/tmpd"; mkdir -p "$TMPDIR"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

. "$SD/expect.sh"
if [ -z "$PY_GIVEN" ]; then
  expect_init "$SD/selfcheck.expected"
  expect_scrub_dir "$T" '<tmp>'
  expect_scrub "$KIT" '<kit>'
fi

# Every `python3` -- selfcheck's and each guard's -- resolves to $PY.
mkdir -p "$T/pybin"; ln -s "$PY" "$T/pybin/python3"
export PATH="$T/pybin:$PATH"

# kitcopy <dir> -- a copy of this plugin to break one thing in
kitcopy() { mkdir -p "$1"; cp -R "$KIT/." "$1/"; rm -rf "$1/scripts/__pycache__"; }

# The SessionStart command exactly as hooks.json declares it, so the fallback
# around it is under test too, not just the script.
HOOKCMD="$("$PY" -c '
import json, sys
for g in json.load(open(sys.argv[1]))["hooks"].get("SessionStart", []):
    for h in g.get("hooks", []):
        print(h["command"]); sys.exit(0)
sys.exit(1)' "$KIT/hooks/hooks.json")" || HOOKCMD=''
chk "hooks.json declares a SessionStart hook" "$([ -n "$HOOKCMD" ] && echo y || echo n)" y
MATCHER="$("$PY" -c '
import json, sys
print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0].get("matcher", ""))' "$KIT/hooks/hooks.json" 2>/dev/null)"
chk "  ...on startup, resume and clear (not compact: nothing changed on disk)" "$MATCHER" "startup|resume|clear"

session_start() {
  printf '{"session_id":"selfcheck-test","transcript_path":"%s/t.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$T" "$T"
}

# hook <kit> -- run the SessionStart command as Claude Code would: sh -c, the
# plugin root in CLAUDE_PLUGIN_ROOT, the payload on stdin. Leaves HOOK_RC,
# HOOK_OUT (stdout), HOOK_ERR (stderr).
hook() {
  local o="$T/hook.out" e="$T/hook.err"
  session_start | CLAUDE_PLUGIN_ROOT="$1" /bin/sh -c "$HOOKCMD" >"$o" 2>"$e"; HOOK_RC=$?
  HOOK_OUT="$(cat "$o")"; HOOK_ERR="$(cat "$e")"
}

# field <name> -- one field of HOOK_OUT's JSON: systemMessage, or
# hookSpecificOutput.<name>. Prints NOT-JSON when stdout is not one JSON object.
field() {
  printf '%s' "$HOOK_OUT" | "$PY" -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("NOT-JSON"); sys.exit(0)
k = sys.argv[1]
v = d.get(k) if k == "systemMessage" else (d.get("hookSpecificOutput") or {}).get(k)
print("" if v is None else v)' "$1"
}

# show <kit> -- the hook's run, decoded for the snapshot: exit code, then each
# field of its JSON as text. Exits with the hook's own code.
show() {
  hook "$1"
  # Its stderr is left out: on exit 0 Claude Code shows it nowhere, and its
  # wording (a Python traceback, the shell's `not found`) varies by platform.
  if [ -z "$HOOK_OUT" ]; then return "$HOOK_RC"; fi
  printf -- '-- systemMessage (the person)\n%s\n' "$(field systemMessage)"
  printf -- '-- hookEventName\n%s\n' "$(field hookEventName)"
  printf -- '-- additionalContext (the model)\n%s\n' "$(field additionalContext)"
  return "$HOOK_RC"
}

# loud <label> -- the assertions every broken case shares.
loud() {
  chk "$1: exit 0 (a session start is never blocked)" "$HOOK_RC" 0
  chk "  ...stdout is one JSON object" "$([ "$(field systemMessage)" = NOT-JSON ] && echo no || echo yes)" yes
  chk "  ...for the SessionStart event" "$(field hookEventName)" SessionStart
  local m c; m="$(field systemMessage)"; c="$(field additionalContext)"
  chk "  ...with a message for the person" "$([ -n "$m" ] && [ "$m" != NOT-JSON ] && echo y || echo n)" y
  chk "  ...and the same news for the model" "$([ -n "$c" ] && [ "$c" != NOT-JSON ] && echo y || echo n)" y
  has "  ...saying the guards are OFF" "OFF" "$(field systemMessage)"
}

capture() {  # capture <label> <kit> -- snapshot under python3 only, run always
  if [ -z "$PY_GIVEN" ]; then expect_capture "$1" show "$2"; fi
  hook "$2"
}

echo "A HEALTHY KIT"
t0=$("$PY" -c 'import time; print(time.time())')
hook "$KIT"
t1=$("$PY" -c 'import time; print(time.time())')
chk "every guard answered: exit 0" "$HOOK_RC" 0
chk "  ...and SILENT on stdout (a check that talks every session gets ignored)" "$HOOK_OUT" ""
chk "  ...and on stderr" "$HOOK_ERR" ""
ms=$("$PY" -c "print(int(($t1 - $t0) * 1000))")
chk "  ...in well under 2s (took ${ms}ms; it runs on every session start)" "$([ "$ms" -lt 2000 ] && echo fast || echo slow)" fast
capture "healthy kit" "$KIT"
# Inside a real session CLAUDE_PROJECT_DIR names the USER's project. The ls-guard
# probe must still read the bendit.json it wrote into its own probe dir, not that
# project's: a project with ls-guard OFF (or a malformed file) must change nothing.
mkdir -p "$T/userproj/.claude"; printf '{"version":1,"features":{"ls-guard":{"on":false,"why":"user"}}}' > "$T/userproj/.claude/bendit.json"
o=$(CLAUDE_PROJECT_DIR="$T/userproj" "$PY" "$KIT/scripts/selfcheck.py" --hook </dev/null 2>&1); rc=$?
chk "a user project with ls-guard OFF does not blind the ls probe (silent, exit 0)" "$rc|$o" "0|"
printf '{"version":1,"features":' > "$T/userproj/.claude/bendit.json"
o=$(CLAUDE_PROJECT_DIR="$T/userproj" "$PY" "$KIT/scripts/selfcheck.py" --hook </dev/null 2>&1); rc=$?
chk "  ...nor does a malformed one (the probe reads its own file)" "$rc|$o" "0|"
if [ -z "$PY_GIVEN" ]; then
  expect_capture "healthy kit, --verbose (what /bendit:doctor prints)" "$PY" "$KIT/scripts/selfcheck.py" --verbose
  chk "--verbose on a healthy kit: exit 0" "$EXPECT_CODE" 0
  has "  ...a row per hook" "block-dangerous-bash" "$EXPECT_STDOUT"
fi

echo
echo "A GUARD THAT CANNOT BE READ -- the macOS case"
# Asserted directly, NOT snapshotted: root reads everything, so this case can
# only run for a normal user, and a snapshot that depends on the uid would fail
# in a root container.
if [ "$(id -u)" -ne 0 ]; then
  K="$T/kit-unreadable"; kitcopy "$K"; chmod 000 "$K/scripts/block-dangerous-bash.py"
  hook "$K"
  loud "unreadable guard"
  has "  ...naming the guard" "block-dangerous-bash" "$(field systemMessage)"
  has "  ...quoting its error line" "Permission denied" "$(field systemMessage)"
  has "  ...telling the model too" "Permission denied" "$(field additionalContext)"
  has "  ...with a fix" "reinstall" "$(field systemMessage)"
  case "$(field systemMessage)" in *path-contracts*) o=others-named ;; *) o=only-it ;; esac
  chk "  ...and ONLY that guard (the rest answered their probes)" "$o" only-it
  chmod 644 "$K/scripts/block-dangerous-bash.py"
else
  printf '  skip  an unreadable guard (running as root reads everything)\n'
fi

# The macOS privacy denial itself (EPERM, `Operation not permitted`) cannot be
# produced without revoking a real app's access, so its wording is checked on
# the line Python prints for it.
fix="$("$PY" -c '
import sys; sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import selfcheck as s
print(s.fix_for("python3: can'"'"'t open file '"'"'/x/scripts/g.py'"'"': [Errno 1] Operation not permitted", 2))' "$SD")"
has "\`Operation not permitted\` -> the fix names Full Disk Access" "Full Disk Access" "$fix"

echo
echo "A GUARD THAT RUNS BUT LETS EVERYTHING THROUGH"
K="$T/kit-open"; kitcopy "$K"
printf 'import sys\nsys.exit(0)\n' > "$K/scripts/block-dangerous-bash.py"
capture "block-dangerous-bash replaced by exit 0" "$K"
loud "guard that never refuses"
has "  ...naming it" "block-dangerous-bash" "$(field systemMessage)"
has "  ...as not refusing its probe" "no longer refuses" "$(field systemMessage)"

echo
echo "A GUARD THAT CRASHES (a syntax error after an update)"
K="$T/kit-syntax"; kitcopy "$K"
printf 'def broken(:\n' > "$K/scripts/path-contracts.py"
# Asserted, not snapshotted: SyntaxError wording varies across Python versions.
hook "$K"
loud "guard with a syntax error"
has "  ...naming it" "path-contracts" "$(field systemMessage)"
has "  ...quoting the error" "SyntaxError" "$(field systemMessage)"

echo
echo "PYTHON3 MISSING FROM PATH"
# For the guards only: selfcheck itself runs on an absolute interpreter, the
# way it would if Claude Code found python3 but the guards' shell did not.
# Asserted, not snapshotted: the shell's wording differs (bash `command not
# found`, dash `not found`).
K="$T/kit-nopy"; kitcopy "$K"
out="$(env PATH=/nonexistent "$PY" "$K/scripts/selfcheck.py" --hook </dev/null)"; rc=$?
HOOK_OUT="$out"; HOOK_RC=$rc
loud "python3 missing for the guards"
has "  ...quoting the shell's error" "not found" "$(field systemMessage)"
has "  ...pointing at PATH" "PATH" "$(field systemMessage)"
# And for selfcheck itself: the fallback in hooks.json must still speak.
session_start | env PATH=/nonexistent CLAUDE_PLUGIN_ROOT="$K" /bin/sh -c "$HOOKCMD" >"$T/o" 2>/dev/null; HOOK_RC=$?
HOOK_OUT="$(cat "$T/o")"
loud "python3 missing for selfcheck itself (the hooks.json fallback)"
has "  ...pointing at python3" "python3" "$(field systemMessage)"

echo
echo "SELFCHECK ITSELF BROKEN"
K="$T/kit-selfbroken"; kitcopy "$K"
printf 'def broken(:\n' > "$K/scripts/selfcheck.py"
capture "selfcheck.py has a syntax error (the hooks.json fallback)" "$K"
loud "selfcheck.py unparseable"
K="$T/kit-probes"; kitcopy "$K"
printf 'raise RuntimeError("synthetic")\n' > "$K/scripts/probes.py"
capture "the probe table raises on import" "$K"
loud "internal error"
has "  ...reported, not raised" "synthetic" "$(field systemMessage)"

echo
echo "A MALFORMED hooks.json"
K="$T/kit-json"; kitcopy "$K"
printf '{"hooks": {"PreToolUse": [' > "$K/hooks/hooks.json"
# The hook command comes from the GOOD hooks.json (Claude Code would not load
# this one at all); selfcheck must still say what it found.
capture "hooks.json is not valid JSON" "$K"
loud "malformed hooks.json"
has "  ...naming the file" "hooks.json" "$(field systemMessage)"

K="$T/kit-empty"; kitcopy "$K"
printf '{"hooks": {}}\n' > "$K/hooks/hooks.json"
capture "hooks.json declares no guards" "$K"
loud "no guards to check (never a silent pass)"

echo
echo "A HOOK WITH NO PROBE"
K="$T/kit-unprobed"; kitcopy "$K"
"$PY" - "$K/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['hooks']['PreToolUse'][0]['hooks'].append(
    {'type': 'command', 'command': 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/new-guard-nobody-probed.py"', 'timeout': 10})
json.dump(d, open(p, 'w'), indent=2)
PY
capture "a hook selfcheck has no probe for" "$K"
loud "unprobed hook"
has "  ...naming it" "new-guard-nobody-probed" "$(field systemMessage)"

echo
echo "FEATURES (--features <root>: the table /bendit:doctor merges in, and the add-on scope warning)"
# `claude` is stubbed on PATH with the shape `claude plugin list --json` really
# prints (a list of {id, scope, enabled, ...}); never the real CLI.
mkdir -p "$T/stub-user" "$T/stub-project" "$T/stub-broken"
stub() {  # stub <dir> <json-or-@fail>
  if [ "$2" = '@fail' ]; then printf '#!/bin/sh\necho "boom: not logged in" >&2\nexit 3\n' > "$1/claude"
  else printf '#!/bin/sh\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$2" > "$1/claude"; fi
  chmod +x "$1/claude"
}
stub "$T/stub-user" '[{"id":"frontend-design@x","scope":"project","enabled":true},{"id":"bendit-web@bendit","scope":"user","enabled":true}]'
stub "$T/stub-project" '[{"id":"bendit-web@bendit","scope":"project","enabled":true,"projectPath":"/p"},{"id":"bendit-web@bendit","scope":"user","enabled":false}]'
stub "$T/stub-broken" @fail
FP="$T/featproj"; mkdir -p "$FP"
"$PY" "$SD/features.py" set "$FP" browser-driver on "package.json:14 next"
"$PY" "$SD/features.py" set "$FP" ls-guard off "declined by the person"
fe() {  # fe <stubdir> <root> -- leaves FE_RC, FE_OUT
  FE_OUT="$(PATH="$1:$PATH" "$PY" "$KIT/scripts/selfcheck.py" --features "$2" 2>&1)"; FE_RC=$?
}
if [ -z "$PY_GIVEN" ]; then
  expect_capture "features table + add-on at user scope" env PATH="$T/stub-user:$PATH" "$PY" "$KIT/scripts/selfcheck.py" --features "$FP"
fi
fe "$T/stub-user" "$FP"
chk "features: exit 0" "$FE_RC" 0
has "  ...a row for a feature that is on" "browser-driver | on" "$FE_OUT"
has "  ...with its reason" "package.json:14 next" "$FE_OUT"
has "  ...a row for one that is off" "ls-guard" "$FE_OUT"
has "  ...add-on enabled at user scope: the warning" "bendit-web is installed for every project, not only this one" "$FE_OUT"
fe "$T/stub-project" "$FP"
case "$FE_OUT" in *"not only this one"*) o=warned ;; *) o=quiet ;; esac
chk "add-on at project scope (user scope disabled): no warning" "$o" quiet
fe "$T/stub-broken" "$FP"
has "claude CLI errors: says it could not check" "could not check" "$FE_OUT"
case "$FE_OUT" in *"not only this one"*) o=warned ;; *) o=quiet ;; esac
chk "  ...and does not claim the add-on is at user scope" "$o" quiet
has "  ...and the table still prints" "browser-driver | on" "$FE_OUT"
# No claude on PATH at all: a hermetic PATH holding only the interpreter.
mkdir -p "$T/hermetic"; ln -sf "$PY" "$T/hermetic/python3"
FE_OUT="$(env PATH="$T/hermetic" "$PY" "$KIT/scripts/selfcheck.py" --features "$FP" 2>&1)"
has "no claude on PATH: says it could not check" "could not check" "$FE_OUT"
# A malformed bendit.json is reported, never read as everything off.
BP="$T/badproj"; mkdir -p "$BP/.claude"; printf '{"version": 1, "features": [' > "$BP/.claude/bendit.json"
fe "$T/stub-user" "$BP"
chk "malformed bendit.json: exit 1" "$FE_RC" 1
has "  ...naming the file" "bendit.json" "$FE_OUT"
has "  ...and still says the add-on scope" "add-on scope:" "$FE_OUT"
case "$FE_OUT" in *"features: features:"*) o=doubled ;; *) o=once ;; esac
chk "  ...and does not print the 'features:' prefix twice" "$o" once
# From a SUBDIRECTORY of a git repo whose ROOT file is malformed: the root is
# resolved like prove.sh does, so this fails (not four "off | (not set)" rows).
SR="$T/subrepo"; mkdir -p "$SR/.claude" "$SR/pkg/deep"; git -C "$SR" init -q
printf '{"version": 1, "features": [' > "$SR/.claude/bendit.json"
FE_OUT="$(cd "$SR/pkg/deep" && PATH="$T/stub-user:$PATH" "$PY" "$KIT/scripts/selfcheck.py" --features . 2>&1)"; FE_RC=$?
chk "subdirectory of a repo with a malformed root bendit.json: exit 1" "$FE_RC" 1
has "  ...names the root file it read" "$SR/.claude/bendit.json" "$FE_OUT"
case "$FE_OUT" in *"(not set)"*) o=off ;; *) o=failed ;; esac
chk "  ...and does not read it as everything off" "$o" failed
# A good root file is found from the subdirectory too.
rm "$SR/.claude/bendit.json"
"$PY" "$SD/features.py" set "$SR" ls-guard off "declined by the person"
FE_OUT="$(cd "$SR/pkg/deep" && PATH="$T/stub-user:$PATH" "$PY" "$KIT/scripts/selfcheck.py" --features . 2>&1)"; FE_RC=$?
chk "subdirectory, good root file: exit 0" "$FE_RC" 0
has "  ...shows the root file's row" "declined by the person" "$FE_OUT"

echo
echo "IT CLEANS UP"
# DIRECTORIES only: selfcheck makes a temp dir per run. expect.sh keeps its own
# capture FILE in $TMPDIR until expect_verify -- on Linux GNU mktemp puts it
# here, on macOS it does not -- and counting it failed CI on Ubuntu only.
chk "selfcheck's temp dirs are gone after every run above" \
    "$(/usr/bin/find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | sed "s|^$TMPDIR/||")" ""

if [ -z "$PY_GIVEN" ]; then
  echo
  echo "WHAT IT SAYS (snapshot)"
  expect_verify || fail=$((fail+1))
fi
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
