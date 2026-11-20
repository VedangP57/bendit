#!/usr/bin/env bash
# Fixture test for post-edit-review.py. Asserts BOTH that it fires on the real
# defect shapes AND that it stays silent on correct code -- a rule that fires on
# correct code gets the whole hook disabled, which is worse than having no rule.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
H="$D/post-edit-review.py"
T=$(mktemp -d); pass=0; fail=0

# The exit code only says the hook FIRED. The message is what an agent reads and
# acts on. If every case sent it to /dev/null, the wording could rot into
# nonsense with every assertion still green. Each case also records what came
# out, into post-edit-review.expected.
. "$D/expect.sh"
expect_init "$D/post-edit-review.expected"
expect_scrub_dir "$T" '<tmp>'

run() { # <want-exit> <label> <filename> <contents>
  printf '%s' "$4" > "$T/$3"
  expect_capture "$2" python3 "$H" \
    <<<"$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T/$3")"
  local got=$EXPECT_CODE
  if [ "$got" -eq "$1" ]; then printf '  ok    %s\n' "$2"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$2" "$got" "$1"; fail=$((fail+1)); fi
}
echo "MUST FIRE"
run 2 "NEXT_PUBLIC key used to authorize" a.ts \
'const keys=[process.env.NEXT_PUBLIC_SYNC_API_KEY];
const k=req.headers.get("x-api-key"); if(keys.includes(k)) return true;'
run 2 "catch returns success" b.ts \
'try{ await go() }catch(e){ return NextResponse.json({ success: true, result: [] }) }'
run 2 "workaround comment" c.ts '// hardcoded for now, revisit later
const x=1;'
run 2 "@ts-ignore" d.ts '// @ts-ignore
const y: number = "s";'
run 2 "use client touching service role" e.tsx '"use client"
import { adminSupabase } from "@/lib/adminClient";'
# The RLS-bypass LINE_RULE. Its message once appeared in NO case,
# and the createClient half of it could never fire: the class stopped at the
# first comma and `createClient(url, key)` is the only signature Supabase has.
run 2 "rpc() call"                     l.ts 'const { data } = await supabase.rpc("bump_counter", { id });'
run 2 "service role as the SECOND arg" m.ts 'const admin = createClient(url, SERVICE_ROLE_KEY);'
run 2 "service role from the real env var" n.ts 'const admin = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);'
run 2 "secret key read straight"       o.ts 'const k = process.env.SUPABASE_SECRET_KEY;'
echo
echo "MUST BE SILENT"
run 0 "an ordinary createClient with no service role" p.ts 'const supabase = createClient(url, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!);'
run 0 "anon key in a browser client" f.ts \
'const url=process.env.NEXT_PUBLIC_SUPABASE_URL!;
const k=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;
export const supabase=createClient(url,k);'
run 0 "NEXT_PUBLIC in a file with no auth" g.ts \
'const p=process.env.NEXT_PUBLIC_POSTHOG_KEY; posthog.init(p);'
run 0 "catch that rethrows" h.ts 'try{ await go() }catch(e){ console.error(e); throw e }'
run 0 "@ts-expect-error" i.ts '// @ts-expect-error known upstream types
const z: number = legacy();'
run 0 "explanatory why-comment" j.ts '// Stripe sends the event twice; dedupe on event.id.
const seen=new Set();'
run 0 "ordinary component" k.tsx 'export default function C(){ return <div>hi</div> }'

