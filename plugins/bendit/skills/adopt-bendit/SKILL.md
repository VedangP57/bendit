---
name: adopt-bendit
description: Use when setting up bendit in a project, or asked to make a project's agent rules enforced and verifiable.
---

# Adopt bendit

The project ends with rules that are **enforced** rather than written down, a
harness that proves a change works, and a report that says which is which, with
evidence. `KIT` below is the plugin root: two directories above this skill's
base directory (it contains `hooks/`, `scripts/`, `templates/`).

## Which flow

- **`/bendit:adopt`** (the default): follow `references/quick.md` and nothing
  below. One plain question, safe defaults for everything else, a plain report.
- **`/bendit:adopt --detailed`** (the arguments contain `--detailed`): the
  step-by-step flow below, for engineers who want to choose each answer.

# The --detailed flow

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
  verification scaffold (`scaffold-verification-skill.sh`) does those writes
  itself, in one command, so you rarely write there by hand; `prove.sh` writes
  nothing in the project. If a
  prompt is refused, report the file as not written; never route around it.
- Every claim you report cites a `file:line` or names its evidence rung
  (1 said · 2 pointed at the line · 3 showed it can't happen · 4 ran it · 5 saw
  it in the running session).

## Steps, in order

1. **Detect** (read-only). Follow `references/detect.md`. Print the findings
   table with sources.
   *Stop* if the directory is your home directory or `/`, or the user does not
   confirm this is the project root. If it is not a git repository, ask whether
   to run `git init`; `/bendit:ship`, `/bendit:review-diff` and the Stop gate need git.
2. **Interview.** Follow `references/interview.md`. Print the answers table and
   get one "yes, go" before anything is written.
3. **Install.** Follow `references/install.md` (marketplace, else vendor).
   *Stop* if neither route works; report what failed with its output.
3b. **Features.** Print the table from `references/detect.md` §8:
   `feature | on/off | why`. For each **on** feature with a missing dependency,
   ask, one at a time, whether to install it, showing the exact command
   (macOS with Homebrew: `brew install node`, `brew install --cask
   google-chrome`; otherwise the download page, https://nodejs.org/ or
   https://www.google.com/chrome/) *[no]*. A "no" turns that feature off with why
   `you declined <dep>` (e.g. `you declined Chrome`); it never stops adoption.
   Chromium is not Chrome (detect.md §8): on a machine that has only Chromium,
   offer Chrome the same way, and if it is still not installed record
   `browser-driver` off with why `Chrome not found (Chromium cannot be driven)`.
   For `browser-driver` that includes Playwright: when
   `bash "$KIT/scripts/drive-setup.sh" --check` exits 1, ask *"Install
   Playwright for the browser driver: `bash "$KIT/scripts/drive-setup.sh"`
   (downloads the pinned version from npm into
   `${BENDIT_CACHE:-${XDG_CACHE_HOME:-~/.cache}/bendit}/drive/`; no browser is
   downloaded and nothing is written in this project)? [no]"*. Run it only
   after a yes, and read its output; a "no" is why `you declined Playwright`.
   The script itself never asks, so this question is the only consent.
   If `ux-design-laws` is on, it needs the `bendit-web` add-on. Run
   `claude plugin list --json` **from the project root** (read-only; the human
   `claude plugin list` shows the project-scope installs of every project
   without saying which, and the JSON's per-project fields depend on the
   directory it runs in). It is a list of objects with `id`, `scope`, `enabled`
   (installed, whatever the project), `projectEnabled` (on for the current
   project) and, for project scope, `projectPath`. `ROOT` is
   `git rev-parse --show-toplevel`; resolve it and each `projectPath` the same
   way (`cd "$p" && pwd -P`), no trailing slash. A `projectPath` that is
   missing or does not resolve is not a match. Skip the question and the
   install only if one entry has `id == "bendit-web@bendit"`,
   `scope == "project"`, resolved `projectPath == ROOT` and
   `projectEnabled == true`. An entry for another project's
   `projectPath`, or at `user` scope, does not count. If `--json` fails or
   prints something that is not that list, treat the add-on as not installed
   and ask. Otherwise ask
   *"Run `claude plugin install bendit-web@bendit --scope project` (changes
   this project's `.claude/settings.json`; Claude Code also records the
   install in its own plugin registry)? [no]"*. On a yes, run it now,
   read its output, and show the `.claude/settings.json` diff. If it is declined,
   `ux-design-laws` is off with why `you declined bendit-web`. If it fails, show
   its output and record off with why `bendit-web install failed`.
   Then show, get a yes, and run **one** Bash call that writes every feature to
   `.claude/bendit.json` (one permission prompt; `ROOT` is the project root):
   ```bash
   python3 "$KIT/scripts/features.py" set "$ROOT" browser-driver on "package.json:5 next" &&
   python3 "$KIT/scripts/features.py" set "$ROOT" ux-design-laws on "package.json:5 next" &&
   python3 "$KIT/scripts/features.py" set "$ROOT" session-brief on "git project (git rev-parse --show-toplevel)" &&
   python3 "$KIT/scripts/features.py" set "$ROOT" ls-guard off "type ls in zsh: ls is the real ls" &&
   python3 "$KIT/scripts/features.py" set "$ROOT" primary-checkout-guard off "off unless chosen in /bendit:adopt --detailed" &&
   python3 "$KIT/scripts/features.py" show "$ROOT"
   ```
   The lines above are an example: substitute the state you detected and the
   real why for each feature. Copied as-is they write false evidence into a
   committed file.
   Re-running it on an unchanged project rewrites the same bytes.
