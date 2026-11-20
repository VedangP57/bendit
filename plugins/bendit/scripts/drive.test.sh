#!/usr/bin/env bash
# The browser driver (lib/drive/drive.mjs) and its installer (drive-setup.sh).
#
# Proves the driver can BOTH confirm and refute -- a harness that only ever
# passes is indistinguishable from one that is broken -- against a real Chrome
# through the real Playwright that drive-setup.sh installs. Neither is skipped
# when missing: the suite FAILS and says what to install, because a browser
# check that quietly did not run is the false green this kit exists to prevent.
#
# Writes nothing in the repo: every path is made under one mktemp dir (plus one
# short-lived dir under $HOME, the only place that is outside both a working
# directory and the temp dir), and the tracked scenarios carry no baseUrl.
#
# Needs: node, python3, Chrome, and Playwright installed by
#   bash plugins/bendit/scripts/drive-setup.sh
# (into $BENDIT_CACHE when set: point it at a throwaway dir to keep your cache
# untouched).
#
#   bash drive.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
DRIVE="$KIT/lib/drive/drive.mjs"
ST="$KIT/lib/drive/selftest"
SETUP="$SD/drive-setup.sh"
PKG="$KIT/lib/drive/package.json"
W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"
SRV=""; OUTSIDE=""
cleanup() {
  if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; fi  # wait reaps it: no "Terminated" line
  [ -z "$OUTSIDE" ] || rm -rf "$OUTSIDE"
  rm -rf "$W"
}
trap cleanup EXIT
# The registry the driver may ask (its fourth base-URL source) is a throwaway,
# never the person's, and a Claude session's project dir is not this suite's.
export BENDIT_CONFIG_DIR="$W/cfg"
unset CLAUDE_PROJECT_DIR BENDIT_BROWSER_CHANNEL
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }
hasnt() { case "$3" in *"$2"*) chk "$1 (unexpected '$2' in: $3)" y n;; *) chk "$1" n n;; esac; }
# drive <log> <cwd> <args...> -- PORT unset and cwd an unregistered temp dir, so
# the base URL comes only from what the case passes. Prints the exit code.
drive() { local log="$1" cwd="$2"; shift 2; (cd "$cwd" && env -u PORT node "$DRIVE" "$@" >"$log" 2>&1); echo $?; }
scn() { printf '%s\n' "$2" > "$W/$1.json"; }
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
PW_VERSION="$(jget "$PKG" playwrightVersion)"

echo "THE PIN"
chk "lib/drive/package.json pins an exact Playwright version" \
  "$(printf '%s' "$PW_VERSION" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')" "1"
chk "  ...and records the day it was chosen" \
  "$(jget "$PKG" playwrightChosenOn | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')" "1"
# NODE_MIN is the Node that Playwright itself demands; a lower one in the
# installer would wave through a machine the driver cannot run on.
floor="$(python3 -c 'import json,re,sys; print(re.match(r"^>=\s*(\d+)", json.load(open(sys.argv[1]))["engines"]["node"]).group(1))' "$PKG")"
chk "install.sh NODE_MIN is Playwright's engines.node floor ($floor)" \
  "$(sed -n 's/^NODE_MIN=\([0-9][0-9]*\)$/\1/p' "$KIT/../../install.sh")" "$floor"

echo
echo "DRIVE-SETUP.SH (npm is a stub: no network)"
STUB="$W/stubbin"; mkdir -p "$STUB"
# The stub logs its argv, the browser-download switch and its cwd, then lays
# out what a real install leaves: node_modules/playwright/package.json.
cat > "$STUB/npm" <<'EOF'
#!/bin/sh
{ printf 'args=%s\n' "$*"; printf 'skip=%s\n' "${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD:-}"; printf 'cwd=%s\n' "$(pwd -P)"; } >> "$NPM_LOG"
if [ "${NPM_FAIL:-}" = 1 ]; then echo "npm ERR! network unreachable" >&2; exit 1; fi
prefix=""; v=""
while [ $# -gt 0 ]; do
  case "$1" in --prefix) prefix="$2"; shift ;; playwright@*) v="${1#playwright@}" ;; esac
  shift
