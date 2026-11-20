#!/usr/bin/env bash
# bendit installer. Meant to be piped from curl, so a dropped connection can hand
# bash HALF this file: every statement below lives in a function, and the only
# top-level call is the last line, `main "$@"`. A truncated copy defines some
# functions and runs nothing.
#
# Exit codes: 0 ready (or --check found nothing missing); 1 something required
# is missing or failed; 2 usage error, refused location, unsupported OS.
set -u
ASK_OPEN=""  # never inherited: a caller must not choose which fd ask() reads
ASKED="
"           # install commands already offered, one per line
CLT_MISSING=0

BENDIT_VERSION="0.3.0"
# The major of Playwright's own engines.node floor (plugins/bendit/lib/drive/
# package.json): the browser driver cannot run on less. drive.test.sh checks it.
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

# Google Chrome, on PATH or as an app bundle. BENDIT_APP_DIRS (space
# separated) overrides the app folders searched. Chromium does NOT count: the
# browser driver launches Playwright channels (chrome, msedge, ...), none of
# which is a system Chromium, so a Chromium-only machine cannot be driven.
find_chrome() {
  local c d
  for c in google-chrome google-chrome-stable; do
    command -v "$c" >/dev/null 2>&1 && return 0
  done
  if [ -n "${BENDIT_APP_DIRS:-}" ]; then
    for d in $BENDIT_APP_DIRS; do
      [ -e "$d/Google Chrome.app" ] && return 0
    done
  else
    for d in /Applications "$HOME/Applications"; do
      [ -e "$d/Google Chrome.app" ] && return 0
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
  apple_stub python3 && return 0
  python3 -I -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null | head -n 1
}

# apple_stub <tool> -- 0 when <tool> is macOS's stub in /usr/bin and the Command
# Line Tools are missing, so running it would open Apple's install dialog.
# BENDIT_APPLE_SHIMS (a test hook) names the folder the stubs live in.
apple_stub() {
  [ "${CLT_MISSING:-0}" = 1 ] || return 1
  [ "$(command -v "$1")" = "${BENDIT_APPLE_SHIMS:-/usr/bin}/$1" ]
}

# row <item> <found-or-empty> <needed> <ok 0|1> <why>
row() {
  local mark="✓" found="$2"
  printf -v "FOUND_$1" '%s' "$2"
  printf -v "NEED_$1" '%s' "$3"
  [ "$4" = 0 ] || mark="✗"
  [ -n "$found" ] || found="missing"
  printf '%s %-8s %-9s %-7s %s\n' "$mark" "$1" "$found" "$3" "$5"
}

# Sets MISSING_REQUIRED and MISSING_WEB (space-separated item names) and prints
# the table.
check_machine() {
  local v ok web=0
  MISSING_REQUIRED=""; MISSING_WEB=""
  # Before anything runs git or python3: on a Mac without the Command Line Tools
  # both are stubs that open Apple's install dialog each time they run.
  CLT_MISSING=0
  if [ "$(uname -s)" = Darwin ] && command -v xcode-select >/dev/null 2>&1 \
     && ! xcode-select -p >/dev/null 2>&1; then
    CLT_MISSING=1
  fi
  is_web_project && web=1
  say "  item     found     needed  why"

  v=""; ok=1
  if command -v claude >/dev/null 2>&1; then
    v="$(claude --version 2>/dev/null | head -n 1 | cut -d' ' -f1)"; ok=0; [ -n "$v" ] || v="found"
  fi
  row claude "$v" any "$ok" "runs the agent bendit plugs into"
  [ "$ok" = 0 ] || MISSING_REQUIRED="$MISSING_REQUIRED claude"

  v=""; ok=1
  if command -v git >/dev/null 2>&1; then
    if apple_stub git; then
      v="stub only"
    elif git --version >/dev/null 2>&1; then
      ok=0; v="found"
    else
      v="found but did not run"
    fi
  fi
  row git "$v" any "$ok" "reads and records your changes"
  [ "$ok" = 0 ] || MISSING_REQUIRED="$MISSING_REQUIRED git"

  v="$(python_version)"; ok=1
  [ -n "$v" ] && ver_ge "$v" 3.9 && ok=0
  if [ -z "$v" ] && command -v python3 >/dev/null 2>&1; then
    if apple_stub python3; then v="stub only"; else v="found but did not run"; fi
  fi
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
  local item="$1" pm="" s
  if [ "$item" = claude ]; then
    command -v curl >/dev/null 2>&1 && say 'curl -fsSL https://claude.ai/install.sh | bash'
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      # brew itself needs the Command Line Tools, and they bring git and python3.
      if [ "${CLT_MISSING:-0}" = 1 ]; then
        case "$item" in git|python3) say 'xcode-select --install'; return 0 ;; esac
      fi
      command -v brew >/dev/null 2>&1 || return 0
      case "$item" in
        python3) say 'brew install python@3.13' ;;
        git)     say 'brew install git' ;;
        node)    say 'brew install node' ;;
        chrome)  say 'brew install --cask google-chrome' ;;
      esac ;;
    Linux)
      for pm in apt-get dnf pacman; do command -v "$pm" >/dev/null 2>&1 && break; pm=""; done
      [ -n "$pm" ] || return 0
      # root needs no sudo; anyone else without sudo (a container) gets no route.
      if command -v id >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
        s=""
      elif command -v sudo >/dev/null 2>&1; then
        s="sudo "
      else
        return 0
      fi
      # apt's own nodejs is older than NODE_MIN (18 on Ubuntu 24.04 and Debian
      # 12, 12 on 22.04), and dnf's can be too (RHEL, Rocky and Alma streams),
      # so neither is a route for node. A fresh image has no package lists
      # until apt-get update. pacman -Sy without -u is a partial upgrade, which
      # Arch does not support, so pacman installs from the database as it is.
      case "$pm:$item" in
        apt-get:python3) say "${s}apt-get update && ${s}apt-get install -y python3" ;;
        apt-get:git)     say "${s}apt-get update && ${s}apt-get install -y git" ;;
        dnf:python3)     say "${s}dnf install -y python3" ;;
        dnf:git)         say "${s}dnf install -y git" ;;
        pacman:python3)  say "${s}pacman -S --needed --noconfirm python" ;;
        pacman:git)      say "${s}pacman -S --needed --noconfirm git" ;;
        pacman:node)     say "${s}pacman -S --needed --noconfirm nodejs" ;;
      esac ;;
  esac
  return 0
}

