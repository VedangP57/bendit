---
name: fix-root-causes
description: Use when a fix adds a fallback, retry, swallowing catch, default value or workaround comment.
---

# Fix Root Causes

## The tell

You are about to write one of these:

- `catch { return { success: true, data: [] } }`: an error reported as success
- `?? []` / `|| ''` / `?? 0` covering a value that should never have been missing
- a retry around something that should not have failed once
- `// If there's an error, return empty results rather than failing`
- a sleep or timeout that makes a race condition less likely

Each one converts a loud failure into a quiet wrong answer. Stop and ask why the bad state is reachable.

## The order

1. **Reproduce it.** Know the actual input and the actual state, not the plausible one.
2. **Find where the invariant breaks**, not where it surfaces. The stack trace shows the second.
3. **Fix it there.** If it cannot be fixed there, say why in the PR, not in a comment.
4. **Make it unreachable** if you can. See `encode-lessons-in-structure`.

## Comments are the warning sign

A comment explaining a workaround is the artifact that makes the workaround permanent: the next agent reads it as sanctioned precedent and copies the pattern. If you are writing one, you have almost certainly stopped short of the fix.

If a constraint genuinely cannot be encoded yet, write it as a `TODO` with a specific condition, not as prose narration. A `TODO` is greppable; "for now" and "safety net" are not.

## When a band-aid is correct

Sometimes it is: an outage, an external dependency you do not control, a deadline you have accepted. Then say so explicitly, in the PR body, with what the real fix is and what would trigger it. That is a decision. A comment in the code is a decision nobody made.
