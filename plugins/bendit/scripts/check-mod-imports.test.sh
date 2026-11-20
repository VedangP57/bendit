#!/usr/bin/env bash
# Fixtures for check-mod-imports.py.
#
# Half of these are MUST BE SILENT. A check that fires on correct code gets the
# whole thing switched off, and this one scans every mod file on every run -- so
# the prose, the strings and the property names that look like constants matter
# more than the defect does.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
CHK="$D/check-mod-imports.py"
pass=0; fail=0
pchk2() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
          else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. "$D/expect.sh"
expect_init "$D/check-mod-imports.expected"
expect_scrub_dir "$T" '<tmp>'

# case <want-exit> <label> <roster.ts body> <index.ts body>
case_() {
  local want="$1" label="$2"
  rm -rf "$T/c"; mkdir -p "$T/c"
  printf '%s\n' "$3" > "$T/c/roster.ts"
  printf '%s\n' "$4" > "$T/c/index.ts"
  expect_capture "$label" python3 "$CHK" "$T/c"
  if [ "$EXPECT_CODE" -eq "$want" ]; then printf '  ok    %s\n' "$label"; pass=$((pass+1))
  else printf '  FAIL  %s (exit %s, wanted %s)\n' "$label" "$EXPECT_CODE" "$want"; fail=$((fail+1)); fi
}

EXP='export const SHOWN_LIMIT_MS = 3600000
export const mergeEntry = (a) => a
export const KEY = "k/"'

echo "MUST FIRE"
case_ 1 "used in an expression, never imported" "$EXP" \
'const f = (n) => n > SHOWN_LIMIT_MS'
case_ 1 "used inside a template literal" "$EXP" \
'const f = () => `cap ${SHOWN_LIMIT_MS}`'
case_ 1 "imported SOME names but not this one" "$EXP" \
'import { KEY } from "./roster"
const f = (n) => KEY + (n > SHOWN_LIMIT_MS)'
# Only all-caps names were ever checked, so 12 of the 21 bindings index.ts
# imports from roster.ts -- every camelCase one -- carried the identical defect
# unreported. The docstring claimed the general rule; the regex added "and be
# SCREAMING_SNAKE".
case_ 1 "a camelCase sibling export" "$EXP" \
'const f = (e) => mergeEntry(e)'
case_ 1 "an async function export" 'export async function fetchAll() { return 1 }' \
'const f = () => fetchAll()'
case_ 1 "an export default function" 'export default function bigThing() {}' \
'const f = () => bigThing()'
# Two regex literals holding an apostrophe put a lone quote in the source twice;
# the string stripper paired THOSE and blanked the real reference between them.
case_ 1 "a reference between two apostrophe regexes" "$EXP" \
'const a = s.replace(/x/g, "A") + SHOWN_LIMIT_MS + s.replace(/y/g, "B")'

echo
echo "MUST BE SILENT"
case_ 0 "imported in braces" "$EXP" \
'import { SHOWN_LIMIT_MS } from "./roster"
const f = (n) => n > SHOWN_LIMIT_MS'
case_ 0 "imported under an alias" "$EXP" \
'import { SHOWN_LIMIT_MS as CAP } from "./roster"
const f = (n) => n > CAP'
case_ 0 "imported alongside a type" "$EXP" \
'import { type Entry, SHOWN_LIMIT_MS } from "./roster"
const f = (n) => n > SHOWN_LIMIT_MS'
case_ 0 "declared locally, shadowing the sibling" "$EXP" \
'const SHOWN_LIMIT_MS = 1
const f = (n) => n > SHOWN_LIMIT_MS'
case_ 0 "only named in a line comment" "$EXP" \
'// SHOWN_LIMIT_MS bounds how long the line is shown
const f = (n) => n > 1'
case_ 0 "only named in a block comment" "$EXP" \
'/** The SHOWN_LIMIT_MS bound applies to every state. */
const f = (n) => n > 1'
case_ 0 "only named in a string" "$EXP" \
'const why = "SHOWN_LIMIT_MS was exceeded"'
case_ 0 "a property of the same name" "$EXP" \
'const f = (o) => o.SHOWN_LIMIT_MS'
case_ 0 "a name no sibling exports" "$EXP" \
'const f = () => PROCESS_ENV_THING'
# Every shape below was a confirmed false positive before it was fixed. A check
# that fires on correct code gets switched off, so these outnumber the firing
# cases on purpose.
case_ 0 "a re-export needs no import" "$EXP" \
'export { SHOWN_LIMIT_MS } from "./roster"'
case_ 0 "an object-literal key" "$EXP" \
'const o = { SHOWN_LIMIT_MS: 1 }'
case_ 0 "destructured from something else" "$EXP" \
'const { SHOWN_LIMIT_MS } = opts
const f = () => SHOWN_LIMIT_MS'
case_ 0 "a function parameter" "$EXP" \
'function f(SHOWN_LIMIT_MS) { return SHOWN_LIMIT_MS }'
case_ 0 "an arrow parameter" "$EXP" \
'const f = (mergeEntry) => mergeEntry(1)'
case_ 0 "prose inside a template literal" "$EXP" \
'const help = `tune SHOWN_LIMIT_MS to change this`'
case_ 0 "a name inside a regex literal" "$EXP" \
'const a = s.replace(/SHOWN_LIMIT_MS/g, "x")'
case_ 0 "division is not a regex literal" "$EXP" \
'const SHOWN_LIMIT_MS = 1
const r = width / height / 2'
# EXPORTED read the RAW text, so an `export const` inside a block comment
# counted as a sibling export and made every mention of the name a finding.
case_ 0 "a sibling export inside a block comment" '/** export const SHOWN_LIMIT_MS = 1 */
export const KEY = "k/"' \
'const f = (n) => n > SHOWN_LIMIT_MS'
case_ 1 "CONTROL: a real reference inside \${}" "$EXP" \
'const f = () => `cap ${SHOWN_LIMIT_MS}`'
case_ 0 "re-exported by this file itself" 'export const KEY = "k/"' \
'export const SHOWN_LIMIT_MS = 1
const f = (n) => n > SHOWN_LIMIT_MS'

