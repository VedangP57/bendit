# Changelog

All notable changes. Dates are UTC.

## [Unreleased]

Nothing below has an eval result yet: every new piece is *not yet measured*.

### Added
- **One-command installer** (`install.sh`; macOS and Linux). Checks the machine
  (`claude`, `git`, `python3` 3.9+; for a web app also Node 20+ and Google
  Chrome), asks before every install (default no, no `--yes`), fetches bendit at
  the matching release tag into the cache folder and starts Claude Code on
  `/adopt`; with no terminal it prints that command instead. Writes nothing in
  the project. Flags `--check`, `--version`, `--help`; settings
  `BENDIT_SOURCE`, `BENDIT_REF`, `BENDIT_CACHE`; exit codes 0, 1, 2.
- **Wrappers** for the same installer: `npx bendit` (`packages/npm`) and
  `pipx run bendit` / `uvx bendit` (`packages/pypi`), kept identical to
  `install.sh` by `packages/sync.sh`.
- **Per-project features** in `.claude/bendit.json`: `browser-driver`,
  `ux-design-laws`, `session-brief`, `ls-guard`, each on or off with why.
  `scripts/features.py` is the one reader and writer; a malformed file
  (unknown key, wrong type, duplicate key) is an error every reader refuses,
  never "all off".
- **ls guard** (`block-ls-parsing.py`, `PreToolUse`): refuses parsing `ls`
  output (a pipe into a text tool, `$(ls)`, backticks, `<( )`, a `for` list),
  only where `ls-guard` is on.
- **Session brief** (`session-brief.py`, `SessionStart` startup and clear):
  branch, push state, uncommitted files, other worktrees with unfinished work,
  and only the liveness probes the project's `brief` config lists; only where
  `session-brief` is on. It never prints URL credentials or a non-URL env
  value, and every timeout says "timed out".
- **Real-browser scenarios**: a `scenarios/<name>.json` in a generated verify
  skill runs in Google Chrome through `lib/drive/drive.mjs`;
  `scripts/drive-setup.sh` installs Playwright 1.65.1 into
  `<cache>/drive/<version>/` (never a project, never a browser download;
  `--check` exits 0 or 1).
- **`bendit-web` add-on** with the `ux-design-laws` skill, listed in the
  marketplace; `/adopt` installs it with `--scope project` for a web app.
- **`blast-radius` skill**, stack-neutral, with `paths:` globs for auth,
  sessions, secrets, policies, migrations, webhooks, payments, `.env*` and CI
  workflows.
- **Controlled vocabulary** (`controlled-vocabulary.py`, `/vocabulary`):
  reports inflated wording, requirements phrased as advice and completion
  claims with no observation; no hook runs it.
- **Plan linter and missing-import notes** (`check-plan.py`,
  `check-mod-imports.py`), run inside the post-edit review as notes, never a
  block.
- README "Features" section, quickstart, and a release checklist in
  `CONTRIBUTING.md`.

### Changed
- **`/adopt`** gains step 3b: detect the features (detect.md §8), ask before
  each missing dependency (Chrome, Node, Playwright, `bendit-web`), and write
  every feature to `.claude/bendit.json` in one chained `features.py` call. A
  "no" turns that feature off with why `you declined <it>`; it never stops
  adoption. The report lists the features and every new piece.
- **`prove.sh`** gives each feature a row: PASS or FAIL when it is on (each is
  run: the driver's selftest in a real browser, `claude plugin list --json`
  for the add-on in this project, the ls guard on `ls | wc -l`, the brief
  naming the branch), UNUSED when it is off, which is not a failure. The
  privacy row also scans `.claude/bendit.json`.
- **`/doctor`** prints the features table (`selfcheck.py --features`) and warns
  when `bendit-web` is enabled at user scope.
- **CI** validates and budget-checks every `plugins/*/`; the shell stage runs
  suites in parallel (half the CPUs, `BENDIT_CI_JOBS`), the suites that bind
  ports or run Chrome one at a time after it, each killed with what it started
  at `BENDIT_CI_SUITE_TIMEOUT` (default 240 s). GitHub CI installs Playwright
  with `drive-setup.sh` and checks Chrome is present.
- The Bash guard refuses setting `BENDIT_TTY` (pre-answering the installer).

### Fixed
- The import check times out (5 s) before its hook does (10 s), so a hung
  checker no longer loses the band-aid notes with it.
- A malformed `bendit.json` makes the ls guard refuse only what it would
  refuse anyway, not every Bash call.
- The installer never runs macOS's `/usr/bin` git and python3 stubs (each run
  opens Apple's dialog), has no apt route for Node (apt's is below 20), and
  counts only Google Chrome: Chromium cannot be driven.

### Not yet seen in a live session
- The installer has not been run from GitHub or the registries: the repo is
  private, so the curl URL, `npx bendit` and `pipx run bendit` do not work for
  anyone yet. It was run from a local clone (`BENDIT_SOURCE`) with no
  terminal, on a Next.js-shaped, a Python and a Go throwaway project.
