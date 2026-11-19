#!/usr/bin/env bash
# A guard that has never been seen to fail is decoration. Every guard the
# scaffold generates is exercised here in BOTH directions against a real
# generated harness: break the condition, assert it refuses for the stated
# reason, correct the condition, assert it passes. Detection is pinned by a
# snapshot (scaffold-verification-skill.expected) of what the scaffold SAYS for
# one fixture per ecosystem. Runs in scratch git repos; never touches a real one.
#
#   bash scaffold-verification-skill.test.sh [--accept]
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
SCAF="$SD/scaffold-verification-skill.sh"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
cleanup() { [ -n "${UP:-}" ] && { pkill -P "$UP" 2>/dev/null; kill "$UP" 2>/dev/null; }; rm -rf "$T"; }
trap cleanup EXIT
# The scaffolder allocates a port block. Without this, every run of this suite
# would write to the user's real registry -- a test that mutates real state is
# not a test. XDG_CONFIG_HOME is pointed away too, so a regression that ignores
# BENDIT_CONFIG_DIR lands in the temp dir, where the check below sees it.
export BENDIT_CONFIG_DIR="$T/cfg" XDG_CONFIG_HOME="$T/xdg"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }
hasnt() { case "$3" in *"$2"*) chk "$1 (unexpected '$2' in: $3)" y n;; *) chk "$1" n n;; esac; }
# A free port BELOW the kernel's ephemeral range. Port 0 hands out 49152+, and a
# registry block based near 65500 leaves no room for the next one: ports.py
# rightly refuses past 65535, which made later cases fail at random (seen
# 2026-11-19, "no free block left ... would start at 65625").
free_port() { python3 -c '
import random, socket
for p in random.sample(range(20000, 40000), 200):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); print(p); break
    except OSError:
        continue
    finally:
        s.close()
'; }
gcommit() { git -C "$1" add -A && git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm "${2:-init}"; }

. "$SD/expect.sh"
expect_init "$SD/scaffold-verification-skill.expected"
expect_scrub_dir "$T" '<tmp>'

echo "THE WEB HARNESS"
PORT=$(free_port)
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q
# A tiny loopback server that takes its port from --port.
echo "require('http').createServer((q,r)=>{if(q.url==='/missing'){r.statusCode=404;return r.end('no')}r.end('<h1>hello fixture</h1>')}).listen(+process.argv[process.argv.indexOf('--port')+1],'127.0.0.1')" > "$R/srv.js"
# "name" matches the folder on purpose: these sections are about the harness,
# and the skill's name comes from package.json (see NAMING below).
printf '{"name":"repo","scripts":{"dev":"node srv.js --port %s"},"dependencies":{"express":"1"}}\n' "$PORT" > "$R/package.json"
echo a > "$R/tracked.txt"
gcommit "$R"
bash "$SCAF" "$R" >/dev/null; chk "a node web app scaffolds cleanly (exit 0)" "$?" "0"
V="$R/.claude/skills/verify-repo/bin/verify-repo"
chk "generated app harness parses" "$(bash -n "$V" 2>&1; echo $?)" "0"
chk "generated .claude/verify-harness parses as sh" "$(sh -n "$R/.claude/verify-harness" 2>&1; echo $?)" "0"
has "the registry went to BENDIT_CONFIG_DIR" "$R" "$(cat "$T/cfg/ports.json" 2>/dev/null)"
chk "  ...and nothing was written under XDG_CONFIG_HOME" "$(/bin/ls -A "$T/xdg" 2>/dev/null | wc -l | tr -d ' ')" "0"
has ".git/info/exclude keeps verify state out of history" ".claude/.verify-state/" "$(cat "$R/.git/info/exclude")"
has "  ...and local env overrides too" ".env.verify.local" "$(cat "$R/.git/info/exclude")"
# A fresh clone has no local-only file, so the scaffold must not make one the
# harness depends on. It writes a COMMITTED example instead.
chk "no .env.verify.local is written (it is local-only: a clone never has it)" "$([ -e "$R/.env.verify.local" ] && echo written || echo absent)" "absent"
chk "a .env.verify.example is written" "$([ -f "$R/.env.verify.example" ] && echo y)" "y"
chk "  ...and git would commit it (not ignored)" "$(git -C "$R" check-ignore -q .env.verify.example && echo ignored || echo tracked)" "tracked"
has "  ...documenting the loopback rule" "loopback" "$(cat "$R/.env.verify.example" 2>/dev/null)"
has "  ...and that PORT comes from the registry, not the file" "PORT" "$(cat "$R/.env.verify.example" 2>/dev/null)"
SC="$R/.claude/skills/verify-repo/scenarios"
chk "a smoke scenario is generated" "$([ -f "$SC/smoke.sh" ] && echo y)" "y"
doc()  ( cd "$R" && PORT="$PORT" "$V" doctor 2>&1 )
drv()  ( cd "$R" && PORT="$PORT" "$V" drive "$@" 2>&1; echo "rc=$?" )
ENVF="$R/.env.verify.local"

