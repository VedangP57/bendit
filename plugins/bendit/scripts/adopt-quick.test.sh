#!/usr/bin/env bash
# The words a person reads at the END of /bendit:adopt (quick) and
# /bendit:doctor, and the one undo command quick.md hands them.
#
# Why it exists: v0.4.0 ran fine on a real project, but its two last steps
# (approve the check in a new Terminal; close and reopen Claude) scrolled away
# above a long report, and /bendit:doctor ended in engineer words without
# saying "reopen Claude" or giving the test to type. These are prompts, so the
# text IS the behaviour: this pins the endings, and RUNS the undo one-liner
# exactly as quick.md prints it, on bash and on every python3 here.
#
#   bash adopt-quick.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
QUICK="$KIT/skills/adopt-bendit/references/quick.md"
DOCTOR="$KIT/commands/doctor.md"
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

echo "QUICK: THE REPORT ENDS WITH WHAT TO DO NEXT"
REPORT="$(block "$QUICK" '^## 6\. The report' 1)"
chk "the report template was found" "$([ -n "$REPORT" ] && echo y || echo n)" y
# The last four non-empty lines of the template, exactly the owner's wording.
tail4="$(printf '%s\n' "$REPORT" | grep -v '^[[:space:]]*$' | tail -n 4)"
chk "its last lines are the two last steps, and nothing after them" "$tail4" \
'Two last steps:
  1. Open a new Terminal window (not this chat), paste this, and type y:
       <the exact --trust command prove.sh printed, e.g. python3 "<KIT>/scripts/require-verification.py" --trust "<ROOT>">
  2. Close Claude and open it again in this project. Then type /bendit:doctor.'
first="$(printf '%s\n' "$REPORT" | grep -v '^[[:space:]]*$' | head -n 1)"
chk "  ...and it still opens with the header" "$first" "<header>"
rec="$(printf '%s\n' "$REPORT" | grep -n 'What I did (for the record' | cut -d: -f1)"
steps="$(printf '%s\n' "$REPORT" | grep -n '^Two last steps:' | cut -d: -f1)"
chk "  ...the record comes BEFORE the steps" "$([ -n "$rec" ] && [ -n "$steps" ] && [ "$rec" -lt "$steps" ] && echo y || echo n)" y
RULES="$(sed -n '/^## 6\. The report/,$p' "$QUICK")"
has "only step 2 left (the check already approved): one last step" "One last step:" "$RULES"
has "step 9 asks whether this window is already live" 'scripts/selfcheck.py" --session' "$(cat "$QUICK")"
has "  ...and then leaves step 2 out" "then last step 2 is left out" "$(cat "$QUICK")"

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
has "the line the person sees" "bendit uses its standard settings" "$(cat "$QUICK")"

echo
echo "QUICK: THE UNDO ONE-LINER WORKS, AS PRINTED"
# Lifted from the template exactly as printed, its two-space indent removed.
UNDO="$(printf '%s\n' "$REPORT" | sed -n "/^  python3 -I -c 'import sys/,/CLAUDE.md:@AGENTS.md/p" | sed 's/^  //')"
chk "the undo template has the one-liner" "$([ -n "$UNDO" ] && echo y || echo n)" y
fixture() {  # fixture <dir> -- CLAUDE.md and .gitignore as quick adopt leaves them
  mkdir -p "$1"
  printf '%s\n' '@AGENTS.md' '' '# My notes' 'keep me' > "$1/CLAUDE.md"
  printf 'node_modules/\n.claude/.bendit-state/\ndist/\n' > "$1/.gitignore"
}
for py in python3 /usr/bin/python3; do
  command -v "$py" >/dev/null || continue
  D="$T/undo-$(basename "$py")"; fixture "$D"
  mkdir -p "$D.bin"; ln -sf "$(command -v "$py")" "$D.bin/python3"
  out="$(cd "$D" && PATH="$D.bin:$PATH" /bin/bash -c "$UNDO" 2>&1)"; rc=$?
  v="$("$py" -V 2>&1)"
  chk "$v, /bin/bash: exit 0, silent" "$rc|$out" "0|"
  chk "  ...CLAUDE.md loses the @AGENTS.md line and the blank after it, nothing else" \
      "$(cat "$D/CLAUDE.md")" "# My notes
keep me"
  chk "  ...and keeps its last newline" "$(tail -c 1 "$D/CLAUDE.md" | od -An -c | tr -d ' ')" '\n'
  chk "  ....gitignore loses only bendit's line" "$(cat "$D/.gitignore")" "node_modules/
dist/"
done
# The import as the LAST line, after the person's own text.
D="$T/undo-last"; mkdir -p "$D"; printf '%s\n' '# Mine' '' '@AGENTS.md' > "$D/CLAUDE.md"
printf '.claude/.bendit-state/\n' > "$D/.gitignore"
out="$(cd "$D" && /bin/bash -c "$UNDO" 2>&1)"; rc=$?
chk "@AGENTS.md as the last line: exit 0" "$rc|$out" "0|"
chk "  ...the person's text and blank line kept" "$(cat "$D/CLAUDE.md"; echo '|')" "# Mine

|"
# Run twice: the second run finds nothing to remove and says nothing.
out="$(cd "$D" && /bin/bash -c "$UNDO" 2>&1)"; rc=$?
chk "a second run (already undone): exit 0, silent, nothing changed" "$rc|$out|$(cat "$D/CLAUDE.md"; echo '|')" "0||# Mine

|"

echo
echo "DOCTOR: THE ENDING IS PLAIN, AND LAST"
D_TXT="$(cat "$DOCTOR")"
has "it asks which window this is" 'selfcheck.py" --session' "$D_TXT"
has "it may run the live test without a permission prompt" "Bash(git push --force bendit-probe HEAD)" "$(sed -n '1,/^---$/{/^allowed-tools/p;}' "$DOCTOR")"
has "not live: says why, plainly" "> This window was opened before bendit was set up, so its protection isn't running here yet." "$D_TXT"
has "  ...says to reopen Claude" "> Close Claude and open it again in this project, then type:" "$D_TXT"
has "  ...gives the exact test" ">     run: git push --force bendit-probe HEAD" "$D_TXT"
has "  ...and what it should say" "> It should say BLOCKED by bendit." "$D_TXT"
has "live: says so, plainly" "> bendit is active in this window: it just stopped a test force-push, as it should." "$D_TXT"
has "never 'active' without the refusal" "Never say bendit is active in this window without that refusal." "$D_TXT"
last="$(grep -n '^\*\*The ending\.\*\*' "$DOCTOR" | cut -d: -f1)"
after="$(sed -n "$((${last:-1}+1)),\$p" "$DOCTOR" | grep -c '^#\|^\*\*' | tr -d ' ')"
chk "  ...the ending is the last section of doctor.md" "${last:+found}|$after" "found|0"
hasnt "the old ending is gone" "None of the scripts proves Claude Code actually runs the hooks" "$D_TXT"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