done
mkdir -p "$prefix/node_modules/playwright"
printf '{"name":"playwright","version":"%s"}\n' "$v" > "$prefix/node_modules/playwright/package.json"
EOF
chmod +x "$STUB/npm"
PROJ="$W/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo a > "$PROJ/a.txt"
git -C "$PROJ" add -A; git -C "$PROJ" -c user.email=t@example.com -c user.name=t commit -qm init
setup() { ( cd "$PROJ" && PATH="$STUB:$PATH" NPM_LOG="$W/npm.log" bash "$SETUP" "$@" 2>&1 ); echo "rc=$?"; }
C1="$W/cache1"
o=$(BENDIT_CACHE="$C1" setup --check)
has "--check on an empty cache exits 1" "rc=1" "$o"; has "  ...saying it is not installed" "not installed" "$o"
chk "  ...and --check installs nothing" "$([ -e "$W/npm.log" ] && echo called || echo silent)" "silent"
o=$(BENDIT_CACHE="$C1" setup)
has "install exits 0" "rc=0" "$o"
D1="$C1/drive/$PW_VERSION"
chk "  ...into <cache>/drive/<pinned version>" "$(jget "$D1/node_modules/playwright/package.json" version 2>&1)" "$PW_VERSION"
has "  ...with exactly the brief's npm command" "args=install --prefix $C1/drive/" "$(cat "$W/npm.log")"
has "  ...for exactly the pinned version" " --no-save playwright@$PW_VERSION" "$(cat "$W/npm.log")"
has "  ...never downloading a browser" "skip=1" "$(cat "$W/npm.log")"
hasnt "  ...and npm never ran in the project (its .npmrc is not ours to read)" "cwd=$PROJ" "$(cat "$W/npm.log")"
chk "  ...and the project is untouched (git status, ignored files included)" \
  "$(git -C "$PROJ" status --porcelain --ignored)" ""
