#!/usr/bin/env bash
# verify.sh end to end, against fixture repos with real harnesses.
#
# Started with one question -- must not treat a 500 as "the app is up". Found
# 2026-11-12 while simulating a CI job: a cold Next checkout answered HTTP 500
# while still compiling, and the readiness loop broke out on it because
# `curl -s -o /dev/null` exits 0 for ANY response. Doctor then ran against a
# half-started app and its failures read as defects in the app. A readiness
# check that cannot tell "serving" from "answering with an error" produces
# exactly the confident nonsense this harness exists to prevent.
#
# End-to-end on purpose: a fixture repo with a real harness whose `up` serves a
# chosen status, driven through the real verify.sh. A unit test of the helper
# would not have caught this, because the bug IS the integration -- and the
# first attempt at the fix shipped `000000` from a duplicated fallback, which
# only showed up here.
#
# Every fixture server EXITS BY ITSELF after a few seconds. An earlier version
# killed leftovers by pid, which is both unsafe and unnecessary: a server that
# outlives its test is the test's bug, not something to clean up afterwards.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$D/verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

# A port nothing is listening on, chosen by the kernel. Fixed ports (3100,
# 3200, 3300) let a case pass for the wrong reason whenever something else on
# the machine already held one: "never answered" and "refused to start" both
# end in a non-zero exit.
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
answers() { curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1"; }

# make_repo <name> <status>   -> prints the repo dir; port in $TMP/port-<name>
make_repo() {
  local name="$1" status="$2" R="$TMP/$1" port
  port=$(free_port); printf '%s' "$port" > "$TMP/port-$name"
  mkdir -p "$R/.claude/skills/verify-$name/bin" \
           "$R/.claude/skills/verify-$name/scenarios"
  git -C "$R" init -q . 2>/dev/null
  cat > "$R/.claude/skills/verify-$name/bin/verify-$name" <<BIN
#!/usr/bin/env bash
REPO="\$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "\$REPO" ] || exit 2
cd "\$REPO" || exit 1
PORT=\${PORT:-$port}
case "\${1:-}" in
  up) exec python3 -c "
import http.server, signal, socketserver
signal.alarm(20)           # exit on its own; never outlive the test
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response($status); s.end_headers(); s.wfile.write(b'<title>fx</title>')
    def log_message(s, *a): pass
# NOT http.server.HTTPServer: its server_bind() calls socket.getfqdn(), a
# reverse-DNS lookup that hung on GitHub's macOS runners with the port bound
# but not yet listening, so every probe timed out (stack dump, 2026-11-19).
# A plain TCPServer binds and listens with no lookup.
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', \$PORT), H).serve_forever()
" ;;
  doctor) echo 'ok    fixture doctor'; exit 0 ;;
  # The verdict comes FIRST and 200KB follow it -- a real driver's console and
  # request logs. Past a 64KB pipe, \`printf | grep -q\` takes SIGPIPE when grep
  # exits on the first match, and under pipefail that read as a FAILED scenario.
  drive) python3 -c "import sys; print('VERDICT: VERIFIED'); sys.stdout.write('x' * 200000 + '\n')"; exit 0 ;;
  *) exit 2 ;;
esac
BIN
  chmod +x "$R/.claude/skills/verify-$name/bin/verify-$name"
  echo ': scenario' > "$R/.claude/skills/verify-$name/scenarios/a.sh"
  echo ': scenario' > "$R/.claude/skills/verify-$name/scenarios/b.sh"
  # The registry keys a repo by its main checkout's real path.
  mkdir -p "$TMP/cfg-$name"
  printf '{"block_size": 100, "repos": {"%s": %s}}\n' "$(cd "$R" && pwd -P)" "$port" > "$TMP/cfg-$name/ports.json"
  printf '%s' "$R"
}

