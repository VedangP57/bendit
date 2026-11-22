---
description: Check every bendit guard can still run and refuse, then prove this repo's setup
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh *), Bash(git push --force bendit-probe HEAD)
---

Run these checks, in this order, from the repo the user is in, and read each
one's full output before saying anything:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --verbose
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --features .
bash "${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh" .
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --session
```

1. **selfcheck** fires one known-bad probe at every hook in `hooks/hooks.json`,
   run the way Claude Code runs it. A row marked `OFF` is a guard protecting
   nothing: it could not start, crashed, or let the probe through.
2. **selfcheck --features** prints this project's `.claude/bendit.json` (the path given is resolved to its git root, so it works from a subfolder, else used as given; `$CLAUDE_PROJECT_DIR` is read only when no path is given; the path used is printed) as a
   table (`feature | on/off | why`), then one `add-on scope:` line. When that
   line says `bendit-web is installed for every project, not only this one`,
   the add-on is enabled at user scope: report it as a warning and give its
   fix as printed. `could not check` means the `claude` CLI did not answer: say
   so, never call it fine or a problem. A `features:` error means
   `.claude/bendit.json` is unreadable: that is a failure, never "all off".
   A `note: ignored feature …` line under the table means a newer bendit
   wrote a feature this one does not know, and wrote it off: report it as a
   note, not a failure. An error saying an unknown feature `is not off` names the
   running version and the update command: report it as a failure and give that
   command as printed.
3. **prove.sh** feeds every hook a known-bad and a known-good payload, dry-runs
   the Stop gate in a throwaway repo, and runs this repo's
   `.claude/verify-harness`. It writes nothing in the repo.
4. **selfcheck --session** says whether bendit's hooks started in THIS Claude
   window. Its first word after `window:` is `live`, `not live` or `unknown`
   (`not live (can't write <folder>)` means the start-up check could not leave
   its marker there). Its `live test:` line says whether the live test below is
   safe to run here: `run`, or `skip` with why.
   The three checks above run the hook scripts by hand; only this one, and the
   live test below, are about the window the person is typing in. It finds
   the marker bendit's start-up check leaves, named after this window's
   session id (`CLAUDE_CODE_SESSION_ID`, which Claude Code gives the Bash tool;
   the start-up check gets the same id in its `session_id`).

**The live test.** Always run the live test, whatever the window line says,
unless the `live test:` line says `skip`. Run this through the Bash tool
yourself, exactly, and read who answered:

```bash
git push --force bendit-probe HEAD
```

It is harmless: nothing here is named `bendit-probe` (that is what the `live
test: run` line checked), so if nothing refuses it, git fails with
`'bendit-probe' does not appear to be a git repository`. A refusal whose
message names bendit (`BLOCKED by bendit ...`, `[bendit] ...`) is a PASS, rung
5, and decides that bendit is running in this window, whatever the window line
says. Anything else is not a pass; then the window line only chooses the words
of the ending. When the `live test:` line says `skip`, leave it out: the push
could reach something real; say plainly that it was skipped, and why.
Never say bendit is active in this window without that refusal.

If a command itself fails to start (`python3: command not found`, `Operation
not permitted`), that is the finding: report it as every guard OFF.

Then print ONE table, a row per check from the first three outputs (a row per feature
from the features table, and one for the add-on scope line) and one `live test`
row (PASS, not a pass with what came back, or `skipped` with why),
without rewording their results:

| check | result | evidence rung | detail |
|---|---|---|---|

Every row is rung 4 (run, output read), except a live test PASS, which is rung 5. `OFF` (selfcheck) is a guard
protecting nothing: a failure. `UNUSED` (prove.sh's `feature:` rows) is a
feature this project does not use, with the reason beside it: not a failure,
report the reason as given. A feature `off` in the features table is that same
state; never call it `OFF`, which is reserved for a broken guard. Under it, for each failing row, say
what it means and the fix the output names:

- `Operation not permitted` -> macOS is blocking the terminal from the plugin
  folder: give the terminal app Full Disk Access (System Settings > Privacy &
  Security), restart it, start a new session.
- `Permission denied`, a missing file, a crash -> reinstall:
  `claude plugin install bendit@bendit`.
- `python3` not found -> put Python 3.9+ on the PATH Claude Code runs with.
- no `.claude/verify-harness` -> this repo is not adopted yet: run `/bendit:adopt`.
  The guards still work without it; the Stop gate has nothing to run.

Then one sentence: all green, or which guards are OFF and which features FAIL
right now.

**The ending.** The very last thing on screen is for a person who is not an
engineer: plain words, nothing after it (no table, no file path, no rung). It
is one status block from the list below, then, when anything is still open,
"What to do next:" with numbered steps in this order:

1. prove.sh's `harness: approved by you` row is FAIL:

   > Open a new Terminal window (not this chat), paste this, and type y:
   >   <the exact --trust command prove.sh printed>

2. Every other FAIL or OFF row: its fix, in plain words (what to do, not what
   broke), one step each.
3. The status block says to reopen Claude: that step goes last.

Never say bendit is active while a guard is OFF. Status blocks, the first that
applies:

- The live test was refused by bendit, and no guard is OFF:

  > bendit is active in this window: it just stopped a test force-push, as it should.

- The live test was refused by bendit, but a guard is OFF:

  > bendit is running in this window, but some of its checks are off. The steps below fix them.

- The live test was not refused, and the window line says `not live`:

  > This window was opened before bendit was set up, so its protection isn't running here yet.
  > Close Claude and open it again in this project, then type /bendit:doctor.

- The live test was not refused, and the window line says `unknown`:

  > bendit's protection isn't running in this window.
  > Close Claude and open it again in this project, then type /bendit:doctor.

- The window line says `live`, and git's own "does not appear to be a git
  repository" error came back (bendit started here, but its force-push check
  let the test through):

  > bendit started in this window, but its safety check did not stop a test force-push.
  > Reinstall it: paste claude plugin install bendit@bendit into a Terminal window.
  > Close Claude and open it again in this project, then type /bendit:doctor.

- The live test was refused by something that does not name bendit (another
  safety tool answered first):

  > Another safety tool in this window stopped the test before bendit could, so I can't
  > tell from here whether bendit's own check is running. Everything else above is as shown.

- The live test was skipped (`live test: skip`):

  > I skipped the live test: <why, from the live test line, in plain words>, so a test push
  > could reach something real. Everything else above is as shown.
