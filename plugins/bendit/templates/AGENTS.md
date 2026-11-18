# {{project_name}}: rules for coding agents

Ordered by how a rule is held. Enforced rules come first because they need no
reading; prose comes last and is kept for judgement a machine cannot make.
Do not restate an enforced rule as prose here: one definition per rule.

- Integration branch: `{{integration_branch}}`
- Production branch(es): {{prod_branches}}

## Commands

Run these exact commands; never substitute a hand-written equivalent.

```
test:       {{test_command}}
lint:       {{lint_command}}
typecheck:  {{typecheck_command}}
build:      {{build_command}}
dev:        {{dev_command}}
```

"Verified" means `.claude/verify-harness` passed: `{{verify_harness}}`.

## Enforced (a hook, CI or the compiler refuses these; listed so you know why)

- bendit guards: destructive shell commands, force pushes, edits to
  `*.gen.*` files, and ending a turn with unverified code changes.
{{project_guards}}

## Structure (one way to do each thing)

{{canonical_helpers}}

## Invariants (checked by /ship and /review-diff on every change)

{{invariants}}

## Judgement (prose, because no machine can check it)

- A factual claim about this codebase cites the `file:line` it was read from,
  or it is written as a question.
- State the evidence rung reached for "done", "fixed" or "works": 1 said so,
  2 pointed at the line, 3 showed it can't happen, 4 ran it, 5 saw it in the
  running app. Partial verification is reported as partial.
- Stay in the task's scope. Anything else found goes in the report, not the diff.
- Ask before adding a dependency.
