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
  check_location
  [ "$check" = 1 ] && say "Checking only; nothing will be installed."
  return 0
}

main "$@"
