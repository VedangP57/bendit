#!/usr/bin/env bash
# install.sh: arguments, refusals, and truncation safety.
#
# The installer is piped from curl, so a dropped connection hands bash HALF a
# script. Every statement therefore lives in a function and `main "$@"` is the
# last line; the truncation case proves a cut-off copy runs nothing.
#
# Each run gets a sandbox PATH holding only symlinks to the tools the installer
# is allowed to use, so a missing or stubbed tool is the only way it can see
# the machine. Later tasks extend this file and rely on sandbox, stub and
# run_installer below.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SD/../../../install.sh"
pass=0; fail=0
. "$SD/expect.sh"
expect_init "$SD/install.expected"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
expect_scrub_dir "$T" '<tmp>'

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# sandbox <dir> [tool...]  -- <dir>/{bin,home,proj}; bin links the base tools
# plus each named one. A tool missing from this machine fails the suite.
sandbox() {
  local d="$1" t p; shift
  mkdir -p "$d/bin" "$d/home" "$d/proj"
  for t in bash cat grep sed head tr cut mkdir mktemp mv rm dirname uname env "$@"; do
    p="$(type -P "$t")" || p=""
    if [ -z "$p" ]; then
      printf '  FAIL  sandbox: %s is not installed here, so the suite cannot run\n' "$t"
      fail=$((fail+1)); continue
    fi
    ln -sf "$p" "$d/bin/$t"
  done
}

# stub <dir> <name> <exit> [stdout]  -- replaces <name> in the sandbox with a
# script that logs "<name> <args>" to <dir>/calls.log.
stub() {
  local d="$1" n="$2" code="$3" out="${4:-}"
  rm -f "$d/bin/$n"
  {
    printf '#!/bin/sh\n'
    printf 'echo "%s $*" >> "%s/calls.log"\n' "$n" "$d"
    [ -n "$out" ] && printf 'printf "%%s\\n" "%s"\n' "$out"
    printf 'exit %s\n' "$code"
  } > "$d/bin/$n"
  chmod +x "$d/bin/$n"
}

# The ambient environment must not redirect any run.
unset INSTALL_CWD INSTALL_SCRIPT BENDIT_APP_DIRS TEST_APPS

# run_installer <dir> [args...]  -- PATH is the sandbox alone; stdin is empty.
# BENDIT_APP_DIRS is an empty folder unless TEST_APPS says otherwise, so the
# machine's own Chrome is never seen. INSTALL_CWD (default <dir>/proj) and INSTALL_SCRIPT (default install.sh)
# override where it runs and what it runs.
run_installer() {
  local d="$1"; shift
  ( cd "${INSTALL_CWD:-$d/proj}" && \
    PATH="$d/bin" HOME="$d/home" BENDIT_APP_DIRS="${TEST_APPS:-$d/noapps}" bash "${INSTALL_SCRIPT:-$INSTALL}" "$@" < /dev/null )
}

if [ ! -f "$INSTALL" ]; then
  printf '  FAIL  %s does not exist\n' "$INSTALL"; fail=$((fail+1))
fi

S="$T/s1"; sandbox "$S"
VERSION="$(sed -n 's/^BENDIT_VERSION="\(.*\)"$/\1/p' "$INSTALL" 2>/dev/null)"
PLUGIN_VERSION="$(sed -n 's/^ *"version": *"\(.*\)".*/\1/p' "$SD/../.claude-plugin/plugin.json")"

echo "version and help"
expect_capture "--version" run_installer "$S" --version
chk "--version exits 0"               "$EXPECT_CODE" 0
chk "--version prints the version"    "$EXPECT_STDOUT" "bendit installer $VERSION"
chk "BENDIT_VERSION equals plugin.json" "$VERSION" "$PLUGIN_VERSION"
expect_capture "--help" run_installer "$S" --help
chk "--help exits 0"                  "$EXPECT_CODE" 0
for f in --check --version --help; do
  chk "--help lists $f"               "$(printf '%s' "$EXPECT_STDOUT" | grep -c -- "^  $f ")" 1
