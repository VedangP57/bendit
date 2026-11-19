#!/usr/bin/env bash
# bendit installer. Meant to be piped from curl, so a dropped connection can hand
# bash HALF this file: every statement below lives in a function, and the only
# top-level call is the last line, `main "$@"`. A truncated copy defines some
# functions and runs nothing.
#
# Exit codes: 0 ready (or --check found nothing missing); 1 something required
# is missing or failed; 2 usage error, refused location, unsupported OS.
set -u

BENDIT_VERSION="0.2.0"
NODE_MIN=20

say() { printf '%s\n' "$*"; }

# die <code> <text>
die() {
  local code="$1"; shift
  printf '%s\n' "$*" >&2
  exit "$code"
}

usage() {
  say "bendit installer $BENDIT_VERSION"
  say ""
  say "Usage: install.sh [--check | --version | --help]"
  say ""
  say "  --check     report what is missing; install nothing"
  say "  --version   print the installer version"
  say "  --help      print this help"
}

check_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin|Linux) ;;
    MINGW*|MSYS*|CYGWIN*) die 2 "Windows is not supported yet." ;;
    *) die 2 "Unsupported system: $os. bendit installs on macOS and Linux." ;;
  esac
}

# Running from $HOME or / would make the whole machine "the project".
check_location() {
  local here home
  here="$(pwd -P)"
  home="$(cd "$HOME" 2>/dev/null && pwd -P)" || home=""
  if [ "$here" = "/" ] || { [ -n "$home" ] && [ "$here" = "$home" ]; }; then
    die 2 "Run this from inside a project folder, not from $here."
  fi
}

# ver_ge <found> <min>  -- 0 when found >= min, compared numerically field by field.
ver_ge() {
  local a="${1#v}" b="${2#v}" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    [ "$((10#$x))" -gt "$((10#$y))" ] && return 0
    [ "$((10#$x))" -lt "$((10#$y))" ] && return 1
  done
  return 0
}

# Chrome or Chromium, on PATH or as an app bundle. BENDIT_APP_DIRS (space
# separated) overrides the app folders searched.
find_chrome() {
  local c d
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$c" >/dev/null 2>&1 && return 0
  done
  if [ -n "${BENDIT_APP_DIRS:-}" ]; then
    for d in $BENDIT_APP_DIRS; do
      { [ -e "$d/Google Chrome.app" ] || [ -e "$d/Chromium.app" ]; } && return 0
    done
  else
    for d in /Applications "$HOME/Applications"; do
      { [ -e "$d/Google Chrome.app" ] || [ -e "$d/Chromium.app" ]; } && return 0
    done
  fi
  return 1
}

# 0 when ./package.json names a web framework as a dependency key, or ./index.html
# exists. Read-only. With python3 >= 3.9 the JSON is parsed properly; without it
# the check is a grep for "<name>": anywhere in the file, which is approximate (a
# nested key of the same name would count).
is_web_project() {
  local names="next react vue svelte @sveltejs/kit nuxt astro vite @angular/core solid-js @remix-run/react"
  local n pv hit=""
  [ -e ./index.html ] && return 0
  [ -f ./package.json ] || return 1
  pv="$(python_version)"
  if [ -n "$pv" ] && ver_ge "$pv" 3.9; then
    if hit="$(python3 -I -c '
import json, sys
names = sys.argv[1:]
d = json.load(open("package.json"))
keys = set()
for k in ("dependencies", "devDependencies"):
    v = d.get(k)
    if isinstance(v, dict):
        keys.update(v)
for n in names:
    if n in keys:
        print(n)
        break
' $names 2>/dev/null)"; then
      # Only a name from the list counts; anything else printed is not an answer.
      case " $names " in *" $hit "*) [ -n "$hit" ] && return 0 ;; esac
      return 1
    fi
  fi
  for n in $names; do
    grep -q "\"$n\"[[:space:]]*:" ./package.json 2>/dev/null && return 0
  done
  return 1
}

python_version() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null | head -n 1
}

# row <item> <found-or-empty> <needed> <ok 0|1> <why>
row() {
  local mark="✓" found="$2"
  [ "$4" = 0 ] || mark="✗"
  [ -n "$found" ] || found="missing"
  printf '%s %-8s %-9s %-7s %s\n' "$mark" "$1" "$found" "$3" "$5"
}