chk "  ...and no install folder is left behind" "$(/usr/bin/find "$C1/drive" -maxdepth 1 -name '.install*' | wc -l | tr -d ' ')" "0"
o=$(BENDIT_CACHE="$C1" setup --check); has "--check after install exits 0" "rc=0" "$o"
n=$(grep -c '^args=' "$W/npm.log")
o=$(BENDIT_CACHE="$C1" setup)
has "re-running is safe: exit 0" "rc=0" "$o"; has "  ...saying it is already installed" "already installed" "$o"
chk "  ...without running npm again" "$(grep -c '^args=' "$W/npm.log")" "$n"
C2="$W/cache2"
o=$(BENDIT_CACHE="$C2" NPM_FAIL=1 setup)
hasnt "a failed npm install does not exit 0" "rc=0" "$o"; has "  ...and shows npm's own error" "network unreachable" "$o"
chk "  ...and leaves no half-made version folder" "$([ -e "$C2/drive/$PW_VERSION" ] && echo left || echo none)" "none"
chk "  ...nor an install folder" "$(/usr/bin/find "$C2/drive" -maxdepth 1 -name '.install*' | wc -l | tr -d ' ')" "0"
has "  ...so --check still says not installed" "rc=1" "$(BENDIT_CACHE="$C2" setup --check)"
o=$(env -u BENDIT_CACHE XDG_CACHE_HOME="$W/xdg" bash -c "cd '$PROJ' && PATH='$STUB:$PATH' NPM_LOG='$W/npm.log' bash '$SETUP'" 2>&1)
chk "without BENDIT_CACHE it uses \$XDG_CACHE_HOME/bendit" "$([ -f "$W/xdg/bendit/drive/$PW_VERSION/node_modules/playwright/package.json" ] && echo y || echo "n: $o")" "y"
o=$(env -u BENDIT_CACHE -u XDG_CACHE_HOME HOME="$W/home" bash -c "cd '$PROJ' && PATH='$STUB:$PATH' NPM_LOG='$W/npm.log' bash '$SETUP'" 2>&1)
chk "  ...and without either, \$HOME/.cache/bendit" "$([ -f "$W/home/.cache/bendit/drive/$PW_VERSION/node_modules/playwright/package.json" ] && echo y || echo "n: $o")" "y"
o=$(BENDIT_CACHE="rel/cache" setup)
has "a relative BENDIT_CACHE is refused (it would land in the project)" "rc=2" "$o"
chk "  ...and nothing was written in the project" "$(git -C "$PROJ" status --porcelain --ignored)" ""
has "an unknown option is refused" "rc=2" "$(setup --bogus)"
# An empty pinned version would make <dir> the drive/ folder itself, which the
# install removes before moving the new one in. A COPY of the kit carries it.
KC="$W/kitcopy-nover"; mkdir -p "$KC/scripts" "$KC/lib/drive"; cp "$SETUP" "$KC/scripts/"
printf '{"playwrightVersion": ""}\n' > "$KC/lib/drive/package.json"
C3="$W/cache3"; mkdir -p "$C3/drive/other"; : > "$C3/drive/other/canary"
n=$(grep -c '^args=' "$W/npm.log")
o=$( ( cd "$PROJ" && BENDIT_CACHE="$C3" PATH="$STUB:$PATH" NPM_LOG="$W/npm.log" bash "$KC/scripts/drive-setup.sh" 2>&1 ); echo "rc=$?")
has "an empty playwrightVersion is refused" "rc=2" "$o"; has "  ...saying it is not a version" "not a version" "$o"
chk "  ...before npm runs" "$(grep -c '^args=' "$W/npm.log")" "$n"
chk "  ...and the drive/ folder's other contents survive" "$([ -e "$C3/drive/other/canary" ] && echo y || echo n)" "y"

# --- no Playwright: needs only node, so it runs on every machine -----------------
echo
echo "NO PLAYWRIGHT: EXIT 2, NAMING drive-setup.sh"
mkdir -p "$W/emptycache"
o=$(BENDIT_CACHE="$W/emptycache" drive "$W/np.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/out-np")
chk "no Playwright in the cache exits 2" "$o" "2"
has "  ...naming drive-setup.sh" "drive-setup.sh" "$(cat "$W/np.log")"
hasnt "  ...never VERIFIED" "VERDICT: VERIFIED" "$(cat "$W/np.log")"

echo
echo "THIS MACHINE CAN DRIVE A BROWSER (fail, never skip)"
if ! command -v node >/dev/null 2>&1; then
  chk "node is installed" "missing" "present"
  echo "$pass passed, $fail failed"; exit 1
fi
if ! bash "$SETUP" --check; then
  chk "Playwright $PW_VERSION is installed -- run: bash $SETUP" "missing" "present"
  echo "$pass passed, $fail failed"; exit 1
fi
chk "Playwright $PW_VERSION is installed" present present

# --- A/B: the tracked scenarios, with --base and NO baseUrl in the file. -----
echo
echo "CONFIRM AND REFUTE"
A=$(drive "$W/a.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/out-a")
if [ "$A" != 0 ] && grep -q 'could not launch' "$W/a.log"; then
  chk "Chrome is installed (the driver launches channel 'chrome')" "$(grep 'could not launch' "$W/a.log" | head -1)" "launched"
  echo "$pass passed, $fail failed"; exit 1
fi
chk "pass.json passes (and --base works with no baseUrl)" "$A" "0"
has "  ...printing VERIFIED" "VERDICT: VERIFIED" "$(cat "$W/a.log")"
chk "  ...leaving its screenshot" "$([ -s "$W/out-a/after.png" ] && echo y || echo n)" "y"
chk "  ...a verdict, a manifest, console and request logs" \
  "$(for f in verdict.md manifest.json console.log requests.log; do [ -e "$W/out-a/$f" ] || printf '%s ' "$f"; done)" ""
