#!/usr/bin/env bash
# Tests for ports.py and verify.sh's use of it.
#
# "No two blocks overlap" and "an unregistered repo is refused by `port`" would each pass
# against a broken implementation on their own -- the first because a small
# registry happens to be disjoint, the second because verify.sh refuses plenty
# of things -- so each is paired with a control that must fail, plus the
# worktree and concurrency cases the registry exists for.
#
# HERMETIC: every case points the registry at a temp dir (BENDIT_CONFIG_DIR,
# and XDG_CONFIG_HOME for the default-location case). The user's real registry
# is never read or written.
#
# Never cd's into $TMP: a cd into a directory the trap deletes wedges the shell.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
PORTS="$D/ports.py"
# PY picks the interpreter under test. Left unset, the suite runs on python3 and
# then AGAIN on /usr/bin/python3 (3.9 on macOS): a `Path | None` annotation once
# made ports.py exit 1 there at import.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
VERIFY="$D/verify.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/xdg-unused"
unset BENDIT_CONFIG_DIR
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
inblock(){ # name port lo hi
  if [ "$2" -gt "$3" ] && [ "$2" -le "$4" ]; then ok "$1 ($2) is inside the block"
  else bad "$1 is inside the block" "$2 not in $3-$4"; fi; }

# reg <config-dir> <block_size> [key:base ...]   writes <config-dir>/ports.json
reg() {
  local dir="$1" size="$2"; shift 2
  local body="" entry
  mkdir -p "$dir"
  while [ $# -gt 0 ]; do
    entry="$1"; shift
    [ -n "$body" ] && body="$body,"
    body="$body\"${entry%:*}\": ${entry##*:}"
  done
  printf '{"block_size": %s, "repos": {%s}}\n' "$size" "$body" > "$dir/ports.json"
}
P() { local dir="$1"; shift; BENDIT_CONFIG_DIR="$dir" "$PY" "$PORTS" "$@"; }
newgit() { mkdir -p "$1"; git -C "$1" init -q .; git -C "$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init; }

echo "THE PLUGIN FOLDER HOLDS NO PER-USER STATE"
if [ -e "$D/../ports.json" ]; then bad "no ports.json ships in the plugin folder" "$D/../ports.json exists"
else ok "no ports.json ships in the plugin folder"; fi

echo
echo "FIRST USE CREATES THE REGISTRY, IN THE CONFIG DIR"
P "$TMP/fresh" show >/dev/null 2>&1
check "show on a missing registry succeeds" "0" "$?"
got=$("$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['block_size'],len(d['repos']))" "$TMP/fresh/ports.json" 2>&1)
check "  ...and creates it with the default block size and no repos" "100 0" "$got"
env XDG_CONFIG_HOME="$TMP/xdg" "$PY" "$PORTS" where >"$TMP/where.out" 2>&1
check "with no BENDIT_CONFIG_DIR it lives under XDG_CONFIG_HOME" "$TMP/xdg/bendit/ports.json" "$(cat "$TMP/where.out")"
env XDG_CONFIG_HOME="$TMP/xdg" "$PY" "$PORTS" show >/dev/null 2>&1
if [ -f "$TMP/xdg/bendit/ports.json" ]; then ok "  ...and is created there on first use"
else bad "  ...and is created there on first use" "missing"; fi
check "  ...and not under the unused default" "0" "$(/bin/ls -A "$TMP/xdg-unused" 2>/dev/null | wc -l | tr -d ' ')"
mkdir -p "$TMP/badjson"; echo '{not json' > "$TMP/badjson/ports.json"
P "$TMP/badjson" show >/dev/null 2>&1
check "an unreadable registry is REFUSED, never replaced by a default" "2" "$?"
check "  ...and left on disk as it was" "{not json" "$(cat "$TMP/badjson/ports.json")"

echo
echo "NO TWO BLOCKS OVERLAP"
reg "$TMP/bad" 100 "/a:3100" "/b:3150"
P "$TMP/bad" check >/dev/null 2>&1
check "an overlapping registry is REFUSED" "2" "$?"
out=$(P "$TMP/bad" check 2>&1)
case "$out" in *OVERLAP*/a*/b*) ok "  ...and it names both blocks";;
                *) bad "  ...and it names both blocks" "$out";; esac
