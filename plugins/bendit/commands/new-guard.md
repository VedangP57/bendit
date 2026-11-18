---
description: Turn a repeated agent mistake into a fail-closed guard hook with its own test suite
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/new-guard.sh *)
---

Scaffold a project guard named from the arguments: `$ARGUMENTS`

If no name was given, ask for one (lowercase letters, digits and hyphens, e.g.
`no-skip-hooks`) and for the mistake it should refuse. Then run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/new-guard.sh <name>
```

It writes `.claude/hooks/<name>.py` and `<name>.test.sh`, refuses to overwrite
anything, and prints a `.claude/settings.json` snippet. It does **not** enable
the guard. Exit 1 means something with that name exists: report it, do not
delete it.

Then follow `references/grow.md` in the `adopt-bendit` skill, from
"Write the cases before the rule": real BLOCK cases from the transcript, more
ALLOW cases, the rule, the snapshot (read it), a false-positive replay, and only
then show the user the settings snippet and ask before adding it.
