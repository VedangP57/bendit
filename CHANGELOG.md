# Changelog

All notable changes. Dates are UTC.

## [Unreleased]

## [0.5.0] - 2026-11-21

Ideas adapted from poteto's public repos (brainmaxxing, verification-skill-example,
noodle, how). See Credits in the README and NOTICE.

### Added
- **`/bendit:suggest-guards`**: reads this project's past Claude Code sessions
  (only sessions that ran in this folder), finds corrections you made more than
  once, and offers each as a guard. Read-only; builds nothing without your yes.
  Secrets are redacted before anything else touches the text.
- **`/bendit:guard-report`**: every refusal is now recorded in
  `.claude/.bendit-state/fires.jsonl` (secrets redacted, never written through a
  symlink, the folder ignores itself in git); the report shows what fires and
  which rules never have.
- **Opt-in `primary-checkout-guard`**: refuses edits on the integration branch in
  the primary checkout and gives the `git worktree add` command instead. Off by
  default; `/bendit:adopt --detailed` asks.
- **Verify skill**: every new `verify-<name>` skill gets a proof bar ("it opens"
  is not proof), a list of what the harness cannot drive, testing rules (mock at
  the outage boundary, no fixed waits), Gotchas, and feature-map/journeys stubs.
- **`/bendit:review-diff`**: findings sorted into Act on / Consider / Noted /
  Dismissed, each with evidence and impact, then a lead judgment.
- **Plain-writing check**: a `slop` category in the controlled vocabulary
  (advisory, never blocks).
- **`INSTALL.md`**: a runbook an agent can follow, each step with a "Skip if"
  check; one summary and the conflict check come before anything is installed.
- **Homebrew**: `brew install vedangp57/tap/bendit`.
- **CI**: `plugin-lint.py` checks every hook path resolves and every description
  is capped.

### Fixed
- A guard whose own code cannot load, or that exits early inside a helper, now
  refuses (exit 2) instead of letting the command run.
- `install-route.sh conflict` no longer reports a false conflict for the same repo
  written another way, and treats Unicode lookalikes as a different source.

### Changed
- Local CI runs independent suites and stages in parallel (about 150 s).

### Changed
- README rebuilt around one command, one question and one approval line: what
  a refusal looks like first, then the quick start, evidence, limits and undo.
  Installer flags, the full enforced-and-advice table, the Stop gate, the
  ladder and measuring a rule moved to `docs/reference.md`.
- The npm and PyPI package descriptions name `/bendit:adopt` (they said
  `/adopt`, which Claude Code does not recognise).