reg "$TMP/touch" 100 "/a:3100" "/b:3200"
P "$TMP/touch" check >/dev/null 2>&1
check "CONTROL: adjacent blocks do NOT overlap" "0" "$?"
reg "$TMP/same" 100 "/a:3100" "/b:3100"
P "$TMP/same" check >/dev/null 2>&1
check "CONTROL: identical bases are an overlap" "2" "$?"

echo
echo "AN UNREGISTERED REPO IS REFUSED, NEVER GIVEN 3000"
R="$TMP/unreg"; mkdir -p "$R"; git -C "$R" init -q .
reg "$TMP/empty" 100
out=$(P "$TMP/empty" port "$R" 2>&1); rc=$?
check "ports.py refuses it" "2" "$rc"
case "$out" in *"not in the port registry"*) ok "  ...with a reason";;
                *) bad "  ...with a reason" "$out";; esac
case "$out" in *3000*) ok "  ...and says why 3000 is not the answer";;
                *) bad "  ...and says why 3000 is not the answer" "$out";; esac
case "$out" in *"add \"$R\""*) ok "  ...and gives the command that registers it";;
                *) bad "  ...and gives the command that registers it" "$out";; esac
reg "$TMP/okreg" 100 "$R:3100"
check "CONTROL: once registered, the same repo resolves" "3100" "$(P "$TMP/okreg" port "$R" 2>&1)"
# Keyed by path, not folder name: two projects both called `app` must not share.
O="$TMP/elsewhere/unreg"; mkdir -p "$O"; git -C "$O" init -q .
P "$TMP/okreg" port "$O" >/dev/null 2>&1
check "a DIFFERENT repo with the same folder name is not given that block" "2" "$?"

echo
echo "FIRST USE ON A MACHINE: verify.sh REGISTERS THE REPO ITSELF"
# A fresh clone on a fresh machine: scaffolded (and registered) on machine A,
# verified on machine B, whose registry does not exist yet. Refusing here made
# "works in any project" false: every new machine needed a hand-run command.
FR="$TMP/fresh-clone"; mkdir -p "$FR"; git -C "$FR" init -q .
printf '{"name":"fresh-clone","scripts":{"dev":"node srv.js"},"dependencies":{"express":"1"}}\n' > "$FR/package.json"
echo "require('http').createServer((q,r)=>r.end('<h1>fresh</h1>')).listen(+process.env.PORT,'127.0.0.1')" > "$FR/srv.js"
BENDIT_CONFIG_DIR="$TMP/machineA" bash "$D/scaffold-verification-skill.sh" "$FR" >/dev/null 2>&1
git -C "$FR" add -A; git -C "$FR" -c user.email=t@example.com -c user.name=t commit -qm init
FB="$FR/.claude/skills/verify-fresh-clone/bin/verify-fresh-clone"
if curl -s -o /dev/null --max-time 2 http://localhost:3100; then
  bad "precondition: :3100 (a fresh registry's first block) must be free for this case" "something answers on 3100; stop it and re-run"
fi
vfy() { ( cd "$FR" && BENDIT_CONFIG_DIR="$1" BENDIT_KIT_ROOT="$D/.." BENDIT_VERIFY_LOCKDIR="$TMP/slots-fresh" BENDIT_APP_WAIT=20 "$FB" verify 2>&1; echo "rc=$?" ); }
out=$(vfy "$TMP/machineB")
case "$out" in *"rc=0"*) ok "verify on a machine with NO registry proceeds and passes";;
                *) bad "verify on a machine with NO registry proceeds and passes" "$(printf '%s' "$out" | tail -5)";; esac
