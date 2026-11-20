# bendit: design (v1)

Status: approved direction 2026-11-17. Working name; renamable before publishing.

## Intent

An open-source Claude Code plugin that lets anyone give their coding agent a
*trust environment*: rules that are **enforced**, not merely written down, and a
method for growing their own rules from their own mistakes and measuring whether
each rule works.

It is extracted from a private kit used daily across one person's portfolio. The
private kit stays private; this repo holds only the generic, tested core plus the
tools to adapt it.

Why it is worth publishing: most agent setups are prose (CLAUDE.md / AGENTS.md
rule lists). Measured in the source kit, guidance moved behaviour about one run
in five, and even that figure was confounded; a hook that refuses moved it 12/12.
The differentiator is enforcement with evidence.

## The method this kit teaches (the ladder)

For every recurring failure, use the cheapest layer that holds it:

| layer | what | example |
|---|---|---|
| L0 | delete the thing | remove a dead config file instead of documenting it |
| L1 | structure / types / one definition | one shared helper instead of nine copies |
| L2 | deterministic enforcement | a blocking hook, a CI gate, a lint rule |
| L3 | prose | a skill or AGENTS.md line, only for judgement a machine cannot make |

And: a check that can pass for the wrong reason is worse than no check. Every
gate in this kit fails closed and refuses to report success on empty input.

## Goals

1. **Ready-made core**, installable in one command, safe defaults, works on macOS
   and Linux, bash or zsh, any language project.
2. **Adopt skill** (`/adopt`, skill `adopt-bendit`): interviews the user
   about their project and builds the project-specific layer, then proves it works.
3. **Grow-your-own**: a template + script to turn a repeated mistake into a new
   guard with a snapshot test suite (`templates/guard/`).
4. **Eval kit**: how to measure whether a rule changes agent behaviour, including
   the traps the source kit fell into.

## Non-goals (v1)

- Multi-session orchestration, session-start project briefs, a browser driver, database
  (Supabase/RLS) helpers. They exist privately but are unproven or stack-specific.
  (v2 adds one SessionStart hook, `scripts/selfcheck.py`: it only test-fires the
  guards and stays silent when they work, so it is not a brief.)
  They may ship later, each only with a measured result.
- Supporting non-Claude-Code agents.
- A GUI.

## Anti-goals (would make this a failure even if it works)

- A guard that fails open (crash → command runs). Every guard fails closed.
- A gate that reports success having checked nothing.
- Any personal data: names, emails, home paths, private repo/branch/project names,
  org names, real vulnerability examples. CI greps for this (privacy stage).
- Prose that claims a capability the code lacks.
- Copy-then-drift inside the kit: one definition per rule.

## Constraints

- Python 3.9+ standard library only for hooks. Bash 3.2-compatible shell.
- No network calls in hooks. Hook timeouts in seconds, each script must finish well
  inside its `hooks.json` timeout.
- Skill listing budget: total name+description of all skills and commands
  <= 2800 chars (scripts/skill-budget.py enforces it).
- Every behaviour has a shell test suite using scripts/expect.sh snapshots;
  `.github/workflows/ci.sh` runs them all and fails if any stage ran nothing.

## Layout (fixed: agents build to these names)

```
bendit/
  README.md                         public intro, quickstart, evidence, ladder
  LICENSE                           MIT, "Bendit contributors"
  .claude-plugin/marketplace.json
  .github/workflows/ci.yml, ci.sh   stages: shell imports privacy validate test
  docs/design.md                    this file
  docs/ladder.md                    the method + generic failure classes F1..F12
  plugins/bendit/
    .claude-plugin/plugin.json      userConfig below
    hooks/hooks.json
    scripts/
      shell_text.py                 shell lexer shared by guards
      block-dangerous-bash.py       PreToolUse Bash
      block-zsh-wordsplit.py        PreToolUse Bash, active only when $SHELL is zsh
      block-ls-parsing.py           PreToolUse Bash, active only when bendit.json turns ls-guard on
      warn-suppressed-stderr.py     PostToolUse Bash
      path-contracts.py             PreToolUse Write|Edit|MultiEdit (.hot.* / .gen.*)
      post-edit-review.py           Pre/PostToolUse writes, band-aid patterns
      require-verification.py       PostToolUse --mark + Stop gate
      expect.sh                     snapshot test helper
      skill-budget.py               listing budget
      eval-freeze.py                freeze/verify eval inputs
      new-guard.sh                  scaffolds a guard from templates/guard/
      scaffold-verification-skill.sh, verify.sh, verify-slots.sh, ports.py
      prove.sh                      /adopt's proof: guards, Stop gate dry run, harness
      privacy-scan.py               fails on personal data (used by CI and /adopt)
      probes.py                     one known-bad payload per hook (prove.sh, selfcheck)
      selfcheck.py                  SessionStart: test-fires every guard, loud only if one is off
      *.test.sh, *.expected
    skills/
      adopt-bendit/SKILL.md + references/*.md
      checks-that-can-lie, encode-lessons-in-structure,
      engineering-habits, create-verification-skill
    commands/ adopt.md, ship.md, review-diff.md, verify.md, new-guard.md, doctor.md
    templates/
      guard/guard.py, guard.test.sh  copy-and-edit starting point
      AGENTS.md                       project rules skeleton (ladder-ordered)
      verify-harness                  .claude/verify-harness example
    evals/ README.md (method), blocks-dangerous-bash/ example case
```

