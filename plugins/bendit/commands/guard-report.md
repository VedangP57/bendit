---
description: Show which bendit guard rules refused something lately, and which never fire
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/guard-report.py *)
---

Run this from the repo the user is in, passing on any `--days N` from the
arguments (default 30), and read its full output before saying anything:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/guard-report.py" --days 30
```

Every bendit guard writes one line to `.claude/.bendit-state/fires.jsonl` each
time it refuses a command or an edit. The report counts those lines per guard
and rule for the window, then lists every rule that never fired in it.

Explain the result in plain words:

- Each row of the table is a rule that stopped something, and how often. Say
  what the rule guards against in one short phrase (for example
  `rm-recursive`: deleting a folder tree; `force-push`: overwriting remote
  history).
- `guard-error` or `payload-unreadable` means a guard could not check
  something and refused to be safe. Several of these point at a broken
  install: suggest `/bendit:doctor`.
- `no refusals recorded yet` means the log does not exist yet. It is not a
  failure, and it does not mean the guards are off: `/bendit:doctor` checks that.
- Exit 2 means the log exists but could not be read. Fires are unknown, not
  zero: say so, and never report it as "nothing fired".
- `skipped N unreadable lines` means some lines were damaged. Report the
  number as given.

Then suggest what is worth a look, and nothing more:

- rules that never fire in a long window may not fit this project;
- rules the person often overrides (runs the refused command themselves) may be
  in their way.

Never remove, turn off or edit a guard or a rule here, and never edit the log.
Removing a rule is the person's call: if they want to, point them to
`/bendit:adopt --detailed`.
