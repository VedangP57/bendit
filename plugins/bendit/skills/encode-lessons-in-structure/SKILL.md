---
name: encode-lessons-in-structure
description: Use when correcting the same mistake twice or about to add a rule to CLAUDE.md or AGENTS.md.
---

# Encode Lessons In Structure

If you are writing the same instruction a second time, the instruction is the symptom. Encode it.

## Use the cheapest layer that holds it (the ladder)

| layer | mechanism | holds because |
|---|---|---|
| **L0** | delete the thing that invites the mistake | there is nothing left to get wrong |
| **L1** | structure: a type, one canonical helper, a constructor that cannot produce the wrong value | the wrong state cannot be written |
| **L2** | deterministic enforcement: a lint rule, a CI gate, a `PreToolUse` hook that exits 2 | it does not depend on anyone reading anything |
| **L3** | prose: a skill or one `AGENTS.md` line | only for judgement a machine cannot make |

Go down the table and stop at the first layer that works. In this kit, `/bendit:new-guard`
scaffolds an L2 hook with its test suite.

**If the fix is structural, use only the structural fix.** Adding the prose rule
*and* the lint rule means the prose rots while the lint holds, and the next reader
cannot tell which is authoritative.

## Before you write a rule, check whether one already failed

Prose that is already being violated is evidence against writing more prose, not
a reason to word it more strongly. Grep for existing violations first. A rule
broken in a hundred files is not a rule.

## When prose is genuinely right

Some things cannot be mechanized: "cite the `file:line` for a factual claim about
this codebase", "ask before adding a dependency". Write those. Keep them short,
keep them in one file, and do not restate them anywhere else.

## Do not encode what will misfire

A gate with a high false-positive rate gets disabled, and then you have nothing.
Run the proposed rule against the real codebase and count firings before
proposing it. If it fires ninety times to catch one real defect, it is worse than
no rule: say so and pick a different mechanism (often an L1 type that knows what
a regex cannot).

A refusal must also be fail-closed and must say why on stderr: a guard that
crashes open, or blocks with no reason, teaches the agent nothing.