run_verify() { # repo-dir name [scenario]
  # BENDIT_APP_WAIT keeps this quick: what is under test is which
  # DECISION verify makes, not how patient it is.
  local dir="$1" name="$2"; shift 2
  ( cd "$dir" && BENDIT_CONFIG_DIR="$TMP/cfg-$name" \
      BENDIT_VERIFY_LOCKDIR="$TMP/slots" BENDIT_APP_WAIT=5 TMPDIR="$TMP/tmpd" \
      bash "$VERIFY" "$@" ) 2>&1
}
mkdir -p "$TMP/tmpd"

echo "A 500 IS NOT READY"
R5=$(make_repo five 500)
out=$(run_verify "$R5" five); rc=$?
if [ "$rc" -ne 0 ]; then ok "verify refuses an app that only ever 500s (exit $rc)"
else bad "verify refuses an app that only ever 500s" "it exited 0"; fi
case "$out" in
  *"fixture doctor"*) bad "  ...and never reaches doctor" "doctor ran against a broken app";;
  *) ok "  ...and never reaches doctor";;
esac
case "$out" in
  *"answering HTTP 500"*) ok "  ...and says the app answered 500, not that it was silent";;
  *) bad "  ...and says the app answered 500" "$(printf '%s' "$out" | tail -2)";;
esac
# A READINESS FAILURE MUST STILL TEAR DOWN. The EXIT trap was installed after
# the readiness loop, so every `die` in it left the app running, the slot held
# and the log behind -- and the next run refused: "something already on :PORT".
if answers "$(cat "$TMP/port-five")"; then bad "  ...and the app it started is stopped" "still answering on :$(cat "$TMP/port-five")"
else ok "  ...and the app it started is stopped"; fi
n=$(/usr/bin/find "$TMP/slots" -name '*.slot' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then ok "  ...and its verify slot is released"; else bad "  ...and its verify slot is released" "$n slot file(s) left"; fi
n=$(/usr/bin/find "$TMP/tmpd" -type f | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then ok "  ...and no app log is left behind"; else bad "  ...and no app log is left behind" "$n file(s) in TMPDIR"; fi
out=$(run_verify "$R5" five)
case "$out" in
  *"already on :"*) bad "  ...so a second run is not refused as 'something already on :PORT'" "$(printf '%s' "$out" | head -3)";;
  *) ok "  ...so a second run is not refused as 'something already on :PORT'";;
esac

echo
echo "CONTROL: a 200 still counts as ready"
# Without this the fix could be refusing every app -- a gate that never passes
# is as useless as one that never fails.
R2=$(make_repo two 200)
out2=$(run_verify "$R2" two); rc2=$?
case "$out2" in
  *"fixture doctor"*) ok "a 200 app gets past readiness and reaches doctor";;
  *) bad "a 200 app gets past readiness and reaches doctor" "$(printf '%s' "$out2" | tail -3)";;
esac
case "$out2" in
  *"2/2 verified"*) ok "a scenario whose verdict precedes 200KB of output PASSES (exit $rc2)";;
  *) bad "a scenario whose verdict precedes 200KB of output PASSES" "$(printf '%s' "$out2" | tail -4)";;
esac
STAMP="$R2/.claude/.verify-state/verified"
if [ -f "$STAMP" ]; then ok "a FULL clean run writes the stamp the Stop gate reads"
else bad "a FULL clean run writes the stamp the Stop gate reads" "no $STAMP"; fi

# ONE SCENARIO IS NOT VERIFICATION. A single-scenario run wrote the same global
# `verified` stamp, so driving the one scenario you expected to pass cleared a
# gate whose job is to insist the change was verified.
rm -f "$STAMP"
out3=$(run_verify "$R2" two a)
case "$out3" in
  *"1/1 verified"*) ok "a single-scenario run still runs and reports";;
  *) bad "a single-scenario run still runs and reports" "$(printf '%s' "$out3" | tail -3)";;
esac
if [ -f "$STAMP" ]; then bad "a single-scenario run does NOT satisfy the Stop gate" "it wrote $STAMP"
else ok "a single-scenario run does NOT satisfy the Stop gate"; fi

echo
echo "CONTROL: nothing listening is reported as silent, not as an error status"
R0=$(make_repo zero 200)
# Replace `up` with a command that serves nothing at all.
printf '#!/usr/bin/env bash\ncase "${1:-}" in up) sleep 30 ;; doctor) exit 0 ;; esac\n' \
  > "$R0/.claude/skills/verify-zero/bin/verify-zero"