case "$out" in *"assigned port 3100"*"$TMP/machineB/ports.json"*) ok "  ...saying which port it assigned and where the registry is";;
                *) bad "  ...saying which port it assigned and where the registry is" "$(printf '%s' "$out" | head -5)";; esac
case "$out" in *"1/1 verified"*) ok "  ...and the scenarios really ran";;
                *) bad "  ...and the scenarios really ran" "$(printf '%s' "$out" | tail -3)";; esac
check "  ...and the repo is now in that registry" "3100" "$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['repos'].get(sys.argv[2],'MISSING'))" "$TMP/machineB/ports.json" "$FR")"
out=$(vfy "$TMP/machineB")
case "$out" in *assigned*) bad "a second run assigns nothing new" "$(printf '%s' "$out" | grep assigned)";;
                *) ok "a second run assigns nothing new (same block, no message)";; esac
# CONTROL: allocation that genuinely cannot happen still refuses, with the reason.
# A registry dir UNDER A FILE cannot be created by anyone, root included.
: > "$TMP/notadir"
out=$(vfy "$TMP/notadir/cfg")
case "$out" in *"rc=0"*) bad "CONTROL: an unwritable registry refuses" "exited 0";;
                *) ok "CONTROL: an unwritable registry refuses";; esac
case "$out" in *"could not"*"$TMP/notadir/cfg"*) ok "  ...naming the registry it could not write";;
                *) bad "  ...naming the registry it could not write" "$(printf '%s' "$out" | head -4)";; esac
case "$out" in *assigned*) bad "  ...and claims no assignment" "it said assigned";; *) ok "  ...and claims no assignment";; esac
# CONTROL: no free block left below 65536 is a refusal, not a port past the range.
reg "$TMP/full" 100 "/elsewhere/a:65400"
out=$(P "$TMP/full" ensure "$FR" 2>&1); rc=$?
check "a registry with no free block left refuses (exit 2)" "2" "$rc"
case "$out" in *"no free block"*) ok "  ...saying why";; *) bad "  ...saying why" "$out";; esac
# `port` stays read-only: only `ensure` (and `add`) write.
reg "$TMP/ro-query" 100
P "$TMP/ro-query" port "$FR" >/dev/null 2>&1
check "CONTROL: plain 'port' still refuses an unknown repo (it never writes)" "2" "$?"

echo
echo "WORKTREES: ONE PORT EACH, STABLE ACROSS CALLS"
M="$TMP/main"; newgit "$M"
reg "$TMP/wt" 100 "$M:3100"
git -C "$M" worktree add -q "$TMP/wtA" -b a 2>/dev/null
git -C "$M" worktree add -q "$TMP/wtB" -b b 2>/dev/null
pm=$(P "$TMP/wt" port "$M" 2>&1)
pa=$(P "$TMP/wt" port "$TMP/wtA" 2>&1)
pb=$(P "$TMP/wt" port "$TMP/wtB" 2>&1)
pa2=$(P "$TMP/wt" port "$TMP/wtA" 2>&1)
check "the main checkout takes the block base" "3100" "$pm"
if [ "$pa" != "$pm" ] && [ "$pb" != "$pm" ]; then ok "neither worktree takes the base"
else bad "neither worktree takes the base" "main=$pm A=$pa B=$pb"; fi
if [ "$pa" != "$pb" ]; then ok "two worktrees get DIFFERENT ports (A=$pa B=$pb)"
else bad "two worktrees get different ports" "both got $pa"; fi
check "the same worktree asked twice is stable" "$pa" "$pa2"
inblock "worktree A" "$pa" 3100 3199
inblock "worktree B" "$pb" 3100 3199
if [ -f "$M/.git/bendit-ports.json" ]; then ok "assignments live in the main checkout's .git"
else bad "assignments live in the main checkout's .git" "no $M/.git/bendit-ports.json"; fi