manual_pointer() {
  case "$1" in
    python3) say "Get Python 3.9 or newer from https://www.python.org/downloads/" ;;
    git)     say "Get git from https://git-scm.com/downloads" ;;
    node)
      say "Get Node.js $NODE_MIN or newer from https://nodejs.org/ (or with nvm)."
      if [ "$(uname -s)" = Linux ]; then
        if command -v apt-get >/dev/null 2>&1; then
          say "  apt's own nodejs is older than $NODE_MIN; NodeSource's packages are new enough."
        elif command -v dnf >/dev/null 2>&1; then
          say "  dnf's own nodejs can be older than $NODE_MIN; NodeSource's packages are new enough."
        fi
      fi ;;
    chrome)  say "Get Chrome from https://www.google.com/chrome/" ;;
    claude)  say "See https://code.claude.com/docs/en/setup" ;;
  esac
}

# pacman_hint <cmd> [failed] -- a pacman install can fail on a stale database;
# bendit never upgrades the system for you, so it says how.
pacman_hint() {
  case "$1" in *pacman\ *) ;; *) return 0 ;; esac
  local s=""   # the prefix the install command itself used (empty for root)
  case "$1" in "sudo "*) s="sudo " ;; esac
  if [ -n "${2:-}" ]; then
    say "  Run \`${s}pacman -Syu\` yourself first (a stale package database), then run this again."
  else
    say "    (if this fails, run \`${s}pacman -Syu\` yourself first)"
  fi
}

why_missing() {
  local var="FOUND_$1"
  if [ "${!var:-}" = "stub only" ]; then
    say "$1 is only Apple's stub until the Command Line Tools are installed."
    return 0
  fi
  case "$1" in
    python3) say "python3 is missing or older than 3.9 (it runs bendit's guards)." ;;
    node)    say "node is missing or older than $NODE_MIN (it drives the browser for a web app)." ;;
    chrome)  say "Chrome is missing (the browser bendit looks at your app with)." ;;
    git)     say "git is missing or does not run (it reads and records your changes)." ;;
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
  local item="$1" cmd rc tool now need added=0 var
  cmd="$(install_cmd "$item")"
  why_missing "$item"
  # One command can serve two items (xcode-select --install brings git and
  # python3): ask once.
  case "$ASKED" in *"
$cmd
"*)
    [ -n "$cmd" ] && { say "  That is the same install as above."; return 1; } ;;
  esac
  ASKED="$ASKED$cmd
