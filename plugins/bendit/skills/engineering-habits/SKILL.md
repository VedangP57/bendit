---
name: engineering-habits
description: Use when a fix adds a fallback, default, retry or swallowing catch; when writing or reviewing a test; before adding a file, dependency, option or rule; before reporting work done.
---

# Engineering Habits

Four moves. Use the section your situation names; each stands alone.

| you are about to | section |
|---|---|
| add `?? []`, `or ""`, a retry, a sleep, a `catch` that returns success | Fix the root cause |
| write or review a test | Test behaviour |
| add a file, dependency, abstraction, config option, flag or rule | Subtract first |
| say done, fixed, working or passing | Prove it works |

## Fix the root cause

A fallback converts a loud failure into a quiet wrong answer. Before writing one, ask **where the bad value comes from**, for every source, not just the one the traceback shows.

1. Reproduce with the real input. Print the rows/values that hit the bad state, all of them, not the first.
2. Find where the invariant breaks, not where it surfaces. A `None` crash in a formatter usually started in a loader, a column map, a query.
3. Fix it there. A default is correct only for a source that is *legitimately* empty; say which one, and fix the others.
4. After the fix, read the output for values that are now silently blank, zero or empty. That is what the fallback would have hidden.

Neighbouring defaults (`or ""` three times in the same function) are precedent for a pattern, not proof it is right here. A workaround comment ("return empty rather than failing") becomes the next agent's precedent; if a band-aid is genuinely the decision (outage, external dependency), say so in the PR body with the real fix and what triggers it.

## Test behaviour

The one question: **would this test still pass if the function under test returned the wrong answer, or `undefined`?** If yes, it tests nothing.

- Assert on the observable result: the returned value, the stored row, the rendered text, the status code.
- Mock only what you cannot run (network, clock, payment provider). Never mock the unit under test. If the collaborator is plain in-memory code, use the real one.
- "Same style as the other tests" does not extend to mock-and-assert-the-call when that style cannot catch the bug the test is for. Match the file's layout and naming; assert on the result. Say why you departed.
- Break the implementation on purpose once (comment out the line) and watch the test go red. If it stays green it is decoration.
- A test that asserts wrong behaviour is correct is worse than none: delete or invert it as part of the fix.

## Subtract first

The cheapest version of most changes is a deletion.

1. **Would deleting something solve this?** A stale call, a retired path, a dead config file. If the CHANGELOG or a comment says a thing is retired, deleting its caller is the fix; a switch whose only correct value is "off" is a second code path kept alive.
2. **Does this already exist?** Grep before writing a helper, a client, a formatter.
3. **Is it a second way to do something done once already?** Extend or replace the existing path; do not run both.
4. A suggested switch "like the existing one" is a precedent to check, not copy: does the existing one have a reason (rollback window, staged rollout) that this case lacks?

When you do add: one place, exported once, and delete what it replaces in the same change. Confirm a config file is actually read before editing it.

## Prove it works

A claim is a generation; an observation is evidence. Report the evidence rung you reached, never rounded up:

1. I said so · 2. I pointed at the `file:line` · 3. I showed the bad case can't happen (type, constraint) · 4. I ran it and read the output · 5. I reproduced it in the running app

- Run it on the **real inputs** the thing exists for (the data file, the full list, the real route), not only the one example the request quoted. A fix copied from a sibling inherits the sibling's blind spots.
- "It compiles" / "CI is green" / "types pass" is rung 4 for compilation and rung 1 for behaviour. Find out what CI actually runs before quoting it.
- Partial verification is reported as partial. If you cannot reach rung 4, say which rung you reached and what the next would need.
- A check you wrote is part of the claim: see `checks-that-can-lie`.

| claim | not enough | reaches rung 4/5 |
|---|---|---|
| a database policy denies a user | reading the policy (permissive policies are OR-ed; a role filter can make a rule never apply) | query *as* the denied principal and count rows |
| a route requires auth | grepping for the middleware | call it with no credential, get the refusal |
| a UI change looks right | the markup diff | a screenshot of the changed screen |
| a hook blocks something | reading its regex | pipe it a real payload, read exit code and stderr |