echo
echo "A BLOCK THAT RUNS OUT IS REFUSED, NOT WRAPPED"
M2="$TMP/main2"; newgit "$M2"
git -C "$M2" worktree add -q "$TMP/w2A" -b a 2>/dev/null
git -C "$M2" worktree add -q "$TMP/w2B" -b b 2>/dev/null
reg "$TMP/tiny" 2 "$M2:3100"
t1=$(P "$TMP/tiny" port "$TMP/w2A" 2>&1)
P "$TMP/tiny" port "$TMP/w2B" >/dev/null 2>&1
check "block_size 2 fits exactly one worktree, then refuses" "2" "$?"
check "  ...and the one that fit got base+1" "3101" "$t1"

echo
echo "CONCURRENT WORKTREES: NEVER THE SAME PORT"
# Read-pick-write with no lock let two worktrees started together both take
# base+1. Several worktrees, all asked at once, several rounds.
C="$TMP/conc"; newgit "$C"
reg "$TMP/cc" 100 "$C:3100"
for i in 1 2 3 4 5 6 7 8; do git -C "$C" worktree add -q "$TMP/cw$i" -b "c$i" 2>/dev/null; done
dupes=0
for round in 1 2 3 4 5; do
  rm -f "$C/.git/bendit-ports.json"
  for i in 1 2 3 4 5 6 7 8; do
    P "$TMP/cc" port "$TMP/cw$i" > "$TMP/cout.$i" 2>&1 &
  done
  wait
  n=$(cat "$TMP"/cout.* | sort -u | wc -l | tr -d ' ')
  [ "$n" -eq 8 ] || dupes=$((dupes+1))
done
check "8 worktrees asked at once get 8 distinct ports, 5 rounds out of 5" "0" "$dupes"
got=$("$PY" -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$C/.git/bendit-ports.json" 2>&1)
check "  ...and the assignments file records all 8" "8" "$got"

echo
echo "add ALLOCATES A FREE BLOCK, UNDER A LOCK"
A1="$TMP/r-a"; A2="$TMP/r-b"; A3="$TMP/r-c"
for r in "$A1" "$A2" "$A3"; do mkdir -p "$r"; git -C "$r" init -q .; done
reg "$TMP/add" 100 "$A1:3100" "$A2:3200"
check "a new repo gets the next block" "3300" "$(P "$TMP/add" add "$A3" 2>&1)"
check "adding an EXISTING repo returns its block" "3100" "$(P "$TMP/add" add "$A1" 2>&1)"
check "  ...and adding from a subdirectory resolves to the same repo" "3100" "$(mkdir -p "$A1/sub" && P "$TMP/add" add "$A1/sub" 2>&1)"
check "the first repo in a fresh registry gets 3100" "3100" "$(P "$TMP/addfresh" add "$A2" 2>&1)"
# Six scaffolds at once must get six blocks. Without the lock around
# read-allocate-write, two read "next is 3200" and both take it.
reg "$TMP/race" 100
for i in 1 2 3 4 5 6; do mkdir -p "$TMP/race$i"; git -C "$TMP/race$i" init -q .; done
for i in 1 2 3 4 5 6; do P "$TMP/race" add "$TMP/race$i" > "$TMP/rout.$i" 2>&1 & done
wait
check "6 concurrent adds get 6 distinct blocks" "6" "$(cat "$TMP"/rout.* | sort -u | wc -l | tr -d ' ')"
check "  ...and the registry records all 6" "6" "$("$PY" -c "import json,sys;print(len(json.load(open(sys.argv[1]))['repos']))" "$TMP/race/ports.json")"
P "$TMP/race" check >/dev/null 2>&1
check "  ...with no overlap" "0" "$?"

echo
echo "WORKTREE HARNESS FALLBACK: USE THE MAIN CHECKOUT'S, OR REFUSE"
W="$TMP/wtmain"; newgit "$W"
mkdir -p "$W/.claude/skills/verify-wtmain/bin"
HB="$W/.claude/skills/verify-wtmain/bin/verify-wtmain"
git -C "$W" worktree add -q "$TMP/wtkid" -b kid 2>/dev/null
reg "$TMP/wtreg" 100 "$W:3100"
# A PATH-derived harness would serve its own checkout -> must refuse.
printf '#!/usr/bin/env bash\nHERE="$(cd "$(dirname "$0")/.." && pwd)"\nREPO="$(cd "$HERE/../../.." && pwd)"\ncd "$REPO" || exit 1\nPORT=${PORT:-3000}\necho up\n' > "$HB"
chmod +x "$HB"
out=$( (cd "$TMP/wtkid" && BENDIT_CONFIG_DIR="$TMP/wtreg" bash "$VERIFY") 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then ok "a PATH-derived fallback harness is REFUSED"
else bad "a PATH-derived fallback harness is REFUSED" "exited 0"; fi
case "$out" in *"ITS OWN checkout"*) ok "  ...saying it would serve the wrong tree";;
                *) bad "  ...saying it would serve the wrong tree" "$(printf '%s' "$out" | head -2)";; esac