echo
echo "EDIT-SHAPE (old_string/new_string)"
edit() { # <want> <label> <old> <new>
  printf 'const x=1;\n' > "$T/z.ts"
  expect_capture "$2" python3 "$H" <<<"$(python3 -c "import json,sys;print(json.dumps({'tool_name':'Edit','tool_input':{'file_path':sys.argv[1],'old_string':sys.argv[2],'new_string':sys.argv[3]}}))" "$T/z.ts" "$3" "$4")"
  local got=$EXPECT_CODE
  if [ "$got" -eq "$1" ]; then printf '  ok    %s\n' "$2"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$2" "$got" "$1"; fail=$((fail+1)); fi
}
edit 2 "adds ?. and nothing else"        'return config.apiUrl;'  'return config?.apiUrl;'
edit 2 "adds ?? {} and nothing else"     'return cfg.x;'          'return (cfg ?? {}).x;'
edit 0 "adds ?. AND real logic"          'return config.apiUrl;'  'if (!config) throw new Error("init() was never called"); return config.apiUrl;'
edit 0 "unrelated rename"                'const a = 1;'           'const b = 1;'
# `''` inside the raw-string regex was Python string CONCATENATION, so the class
# compiled to `(\{\}|\[\]|0||""|null)` -- an empty alternative that matched any
# `??` -- and the skeleton comparison kept `0`, `''`, `""` and a catch binding,
# so these three band-aids never fired.
edit 2 "adds ?? '' and nothing else"     'return cfg.name;'       "return cfg.name ?? '';"
edit 2 "adds ?? 0 and nothing else"      'return n.count;'        'return n.count ?? 0;'
edit 2 "wraps in try/catch(e){} and nothing else" 'go();'         'try { go(); } catch (e) {}'
edit 0 "?? with a computed default is real logic" 'return n.count;' 'return n.count ?? defaultCount(n);'
rxc=$(python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("per", sys.argv[1]); m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
rx = dict((l, r) for r, l in m.BAND_AID)["a nullish default"]
print("".join("y" if rx.search(t) else "n" for t in ["a ?? x", "a ?? 10", "a ?? 0", "a ?? \x27\x27", "a ?? {}"]))' "$H")
chk_eq() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
           else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
chk_eq "the nullish-default regex matches only literal defaults" "$rxc" "nnyyy"

# LINE RULES JUDGE THE EDIT, NOT THE FILE. An unrelated one-line edit to a file
# that already carried a @ts-ignore exited 2 -- the agent was told to fix code
# it had not touched, on every edit, until it stopped reading the hook.
lined() { # <want> <label> <file-before> <old> <new>
  printf '%s' "$3" > "$T/lr.ts"
  python3 - "$T/lr.ts" "$4" "$5" <<'PY'
import sys; p, o, n = sys.argv[1:]; s = open(p).read(); open(p, 'w').write(s.replace(o, n, 1))
PY
  expect_capture "$2" python3 "$H" <<<"$(python3 -c "import json,sys;print(json.dumps({'tool_name':'Edit','tool_input':{'file_path':sys.argv[1],'old_string':sys.argv[2],'new_string':sys.argv[3]}}))" "$T/lr.ts" "$4" "$5")"
  if [ "$EXPECT_CODE" -eq "$1" ]; then printf '  ok    %s\n' "$2"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$2" "$EXPECT_CODE" "$1"; fail=$((fail+1)); fi
}
PRE='// @ts-ignore
const y: number = "s";
const a = 1;
'
lined 0 "an unrelated edit to a file with an OLD @ts-ignore is silent" "$PRE" 'const a = 1;' 'const a = 2;'
lined 2 "CONTROL: an edit that ADDS a @ts-ignore still fires" "$PRE" 'const a = 1;' '// @ts-ignore
const a = 1;'


echo
echo "SHELL FALSE-PASS RULES"
sh() { # <want> <label> <contents>
  printf '%s' "$3" > "$T/s.sh"
  expect_capture "$2" python3 "$H" \
    <<<"$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T/s.sh")"
  local got=$EXPECT_CODE
  if [ "$got" -eq "$1" ]; then printf '  ok    %s\n' "$2"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$2" "$got" "$1"; fail=$((fail+1)); fi
}
sh 2 "exit status after a pipe"        'psql db -f x.sql | tail -3 && echo "seed OK"'
sh 2 "[ test ] && VAR under set -e"    'set -e
[ -f yarn.lock ] && PM=yarn'
sh 2 "timeout (absent on macOS)"       'timeout 60 claude -p "run the thing"'
printf '%s\n' 'psql "$d" -c "select to_regclass('"'"'"'"'"'"'"'"'public.t'"'"'"'"'"'"'"'"')"' > "$T/s.sh" 2>/dev/null || true
cat > "$T/s.sh" <<'LITERAL'
psql "$d" -c "select to_regclass('"'"'public.t'"'"')"
LITERAL
expect_capture "quote idiom in double quotes" python3 "$H" \
  <<<"$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T/s.sh")"