# --- Guard 0: the repo under test is the checkout you stand in -----------------
# A harness symlinked into several worktrees, derived from its own path, would
# make every worktree verify the canonical checkout's code. R has a loopback
# env and R2 has none, so "ok every URL" can only come from R's bytes.
echo
echo "GUARD 0: THE CHECKOUT YOU STAND IN"
git_init() { mkdir -p "$1"; git -C "$1" init -q; }
printf 'APP_URL=http://127.0.0.1:9/x\n' > "$ENVF"
dd0() { ( cd "$1" && shift && PORT="$PORT" GIT_CEILING_DIRECTORIES="$T" "$@" doctor 2>&1; echo "rc=$?" ); }
mkdir -p "$R/sub/deeper"
o=$(dd0 "$R" "$V"); has "run from the repo root passes the guard" "ok    every URL in .env.verify.local is loopback" "$o"; hasnt "... and does not refuse" "refusing" "$o"
o=$(dd0 "$R/sub/deeper" "$V"); has "run from a subdirectory finds the root's env" "ok    every URL in .env.verify.local is loopback" "$o"
R2="$T/worktree"; git_init "$R2"; mkdir -p "$R2/.claude/skills"; ln -s "$R/.claude/skills/verify-repo" "$R2/.claude/skills/verify-repo"
o=$(dd0 "$R2" "$V"); has "symlinked harness run via its RESOLVED path verifies the WORKTREE (R2 has no env)" "no .env.verify.local" "$o"
hasnt "... and never reports the canonical checkout's bytes as ok" "ok    every URL" "$o"; hasnt "... and is not refused" "refusing" "$o"
R3="$T/bare"; git_init "$R3"
o=$(dd0 "$R3" "$V"); has "git repo with no harness is refused, naming where it looked" "refusing: no harness at $R3/.claude/skills/verify-repo" "$o"; has "... with exit 2" "rc=2" "$o"
R4="$T/copy"; git_init "$R4"; mkdir -p "$R4/.claude/skills"; cp -R "$R/.claude/skills/verify-repo" "$R4/.claude/skills/verify-repo"
o=$(dd0 "$R4" "$V"); has "a DIFFERENT harness of the same name is refused" "refusing: $R4/.claude/skills/verify-repo resolves to" "$o"
NG="$T/nogit"; mkdir -p "$NG"
o=$(dd0 "$NG" "$V"); has "outside any git repo is refused with a reason" "refusing: not inside a git checkout" "$o"; has "... with exit 2" "rc=2" "$o"
# Falsify: restore a path-derived REPO in a COPY; from R2 it must then report
# the canonical checkout's bytes -- the silent wrong answer.
M0="$R/.claude/skills/verify-repo/bin/mutant0"
awk '/^REPO="\$\(git rev-parse/{print "REPO=\"$(cd \"$HERE/../../..\" && pwd)\""; skip=1} skip&&/^cd "\$REPO"/{skip=0} !skip{print}' "$V" > "$M0"; chmod +x "$M0"
chk "guard mutant differs from the real harness" "$(cmp -s "$M0" "$V" && echo same || echo differs)" "differs"
o=$(dd0 "$R2" "$M0"); has "WITHOUT the guard the worktree silently verifies main (guard is load-bearing)" "ok    every URL in .env.verify.local is loopback" "$o"
rm -f "$M0" "$ENVF"

# --- Guard 1: non-loopback refusal -------------------------------------------
echo
echo "GUARD 1: NO URL LEAVES THE MACHINE"
printf 'APP_URL=http://127.0.0.1:9/x\nDB_URL=postgresql://u:p@localhost:5432/d\nV6_URL=http://[::1]:80/\nEMPTY_URL=\n# NOTE_URL=https://commented.example.com\n' > "$ENVF"
o=$(doc); has "loopback URLs (incl. userinfo, ipv6, empty, comment) pass" "ok    every URL in .env.verify.local is loopback" "$o"
printf 'SERVICE_URL=https://api.example.com\n' >> "$ENVF"
o=$(doc); has "external *_URL fails, naming var and host" "SERVICE_URL(api.example.com)" "$o"
has "doctor itself reports FAIL" "doctor: FAIL" "$o"
for bad in 'X_URL=http://localhost@evil.example.com/' 'X_URL=localhost.evil.example.com' 'X_URL="https://evil.example.com"' 'export X_URL=http://evil.example.com' 'WEBHOOK=https://evil.example.com/h' 'X_URL=evil.example.com'; do
  printf 'APP_URL=http://127.0.0.1:9/x\n%s\n' "$bad" > "$ENVF"
  has "refused: $bad" "non-loopback URL(s)" "$(doc)"
done
printf 'APP_URL=http://127.0.0.1:9/x\n' > "$ENVF"
hasnt "corrected env no longer fails the URL check" "non-loopback" "$(doc)"
rm "$ENVF"
o=$(doc); has "no env file means no overrides, said plainly" "ok    no .env.verify.local" "$o"
hasnt "  ...and is not a failure of its own" "FAIL  .env.verify" "$o"
printf 'APP_URL=http://127.0.0.1:9/x\n' > "$ENVF"