# CONTROL: a git-derived harness honours the cwd, so it must be ACCEPTED.
# Without this control the refusal above could be refusing every fallback.
printf '#!/usr/bin/env bash\nREPO="$(git rev-parse --show-toplevel)"\ncd "$REPO" || exit 1\nPORT=${PORT:-3000}\necho up\n' > "$HB"
chmod +x "$HB"
out=$( (cd "$TMP/wtkid" && BENDIT_CONFIG_DIR="$TMP/wtreg" BENDIT_VERIFY_LOCKDIR="$TMP/slots" BENDIT_APP_WAIT=1 bash "$VERIFY") 2>&1 )
case "$out" in *"ITS OWN checkout"*) bad "CONTROL: a git-derived fallback is accepted" "still refused";;
                *) ok "CONTROL: a git-derived fallback is NOT refused for that reason";; esac
case "$out" in *"no harness in this worktree; using"*) ok "  ...and it says which checkout's harness it used";;
                *) bad "  ...and it says which checkout's harness it used" "$(printf '%s' "$out" | head -2)";; esac

echo
echo "audit: EVERY KEY MUST BE AN EXISTING DIRECTORY"
reg "$TMP/aud" 100 "$A1:3100" "$A2:3200"
P "$TMP/aud" audit >/dev/null 2>&1
check "a registry of existing checkouts passes the audit" "0" "$?"
reg "$TMP/audbad" 100 "$A1:3100" "$TMP/definitely-gone:9900"
out=$(P "$TMP/audbad" audit 2>&1); rc=$?
check "CONTROL: a key whose checkout is gone FAILS the audit" "2" "$rc"
case "$out" in *definitely-gone*9900*) ok "  ...naming the key and its port";;
                *) bad "  ...naming the key and its port" "$out";; esac
P "$TMP/empty" audit >/dev/null 2>&1
check "an EMPTY registry fails the audit; it does not pass vacuously" "2" "$?"

echo
echo "THE SCAFFOLDER WRITES ONLY THE REGISTRY IT IS POINTED AT"
SB="$TMP/scaffold/webapp"; mkdir -p "$SB"; git -C "$SB" init -q .
printf '{"name":"x","scripts":{"dev":"next dev"},"dependencies":{"next":"1"}}\n' > "$SB/package.json"
BENDIT_CONFIG_DIR="$TMP/scfg" bash "$D/scaffold-verification-skill.sh" "$SB" >/dev/null 2>&1
got=$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['repos'].get(sys.argv[2],'MISSING'))" "$TMP/scfg/ports.json" "$SB")
check "scaffolding a web app registers it in BENDIT_CONFIG_DIR" "3100" "$got"
if [ -e "$D/../ports.json" ]; then bad "  ...and creates nothing in the plugin folder" "ports.json appeared"
else ok "  ...and creates nothing in the plugin folder"; fi
check "  ...and nothing under XDG_CONFIG_HOME" "0" "$(/bin/ls -A "$TMP/xdg-unused" 2>/dev/null | wc -l | tr -d ' ')"

if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