"
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
  # pipefail: a failed download in `curl ... | bash` is a failure, not bash's
  # 0. fd 3 is the terminal ask() reads; the command does not get it.
  ( set -o pipefail; eval "$cmd" ) < /dev/null 3<&-; rc=$?
  # claude installs to ~/.local/bin, which a fresh machine may not have on PATH yet.
  if [ "$item" = claude ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; added=1 ;; esac
  fi
  hash -r 2>/dev/null
  if ! is_missing "$item"; then
    say "  $item is ready."
    if [ "$added" = 1 ] && [ "$(command -v claude)" = "$HOME/.local/bin/claude" ]; then
      say "  claude is in ~/.local/bin, which this shell's PATH lacks: open a new terminal"
      say "  (or add ~/.local/bin to PATH) before you run claude yourself."
    fi
    return 0
  fi
  if [ "$cmd" = "xcode-select --install" ]; then
    say "  Apple's installer has opened in its own window."
    say "  When Apple's installer finishes, run this again."
    return 2
  fi
  tool="${cmd#sudo }"; tool="${tool%% *}"
  var="FOUND_$item"; now="${!var:-}"; var="NEED_$item"; need="${!var:-}"
  if [ "$rc" != 0 ]; then
    say "  The install command failed (exit $rc), and $item is still not ready."
    pacman_hint "$cmd" failed
  elif [ -z "$now" ]; then
    say "  $tool said it worked, but $item is still not found."
  elif [ "$now" = "found but did not run" ] || [ "$now" = "stub only" ]; then
    say "  $tool said it worked, but $item still does not run."
  else
    say "  $tool said it worked, but $item is still $now; bendit needs $need."
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
    if [ -n "$cmd" ]; then say "  $item: $cmd"; pacman_hint "$cmd"; else say "  $item: $(manual_pointer "$item")"; fi
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

# fetch_kit -- prints the plugin directory, cloning bendit into the cache first
# unless a good clone of this version is already there. The clone lands in a temp
# folder inside the cache and is moved into place, so a failed or interrupted
# fetch never leaves a half-made v<version> folder.
fetch_kit() {
  local cache dir src ref tmp out
  cache="${BENDIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bendit}"
  dir="$cache/v$BENDIT_VERSION"
  src="${BENDIT_SOURCE:-https://github.com/VedangP57/bendit.git}"
  ref="${BENDIT_REF:-v$BENDIT_VERSION}"
  # git -C walks up into a parent repository, so .git must be in dir itself, and
  # the plugin must really be there.
  if [ -d "$dir/.git" ] && [ -f "$dir/plugins/bendit/.claude-plugin/plugin.json" ] \
     && git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    say "$dir/plugins/bendit"
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$cache" || { printf '%s\n' "could not create $cache" >&2; return 1; }
  tmp="$(mktemp -d "$cache/.fetch.XXXXXX")" || { printf '%s\n' "could not create a temporary folder in $cache" >&2; return 1; }
  # git's own chatter (detached HEAD advice, local-clone depth warning) is noise
  # unless the clone fails, and then it is the reason.
  if ! out="$(git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$src" "$tmp/kit" </dev/null 2>&1)"; then
    rm -rf "$tmp"
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf '%s\n' "could not fetch bendit from $src ($ref)." >&2
    return 1
  fi
  if ! mv "$tmp/kit" "$dir"; then
    rm -rf "$tmp"
    printf '%s\n' "could not move bendit into $cache." >&2
    return 1
  fi
  rm -rf "$tmp"
  say "$dir/plugins/bendit"
}

# handover_stdin -- sets HANDOVER_STDIN to where claude should read its input:
# empty means "leave stdin alone" (it already is the terminal); otherwise a path.
# Under `curl | bash` stdin is the script pipe, so claude needs the terminal
# explicitly -- and the real device (/dev/ttys003), not the /dev/tty alias:
# macOS kqueue cannot watch /dev/tty, and a Bun claude dies with EINVAL on it.
# Sets a variable instead of printing: a command substitution would hide the
# terminal on stdout.
handover_stdin() {
  local dev=""
  HANDOVER_STDIN=""
  if [ -n "${BENDIT_TTY:-}" ]; then HANDOVER_STDIN="$BENDIT_TTY"; return 0; fi
  [ -t 0 ] && return 0
  if [ -t 2 ]; then dev="$(tty 0<&2 2>/dev/null)"
  elif [ -t 1 ]; then dev="$(tty 0<&1 2>/dev/null)"; fi
  if [ -n "$dev" ] && [ "$dev" != "not a tty" ] && [ -c "$dev" ]; then
    HANDOVER_STDIN="$dev"
  else
    HANDOVER_STDIN=/dev/tty
  fi
  return 0
}

# hand_over <plugin-dir> -- with a terminal, becomes claude running /bendit:adopt (its
# input is the terminal, not the script a curl pipe may be feeding stdin);
# without one, prints the command to run.
hand_over() {
  local plugin="$1" q
  if have_tty; then
    handover_stdin
    if [ -n "$HANDOVER_STDIN" ]; then
      exec claude --plugin-dir "$plugin" "/bendit:adopt" < "$HANDOVER_STDIN"
    fi
    exec claude --plugin-dir "$plugin" "/bendit:adopt"
  fi
  printf -v q '%q' "$plugin"
  say ""
  say "There is no terminal to open Claude on. To finish, run this in your project:"
  say "  claude --plugin-dir $q \"/bendit:adopt\""
  exit 0
}

# repo_note -- one line when the project folder is not a git repository.
repo_note() {
  local out
  out="$(LC_ALL=C git rev-parse --is-inside-work-tree 2>&1)" && return 0
  case "$out" in
    *"not a git repository"*) say "This folder is not a git repository; /bendit:adopt will offer git init." ;;
    *) say "git could not tell whether this folder is a repository: $(printf '%s\n' "$out" | head -n 1)" ;;
  esac
}

ready() {
  local plugin
  say ""
  repo_note
  say "This machine is ready. Fetching bendit..."
  plugin="$(fetch_kit)" || exit 1
  hand_over "$plugin"
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
