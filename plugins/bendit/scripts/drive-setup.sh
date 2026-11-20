#!/usr/bin/env bash
# Install the browser driver's one dependency, Playwright, outside any project.
#
#   drive-setup.sh           install it (safe to re-run: a good install is kept)
#   drive-setup.sh --check   exit 0 when it is installed, 1 when it is not
#
# WHAT: exactly lib/drive/package.json's playwrightVersion, with
#   npm install --prefix <dir> --no-save playwright@<version>
# WHERE: <dir> = ${BENDIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bendit}/drive/<version>/,
# the cache the installer already uses -- never the project, whose own
# node_modules and package files are not bendit's to change. npm runs from a
# folder of its own, so a project's .npmrc is never read either.
# NO BROWSER is downloaded (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1): drive.mjs drives
# the Chrome already on the machine, or BENDIT_BROWSER_CHANNEL's browser.
#
# It never asks. /adopt asks the person before it runs this; anything else that
# runs it has decided to download Playwright from npm.
#
# The install lands in a temporary folder beside <dir> and is moved into place
# only once it holds the pinned version, so a failed or interrupted install is
# never mistaken for a good one.
#
# Exit: 0 installed; 1 not installed (--check) or the install failed;
#       2 usage error, a relative BENDIT_CACHE, or npm / python3 missing.
set -uo pipefail

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; }
case "${1:-}" in
  '') check=0 ;;
  --check) check=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "drive-setup: unknown option '$1'" >&2; usage >&2; exit 2 ;;
esac

KIT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$KIT/lib/drive/package.json"
command -v python3 >/dev/null 2>&1 || { echo "drive-setup: python3 is required (it reads $PKG)" >&2; exit 2; }
# version_in <package.json> -- prints its "version" (or playwrightVersion for
# ours); exit 1, printing nothing, when the file does not exist. A file that
# exists but does not parse is an error worth seeing, so stderr is left alone.
version_in() {
  python3 -c '
import json, os, sys
p, key = sys.argv[1], sys.argv[2]
if not os.path.isfile(p):
    sys.exit(1)
print(json.load(open(p))[key])' "$1" "$2"
}
version="$(version_in "$PKG" playwrightVersion)" || { echo "drive-setup: cannot read playwrightVersion from $PKG" >&2; exit 2; }

cache="${BENDIT_CACHE:-${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/bendit}"
# A relative cache would resolve against the cwd -- usually the project.
case "$cache" in
  /*) ;;
  *) echo "drive-setup: refusing a relative cache folder '$cache' (from BENDIT_CACHE or XDG_CACHE_HOME): it would be written inside the current folder. Give an absolute path." >&2; exit 2 ;;
esac
dir="$cache/drive/$version"
installed() { [ "$(version_in "$1/node_modules/playwright/package.json" version)" = "$version" ]; }

if [ "$check" = 1 ]; then
  if installed "$dir"; then echo "drive-setup: Playwright $version is installed in $dir"; exit 0; fi
  echo "drive-setup: Playwright $version is not installed (looked in $dir). Install it with: bash $KIT/scripts/drive-setup.sh"
  exit 1
fi

if installed "$dir"; then
  echo "drive-setup: Playwright $version is already installed in $dir"
  exit 0
fi
command -v npm >/dev/null 2>&1 || { echo "drive-setup: npm is required to install Playwright, and it is not on PATH (it comes with Node.js: https://nodejs.org/)" >&2; exit 2; }

mkdir -p "$cache/drive" || { echo "drive-setup: could not create $cache/drive" >&2; exit 1; }
tmp="$(mktemp -d "$cache/drive/.install.XXXXXX")" || { echo "drive-setup: could not create a temporary folder in $cache/drive" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
echo "drive-setup: installing Playwright $version into $dir (from npm; no browser is downloaded)"
if ! ( cd "$tmp" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --prefix "$tmp" --no-save "playwright@$version" ); then
  echo "drive-setup: npm install failed (output above); nothing was installed" >&2
  exit 1
fi
if ! installed "$tmp"; then
  echo "drive-setup: npm finished, but $tmp/node_modules/playwright is not version $version; nothing was installed" >&2
  exit 1
fi
# Another run may have finished first; its install is as good as this one.
if installed "$dir"; then
  echo "drive-setup: Playwright $version is installed in $dir"
  exit 0
fi
rm -rf "$dir"
if ! mv "$tmp" "$dir"; then
  echo "drive-setup: could not move the install into $dir" >&2
  exit 1
fi
echo "drive-setup: Playwright $version is installed in $dir"