chmod +x "$R0/.claude/skills/verify-zero/bin/verify-zero"
out4=$(run_verify "$R0" zero)
case "$out4" in
  *"never answered"*) ok "a silent app is 'never answered', a distinct message";;
  *) bad "a silent app is 'never answered'" "$(printf '%s' "$out4" | tail -2)";;
esac

echo
echo "A WORKTREE WITHOUT ITS OWN HARNESS"
# verify.sh fell back to the main checkout's harness, but a scaffolded harness
# refuses unless the checkout you stand in has .claude/skills/verify-<name>
# resolving to it. So the fallback announced "using main's, against this tree"
# and then died on the harness's own refusal -- a message about the harness,
# not about the missing link that was the real cause.
RM=$(make_repo mainrepo 200)
# Make it a SCAFFOLDED harness: the stand-in check the scaffold generates.
python3 - "$RM/.claude/skills/verify-mainrepo/bin/verify-mainrepo" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
guard = ('THEIRS="$(cd "$REPO/.claude/skills/verify-mainrepo" 2>/dev/null && pwd -P)"\n'
         '[ -n "$THEIRS" ] || { echo "refusing: no harness at $REPO/.claude/skills/verify-mainrepo" >&2; exit 2; }\n')
open(p, 'w').write(s.replace('cd "$REPO" || exit 1\n', guard + 'cd "$REPO" || exit 1\n', 1))
PY
git -C "$RM" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$RM" worktree add -q "$TMP/wt" 2>/dev/null
out5=$(run_verify "$TMP/wt" mainrepo); rc5=$?
if [ "$rc5" -ne 0 ]; then ok "verify in a worktree with no harness link refuses (exit $rc5)"
else bad "verify in a worktree with no harness link refuses" "it exited 0"; fi
case "$out5" in
  *"ln -s "*".claude/skills/verify-mainrepo"*) ok "  ...and names the real cause: the missing link, with the command";;
  *) bad "  ...and names the real cause: the missing link, with the command" "$(printf '%s' "$out5" | tail -4)";;
esac
case "$out5" in
  *"fixture doctor"*|*"starting app"*) bad "  ...before starting anything" "it got as far as the app";;
  *) ok "  ...before starting anything";;
esac
# CONTROL: with the link the scaffold expects, the worktree verifies itself.
mkdir -p "$TMP/wt/.claude/skills"
ln -s "$RM/.claude/skills/verify-mainrepo" "$TMP/wt/.claude/skills/verify-mainrepo"
out6=$(run_verify "$TMP/wt" mainrepo)
case "$out6" in
  *"fixture doctor"*) ok "CONTROL: with the link in place the worktree gets to doctor";;
  *) bad "CONTROL: with the link in place the worktree gets to doctor" "$(printf '%s' "$out6" | tail -3)";;
esac

echo
echo "NO SCENARIOS IS NOT VERIFIED"
# A fresh harness with an empty scenarios/ used to print "no scenarios yet" and
# exit 0 -- which the Stop gate reads as verified, having checked readiness only.
RN=$(make_repo none 200)
rm -f "$RN/.claude/skills/verify-none/scenarios/"*.sh
outn=$(run_verify "$RN" none); rcn=$?
if [ "$rcn" -ne 0 ]; then ok "verify with zero scenarios exits non-zero ($rcn)"; else bad "verify with zero scenarios exits non-zero" "exited 0"; fi
case "$outn" in *"nothing was verified"*) ok "  ...saying nothing was verified";; *) bad "  ...saying nothing was verified" "$(printf '%s' "$outn" | tail -2)";; esac
if [ -f "$RN/.claude/.verify-state/verified" ]; then bad "  ...and writes no stamp" "stamp written"; else ok "  ...and writes no stamp"; fi

