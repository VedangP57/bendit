#!/usr/bin/env bash
# Both halves of a path contract are tested: it must REFUSE the file that claims
# the contract and breaks it, and stay SILENT on the file that claims nothing.
# A rule that fires on ordinary files would be uninstalled within a day.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
H="$SD/path-contracts.py"
pass=0; fail=0
. "$SD/expect.sh"
expect_init "$SD/path-contracts.expected"

chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
# w <path> <content> -- print a Write payload
w() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":%s}}' "$1" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")"; }
run() { python3 "$H" >/dev/null 2>&1; echo $?; }

# --- .hot.*: refuses each allocating shape -----------------------------------
chk "hot + new"               "$(w /x/a.hot.ts 'const v = new Vec3()'        | run)" "2"
chk "hot + arrow closure"     "$(w /x/a.hot.ts 'xs.forEach(x => x)'          | run)" "2"
chk "hot + object literal"    "$(w /x/a.hot.ts 'return { x: 1, y: 2 }'       | run)" "2"
chk "hot + .map"              "$(w /x/a.hot.ts 'const b = xs.map(f)'         | run)" "2"
chk "hot + spread"            "$(w /x/a.hot.ts 'const b = [...xs]'           | run)" "2"
chk "hot + template literal"  "$(w /x/a.hot.ts 'log(`tick ${n}`)'            | run)" "2"

# --- .hot.*: allows allocation-free code -------------------------------------
chk "hot, no allocation, allowed" \
    "$(w /x/a.hot.ts 'let i = 0; i += 1; out.x = a.x + b.x; return i' | run)" "0"

# --- the contract is OPT-IN: an ordinary file is never touched ---------------
chk "ordinary .ts allocating freely is allowed" \
    "$(w /x/a.ts 'const o = { a: 1 }; const f = () => new Map([...xs])' | run)" "0"
chk "a .hot in the DIRECTORY name does not count" \
    "$(w /x/hot/a.ts 'const f = () => 1' | run)" "0"

# --- .gen.*: refused outright ------------------------------------------------
chk "generated file is refused"        "$(w /x/types.gen.ts 'export type A = 1' | run)" "2"
chk "generated sql is refused"         "$(w /x/schema.gen.sql 'select 1'        | run)" "2"
chk "a file merely named generated.ts" "$(w /x/generated.ts 'select 1'          | run)" "0"

# --- MultiEdit carries an `edits` ARRAY and neither of the other shapes. A rule
# --- that reads only new_string/content has never once applied to it here.
ME='{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.hot.ts","edits":[{"old_string":"a","new_string":"let i = 0"},{"old_string":"b","new_string":"const f = () => 1"}]}}'
chk "MultiEdit into a .hot file is refused" "$(echo "$ME" | run)" "2"
MEOK='{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/a.hot.ts","edits":[{"old_string":"a","new_string":"i += 1"}]}}'
chk "MultiEdit with no allocation is allowed" "$(echo "$MEOK" | run)" "0"

# --- malformed input must never crash a turn ---------------------------------
chk "junk stdin is allowed, not a crash" "$(echo 'not json' | run)" "0"
chk "no file_path is allowed"            "$(echo '{"tool_name":"Write","tool_input":{}}' | run)" "0"
chk "tool_input is a string"             "$(echo '{"tool_name":"Write","tool_input":"x"}' | run)" "0"
chk "tool_input is a list"               "$(echo '{"tool_name":"Write","tool_input":["x"]}' | run)" "0"
chk "payload is a list"                  "$(echo '[1]' | run)" "0"
chk "edits holds a non-object"           "$(echo '{"tool_input":{"file_path":"/x/a.hot.ts","edits":["new Foo()"]}}' | run)" "0"

# --- names that claimed a contract and once escaped it -----------------------
chk "types.gen.d.ts is generated"        "$(w /x/types.gen.d.ts 'export type A = 1' | run)" "2"
chk "api.gen.d.ts is generated"          "$(w /x/api.gen.d.ts 'x'                   | run)" "2"
chk "foo.GEN.ts, any case"               "$(w /x/foo.GEN.ts 'x'                     | run)" "2"
chk "a.hot.mts is hot"                   "$(w /x/a.hot.mts 'const v = new Vec3()'   | run)" "2"
chk "a.hot.mjs is hot"                   "$(w /x/a.hot.mjs 'const v = new Vec3()'   | run)" "2"
chk "a.hot.cjs is hot"                   "$(w /x/a.hot.cjs 'const v = new Vec3()'   | run)" "2"
chk "a.HOT.ts, any case"                 "$(w /x/a.HOT.ts 'const v = new Vec3()'    | run)" "2"
chk "CONTROL: hotel.ts is not hot"       "$(w /x/hotel.ts 'const v = new Vec3()'    | run)" "0"
chk "CONTROL: gene.ts is not generated"  "$(w /x/gene.ts 'x'                        | run)" "0"

