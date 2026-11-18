---
name: prove-it-works
description: Use when about to report work as done, fixed, working or passing.
---

# Prove It Works

A claim that something works is a generation. An observation is evidence. Report the second.

## The evidence ladder

State which rung you reached. Rung 1 alone is not a result.

1. **I said so.** Worthless on its own.
2. **I pointed at the line.** A real `file:line` you read this session, or the library's own source.
3. **I showed the bad case can't happen.** A type, a constraint, a policy that makes it unrepresentable.
4. **I ran it.** A command, its exit code, and the part of its output that decides the question.
5. **I reproduced it in the running app.** The real user path, the real data store, the observable result.

## Rules

- Never report a step as passing unless you ran it and saw the output. Partial verification is reported as partial.
- "It compiles" and "types pass" are rung 4 for *compilation* and rung 1 for behaviour.
- A test you wrote and ran proves behaviour only if it would fail when the behaviour broke. See `test-behavior-not-implementation`.
- A check you wrote is part of the claim. If you never saw it fail, see `checks-that-can-lie`.
- When you cannot reach rung 4, say which rung you reached and what the next one would need. That is a complete answer; a confident guess is not.

## Common cases

| claim | rung 2 (not enough) | what reaches rung 4/5 |
|---|---|---|
| a database access policy denies a user | reading the policy text (permissive policies are OR-ed, and a role filter can make a scary-looking rule never apply) | run the query *as* a principal who should be denied and count the rows |
| a route requires auth | grepping for the middleware | call it with no credential and get the refusal |
| a UI change looks right | the diff of the markup | a screenshot of the changed screen |
| a dependency bump is safe | the build passing (rung 4 for the build only) | diff the emitted output (CSS, serialized data) where the dependency owns behaviour |
| a hook blocks something | reading its regex | pipe it a real payload and read exit code and stderr |