echo
echo "NO APP HARNESS: THE DECLARED HARNESS IS THE VERIFICATION"
decl_repo() { # <name> <harness body>
  local R="$TMP/$1"; mkdir -p "$R/.claude"; git -C "$R" init -q . 2>/dev/null
  printf '%s\n' "$2" > "$R/.claude/verify-harness"; printf '%s' "$R"; }
RD=$(decl_repo declpass '# a comment
echo running-the-suite')
outd=$(run_verify "$RD" declpass); rcd=$?
if [ "$rcd" -eq 0 ]; then ok "a passing declared harness verifies (exit 0)"; else bad "a passing declared harness verifies" "exit $rcd: $(printf '%s' "$outd" | tail -2)"; fi
case "$outd" in *running-the-suite*) ok "  ...because it RAN it";; *) bad "  ...because it RAN it" "$outd";; esac
if [ -f "$RD/.claude/.verify-state/verified" ]; then ok "  ...and stamps the Stop gate"; else bad "  ...and stamps the Stop gate" "no stamp"; fi
RF=$(decl_repo declfail 'echo boom; exit 3')
outf=$(run_verify "$RF" declfail); rcf=$?
if [ "$rcf" -ne 0 ]; then ok "CONTROL: a failing declared harness fails ($rcf)"; else bad "CONTROL: a failing declared harness fails" "exit 0"; fi
if [ -f "$RF/.claude/.verify-state/verified" ]; then bad "  ...and writes no stamp" "stamp written"; else ok "  ...and writes no stamp"; fi
RC=$(decl_repo declempty '# only a comment
   # and another')
outc=$(run_verify "$RC" declempty); rcc=$?
if [ "$rcc" -ne 0 ]; then ok "a comment-only declared harness is refused ($rcc), not run as a pass"; else bad "a comment-only declared harness is refused" "exit 0"; fi
case "$outc" in *"holds no command"*) ok "  ...saying it holds no command";; *) bad "  ...saying it holds no command" "$outc";; esac
# A web-shaped verify-harness calls verify.sh. With its verify-* skill deleted,
# verify.sh would run the harness, which runs verify.sh... -- refused instead.
RL=$(decl_repo declloop "bash '$VERIFY'")
outl=$(run_verify "$RL" declloop); rcl=$?
if [ "$rcl" -ne 0 ]; then ok "a harness that calls verify.sh with no app harness is refused ($rcl), not a loop"; else bad "a harness that calls verify.sh with no app harness is refused" "exit 0"; fi
case "$outl" in *"asked for the app harness"*) ok "  ...naming the missing skill";; *) bad "  ...naming the missing skill" "$(printf '%s' "$outl" | tail -2)";; esac

echo
echo "THE APP'S WHOLE PROCESS TREE IS STOPPED, NOT JUST ITS LAUNCHER"
# A real `up` is rarely the server itself: `npm run dev` -> sh -> node puts the
# listener two levels down. Teardown killed the launcher and its direct
# children (`pkill -P`), so the grandchild kept the port -- found running CI in
# a Linux container, where the second pass of a suite was refused with
# "something is already on :PORT" by the first pass's own app. Every fixture
# above uses `exec`, which is exactly why none of them could see it.
RG=$(make_repo grand 200)
python3 - "$RG/.claude/skills/verify-grand/bin/verify-grand" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# `up` becomes a shell that RUNS the server and then does something else, so
# neither bash nor sh can turn it into an exec: the server is a grandchild.
s = s.replace('up) exec python3 -c "', 'up) sh -c "python3 -c \\"\\$0\\"; :" "', 1)
open(p, 'w').write(s)
PY
outg=$(run_verify "$RG" grand); rcg=$?
case "$outg" in
  *"fixture doctor"*) ok "a launcher-wrapped app still gets to doctor (exit $rcg)";;
  *) bad "a launcher-wrapped app still gets to doctor" "$(printf '%s' "$outg" | tail -3)";;
esac
if answers "$(cat "$TMP/port-grand")"; then bad "  ...and when verify returns, the grandchild server is stopped too" "still answering on :$(cat "$TMP/port-grand")"
else ok "  ...and when verify returns, the grandchild server is stopped too"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