chk "  ...and the evidence marker" "$([ -e "$W/out-a/.bendit-drive-evidence" ] && echo y || echo n)" "y"
B=$(drive "$W/b.log" "$W" "$ST/fail.json" --base "file://$ST" --out "$W/out-b")
chk "fail.json fails" "$B" "1"
has "  ...printing NOT VERIFIED" "VERDICT: NOT VERIFIED" "$(cat "$W/b.log")"
chk "  ...with a screenshot of the failing step" "$(/usr/bin/find "$W/out-b" -name 'FAILED-step-*.png' | wc -l | tr -d ' ')" "1"

# --- what the driver needs, said plainly ----------------------------------------
echo
echo "NO CHROME: EXIT 2, SAYING WHICH"
o=$(BENDIT_BROWSER_CHANNEL=nonexistent drive "$W/nc.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/out-a")
chk "a browser that is not there exits 2" "$o" "2"
has "  ...saying which browser it looked for" '"nonexistent"' "$(cat "$W/nc.log")"
has "  ...and how to pick another" "BENDIT_BROWSER_CHANNEL" "$(cat "$W/nc.log")"
hasnt "  ...never VERIFIED" "VERDICT: VERIFIED" "$(cat "$W/nc.log")"
chk "  ...and the previous run's evidence is still there (nothing deleted before launch)" \
  "$([ -s "$W/out-a/after.png" ] && echo y || echo n)" "y"

