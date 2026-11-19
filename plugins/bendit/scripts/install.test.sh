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
unset INSTALL_CWD INSTALL_SCRIPT INSTALL_STDIN BENDIT_APP_DIRS BENDIT_TTY TEST_APPS

# run_installer <dir> [args...]  -- PATH is the sandbox alone; stdin is empty
# (INSTALL_STDIN names a file to feed instead). BENDIT_TTY defaults to a path that
# cannot be opened, so no run can ever read this terminal's real /dev/tty.
# BENDIT_APP_DIRS is an empty folder unless TEST_APPS says otherwise, so the
# machine's own Chrome is never seen. INSTALL_CWD (default <dir>/proj) and INSTALL_SCRIPT (default install.sh)
# override where it runs and what it runs.
run_installer() {
  local d="$1"; shift
  ( cd "${INSTALL_CWD:-$d/proj}" && \
    PATH="$d/bin" HOME="$d/home" BENDIT_APP_DIRS="${TEST_APPS:-$d/noapps}" BENDIT_TTY="${BENDIT_TTY:-/nonexistent}" \
    bash "${INSTALL_SCRIPT:-$INSTALL}" "$@" < "${INSTALL_STDIN:-/dev/null}" )
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
printf '{"dependencies":{"lodash":"1"}}\n' > "$C/proj/package.json"
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


echo "python3 that does not run, and a hostile json.py"
C="$T/p1"; sandbox "$C"; ok_tools "$C"; stub "$C" python3 1
expect_capture "check, python3 found but broken" run_installer "$C" --check
chk "a python3 that exits 1 is not ok"  "$EXPECT_CODE" 1
chk "the table says it did not run"     "$(nodots "$EXPECT_STDOUT" 'found but did not run')" 1
chk "and it is not called missing"      "$(nodots "$EXPECT_STDOUT" '^✗ python3 *missing')" 0
C="$T/p2"; sandbox "$C"; ok_tools "$C"; real_python "$C"
printf '{"dependencies":{"next":"14"}}\n' > "$C/proj/package.json"
printf 'open("%s/MARKER","w").write("ran")\n' "$C" > "$C/proj/json.py"
run_installer "$C" --check >/dev/null 2>&1
chk "a json.py in the project never runs" "$([ -e "$C/MARKER" ] && echo ran || echo never)" never

# brew_fixes <dir> -- a brew stub that logs and drops a working python3 into bin.
brew_fixes() {
  cat > "$1/bin/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$1/calls.log"
printf '#!/bin/sh\necho 3.12.1\n' > "$1/bin/python3"
chmod +x "$1/bin/python3"
EOF
  chmod +x "$1/bin/brew"
}
# no_python <dir> -- the always-required tools, python3 absent, brew stubbed in.
no_python() { sandbox "$1" chmod; ok_tools "$1"; rm -f "$1/bin/python3"; stub "$1" uname 0 Darwin; }
callsfor() { { grep -c "^$2" "$1/calls.log" 2>/dev/null || true; } | head -n 1; }

echo "ask: python3 missing"
I="$T/i1"; no_python "$I"; brew_fixes "$I"; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install, answer no" run_installer "$I"
chk "no: exits 1"                      "$EXPECT_CODE" 1
chk "no: brew never ran"               "$(callsfor "$I" brew)" 0
chk "no: says python3 is required"     "$(nodots "$EXPECT_STDOUT" 'python3 is required')" 1
chk "no: the command was shown first"  "$(nodots "$EXPECT_STDOUT" 'brew install python@3.13')" 1
I="$T/i1e"; no_python "$I"; brew_fixes "$I"; : > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install, no answer at all" run_installer "$I"
chk "empty answer defaults to no"      "$(callsfor "$I" brew)" 0
chk "empty answer exits 1"             "$EXPECT_CODE" 1
I="$T/i1w"; no_python "$I"; brew_fixes "$I"; printf 'yep\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install, answer yep" run_installer "$I"
chk "only y or yes counts"             "$(callsfor "$I" brew)" 0
I="$T/i2"; no_python "$I"; brew_fixes "$I"; printf 'y\n' > "$I/ans"
stub "$I" uname 0 Darwin
BENDIT_TTY="$I/ans" expect_capture "install, answer yes, brew fixes it" run_installer "$I"
chk "yes: brew ran once"               "$(callsfor "$I" 'brew install python@3.13')" 1
chk "yes: the re-check passes, exit 0" "$EXPECT_CODE" 0
chk "yes: says python3 is ready"       "$(nodots "$EXPECT_STDOUT" 'python3 is ready')" 1
I="$T/i3"; no_python "$I"; stub "$I" brew 0; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install that did not take" run_installer "$I"
chk "did not take: exits 1"            "$EXPECT_CODE" 1
chk "did not take: says so"            "$(nodots "$EXPECT_STDOUT" 'brew said it worked, but python3 is still not found')" 1
I="$T/i3b"; no_python "$I"; stub "$I" brew 7; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install that failed" run_installer "$I"
chk "failed: exits 1"                  "$EXPECT_CODE" 1
chk "failed: names the exit code"      "$(nodots "$EXPECT_STDOUT" 'failed (exit 7)')" 1

echo "ask: web items"
I="$T/i4"; sandbox "$I" chmod; ok_tools "$I"; real_python "$I"
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; mkdir -p "$I/apps/Google Chrome.app"
stub "$I" brew 0; stub "$I" uname 0 Darwin; printf 'n\n' > "$I/ans"
TEST_APPS="$I/apps" BENDIT_TTY="$I/ans" expect_capture "web, node declined" run_installer "$I"
chk "node declined: carries on, exit 0" "$EXPECT_CODE" 0
chk "node declined: browser driver off" "$(nodots "$EXPECT_STDOUT" 'the browser driver will be off')" 1
chk "node declined: brew never ran"    "$(callsfor "$I" brew)" 0
I="$T/i4b"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/python3"; brew_fixes "$I"; stub "$I" uname 0 Darwin
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; printf 'n\nn\nn\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "web project, python3 declined" run_installer "$I"
chk "required still enforced: exit 1"  "$EXPECT_CODE" 1
chk "web items are not asked when a required one is refused" "$(nodots "$EXPECT_STDOUT" 'brew install node')" 0
I="$T/i4c"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/python3"; brew_fixes "$I"; stub "$I" uname 0 Darwin
printf 'y\nn\nn\n' > "$I/ans"; printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"
BENDIT_TTY="$I/ans" expect_capture "answers are read one per question" run_installer "$I"
chk "second answer was its own line"   "$(callsfor "$I" 'brew install python')" 1
chk "then node and chrome declined, exit 0" "$EXPECT_CODE" 0

echo "ask: no terminal"
I="$T/i5"; no_python "$I"; brew_fixes "$I"; printf 'y\n' > "$I/stdin"
INSTALL_STDIN="$I/stdin" BENDIT_TTY=/nonexistent expect_capture "stdin answers are ignored" run_installer "$I"
chk "stdin y: nothing installed"       "$(callsfor "$I" brew)" 0
chk "stdin y: exits 1"                 "$EXPECT_CODE" 1
chk "stdin y: lists what is missing"   "$(nodots "$EXPECT_STDOUT" '^Missing: python3$')" 1
chk "stdin y: shows the command"       "$(nodots "$EXPECT_STDOUT" 'brew install python@3.13')" 1

echo "ask: Linux"
I="$T/i6"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, git missing, apt-get" run_installer "$I"
chk "linux: shows sudo apt-get verbatim" "$(nodots "$EXPECT_STDOUT" '^    sudo apt-get install -y git$')" 1
chk "linux: declined, nothing ran"     "$(callsfor "$I" apt-get)" 0
I="$T/i7"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"; stub "$I" uname 0 Linux; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, git missing, no package manager" run_installer "$I"
chk "no route: points at git-scm.com"  "$(nodots "$EXPECT_STDOUT" 'git-scm.com')" 1
chk "no route: exits 1"                "$EXPECT_CODE" 1
I="$T/i8"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/claude"; printf 'n\n' > "$I/ans"; stub "$I" curl 0
BENDIT_TTY="$I/ans" expect_capture "claude missing" run_installer "$I"
chk "claude: the documented command"   "$(nodots "$EXPECT_STDOUT" 'curl -fsSL https://claude.ai/install.sh | bash')" 1

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