# --- Guard 2: sidecar --------------------------------------------------------
echo
echo "GUARD 2: THE SERVER IS THE ONE 'up' STARTED"
node "$R/srv.js" --port "$PORT" >/dev/null 2>&1 & HAND=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://localhost:$PORT" && break; sleep 0.1; done
o=$(doc); has "hand-started server (no sidecar) is refused with a reason" "no sidecar for :$PORT" "$o"
has "... and doctor FAILs" "doctor: FAIL" "$o"
o=$(drv smoke); has "drive refuses on that same reason" "no sidecar" "$o"; has "... with exit 2" "rc=2" "$o"
kill "$HAND"; wait "$HAND" 2>/dev/null

( cd "$R" && PORT="$PORT" exec "$V" up ) >"$T/up.log" 2>&1 & UP=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://localhost:$PORT" && break; sleep 0.1; done
o=$(doc); has "server started by 'up' passes the sidecar" "doctor: PASS" "$o"
has "... and says why: listener is the recorded process" "was started by sidecar pid" "$o"
printf '# touched\n' >> "$ENVF"
o=$(doc); has "env edited after start -> refused, names the env file" ".env.verify.local changed since this server started" "$o"
o=$(drv smoke); has "drive refuses with that reason, not a bare 'doctor failed'" "changed since this server started" "$o"
printf 'APP_URL=http://127.0.0.1:9/x\n' > "$ENVF"
has "env restored byte-for-byte -> passes again" "doctor: PASS" "$(doc)"
echo dirty >> "$R/tracked.txt"
o=$(doc); has "dev server + code moved is a note, not a failure (it hot-reloads)" "note  code moved" "$o"; has "... and still passes" "doctor: PASS" "$o"
git -C "$R" checkout -q -- tracked.txt
SCAR="$R/.claude/.verify-state/server-$PORT"; cp "$SCAR" "$T/sidecar.orig"
# `sed -i.bak` (suffix attached) is the one spelling GNU and BSD sed share.
sed -i.bak 's/^verb=up/verb=serve/' "$SCAR"; echo dirty >> "$R/tracked.txt"
o=$(doc); has "a 'serve' build + code moved -> refused (the stale-commit failure)" "code moved since this 'serve' build" "$o"
git -C "$R" checkout -q -- tracked.txt
has "code back to the recorded state -> serve sidecar passes" "doctor: PASS" "$(doc)"
sed -i.bak 's/^code=.*/code=/' "$SCAR"
has "sidecar with no code state is refused" "records no code state" "$(doc)"
cp "$T/sidecar.orig" "$SCAR"; sed -i.bak 's|^repo=.*|repo=/elsewhere|' "$SCAR"
has "server from another checkout is refused" "server was started from '/elsewhere'" "$(doc)"
cp "$T/sidecar.orig" "$SCAR"; sed -i.bak 's/^pid=.*/pid=1/' "$SCAR"
has "listener that is not the recorded process is refused" "is not the process the sidecar recorded" "$(doc)"
cp "$T/sidecar.orig" "$SCAR"
has "sidecar restored -> passes" "doctor: PASS" "$(doc)"

# --- a scenario must CHECK something -------------------------------------------
echo
echo "DRIVE: VERIFIED MEANS CHECKED AND PASSED"
o=$(drv smoke); has "the generated smoke scenario is VERIFIED against the live app" "VERDICT: VERIFIED (1 checks)" "$o"; has "... exit 0" "rc=0" "$o"
printf '. "$PROBE"\necho "looked around"\n' > "$SC/nothing.sh"
o=$(drv nothing); has "a scenario that made NO checks is NOT VERIFIED, however cleanly it exits" "made no checks" "$o"; has "... exit 1" "rc=1" "$o"
printf '. "$PROBE"\nexpect_ok /\nexpect_text / "this text is not on the page"\nexit 0\n' > "$SC/wrong.sh"
o=$(drv wrong); has "one failing check fails the scenario even when the script exits 0" "1 failed check(s)" "$o"; has "... exit 1" "rc=1" "$o"
printf '. "$PROBE"\nexpect_status /missing 404\nexpect_no_text / "Internal Server Error"\ncheck "true is true" true\n' > "$SC/denial.sh"
o=$(drv denial); has "CONTROL: a denial, a negative and a custom check all pass" "VERDICT: VERIFIED (3 checks)" "$o"
printf '. "$PROBE"\nexpect_status /missing 200\n' > "$SC/denial2.sh"
o=$(drv denial2); has "  ...and the status check can fail (a 404 is not a 200)" "GET /missing -> 404, wanted 200" "$o"
rm -f "$SC/nothing.sh" "$SC/wrong.sh" "$SC/denial.sh" "$SC/denial2.sh"
o=$(drv smoke --bogus x); has "an unknown drive option is refused" "unknown drive option" "$o"