- Hooks are documented as making no network calls except the session brief's
  probes of hosts and ports the project lists (the README said "no network
  calls" outright).

## [0.4.1] - 2026-11-20

### Changed
- `/bendit:adopt` ends with exactly what to do next: "Two last steps:" — the
  approval command to paste into a new Terminal window (only when the check is
  not yet approved), then "Close Claude and open it again in this project, then
  type /bendit:doctor." Step 2 is dropped when bendit is already running in
  this window.
- `/bendit:doctor` says whether bendit is running in THIS window (a SessionStart
  marker per session, outside the project), always runs the live force-push
  test, never says "active" while a guard is OFF, and ends with "What to do
  next:" — the approval command first, then every other fix, then reopen.
- The one-line undo works pasted exactly as printed (any indent), keeps CRLF
  line endings and skips files that are missing.
- `scaffold-verification-skill.sh --harness-owner`: a harness tracked in git is
  the person's, even when it still has a `TODO(bendit):` line.
- The setup summary uses plainer words (no `.git/info/exclude` row; exact paths
  move to "Also noted:" in the record).

## [0.4.0] - 2026-11-20

### Added
- **One-question `/bendit:adopt`**: the default flow detects the stack, shows one
  plain-words summary (what you get, every file, every install) and asks one
  question, "Go ahead?"; nothing outside that summary is written or installed.
  Ends with one command for the person to paste into a new Terminal window to
  approve the test check.
- **`/bendit:adopt --detailed`** keeps the full interview as before; it is also
  how to change a project that is already set up.
- **`scripts/install-route.sh`**: decides how bendit is installed for a project
  (GitHub or a vendored copy) and detects a conflicting copy elsewhere.
- **`scaffold-verification-skill.sh --keep-harness`**: leaves an existing
  `.claude/verify-harness` and verify skill exactly as they are, so a retry after
  a late failure resumes instead of being refused.
- A short README for the npm and PyPI package pages (they were blank).

### Changed
- `prove.sh`'s privacy row fails only on bendit's own files, not on other tools'
  notices in the project.
- The Stop gate's "nobody has approved it" message opens with one plain
  paragraph (what the check is, why a person approves it, the one command to
  paste into a new Terminal window) before the harness content. Its
  no-harness hints now say `/bendit:adopt --detailed`, since plain
  `/bendit:adopt` answers "already set up" on an adopted project.

### Fixed
- A retry of adopt after a late failure no longer stops on the harness an earlier
  run left behind (`--keep-harness`).

### Not yet seen in a live session
- Quick mode's install-and-write steps have not been run by a person end to end.

## [0.3.0] - 2026-11-20

Nothing below has an eval result yet: every new piece is *not yet measured*.

### Added
- **One-command installer** (`install.sh`; macOS and Linux). Checks the machine
  (`claude`, `git`, `python3` 3.9+; for a web app also Node 20+ and Google
  Chrome), asks before every install (default no, no `--yes`), fetches bendit at
  the matching release tag into the cache folder and starts Claude Code on
  `/bendit:adopt`; with no terminal it prints that command instead. Writes nothing in
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
  marketplace; `/bendit:adopt` installs it with `--scope project` for a web app.
- **`blast-radius` skill**, stack-neutral, with `paths:` globs for auth,
  sessions, secrets, policies, migrations, webhooks, payments, `.env*` and CI
  workflows.
- **Controlled vocabulary** (`controlled-vocabulary.py`, `/bendit:vocabulary`):
  reports inflated wording, requirements phrased as advice and completion
  claims with no observation; no hook runs it.
- **Plan linter and missing-import notes** (`check-plan.py`,
  `check-mod-imports.py`), run inside the post-edit review as notes, never a
  block.
- README "Features" section, quickstart, and a release checklist in
  `CONTRIBUTING.md`.

### Changed
- **Saved login state** (`saveState` / `storageState` in a scenario): a relative path
  now resolves against the scenario's folder, not the current directory, and must
  stay inside it. Saved login state is git-ignored, and `saveState` is refused if
  git would commit the file or if git cannot confirm it is ignored.
- **`/bendit:adopt`** gains step 3b: detect the features (detect.md §8), ask before
  each missing dependency (Chrome, Node, Playwright, `bendit-web`), and write
  every feature to `.claude/bendit.json` in one chained `features.py` call. A
  "no" turns that feature off with why `you declined <it>`; it never stops
  adoption. The report lists the features and every new piece.
- **`prove.sh`** gives each feature a row: PASS or FAIL when it is on (each is
  run: the driver's selftest in a real browser, `claude plugin list --json`
  for the add-on in this project, the ls guard on `ls | wc -l`, the brief
  naming the branch), UNUSED when it is off, which is not a failure. The
  privacy row also scans `.claude/bendit.json`.
- **`/bendit:doctor`** prints the features table (`selfcheck.py --features`) and warns
  when `bendit-web` is enabled at user scope.
- **CI** validates and budget-checks every `plugins/*/`; the shell stage runs
  suites in parallel (half the CPUs, `BENDIT_CI_JOBS`), the suites that bind
  ports or run Chrome one at a time after it, each killed with what it started
  at `BENDIT_CI_SUITE_TIMEOUT` (default 240 s). GitHub CI installs Playwright
  with `drive-setup.sh` and checks Chrome is present.
- The Bash guard refuses setting `BENDIT_TTY` (pre-answering the installer).

### Fixed
- **The installer's hand-over now works on a real terminal.** Two bugs seen
  live on 2026-11-20 (Claude Code 2.1.328): on macOS, handing claude `/dev/tty`
  as stdin crashed it (kqueue cannot watch a tty), and the command it was
  started on, `/adopt`, printed "Unknown command: /adopt" because plugin
  commands are namespaced by plugin name. The hand-over is now
  `claude --plugin-dir <kit>/plugins/bendit "/bendit:adopt"`, and every place
  that tells a person or the agent to type a bendit command (README, docs,
  commands, skills, script messages) uses the namespaced form.
- The import check times out (5 s) before its hook does (10 s), so a hung
  checker no longer loses the band-aid notes with it.
- A malformed `bendit.json` makes the ls guard refuse only what it would
  refuse anyway, not every Bash call.
- The installer never runs macOS's `/usr/bin` git and python3 stubs (each run
  opens Apple's dialog), has no apt route for Node (apt's is below 20), and
  counts only Google Chrome: Chromium cannot be driven.

### Not yet seen in a live session
- The installer has not been run from GitHub or the registries: at this
  release the repo was private, so the curl URL, `npx bendit` and
  `pipx run bendit` did not work for anyone yet. It was run from a local clone
  (`BENDIT_SOURCE`) with no terminal, on a Next.js-shaped, a Python and a Go
  throwaway project. (Since then the repo is public and bendit is published on
  npm and PyPI.)
- `/bendit:adopt`'s interactive flow has not been driven end to end by a person: its
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
  list. `/bendit:adopt`, the scaffold and `prove.sh` all say so.

### Added
- **Guard self-check** at session start: silent when healthy; names any guard
  that cannot run or no longer refuses, and how to fix it. `/bendit:doctor` runs it on
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
generator, `/bendit:adopt`, `/bendit:new-guard`, `/bendit:ship`, `/bendit:review-diff`, the eval kit, and
the first measured result (Bash guard 12/12 vs 0/12 in two cases).
