---
name: create-verification-skill
description: Use when a repo has no way to prove a change works, or asked to "add verification" / "make this verifiable" - scaffolds .claude/verify-harness (what the Stop gate runs) and, for a web app, a harness that launches, probes and leaves evidence.
---

# Create a verification harness

A repo where the strongest available evidence is "it compiles" cannot be trusted
to an agent. This builds the missing layer: a harness, in the repo, that runs
the real thing and fails when it is broken.

## Scaffold first

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/scaffold-verification-skill.sh <repo-path> [--dry-run]
    [--kind web|cli|library] [--dev '<serve command using "$PORT">']
    [--pm npm|pnpm|yarn|bun] [--name <name>] [--force]
```

Run `--dry-run` first: it prints what was detected (ecosystem, package manager,
lint/typecheck/test commands, app kind, launch command) and writes nothing.
Detection covers node (pnpm/npm/yarn/bun by lockfile), python (uv/poetry/.venv/
python3), go, rust and Makefile targets.

It writes:

- **`.claude/verify-harness`** (always) -- the command the Stop gate runs. For a
  library: lint/typecheck/test. For a CLI: those plus `<entrypoint> --help`. For a
  web app: those plus `scripts/verify.sh`. Commit it.
- **`.claude/skills/verify-<name>/`** (web only) -- `bin/verify-<name>` with
  `doctor` / `up` / `drive`, probe helpers in `lib/probe.sh`, a `scenarios/smoke.sh`,
  and a `SKILL.md`. Plus a committed `.env.verify.example` listing what a
  checkout may override, and a port block in the machine-wide registry
  (`scripts/ports.py`). Nothing it generates needs a local-only file: a fresh
  clone verifies as cloned. The skill is named after the project
  (`package.json` name without its scope, `pyproject.toml`, `go.mod`,
  `Cargo.toml`), else the folder; `--name` overrides.

Exit codes: **0** done; **3** written with TODOs; **2** refused (not a git repo,
bad flag, or a harness already exists -- `--force` regenerates and keeps your
scenarios).

**It never guesses silently.** Anything it could not detect -- no tests, two
lockfiles, a web app with no launch command, a project it does not recognise --
becomes a `TODO(bendit)` line at the top of the generated harness that
exits 2. Replace each with the real check it names. Do not delete a TODO to
make the harness pass: that is the false green this kit exists to prevent.

## Then do the parts a script cannot

### 1. Prove the harness can fail

Break the thing it checks -- a failing assertion, a stopped server -- and run it.
It must go red for that reason. A harness never seen to fail is decoration
(`checks-that-can-lie`).

### 2. Isolate the environment (web)

With no env file the app runs on its own defaults. To point it elsewhere, copy
`.env.verify.example` to `.env.verify.local` (local only, git-excluded): `up`
adds that file to the app's environment and never reads `.env` / `.env.local`.
Point every database and API at a local stack; set external services to invalid
placeholders so an accidental call fails loudly. `doctor` refuses any `*_URL` or
`scheme://` value that is not loopback. `PORT` always comes from the registry,
never from the file.

### 3. Write scenarios from what the app really does (web)

`scenarios/<name>.sh` runs with `BASE_URL`, `PORT` and `OUT`, sources
`"$PROBE"`, and calls `expect_ok`, `expect_status`, `expect_text`,
`expect_no_text` or `check <description> <command...>`. A scenario is
`VERDICT: VERIFIED` only if it exits 0, made at least one check, and none
failed. Fetch the page first and read it; write assertions from what it says.

### 4. Prove a denial, not just a success

For every capability, check the negative too: the logged-out request is
redirected, the invalid input is rejected, the missing page is a 404.

### 5. Turn written invariants into executed ones

Rules in `AGENTS.md`, `CLAUDE.md` or a review checklist are candidates for
scenarios or harness lines. A prose rule nobody checks is the layer this
replaces.

### 6. Record what each check covers

The generated `SKILL.md` has a `## Coverage` table: Check / Covers / Synced,
where Synced is the commit at which someone last read that code and confirmed
the check still describes it -- not when it last passed.
`git log --oneline <synced>..HEAD -- <covers>` empty means the row is current.

### 7. Run it end to end

Run `/verify` (or `sh .claude/verify-harness`), read the output, and open the
evidence (`artifacts/<scenario>-<timestamp>/` for a web app). **A harness that
was never executed is a draft, not a deliverable.** Report the evidence rung
reached.

## When a check fails: drift or defect

1. **Update from the code, not from the result.** Read what the check covers
   before editing it; editing until the red goes away is how a check becomes a lie.
2. **Re-falsify** after any edit that makes a check pass.
3. **Never edit product code in a maintenance pass.** Report the regression.

A pass ends in exactly one of **clean**, **changed** (updated, re-falsified,
Synced stamped) or **blocked** (could not run, and why). Blocked is not a pass.