# --- Guard 3: evidence pruning -----------------------------------------------
echo
echo "GUARD 3: EVIDENCE IS PRUNED, NEVER THE RUN BEING WRITTEN"
A="$R/.claude/skills/verify-repo/artifacts"
rm -rf "$A"/smoke-*   # today's runs from the section above would muddy the counts
mk() { for i in $(seq 1 "$2"); do mkdir -p "$A/$1-2020010$((i % 10))T0000$(printf '%02d' "$i")"; done; }
mk smoke 13; mk smoke-b 13; mk t 3
o=$(drv smoke)
chk "default keeps 10 of scenario smoke" "$(/bin/ls "$A" | grep -cE '^smoke-[0-9]{8}T[0-9]{6}$')" "10"
has "prints what it pruned" "pruned: smoke-2020010" "$o"
today=$(date +%Y%m%d)
chk "the run just written survives" "$(/bin/ls "$A" | grep -c "^smoke-${today}T")" "1"
chk "a prefix-sharing scenario (smoke-b) is untouched" "$(/bin/ls "$A" | grep -c '^smoke-b-')" "13"
chk "another scenario is untouched" "$(/bin/ls "$A" | grep -c '^t-')" "3"
o=$(VERIFY_KEEP_RUNS=2 drv smoke); chk "VERIFY_KEEP_RUNS overrides" "$(/bin/ls "$A" | grep -cE '^smoke-[0-9]{8}T[0-9]{6}$')" "2"
o=$(VERIFY_KEEP_RUNS=0 drv smoke); has "KEEP=0 is refused" "must be a positive integer" "$o"
o=$(VERIFY_KEEP_RUNS=abc drv smoke); has "KEEP=abc is refused" "must be a positive integer" "$o"
for i in 1 2 3 4; do mkdir -p "$A/smoke-2099010${i}T000000"; done
o=$(VERIFY_KEEP_RUNS=3 drv smoke)
chk "run being written survives even when it sorts outside the newest N" "$(/bin/ls "$A" | grep -c "^smoke-${today}T")" "1"
M="$R/.claude/skills/verify-repo/bin/mutant"
sed 's/if \[ "\$HERE\/artifacts\/\$d" = "\$cur" \] || \[ "\$n" -lt "\$keep" \]/if [ "$n" -lt "$keep" ]/' "$V" > "$M"; chmod +x "$M"
chk "mutant differs from the real harness" "$(cmp -s "$M" "$V" && echo same || echo differs)" "differs"
( cd "$R" && PORT="$PORT" VERIFY_KEEP_RUNS=3 "$M" drive smoke >/dev/null 2>&1 )
chk "WITHOUT the exclusion the current run is deleted (guard is load-bearing)" "$(/bin/ls "$A" | grep -c "^smoke-${today}T")" "0"
rm -f "$M"
pkill -P "$UP" 2>/dev/null; kill "$UP" 2>/dev/null; wait "$UP" 2>/dev/null; UP=""

# --- `up` serves on THE port, whoever else names one ---------------------------
echo
echo "'up' SERVES ON THE REGISTRY PORT"
newrepo() { # <dir> <package.json>
  mkdir -p "$1"; git -C "$1" init -q; printf '%s\n' "$2" > "$1/package.json"; gcommit "$1"; }
upon() { # <repo> <harness> <port-to-probe> [env PORT]  -> "served" or "silent"
  local d="$1" h="$2" p="$3" pid r=silent
  if [ -n "${4:-}" ]; then ( cd "$d" && PORT="$4" exec "$h" up ) >/dev/null 2>&1 & pid=$!
  else ( cd "$d" && unset PORT && exec "$h" up ) >/dev/null 2>&1 & pid=$!; fi
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$p" && { r=served; break; }; sleep 0.1; done
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf '%s' "$r"; }
LASTPORT="require('http').createServer((q,r)=>r.end('x')).listen(+process.argv[process.argv.lastIndexOf('--port')+1],'127.0.0.1')"
ENVPORT="require('http').createServer((q,r)=>r.end('x')).listen(+process.env.PORT,'127.0.0.1')"
P1=$(free_port)
R5="$T/pinned"; newrepo "$R5" '{"name":"pinned","scripts":{"dev":"node srv.js --port 1"}}'
echo "$LASTPORT" > "$R5/srv.js"
bash "$SCAF" "$R5" >/dev/null 2>&1
chk "a dev script's own --port does not beat PORT" "$(upon "$R5" "$R5/.claude/skills/verify-pinned/bin/verify-pinned" "$P1" "$P1")" served
# Registered BEFORE scaffolding, at a port known to be free, so the harness's
# own default is a port this test can probe.
P2=$(free_port)
R6="$T/envport"; newrepo "$R6" '{"name":"envport","scripts":{"dev":"node srv.js"},"dependencies":{"express":"1"}}'
echo "$ENVPORT" > "$R6/srv.js"
python3 - "$T/cfg/ports.json" "$P2" "$R6" <<'PY'
import json, sys
p, port, key = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(p)); d['repos'][key] = port
json.dump(d, open(p, 'w'))
PY
bash "$SCAF" "$R6" >/dev/null 2>&1
chk "run on its own (no PORT in env), the harness EXPORTS its registry port" \
    "$(upon "$R6" "$R6/.claude/skills/verify-envport/bin/verify-envport" "$P2")" served
