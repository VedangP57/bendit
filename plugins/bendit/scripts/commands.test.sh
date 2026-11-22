#!/usr/bin/env bash
# Grep pins for command prose, and for the docs that point at the commands
# (README, INSTALL.md, docs/reference.md). A command is a prompt, so its text IS
# its behaviour: this pins the sentences that carry a rule, so an edit that drops
# one fails here. A pin proves the words are present, not that a model obeys them.
#
#   bash commands.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SD/.." && pwd)"
CMD="$KIT/commands"
pass=0; fail=0
# pin <file> <fixed string>: the file contains the string. hasnt: it does not.
pin() {
  if [ ! -f "$1" ]; then printf '  FAIL  %s: no such file (wanted "%s")\n' "$1" "$2"; fail=$((fail+1))
  elif grep -qF -- "$2" "$1"; then printf '  ok    %s has "%s"\n' "$(basename "$1")" "$2"; pass=$((pass+1))
  else printf '  FAIL  %s is missing "%s"\n' "$1" "$2"; fail=$((fail+1)); fi
}
hasnt() {
  if [ ! -f "$1" ]; then printf '  FAIL  %s: no such file (must not have "%s")\n' "$1" "$2"; fail=$((fail+1))
  elif grep -qF -- "$2" "$1"; then printf '  FAIL  %s has "%s" and must not\n' "$1" "$2"; fail=$((fail+1))
  else printf '  ok    %s lacks "%s"\n' "$(basename "$1")" "$2"; pass=$((pass+1)); fi
}

echo "REVIEW-DIFF: VERDICT BUCKETS AND LEAD JUDGMENT"
RD="$CMD/review-diff.md"
pin "$RD" '### Act on'
pin "$RD" '### Consider'
pin "$RD" '### Noted'
pin "$RD" '### Dismissed'
pin "$RD" 'Each finding states its evidence (file:line) and its impact'
pin "$RD" 'No findings is a valid result'
pin "$RD" '## Lead judgment'
pin "$RD" 'accept or reject each finding, with one reason'
pin "$RD" 'Name every reviewer or check that ran; never skip one silently'

echo; echo "VOCABULARY: SLOP RULE AND JUDGMENT LIST"
VC="$CMD/vocabulary.md"
pin "$VC" '**slop**'
pin "$VC" '`--check` and the'
pin "$VC" 'Rule of three'
pin "$VC" 'Synonym cycling'

echo; echo "GUARD-REPORT: RUN IT, EXPLAIN, NEVER REMOVE"
GR="$CMD/guard-report.md"
pin "$GR" 'scripts/guard-report.py" --days 30'
pin "$GR" 'Explain the result in plain words'
pin "$GR" 'Fires are unknown, not'
pin "$GR" 'never report it as "nothing fired"'
pin "$GR" 'rules that never fire in a long window'
pin "$GR" 'rules the person often overrides'
pin "$GR" 'Never remove, turn off or edit a guard or a rule here'
pin "$GR" "Removing a rule is the person's call"
pin "$GR" '/bendit:adopt --detailed'
hasnt "$GR" 'rm .claude'
hasnt "$GR" 'Bash(rm'

echo; echo "SUGGEST-GUARDS: READ-ONLY, CHEAPEST LAYER, ASK ONCE"
SG="$CMD/suggest-guards.md"
pin "$SG" 'scripts/suggest-guards.py" --min 2'
pin "$SG" 'No past sessions found for this project'
pin "$SG" 'Arguments: `$ARGUMENTS`'
pin "$SG" '**delete** (L0)'
pin "$SG" '**structure** (L1)'
pin "$SG" '**guard** (L2)'
pin "$SG" '**prose** (L3)'
pin "$SG" 'Then ask once which rows to build'
pin "$SG" 'Only on a yes, run `/bendit:new-guard <name>`'
pin "$SG" 'Write nothing otherwise'
pin "$SG" 'never open the transcripts to read more'
pin "$SG" "Adapted from the \`ruminate\` idea in poteto's brainmaxxing"
pin "$SG" 'one PR per row'
pin "$SG" '| # | source | pattern | count | layer | proposal |'
pin "$SG" '`No pattern repeats`'
pin "$SG" "read every candidate's quoted example and drop the ones that are not corrections of the agent"
pin "$SG" 'Then say in one line how many you dropped and why.'
pin "$SG" 'A cluster made only of `maybe` candidates is never shown without your confirmation'
hasnt "$SG" 'Bash(rm'
hasnt "$SG" '.claude/settings.json'
pin "$KIT/skills/adopt-bendit/references/grow.md" '/bendit:suggest-guards'

