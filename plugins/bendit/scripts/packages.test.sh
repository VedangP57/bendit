#!/usr/bin/env bash
# packages/: the npm and PyPI wrappers around install.sh.
#
# Each wrapper ships its own byte-identical copy of install.sh (packages/sync.sh
# makes it), so the checks are: the copies match, the four version strings
# match, each wrapper runs the bundled installer and passes arguments and exit
# codes through, and the npm tarball would contain the files it needs.
# node and npm are required: their absence FAILS the suite, never skips it.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/../../.." && pwd)"
pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
good() { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }

echo "TOOLS"
have_node=1
for t in node npm python3 bash; do
  if type -P "$t" >/dev/null; then good "$t is installed"
  else
    bad "$t is not installed here, so the suite cannot run"
    case "$t" in node|npm) have_node=0 ;; esac
  fi
done

echo; echo "COPIES OF install.sh"
for c in packages/npm/install.sh packages/pypi/src/bendit/install.sh; do
  if cmp -s "$ROOT/install.sh" "$ROOT/$c"; then good "$c is identical to install.sh"
  else bad "$c differs from install.sh (or is missing): run packages/sync.sh"; fi
done

echo; echo "VERSIONS"
v_sh="$(sed -n 's/^BENDIT_VERSION="\(.*\)"$/\1/p' "$ROOT/install.sh")"
v_plugin="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$ROOT/plugins/bendit/.claude-plugin/plugin.json" | head -1)"
v_npm="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$ROOT/packages/npm/package.json" | head -1)"
v_py="$(sed -n 's/^version *= *"\(.*\)"$/\1/p' "$ROOT/packages/pypi/pyproject.toml" | head -1)"
if [ -n "$v_sh" ] && [ "$v_sh" = "$v_plugin" ] && [ "$v_sh" = "$v_npm" ] && [ "$v_sh" = "$v_py" ]; then
  good "all four versions are $v_sh"
else
  bad "versions differ: install.sh=${v_sh:-?} plugin.json=${v_plugin:-?} package.json=${v_npm:-?} pyproject.toml=${v_py:-?}"
fi

echo; echo "WRAPPERS RUN THE BUNDLED INSTALLER"
want="$(bash "$ROOT/install.sh" --version)"
chk "install.sh --version names the version" "$want" "bendit installer ${v_sh:-?}"
if [ "$have_node" = 1 ]; then
  got="$(node "$ROOT/packages/npm/bin/bendit.js" --version 2>"$T/e")"; rc=$?
  chk "npm wrapper --version" "$got" "$want"; chk "npm wrapper --version exit" "$rc" 0
  node "$ROOT/packages/npm/bin/bendit.js" --bogus >"$T/o" 2>"$T/e"; rc=$?
  chk "npm wrapper passes exit 2 for --bogus" "$rc" 2
fi
got="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/packages/pypi/src" python3 -m bendit --version 2>"$T/e")"; rc=$?
chk "python wrapper --version" "$got" "$want"; chk "python wrapper --version exit" "$rc" 0
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/packages/pypi/src" python3 -m bendit --bogus >"$T/o" 2>"$T/e"; rc=$?
chk "python wrapper passes exit 2 for --bogus" "$rc" 2

echo; echo "NPM TARBALL"
if [ "$have_node" = 1 ]; then
  before="$(cd "$ROOT" && git status --porcelain)"
  (cd "$ROOT/packages/npm" && npm pack --dry-run --json --ignore-scripts >"$T/pack.json" 2>"$T/pack.err"); rc=$?
  chk "npm pack --dry-run exits 0" "$rc" 0
  [ "$rc" = 0 ] || sed 's/^/    /' "$T/pack.err"
  for f in install.sh bin/bendit.js package.json; do
    if grep -q "\"path\": *\"$f\"" "$T/pack.json"; then good "tarball lists $f"
    else bad "tarball does not list $f"; fi
  done
  after="$(cd "$ROOT" && git status --porcelain)"
  chk "npm pack --dry-run left the working tree unchanged" "$after" "$before"
fi

echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