chk "  ...with no .env.verify.local at all (overrides are optional)" "$([ -e "$R6/.env.verify.local" ] && echo present || echo absent)" "absent"
# An override file must not be able to move the port: `up` checks one port is
# free, and a PORT sourced afterwards would serve on another while verify.sh
# waited on the first.
printf 'PORT=1\nAPP_URL=http://127.0.0.1:9/x\n' > "$R6/.env.verify.local"
chk "a PORT in .env.verify.local does not move the app off the registry port" \
    "$(upon "$R6" "$R6/.claude/skills/verify-envport/bin/verify-envport" "$P2")" served
rm -f "$R6/.env.verify.local"

# --- a fresh clone verifies with nothing local -----------------------------------
echo
echo "FRESH CLONE: COMMITTED FILES ARE ENOUGH"
gcommit "$R6" "harness"
C="$T/clone"; git clone -q "$R6" "$C"
chk "the clone has the harness and the example, and no local env" \
    "$([ -x "$C/.claude/skills/verify-envport/bin/verify-envport" ] && [ -f "$C/.env.verify.example" ] && [ ! -e "$C/.env.verify.local" ] && echo y)" y
P3=$(free_port)
( cd "$C" && PORT="$P3" exec "$C/.claude/skills/verify-envport/bin/verify-envport" up ) >"$T/clone-up.log" 2>&1 & UP=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://localhost:$P3" && break; sleep 0.1; done
o=$(cd "$C" && PORT="$P3" "$C/.claude/skills/verify-envport/bin/verify-envport" doctor 2>&1; echo "rc=$?")
has "doctor PASSES in a fresh clone with no .env.verify.local" "doctor: PASS" "$o"; has "  ...exit 0" "rc=0" "$o"
pkill -P "$UP" 2>/dev/null; kill "$UP" 2>/dev/null; wait "$UP" 2>/dev/null; UP=""

# --- the harness finds the kit without being told where it is --------------------
echo
echo "KIT DISCOVERY: RUN BY HAND, NO ENV VARS"
CV="$C/.claude/skills/verify-envport/bin/verify-envport"
mkkit() { # <dir> <label> [plugin-name] -- a stand-in kit whose verify.sh says who it is
  mkdir -p "$1/scripts" "$1/.claude-plugin"
  printf '{"name": "%s", "version": "0"}\n' "${3:-bendit}" > "$1/.claude-plugin/plugin.json"
  printf 'echo "fake kit %s ran: $*"\n' "$2" > "$1/scripts/verify.sh"; }
# kitw <extra env...> -- `kit` from the clone, with a clean environment apart from what is given
kitw() { ( cd "$C" && env -u BENDIT_KIT_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CONFIG_DIR HOME="$T/fakehome" "$@" "$CV" kit 2>&1; echo "rc=$?" ); }
mkdir -p "$T/fakehome"
expect_capture "kit discovery: nothing installed -> refused, naming every place searched" \
  env -u BENDIT_KIT_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CONFIG_DIR HOME="$T/fakehome" sh -c 'cd "$1" && "$2" kit' _ "$C" "$CV"
chk "nothing installed -> exit 2" "$EXPECT_CODE" "2"
has "  ...naming the installed-plugin cache it searched" "$T/fakehome/.claude/plugins/cache/*/bendit/*/scripts/verify.sh" "$EXPECT_OUT"
has "  ...and the vendored copy" ".claude/vendor/bendit" "$EXPECT_OUT"
CA="$T/fakehome/.claude/plugins/cache/mk/bendit"
mkkit "$CA/0.9.0" home-0.9.0; mkkit "$CA/0.10.0" home-0.10.0; mkkit "$CA/0.2.0" home-0.2.0
o=$(kitw); has "installed copies under HOME: the highest VERSION wins (0.10.0 > 0.9.0, not text order)" "$CA/0.10.0" "$o"; has "  ...exit 0" "rc=0" "$o"
mkdir -p "$T/nosortv"; printf '#!/bin/sh\nfor a; do [ "$a" = -V ] && { echo "sort: invalid option -- V" >&2; exit 2; }; done\nexec %s "$@"\n' "$(command -v sort)" > "$T/nosortv/sort"; chmod +x "$T/nosortv/sort"
o=$(kitw PATH="$T/nosortv:$PATH"); has "  ...and still with a sort that has no -V (portable fallback)" "$CA/0.10.0" "$o"
mkkit "$T/ccd/plugins/cache/mk/bendit/1.0.0" ccd-1.0.0
o=$(kitw CLAUDE_CONFIG_DIR="$T/ccd"); has "CLAUDE_CONFIG_DIR replaces ~/.claude" "$T/ccd/plugins/cache/mk/bendit/1.0.0" "$o"
mkkit "$T/other" other other-plugin
o=$(kitw CLAUDE_PLUGIN_ROOT="$T/other"); has "CLAUDE_PLUGIN_ROOT of a DIFFERENT plugin is not taken for the kit" "$CA/0.10.0" "$o"
mkkit "$C/.claude/vendor/bendit/plugins/bendit" vendored
o=$(kitw); has "a copy vendored in the repo beats the machine's cache (the repo pins it)" "$C/.claude/vendor/bendit/plugins/bendit" "$o"
mkkit "$T/cpr" cpr
o=$(kitw CLAUDE_PLUGIN_ROOT="$T/cpr"); has "CLAUDE_PLUGIN_ROOT of bendit beats the vendored copy" "$T/cpr" "$o"
mkkit "$T/atkr" atkr
o=$(kitw CLAUDE_PLUGIN_ROOT="$T/cpr" BENDIT_KIT_ROOT="$T/atkr"); has "BENDIT_KIT_ROOT beats everything" "$T/atkr" "$o"
o=$(kitw BENDIT_KIT_ROOT="$T/nope"); has "an BENDIT_KIT_ROOT that is not the kit is refused, not skipped" "BENDIT_KIT_ROOT=$T/nope" "$o"; has "  ...exit 2" "rc=2" "$o"
rm -rf "$C/.claude/vendor"
o=$( (cd "$C" && env -u BENDIT_KIT_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CONFIG_DIR HOME="$T/fakehome" sh .claude/verify-harness) 2>&1; echo "rc=$?")
has "the committed .claude/verify-harness, run by hand with no env vars, runs the installed kit's verify.sh" "fake kit home-0.10.0 ran" "$o"; has "  ...exit 0" "rc=0" "$o"