echo; echo "PRIMARY-CHECKOUT-GUARD: --detailed ASKS (DEFAULT NO), QUICK NEVER TURNS IT ON"
REF="$KIT/skills/adopt-bendit/references"
pin "$REF/interview.md" '7. **Edit only in a separate copy?**'
pin "$REF/interview.md" '`git worktree add` instead? [no]"*'
pin "$REF/interview.md" 'Yes: `primary-checkout-guard` on'
pin "$REF/interview.md" 'No, or an empty reply: off'
pin "$REF/interview.md" 'features.py" integration-branch "$ROOT" <name>'
pin "$REF/interview.md" 'the plugin option `integrationBranch` is set (read it'
pin "$REF/interview.md" 'never the plugin option or `AGENTS.md`'
pin "$REF/quick.md" '`primary-checkout-guard` is always off here (only `--detailed` asks), and the summary never mentions it.'
pin "$REF/detect.md" '| `primary-checkout-guard` | never from detection'
pin "$KIT/skills/adopt-bendit/SKILL.md" 'set "$ROOT" primary-checkout-guard off "off unless chosen in /bendit:adopt --detailed"'
# The quick summary (§2's template, up to §3) must not offer it.
QS="$(mktemp)"; sed -n '/^## 2\. The one question/,/^## 3\./p' "$REF/quick.md" > "$QS"
pin "$QS" 'Here is what I'"'"'ll set up'
hasnt "$QS" 'primary-checkout'
hasnt "$QS" 'worktree'
rm -f "$QS"
pin "$KIT/../../README.md" '`primary-checkout-guard`'
pin "$KIT/../../docs/reference.md" '| `primary-checkout-guard` |'

echo; echo "DOCTOR: WHICH BENDIT IS RUNNING, AND WHICH EACH CHECKOUT WILL LOAD"
DR="$CMD/doctor.md"
pin "$DR" 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/installed-versions.py" --root .'
pin "$DR" 'Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/installed-versions.py *)'
pin "$DR" 'one `version` row: the `running: bendit <version>` line'
pin "$DR" 'another checkout of this repo will load a different bendit'
pin "$DR" 'give each update command exactly as printed'
pin "$DR" 'Exit 2 means the versions could not be read'
pin "$DR" '> bendit is running in this window, but not the copy installed for this project.'
pin "$DR" 'anything other than `installed`'
pin "$DR" 'Only project-scope installs are checked'
hasnt "$DR" 'claude plugin list'

echo; echo "DOCS: AN INSTALL RUNBOOK AN AGENT CAN RESUME, CREDITS, NEW COMMANDS"
ROOT="$(cd "$KIT/../.." && pwd)"
IN="$ROOT/INSTALL.md"; RM="$ROOT/README.md"; RF="$ROOT/docs/reference.md"
# Every numbered step (a "## <n>." heading) has its own "Skip if:" line, so an
# agent that stopped half way can rerun the runbook and resume. Counted per
# section, never in total: one step with two lines must not cover one with none.
if [ -f "$IN" ]; then
  steps="$(grep -cE '^## [0-9]+\. ' "$IN")"
  bare="$(awk '/^## [0-9]+\. /{ if (s && !k) print s; s=$0; k=0; next }
               /^## /{ if (s && !k) print s; s=""; next }
               s && /^\*\*Skip if:\*\*/{ k=1 }
               END{ if (s && !k) print s }' "$IN")"
  if [ "$steps" -ge 6 ]; then printf '  ok    INSTALL.md has %s numbered steps\n' "$steps"; pass=$((pass+1))
  else printf '  FAIL  INSTALL.md has %s numbered steps, wanted at least 6\n' "$steps"; fail=$((fail+1)); fi
  if [ -z "$bare" ]; then printf '  ok    every INSTALL.md step has its own **Skip if:**\n'; pass=$((pass+1))
  else printf '  FAIL  INSTALL.md steps with no **Skip if:**: %s\n' "$bare"; fail=$((fail+1)); fi
else
  printf '  FAIL  %s: no such file\n' "$IN"; fail=$((fail+1))
fi
pin "$IN" '/bendit:adopt'
pin "$IN" '/bendit:doctor'
pin "$IN" 'require-verification.py --trust'
pin "$IN" 'Never run it yourself'
pin "$IN" 'claude plugin install bendit@bendit --scope project'
# Nothing is installed before the person has seen one summary and said yes, and
# before install-route.sh has checked that the global name `bendit` is not
# someone else's (marketplace names are per computer, not per project).
pin "$IN" 'Go ahead? (yes or no)'
pin "$IN" 'install-route.sh" route https://github.com/VedangP57/bendit'
pin "$IN" 'install-route.sh" conflict'
pin "$IN" 'Any other exit: show the person its message exactly as printed, and stop'
# The skip check proves the right source and an install that is on for THIS project.
pin "$IN" 'known_marketplaces.json'
pin "$IN" 'p.get("projectEnabled") is True'
# Step 5 is done when there is nothing to approve.
pin "$IN" 'if not os.path.isfile(harness):'
first_line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
l_yes="$(first_line "$IN" 'Go ahead? (yes or no)')"
l_conf="$(first_line "$IN" 'install-route.sh" conflict')"
l_add="$(first_line "$IN" 'claude plugin marketplace add')"
if [ -n "$l_yes" ] && [ -n "$l_conf" ] && [ -n "$l_add" ] && [ "$l_yes" -lt "$l_conf" ] && [ "$l_conf" -lt "$l_add" ]; then
  printf '  ok    INSTALL.md: summary (line %s), then conflict check (%s), then marketplace add (%s)\n' "$l_yes" "$l_conf" "$l_add"; pass=$((pass+1))
