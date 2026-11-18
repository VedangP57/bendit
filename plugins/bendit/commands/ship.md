---
description: Pre-PR checklist (gates, suppressions, secrets, review), then open the PR after you confirm
---

Run the pre-PR checklist for this change.

**Do not skip a step, and do not report a step as passing unless you ran it and saw the output. Partial verification is reported as partial.**

The authority for project rules is the project's `AGENTS.md`. Read its invariants and definition-of-done before step 2.

## 0. Which branch, against which base

Resolve the integration branch in this order, and say which source it came from:

1. the plugin option `integrationBranch`, if set;
2. the remote's default branch, `git symbolic-ref refs/remotes/origin/HEAD`;
3. an `Integration branch:` line in `AGENTS.md`;
4. otherwise **ask the human**. Never assume `main`.

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
git fetch --quiet origin "$BASE" || echo "FETCH FAILED: origin/$BASE"
git rev-parse --abbrev-ref HEAD
git merge-base HEAD "origin/$BASE" || echo "NO MERGE-BASE with origin/$BASE"
```

**Stop** if the current branch is `HEAD` (detached), is `$BASE`, or is a production branch `AGENTS.md` names: a PR is opened from a feature branch, never from the branch it merges into. Stop too if the fetch or the merge-base failed: every later step diffs against that merge-base, and an empty diff from a failed command reads as "clean".

## 1. Gates: run every one this project has

Take the commands from `AGENTS.md` (written by `/adopt`), else from the project's own manifest (`package.json` scripts, `Makefile`, `pyproject.toml`, `Cargo.toml`, `go.mod`). Run in this order:

```
lint  →  typecheck  →  test  →  build
```

Use the project's own commands; never substitute a hardcoded one (a project's `typecheck` may wrap code generation a bare compiler call skips). If the project lacks one, say which, and do not treat it as passing.

If `.claude/verify-harness` exists, run `/bendit:verify` too: that is the project's definition of "it works".

Report each result with its exit code. If any fails, stop, fix it, and restart at step 1.

## 2. Project invariants

Check this change against every invariant `AGENTS.md` lists. Report each as pass, fail with `file:line`, or not-applicable-because. If `AGENTS.md` has none, say so: that is a gap, not a pass.

## 3. New suppressions

Scan the **whole branch**, not just uncommitted edits: `git diff <merge-base>` (no `..HEAD`) is every committed and uncommitted change since the branch left `$BASE`, and untracked files are grepped separately because no diff shows them. The first line prints what was scanned; "no output" over zero files is not "clean".

```bash
MB=$(git merge-base HEAD "origin/$BASE") || { echo "NO MERGE-BASE: nothing scanned"; exit 1; }
P='(eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error|# *type: *ignore|# *noqa|//nolint|#\[allow\(|@SuppressWarnings|# *pylint: *disable)'
echo "scanned: $(git diff --name-only "$MB" | wc -l | tr -d ' ') changed file(s) since ${MB:0:9}, $(git ls-files --others --exclude-standard | wc -l | tr -d ' ') untracked"
git diff -U0 "$MB" | grep -E "^\+.*$P"
git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do grep -nHIE "$P" -- "$f"; done
```

Each new suppression needs an inline reason explaining why *the rule is wrong here*, not why the code is inconvenient, plus a line in the PR body. A suppression added to make a gate pass is a failure, not a fix (see `fix-root-causes`). Never disable a rule project-wide to clear a local violation.

## 4. Secrets

Same scope as step 3. Add any project-specific secret prefixes `AGENTS.md` lists to `P`.

```bash
MB=$(git merge-base HEAD "origin/$BASE") || { echo "NO MERGE-BASE: nothing scanned"; exit 1; }
P='(-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|sk_live_|ghp_[A-Za-z0-9]{20,}|github_pat_|xox[baprs]-|AIza[0-9A-Za-z_-]{30,})'
echo "scanned: $(git diff --name-only "$MB" | wc -l | tr -d ' ') changed file(s) since ${MB:0:9}, $(git ls-files --others --exclude-standard | wc -l | tr -d ' ') untracked"
git diff -U0 "$MB" | grep -E "^\+.*$P"
git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do grep -nHIE "$P" -- "$f"; done
```

Any hit stops the checklist until a human has looked. An untracked hit is a file about to be committed or left out of the PR: say which. Also check that no server-only credential became reachable from client code (a public env-var prefix, a browser bundle).

## 5. Docs

Did this change touch routes, env vars, scripts, CI, or an integration? If yes, update the matching docs in the same change. If no, say "no docs impact" and put that line in the PR body.

## 6. Review

Run `/bendit:review-diff`. Required. Act on what it finds or state why a finding does not apply.

## 7. Open the PR

Only after 0–6 are green.

1. **Nothing left behind.** `git status --porcelain` must be empty. Uncommitted or untracked work is not in the PR; ask the human whether to commit it. Never commit on their behalf without asking.
2. **Show, then ask.** Print the base (`$BASE`), the head branch, `git log --oneline <merge-base>..HEAD`, and the exact title and body you will submit. Every checkbox in the body reflects something you actually verified. Then **ask the human to confirm** and wait. Do not push or create anything until they say yes.
3. **Push the branch** as its own step, so a failed push is seen rather than surfacing as a confusing PR error:

   ```bash
   git push -u origin HEAD
   ```

   Read the output. Rejected, or pushed somewhere other than the branch you showed: stop.
4. **Create the PR** with what was confirmed, unchanged (GitHub shown; use the project's forge CLI if different):

   ```bash
   gh pr create --base "$BASE" --head "$(git rev-parse --abbrev-ref HEAD)" --title "<type>: <what changed>" --body "<the confirmed body>"
   ```

Then **stop. Never merge.** That is the human's call.