if [ "$EXPECT_CODE" -eq 2 ]; then printf '  ok    %s\n' "quote idiom in double quotes"; pass=$((pass+1));
else printf '  FAIL  %s\n' "quote idiom in double quotes"; fail=$((fail+1)); fi
echo
echo "SHELL — MUST BE SILENT"
sh 0 "pipefail set, pipe then &&"      'set -eo pipefail
grep x f | head -1 && echo found'
sh 0 "[ test ] && VAR, no set -e"      '[ -f yarn.lock ] && PM=yarn'
sh 0 "if/then instead of && VAR"       'set -e
if [ -f yarn.lock ]; then PM=yarn; fi'
sh 0 "ordinary pipeline"               'cat f | sort | uniq -c'
sh 0 "commented-out trap"              'set -e
# [ -f x ] && VAR=y   <- would be a bug'

pchk() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
pay() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }

# --- the PreToolUse snapshot path: Write and MultiEdit ---
# hooks.json matches Write|Edit|MultiEdit on BOTH passes, and nothing here ever
# sent a Write payload or ran --pre. The band-aid rule needs a before and an
# after; only Edit carries both in its payload. Write sends the whole new file
# and MultiEdit sends an `edits` array, so both rely on the snapshot --
# untested, and MultiEdit did not work at all.
echo
echo "SNAPSHOT PATH (--pre, then Write / MultiEdit)"
# wsnap <want-exit> <label> <tool> <before> <after> [extra-input-json]
wsnap() {
  local want="$1" label="$2" tool="$3" before="$4" after="$5" extra="${6:-}"
  printf '%s' "$before" > "$T/w.ts"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$T/w.ts"     | python3 "$H" --pre >/dev/null 2>&1
  printf '%s' "$after" > "$T/w.ts"
  expect_capture "$label" python3 "$H" <<<"$(python3 -c "
import json,sys
ti = {'file_path': sys.argv[1]}
ti.update(json.loads(sys.argv[3]) if sys.argv[3] else {})
print(json.dumps({'tool_name': sys.argv[2], 'tool_input': ti}))" "$T/w.ts" "$tool" "$extra")"
  if [ "$EXPECT_CODE" -eq "$want" ]; then printf '  ok    %s\n' "$label"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$label" "$EXPECT_CODE" "$want"; fail=$((fail+1)); fi
}

wsnap 2 "Write that only adds ?." Write   'return config.apiUrl;' 'return config?.apiUrl;'   '{"content": "return config?.apiUrl;"}'
wsnap 0 "Write that also changes real logic" Write   'return config.apiUrl;' 'if (!config) throw new Error("init() was never called"); return config.apiUrl;'   '{"content": "if (!config) throw new Error(\"init() was never called\"); return config.apiUrl;"}'
# MultiEdit sends an `edits` array and no content: the snapshot and the file on
# disk are the only before and after there is.
wsnap 2 "MultiEdit that only adds ?." MultiEdit   'return config.apiUrl;' 'return config?.apiUrl;'   '{"edits": [{"old_string": "a", "new_string": "b"}]}'
wsnap 0 "MultiEdit that also changes real logic" MultiEdit   'return config.apiUrl;' 'if (!config) throw new Error("init() was never called"); return config.apiUrl;'   '{"edits": [{"old_string": "a", "new_string": "b"}]}'

# No --pre ran (a brand new file): there is nothing to diff against, and the
# hook must stay silent rather than treat an empty before as "everything added".
printf 'return config?.apiUrl;\n' > "$T/fresh.ts"
expect_capture "a Write with no snapshot is silent about band-aids" python3 "$H" \
  <<<"$(python3 -c "
import json,sys
print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':'return config?.apiUrl;\n'}}))" "$T/fresh.ts")"
pchk "no snapshot, no band-aid claim" "$(printf '%s' "$EXPECT_OUT" | grep -c 'adds optional chaining')" 0

