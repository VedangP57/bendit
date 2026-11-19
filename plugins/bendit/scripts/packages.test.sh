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

# A hermetic machine for the exit-1 case: only these tools, no claude, no git,
# an empty HOME and project, so `--check` reports something missing and exits 1
# without touching the network.
SB="$T/sb"; mkdir -p "$SB/bin" "$SB/home" "$SB/proj"
for t in bash cat grep sed head tr cut mkdir mktemp mv rm rmdir dirname uname env node python3; do
  p="$(type -P "$t")" && ln -sf "$p" "$SB/bin/$t"
done
PYRUN() { PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/packages/pypi/src" python3 -m bendit "$@"; }
NPMRUN() { node "$ROOT/packages/npm/bin/bendit.js" "$@"; }

check_wrapper() {  # <label> <function>
  local label="$1" run="$2" got rc
  got="$($run --version 2>"$T/e")"; rc=$?
  chk "$label --version" "$got" "$want"; chk "$label --version exit" "$rc" 0
  $run --bogus >"$T/o" 2>"$T/e"; rc=$?
  chk "$label passes exit 2 for --bogus" "$rc" 2
  $run "a b" >"$T/o" 2>"$T/e"; rc=$?
  if grep -q -F -- 'Unknown option: a b (' "$T/o" "$T/e"; then good "$label passes the argument 'a b' whole"
  else bad "$label did not pass 'a b' as one argument (installer said: $(cat "$T/o" "$T/e"))"; fi
  (cd "$SB/proj" && HOME="$SB/home" PATH="$SB/bin" $run --check </dev/null >"$T/o" 2>"$T/e"); rc=$?
  chk "$label passes exit 1 when something is missing" "$rc" 1
}
check_wrapper "python wrapper" PYRUN
if [ "$have_node" = 1 ]; then check_wrapper "npm wrapper" NPMRUN; fi

echo; echo "bendit needs bash (no bash on PATH)"
EMPTY="$T/empty"; mkdir -p "$EMPTY"
nobash_msg='bendit needs bash, and it was not found on PATH.'
PYBIN="$(type -P python3)"; NODEBIN="$(type -P node)"
PATH="$EMPTY" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/packages/pypi/src" "$PYBIN" -m bendit --version >"$T/o" 2>"$T/e"; rc=$?
chk "python wrapper exits 2 without bash" "$rc" 2
chk "python wrapper says it needs bash" "$(cat "$T/e")" "$nobash_msg"
if [ "$have_node" = 1 ]; then
  PATH="$EMPTY" "$NODEBIN" "$ROOT/packages/npm/bin/bendit.js" --version >"$T/o" 2>"$T/e"; rc=$?
  chk "npm wrapper exits 2 without bash" "$rc" 2
  chk "npm wrapper says it needs bash" "$(cat "$T/e")" "$nobash_msg"
fi

echo; echo "NPM TARBALL"
if [ "$have_node" = 1 ]; then
  before="$(cd "$ROOT" && git status --porcelain)"
  (cd "$ROOT/packages/npm" && npm pack --dry-run --json --ignore-scripts >"$T/pack.json" 2>"$T/pack.err"); rc=$?
  chk "npm pack --dry-run exits 0" "$rc" 0
  [ "$rc" = 0 ] || sed 's/^/    /' "$T/pack.err"
  for f in install.sh bin/bendit.js package.json; do
    node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.exit(j[0].files.some(x=>x.path===process.argv[2])?0:1)' "$T/pack.json" "$f" 2>"$T/e"; rc=$?
    chk "tarball lists $f" "$rc" 0
  done
  after="$(cd "$ROOT" && git status --porcelain)"
  chk "npm pack --dry-run left the working tree unchanged" "$after" "$before"
fi

echo; echo "$pass passed, $fail failed"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
