---
name: adopt-bendit
description: Use when setting up bendit in a project, or asked to make a project's agent rules enforced and verifiable.
---

# Adopt bendit

The project ends with rules that are **enforced** rather than written down, a
harness that proves a change works, and a report that says which is which, with
evidence. `KIT` below is the plugin root: two directories above this skill's
base directory (it contains `hooks/`, `scripts/`, `templates/`).

## Ground rules for the whole flow

- **Detect before asking.** Ask only what files could not answer, **one question
  at a time, each with a default** the user can accept with "yes".
- **Show, then write.** Before each step that writes, list every file you will
  create or change, show the content or diff, and wait for a yes. Never edit
  user-level settings (`~/.claude/…`), never commit, never push.
- **Never overwrite** an existing `AGENTS.md`, `CLAUDE.md`, hook or workflow.
  Propose an addition and ask.
- **Expect permission prompts for `.claude/`.** Claude Code treats writes under
  a project's `.claude/` as sensitive and asks before each one. That is
  expected, not a failure: tell the user before the step that causes them. The
  kit's scripts (`scaffold-verification-skill.sh`, `prove.sh`) do those writes
  themselves, in one command each, so you rarely write there by hand. If a
  prompt is refused, report the file as not written; never route around it.
- Every claim you report cites a `file:line` or names its evidence rung
  (1 said · 2 pointed at the line · 3 showed it can't happen · 4 ran it · 5 saw
  it in the running session).

## Steps, in order

1. **Detect** (read-only). Follow `references/detect.md`. Print the findings
   table with sources.
   *Stop* if the directory is your home directory or `/`, or the user does not
   confirm this is the project root. If it is not a git repository, ask whether
   to run `git init`; `/ship`, `/review-diff` and the Stop gate need git.
2. **Interview.** Follow `references/interview.md`. Print the answers table and
   get one "yes, go" before anything is written.
3. **Install.** Follow `references/install.md` (marketplace, else vendor).
   *Stop* if neither route works; report what failed with its output.
4. **Build the project layer.** Follow `references/project-layer.md`:
   `AGENTS.md` (which records the integration and production branches),
   `.claude/verify-harness`, a verification skill if there is an app, CI if
   absent. Facts are written only where something reads them.
5. **Prove it.** Follow `references/prove.md`. Run
   `bash "$KIT/scripts/prove.sh" <project root>`: it feeds every guard a
   known-bad and a known-good payload, dry-runs the Stop gate in a throwaway
   repo, runs the harness, privacy-scans the written files, writes nothing in
   the project, and prints `check | result | evidence rung`. Then do the one
   live check by hand: a harmless force push this session must refuse with a
   message naming bendit (another kit refusing first is
   "inconclusive", not a pass).
   *Stop* on any FAIL: adoption is **not done**. Report what failed, its
   output, and the next step. Do not soften it into a pass.
6. **Hand over.** Print the report below, then point at `references/grow.md`
   for turning the next repeated mistake into a guard (`/new-guard`).

## The report

```
bendit adoption: <project>  — COMPLETE | NOT COMPLETE (<what failed>)

PROVE.SH (as printed)
<check>                           | PASS/FAIL                    | 4
LIVE WIRING                       | PASS / FAIL / inconclusive / pending | 5

ENFORCED (refuses, exit 2)        | proved by
<guard>                           | prove.sh rows + live check
Stop gate + .claude/verify-harness| prove.sh Stop gate + harness rows

ADVICE (skills/commands; the agent may ignore them)
<skill or command>                | when it applies

NOT POSSIBLE HERE, AND WHY
<item>                            | <reason, with source>

NEXT: the next time you correct the same mistake twice, run /new-guard.
```

Keep "enforced" and "advice" strictly apart. A PostToolUse hook cannot block
(the tool already ran), so it is advice, however it is wired.