# Sets MISSING_REQUIRED and MISSING_WEB (space-separated item names) and prints
# the table.
check_machine() {
  local v ok web=0
  MISSING_REQUIRED=""; MISSING_WEB=""
  is_web_project && web=1
  say "  item     found     needed  why"

  v=""; ok=1
  if command -v claude >/dev/null 2>&1; then
    v="$(claude --version 2>/dev/null | head -n 1 | cut -d' ' -f1)"; ok=0; [ -n "$v" ] || v="found"
  fi
  row claude "$v" any "$ok" "runs the agent bendit plugs into"
  [ "$ok" = 0 ] || MISSING_REQUIRED="$MISSING_REQUIRED claude"

  v=""; ok=1
  if command -v git >/dev/null 2>&1; then v="found"; ok=0; fi
  row git "$v" any "$ok" "reads and records your changes"
  [ "$ok" = 0 ] || MISSING_REQUIRED="$MISSING_REQUIRED git"

  v="$(python_version)"; ok=1
  [ -n "$v" ] && ver_ge "$v" 3.9 && ok=0
  # On PATH but silent: macOS's /usr/bin/python3 shim without Command Line Tools.
  if [ -z "$v" ] && command -v python3 >/dev/null 2>&1; then v="found but did not run"; fi
  row python3 "$v" "3.9+" "$ok" "runs bendit's guards"
  [ "$ok" = 0 ] || MISSING_REQUIRED="$MISSING_REQUIRED python3"

  if [ "$web" = 1 ]; then
    v=""; ok=1
    if command -v node >/dev/null 2>&1; then
      v="$(node --version 2>/dev/null | head -n 1)"; v="${v#v}"
      [ -n "$v" ] && ver_ge "$v" "$NODE_MIN" && ok=0
    fi
    row node "$v" "$NODE_MIN+" "$ok" "drives the browser for a web app"
    [ "$ok" = 0 ] || MISSING_WEB="$MISSING_WEB node"

    ok=1; v=""
    if find_chrome; then ok=0; v="found"; fi
    row chrome "$v" any "$ok" "the browser bendit looks at your app with"
    [ "$ok" = 0 ] || MISSING_WEB="$MISSING_WEB chrome"
  fi
  MISSING_REQUIRED="${MISSING_REQUIRED# }"; MISSING_WEB="${MISSING_WEB# }"
  return 0
}

# ask <question> -- 0 only for y/yes, read from the terminal (BENDIT_TTY is a
# test hook), never from stdin: stdin may be the script itself, piped from curl.
# 1 for anything else; 3 when there is no terminal to ask on.
ask() {
  local a=""
  have_tty || return 3
  [ -n "${ASK_OPEN:-}" ] || { exec 3< "${BENDIT_TTY:-/dev/tty}"; ASK_OPEN=1; }
  printf '%s' "$1"
  IFS= read -r a <&3 || a=""
  case "$a" in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
  return 1
}

# 0 when the terminal can be opened for reading.
have_tty() { ( : < "${BENDIT_TTY:-/dev/tty}" ) 2>/dev/null; }

# install_cmd <item> -- the command for this machine, or nothing.
install_cmd() {
  local item="$1" pm=""
  if [ "$item" = claude ]; then
    command -v curl >/dev/null 2>&1 && say 'curl -fsSL https://claude.ai/install.sh | bash'
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || return 0
      case "$item" in
        python3) say 'brew install python@3.13' ;;
        git)     say 'brew install git' ;;
        node)    say 'brew install node' ;;
        chrome)  say 'brew install --cask google-chrome' ;;
      esac ;;
    Linux)
      for pm in apt-get dnf pacman; do command -v "$pm" >/dev/null 2>&1 && break; pm=""; done
      case "$pm:$item" in
        apt-get:python3) say 'sudo apt-get install -y python3' ;;
        apt-get:git)     say 'sudo apt-get install -y git' ;;
        apt-get:node)    say 'sudo apt-get install -y nodejs' ;;
        dnf:python3)     say 'sudo dnf install -y python3' ;;
        dnf:git)         say 'sudo dnf install -y git' ;;
        dnf:node)        say 'sudo dnf install -y nodejs' ;;
        pacman:python3)  say 'sudo pacman -S --noconfirm python' ;;
        pacman:git)      say 'sudo pacman -S --noconfirm git' ;;
        pacman:node)     say 'sudo pacman -S --noconfirm nodejs' ;;
      esac ;;
  esac
  return 0
}

manual_pointer() {
  case "$1" in
    python3) say "Get Python 3.9 or newer from https://www.python.org/downloads/" ;;
    git)     say "Get git from https://git-scm.com/downloads" ;;
    node)    say "Get Node.js $NODE_MIN or newer from https://nodejs.org/" ;;
    chrome)  say "Get Chrome from https://www.google.com/chrome/" ;;
    claude)  say "See https://code.claude.com/docs/en/setup" ;;
  esac
}