- `/adopt`'s interactive flow has not been driven end to end by a person: its
  headless parts (the detect.md §8 commands, the `features.py` chain,
  `prove.sh`) were run by hand on those three projects.
- `prove.sh`'s `ux-design-laws` PASS path (an entry with `projectEnabled` true
  for this project) has been seen only with stubbed `claude plugin list`
  output; `bendit-web` has not been installed into a real project.
- That Claude Code offers `blast-radius` from its skill `paths:` globs is
  assumed, not observed.
- That the session brief, the ls guard and the plan and import notes reach the
  agent in a real session (each was tested by running its hook).

## [0.2.0] - 2026-11-19

Every change below came from something measured or seen: an adversarial
review, live headless runs of the commands, two real sessions in one repo, or
the eval sweeps recorded in `plugins/bendit/evals/results/INDEX.md`.

### Security
- **The Stop gate no longer runs a repo's `.claude/verify-harness` until you
  approve its exact content.** Before, a cloned repo could get code run on your
  machine with no prompt. You approve in your own terminal
  (`require-verification.py --trust <repo>`); any change needs approval again;
  the Bash guard refuses `--trust` from the agent and any write to the approval
  list. `/adopt`, the scaffold and `prove.sh` all say so.

### Added
- **Guard self-check** at session start: silent when healthy; names any guard
  that cannot run or no longer refuses, and how to fix it. `/doctor` runs it on
  demand together with `prove.sh`.
- `engineering-habits` skill (see Changed).
- Plugin icon, `CONTRIBUTING.md`, `SECURITY.md`, issue templates, this changelog.
- `verify` explains an app that never answers (its processes and their state,
  and probes of `127.0.0.1` and `localhost`).

### Changed
- **Bash guard**, from an adversarial review (11 of 64 bypasses blocked before,
  49 after) and the final eval: recursive deletes are refused with or without
  `-f` (an agent chose `rm -r` in 1 of 12 unprompted runs); destructive SQL
  piped into a client, `TRUNCATE` without `TABLE`, `ALTER TABLE … DROP`, a
  `WHERE` that exists only in a comment; `docker`/`kubectl exec` unwrapped;
  `prisma migrate reset`; `git reset --hard`, `git checkout -- .`,
  `git restore .`, `git push --mirror`/`--delete`, `git clean -f` (option values
  parsed correctly); deleting the folder the shell is in or one of its
  parents; `gtimeout`, `bash -c --`, `env -S`, `rimraf`, and node/python
  recursive-delete one-liners. A named folder inside a temp location (`/tmp`,
  `$TMPDIR`, macOS's `/var/folders/…/T/`) may still be deleted. A bare
  variable set only on some paths no longer trips the unset-variable rule,
  unless it is an inherited name such as `HOME` or `PWD`. 2,000-line commands are checked in 0.07s (was 12.8s).
  Remaining gaps need deliberate evasion and are listed in the guard's header.
- **Stop gate**: no longer blames one session for another session's edits
  (seen live, then tested live with two real sessions); also counts manifests,
  lockfiles, Dockerfiles, CI workflows, schema/SQL files, shebang scripts and
  CSS/HTML as changes; with no harness it suggests the project's own test
  command as one line; a failing harness is named by its failing lines, not
  only the last 1,500 characters; a `verified` stamp and hand-removed marks are
  shown to you. State moved to `.claude/.bendit-state/` so another copy of the
  gate cannot collide with it.
- **Skills**: four skills with no measured effect in three sweeps
  (fix-root-causes, prove-it-works, subtract-before-you-add,
  test-behavior-not-implementation) folded into `engineering-habits`.
  `checks-that-can-lie` kept: 28/30 vs 1/30 in a 30-run test (p = 2.3e-13).
- **Evals**: no LLM judge decides something a deterministic grader can see (a
  trace judge sees only the first and last 12 events); falsification twins for
  the new judges; the template moved out of discovery.
- `verify`: readiness waits in seconds (it counted attempts, so "within 90s"
  could take 270s); the app runs in its own process group so teardown stops
  the whole tree; the generated smoke test probes the app's health route when
  its source has one.
- CI: `actions/checkout` v7.0.1, `actions/setup-node` v7.1.0, Node 26 LTS,
  Claude Code CLI 2.1.328.

### Fixed
- Test fixtures that hung on GitHub's macOS runners (`HTTPServer`'s
  reverse-DNS lookup), a flaky port choice, a Linux-only temp-file check, and
  bash's "Terminated" notice leaking from teardown.
- The privacy scan catches home paths without a trailing slash, escaped or
  spaced names, and encoded `@`.

### Not yet seen in a live session
- That the self-check's message reaches you in the interface (tested by
  running the hook; not yet hit in a real session).
- That Claude Code passes `CLAUDE_PROJECT_DIR` to Stop hooks (the gate falls
  back to the shell's folder if not).

## [0.1.0] - 2026-11-18

First version: fail-closed guard hooks, the Stop gate, the verify-harness
generator, `/adopt`, `/new-guard`, `/ship`, `/review-diff`, the eval kit, and
the first measured result (Bash guard 12/12 vs 0/12 in two cases).
