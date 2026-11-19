---
name: checks-that-can-lie
description: Use when writing a test, script, grader or assertion whose result you will act on, or when a check passes suspiciously cleanly.
---

# Checks That Can Lie

A failing check costs you a minute. A check that **passes for the wrong reason**
costs you every conclusion built on top of it.

Before trusting a green result, make the check fail on purpose once. If you
cannot make it fail, it is not testing anything.

## Falsify first

```bash
# 1. run the check against a case that MUST fail
# 2. confirm it fails, and for the stated reason
# 3. only then trust it passing
```

When the evidence came from a command you wrote, that command is part of the
claim. A green result from an unfalsified checker is evidence rung 1, not rung 4
(see `engineering-habits`).

## Shell traps that produce confident false passes

| trap | what happens | instead |
|---|---|---|
| `cmd \| tail && echo OK` | `$?` is `tail`'s, so OK prints while `cmd` fails | `set -o pipefail`, or don't pipe the thing you check |
| a binary that is not installed (`timeout` is absent on stock macOS) | `command not found`, the work never runs, later assertions see nothing changed and pass | probe the binary first; refuse without it |
| `[ test ] && VAR=x` under `set -e` | a false test exits the script silently, mid-way | `if …; then …; fi` |
| backticks in an unquoted heredoc (`<<EOF`) | the backticked word is *executed* and replaced by its output | quote the delimiter: `<<'EOF'` |
| `'"'"'` inside double quotes | that idiom is for single-quoted strings; in double quotes it injects stray quotes | pick one quoting style per string |
| a regex narrower or wider than what you mean | it flags prose that merely mentions the word, or misses the one line that matters | print the matches with context and read them |

## Absence assertions need two controls

"Does not contain X" passes when the file does not exist, the selector never
rendered, or the query returned nothing. Pair every negative assertion with a
**positive control** that must match.

That is not enough on its own. "The bad pattern is gone" and "nobody touched the
file" read identically, and the second scores a perfect pass. Add the control
that costs something to satisfy: **assert the input is no longer byte-identical
to what you seeded**, computed from the seed rather than typed.

## A checker that never started

"No output" is not "no problems". A type checker invoked the wrong way, a linter
pointed at a missing config, a test runner given a directory with no tests, a
grep over a file that does not exist: each reports nothing, which reads as
nothing wrong.

- **Prove the tool ran.** Probe for a version, or count what it checked, and
  refuse to continue without it.
- **Never score "exit code plus empty report" as success.** Non-zero with
  nothing to say is the tool failing to start, not a clean project.
- **Zero cases is never a pass.** A suite whose cases all stopped running must
  go red, not report "0 failed".

## The runner can withdraw the ability to act

Every trap above assumes the subject at least ran. A harness that silently
removes a capability (a tool gated behind a permission nobody granted, a sandbox
that blocks writes) defeats them all: the subject does nothing, nothing changes,
and every absence assertion goes green together.

The tell is a whole row of checks turning green at once, especially ones that
disagreed before. Confirm the subject still has the capability under test, and
read what one subject actually did, not only its score.

## A judge reads what the subject chose to say

An LLM grader or rubric that reads a transcript is reading the subject's last
message, not the work. Anything that seizes that message (a hook firing, a
warning, a permission prompt) moves the score with no change in the work.

- Find the setting that chooses the judge's input and set it explicitly. Prose
  in a rubric ("read only the report file") instructs the judge; it does not
  select what the judge is shown.
- Before believing a large effect, read one subject's actual output. Real effects
  on behaviour are rarely perfectly clean; a perfect split usually means
  something upstream is answering a different question.
- Falsify a judgment with a **pair of twins** whose narration contradicts the
  artifact: one that must fail, one that must pass. A judge that tracks the
  artifact in both directions is reading the artifact.

## Run the check where the failure lives

A check that runs somewhere the bug cannot reach always passes.

- **Same confinement** as the real thing: sandbox, permissions, user, cwd. A
  hook tested by hand outside its sandbox works every time and fails in use.
- **Same inputs, from the same source** as the real thing: the engine's own type
  declarations, a recorded payload, the actual file. A fixture you typed encodes
  what you believe, so agreement between your code and your fixture is one
  belief counted twice.
- For a data shape, cite where the shape is defined (`file:line`) next to the
  fixture, so a shape that moves breaks the citation instead of passing quietly.

When a check keeps passing while the thing it watches keeps breaking, stop adding
assertions and go watch the running system.

## A signal nobody can act on is worse than none

A warning that restates a permanent, acceptable condition on every run teaches
the reader to ignore the place warnings appear, and costs you every real warning
later. Before shipping one, ask: what is the reader supposed to do? Can this be
the normal state indefinitely? If the condition is permanent and acceptable, say
nothing; if it is not acceptable, fix it or fail loudly once. When it is
resolved, clear the message: a status line holds the last thing written to it.

## When the output IS the product, snapshot it

An assertion only tests the question someone thought to ask. When the thing
being built is text an agent or human reads (a hook's refusal, a report, a CLI's
output), **print what it said, commit that, and diff it on every run.** In this
kit that is `scripts/expect.sh`:

```bash
. "$D/expect.sh"
expect_init "$D/my-guard.expected"
expect_scrub_dir "$T" '<tmp>'      # before the first capture, or it is refused
expect_capture "blocks the bad case" python3 "$GUARD" <<<"$payload"
expect_verify || fail=$((fail+1))
```

- **Scrub anything that varies** (temp paths, ids, timestamps). On macOS a temp
  dir has two spellings (`/var/...` and `/private/var/...`); scrub both.
- **Keep stdout and stderr apart.** A blocking hook's reason must be on stderr;
  merged with `2>&1`, a reason that moved to stdout stays green.
- **Accepting must not report success.** Recording a snapshot fails the run; the
  second run, comparing against what was written, is the review.
- **Read the diff before accepting.** An unread accepted snapshot proves nothing.
- **Keep the ordinary assertions.** A snapshot says what changed, not whether it
  is right; exit codes and must-fire/must-stay-silent pairs still matter.

## Two questions that find a dead feature

**"If this block never ran, would anything fail?"** Make the first line of each
`try` throw, run the suite, revert. Zero failures means nothing protects that
path, and a `catch` that discards its error is what lets a whole feature die
unnoticed. Keep the protection, drop the silence: report the error once.

**"Does every rule have a fixture?"** For each user-facing message in a rule
table, grep for it in the committed snapshot. A message that appears in no case
is a rule nobody has seen fire, and may be unable to. Likewise, **every tool a
hook matcher names needs a fixture**: a rule that reads one tool's payload shape
silently never applies to a sibling tool that sends a different shape.