# --- declarations and comments are not allocations ---------------------------
# A function DECLARED in a hot file is the hot path itself; declaring it does
# not allocate per tick. A type is erased. A comment is not code.
chk "a function declaration"             "$(w /x/a.hot.ts 'export function tick(dt: number) { i += dt }' | run)" "0"
chk "an async function declaration"      "$(w /x/a.hot.ts 'export async function step(n: number) { i += n }' | run)" "0"
chk "a type alias with an object type"   "$(w /x/a.hot.ts 'type P = { x: number }' | run)" "0"
chk "an interface"                       "$(w /x/a.hot.ts 'export interface P { x: number; y: number }' | run)" "0"
chk "a line comment with =>"             "$(w /x/a.hot.ts '// a => b
i += 1' | run)" "0"
chk "a block comment with new"           "$(w /x/a.hot.ts '/* never new Foo() here */ i += 1' | run)" "0"
chk "a // inside a string is not a comment" "$(w /x/a.hot.ts "const u = 'http://x'; const v = new Vec3()" | run)" "2"
# ...but what is INSIDE the declared function is still the hot path.
chk "CONTROL: closure inside a declared function" "$(w /x/a.hot.ts 'export function tick() { xs.forEach(x => x) }' | run)" "2"
chk "CONTROL: nested function expression" "$(w /x/a.hot.ts 'export function tick() { run(function () {}) }' | run)" "2"
chk "CONTROL: object literal inside it"   "$(w /x/a.hot.ts 'export function tick() { return { x: 1 } }' | run)" "2"

# --- allocating shapes the list missed -----------------------------------------
chk "array literal"                      "$(w /x/a.hot.ts 'const p = [x, y]'           | run)" "2"
chk "returned array literal"             "$(w /x/a.hot.ts 'return [x, y]'              | run)" "2"
chk "empty object"                       "$(w /x/a.hot.ts 'const o = {}'               | run)" "2"
chk "shorthand object"                   "$(w /x/a.hot.ts 'emit({x, y})'               | run)" "2"
chk "quoted-key object"                  "$(w /x/a.hot.ts "const o = { 'x': 1 }"       | run)" "2"
chk "Array.from"                         "$(w /x/a.hot.ts 'const a = Array.from(s)'    | run)" "2"
chk "Object.assign"                      "$(w /x/a.hot.ts 'Object.assign(o, p)'        | run)" "2"
chk ".join"                              "$(w /x/a.hot.ts 'const s = xs.join(",")'     | run)" "2"
chk "string concatenation"               "$(w /x/a.hot.ts "const s = 'id-' + n"        | run)" "2"
chk "CONTROL: indexing is not a literal" "$(w /x/a.hot.ts 'out[i] = xs[i] + ys[i]'      | run)" "0"
chk "CONTROL: array destructuring"       "$(w /x/a.hot.ts 'const [a, b] = pair'        | run)" "0"
chk "CONTROL: numeric addition"          "$(w /x/a.hot.ts 'i = a + b'                  | run)" "0"
chk "CONTROL: if block"                  "$(w /x/a.hot.ts 'if (x) { i += 1 }'          | run)" "0"

# --- a crash inside the guard REFUSES the write -------------------------------
# Exit 1 from a traceback is non-blocking to Claude Code: the write would land
# unchecked. Forced by replacing the allocation scan with one that raises.
crash() {
  w /x/a.hot.ts 'const v = 1' | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
def boom(_text): raise RuntimeError("synthetic")
guard.allocations = boom
sys.exit(guard.run())' "$H" 2>&1 >/dev/null
  echo "exit=$?"
}
case "$(crash)" in
  *"guard itself failed"*"exit=2") printf '  ok    %s\n' "a crash inside the guard refuses"; pass=$((pass+1));;
  *) printf '  FAIL  %s: %s\n' "a crash inside the guard refuses" "$(crash | tail -1)"; fail=$((fail+1));;
esac

# What it SAYS is the only thing telling the agent what to do instead.
expect_capture "hot: allocation refused" python3 "$H" <<< "$(w /x/particles.hot.ts 'const v = new Vec3()')"
expect_capture "gen: refused outright"   python3 "$H" <<< "$(w /x/types.gen.ts 'export type A = 1')"
echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
