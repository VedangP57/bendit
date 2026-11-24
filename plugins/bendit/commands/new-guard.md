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

Tell the user before editing: Claude Code treats `.claude/hooks/` as
sensitive, so **each edit to the guard and its tests asks them to approve
it**, even with edits pre-approved. That is by design (a hook decides what
the agent may do, so a person sees every change to one). Expect two or three
prompts. In a non-interactive run those edits are refused: stop and say the
guard is still the template and refuses nothing until the rule is written.

Then follow `references/grow.md` in the `adopt-bendit` skill, from
"Write the cases before the rule": real BLOCK cases from the transcript, more
ALLOW cases, the rule, the snapshot (read it), a false-positive replay, and only
then show the user the settings snippet and ask before adding it.

**Prove it on a real past command before it is turned on.** Take the command
the agent really ran from `/bendit:guard-report` (its `most recent` column) or
from an example `/bendit:suggest-guards` printed, or ask the person to paste it.
Never invent or retype a command to replay: a command you made up proves only
what you believe the mistake looks like. Then run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/new-guard.sh <name> --replay "<the real command>"
```

It must refuse every `--replay` (exit 2 with a reason) and allow ~20 everyday
commands; pass `--allow-file <file>`, one command per line, to use the
person's own ordinary commands instead.
Exit 1 on a replay means the guard is not proven: fix the rule,
never weaken the replay, and do not offer the settings snippet.
It prints commands redacted; quote them as printed. It never writes settings.

Adapted from poteto's pstack: prove each check catches a real past mistake
before you trust it.