# A parameter binds a name inside ITS function only. The bound set was
# file-wide, so a parameter called SHOWN_LIMIT_MS in one function silenced a
# genuinely unimported use in every other function of the file.
case_ 1 "a parameter in one function does not bind another" "$EXP" \
'function f(SHOWN_LIMIT_MS) { return SHOWN_LIMIT_MS }
const g = () => SHOWN_LIMIT_MS'
case_ 1 "an if (...) condition is not a parameter list" "$EXP" \
'if (SHOWN_LIMIT_MS > 1) { go() }'
case_ 0 "CONTROL: the parameter is still bound inside its own body" "$EXP" \
'const f = (SHOWN_LIMIT_MS) => {
  const g = () => SHOWN_LIMIT_MS + 1
  return g()
}'

echo
echo "IMPORTS THE SIBLING DOES NOT EXPORT"
case_ 1 "importing a name the sibling does not export" "$EXP" \
'import { NOT_THERE } from "./roster"
const f = () => NOT_THERE'
case_ 0 "CONTROL: a name it does export, spelled ./roster.js" "$EXP" \
'import { KEY } from "./roster.js"
const f = () => KEY'
case_ 0 "type exports count for an import" 'export type Entry = { a: 1 }
export interface Row { b: 2 }' \
'import type { Entry, Row } from "./roster"
const f = (e: Entry, r: Row) => e'
case_ 0 "a sibling with export * cannot be judged, so it is not" 'export * from "./elsewhere"' \
'import { ANYTHING } from "./roster"
const f = () => ANYTHING'

echo
echo "EXPORT LISTS"
# `export { X }` was invisible: only `export const|function|...` counted.
case_ 1 "a name exported by an export { } list, used unimported" \
'const LIST_LIMIT_MS = 1
function helper() {}
export { LIST_LIMIT_MS, helper as renamedHelper }' \
'const f = (n) => n > LIST_LIMIT_MS && renamedHelper()'
case_ 0 "CONTROL: the export { } name imported" \
'const LIST_LIMIT_MS = 1
export { LIST_LIMIT_MS }' \
'import { LIST_LIMIT_MS } from "./roster"
const f = (n) => n > LIST_LIMIT_MS'

echo
echo "RECURSION — a mod's subdirectories are checked too"
# A caller that passes a mod's top directory must still reach the modules in
# its subdirectories; iterdir() alone did not descend.
rm -rf "$T/r"; mkdir -p "$T/r/sub"
printf 'export const TOP = 1\n' > "$T/r/top.ts"
printf '%s\n' "$EXP" > "$T/r/sub/roster.ts"
printf 'const f = (n) => n > SHOWN_LIMIT_MS\n' > "$T/r/sub/index.ts"
expect_capture "a defect one directory down" python3 "$CHK" "$T/r"
pchk2 "a defect one directory down is found from the parent" "$EXPECT_CODE" 1
python3 "$CHK" --no-recurse "$T/r" >/dev/null 2>&1
pchk2 "--no-recurse checks only the directory given" "$?" 0
# Siblings are files in the SAME directory: a parent's export is not one.
printf 'const f = () => TOP\n' > "$T/r/sub/index.ts"
python3 "$CHK" "$T/r" >/dev/null 2>&1
pchk2 "a parent directory's export is not a sibling export" "$?" 0

echo
echo "A PATH THAT IS NOT A DIRECTORY"
# `main()` exited 0 for a missing path, so the real-world case below could not
# fail: rename the directory and it stayed green, having scanned nothing.
python3 "$CHK" "$T/definitely-not-here" >/dev/null 2>&1
pchk2 "a missing directory exits non-zero" "$?" 2
python3 "$CHK" "$D/check-mod-imports.py" >/dev/null 2>&1
pchk2 "a file passed by mistake exits non-zero" "$?" 2

echo
echo "A CLEAN PLUGIN DIRECTORY — a fixture mod with correct imports is silent"
# Stands in for a committed mod: a hooks.json, a module that exports, and a
# module that imports what it uses, one directory down as well.
rm -rf "$T/plug"; mkdir -p "$T/plug/hooks/sub"
printf '{"hooks":{}}\n' > "$T/plug/hooks/hooks.json"
printf 'export const LIMIT = 1\nexport function go() {}\n' > "$T/plug/hooks/roster.ts"
printf 'import { LIMIT, go } from "./roster"\nconst f = () => go() + LIMIT\n' > "$T/plug/hooks/index.ts"
printf 'export const DEEP = 1\n' > "$T/plug/hooks/sub/a.ts"
printf 'import { DEEP } from "./a"\nconst g = () => DEEP\n' > "$T/plug/hooks/sub/b.ts"
python3 "$CHK" "$T/plug/hooks" >/dev/null 2>&1
pchk2 "the fixture plugin's hooks/ has no unimported sibling exports" "$?" 0
# CONTROL: the same directory with one import removed must fail, or the case
# above could not tell a clean mod from an unscanned one.
printf 'import { go } from "./roster"\nconst f = () => go() + LIMIT\n' > "$T/plug/hooks/index.ts"
python3 "$CHK" "$T/plug/hooks" >/dev/null 2>&1
pchk2 "CONTROL: dropping one import from the fixture fails it" "$?" 1

echo
echo "WHAT IT SAYS (snapshot)"
expect_verify || fail=$((fail+1))

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
