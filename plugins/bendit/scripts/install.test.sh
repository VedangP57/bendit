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
  for t in bash cat grep sed head tr cut mkdir mktemp mv rm rmdir dirname uname env "$@"; do
    p="$(type -P "$t")" || p=""
    if [ -z "$p" ]; then
      printf '  FAIL  sandbox: %s is not installed here, so the suite cannot run\n' "$t"
      fail=$((fail+1)); continue
    fi
    ln -sf "$p" "$d/bin/$t"
  done
}

# stub <dir> <name> <exit> [stdout]  -- replaces <name> in the sandbox with a
# script that logs "<name> [arg] [arg]..." to <dir>/calls.log: one bracketed
# field per argument, so an argument split on a space logs differently from one
# that arrived whole.
LOGARGS='for a in "$@"; do printf " [%s]" "$a"; done; echo'
stub() {
  local d="$1" n="$2" code="$3" out="${4:-}"
  rm -f "$d/bin/$n"
  {
    printf '#!/bin/sh\n'
    printf '{ printf %%s %s; %s; } >> "%s/calls.log"\n' "$n" "$LOGARGS" "$d"
    [ -n "$out" ] && printf 'printf "%%s\\n" "%s"\n' "$out"
    printf 'exit %s\n' "$code"
  } > "$d/bin/$n"
  chmod +x "$d/bin/$n"
}

# The ambient environment must not redirect any run.
unset INSTALL_CWD INSTALL_SCRIPT INSTALL_STDIN BENDIT_APP_DIRS BENDIT_TTY TEST_APPS BENDIT_SOURCE BENDIT_CACHE BENDIT_REF XDG_CACHE_HOME KIT_SOURCE TEST_SHIMS BENDIT_APPLE_SHIMS

