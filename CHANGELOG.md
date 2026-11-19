# Changelog

All notable changes. Dates are UTC.

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