# --- the skill is named after the project, not the folder --------------------------
echo
echo "NAMING"
N="$T/some-folder"; newrepo "$N" '{"name":"@acme/Notes_Web.App","scripts":{"dev":"node srv.js"},"dependencies":{"express":"1"}}'
o=$(bash "$SCAF" "$N" 2>&1; echo "rc=$?")
chk "a scoped package.json name names the skill (scope stripped, sanitised)" "$([ -d "$N/.claude/skills/verify-notes-web-app" ] && echo y || echo "n: $(/bin/ls "$N/.claude/skills" 2>&1)")" y
has "  ...and the report says where the name came from" 'package.json "name"' "$o"
o=$(bash "$SCAF" "$N" --name custom --force 2>&1; echo "rc=$?")
chk "--name still overrides detection" "$([ -d "$N/.claude/skills/verify-custom" ] && echo y)" y
o=$(bash "$SCAF" "$N" --name 'Bad Name' --dry-run 2>&1; echo "rc=$?"); has "  ...and a bad --name is refused, not rewritten" "rc=2" "$o"

# --kind web with nothing to launch: `up` must refuse, never start nothing and
# succeed (`npm run` with no script name lists the scripts and exits 0).
R7="$T/nodev"; newrepo "$R7" '{"name":"nodev","scripts":{"build":"true"}}'
o=$(bash "$SCAF" "$R7" --kind web 2>&1; echo "rc=$?")
has "--kind web with no launch command is a TODO" "no command to serve this web app" "$o"; has "... and the scaffold exits 3" "rc=3" "$o"
o=$(cd "$R7" && "$R7/.claude/skills/verify-nodev/bin/verify-nodev" up 2>&1; echo "rc=$?")
has "  ...and 'up' REFUSES with a reason" "no command to serve this app" "$o"; has "  ...with exit 2" "rc=2" "$o"
o=$(bash "$SCAF" "$R7" --kind web --force --dev 'node -e "1" --port "$PORT"' 2>&1; echo "rc=$?")
has "--dev supplies the launch command, and the TODO goes away" "rc=0" "$o"
has "  ...with \$PORT left literal for run time" 'exec node -e "1" --port "$PORT"' "$(cat "$R7/.claude/skills/verify-nodev/bin/verify-nodev")"

# --- tests-only shapes ------------------------------------------------------------
echo
echo "LIBRARY / CLI: THE HARNESS RUNS THE PROJECT'S OWN CHECKS"
L="$T/pylib"; mkdir -p "$L/tests" "$L/pylib"; git -C "$L" init -q
printf '[project]\nname = "pylib"\n' > "$L/pyproject.toml"
printf 'def add(a, b):\n    return a + b\n' > "$L/pylib/__init__.py"
printf 'import unittest\nfrom pylib import add\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 2), 4)\n' > "$L/tests/test_add.py"
gcommit "$L"
o=$(bash "$SCAF" "$L" 2>&1; echo "rc=$?"); has "a python library scaffolds cleanly" "rc=0" "$o"
chk "  ...and writes NO app harness (nothing to launch)" "$([ -d "$L/.claude/skills" ] && echo y || echo n)" "n"
# The Stop gate runs a harness only after the PERSON approves it; the scaffold
# is where they first meet it, so it must say how, in their own terminal.
has "  ...and tells the person to approve the harness" "will not run .claude/verify-harness until you approve it" "$o"
has "  ...with the exact --trust command" "require-verification.py --trust" "$o"
has "  ...to run in their own terminal, not via the agent" "YOUR OWN terminal" "$o"
hasnt "  ...and takes no port (no registry key for it)" "$L" "$(cat "$T/cfg/ports.json")"
o=$( (cd "$L" && sh .claude/verify-harness) 2>&1; echo "rc=$?"); has "the generated harness passes when the tests pass" "rc=0" "$o"
has "  ...because it RAN them" "Ran 1 test" "$o"
# A different LENGTH as well as different bytes: a same-size edit in the same
# second leaves a stale .pyc that Python trusts, and the control passes.
sed -i.bak 's/return a + b/return 0/' "$L/pylib/__init__.py"
o=$( (cd "$L" && sh .claude/verify-harness) 2>&1; echo "rc=$?"); hasnt "CONTROL: a broken function fails the harness" "rc=0" "$o"
has "  ...because the test failed" "FAILED (failures=1)" "$o"

