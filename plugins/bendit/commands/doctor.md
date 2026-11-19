---
description: Check every bendit guard can still run and refuse, then prove this repo's setup
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh *)
---

Run both checks, in this order, from the repo the user is in, and read each
one's full output before saying anything:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/selfcheck.py" --verbose
bash "${CLAUDE_PLUGIN_ROOT}/scripts/prove.sh" .
```

1. **selfcheck** fires one known-bad probe at every hook in `hooks/hooks.json`,
   run the way Claude Code runs it. A row marked `OFF` is a guard protecting
   nothing: it could not start, crashed, or let the probe through.
2. **prove.sh** feeds every hook a known-bad and a known-good payload, dry-runs
   the Stop gate in a throwaway repo, and runs this repo's
   `.claude/verify-harness`. It writes nothing in the repo.

If a command itself fails to start (`python3: command not found`, `Operation
not permitted`), that is the finding: report it as every guard OFF.

Then print ONE table, a row per check from both outputs, without rewording
their results:

| check | result | evidence rung | detail |
|---|---|---|---|

Every row is rung 4 (run, output read). Under it, for each failing row, say
what it means and the fix the output names:

- `Operation not permitted` -> macOS is blocking the terminal from the plugin
  folder: give the terminal app Full Disk Access (System Settings > Privacy &
  Security), restart it, start a new session.
- `Permission denied`, a missing file, a crash -> reinstall:
  `claude plugin install bendit@bendit`.
- `python3` not found -> put Python 3.9+ on the PATH Claude Code runs with.
- no `.claude/verify-harness` -> this repo is not adopted yet: run `/adopt`.
  The guards still work without it; the Stop gate has nothing to run.

Neither script proves Claude Code actually runs the hooks in this session. Say
so, and end with: all green, or which guards are OFF right now.