# The snapshot is consumed. A second pass with no new --pre must not re-judge
# the same file against a stale before.
printf 'return cfg.x;\n' > "$T/w.ts"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$T/w.ts" | python3 "$H" --pre >/dev/null 2>&1
printf 'return cfg?.x;\n' > "$T/w.ts"
paySnap() { python3 -c "
import json,sys
print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':open(sys.argv[1]).read()}}))" "$1"; }
first=$(paySnap "$T/w.ts" | python3 "$H" 2>&1 >/dev/null | grep -c 'adds optional chaining')
second=$(paySnap "$T/w.ts" | python3 "$H" 2>&1 >/dev/null | grep -c 'adds optional chaining')
pchk "the snapshot fires once"          "$first"  1
pchk "and is consumed, not re-used"     "$second" 0

# hooks.json runs --pre before EVERY Write|Edit|MultiEdit, but only the
# Write/MultiEdit branch ever deleted the snapshot, so every Edit left one
# behind in $TMPDIR/bendit-snap for good.
SNAPT="$T/snaptmp"; mkdir -p "$SNAPT"
printf 'const x = 1;\n' > "$T/e.ts"
editpay() { python3 -c "import json,sys;print(json.dumps({'session_id':'s1','tool_name':'Edit','tool_input':{'file_path':sys.argv[1],'old_string':'const x = 1;','new_string':'const x = 2;'}}))" "$T/e.ts"; }
editpay | TMPDIR="$SNAPT" python3 "$H" --pre >/dev/null 2>&1
printf 'const x = 2;\n' > "$T/e.ts"
editpay | TMPDIR="$SNAPT" python3 "$H" >/dev/null 2>&1
pchk "an Edit consumes its --pre snapshot too" "$(/usr/bin/find "$SNAPT" -type f | wc -l | tr -d ' ')" 0

# Snapshots were keyed by PATH alone, so two sessions editing one file shared a
# snapshot: B's --pre overwrote A's "before", and A's band-aid went unseen.
spay() { python3 -c "import json,sys;print(json.dumps({'session_id':sys.argv[2],'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':open(sys.argv[1]).read()}}))" "$T/sx.ts" "$1"; }
printf 'return config.apiUrl;\n' > "$T/sx.ts"
spay A | TMPDIR="$SNAPT" python3 "$H" --pre >/dev/null 2>&1
printf 'return config?.apiUrl;\n' > "$T/sx.ts"          # A's write lands
spay B | TMPDIR="$SNAPT" python3 "$H" --pre >/dev/null 2>&1   # B snapshots A's result
pchk "session A is judged against ITS OWN before, not B's" \
  "$(spay A | TMPDIR="$SNAPT" python3 "$H" 2>&1 >/dev/null | grep -c 'adds optional chaining')" 1

# --- malformed payloads, and a crash inside the review ---
echo
echo "MALFORMED PAYLOADS AND CRASHES"
# A payload of the wrong shape has no file to review: ignored, not a traceback.
pchk "payload is a list"        "$(echo '[1,2]' | python3 "$H" >/dev/null 2>&1; echo $?)" 0
pchk "tool_input is a string"   "$(echo '{"tool_input":"x"}' | python3 "$H" >/dev/null 2>&1; echo $?)" 0
pchk "file_path is a number"    "$(echo '{"tool_input":{"file_path":7}}' | python3 "$H" >/dev/null 2>&1; echo $?)" 0
pchk "--pre: payload is a list" "$(echo '[1,2]' | python3 "$H" --pre >/dev/null 2>&1; echo $?)" 0
pchk "--pre: tool_input string" "$(echo '{"tool_input":"x"}' | python3 "$H" --pre >/dev/null 2>&1; echo $?)" 0
# A crash in the review must be SAID (exit 2, reason on stderr), never a silent
# exit 1 that reads as "nothing to report". Forced by replacing the reviewer
# with one that raises.
printf 'const x = 1;\n' > "$T/c.ts"
crash() {
  pay "$T/c.ts" | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(*_a): raise RuntimeError("synthetic")
guard._review = boom
sys.exit(guard.run(sys.argv[2:]))' "$H" 2>&1 >/dev/null
  echo "exit=$?"
}
case "$(crash)" in
  *"review itself failed"*"exit=2") printf '  ok    %s\n' "a crash inside the review exits 2 with a reason"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash inside the review exits 2 with a reason" "$(crash | tail -1)"; fail=$((fail+1));;
esac