echo
echo "NEVER GUESS SILENTLY: A TODO HARNESS REFUSES"
G="$T/golib"; mkdir -p "$G"; git -C "$G" init -q; printf 'module example.com/golib\n\ngo 1.21\n' > "$G/go.mod"; printf 'package golib\n' > "$G/lib.go"
o=$(bash "$SCAF" "$G" 2>&1; echo "rc=$?")
has "a Go module with no tests is a TODO" "no Go tests" "$o"; has "  ...and the scaffold exits 3" "rc=3" "$o"
has "  ...saying the harness refuses until it is filled in" "NOT DONE" "$o"
o=$( (cd "$G" && sh .claude/verify-harness) 2>&1; echo "rc=$?")
has "the generated harness REFUSES (cannot pass by doing nothing)" "rc=2" "$o"; has "  ...naming what to fill in" "TODO(bendit): no Go tests" "$o"
E="$T/empty"; mkdir -p "$E"; git -C "$E" init -q
o=$(bash "$SCAF" "$E" 2>&1; echo "rc=$?"); has "a repo with nothing recognisable is a TODO, exit 3" "rc=3" "$o"
o=$( (cd "$E" && sh .claude/verify-harness) 2>&1; echo "rc=$?"); has "  ...and its harness refuses" "rc=2" "$o"

echo
echo "REFUSALS"
o=$(bash "$SCAF" "$L" 2>&1; echo "rc=$?"); has "an existing harness is not overwritten without --force" "already exists" "$o"; has "  ...exit 2" "rc=2" "$o"
printf '. "$PROBE"\nexpect_ok /\n' > "$R/.claude/skills/verify-repo/scenarios/mine.sh"
bash "$SCAF" "$R" --force >/dev/null 2>&1
chk "--force regenerates but KEEPS the user's scenarios" "$([ -f "$R/.claude/skills/verify-repo/scenarios/mine.sh" ] && echo kept)" "kept"
o=$(bash "$SCAF" "$NG" 2>&1; echo "rc=$?"); has "a folder outside git is refused" "not inside a git repository" "$o"; has "  ...exit 2" "rc=2" "$o"
o=$(bash "$SCAF" "$R" --kind banana 2>&1; echo "rc=$?"); has "a bad --kind is refused" "rc=2" "$o"
o=$(bash "$SCAF" 2>&1; echo "rc=$?"); has "no repo path prints usage" "usage: scaffold-verification-skill.sh" "$o"

echo
echo "THE SHIPPED TEMPLATE (templates/verify-harness)"
TPL="$SD/../templates/verify-harness"
chk "the template parses as sh" "$(sh -n "$TPL" 2>&1; echo $?)" "0"
o=$( (cd "$E" && sh "$TPL") 2>&1; echo "rc=$?"); has "an unedited copy REFUSES (exit 2) rather than passing" "rc=2" "$o"
has "  ...saying what to do" "unedited template" "$o"
# Each shape, uncommented, must at least be valid sh: the examples are meant to
# be copied, and prose that only looks like a harness would be copied too.
for n in 1 2 3; do
  sed -n "/^# --- $n\\./,/^# --- [^$n]/p" "$TPL" | sed -n 's/^#   //p' > "$T/shape$n"
  chk "  ...shape $n, uncommented, parses as sh ($(grep -c . "$T/shape$n") lines)" "$(sh -n "$T/shape$n" 2>&1; [ -s "$T/shape$n" ]; echo $?)" "0"
done