else
  printf '  FAIL  INSTALL.md order must be summary < conflict check < marketplace add (got %s, %s, %s)\n' "${l_yes:-none}" "${l_conf:-none}" "${l_add:-none}"; fail=$((fail+1))
fi
hasnt "$IN" '`/bendit:adopt --detailed` explains the'
hasnt "$RM" 'The approval in step 2 below'
hasnt "$RF" '(`integrationBranch` in `.claude/bendit.json`'
# NOTICE: noodle's MIT notice, for the unslop phrases in vocabulary.json.
NT="$ROOT/NOTICE"
pin "$NT" 'Copyright (c) 2026 Lauren Tan'
pin "$NT" 'Permission is hereby granted, free of charge, to any person obtaining a copy'
pin "$NT" 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND'
pin "$NT" 'plugins/bendit/scripts/vocabulary.json'
pin "$NT" 'https://github.com/poteto/noodle'
pin "$KIT/scripts/vocabulary.json" '"notice": "NOTICE'
pin "$RM" 'Paste into Claude Code: Install bendit in this project by following https://raw.githubusercontent.com/VedangP57/bendit/main/INSTALL.md'
pin "$RM" '**Start here:**'
# INSTALL step 2's "Skip if" accepts every URL form install-route accepts
# for this repo (else a false "not installed", a needless re-run), and no other repo.
skip_re="$(python3 - "$IN" <<'PY'
import re, sys
line = next(l for l in open(sys.argv[1]) if 'm = re.match(r"' in l)
rx = re.compile(re.search(r'm = re\.match\(r"(.*?)", src', line).group(1))
yes = ["VedangP57/bendit", "https://github.com/VedangP57/bendit.git", "https://github.com/vedangp57/bendit/",
       "http://github.com/VedangP57/bendit", "https://tok" + chr(64) + "github.com/VedangP57/bendit",
       "git@github.com:VedangP57/bendit.git", "ssh://git@github.com/VedangP57/bendit.git",
       "git@github.com/VedangP57/bendit"]
no = ["https://github.com/other/bendit", "https://evil.test/VedangP57/bendit", "VedangP57/bendit-fork"]
ok = lambda u: bool(rx.match(u)) and rx.match(u).group(1).lower() == "vedangp57/bendit"
print(" ".join([u for u in yes if not ok(u)] + ["FALSE-SKIP:" + u for u in no if ok(u)]) or "ok")
PY
)"
if [ "$skip_re" = ok ]; then printf '  ok    INSTALL.md step 2 Skip-if: every URL form of this repo, no other repo\n'; pass=$((pass+1))
else printf '  FAIL  INSTALL.md step 2 Skip-if regex: %s\n' "$skip_re"; fail=$((fail+1)); fi
pin "$RM" '## Credits'
pin "$RM" '(https://github.com/poteto/brainmaxxing)'
pin "$RM" '(https://github.com/poteto/verification-skill-example)'
pin "$RM" '(https://github.com/poteto/noodle)'
pin "$RM" '(https://github.com/poteto/how)'
pin "$RM" '| `/bendit:guard-report` |'
pin "$RM" '| `/bendit:suggest-guards` |'
pin "$RF" '`/bendit:guard-report`'
pin "$RF" '`/bendit:suggest-guards`'
pin "$RF" 'fires.jsonl'
pin "$RF" 'plugin-lint.py'
# Credit, never overclaim: poteto inspired parts of bendit; she did not write
# or endorse it, and no doc may read as if she did. Checked on the README's
# Credits section as a whole, and on every line anywhere that names poteto
# ("written by" elsewhere, about a stamp file, is fine).
OVER='written by|wrote|authored|co-author|endorse|built by|made by|maintained by|official'
CR="$(mktemp)"; sed -n '/^## Credits/,/^## [^C]/p' "$RM" > "$CR"
for f in "$CR" "$RM" "$IN" "$RF"; do
  if [ ! -s "$f" ]; then printf '  FAIL  %s is missing or empty, so nothing was checked\n' "$f"; fail=$((fail+1)); continue; fi
  if [ "$f" = "$CR" ]; then hits="$(grep -inE "$OVER" "$f")"; what="the Credits section"
  else hits="$(grep -i 'poteto' "$f" | grep -iE "$OVER")"; what="$(basename "$f")'s lines naming poteto"; fi
  if [ -z "$hits" ]; then printf '  ok    %s: no authorship or endorsement claimed\n' "$what"; pass=$((pass+1))
  else printf '  FAIL  %s overclaim: %s\n' "$what" "$hits"; fail=$((fail+1)); fi
done
# The person, linked, not only her repositories' URLs (which also hold "poteto").
if grep -qF '[poteto](https://github.com/poteto)' "$CR"; then printf '  ok    the Credits section names and links poteto\n'; pass=$((pass+1))
else printf '  FAIL  the Credits section does not name and link poteto\n'; fail=$((fail+1)); fi
rm -f "$CR"

echo; echo "commands.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