why_missing() {
  case "$1" in
    python3) say "python3 is missing or older than 3.9 (it runs bendit's guards)." ;;
    node)    say "node is missing or older than $NODE_MIN (it drives the browser for a web app)." ;;
    chrome)  say "Chrome is missing (the browser bendit looks at your app with)." ;;
    git)     say "git is missing (it reads and records your changes)." ;;
    claude)  say "claude is missing (the agent bendit plugs into)." ;;
  esac
}

# is_missing <item> -- re-runs the machine check quietly.
is_missing() {
  check_machine >/dev/null
  case " $MISSING_REQUIRED $MISSING_WEB " in *" $1 "*) return 0 ;; esac
  return 1
}

# offer <item> -- 0 installed and verified, 1 declined or no automatic route,
# 2 the install ran but the item is still missing, 3 no terminal.
offer() {
  local item="$1" cmd rc tool
  cmd="$(install_cmd "$item")"
  why_missing "$item"
  if [ -z "$cmd" ]; then
    say "  bendit cannot install it automatically here. $(manual_pointer "$item")"
    return 1
  fi
  say "  To install it, bendit would run:"
  say "    $cmd"
  ask "  Run that now? [y/N] "; rc=$?
  [ "$rc" = 3 ] && return 3
  say ""
  [ "$rc" = 0 ] || return 1
  eval "$cmd" < /dev/null; rc=$?
  # claude installs to ~/.local/bin, which a fresh machine may not have on PATH yet.
  if [ "$item" = claude ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
  fi
  hash -r 2>/dev/null
  if ! is_missing "$item"; then say "  $item is ready."; return 0; fi
  tool="${cmd#sudo }"; tool="${tool%% *}"
  if [ "$rc" = 0 ]; then
    say "  $tool said it worked, but $item is still not found."
  else
    say "  The install command failed (exit $rc), and $item is still not found."
  fi
  return 2
}

# Nothing can be asked: list what is missing and the commands, install nothing.
no_terminal() {
  local item cmd all="$MISSING_REQUIRED $MISSING_WEB"
  all="${all# }"; all="${all% }"
  say ""
  say "Missing: $all"
  for item in $all; do
    cmd="$(install_cmd "$item")"
    if [ -n "$cmd" ]; then say "  $item: $cmd"; else say "  $item: $(manual_pointer "$item")"; fi
  done
  say "There is no terminal to ask on, so nothing was installed. Run the commands"
  say "above yourself, or run this installer from a terminal."
  exit 1
}

# Asks about every missing item; installs only after a yes; re-checks each.
install_missing() {
  local item rc blocked="" web_off=""
  have_tty || no_terminal
  for item in $MISSING_REQUIRED; do
    say ""
    offer "$item"; rc=$?
    [ "$rc" = 3 ] && no_terminal
    [ "$rc" = 0 ] || blocked="$blocked $item"
  done
  if [ -n "$blocked" ]; then
    say ""
    for item in $blocked; do say "$item is required, so bendit cannot go on without it."; done
    say "Install it, then run this again."
    exit 1
  fi
  for item in $MISSING_WEB; do
    say ""
    offer "$item"; rc=$?
    [ "$rc" = 3 ] && no_terminal
    [ "$rc" = 0 ] || web_off="$web_off $item"
  done
  if [ -n "$web_off" ]; then
    say ""
    say "Skipping${web_off}: the browser driver will be off, so bendit cannot look at"
    say "your web app until that is installed. Everything else will work."
  fi
  return 0
}

# Task 4 continues from here: fetch the kit and hand over.
ready() {
  say ""
  say "This machine is ready."
}

main() {
  local check=0 arg
  for arg in "$@"; do
    case "$arg" in
      --version) say "bendit installer $BENDIT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      --check) check=1 ;;
      *) die 2 "Unknown option: $arg (try --help)" ;;
    esac
  done
  check_os
  [ -n "${HOME:-}" ] || die 2 "HOME is not set, so bendit cannot tell where your home folder is. Set HOME and run again."
  check_location
  check_machine
  if [ "$check" = 1 ]; then
    local all="$MISSING_REQUIRED $MISSING_WEB"
    all="${all# }"; all="${all% }"
    [ -z "$all" ] && { say "Nothing is missing."; exit 0; }
    say "Missing: $all"
    exit 1
  fi
  if [ -n "$MISSING_REQUIRED$MISSING_WEB" ]; then
    install_missing
    check_machine >/dev/null
  fi
  ready
  return 0
}

main "$@"