4. **Build the project layer.** Follow `references/project-layer.md`:
   `AGENTS.md` (which records the integration and production branches),
   `.claude/verify-harness`, a verification skill if there is an app, CI if
   absent. Facts are written only where something reads them. Then ask the
   person to approve the harness in their own terminal with the command the
   scaffold printed; you cannot, and must not try.
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
   for turning the next repeated mistake into a guard (`/bendit:new-guard`).

## The report

```
bendit adoption: <project>  — COMPLETE | NOT COMPLETE (<what failed>)

PROVE.SH (as printed)
<check>                           | PASS/FAIL/UNUSED             | 4
LIVE WIRING                       | PASS / FAIL / inconclusive / pending | 5

FEATURES (.claude/bendit.json)    | on/off | why             | measured?
<every feature>                   | on/off | <its source>    | not yet measured
(an off feature: install its missing dependency or add-on, then re-run /bendit:adopt --detailed)

ENFORCED (refuses, exit 2)        | proved by
<guard>                           | prove.sh rows + live check
ls guard (if ls-guard is on)      | prove.sh feature: ls-guard row; not yet measured
primary-checkout guard (if on)    | prove.sh feature: primary-checkout-guard row; not yet measured
Stop gate + .claude/verify-harness| prove.sh Stop gate + harness rows
browser scenarios (if the harness runs verify and browser-driver is on) | prove.sh feature: browser-driver row; not yet measured

ADVICE (skills/commands/notes; the agent may ignore them)
<skill or command>                | when it applies
session brief (if on)             | session start; never blocks; not yet measured
plan and import notes             | after an edit to a plan or a mod's .ts; not yet measured
blast-radius                      | auth, payments, policies, migrations, secrets, webhooks; not yet measured
ux-design-laws (bendit-web)       | UI work, only where the add-on is installed; not yet measured
/bendit:vocabulary                       | on request; no hook runs it; not yet measured

NOT POSSIBLE HERE, AND WHY
<item>                            | <reason, with source>

NEXT: the next time you correct the same mistake twice, run /bendit:new-guard.
```

Keep "enforced" and "advice" strictly apart. A PostToolUse hook cannot block
(the tool already ran), so it is advice, however it is wired.
