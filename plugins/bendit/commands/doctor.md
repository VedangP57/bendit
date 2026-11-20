---
description: Check every bendit guard can still run and refuse, then prove this repo's setup
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh *)
---

Run these checks, in this order, from the repo the user is in, and read each
one's full output before saying anything:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --verbose
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --features .
bash "${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh" .
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
3. **prove.sh** feeds every hook a known-bad and a known-good payload, dry-runs
   the Stop gate in a throwaway repo, and runs this repo's
   `.claude/verify-harness`. It writes nothing in the repo.

If a command itself fails to start (`python3: command not found`, `Operation
not permitted`), that is the finding: report it as every guard OFF.

Then print ONE table, a row per check from all three outputs (a row per feature
from the features table, and one for the add-on scope line), without rewording
their results:

| check | result | evidence rung | detail |
|---|---|---|---|

Every row is rung 4 (run, output read). `OFF` (selfcheck) is a guard
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

None of the scripts proves Claude Code actually runs the hooks in this session. Say
so, and end with: all green, or which guards are OFF and which features FAIL right now.
