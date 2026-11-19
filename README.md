# Bendit

[![ci](https://github.com/VedangP57/bendit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/VedangP57/bendit/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Claude Code plugin that gives your coding agent rules that are **enforced**,
not merely written down, and a method for growing your own rules from your own
mistakes and measuring whether each one works.

## The problem

Most agent setups are prose: a `CLAUDE.md` or `AGENTS.md` full of rules. Prose
fails silently. Nothing tells you when a rule was not read, or was read and not
followed, and the usual response to a broken rule is to write it again, more
firmly. In real codebases you find rules like "keep files short" sitting beside
a hundred long files, and safety hooks that have never fired because they read
the wrong field of their input.

## The evidence, stated honestly

In the author's own evaluation (private, and **not reproducible from this
repo**), the same instruction was tested two ways:

- as **guidance** (a skill telling the agent what to do), it changed behaviour
  in roughly one run in five, and even that figure was confounded: the
  measurement turned out to be partly reading the agent's narration rather than
  its work;
- as a **hook that refuses** the action, it held 12 times out of 12.

**This kit's own results, reproducible from this repo** (v0.2.0 sweep,
2026-11-19, CLI 2.1.328, judge sonnet, inputs frozen in
`evals/freezes/v2-final.json`; commands and provenance in
[evals/results/INDEX.md](plugins/bendit/evals/results/INDEX.md)):

| what was measured | with the kit | without | two-sided Fisher p |
|---|---|---|---|
| Bash guard: agent told to run `rm -rf ./build` | 12/12 directory survived | 0/12 | 7.4e-07 |
| Bash guard: agent told only to "free up space" (it picks the command) | 11/12 | 0/12 | 9.6e-06 |
| skill `checks-that-can-lie`: the CI check it writes refuses an empty scan | **28/30** | **1/30** | **2.3e-13** |

Every run in every arm attempted the task (a liveness control passed in all of
them), so no column is a run that measured nothing. The same guard result was
measured on v0.1.0 a day earlier (12/12 and 12/12 vs 0/12).

**The one deletion that got through** used `rm -r -- ./dist`: recursive, without
`-f`. v0.1.0 allowed that on purpose so routine cleanups kept working; the sweep
measured the cost (1 agent in 12 chose it unprompted), and since the `-f` flag
changes almost nothing in an agent's shell, recursive deletes are now refused
with or without it. Deleting a scratch folder inside a temp location stays
allowed.

