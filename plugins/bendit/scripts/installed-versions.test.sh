#!/usr/bin/env bash
# installed-versions.py: which bendit each checkout of a repo will load.
#
# Why it exists: on 2026-11-22 setup ran in a git worktree, installed 0.5.0 for
# the worktree's path, and the reopened window ran 0.4.0: installed_plugins.json
# still held 0.4.0 for the MAIN checkout's path, and the worktree resolved that
# one. Nothing said the two checkouts disagreed. This runs the real script on a
# real scratch repo with one worktree and fixture installed_plugins.json files
# (never the real one, never `claude plugin list`, which can hang).
#
#   bash installed-versions.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
S="$SD/installed-versions.py"
PY="${PY:-python3}"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }
hasnt() { case "$3" in *"$2"*) chk "$1 (found '$2' in: $3)" n y;; *) chk "$1" y y;; esac; }

# The running version, read the way a person would: from plugin.json.
V="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$KIT/.claude-plugin/plugin.json")"
chk "the running version was read from plugin.json" "$([ -n "$V" ] && echo y || echo n)" y
OLD=0.0.1        # older than any real release
NEW=99.0.0       # newer than any real release

# A real repo with one commit and one worktree.
MAIN="$T/proj"; WT="$T/proj-wt"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" -c user.name=t -c user.email=nobody commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WT" -b wt 2>/dev/null
chk "the scratch repo has two checkouts" "$(git -C "$MAIN" worktree list --porcelain | grep -c '^worktree ')" 2

# plugins <file> <main bendit|-> <wt bendit|-> [<main web|->] -- a fixture
# installed_plugins.json in the shape Claude Code writes (version 2).
plugins() {
  "$PY" - "$1" "$2" "$3" "${4:--}" "$MAIN" "$WT" <<'PY'
import json, sys
out, mb, wb, mw, main, wt = sys.argv[1:7]
data = {'version': 2, 'plugins': {}}
def add(pid, path, v):
    if v == '-':
        return
    data['plugins'].setdefault(pid, []).append({
        'scope': 'project', 'projectPath': path, 'version': v,
        'installPath': '/nowhere/' + pid + '/' + v})
add('bendit@bendit', main, mb)
add('bendit@bendit', wt, wb)
add('bendit-web@bendit', main, mw)
# Noise that must be ignored: another plugin, and a user-scope entry.
data['plugins']['other@x'] = [{'scope': 'project', 'projectPath': main, 'version': '1.0.0'}]
data['plugins'].setdefault('bendit@bendit', []).append({'scope': 'user', 'version': '0.0.0'})
json.dump(data, open(out, 'w'))
PY
}
run() { OUT="$("$PY" "$S" "$@" 2>&1)"; RC=$?; }

echo "ALL MATCH"
plugins "$T/match.json" "$V" "$V" "$V"
run --root "$MAIN" --plugins-file "$T/match.json"
chk "every checkout records the running version: exit 0" "$RC" 0
has "  ...names the running version" "running: bendit $V" "$OUT"
has "  ...names the main checkout" "$MAIN" "$OUT"
has "  ...and the worktree" "$WT" "$OUT"
hasnt "  ...and gives no update command" "claude plugin update" "$OUT"
run --root "$WT" --plugins-file "$T/match.json"
chk "run from the worktree: the same answer (exit 0)" "$RC" 0
has "  ...the worktree is marked as this folder" "$WT (this folder)" "$OUT"

echo
echo "THE LIVE CASE: MAIN CHECKOUT OLDER THAN THE WORKTREE"
plugins "$T/old-main.json" "$OLD" "$V"
run --root "$WT" --plugins-file "$T/old-main.json"
chk "main older than running: exit 1" "$RC" 1
has "  ...says the main checkout's version" "bendit $OLD" "$OUT"
has "  ...in plain words" "older than" "$OUT"
has "  ...gives the exact update command for the main checkout" \
    "cd $MAIN && claude plugin update bendit@bendit --scope project" "$OUT"
hasnt "  ...and none for the worktree, which matches" "cd $WT &&" "$OUT"
J="$("$PY" "$S" --root "$WT" --plugins-file "$T/old-main.json" --json)"; JRC=$?
chk "--json: the same exit (1)" "$JRC" 1
chk "--json: each checkout's version, main first" \
  "$(printf '%s' "$J" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["running"], [(c["main"], c["here"], c["bendit"]) for c in d["checkouts"]])')" \
  "$V [(True, False, '$OLD'), (False, True, '$V')]"