done

echo "usage errors"
expect_capture "unknown flag --yes" run_installer "$S" --yes
chk "unknown flag exits 2"            "$EXPECT_CODE" 2
chk "the message names the flag"      "$(printf '%s' "$EXPECT_STDERR" | grep -c -- '--yes')" 1

echo "unsupported OS"
W="$T/win"; sandbox "$W"; stub "$W" uname 0 "MINGW64_NT-10.0"
expect_capture "windows" run_installer "$W"
chk "windows exits 2"                 "$EXPECT_CODE" 2
chk "windows says so"                 "$(printf '%s' "$EXPECT_STDERR" | grep -c 'Windows is not supported yet')" 1

echo "refused locations"
INSTALL_CWD="$S/home" expect_capture "run from HOME" run_installer "$S"
chk "HOME exits 2"                    "$EXPECT_CODE" 2
INSTALL_CWD=/ expect_capture "run from /" run_installer "$S"
chk "/ exits 2"                       "$EXPECT_CODE" 2
ln -s "$S/home" "$T/homelink"
INSTALL_CWD="$T/homelink" expect_capture "run from a symlink to HOME" run_installer "$S"
chk "a symlink to HOME exits 2"       "$EXPECT_CODE" 2

echo "truncated script runs nothing"
R="$T/trunc"; sandbox "$R" ; stub "$R" claude 0
lines="$(wc -l < "$INSTALL" | tr -d ' ')"
head -n $((lines / 2)) "$INSTALL" > "$T/half.sh"
chk "the cut really is a partial script" "$([ "$(tail -n 1 "$T/half.sh")" != 'main "$@"' ] && echo yes || echo no)" yes
INSTALL_SCRIPT="$T/half.sh" run_installer "$R" >/dev/null 2>&1
chk "no tool was called"              "$([ -e "$R/calls.log" ] && echo called || echo none)" none
chk "nothing under .cache"            "$([ -e "$R/home/.cache" ] && echo exists || echo none)" none
# The whole file with its last line removed is the harshest cut: every function is
# defined and none is called.
sed '$d' "$INSTALL" > "$T/nomain.sh"
INSTALL_SCRIPT="$T/nomain.sh" run_installer "$R" --version >/dev/null 2>&1
chk "all functions but no main: silent" "$([ -e "$R/calls.log" ] && echo called || echo none)" none
chk "main is the final line"          "$(tail -n 1 "$INSTALL")" 'main "$@"'
chk "main is the only top-level call" "$(grep -c '^main ' "$INSTALL")" 1

echo "HOME unset"
expect_capture "HOME unset" env -u HOME PATH="$S/bin" bash "$INSTALL" --check
chk "HOME unset exits 2"              "$EXPECT_CODE" 2

# ok_tools <dir> -- the three always-required tools, present and new enough.
ok_tools() {
  stub "$1" claude 0 "2.1.328"; stub "$1" git 0; stub "$1" python3 0 "3.12.1"
}
# real_python <dir> -- the machine's own python3 for the package.json parse; only
# the version query is faked, so the snapshot does not depend on this machine.
real_python() {
  local p; p="$(type -P python3)" || p=""
  if [ -z "$p" ]; then printf '  FAIL  real python3 is not installed here\n'; fail=$((fail+1)); return; fi
  rm -f "$1/bin/python3"
  printf '#!/bin/sh\ncase "$*" in *version_info*) echo 3.12.1 ;; *) exec "%s" "$@" ;; esac\n' "$p" > "$1/bin/python3"
  chmod +x "$1/bin/python3"
}
nodots() { printf '%s' "$1" | grep -c "$2"; }

echo "machine check: all present, not a web project"
C="$T/c1"; sandbox "$C"; ok_tools "$C"
expect_capture "check, all present" run_installer "$C" --check
chk "all present exits 0"             "$EXPECT_CODE" 0
chk "three tools show a tick"         "$(nodots "$EXPECT_STDOUT" '✓')" 3
chk "no node or chrome row"           "$(nodots "$EXPECT_STDOUT" 'node\|chrome')" 0