**Skills.** `checks-that-can-lie` is the first skill with a measured effect: a
30-runs-per-arm test, decisive at p = 2.3e-13. Its judged criterion ("made the
check fail once") went the other way (21/30 vs 28/30), but the deterministic
grader that sees the same fact in the full trace passed 30/30 in both arms; the
LLM judge sees only the first and last 12 trace events, and the kit's hook
messages push that evidence into the part it cannot see. The other skills
showed no difference in three 3-runs-per-arm pressure tests: the model already
did the right thing without them, even under pressure. Four of them were
therefore folded into one, `engineering-habits`, to cut the per-session listing
cost. Treat the hooks as enforcement, `checks-that-can-lie` as measured advice,
and the other skills as advice.

**Cost of the kit.** In the earlier v0.1.0 skill sweep, 6 of 18 with-kit runs ran
out of turns (0 of 18 without): the Stop gate in a project with no harness yet,
and the guard refusing a scratch-folder cleanup. After two fixes it was 0 of 6
on the two worst cases, and 2 of 18 in the v0.2.0 sweep. Running `/adopt`
first, which writes the harness, avoids most of it.

That is a small sample, and you should not take it on trust. The kit ships the
method to measure it on your own project
([evals](plugins/bendit/evals/README.md)), including the traps that made
the author's own early numbers wrong.

## The method: the ladder

For every recurring failure, use the cheapest layer that holds it:

| layer | what | example |
|---|---|---|
| L0 | delete the thing | remove a dead config file instead of documenting it |
| L1 | structure / types / one definition | one shared helper instead of nine copies |
| L2 | deterministic enforcement | a blocking hook, a CI gate, a lint rule |
| L3 | prose | a skill or `AGENTS.md` line, only for judgement a machine cannot make |

A check that can pass for the wrong reason is worse than no check, so every gate
here **fails closed** (a crash refuses) and refuses to report success having
checked nothing. The full method and twelve generic failure classes, each with
the layer that holds it, are in [docs/ladder.md](docs/ladder.md).

## What is enforced, and what is advice

| | what | how |
|---|---|---|
| **Enforced** | destructive shell commands (recursive delete with or without `-f`, `find -delete`, destructive SQL, `git reset --hard` and other work-losing git commands, force push, …) | `PreToolUse` hook, exit 2 |
| **Enforced** | zsh word-splitting mistakes, when your shell is zsh | `PreToolUse` hook, exit 2 (option `zshGuard`) |
| **Enforced** | edits to files named `*.gen.*`; allocations in `*.hot.*` files | `PreToolUse` hook, exit 2 (opt in by file name) |
| **Enforced** | ending a turn that edited code without running the project's verification command | `Stop` hook runs `.claude/verify-harness`; an escape exists and is always shown to you |
| Check | that every guard can still run and refuse (python3 missing, a folder macOS made unreadable, a broken install) | `SessionStart` hook: silent when healthy; otherwise tells you and the agent which guards are off and how to fix it. Run `/doctor` any time |
| Advice | band-aid patterns in edits, suppressed stderr | `PostToolUse` hooks: they speak after the tool ran and cannot block |
| Advice | skills: `checks-that-can-lie`, `encode-lessons-in-structure`, `engineering-habits` | loaded when relevant; the agent may ignore them |
| Advice | commands: `/ship`, `/review-diff`, `/verify`, `/doctor` | checklists the agent runs when asked |

Guards read shell commands with a small lexer, so a rule asks about the command
that would actually run (through `sudo`, `env`, `bash -c`, `xargs`…), and quoted
text such as a commit message never trips one.

## Quickstart

One command, from inside your project folder, on macOS or Linux. Pick any of
the three spellings:

```bash
curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh | bash
npx bendit
pipx run bendit        # or: uvx bendit
```

That URL is "latest". To pin a release, put its tag in the URL:
`https://raw.githubusercontent.com/VedangP57/bendit/<tag>/install.sh`.

The installer checks that your machine has what bendit needs (`claude`, `git`,
`python3` 3.9 or newer; for a web app also `node` 20 or newer and Chrome or
Chromium), fetches bendit at the matching release tag into
`${XDG_CACHE_HOME:-~/.cache}/bendit/`, and starts Claude Code on `/adopt`.

- **It asks before every install.** The default answer is no, there is no
  `--yes`, and a `sudo` command is shown in the question before it can run.
  With no terminal to ask on, it installs nothing, lists what is missing and
  exits 1.
- **The installer itself writes only under the cache folder above**: nothing
  in your project and no Claude Code settings. The install commands you
  approve (a package manager, or the Claude Code installer) write wherever they
  normally do, system-wide or under `~/.local`. After the hand-over, `/adopt`
  (which asks before each step) is what changes your project.
- **Read it first** if you prefer not to pipe into a shell:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh -o install.sh
  less install.sh
  bash install.sh
  ```

- **Check without installing:** `bash install.sh --check` prints what is
  missing and installs nothing. Exit codes: 0 nothing is missing, 1 something is
  missing or failed, 2 usage error, refused location (your home folder or `/`)
  or unsupported system (Windows is not supported yet). `--version` and
  `--help` also exist.
- **Settings:** `BENDIT_SOURCE` (git URL or path to fetch bendit from),
  `BENDIT_REF` (tag or branch; default `v` plus the installer's version) and
  `BENDIT_CACHE` (cache folder).

### Manual install

```bash
claude plugin marketplace add https://github.com/VedangP57/bendit
claude plugin install bendit@bendit
```

Then, in your project:

```
/adopt
```

`/adopt` detects your stack (Node with pnpm/npm/yarn/bun, Python with
uv/poetry/pip, Go, Rust; anything else it asks about), asks only what it could
not detect, one question at a time, shows every file before writing it, and
builds the project layer: `AGENTS.md`, `.claude/verify-harness` (the command
that means "verified" here), and optionally a verification skill and CI. Then it
**proves** the setup with `scripts/prove.sh`: every guard is fed a known-bad
payload and must refuse (and a known-good one it must allow), the Stop gate is
dry-run in a throwaway repo, the harness is run, and the result is printed as a
table with the evidence rung of each row. It will not call adoption complete if
any check fails. You can run the same check yourself at any time:

```bash
bash <plugin folder>/scripts/prove.sh .
```

**Expect permission prompts.** Claude Code asks before any write under a
project's `.claude/` folder, because it treats that folder as sensitive. That
is expected, not an error. The kit's scripts (the verification scaffold,
`prove.sh`) do those writes themselves, one command each, so the agent rarely
has to write there file by file; `prove.sh` writes nothing in your project at
all.

To pin the kit inside your repository instead (no network at session time),
`/adopt` can vendor it under `.claude/vendor/bendit/` and write where
it came from to `.claude/vendor/bendit/VENDORED_FROM`. To check which
version you run against upstream:

```bash
cat .claude/vendor/bendit/VENDORED_FROM     # source: <url>, commit: <sha>
git ls-remote <url> HEAD                            # is upstream past that commit?
```

A web app's generated verify harness needs nothing local: a fresh clone runs
`.claude/skills/verify-<name>/bin/verify-<name> verify`, which finds the kit
itself (`BENDIT_KIT_ROOT`, a vendored copy, or the installed plugin).
Local overrides are optional and go in `.env.verify.local`; the committed
`.env.verify.example` lists them.

## Grow your own guard

The kit's guards cover common mistakes. The ones that cost *your* project are
found by using it: the second time you correct the same mistake, run

```
/new-guard no-skip-hooks
```

That scaffolds `.claude/hooks/no-skip-hooks.py` (a fail-closed `PreToolUse`
guard) and `no-skip-hooks.test.sh` (block / allow / crash cases with a message
snapshot). It never overwrites a file and never edits your settings: it prints
the `.claude/settings.json` snippet for you to add. The adopt skill's
`references/grow.md` walks through writing cases from the real transcript,
replaying your history to count false positives, and turning it on.

## Measuring whether a rule works

[plugins/bendit/evals/README.md](plugins/bendit/evals/README.md)
is the method: run a task that tempts the mistake many times with and without
the rule, and believe the difference only if it survives the listed traps.

- Sweep cases by `--tag`, never untagged: `_falsify/` holds cases built to
  FAIL and is discovered like any other case. To write a new case, copy
  `plugins/bendit/templates/eval-case/` into `evals/` and edit it.
- Always pass `--no-publish`; otherwise the HTML report is published to
  claude.ai by default where your account supports it.
- Grant the tools under test with `--allow-tools`. Without the grant, every case
  that needs to edit or run something can score perfectly while measuring
  nothing.

```bash
claude plugin eval ./plugins/bendit --tag smoke --scaffold --allow-tools Bash --no-publish
```

Run the smoke case first: if it fails with the plugin loaded, the harness is
wrong (grant, scaffold, plugin path) and no other number is worth reading.

## Platform support

- macOS and Linux; bash 3.2+ or zsh.
- Python 3.9+ (standard library only) for every hook. Hooks make no network calls.
- Any language project; `/adopt` detects Node, Python, Go and Rust and asks about
  anything else.
- Windows is not supported in v1 (untested).
- Claude Code only.

## Not in v1

Multi-session orchestration, session-start project briefs (the only
session-start hook here is the guard self-check), a browser driver for
verification, and database-policy helpers. They exist in the private kit this
was extracted from but are unproven or stack-specific; each may ship later, only
with a measured result. No GUI, and no support for agents other than Claude Code.

## Repository layout

```
.claude-plugin/marketplace.json
docs/ladder.md                      the method and failure classes F1-F12
docs/design.md                      design decisions for v1
plugins/bendit/
  hooks/hooks.json                  which guard runs on which tool
  scripts/                          guards, gates, test suites (*.test.sh)
  skills/                           practice skills + adopt-bendit
  commands/                         /adopt /new-guard /ship /review-diff /verify /doctor
  templates/                        guard template, AGENTS.md skeleton
  evals/                            measuring whether a rule changes behaviour
```

Every behaviour has a shell test suite (`scripts/*.test.sh`) using snapshot
tests of what the hooks actually say; `.github/workflows/ci.sh` runs them all and
fails if any stage ran nothing.

## Contributing and security

[CONTRIBUTING.md](CONTRIBUTING.md) covers running CI locally, test-first
changes and how to back a claim with evidence. Report a guard bypass or a
fail-open privately, as [SECURITY.md](SECURITY.md) describes, not in a public
issue. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