# --- advisory notes: the plan linter and the missing-import check ---
# Both ride on additionalContext (stdout, exit 0). They are ADVICE: a clean file
# prints nothing, and nothing they do may change the hook's exit status.
echo
echo "ADVISORY NOTES (plan linter, missing imports)"
# Every helper is defined before its first call.
note_of() { # <path> -> the additionalContext text, empty when the hook said nothing
  pay "$1" | python3 "$H" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
print(json.loads(raw)["hookSpecificOutput"]["additionalContext"] if raw.strip() else "", end="")'
}
code_of() { pay "$1" | python3 "$H" >/dev/null 2>&1; echo $?; }
has() { case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

PR="$T/proj"; mkdir -p "$PR/docs/superpowers/plans" "$PR/docs/superpowers/specs" "$PR/docs/plans"
echo "# Word Count Spec" > "$PR/docs/superpowers/specs/real-spec.md"
sed -n "/<<'PLAN'/,/^PLAN\$/p" "$D/check-plan.test.sh" | sed '1d;$d' > "$PR/docs/superpowers/plans/2026-01-01-good.md"
grep -v '^## Review Focus' "$PR/docs/superpowers/plans/2026-01-01-good.md" > "$PR/docs/superpowers/plans/2026-01-01-noreview.md"
cp "$PR/docs/superpowers/plans/2026-01-01-noreview.md" "$PR/docs/plans/2026-01-01-noreview.md"

pchk "a complete plan is silent"           "$(note_of "$PR/docs/superpowers/plans/2026-01-01-good.md")" ""
expect_capture "plan note wording" python3 "$H" <<<"$(pay "$PR/docs/superpowers/plans/2026-01-01-noreview.md")"
n="$(note_of "$PR/docs/superpowers/plans/2026-01-01-noreview.md")"
pchk "a plan missing ## Review Focus gets a note naming it" "$(has "$n" '## Review Focus')" yes
pchk "the plan note is advisory: exit 0"   "$(code_of "$PR/docs/superpowers/plans/2026-01-01-noreview.md")" 0
pchk "the same content under docs/plans/ is not a superpowers plan: silent" \
  "$(note_of "$PR/docs/plans/2026-01-01-noreview.md")" ""

MOD="$T/plug/hooks"; mkdir -p "$MOD" "$T/plain/src"
printf '{"hooks":{}}\n' > "$MOD/hooks.json"
printf 'export const SHOWN_LIMIT_MS = 1\n' > "$MOD/roster.ts"
printf 'const f = (n) => n > SHOWN_LIMIT_MS\n' > "$MOD/index.ts"
printf 'export const SHOWN_LIMIT_MS = 1\n' > "$T/plain/src/roster.ts"
printf 'const f = (n) => n > SHOWN_LIMIT_MS\n' > "$T/plain/src/index.ts"
expect_capture "missing-import note wording" python3 "$H" <<<"$(pay "$MOD/index.ts")"
n="$(note_of "$MOD/index.ts")"
pchk "a mod file using an un-imported sibling export gets a note" "$(has "$n" 'SHOWN_LIMIT_MS is used here')" yes
pchk "the import note is advisory: exit 0" "$(code_of "$MOD/index.ts")" 0
pchk "the same code in a directory with no hooks.json is silent" "$(note_of "$T/plain/src/index.ts")" ""
printf 'import { SHOWN_LIMIT_MS } from "./roster"\nconst f = (n) => n > SHOWN_LIMIT_MS\n' > "$MOD/index.ts"
pchk "CONTROL: once imported, the mod file is silent" "$(note_of "$MOD/index.ts")" ""

# Advice must never break the hook. Copy the plugin's scripts, break each
# checker so it raises (or, for the import check, crashes with a traceback and
# exit 1), and require: exit 0, no output.
BR="$T/broken"; mkdir -p "$BR"
cp "$D/post-edit-review.py" "$D/check-plan.py" "$D/check-mod-imports.py" "$BR/"
printf 'def advise(path):\n    raise RuntimeError("synthetic")\n' > "$BR/check-plan.py"
printf 'raise RuntimeError("synthetic")\n' > "$BR/check-mod-imports.py"
printf 'const f = (n) => n > SHOWN_LIMIT_MS\n' > "$MOD/index.ts"
bout="$(pay "$PR/docs/superpowers/plans/2026-01-01-noreview.md" | python3 "$BR/post-edit-review.py" 2>&1)"; bcode=$?
pchk "a crash inside advise() yields exit 0" "$bcode" 0
pchk "and no note" "$bout" ""
bout="$(pay "$MOD/index.ts" | python3 "$BR/post-edit-review.py" 2>&1)"; bcode=$?
pchk "a crash inside the import checker yields exit 0" "$bcode" 0
pchk "and its traceback is not passed off as a note" "$bout" ""

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

rm -rf "$T"
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
