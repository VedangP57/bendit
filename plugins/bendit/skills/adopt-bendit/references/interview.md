# Interview

Ask **only** what detection left as `?` or got from a weak source. **One
question per message**, each with a default in brackets and one line on why it
matters. "yes", "default" or an empty reply takes the default. Never batch
questions into a form: the user answers the first and skips the rest.

Order matters: later defaults depend on earlier answers.

1. **Confirm the commands.** Show the detected test / lint / typecheck / build /
   dev commands in one block. *"Are these right? [yes]"* Any correction
   overrides detection and is recorded with source "user".

2. **How do you run the app?** Only if there is an app and no dev command was
   found. *[the dev script; "none" for a library or CLI]*. Ask for the port and
   the URL or log line that means "ready" if the project shows neither.

3. **What does "verified" mean here?** This becomes `.claude/verify-harness`,
   which the Stop gate runs at the end of every turn that edited code.
   *[typecheck then test, e.g. `pnpm typecheck && pnpm test`]*.
   Say the cost: it runs often, so it must finish well inside the Stop hook's
   timeout (see `KIT/hooks/hooks.json`). If the full suite is slow, offer a fast
   subset and leave the full suite to CI. Refuse options that make it lie, such
   as a test flag that passes with zero tests.

4. **Integration branch?** Only if `origin/HEAD` is unset. *[`main` if it
   exists remotely, else the current branch]*. Recorded in `AGENTS.md` as
   `Integration branch: <name>`, where `/ship` and `/review-diff` read it.

5. **Production branch(es)?** Only if CI/deploy config did not show one.
   *[none]*. `/ship` refuses to open a PR from these.

6. **Guards.** Show the kit's guards in one line each (from `KIT/hooks/hooks.json`)
   and say plainly: they ship together; the zsh word-split guard is the one
   toggle (`zshGuard`, on by default, active only when `$SHELL` is zsh).
   *"Keep them all? [yes]"*. If the user wants one off, say that v1 cannot turn
   off a single kit guard other than via `zshGuard`, and record it under
   "not possible here".

7. **Generated files and hot paths?** The path-contracts guard refuses edits to
   files named `*.gen.*` and allocations in `*.hot.*`, and fires on nothing
   else. *"Any generated files or per-frame code you want protected? [no]"*. If
   yes, list them; renaming is the user's change to make, not this flow's.

8. **Install route.** Only if both are possible. *[marketplace, project scope]*.
   See `install.md`.

9. **CI.** Only if detection found none, or found one that never runs the gates
   on the integration branch. *[add a workflow that runs the gates on pull
   requests and on pushes to the integration branch]*. If the lint gate is red
   today, ask whether to land it non-blocking first and say how long: a gate
   that is red on day one gets `continue-on-error` and stays a badge.

10. **Project invariants.** *"Name up to three things that must never happen in
    this project (e.g. an unauthenticated route, a secret in client code).
    [skip]"*. They go into `AGENTS.md` under Invariants; `/ship` and
    `/review-diff` check every change against them.

## Output

Print the answers as a table (question, answer, source: detected / default /
user) and ask once: *"Write the project layer with these? [yes]"*. Nothing is
written before that yes.