# run_installer <dir> [args...]  -- PATH is the sandbox alone; stdin is empty
# (INSTALL_STDIN names a file to feed instead). BENDIT_TTY defaults to a path that
# cannot be opened, so no run can ever read this terminal's real /dev/tty.
# BENDIT_SOURCE is a folder that does not exist unless KIT_SOURCE names a fixture,
# so no run can reach the network.
# BENDIT_APP_DIRS is an empty folder unless TEST_APPS says otherwise, so the
# machine's own Chrome is never seen. BENDIT_APPLE_SHIMS (where macOS keeps its
# git and python3 stubs) is an empty folder unless TEST_SHIMS says otherwise. INSTALL_CWD (default <dir>/proj) and INSTALL_SCRIPT (default install.sh)
# override where it runs and what it runs.
run_installer() {
  local d="$1"; shift
  ( cd "${INSTALL_CWD:-$d/proj}" && \
    PATH="$d/bin" HOME="$d/home" BENDIT_APP_DIRS="${TEST_APPS:-$d/noapps}" BENDIT_TTY="${BENDIT_TTY:-/nonexistent}" \
    BENDIT_APPLE_SHIMS="${TEST_SHIMS:-$d/noshims}" BENDIT_SOURCE="${KIT_SOURCE:-$d/nokit}" \
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

# The kit fixture: a git repo shaped like bendit, tagged v<version>, standing in
# for the GitHub remote. real_git <dir> swaps the git stub for the machine's git.
KIT="$T/kit"; mkdir -p "$KIT/plugins/bendit/.claude-plugin"
printf '{"version":"%s"}\n' "$VERSION" > "$KIT/plugins/bendit/.claude-plugin/plugin.json"
if command -v git >/dev/null 2>&1; then
  ( cd "$KIT" && git init -q . && git add -A && \
    git -c user.name=t -c user.email=t@t commit -q -m fixture && git tag "v$VERSION" )
else
  printf '  FAIL  git is not installed here, so the fetch tests cannot run\n'; fail=$((fail+1))
fi
real_git() { rm -f "$1/bin/git"; ln -sf "$(type -P git)" "$1/bin/git"; }

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
# CHROMIUM IS NOT CHROME. The driver launches Playwright browser channels
# (chrome, msedge, ...), and none of them is a system Chromium, so a machine
# with only Chromium cannot run a browser scenario. Counting it as Chrome passed
# the check and then failed at the first launch.
C="$T/w3c"; sandbox "$C"; ok_tools "$C"; real_python "$C"; stub "$C" node 0 "v20.0.0"
stub "$C" chromium 0 "Chromium 120"; stub "$C" chromium-browser 0 "Chromium 120"
printf '{"devDependencies":{"vite":"5"}}\n' > "$C/proj/package.json"
mkdir -p "$C/apps/Chromium.app"
TEST_APPS="$C/apps" expect_capture "check, web, Chromium only" run_installer "$C" --check
chk "Chromium alone (on PATH and as an app) is not Chrome: exits 1" "$EXPECT_CODE" 1
chk "  ...listing chrome as missing" "$(nodots "$EXPECT_STDOUT" '^Missing: chrome$')" 1
C="$T/w3g"; sandbox "$C"; ok_tools "$C"; real_python "$C"; stub "$C" node 0 "v20.0.0"
stub "$C" google-chrome 0 "Google Chrome 131"
printf '{"devDependencies":{"vite":"5"}}\n' > "$C/proj/package.json"
expect_capture "check, web, google-chrome on PATH" run_installer "$C" --check
chk "CONTROL: google-chrome on PATH is Chrome: exits 0" "$EXPECT_CODE" 0
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
# The python3 it drops answers only the version query; anything else goes to the
# machine's real python3, so a package.json is still parsed on the re-check.
brew_fixes() {
  local RP; RP="$(type -P python3)" || RP=""
  cat > "$1/bin/brew" <<EOF
#!/bin/sh
{ printf %s brew; $LOGARGS; } >> "$1/calls.log"
printf '#!/bin/sh\ncase "\$*" in *version_info*) echo 3.12.1 ;; *) exec "$RP" "\$@" ;; esac\n' > "$1/bin/python3"
chmod +x "$1/bin/python3"
EOF
  chmod +x "$1/bin/brew"
}
# no_python <dir> -- the always-required tools, python3 absent, brew stubbed in.
no_python() { sandbox "$1" chmod; ok_tools "$1"; rm -f "$1/bin/python3"; stub "$1" uname 0 Darwin; }
# callsfor <dir> <prefix> -- how many logged calls start with <prefix>, read as
# literal text (the log's brackets would be a character class to grep).
callsfor() {
  [ -f "$1/calls.log" ] || { echo 0; return; }
  awk -v p="$2" 'index($0, p) == 1 { n++ } END { print n + 0 }' "$1/calls.log"
}

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
stub "$I" uname 0 Darwin; real_git "$I"
KIT_SOURCE="$KIT" BENDIT_TTY="$I/ans" expect_capture "install, answer yes, brew fixes it" run_installer "$I"
chk "yes: brew ran once"               "$(callsfor "$I" 'brew [install] [python@3.13]')" 1
chk "yes: the re-check passes, exit 0" "$EXPECT_CODE" 0
chk "yes: says python3 is ready"       "$(nodots "$EXPECT_STDOUT" 'python3 is ready')" 1
I="$T/i3"; no_python "$I"; stub "$I" brew 0; printf 'y\n' > "$I/ans"
# The approved command must not inherit fd 3, the terminal ask() reads answers on.
printf 'if (: <&3) 2>/dev/null; then echo "brew fd3 open"; else echo "brew fd3 closed"; fi >> "%s/calls.log"\n' "$I" >> "$I/bin/brew"
sed -i.bak '/^exit /d' "$I/bin/brew"; rm -f "$I/bin/brew.bak"; echo 'exit 0' >> "$I/bin/brew"
BENDIT_TTY="$I/ans" expect_capture "install that did not take" run_installer "$I"
chk "did not take: exits 1"            "$EXPECT_CODE" 1
chk "did not take: brew got no fd 3"   "$(callsfor "$I" 'brew fd3 closed')" 1
chk "did not take: says so"            "$(nodots "$EXPECT_STDOUT" 'brew said it worked, but python3 is still not found')" 1
I="$T/i3b"; no_python "$I"; stub "$I" brew 7; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "install that failed" run_installer "$I"
chk "failed: exits 1"                  "$EXPECT_CODE" 1
chk "failed: names the exit code"      "$(nodots "$EXPECT_STDOUT" 'failed (exit 7)')" 1

echo "ask: web items"
I="$T/i4"; sandbox "$I" chmod; ok_tools "$I"; real_python "$I"
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; mkdir -p "$I/apps/Google Chrome.app"
stub "$I" brew 0; stub "$I" uname 0 Darwin; printf 'n\n' > "$I/ans"; real_git "$I"
KIT_SOURCE="$KIT" TEST_APPS="$I/apps" BENDIT_TTY="$I/ans" expect_capture "web, node declined" run_installer "$I"
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
real_git "$I"
KIT_SOURCE="$KIT" BENDIT_TTY="$I/ans" expect_capture "answers are read one per question" run_installer "$I"
chk "second answer was its own line"   "$(callsfor "$I" 'brew [install] [python')" 1
chk "then node and chrome declined, exit 0" "$EXPECT_CODE" 0
chk "the web project is still web after python3 is installed" "$(nodots "$EXPECT_STDOUT" 'brew install node')" 1
chk "chrome is asked too (third answer)" "$(nodots "$EXPECT_STDOUT" 'brew install --cask google-chrome')" 1
chk "both declined are named"          "$(nodots "$EXPECT_STDOUT" 'Skipping node chrome:')" 1

echo "ask: no terminal"
I="$T/i5"; no_python "$I"; brew_fixes "$I"; printf 'y\n' > "$I/stdin"
INSTALL_STDIN="$I/stdin" BENDIT_TTY=/nonexistent expect_capture "stdin answers are ignored" run_installer "$I"
chk "stdin y: nothing installed"       "$(callsfor "$I" brew)" 0
chk "stdin y: exits 1"                 "$EXPECT_CODE" 1
chk "stdin y: lists what is missing"   "$(nodots "$EXPECT_STDOUT" '^Missing: python3$')" 1
chk "stdin y: shows the command"       "$(nodots "$EXPECT_STDOUT" 'brew install python@3.13')" 1
# A readable terminal that says n, with y on stdin: stdin must not be consulted.
I="$T/i5c"; no_python "$I"; brew_fixes "$I"; printf 'y\n' > "$I/stdin"; printf 'n\n' > "$I/ans"
INSTALL_STDIN="$I/stdin" BENDIT_TTY="$I/ans" expect_capture "terminal n, stdin y" run_installer "$I"
chk "tty n, stdin y: nothing installed" "$(callsfor "$I" brew)" 0
chk "tty n, stdin y: exits 1"           "$EXPECT_CODE" 1
# A terminal with no lines at all must not fall back to stdin.
I="$T/i5d"; no_python "$I"; brew_fixes "$I"; printf 'y\n' > "$I/stdin"; : > "$I/ans"
INSTALL_STDIN="$I/stdin" BENDIT_TTY="$I/ans" expect_capture "empty terminal, stdin y" run_installer "$I"
chk "empty tty, stdin y: nothing installed" "$(callsfor "$I" brew)" 0
# A caller must not choose the answer source through the environment.
I="$T/i5e"; no_python "$I"; brew_fixes "$I"; printf 'n\n' > "$I/ans"; printf 'y\n' > "$I/fd3"
ASK_OPEN=1 BENDIT_TTY="$I/ans" expect_capture "inherited ASK_OPEN and fd 3" run_installer "$I" 3< "$I/fd3"
chk "inherited ASK_OPEN and fd 3 y: brew never ran" "$(callsfor "$I" brew)" 0

echo "fetch and hand over"
# ready_kit <dir> -- a machine that needs nothing, with the real git.
ready_kit() { sandbox "$1"; ok_tools "$1"; claude_reads "$1"; real_git "$1"; }
# claude_reads <dir> -- a claude stub that, when handed over to, also logs the
# first line of its stdin: the hand-over must give it the terminal, never the
# script a curl pipe is feeding the installer.
claude_reads() {
  rm -f "$1/bin/claude"
  {
    printf '#!/bin/sh\n'
    printf '{ printf %%s claude; %s; } >> "%s/calls.log"\n' "$LOGARGS" "$1"
    printf 'case "$1" in\n'
    printf '  --version) echo 2.1.328 ;;\n'
    printf '  --plugin-dir) IFS= read -r l || l="<nothing>"; echo "claude stdin [$l]" >> "%s/calls.log" ;;\n' "$1"
    printf 'esac\n'
  } > "$1/bin/claude"
  chmod +x "$1/bin/claude"
}
handed() { grep '^claude \[--plugin-dir\]' "$1/calls.log" | tail -n 1; }
fed() { grep '^claude stdin ' "$1/calls.log" | tail -n 1; }
REPO_NOTE='not a git repository'
F="$T/f1"; ready_kit "$F"; printf 'typed-at-terminal\n' > "$F/ans"; printf 'echo piped-script\n' > "$F/pipe"
cache_of() { printf '%s/home/.cache/bendit' "$1"; }
clones() { find "$(cache_of "$1")" -maxdepth 1 -name 'v*' 2>/dev/null | wc -l | tr -d ' '; }
( cd "$F/proj" && git init -q . )
INSTALL_STDIN="$F/pipe" KIT_SOURCE="$KIT" BENDIT_TTY="$F/ans" expect_capture "ready, with a terminal" run_installer "$F"
chk "ready: exits 0"                   "$EXPECT_CODE" 0
chk "ready: one clone in the cache"    "$(clones "$F")" 1
chk "ready: the clone is a git repo"   "$(git -C "$(cache_of "$F")/v$VERSION" rev-parse --verify HEAD >/dev/null 2>&1 && echo yes || echo no)" yes
chk "ready: claude is handed over to"  "$(handed "$F")" "claude [--plugin-dir] [$(cache_of "$F")/v$VERSION/plugins/bendit] [/bendit:adopt]"
chk "ready: claude reads the terminal, not the pipe" "$(fed "$F")" "claude stdin [typed-at-terminal]"
chk "ready: the hand-over is the last thing" "$(tail -n 1 "$F/calls.log")" "claude stdin [typed-at-terminal]"
chk "ready: a git repo gets no git-init note" "$(nodots "$EXPECT_STDOUT" "$REPO_NOTE")" 0
chk "ready: nothing new in the project" "$(cd "$F/proj" && git status --porcelain | wc -l | tr -d ' ')" 0
chk "ready: no temp folder left behind" "$(find "$(cache_of "$F")" -name '.fetch.*' | wc -l | tr -d ' ')" 0
mkdir -p "$(cache_of "$F")/v$VERSION/marker-dir"
KIT_SOURCE="$T/gone" BENDIT_TTY="$F/ans" expect_capture "second run" run_installer "$F"
chk "second run: exits 0"              "$EXPECT_CODE" 0
chk "second run: still one clone"      "$(clones "$F")" 1
chk "second run: the source was not asked again" "$(find "$(cache_of "$F")/v$VERSION" -name marker-dir | wc -l | tr -d ' ')" 1
chk "second run: same hand-over"       "$(handed "$F")" "claude [--plugin-dir] [$(cache_of "$F")/v$VERSION/plugins/bendit] [/bendit:adopt]"
chk "second run: two claude calls in all" "$(callsfor "$F" "claude [--plugin-dir]")" 2
chk "second run: no install calls"     "$(callsfor "$F" brew)" 0
F="$T/f2"; ready_kit "$F"; : > "$F/ans"
mkdir -p "$(cache_of "$F")/v$VERSION/plugins"; : > "$(cache_of "$F")/v$VERSION/stale"
KIT_SOURCE="$KIT" BENDIT_TTY="$F/ans" expect_capture "cache without .git" run_installer "$F"
chk "no .git: exits 0"                 "$EXPECT_CODE" 0
chk "not a repo: says /bendit:adopt will offer git init" "$(nodots "$EXPECT_STDOUT" "^This folder is $REPO_NOTE; /bendit:adopt will offer git init.$")" 1
chk "no .git: the stale folder is gone" "$([ -e "$(cache_of "$F")/v$VERSION/stale" ] && echo kept || echo replaced)" replaced
chk "no .git: a fresh clone is there"  "$([ -d "$(cache_of "$F")/v$VERSION/.git" ] && echo yes || echo no)" yes
# A cache inside a git work tree (HOME is a dotfiles repo): an empty v folder must
# not count as a good clone just because a parent repo has commits.
F="$T/f6"; ready_kit "$F"; : > "$F/ans"
( cd "$F/home" && git init -q . && : > seed && git add seed && git -c user.name=t -c user.email=t@t commit -q -m seed )
mkdir -p "$(cache_of "$F")/v$VERSION"
KIT_SOURCE="$KIT" BENDIT_TTY="$F/ans" expect_capture "cache inside a git repo, empty v folder" run_installer "$F"
chk "parent repo: exits 0"             "$EXPECT_CODE" 0
chk "parent repo: replaced by a fresh clone" "$([ -d "$(cache_of "$F")/v$VERSION/.git" ] && echo yes || echo no)" yes
chk "parent repo: the plugin dir exists" "$([ -f "$(cache_of "$F")/v$VERSION/plugins/bendit/.claude-plugin/plugin.json" ] && echo yes || echo no)" yes
F="$T/f7"; ready_kit "$F"; : > "$F/ans"
KIT_SOURCE="$KIT" BENDIT_TTY="$F/ans" run_installer "$F" >/dev/null
rm -f "$(cache_of "$F")/v$VERSION/plugins/bendit/.claude-plugin/plugin.json"
KIT_SOURCE="$KIT" BENDIT_TTY="$F/ans" expect_capture "clone missing plugin.json" run_installer "$F"
chk "no plugin.json: exits 0"          "$EXPECT_CODE" 0
chk "no plugin.json: re-fetched"       "$([ -f "$(cache_of "$F")/v$VERSION/plugins/bendit/.claude-plugin/plugin.json" ] && echo yes || echo no)" yes
F="$T/f3"; ready_kit "$F"; : > "$F/ans"
KIT_SOURCE="$T/gone" BENDIT_TTY="$F/ans" expect_capture "unreachable source" run_installer "$F"
chk "unreachable: exits 1"             "$EXPECT_CODE" 1
chk "unreachable: says so"             "$(nodots "$EXPECT_STDERR" 'could not fetch bendit from')" 1
chk "unreachable: no v folder left"    "$(clones "$F")" 0
chk "unreachable: no temp folder left" "$(find "$(cache_of "$F")" -name '.fetch.*' | wc -l | tr -d ' ')" 0
chk "unreachable: claude not called"   "$(callsfor "$F" "claude [--plugin-dir]")" 0
F="$T/f4"; ready_kit "$F"
KIT_SOURCE="$KIT" BENDIT_TTY=/nonexistent expect_capture "ready, no terminal" run_installer "$F"
chk "no terminal: exits 0"             "$EXPECT_CODE" 0
chk "no terminal: prints the command"  "$(nodots "$EXPECT_STDOUT" '^  claude --plugin-dir .*/plugins/bendit "/bendit:adopt"$')" 1
chk "no terminal: claude not called"   "$(callsfor "$F" "claude [--plugin-dir]")" 0

# handover_choice <stdin> <stderr> [BENDIT_TTY] -- runs the installer's own
# handover_stdin with stdin/stderr each either a real pseudo-terminal ("pty") or
# /dev/null, and prints "<chosen source>|<pty device>". "inherit" means no
# redirect. Needs python3 for the pty; the function text is cut out of $INSTALL.
handover_choice() {
  local fn; fn="$(sed -n '/^handover_stdin() {/,/^}/p' "$INSTALL")"
  python3 -I - "$1" "$2" "${3:-}" "$fn" <<'PY'
import os, pty, subprocess, sys
si, se, bt, fn = sys.argv[1:5]
m, s = pty.openpty()
dev = os.ttyname(s)
null = open(os.devnull)
env = {"PATH": os.environ["PATH"]}
if bt: env["BENDIT_TTY"] = bt
code = fn + '\nhandover_stdin; printf "%s" "${HANDOVER_STDIN:-inherit}"'
r = subprocess.run(["bash", "-c", code], stdin=s if si == "pty" else null,
                   stderr=s if se == "pty" else null, stdout=subprocess.PIPE, env=env)
print("%s|%s" % (r.stdout.decode(), dev))
PY
}
echo "hand-over: where claude reads"
HC="$(handover_choice pty pty)"
chk "stdin is a terminal: no redirect"        "${HC%%|*}" inherit
HC="$(handover_choice null pty)"
chk "piped, stderr a terminal: real device"   "${HC%%|*}" "${HC#*|}"
chk "piped: never the /dev/tty alias"         "$([ "${HC%%|*}" = /dev/tty ] && echo alias || echo real)" real
HC="$(handover_choice null null)"
chk "no terminal at all: /dev/tty fallback"   "${HC%%|*}" /dev/tty
HC="$(handover_choice pty pty /some/seam)"
chk "BENDIT_TTY wins"                         "${HC%%|*}" /some/seam
F="$T/f5"; ready_kit "$F"; printf 'typed-at-terminal\n' > "$F/ans"
mkdir -p "$F/h ome" "$F/my app"; ( cd "$F/my app" && git init -q . )
expect_capture "space in HOME, with a terminal" \
  env -i PATH="$F/bin" HOME="$F/h ome" BENDIT_TTY="$F/ans" BENDIT_SOURCE="$KIT" BENDIT_APP_DIRS="$F/noapps" \
  bash -c 'cd "$1" && bash "$2" </dev/null' _ "$F/my app" "$INSTALL"
chk "space, terminal: exits 0"         "$EXPECT_CODE" 0
chk "space, terminal: claude got the unsplit path" "$(handed "$F")" "claude [--plugin-dir] [$F/h ome/.cache/bendit/v$VERSION/plugins/bendit] [/bendit:adopt]"
chk "space, terminal: claude reads the terminal" "$(fed "$F")" "claude stdin [typed-at-terminal]"
expect_capture "space in HOME, no terminal" \
  env -i PATH="$F/bin" HOME="$F/h ome" BENDIT_TTY=/nonexistent BENDIT_SOURCE="$KIT" BENDIT_APP_DIRS="$F/noapps" \
  bash -c 'cd "$1" && bash "$2" </dev/null' _ "$F/my app" "$INSTALL"
chk "space: exits 0"                   "$EXPECT_CODE" 0
chk "space: the path is quoted so it pastes" "$(nodots "$EXPECT_STDOUT" 'plugin-dir .*h\\ ome/.cache/bendit/v')" 1
chk "space: nothing new in the project" "$(cd "$F/my app" && git status --porcelain | wc -l | tr -d ' ')" 0

echo "ask: Linux"
I="$T/i6"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; stub "$I" sudo 0; stub "$I" id 0 1000; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, git missing, apt-get" run_installer "$I"
chk "linux: shows sudo apt-get verbatim, update first" "$(nodots "$EXPECT_STDOUT" '^    sudo apt-get update && sudo apt-get install -y git$')" 1
chk "linux: declined, nothing ran"     "$(callsfor "$I" apt-get)$(callsfor "$I" sudo)" 00
I="$T/i6y"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; stub "$I" sudo 0; stub "$I" id 0 1000; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, git missing, apt-get, yes" run_installer "$I"
chk "apt yes: sudo apt-get update ran"  "$(callsfor "$I" 'sudo [apt-get] [update]')" 1
chk "apt yes: then the install"         "$(callsfor "$I" 'sudo [apt-get] [install] [-y] [git]')" 1
chk "apt yes: update came first"        "$(grep -n '^sudo' "$I/calls.log" | head -n 1 | cut -d: -f2)" "sudo [apt-get] [update]"
I="$T/i6r"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; stub "$I" id 0 0; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux as root, no sudo" run_installer "$I"
chk "root: no sudo in the command"      "$(nodots "$EXPECT_STDOUT" '^    apt-get update && apt-get install -y git$')" 1
I="$T/i6n"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; stub "$I" id 0 1000; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, no sudo, not root" run_installer "$I"
chk "no sudo: no automatic route"       "$(nodots "$EXPECT_STDOUT" 'Run that now')" 0
chk "no sudo: points at git-scm.com"    "$(nodots "$EXPECT_STDOUT" 'git-scm.com')" 1
chk "no sudo: nothing ran"              "$(callsfor "$I" apt-get)" 0
chk "no sudo: exits 1"                  "$EXPECT_CODE" 1
I="$T/i6p"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" pacman 0; stub "$I" sudo 0; stub "$I" id 0 1000; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, pacman" run_installer "$I"
chk "pacman: installs without a partial upgrade" "$(nodots "$EXPECT_STDOUT" '^    sudo pacman -S --needed --noconfirm git$')" 1
chk "pacman: never -Sy (a partial upgrade)" "$(nodots "$EXPECT_STDOUT" 'pacman -Sy ')" 0
I="$T/i6pf"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" pacman 1; stub "$I" sudo 1; stub "$I" id 0 1000; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, pacman, install fails" run_installer "$I"
chk "pacman failed: the command ran"    "$(callsfor "$I" 'sudo [pacman] [-S] [--needed] [--noconfirm] [git]')" 1
chk "pacman failed: says to upgrade first" "$(nodots "$EXPECT_STDOUT" 'Run `sudo pacman -Syu` yourself first')" 1
I="$T/i6pt"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" pacman 0; stub "$I" sudo 0; stub "$I" id 0 1000
expect_capture "linux, pacman, no terminal" run_installer "$I"
chk "pacman, no terminal: lists the command" "$(nodots "$EXPECT_STDOUT" '^  git: sudo pacman -S --needed --noconfirm git$')" 1
chk "pacman, no terminal: says to upgrade first" "$(nodots "$EXPECT_STDOUT" 'if this fails, run `sudo pacman -Syu` yourself first')" 1
chk "pacman, no terminal: nothing ran"  "$(callsfor "$I" sudo)$(callsfor "$I" pacman)" 00
I="$T/i6pr"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" pacman 0; stub "$I" id 0 0
expect_capture "linux, pacman, root, no terminal" run_installer "$I"
chk "pacman as root: command has no sudo" "$(nodots "$EXPECT_STDOUT" '^  git: pacman -S --needed --noconfirm git$')" 1
chk "pacman as root: hint says pacman -Syu, no sudo" "$(nodots "$EXPECT_STDOUT" 'if this fails, run `pacman -Syu` yourself first')" 1
chk "pacman as root: never mentions sudo" "$(nodots "$EXPECT_STDOUT" 'sudo')" 0
I="$T/i6prf"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"
stub "$I" uname 0 Linux; stub "$I" pacman 1; stub "$I" id 0 0; printf 'y\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, pacman, root, install fails" run_installer "$I"
chk "pacman as root, failed: hint says pacman -Syu, no sudo" "$(nodots "$EXPECT_STDOUT" 'Run `pacman -Syu` yourself first')" 1
chk "pacman as root, failed: never mentions sudo" "$(nodots "$EXPECT_STDOUT" 'sudo')" 0
I="$T/i6dn"; sandbox "$I" chmod; ok_tools "$I"; real_python "$I"; real_git "$I"; claude_reads "$I"
stub "$I" uname 0 Linux; stub "$I" dnf 0; stub "$I" sudo 0; stub "$I" id 0 1000; stub "$I" node 0 "v18.19.0"
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; mkdir -p "$I/apps/Google Chrome.app"; printf 'y\n' > "$I/ans"
KIT_SOURCE="$KIT" TEST_APPS="$I/apps" BENDIT_TTY="$I/ans" expect_capture "linux dnf, node 18" run_installer "$I"
chk "dnf node: no automatic install"    "$(nodots "$EXPECT_STDOUT" 'dnf install -y nodejs')" 0
chk "dnf node: nothing ran"             "$(callsfor "$I" sudo)$(callsfor "$I" dnf)" 00
chk "dnf node: points at nodejs.org"    "$(nodots "$EXPECT_STDOUT" 'nodejs.org')" 1
chk "dnf node: names NodeSource"        "$(nodots "$EXPECT_STDOUT" "dnf's own nodejs .*NodeSource")" 1
chk "dnf node: carries on without it"   "$EXPECT_CODE" 0
I="$T/i6d"; sandbox "$I" chmod; ok_tools "$I"; real_python "$I"; real_git "$I"; claude_reads "$I"
stub "$I" uname 0 Linux; stub "$I" apt-get 0; stub "$I" sudo 0; stub "$I" id 0 1000; stub "$I" node 0 "v18.19.0"
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; mkdir -p "$I/apps/Google Chrome.app"; printf 'y\n' > "$I/ans"
KIT_SOURCE="$KIT" TEST_APPS="$I/apps" BENDIT_TTY="$I/ans" expect_capture "linux apt, node 18" run_installer "$I"
chk "apt node: no automatic install"    "$(nodots "$EXPECT_STDOUT" 'nodejs$')" 0
chk "apt node: nothing ran"             "$(callsfor "$I" sudo)$(callsfor "$I" apt-get)" 00
chk "apt node: points at nodejs.org"    "$(nodots "$EXPECT_STDOUT" 'nodejs.org')" 1
chk "apt node: carries on without it"   "$EXPECT_CODE" 0
I="$T/i7"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/git"; stub "$I" uname 0 Linux; printf 'n\n' > "$I/ans"
BENDIT_TTY="$I/ans" expect_capture "linux, git missing, no package manager" run_installer "$I"
chk "no route: points at git-scm.com"  "$(nodots "$EXPECT_STDOUT" 'git-scm.com')" 1
chk "no route: exits 1"                "$EXPECT_CODE" 1
I="$T/i8"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/claude"; printf 'n\n' > "$I/ans"; stub "$I" curl 0
BENDIT_TTY="$I/ans" expect_capture "claude missing" run_installer "$I"
chk "claude: the documented command"   "$(nodots "$EXPECT_STDOUT" 'curl -fsSL https://claude.ai/install.sh | bash')" 1
I="$T/i9"; sandbox "$I" chmod; ok_tools "$I"; rm -f "$I/bin/claude"; printf 'y\n' > "$I/ans"; stub "$I" curl 22
BENDIT_TTY="$I/ans" expect_capture "claude download fails" run_installer "$I"
chk "failed download: names curl's exit code" "$(nodots "$EXPECT_STDOUT" 'failed (exit 22)')" 1
chk "failed download: never says it worked" "$(nodots "$EXPECT_STDOUT" 'said it worked')" 0
chk "failed download: exits 1"          "$EXPECT_CODE" 1
I="$T/i10"; sandbox "$I" chmod cp; ok_tools "$I"; real_git "$I"; claude_reads "$I"; mv "$I/bin/claude" "$I/new-claude"
printf 'typed-at-terminal\n' > "$I/ans"; printf 'y\n' | cat - "$I/ans" > "$I/ans2"
cat > "$I/bin/curl" <<EOF
#!/bin/sh
{ printf %s curl; $LOGARGS; } >> "$I/calls.log"
echo 'mkdir -p "\$HOME/.local/bin" && cp "$I/new-claude" "\$HOME/.local/bin/claude"'
EOF
chmod +x "$I/bin/curl"
KIT_SOURCE="$KIT" BENDIT_TTY="$I/ans2" expect_capture "claude installed to ~/.local/bin" run_installer "$I"
chk "claude installed: ready"           "$(nodots "$EXPECT_STDOUT" 'claude is ready')" 1
chk "claude installed: says a new shell may need ~/.local/bin" "$(nodots "$EXPECT_STDOUT" 'open a new terminal')" 1
chk "claude installed: handed over"     "$(callsfor "$I" 'claude [--plugin-dir]')" 1
chk "claude installed: exits 0"         "$EXPECT_CODE" 0

echo "git that does not run"
C="$T/g1"; sandbox "$C"; ok_tools "$C"; stub "$C" git 1
expect_capture "check, git found but broken" run_installer "$C" --check
chk "a git that exits 1 is not ok"      "$EXPECT_CODE" 1
chk "git: the table says it did not run" "$(nodots "$EXPECT_STDOUT" '^✗ git *found but did not run')" 1
chk "git is listed missing"             "$(nodots "$EXPECT_STDOUT" '^Missing: git$')" 1

echo "macOS without Command Line Tools"
# no_clt <dir> -- a Mac whose git and python3 are Apple's stubs (BENDIT_APPLE_SHIMS
# points at the sandbox bin) and whose xcode-select -p fails. Running a stub
# would open Apple's install dialog, so neither may be called.
no_clt() {
  sandbox "$1" chmod; ok_tools "$1"; stub "$1" uname 0 Darwin; stub "$1" brew 0
  cat > "$1/bin/xcode-select" <<EOF
#!/bin/sh
{ printf %s xcode-select; $LOGARGS; } >> "$1/calls.log"
case "\$1" in -p) echo "xcode-select: error: unable to get active developer directory" >&2; exit 2 ;; esac
exit 0
EOF
  chmod +x "$1/bin/xcode-select"
}
C="$T/x1"; no_clt "$C"
TEST_SHIMS="$C/bin" expect_capture "check, mac without Command Line Tools" run_installer "$C" --check
chk "no CLT: exits 1"                   "$EXPECT_CODE" 1
chk "no CLT: git and python3 missing"   "$(nodots "$EXPECT_STDOUT" '^Missing: git python3$')" 1
chk "no CLT: the git stub never ran"    "$(callsfor "$C" git)" 0
chk "no CLT: the python3 stub never ran" "$(callsfor "$C" python3)" 0
C="$T/x2"; no_clt "$C"; printf 'y\ny\n' > "$C/ans"
TEST_SHIMS="$C/bin" BENDIT_TTY="$C/ans" expect_capture "mac without Command Line Tools, yes" run_installer "$C"
chk "no CLT: offers xcode-select --install" "$(nodots "$EXPECT_STDOUT" '^    xcode-select --install$')" 1
chk "no CLT: not brew (it needs the tools too)" "$(nodots "$EXPECT_STDOUT" 'brew install')" 0
chk "no CLT: asked once for both"       "$(nodots "$EXPECT_STDOUT" 'Run that now')" 1
chk "no CLT: xcode-select --install ran once" "$(callsfor "$C" 'xcode-select [--install]')" 1
chk "no CLT: says to finish Apple's installer" "$(nodots "$EXPECT_STDOUT" "When Apple's installer finishes, run this again")" 1
chk "no CLT: the stubs never ran"       "$(callsfor "$C" git)$(callsfor "$C" python3)" 00
chk "no CLT: exits 1"                   "$EXPECT_CODE" 1
C="$T/x3"; sandbox "$C"; ok_tools "$C"; stub "$C" uname 0 Darwin; stub "$C" xcode-select 0 /Library/Developer/CommandLineTools
TEST_SHIMS="$C/bin" expect_capture "check, mac with Command Line Tools" run_installer "$C" --check
chk "with CLT: the tools are run"       "$(callsfor "$C" 'git [--version]')" 1
chk "with CLT: exits 0"                 "$EXPECT_CODE" 0

echo "re-check names a version that is still too old"
I="$T/n1"; sandbox "$I" chmod; ok_tools "$I"; real_python "$I"; real_git "$I"; claude_reads "$I"
stub "$I" uname 0 Darwin; stub "$I" brew 0; stub "$I" node 0 "v18.19.0"
printf '{"dependencies":{"next":"14"}}\n' > "$I/proj/package.json"; mkdir -p "$I/apps/Google Chrome.app"; printf 'y\n' > "$I/ans"
KIT_SOURCE="$KIT" TEST_APPS="$I/apps" BENDIT_TTY="$I/ans" expect_capture "node still too old after brew" run_installer "$I"
chk "too old: names what it found"      "$(nodots "$EXPECT_STDOUT" 'brew said it worked, but node is still 18.19.0; bendit needs 20+.')" 1
chk "too old: not called missing"       "$(nodots "$EXPECT_STDOUT" 'still not found')" 0

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))
echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
