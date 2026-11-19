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

# run_installer <dir> [args...]  -- PATH is the sandbox alone; stdin is empty.
# INSTALL_CWD (default <dir>/proj) and INSTALL_SCRIPT (default install.sh)
# override where it runs and what it runs.
run_installer() {
  local d="$1"; shift
  ( cd "${INSTALL_CWD:-$d/proj}" && \
    PATH="$d/bin" HOME="$d/home" bash "${INSTALL_SCRIPT:-$INSTALL}" "$@" < /dev/null )
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
chk "nothing under .cache"            "$(/usr/bin/find "$R/home/.cache" 2>/dev/null | wc -l | tr -d ' ')" 0
# The whole file with its last line removed is the harshest cut: every function is
# defined and none is called.
sed '$d' "$INSTALL" > "$T/nomain.sh"
INSTALL_SCRIPT="$T/nomain.sh" run_installer "$R" --version >/dev/null 2>&1
chk "all functions but no main: silent" "$([ -e "$R/calls.log" ] && echo called || echo none)" none
chk "main is the final line"          "$(tail -n 1 "$INSTALL")" 'main "$@"'
chk "main is the only top-level call" "$(grep -c '^main ' "$INSTALL")" 1

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
