# The ladder

Most agent setups are a list of rules in prose (`CLAUDE.md`, `AGENTS.md`). Prose
is the layer that fails silently: nothing tells you when it was not read, or
was read and not followed. This kit's method is to hold each recurring failure
with the **cheapest layer that actually holds it**.

| layer | what | holds because | example |
|---|---|---|---|
| **L0** | delete the thing | there is nothing left to get wrong | remove a dead config file instead of documenting it |
| **L1** | structure: types, one definition, file layout | the wrong state cannot be written | one shared helper instead of nine copies; a branded type |
| **L2** | deterministic enforcement | it does not depend on anyone reading anything | a blocking hook, a CI gate, a lint rule |
| **L3** | prose | only as well as it is read and remembered | a skill or one `AGENTS.md` line, for judgement no machine can make |

Go down the table and stop at the first layer that works. Two corollaries:

- **If the fix is structural, use only the structural fix.** A prose rule next to
  the lint rule that enforces it rots, and the reader cannot tell which is
  authoritative.
- **A check that can pass for the wrong reason is worse than no check.** Every
  gate in this kit fails closed (a crash refuses) and refuses to report success
  on empty input (zero files scanned, zero tests run, zero cases captured).

And one rule about rules: **do not encode what will misfire.** Count how often a
proposed gate fires on the real codebase before turning it on. A gate that fires
ninety times to catch one defect gets disabled, and then you have nothing.

## Where the layers have limits

- A `PreToolUse` hook that exits 2 is the only in-session layer that **refuses**.
  A `PostToolUse` hook cannot block: the tool already ran. It is a well-timed
  nudge (L3 delivered at the right moment), not enforcement.
- `permissions.deny` rules match command text from the start, so they miss
  reordered arguments (`git push origin main --force`). Use them, but put the
  real check in a hook that reads the whole command.
- A `Stop` hook can refuse to end a turn, which is how this kit requires a
  verification run after code edits. It must allow an explicit, visible escape,
  or it will be disabled.
- A CI workflow that is not a required status check is a badge.

## Failure classes

Generic classes of failure seen when agents work in real codebases, each with
the cheapest layer that holds it. They are numbered for reference; the order is
roughly by how often each was seen.

### F1. Configuration that looks live and is dead

Hooks that call scripts that do not exist (hidden by `[ -f x ] || exit 0`); a
guard that reads the wrong payload field and so never fires; a refusal printed
to stdout where the agent never sees it; timeouts written in milliseconds into a
field read as seconds; two config files for one tool where only one is read; CI
filtered to a branch nobody pushes to.
**Layer: L0 + L2.** Delete what is dead. For what stays, a test that feeds it a
realistic payload and asserts the exit code *and* the message. A schema
validator catches none of these: each was semantically wrong, not malformed.

### F2. A written rule, violated at scale

"Keep files short" with a hundred long files; "validate input at boundaries"
with no validation library installed; a forbidden flag that nothing forbids.
**Layer: L2, or delete the rule.** More prose has already been tried. If a rule
cannot be enforced without blocking its own remediation, enforce a ratchet (fail
only when the count grows) instead.

### F3. Copy-then-drift

The same command, hook, config or helper copied into several places, each
edited separately until nobody knows which is right.
**Layer: L1.** One definition, consumed everywhere: a package, a plugin, an
import. Delete the copies in the same change.

### F4. Verification that resolves to "it compiles"

No tests in CI, tests that never run on the working branch, a suite gone silently
red, mock-heavy tests that pass whatever the code does.
**Layer: L2 first** (a gate that runs on every change), then a verification
harness that drives the running app. A verification skill on a project whose
tests never run is proving the wrong thing carefully.

### F5. Type escapes where the linter was told to be quiet

Escape hatches (`any`, ignores, disables) concentrate exactly where the rule
against them was switched off.
**Layer: L2, usually a one-line change:** turn the rule back on as a warning,
set the current count as a maximum, and ratchet it down.

### F6. Security checks re-implemented per area, with holes

Several ways to authenticate a request, each subtree choosing its own, and some
entry points with none; a credential compiled into client code; a test that
asserts the insecure behaviour is correct.
**Layer: L1 first** (one wrapper every entry point uses; a server-only marker
that makes a client import a build error), **then L2** (a lint rule that every
entry point uses the wrapper, with a reasoned escape for genuinely public ones).

### F7. Prose that asserts what the code does not do

Comments, plans and commit messages that describe behaviour the code does not
have, or excuse a workaround so the next agent copies it.
**Layer: L3, honestly.** No machine can check a claim. The rule: a factual claim
cites the `file:line` it was read from, or is written as a question; and every
report states its evidence rung.

### F8. Silent behaviour changes from dependency upgrades

A major version shifts a default (a style scale, a validator's strictness) and
nothing fails: typecheck, lint, build and a screenshot all pass.
**Layer: L2, its own gate:** diff the emitted output (CSS, serialized data)
against the base commit, and upgrade one major at a time.

### F9. The gate leaks through its exclusion list

Rules are reviewed; the `ignore`/`exclude` lists that take whole directories out
of the linter and type checker are not.
**Layer: L2:** print every exclusion the gates actually use, and require a
one-line reason for each.

### F10. Ship-then-fix

A fix lands within a few commits of the change it fixes. Worth measuring, but a
noisy signal until commit messages follow a convention.
**Layer: none yet.** Measure first; do not act on an unreliable metric.

### F11. Scope creep inside an agent task

"While I was there" tidying folded into a focused change, invisible in review.
**Layer: L3, one mechanic:** the task's planned steps become the agent's todo
list verbatim, and a step it skips stays in the list with a reason.

### F12. A test environment that makes the bug unreachable

A date bug that only appears across a daylight-saving boundary survives because
the tests pin the timezone to UTC, where no such boundary exists.
**Layer: L1, narrowly:** a distinct type for calendar dates so the wrong parse
does not compile; tests pinned to an environment where the bug is *possible*. A
regex lint for this fires on nearly every date in the codebase and catches
almost nothing.