echo "machine check: missing and too old"
C="$T/c2"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 0 "3.8.10"
expect_capture "check, python too old" run_installer "$C" --check
chk "python 3.8 exits 1"              "$EXPECT_CODE" 1
chk "python3 is listed missing"       "$(nodots "$EXPECT_STDOUT" '^Missing: python3$')" 1
C="$T/c3"; sandbox "$C"; ok_tools "$C"; rm -f "$C/bin/git"
expect_capture "check, no git" run_installer "$C" --check
chk "no git exits 1"                  "$EXPECT_CODE" 1
chk "git is listed missing"           "$(nodots "$EXPECT_STDOUT" '^Missing: git$')" 1
C="$T/c3b"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 0 "3.9.0"
expect_capture "check, python exactly 3.9" run_installer "$C" --check
chk "python 3.9.0 is enough"          "$EXPECT_CODE" 0
C="$T/c3c"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 0 "3.10.1"
expect_capture "check, python 3.10" run_installer "$C" --check
chk "3.10 is newer than 3.9 (numeric)" "$EXPECT_CODE" 0

echo "machine check: web project"
C="$T/w1"; sandbox "$C"; ok_tools "$C"; real_python "$C"; stub "$C" node 0 "v18.19.0"
printf '{"dependencies":{"next":"14.0.0"}}\n' > "$C/proj/package.json"
expect_capture "check, web, old node, no chrome" run_installer "$C" --check
chk "web with old node and no chrome exits 1" "$EXPECT_CODE" 1
chk "node and chrome are listed"      "$(nodots "$EXPECT_STDOUT" '^Missing: node chrome$')" 1
C="$T/w2"; sandbox "$C"; ok_tools "$C"; real_python "$C"; stub "$C" node 0 "v18.19.0"
expect_capture "check, same tools, not web" run_installer "$C" --check
chk "same tools, not a web project, exits 0" "$EXPECT_CODE" 0
chk "node and chrome are not listed"  "$(nodots "$EXPECT_STDOUT" 'node\|chrome')" 0
C="$T/w3"; sandbox "$C"; ok_tools "$C"; real_python "$C"; stub "$C" node 0 "v20.0.0"
printf '{"devDependencies":{"vite":"5"}}\n' > "$C/proj/package.json"
mkdir -p "$C/apps/Google Chrome.app"
TEST_APPS="$C/apps" expect_capture "check, web, all there" run_installer "$C" --check
chk "node 20 and a Chrome app: exits 0" "$EXPECT_CODE" 0
C="$T/w4"; sandbox "$C"; ok_tools "$C"; real_python "$C"
printf '{"scripts":{"dev":"next dev"}}\n' > "$C/proj/package.json"
expect_capture "check, next only in a script" run_installer "$C" --check
chk "next in a script string is not web" "$(nodots "$EXPECT_STDOUT" 'node\|chrome')" 0
C="$T/w5"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 0 "3.8.10"
printf '{"dependencies":{"react":"18"}}\n' > "$C/proj/package.json"
expect_capture "check, grep fallback" run_installer "$C" --check
chk "without python 3.9 the grep fallback still sees react" "$(nodots "$EXPECT_STDOUT" '^Missing: python3 node chrome$')" 1
C="$T/w5b"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 0 "3.8.10"
printf '{"scripts":{"dev":"next"}}\n' > "$C/proj/package.json"
expect_capture "check, grep fallback, next as a script value" run_installer "$C" --check
chk "the grep fallback needs a key, not a value" "$(nodots "$EXPECT_STDOUT" '^Missing: python3$')" 1
C="$T/w6"; sandbox "$C"; ok_tools "$C"; : > "$C/proj/index.html"
expect_capture "check, index.html" run_installer "$C" --check
chk "an index.html makes it a web project" "$(nodots "$EXPECT_STDOUT" '^Missing: node chrome$')" 1

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