# --- detection, pinned as a snapshot -------------------------------------------
echo
echo "DETECTION (snapshot of what the scaffold says, --dry-run)"
fx() { mkdir -p "$T/fx/$1"; git -C "$T/fx/$1" init -q; }
fx node-pnpm-next; printf '{"scripts":{"dev":"next dev -p 3000","lint":"eslint .","typecheck":"tsc --noEmit","test":"vitest run"},"dependencies":{"next":"15"}}' > "$T/fx/node-pnpm-next/package.json"; touch "$T/fx/node-pnpm-next/pnpm-lock.yaml"
fx node-yarn-vite; printf '{"scripts":{"dev":"vite","test":"vitest run"},"devDependencies":{"vite":"5"}}' > "$T/fx/node-yarn-vite/package.json"; touch "$T/fx/node-yarn-vite/yarn.lock"
fx node-bun-cli; printf '{"bin":{"tool":"bin/tool.js"},"scripts":{"test":"bun test"}}' > "$T/fx/node-bun-cli/package.json"; touch "$T/fx/node-bun-cli/bun.lockb"
fx node-two-locks; printf '{"scripts":{"test":"jest"}}' > "$T/fx/node-two-locks/package.json"; touch "$T/fx/node-two-locks/yarn.lock" "$T/fx/node-two-locks/package-lock.json"
fx node-placeholder; printf '{"scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}' > "$T/fx/node-placeholder/package.json"
fx node-watch-dev; printf '{"scripts":{"dev":"tsc -w","test":"node --test"}}' > "$T/fx/node-watch-dev/package.json"; touch "$T/fx/node-watch-dev/package-lock.json"
fx py-uv-cli; printf '[project]\nname = "c"\n[project.scripts]\nmytool = "c.main:run"\n[tool.ruff]\n[tool.mypy]\n[dependency-groups]\ndev = ["pytest"]\n' > "$T/fx/py-uv-cli/pyproject.toml"; touch "$T/fx/py-uv-cli/uv.lock"; mkdir -p "$T/fx/py-uv-cli/tests"; touch "$T/fx/py-uv-cli/tests/test_main.py"
fx py-poetry-fastapi; printf '[tool.poetry]\nname = "w"\n[tool.poetry.dependencies]\nfastapi = "*"\npytest = "*"\n' > "$T/fx/py-poetry-fastapi/pyproject.toml"; touch "$T/fx/py-poetry-fastapi/poetry.lock" "$T/fx/py-poetry-fastapi/test_app.py"
fx py-django; printf 'django\npytest-django\n' > "$T/fx/py-django/requirements.txt"; touch "$T/fx/py-django/manage.py"; mkdir -p "$T/fx/py-django/app"; touch "$T/fx/py-django/app/test_views.py"
fx py-no-tests; printf '[project]\nname = "n"\n' > "$T/fx/py-no-tests/pyproject.toml"
fx go-cli; printf 'module example.com/c\n' > "$T/fx/go-cli/go.mod"; mkdir -p "$T/fx/go-cli/cmd/c"; printf 'package main\nfunc main() {}\n' > "$T/fx/go-cli/cmd/c/main.go"; printf 'package c\n' > "$T/fx/go-cli/c_test.go"
fx go-web; printf 'module example.com/w\n' > "$T/fx/go-web/go.mod"; printf 'package main\nimport "net/http"\nfunc main() { http.ListenAndServe(":8080", nil) }\n' > "$T/fx/go-web/main.go"; printf 'package main\n' > "$T/fx/go-web/main_test.go"
fx rust-lib; printf '[package]\nname = "r"\n' > "$T/fx/rust-lib/Cargo.toml"; mkdir -p "$T/fx/rust-lib/src"; printf '#[test]\nfn t() {}\n' > "$T/fx/rust-lib/src/lib.rs"
fx make-only; printf 'test:\n\t./run-tests\nlint:\n\t./lint\n' > "$T/fx/make-only/Makefile"
fx nothing
fx name-py-poetry; printf '[project]\nname = "Data_Tool"\n[tool.poetry]\nname = "ignored"\n' > "$T/fx/name-py-poetry/pyproject.toml"; touch "$T/fx/name-py-poetry/test_x.py"
fx name-go-v2; printf 'module example.com/org/svc/v2\n' > "$T/fx/name-go-v2/go.mod"; printf 'package svc\n' > "$T/fx/name-go-v2/s_test.go"
fx name-cargo; printf '[package]\nname = "fast_thing"\n[dependencies]\nname = "not-this"\n' > "$T/fx/name-cargo/Cargo.toml"; mkdir -p "$T/fx/name-cargo/src"; printf '#[test]\nfn t() {}\n' > "$T/fx/name-cargo/src/lib.rs"
fx name-unusable; printf '{"name":"@@@","scripts":{"test":"jest"}}' > "$T/fx/name-unusable/package.json"
fx Name.With_Dots; printf 'test:\n\t./t\n' > "$T/fx/Name.With_Dots/Makefile"
for f in node-pnpm-next node-yarn-vite node-bun-cli node-two-locks node-placeholder node-watch-dev py-uv-cli py-poetry-fastapi py-django py-no-tests go-cli go-web rust-lib make-only nothing name-py-poetry name-go-v2 name-cargo name-unusable Name.With_Dots; do
  expect_capture "$f" bash "$SCAF" "$T/fx/$f" --dry-run
done
expect_capture "node-two-locks with --pm yarn" bash "$SCAF" "$T/fx/node-two-locks" --pm yarn --dry-run
expect_capture "node-watch-dev with --kind library" bash "$SCAF" "$T/fx/node-watch-dev" --kind library --dry-run
chk "--dry-run wrote nothing" "$(/usr/bin/find "$T/fx" -path '*/.claude/*' | wc -l | tr -d ' ')" "0"
expect_verify || fail=$((fail+1))

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
