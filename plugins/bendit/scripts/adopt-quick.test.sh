#!/usr/bin/env bash
# The words a person reads at the END of /bendit:adopt (quick) and
# /bendit:doctor, and the one undo command quick.md hands them.
#
# Why it exists: v0.4.0 ran fine on a real project, but its two last steps
# (approve the check in a new Terminal; close and reopen Claude) scrolled away
# above a long report, and /bendit:doctor ended in engineer words without
# saying "reopen Claude". These are prompts, so the text IS the behaviour: this
# pins the endings, and RUNS the undo command exactly as quick.md prints it
# (with the template's indent, as a person pastes it, and without), on bash and
# on every python3 here.
#
#   bash adopt-quick.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
QUICK="$KIT/skills/adopt-bendit/references/quick.md"
DOCTOR="$KIT/commands/doctor.md"
LAYER="$KIT/skills/adopt-bendit/references/project-layer.md"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2')" n y;; esac; }
hasnt() { case "$3" in *"$2"*) chk "$1 (found '$2')" n y;; *) chk "$1" y y;; esac; }

# block <file> <heading regex> <n> -- the n-th fenced block (1-based) after the
# first line matching the heading, without its fences.
block() {
  awk -v h="$2" -v n="$3" '
    !go && $0 ~ h { go = 1; next }
    go && /^```/ { k++; if (k == 2 * n - 1) { on = 1; next } if (k == 2 * n) exit }
    on { print }' "$1"
}

STEP2='Close Claude and open it again in this project, then type /bendit:doctor.'

echo "QUICK: THE REPORT ENDS WITH WHAT TO DO NEXT"
REPORT="$(block "$QUICK" '^## 6\. The report' 1)"
chk "the report template was found" "$([ -n "$REPORT" ] && echo y || echo n)" y
# The last four non-empty lines of the template, exactly the owner's wording.
tail4="$(printf '%s\n' "$REPORT" | grep -v '^[[:space:]]*$' | tail -n 4)"
chk "its last lines are the two last steps, and nothing after them" "$tail4" \
"Two last steps:
  1. Open a new Terminal window (not this chat), paste this, and type y:
       <the exact --trust command prove.sh printed, e.g. python3 \"<KIT>/scripts/require-verification.py\" --trust \"<ROOT>\">
  2. $STEP2"
first="$(printf '%s\n' "$REPORT" | grep -v '^[[:space:]]*$' | head -n 1)"
chk "  ...and it still opens with the header" "$first" "<header>"
rec="$(printf '%s\n' "$REPORT" | grep -n 'What I did (for the record' | cut -d: -f1)"
steps="$(printf '%s\n' "$REPORT" | grep -n '^Two last steps:' | cut -d: -f1)"
chk "  ...the record comes BEFORE the steps" "$([ -n "$rec" ] && [ -n "$steps" ] && [ "$rec" -lt "$steps" ] && echo y || echo n)" y
RULES="$(sed -n '/^## 6\. The report/,$p' "$QUICK")"
has "only step 2 left (the check already approved): one last step" "One last step:" "$RULES"
has "  ...worded as the ruling says" "$STEP2" "$RULES"
Q_TXT="$(cat "$QUICK")"
has "step 9 asks whether this window is already live" 'scripts/selfcheck.py" --session' "$Q_TXT"
has "  ...and then leaves step 2 out" "then last step 2 is left out" "$Q_TXT"
has "step 9 always runs the live test (unless --session says to skip it)" "Always run the live force-push check" "$Q_TXT"
hasnt "the person is never asked to type a force push" "run: git push" "$Q_TXT"
# 2026-11-22: setup ran the installer's own copy (bendit@inline), its refusal
# dropped "reopen Claude", and the reopened window ran an older INSTALLED bendit.
# A refusal counts only when --session's copy: line says the installed copy ran.
has "step 9 reads the copy: line" '`copy:` line' "$Q_TXT"
has "  ...step 2 is left out only for the installed copy, refused by bendit" \
    'A refusal by bendit with `copy: installed` means this window already runs the bendit installed for this project: then last step 2 is left out.' "$Q_TXT"
has "  ...the installer's copy, or any other copy, keeps step 2" '`copy: installer copy` or `copy: other copy`, step 2 stays' "$Q_TXT"
echo
echo "DETAILED: PROVE.MD FOLLOWS THE SAME REOPEN RULE"
P_TXT="$(cat "$KIT/skills/adopt-bendit/references/prove.md")"
has "PASS needs the installed copy" 'and `python3 "$KIT/scripts/selfcheck.py" --session` says `copy: installed` | **PASS**, rung 5 |' "$P_TXT"
has "  ...any other copy is not a PASS, and the reopen step stays" '`copy: installer copy` or `copy: other copy` | **passed in the setup copy, not this project' "$P_TXT"
has "  ...SKILL.md step 5 says it too" 'It is a PASS only when' "$(cat "$KIT/skills/adopt-bendit/SKILL.md")"
hasnt "  ...the old row (any bendit refusal is PASS) is gone" '`[bendit] ...`) | **PASS**, rung 5 |' "$P_TXT"
hasnt "  ...the old rule (any refusal drops step 2) is gone" 'A refusal by bendit means this window is
   already protected' "$Q_TXT"
has "the report's 'everything passed' needs the installed copy too" 'refused by bendit in this window with `copy: installed`' "$Q_TXT"
echo
echo "QUICK: STEP 2b SAYS WHICH BENDIT EACH CHECKOUT WILL LOAD"
S5="$(sed -n '/^## 5\. Do it/,/^## 6\./p' "$QUICK")"
has "step 2b exists" '2b. **Which bendit each checkout will load.**' "$S5"
has "  ...runs installed-versions on ROOT" 'scripts/installed-versions.py" --root "$ROOT"' "$S5"
has "  ...updates THIS folder only" 'only the command for the line marked `(this folder)`' "$S5"
has "  ...never another checkout" 'Never run the command for another checkout' "$S5"
l2="$(printf '%s\n' "$S5" | grep -n '^2\. \*\*Install bendit' | cut -d: -f1)"
l2b="$(printf '%s\n' "$S5" | grep -n '^2b\. ' | cut -d: -f1)"
l3="$(printf '%s\n' "$S5" | grep -n '^3\. ' | cut -d: -f1)"
chk "  ...between step 2 and step 3" "$([ -n "$l2" ] && [ -n "$l2b" ] && [ -n "$l3" ] && [ "$l2" -lt "$l2b" ] && [ "$l2b" -lt "$l3" ] && echo y || echo n)" y
has "  ...and its result is in the report's record" 'Versions:' \
    "$(printf '%s\n' "$REPORT" | sed -n '/What I did (for the record/,/^Two last steps:/p')"
has "the summary lists the update when this folder has an older bendit" 'Update bendit for this project to' \
    "$(block "$QUICK" '^## 2\. The one question' 1)"

echo
echo "QUICK: THE SUMMARY IS IN EVERYDAY WORDS"
SUMMARY="$(block "$QUICK" '^## 2\. The one question' 1)"
chk "the summary template was found" "$([ -n "$SUMMARY" ] && echo y || echo n)" y
hasnt "no .git/info/exclude in the summary" ".git/info/exclude" "$SUMMARY"
hasnt "no ~/.config/bendit in the summary" "~/.config/bendit" "$SUMMARY"
hasnt "no 'port' in the summary" "(port)" "$SUMMARY"
RECORD="$(printf '%s\n' "$REPORT" | sed -n '/What I did (for the record/,/^Two last steps:/p')"
has "  ...the private ignore list is still named in the record" ".git/info/exclude" "$RECORD"
has "  ...and where the port is noted" "ports.json" "$RECORD"

echo
echo "QUICK: THE INSTALL'S 'OPTIONS NOT YET SET' IS EXPLAINED IN ONE PLAIN LINE"
has "the line the person sees" "bendit uses its standard settings" "$Q_TXT"

echo
echo "QUICK: WHERE @AGENTS.md GOES IS PINNED, SO THE UNDO REVERSES IT EXACTLY"
PIN='`@AGENTS.md` as the first line, then one blank line'
has "quick.md says it" "$PIN" "$Q_TXT"
has "project-layer.md says it" "$PIN" "$(cat "$LAYER")"

echo
echo "QUICK: THE UNDO COMMAND WORKS, AS PRINTED"
# AS PRINTED: the template's two-space indent kept on every line, which is what
# a person copies; STRIPPED: the indent removed. Both must work.
PRINTED="$(printf '%s\n' "$REPORT" | sed -n "/^  python3 -I -c '/,/CLAUDE.md:@AGENTS.md/p")"
STRIPPED="$(printf '%s\n' "$PRINTED" | sed 's/^  //')"
chk "the undo template has the command" "$([ -n "$PRINTED" ] && echo y || echo n)" y
has "  ...as one python3 -I command" "python3 -I -c" "$PRINTED"
fixture() {  # fixture <dir> -- CLAUDE.md and .gitignore as quick adopt leaves them
  mkdir -p "$1"
  printf '%s\n' '@AGENTS.md' '' '# My notes' 'keep me' > "$1/CLAUDE.md"
  printf 'node_modules/\n.claude/.bendit-state/\ndist/\n' > "$1/.gitignore"
}
undo() {  # undo <dir> <text> [python] -- leaves U_RC, U_OUT
  local bin="$1.bin"
  mkdir -p "$bin"; ln -sf "$(command -v "${3:-python3}")" "$bin/python3"
  U_OUT="$(cd "$1" && PATH="$bin:$PATH" /bin/bash -c "$2" 2>&1)"; U_RC=$?
}
for form in PRINTED STRIPPED; do
  eval "text=\"\$$form\""
  for py in python3 /usr/bin/python3; do
    command -v "$py" >/dev/null || continue
    v="$("$py" -V 2>&1)"
    D="$T/undo-$form-$(basename "$py")"; fixture "$D"
    undo "$D" "$text" "$py"
    chk "$form, $v, /bin/bash: exit 0, silent" "$U_RC|$U_OUT" "0|"
    chk "  ...CLAUDE.md loses the @AGENTS.md line and the blank after it, nothing else" \
        "$(cat "$D/CLAUDE.md")" "# My notes
keep me"
    chk "  ...and keeps its last newline" "$(tail -c 1 "$D/CLAUDE.md" | od -An -c | tr -d ' ')" '\n'
    chk "  ....gitignore loses only bendit's line" "$(cat "$D/.gitignore")" "node_modules/
dist/"
  done
done
# The import as the LAST line, after the person's own text.
D="$T/undo-last"; mkdir -p "$D"; printf '%s\n' '# Mine' '' '@AGENTS.md' > "$D/CLAUDE.md"
printf '.claude/.bendit-state/\n' > "$D/.gitignore"
undo "$D" "$PRINTED"
chk "@AGENTS.md as the last line: exit 0" "$U_RC|$U_OUT" "0|"
chk "  ...the person's text and blank line kept" "$(cat "$D/CLAUDE.md"; echo '|')" "# Mine

|"
# Run twice: the second run finds nothing to remove and says nothing.
undo "$D" "$PRINTED"
chk "a second run (already undone): exit 0, silent, nothing changed" "$U_RC|$U_OUT|$(cat "$D/CLAUDE.md"; echo '|')" "0||# Mine

|"
# A file that is gone is skipped, said plainly, and the rest still runs.
D="$T/undo-missing"; fixture "$D"; rm "$D/.gitignore"
undo "$D" "$PRINTED"
chk "a missing .gitignore: exit 0" "$U_RC" 0
has "  ...says it skipped it" ".gitignore: not found, skipped" "$U_OUT"
hasnt "  ...no traceback" "Traceback" "$U_OUT"
chk "  ...and CLAUDE.md is still undone" "$(cat "$D/CLAUDE.md")" "# My notes
keep me"
# Windows line endings stay Windows line endings.
D="$T/undo-crlf"; mkdir -p "$D"
printf '@AGENTS.md\r\n\r\n# Notes\r\n' > "$D/CLAUDE.md"
printf 'dist/\r\n.claude/.bendit-state/\r\nout/\r\n' > "$D/.gitignore"
undo "$D" "$PRINTED"
chk "CRLF files: exit 0, silent" "$U_RC|$U_OUT" "0|"
chk "  ...CLAUDE.md: the line and the blank after it gone, CRLF kept" "$(od -An -c "$D/CLAUDE.md" | tr -s ' ' | tr -d '\n')" \
    "$(printf '# Notes\r\n' | od -An -c | tr -s ' ' | tr -d '\n')"
chk "  ....gitignore: only bendit's line gone, CRLF kept" "$(od -An -c "$D/.gitignore" | tr -s ' ' | tr -d '\n')" \
    "$(printf 'dist/\r\nout/\r\n' | od -An -c | tr -s ' ' | tr -d '\n')"

echo
echo "DOCTOR: THE ENDING IS PLAIN, AND LAST"
D_TXT="$(cat "$DOCTOR")"
has "it asks which window this is" 'selfcheck.py" --session' "$D_TXT"
has "it may run the live test without a permission prompt" "Bash(git push --force bendit-probe HEAD)" "$(sed -n '1,/^---$/{/^allowed-tools/p;}' "$DOCTOR")"
has "it ALWAYS runs the live test (a missing marker must not loop 'restart' forever)" "Always run the live test" "$D_TXT"
hasnt "  ...never skips it because the window looks not live" "do not run it" "$D_TXT"
has "  ...except when --session says the name reaches something" "live test: skip" "$D_TXT"
has "not live: says why, plainly" "> This window was opened before bendit was set up, so its protection isn't running here yet." "$D_TXT"
has "  ...and says to reopen Claude, then /bendit:doctor" "> $STEP2" "$D_TXT"
hasnt "the person is never asked to type a force push" "run: git push" "$D_TXT"
has "the approval step, when prove.sh says it is not approved" "> Open a new Terminal window (not this chat), paste this, and type y:" "$D_TXT"
has "live: says so, plainly" "> bendit is active in this window: it just stopped a test force-push, as it should." "$D_TXT"
has "never 'active' without the refusal" "Never say bendit is active in this window without that refusal." "$D_TXT"
has "never 'active' while a guard is OFF" "Never say bendit is active while a guard is OFF." "$D_TXT"
last="$(grep -n '^\*\*The ending\.\*\*' "$DOCTOR" | cut -d: -f1)"
after="$(sed -n "$((${last:-1}+1)),\$p" "$DOCTOR" | grep -c '^#\|^\*\*' | tr -d ' ')"
chk "  ...the ending is the last section of doctor.md" "${last:+found}|$after" "found|0"
hasnt "the old ending is gone" "None of the scripts proves Claude Code actually runs the hooks" "$D_TXT"

echo
echo "QUICK: THE TEST CHECK IS WRITTEN ONCE (step 6)"
# 2026-11-22: step 6 ran the scaffold, which wrote a harness (lint + type-check
# + test + the app's verify call), and the agent then rewrote it to the decided
# check: two writes, a confusing diff. Step 6 now writes the decided check
# FIRST and runs the scaffold with --keep-harness, which leaves it as it is.
S6="$(sed -n '/^6\. \*\*The test check/,/^7\. \*\*Project files/p' "$QUICK")"
chk "step 6 was found" "$([ -n "$S6" ] && echo y || echo n)" y
has "step 6 says written once" 'The test check, written once.' "$S6"
w="$(printf '%s' "$S6" | awk 'BEGIN{RS="\001"} {print index($0,"first write")}')"
sc="$(printf '%s' "$S6" | awk 'BEGIN{RS="\001"} {print index($0,"Then run `bash")}')"
chk "  ...the harness is written BEFORE the scaffold runs" "$([ "$w" -gt 0 ] && [ "$sc" -gt "$w" ] && echo y || echo n)" y
has "  ...the scaffold is told to keep it" '"$ROOT" --keep-harness' "$S6"
hasnt "  ...no rewrite after the scaffold" 'rewrite `.claude/verify-harness`' "$S6"

# Run it as step 6 reads: --harness-owner, write the decided check, scaffold
# with --keep-harness. A wrapper on `cat`-style writes is not possible in sh, so
# the file's identity (inode, mtime to the second via stat, bytes) is compared
# before and after the scaffold: any rewrite changes the bytes or the inode.
SCAF="$KIT/scripts/scaffold-verification-skill.sh"
P="$T/once"; mkdir -p "$P"
printf '%s\n' '{"name":"demo","scripts":{"dev":"next dev","lint":"next lint","type-check":"tsc --noEmit","test":"vitest run"},"dependencies":{"next":"14.0.0"}}' > "$P/package.json"
: > "$P/pnpm-lock.yaml"
git -C "$P" init -q . 2>/dev/null
chk "owner before step 6: absent" "$(bash "$SCAF" "$P" --harness-owner --pm pnpm 2>&1)" absent
DECIDED='# What verifies demo: type-check and tests.
set -e
pnpm run type-check && pnpm run test'
mkdir -p "$P/.claude"; printf '%s\n' "$DECIDED" > "$P/.claude/verify-harness"
ino1="$(stat -f %i "$P/.claude/verify-harness" 2>/dev/null || stat -c %i "$P/.claude/verify-harness")"
sum1="$(cksum < "$P/.claude/verify-harness")"
bash "$SCAF" "$P" --keep-harness --pm pnpm >"$T/once.out" 2>&1; rc=$?
ino2="$(stat -f %i "$P/.claude/verify-harness" 2>/dev/null || stat -c %i "$P/.claude/verify-harness")"
chk "the scaffold ran (0 or 3: TODOs are fine)" "$([ "$rc" = 0 ] || [ "$rc" = 3 ] && echo y || echo n)" y
chk "the harness is byte-for-byte what step 6 wrote" "$(cksum < "$P/.claude/verify-harness")" "$sum1"
chk "  ...and the same file (never replaced)" "$ino2" "$ino1"
chk "  ...it has no lint and no app line" "$(grep -c 'lint\|verify-demo' "$P/.claude/verify-harness")" 0
chk "  ...the scaffold said it kept it" "$(grep -c 'kept as it was: --keep-harness' "$T/once.out" | tr -d ' ')" 1
chk "  ...and the app skill was still generated" "$([ -d "$P/.claude/skills/verify-demo" ] && echo y || echo n)" y
chk "owner after: kept (a retry keeps it)" "$(bash "$SCAF" "$P" --harness-owner --pm pnpm 2>&1)" kept

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