# --- base URL: --base, then PORT, then scenario.baseUrl, then the registry -------
echo
echo "BASE URL ORDER (never :3000 by default)"
# The steps navigate to an ABSOLUTE file:// URL, so a run passes whatever base it
# chose, and the manifest says which one that was.
ABS='"steps":[{"goto":"file://'"$ST"'/page.html"},{"expectText":"Entities"}]'
scn nobase '{"name":"nobase",'"$ABS"'}'
scn withbase '{"name":"withbase","baseUrl":"http://127.0.0.1:4555",'"$ABS"'}'
base_of() { jget "$1/manifest.json" baseUrl; }
mkdir -p "$W/nowhere"
o=$(drive "$W/bu0.log" "$W/nowhere" "$W/nobase.json" --out "$W/nowhere/out")
chk "no --base, no PORT, no baseUrl, no registry entry: exit 2" "$o" "2"
has "  ...saying there is no base URL" "no base URL" "$(cat "$W/bu0.log")"
hasnt "  ...and never running on a default" "VERDICT" "$(cat "$W/bu0.log")"
( cd "$W" && PORT=4111 node "$DRIVE" "$W/nobase.json" --out "$W/out-p" >"$W/bu1.log" 2>&1 )
chk "PORT is used when it is the only source" "$(base_of "$W/out-p")" "http://localhost:4111"
( cd "$W" && PORT=4111 node "$DRIVE" "$W/withbase.json" --base http://127.0.0.1:4999 --out "$W/out-b1" >"$W/bu2.log" 2>&1 )
chk "--base beats PORT and the scenario" "$(base_of "$W/out-b1")" "http://127.0.0.1:4999"
( cd "$W" && PORT=4111 node "$DRIVE" "$W/withbase.json" --out "$W/out-b2" >"$W/bu3.log" 2>&1 )
chk "PORT beats the scenario's baseUrl" "$(base_of "$W/out-b2")" "http://localhost:4111"
drive "$W/bu4.log" "$W" "$W/withbase.json" --out "$W/out-b3" >/dev/null
chk "the scenario's baseUrl is used without --base or PORT" "$(base_of "$W/out-b3")" "http://127.0.0.1:4555"
REG="$W/regrepo"; mkdir -p "$REG"; git -C "$REG" init -q
rport=$(python3 "$KIT/scripts/ports.py" add "$REG")
drive "$W/bu5.log" "$REG" "$W/nobase.json" --out "$REG/out" >/dev/null
chk "the registry's port for the cwd is the last source" "$(base_of "$REG/out")" "http://localhost:$rport"
drive "$W/bu6.log" "$REG" "$W/withbase.json" --out "$REG/out2" >/dev/null
chk "  ...and the scenario's baseUrl beats it" "$(base_of "$REG/out2")" "http://127.0.0.1:4555"

# --- baseline comparison: must be able to fail, pass, and refuse to self-approve.
echo
echo "BASELINES"
# A scratch copy, so nothing here ever touches a committed baseline.
mkdir -p "$W/bl"; cp "$ST/page.html" "$W/bl/page.html"
python3 - "$ST/pass.json" "$W/bl/scn.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["name"] = "baseline-check"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
run() { drive "$W/bl/log" "$W/bl" scn.json --base "file://$W/bl" --out "$W/bl/out" "$@"; }
BL="$W/bl/scn.json.baselines/after.aria.yml"
C0=$(run);                      grep -q 'NOT COMPARED' "$W/bl/log" && C0w=1 || C0w=0
C1=$(run --require-baseline)
C2=$(run --accept);             [ -s "$BL" ] && C2w=1 || C2w=0
C3=$(run);                      grep -q 'matches baseline' "$W/bl/log" && C3m=1 || C3m=0
sed -i.bak 's/<h1>Entities<\/h1>/<h1>Entities<\/h1><p>Total Entities 82<\/p>/' "$W/bl/page.html"
cmp -s "$ST/page.html" "$W/bl/page.html" && MUT=0 || MUT=1   # positive control: the page really changed
C4=$(run)
grep -q 'baseline.*after.aria.yml' "$W/bl/log" && grep -q '^ *+ *- paragraph: Total Entities 82' "$W/bl/log" && C4d=1 || C4d=0
cp "$BL" "$W/bl/keep"
C5=$(run);                      cmp -s "$BL" "$W/bl/keep" && C5k=1 || C5k=0
chk "no baseline -> exit 0" "$C0" "0";              chk "no baseline -> warned" "$C0w" "1"
chk "--require-baseline fails" "$C1" "1"
chk "--accept fails the run" "$C2" "1";             chk "--accept wrote the baseline" "$C2w" "1"
chk "rerun passes" "$C3" "0";                       chk "rerun matched" "$C3m" "1"
chk "page mutated (control)" "$MUT" "1"
chk "baseline differs -> fails" "$C4" "1";          chk "  ...showing the diff" "$C4d" "1"
chk "a failing run kept the baseline" "$C5k" "1"
drive "$W/cb.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/out-cb" >/dev/null
chk "the committed selftest baseline matches the tracked page" "$(grep -c 'matches baseline' "$W/cb.log")" "1"

# --- expectNotVisible must mean NONE visible, not "the first match is hidden".
echo
echo "STEPS"
scn notvis '{"name":"notvis","steps":[{"goto":"/cases.html"},{"expectNotVisible":{"text":"Delete"},"timeout":1500}]}'
chk "expectNotVisible fails when a LATER match is visible" \
  "$(drive "$W/notvis.log" "$W" notvis.json --base "file://$ST" --out "$W/out-notvis")" "1"
scn empty '{"name":"empty","steps":[]}'
chk "a scenario with no steps fails" "$(drive "$W/empty.log" "$W" empty.json --base "file://$ST" --out "$W/out-empty")" "1"

# --- goto must fail on HTTP >= 400 unless the step expects that status.
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$ST" >"$W/srv.log" 2>"$W/srv.err" & SRV=$!
P=""; for _ in $(seq 1 50); do
  P=$(sed -nE 's/.* port ([0-9]+).*/\1/p' "$W/srv.log" | head -1); [ -n "$P" ] && break; sleep 0.1
done
chk "http server came up (control)" "$([ -n "$P" ] && echo 1 || echo 0)" "1"
H="http://127.0.0.1:${P:-1}"
scn g404 '{"name":"g404","steps":[{"goto":"/no-such-page.html"}]}'
scn g404ok '{"name":"g404ok","steps":[{"goto":"/no-such-page.html","expectStatus":404}]}'
scn g200bad '{"name":"g200bad","steps":[{"goto":"/page.html","expectStatus":404}]}'
scn g200 '{"name":"g200","steps":[{"goto":"/page.html"}]}'
chk "goto 404 fails" "$(drive "$W/g404.log" "$W" g404.json --base "$H" --out "$W/out-g404")" "1"
chk "goto 404 with expectStatus 404 passes" "$(drive "$W/g404ok.log" "$W" g404ok.json --base "$H" --out "$W/out-g404ok")" "0"
chk "goto 200 with expectStatus 404 fails" "$(drive "$W/g200bad.log" "$W" g200bad.json --base "$H" --out "$W/out-g200bad")" "1"
chk "goto 200 passes (control)" "$(drive "$W/g200.log" "$W" g200.json --base "$H" --out "$W/out-g200")" "0"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# --- saved logins: resolved against the scenario's folder, never outside it,
# and never somewhere git would commit. The fixture .gitignore is the one the
# scaffold writes (scaffold-verification-skill.test.sh checks it does).
echo
echo "SAVED STATE (a login is a credential)"
G="$W/stateproj"; mkdir -p "$G/sc/fixtures/auth-state"; git -C "$G" init -q
cp "$ST/page.html" "$G/sc/page.html"
printf '%s\n' '# saveState writes logins here: credentials, never committed.' '*' '!.gitignore' > "$G/sc/fixtures/auth-state/.gitignore"
sstate() { printf '{"name":"%s","steps":[{"goto":"/page.html"},{"saveState":"%s"}]}\n' "$1" "$2" > "$G/sc/$1.json"; }
sstate save fixtures/auth-state/user.json
chk "saveState relative to the scenario's folder (run from the repo root)" "$(drive "$W/ss1.log" "$G" sc/save.json --base "file://$G/sc" --out "$W/out-ss1")" "0"
chk "  ...landed beside the scenario" "$([ -s "$G/sc/fixtures/auth-state/user.json" ] && echo y || echo n)" "y"
chk "  ...not under the working directory" "$([ -e "$G/fixtures" ] && echo y || echo n)" "n"
chk "  ...and git ignores it" "$(git -C "$G" check-ignore -q sc/fixtures/auth-state/user.json && echo ignored || echo tracked)" "ignored"
printf '{"name":"use","storageState":"fixtures/auth-state/user.json","steps":[{"goto":"/page.html"}]}\n' > "$G/sc/use.json"
chk "storageState is read from the scenario's folder too (run from elsewhere)" "$(drive "$W/ss2.log" "$W" "$G/sc/use.json" --base "file://$G/sc" --out "$W/out-ss2")" "0"
sstate up ../escaped.json
chk "saveState outside the scenario's folder refused" "$(drive "$W/ss3.log" "$G" sc/up.json --base "file://$G/sc" --out "$W/out-ss3")" "2"
has "  ...saying why" "REFUSING saveState" "$(cat "$W/ss3.log")"
chk "  ...and nothing was written there" "$([ -e "$G/escaped.json" ] || [ -e "$W/escaped.json" ] && echo y || echo n)" "n"
sstate abs "$W/abs-state.json"
chk "an absolute saveState outside the folder refused" "$(drive "$W/ss4.log" "$G" sc/abs.json --base "file://$G/sc" --out "$W/out-ss4")" "2"
chk "  ...and nothing was written there" "$([ -e "$W/abs-state.json" ] && echo y || echo n)" "n"
printf '{"name":"useup","storageState":"../user.json","steps":[{"goto":"/page.html"}]}\n' > "$G/sc/useup.json"
chk "storageState outside the scenario's folder refused" "$(drive "$W/ss5.log" "$G" sc/useup.json --base "file://$G/sc" --out "$W/out-ss5")" "2"
has "  ...saying why" "REFUSING storageState" "$(cat "$W/ss5.log")"
sstate open plain-user.json
chk "saveState where git would commit it refused" "$(drive "$W/ss6.log" "$G" sc/open.json --base "file://$G/sc" --out "$W/out-ss6")" "2"
has "  ...saying git would commit it" "git would commit" "$(cat "$W/ss6.log")"
chk "  ...and nothing was written" "$([ -e "$G/sc/plain-user.json" ] || [ -e "$G/plain-user.json" ] && echo y || echo n)" "n"

# --- step names are filenames: they must not climb out of the evidence dir.
echo
echo "EVIDENCE DIR GUARDS"
mkdir -p "$W/esc"
scn esc '{"name":"esc","steps":[{"goto":"/page.html"},{"snapshot":"../../escape-snap"},{"screenshot":"../../escape-shot"}]}'
chk "escaping step names: the run itself passes" "$(drive "$W/esc.log" "$W" esc.json --base "file://$ST" --out "$W/esc/out")" "0"
# find's stdout is the answer; its stderr is left visible on purpose.
chk "  ...nothing written outside --out" \
  "$(/usr/bin/find "$W" -name 'escape-*' -not -path "$W/esc/out/*" | wc -l | tr -d ' ')" "0"
chk "  ...evidence still written inside --out" \
  "$(/usr/bin/find "$W/esc/out" -name '*escape-*' | wc -l | tr -d ' ')" "2"

# --- --out is rm -rf'd: a dangerous one must be refused, not obeyed.
# Each case asserts the REASON as well as exit 2: exit 2 alone is also what a
# missing Playwright or a bad base URL gives, so a broken guard could hide behind
# it. Every target that could be a real folder is a stand-in under $W.
ROOTMSG='it is /, $HOME or the repository root'
ANCMSG='it is the working directory or one of its ancestors'
# $HOME is read through os.homedir(), i.e. $HOME: a fake one holds a canary.
# Playwright is then found through the cache that was resolved for the real one.
CACHE_NOW="${BENDIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bendit}"
fakehome() { # <log> <drive.mjs> -- --out is the fake $HOME itself
  ( cd "$W" && env -u PORT HOME="$W/fakehome" BENDIT_CACHE="$CACHE_NOW" node "$2" "$ST/pass.json" \
      --base "file://$ST" --out "$W/fakehome" >"$1" 2>&1 ); echo $?; }
mkdir -p "$W/victim/inner"; : > "$W/victim/canary"
chk "--out .. refused" "$(drive "$W/v1.log" "$W/victim/inner" "$ST/pass.json" --base "file://$ST" --out ..)" "2"
has "  ...as an ancestor of the working directory" "REFUSING --out" "$(cat "$W/v1.log")"; has "  ...(reason)" "$ANCMSG" "$(cat "$W/v1.log")"
chk "  ...left the parent alone" "$([ -e "$W/victim/canary" ] && echo 1 || echo 0)" "1"
chk "--out . (the working directory) refused" "$(drive "$W/v1b.log" "$W/victim/inner" "$ST/pass.json" --base "file://$ST" --out .)" "2"
has "  ...as the working directory" "$ANCMSG" "$(cat "$W/v1b.log")"
# `/` cannot be given a stand-in: the reason is the most this can check. It is
# also refused by the outside-cwd-and-temp and no-marker rules behind it.
chk "--out / refused" "$(drive "$W/v1c.log" "$W" "$ST/pass.json" --base "file://$ST" --out /)" "2"
has "  ...as /" "REFUSING --out /: $ROOTMSG" "$(cat "$W/v1c.log")"
mkdir -p "$W/fakehome"; : > "$W/fakehome/canary"
chk "--out \$HOME refused (a fake \$HOME)" "$(fakehome "$W/v1d.log" "$DRIVE")" "2"
has "  ...as \$HOME" "$ROOTMSG" "$(cat "$W/v1d.log")"
chk "  ...and \$HOME's canary survives" "$([ -e "$W/fakehome/canary" ] && echo y || echo n)" "y"
# CONTROL: the same case against a COPY of drive.mjs with the /-\$HOME-toplevel
# rule removed. The run must then give a different reason (the no-marker rule
# still saves the canary), proving the assertion above reads this rule.
MC="$W/mutantkit/lib/drive"; mkdir -p "$MC"; cp "$KIT/lib/drive/package.json" "$MC/"
grep -v "if (forbidden.includes(out)) refuse(" "$DRIVE" > "$MC/drive.mjs"
chk "  (the mutant really lost the rule)" "$(grep -c 'forbidden.includes(out)' "$MC/drive.mjs")" "0"
VM=$(fakehome "$W/v1m.log" "$MC/drive.mjs")
hasnt "  CONTROL: without the rule the \$HOME reason is gone" "$ROOTMSG" "$(cat "$W/v1m.log")"
# ...and not vacuously: the mutant RAN and was stopped by the next rule (the
# marker), not by a crash or a missing Playwright that also lacks the reason.
chk "  CONTROL: the mutant still refused (exit 2)" "$VM" "2"
has "  CONTROL: ...on the marker rule" ".bendit-drive-evidence" "$(cat "$W/v1m.log")"
chk "  CONTROL: ...and \$HOME's canary survives the mutant" "$([ -e "$W/fakehome/canary" ] && echo y || echo n)" "y"
mkdir -p "$PROJ/sub"
chk "--out <git toplevel> refused" "$(drive "$W/v1e.log" "$PROJ/sub" "$ST/pass.json" --base "file://$ST" --out "$PROJ")" "2"
has "  ...as the repository root" "$ROOTMSG" "$(cat "$W/v1e.log")"
rmdir "$PROJ/sub"
chk "  ...and the repo is untouched" "$(git -C "$PROJ" status --porcelain --ignored)" ""
mkdir -p "$W/victim2"; : > "$W/victim2/keep.txt"
chk "--out <dir holding files, no marker> refused" "$(drive "$W/v2.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/victim2")" "2"
chk "  ...left its files" "$([ -e "$W/victim2/keep.txt" ] && echo 1 || echo 0)" "1"
has "  ...naming the marker it looked for" ".bendit-drive-evidence" "$(cat "$W/v2.log")"
# ...and re-using a real evidence dir still works (harnesses re-run into one).
chk "--out <a previous run's evidence dir> passes" "$(drive "$W/v3.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$W/out-a")" "0"

# A later --out overrides an earlier one: a harness appends its own --out and
# then forwards the caller's arguments, so the caller's must win. OUTSIDE is
# genuinely outside BOTH the working directory and the temp dir -- one under
# $TMPDIR would be allowed by the rule, and the control below would prove
# nothing.
OUTSIDE="$(mktemp -d "$HOME/.bendit-drive-test.XXXXXX")"; OUTSIDE="$(cd "$OUTSIDE" && pwd -P)"
D1=$(drive "$W/o1.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$OUTSIDE/first" --out "$W/out-second")
chk "a later --out overrides an earlier one" "$D1" "0"
chk "  ...it wrote to the LAST --out" "$([ -d "$W/out-second" ] && echo y || echo n)" "y"
chk "  ...and never touched the earlier one" "$([ -d "$OUTSIDE/first" ] && echo y || echo n)" "n"
D2=$(drive "$W/o2.log" "$W" "$ST/pass.json" --base "file://$ST" --out "$OUTSIDE/only")
chk "CONTROL: a lone --out outside the working and temp dirs is refused" "$D2" "2"
has "  ...and says why" "REFUSING --out" "$(cat "$W/o2.log")"

echo
echo "$pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  for f in "$W"/*.log "$W"/bl/log; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done
fi
[ "$fail" -eq 0 ]