## Configuration (plugin.json userConfig)

- `integrationBranch` (string, default empty = detect from git remote HEAD):
  used by /ship and /review-diff.
- `zshGuard` (boolean, default true): enables block-zsh-wordsplit when $SHELL is zsh.
Per-project state lives in the project, never in the plugin folder, and only
where something reads it (a config file nothing reads is failure class F1).
There is one config file, `.claude/bendit.json`, read by `prove.sh` (and so
`/doctor`) and by the ls-guard hook (the session-brief hook will read it once it ships). It
records which optional features
(`browser-driver`, `ux-design-laws`, `session-brief`, `ls-guard`) are on and
why, and `/adopt` writes it through `scripts/features.py`. For a web app,
`/adopt` also installs the `bendit-web` add-on with `--scope project`, verified
on Claude Code 2.1.328: a plugin installed with --scope project loads only in
that project. The rest: `.claude/verify-harness` (command the Stop gate runs; holds the project's
commands), `AGENTS.md` (`Integration branch:` and production branch lines, read
by /ship and /review-diff), `.env.verify.example` (committed list of optional
local overrides, `.env.verify.local`), and for a vendored install
`.claude/vendor/bendit/VENDORED_FROM` (source and commit, plain text).
Nothing the kit generates may require a local-only file: a fresh clone verifies
as cloned.
Machine-wide state (port registry) lives under `${XDG_CONFIG_HOME:-~/.config}/bendit/`.
A repo the registry has not seen is registered on its first verify run (under
the registry lock, said in one line), so a fresh clone on a new machine works
without a hand-run command; only a failed allocation refuses.

## The adopt flow (skill adopt-bendit)

1. **Detect** (read-only): language(s), package manager, scripts (test/lint/typecheck/
   build/dev), integration + prod branches, CI present?, existing hooks/CLAUDE.md/
   AGENTS.md, monorepo?, shell. Print a findings table with file:line sources.
2. **Interview**: ask only what detection could not answer, one question at a time,
   each with a default: how to run the app, what "verified" means here, prod branch,
   which guards to enable, files that are generated / hot paths.
3. **Install**: plugin via marketplace if reachable; else vendor `plugins/bendit`
   into the project's `.claude/vendor/bendit/` and record the source and
   commit in `VENDORED_FROM` beside it.
4. **Build the project layer**: `.claude/verify-harness`, AGENTS.md from template
   (ladder-ordered, short), verify skill via scaffold-verification-skill.sh if the
   project has a runnable app, CI workflow if absent.
5. **Prove it**: `scripts/prove.sh <repo>` (tested, writes nothing in the repo):
   every hook in hooks.json gets a known-bad payload (exit 2, stderr naming
   bendit) and a known-good one (exit 0), the Stop gate is dry-run in a
   throwaway repo, the project's harness is run; it prints check | result |
   evidence rung. Then one live, in-session probe (a harmless force push) whose
   refusal must name bendit; another kit refusing first is
   "inconclusive". Refuse to call adoption done if any check fails.
6. **Hand over**: a short report: what is enforced, what is advice, what was not
   possible here and why, and how to add a guard (`/new-guard`).

## Evidence rungs (used in every report the kit's skills ask for)

1 said so · 2 pointed at the line · 3 showed the bad case cannot happen ·
4 ran it and read the output · 5 reproduced it in the running app.

## Left to the builder

Exact wording of skills/docs; test case selection beyond the shipped suites;
how /adopt detects each ecosystem (cover at least node/pnpm/npm/yarn/bun,
python/uv/pip/poetry, go, rust, plus "other: ask").
