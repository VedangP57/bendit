#!/usr/bin/env bash
# A guard whose OWN code cannot load must refuse, never let the call run.
#
# block-dangerous-bash and block-zsh-wordsplit imported shell_text.py outside
# their crash net. A shell_text.py that was broken, missing or unreadable made
# Python exit 1 with a traceback -- and Claude Code treats any exit but 2 as a
# NON-blocking error, so the command ran with no guard at all. block-ls-parsing
# caught only Exception, so a helper that called sys.exit(0) on import let the
# command through as well.
#
# Each case runs a COPY of scripts/ with one helper module broken three ways --
# a syntax error, missing, exiting 0 on import -- and asserts exit 2 with a
# refusal that names the guard, for a command the guard would allow AND one it
# would refuse. Controls: the intact copy allows and refuses as usual, and a
# guard that is switched off stays off. Then selfcheck.py, run on a whole
# plugin copy, must name each such guard as broken, not "ok": a guard that
# refuses every call is not a working guard.
#
# NOT covered, and cannot be: a helper that calls os._exit(0) ends the process
# on the spot -- no except, finally or excepthook runs -- so the guard exits 0.
# Only a wrapper outside Python could catch that; none is installed.
#
# block-primary-checkout's one helper is features.py (fire_log comes after the
# decision). path-contracts has no helper module to break (only fire_log, imported after
# the decision; fire-log.test.sh covers that). require-verification --pre and
# post-edit-review --pre never block, by design.
#
#   bash guard-startup.test.sh          (PY=/usr/bin/python3 to run under 3.9)
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
PY="${PY:-python3}"
pass=0; fail=0
unset CLAUDE_PROJECT_DIR
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ -- $2}"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "no [$2] in [$(printf '%s' "$3" | tail -c 300)]";; esac; }

# A project with ls-guard on, so block-ls-parsing does not skip itself.
P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q
"$PY" "$SD/features.py" set "$P" ls-guard on "guard-startup test" >/dev/null || exit 1
# ...and primary-checkout-guard, on `main`, so block-primary-checkout refuses
# an edit in it (its "command" below is a file path: an Edit payload).
git -C "$P" symbolic-ref HEAD refs/heads/main
"$PY" "$SD/features.py" set "$P" primary-checkout-guard on "guard-startup test" >/dev/null || exit 1
"$PY" "$SD/features.py" integration-branch "$P" main >/dev/null || exit 1
mkdir -p "$T/outside"
pl() { "$PY" -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "$P"; }
pl_edit() { "$PY" -c 'import json,sys;print(json.dumps({"tool_name":"Edit","cwd":sys.argv[2],"tool_input":{"file_path":sys.argv[1],"old_string":"a","new_string":"b"}}))' "$1" "$P"; }

# copy <dir>: a fresh copy of scripts/, no bytecode cache (a cached .pyc of the
# intact helper would otherwise load in place of the broken source).
copy() { rm -rf "$1"; mkdir -p "$1"; cp -R "$SD/." "$1/"; rm -rf "$1/__pycache__"; }
breakit() {  # breakit <dir> <module> <how>
  case "$3" in
    syntax)  printf 'def broken(:\n' >"$1/$2.py";;
    missing) rm -f "$1/$2.py";;
    exits)   printf 'import sys\nsys.exit(0)\n' >"$1/$2.py";;
    # An error whose own text cannot be produced: the refusal must still speak.
    badstr)  printf '%s\n' 'class E(Exception):' '    def __str__(self): raise RuntimeError("no text")' 'raise E()' >"$1/$2.py";;
    # The module imports fine; every function it defines raises when CALLED.
    # block-dangerous-bash calls lex during module setup, the others in main.
    call-exit0)    callraise "$1/$2.py" 'SystemExit(0)';;
    call-exitnone) callraise "$1/$2.py" 'SystemExit(None)';;
    call-kbi)      callraise "$1/$2.py" 'KeyboardInterrupt()';;
  esac
}
callraise() {  # callraise <module file> <exception expr>
  printf '%s\n' '' 'def _bendit_boom(*_a, **_k):' "    raise $2" \
    'for _n, _v in list(globals().items()):' \
    "    if type(_v) is type(_bendit_boom) and _v is not _bendit_boom and getattr(_v, '__module__', '') == __name__:" \
    '        globals()[_n] = _bendit_boom' >>"$1"
}
# rung <dir> <guard> <command> [env...]: exit code; stderr kept in $T/err.
rung() {
  local d="$1" g="$2" c="$3" mk=pl; shift 3
  [ "$g" = block-primary-checkout ] && mk=pl_edit
  "$mk" "$c" | env "$@" PYTHONDONTWRITEBYTECODE=1 "$PY" "$d/$g.py" >/dev/null 2>"$T/err"; echo $?
}

