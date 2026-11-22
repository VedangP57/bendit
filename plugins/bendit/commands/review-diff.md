---
description: Review everything this branch changes against common agent failure modes, then the project's AGENTS.md
---

Review **everything this branch changes**: every commit since it left the integration branch, plus uncommitted edits, plus untracked files. A bare `git diff` sees only uncommitted edits, so on a clean tree it reviews nothing and the review reads as "clean".

Resolve the integration branch in this order, and say which source it came from: the plugin option `integrationBranch`; else `git symbolic-ref refs/remotes/origin/HEAD`; else an `Integration branch:` line in `AGENTS.md`; else **ask the human**. Never assume `main`.

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
BASE=$(python3 - "$CFG" <<'PY'
import json, sys
try:
    cfgs = json.load(open(sys.argv[1])).get('pluginConfigs', {})
    print(next((v.get('options', {}).get('integrationBranch', '') for k, v in cfgs.items()
                if k.split('@')[0] == 'bendit'), '') or '')
except Exception:
    print('')
PY
); SRC="plugin option integrationBranch"
if [ -z "$BASE" ]; then BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's#^origin/##'); SRC="origin/HEAD"; fi
if [ -z "$BASE" ] && [ -f AGENTS.md ]; then BASE=$(sed -n 's/^[-* ]*Integration branch:[ `]*\([^ `]*\).*/\1/p' AGENTS.md | head -1); SRC="AGENTS.md"; fi
if [ -n "$BASE" ]; then echo "BASE=$BASE (from $SRC)"; else echo "BASE UNKNOWN: ask the human"; fi
```

Then, with `BASE` set:

```bash
git fetch --quiet origin "$BASE" || echo "FETCH FAILED: origin/$BASE (using the last-fetched origin/$BASE, which may be stale)"
MB=$(git merge-base HEAD "origin/$BASE") || { echo "NO MERGE-BASE with origin/$BASE: nothing reviewed"; exit 1; }
CHANGED=$(git diff --name-only "$MB" | wc -l | tr -d ' ')
UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
echo "reviewing: $CHANGED changed file(s) since ${MB:0:9} (commits + uncommitted), $UNTRACKED untracked"
if [ "$CHANGED" -eq 0 ] && [ "$UNTRACKED" -eq 0 ]; then
  echo "EMPTY DIFF: nothing to review against origin/$BASE. This is NOT a clean review."; exit 1
fi
git diff --stat "$MB" && git diff "$MB"
git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do echo "=== untracked: $f"; cat -- "$f"; done
```

**If it prints `EMPTY DIFF`, `NO MERGE-BASE` or `BASE UNKNOWN`, stop and say so.** Do not report a review: no sections, no "clean". Check that the base branch is right and that the work is actually on this branch.

Open the review by stating the base, where it came from, the merge-base and the file counts from the `reviewing:` line.

Each finding states its evidence (file:line) and its impact: what is wrong, and the concrete consequence. Say "clean" per section when it is. State the evidence rung for anything you assert (see `engineering-habits`): a review that sounds right is worthless if it was not checked.

Sort every finding into one bucket, under these headings, and leave an empty bucket out:

### Act on
Wrong now, and fixing it is in scope for this branch: a defect, a broken invariant, a claim the code contradicts.

### Consider
Plausibly worth changing, but a judgment call or beyond this branch's purpose. Say what it costs to ignore.

### Noted
True and worth knowing, with no action needed now.

### Dismissed
Looked at and rejected, with the reason, so the same worry is not raised again.

No findings is a valid result. Say so plainly, name what was checked, and do not pad the review to look thorough.

---

## Part A: common agent failure modes

### A1. Auth on entry points
Every new or modified request handler, RPC, job or CLI entry: does it check authorization before doing work? Name the mechanism. A handler that reads or writes through a privileged client (one that bypasses row-level or tenant checks) with no check is a finding however obscure the path looks.

### A2. Credentials crossing to the client
Any value compiled into a client bundle or shipped binary (public env-var prefixes, embedded config) that is used as a credential rather than as configuration. It is public in every build that shipped.

### A3. Errors reported as success
`catch` blocks that return a success shape, defaults (`?? []`, `|| ''`, `or {}`) covering a value that should not be missing, and success status codes on a failed operation. Each converts a loud failure into a quiet wrong answer (see `engineering-habits`).

### A4. New type escapes and suppressions
Every added `any`, cast-to-silence, `@ts-ignore`, `# type: ignore`, `# noqa`, `eslint-disable`, `#[allow(...)]`, `//nolint`. Ask what the underlying rule was protecting. A suppression added to pass a gate is a defect.

### A5. Comments that excuse rather than explain
Flag added comments that narrate a workaround, a fallback, a "for now" or a "safety net": the next agent reads them as precedent. A comment explaining a non-obvious *why* forced by an external constraint is fine.

### A6. Prose that claims what the code does not do
For each factual claim the diff adds (a comment, doc, PR text, commit message), open the code it describes and confirm it. A claim with no `file:line` behind it is a question, not a fact.

### A7. Second implementations
Does this add a second way to do something the project already does once: another formatter, date helper, logger, client, auth check? Name the existing one (see `engineering-habits`).

### A8. Dead or shadowed configuration
New or edited config: is the file actually read (a second config of the same tool that wins, a key the tool reads from somewhere else, a value in the wrong unit)? Did an exclude/ignore list grow, taking files out of a gate?

### A9. Scope
Changes unrelated to the stated purpose? Tidying folded into a dependency bump is invisible to review. Call it out and suggest splitting.

### A10. Tests that cannot fail
For every added test: would it still pass if the functions it calls returned `undefined`? Does any assertion pin behaviour that is itself wrong? (see `engineering-habits`)

---

## Part B: this project

Read `AGENTS.md` and check the diff against every invariant it lists. If it has no invariants section, report that as the finding.

---

## Lead judgment

You are the lead, not a relay. Before reporting, accept or reject each finding, with one reason: a finding from a reviewer or check is a claim, so open the code it cites and confirm it. A finding you cannot confirm goes to Dismissed, or to Noted if it stays plausible.

Name every reviewer or check that ran; never skip one silently. If one was skipped, failed or could not start, say which and why, so a missing check never reads as a clean one.