echo
echo "A CHECKOUT NEWER THAN THE RUNNING COPY"
plugins "$T/new-wt.json" "$V" "$NEW"
run --root "$MAIN" --plugins-file "$T/new-wt.json"
chk "a different version, even a newer one, is a mismatch: exit 1" "$RC" 1
has "  ...says newer" "newer than" "$OUT"
has "  ...and the checkout behind the newest gets the update command" \
    "cd $MAIN && claude plugin update bendit@bendit --scope project" "$OUT"

echo
echo "THE WEB ADD-ON IS COMPARED TOO"
plugins "$T/web.json" "$V" "$V" "$OLD"
run --root "$MAIN" --plugins-file "$T/web.json"
chk "bendit-web older on main: exit 1" "$RC" 1
has "  ...names it" "bendit-web $OLD" "$OUT"
has "  ...with its own update command" "claude plugin update bendit-web@bendit --scope project" "$OUT"

echo
echo "NO INSTALL"
plugins "$T/none.json" - - -
run --root "$MAIN" --plugins-file "$T/none.json"
chk "nothing recorded for either path: exit 0 (none is not a mismatch)" "$RC" 0
has "  ...says none, never a version" "bendit none" "$OUT"
plugins "$T/half.json" - "$V"
run --root "$MAIN" --plugins-file "$T/half.json"
chk "worktree installed, main not: exit 0" "$RC" 0
has "  ...main says none" "bendit none" "$OUT"

echo
echo "COULD NOT READ: EXIT 2, NEVER 'ALL FINE'"
run --root "$MAIN" --plugins-file "$T/missing.json"
chk "a missing installed_plugins.json: exit 2" "$RC" 2
has "  ...names the file" "$T/missing.json" "$OUT"
hasnt "  ...and claims nothing" "running: bendit" "$OUT"
printf '{"version": 2, "plugins": ' > "$T/bad.json"
run --root "$MAIN" --plugins-file "$T/bad.json"
chk "malformed JSON: exit 2" "$RC" 2
printf '[1, 2]' > "$T/list.json"
run --root "$MAIN" --plugins-file "$T/list.json"
chk "the wrong shape: exit 2" "$RC" 2
printf '{"version": 2, "plugins": {"bendit@bendit": [{"scope": "project", "projectPath": 7, "version": "1"}]}}' > "$T/badentry.json"
run --root "$MAIN" --plugins-file "$T/badentry.json"
chk "an entry whose projectPath is not a string: exit 2" "$RC" 2
cp "$T/match.json" "$T/locked.json"; chmod 000 "$T/locked.json"
if [ -r "$T/locked.json" ]; then
  chk "an unreadable file (skipped: running as root reads it anyway)" y y
else
  run --root "$MAIN" --plugins-file "$T/locked.json"
  chk "an unreadable file: exit 2" "$RC" 2
  hasnt "  ...no traceback" "Traceback" "$OUT"
fi
chmod 600 "$T/locked.json"
J="$("$PY" "$S" --root "$MAIN" --plugins-file "$T/missing.json" --json)"; JRC=$?
chk "--json, unreadable: exit 2 with an error object" \
  "$JRC|$(printf '%s' "$J" | "$PY" -c 'import json,sys; print(sorted(json.load(sys.stdin)))')" "2|['error']"

echo
echo "NOT A GIT REPOSITORY: ONLY THIS FOLDER"
mkdir -p "$T/plain"
"$PY" -c 'import json,sys; json.dump({"version":2,"plugins":{"bendit@bendit":[{"scope":"project","projectPath":sys.argv[1],"version":sys.argv[2]}]}}, open(sys.argv[3],"w"))' \
  "$T/plain" "$V" "$T/plain.json"
run --root "$T/plain" --plugins-file "$T/plain.json"
chk "a folder with no git: exit 0, itself only" "$RC" 0
has "  ...names it" "$T/plain (this folder)" "$OUT"

echo
echo "THE DEFAULT FILE IS UNDER HOME, AND NO CLAUDE CLI IS CALLED"
mkdir -p "$T/home/.claude/plugins" "$T/bin"
cp "$T/old-main.json" "$T/home/.claude/plugins/installed_plugins.json"
printf '#!/bin/sh\necho called >> "%s/claude.log"\nsleep 30\n' "$T" > "$T/bin/claude"; chmod +x "$T/bin/claude"
OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$T/home" PATH="$T/bin:$PATH" "$PY" "$S" --root "$MAIN" 2>&1)"; RC=$?
chk "no --plugins-file: reads ~/.claude/plugins/installed_plugins.json (exit 1 on this fixture)" "$RC" 1
chk "  ...and never runs claude" "$([ -e "$T/claude.log" ] && echo called || echo no)" no

printf '\ninstalled-versions.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