# guard @ helper modules @ a command it allows @ one it refuses @ env
CASES=(
  "block-dangerous-bash@shell_text@git status@git push --force origin HEAD@"
  "block-zsh-wordsplit@shell_text@echo hi@for f in \$files; do echo \"\$f\"; done@SHELL=/bin/zsh"
  "block-ls-parsing@features shell_text@ls -la@ls | wc -l@"
  "block-primary-checkout@features@$T/outside/x.txt@$P/app.py@"
)

for row in "${CASES[@]}"; do
  IFS='@' read -r g mods allow refuse envs <<<"$row"
  # shellcheck disable=SC2206
  E=(${envs:-X_BENDIT_UNUSED=1})
  echo "$g"
  C="$T/intact"; copy "$C"
  chk "  control: intact copy allows \`$allow\`"  "$(rung "$C" "$g" "$allow" "${E[@]}")" 0
  chk "  control: intact copy refuses \`$refuse\`" "$(rung "$C" "$g" "$refuse" "${E[@]}")" 2
  for m in $mods; do
    for how in syntax missing exits badstr call-exit0 call-exitnone call-kbi; do
      C="$T/$g-$m-$how"; copy "$C"; breakit "$C" "$m" "$how"
      for cmd in "$allow" "$refuse"; do
        chk "  $m.py $how: \`$cmd\` is refused" "$(rung "$C" "$g" "$cmd" "${E[@]}")" 2
        err="$(cat "$T/err")"
        case "$how" in
          # Once main runs, the guard's own crash net answers, in the wording
          # its own suite pins ("guard itself failed", "crashed"); it must still
          # read as a bendit refusal and name what was raised.
          call-*)
            case "$err" in "[bendit]"*|"BLOCKED by bendit"*) ok "    a bendit refusal";;
                           *) bad "    a bendit refusal" "$err";; esac
            case "$how" in call-kbi) want=KeyboardInterrupt;; *) want=SystemExit;; esac
            has "    ...naming what was raised"  "$want" "$err";;
          *)
            has "    the refusal names the guard"  "bendit guard $g could not start" "$err"
            has "    ...and says what to run"      "/bendit:doctor" "$err";;
        esac
      done
    done
  done
done

# The ls guard decides "no bendit.json here, nothing to do" before it imports
# anything, so a project that never turned it on is untouched. The zsh guard
# imports first and refuses even when SHELL is not zsh: fail closed, and its
# helper is block-dangerous-bash's too, which refuses every call by then anyway.
echo "THE LS GUARD, NEVER TURNED ON, STAYS OFF WHEN BROKEN"
C="$T/off"; copy "$C"; breakit "$C" shell_text syntax
N="$T/noproj"; mkdir -p "$N"
chk "  ls guard, no bendit.json: allowed (it never runs)" \
    "$(pl 'ls | wc -l' | sed "s#$P#$N#" | PYTHONDONTWRITEBYTECODE=1 "$PY" "$C/block-ls-parsing.py" >/dev/null 2>&1; echo $?)" 0

echo "SELFCHECK NAMES A GUARD THAT CANNOT START (it refuses everything: not ok)"
# Only shell_text: probes.py itself imports features.py, so a broken features.py
# is reported as "the probe table did not load" (selfcheck.test.sh's ground).
for m in shell_text; do
  for how in syntax missing; do
    K="$T/kit-$m-$how"; rm -rf "$K"; mkdir -p "$K"; cp -R "$KIT/hooks" "$KIT/scripts" "$K/"
    rm -rf "$K/scripts/__pycache__"; breakit "$K/scripts" "$m" "$how"
    out="$(PYTHONDONTWRITEBYTECODE=1 "$PY" "$K/scripts/selfcheck.py" 2>&1)"; rc=$?
    chk "  $m.py $how: selfcheck exits 1" "$rc" 1
    for g in block-dangerous-bash block-zsh-wordsplit block-ls-parsing; do
      row="$(printf '%s\n' "$out" | grep -E "^$g\.py +\|" || true)"
      has "    $g is not ok"                 "| OFF" "$row"
      has "    ...and its error is named"    "$g.py: [bendit] BLOCKED: bendit guard $g could not start" "$out"
    done
  done
done

echo; echo "path-contracts: A SystemExit OR ^C RAISED INSIDE THE CHECK REFUSES, LIKE ITS SIBLINGS"
for exc in "SystemExit(0)" "KeyboardInterrupt()"; do
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/src/a.gen.ts","content":"x"}}' | "$PY" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
class Boom:
    def search(self, _t): raise eval(sys.argv[2])
pc.GEN = Boom()
sys.exit(pc.run())' "$SD/path-contracts.py" "$exc" >/dev/null 2>"$T/pc.err"
  chk "$exc inside main(): exit 2" "$?" 2
  has "  and says the guard failed" "the path-contracts guard itself failed" "$(cat "$T/pc.err")"
done

echo
echo "guard-startup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
