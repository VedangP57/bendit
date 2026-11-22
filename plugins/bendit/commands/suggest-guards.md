---
description: Find corrections you keep repeating in this project's past sessions, and propose guards
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/suggest-guards.py *)
---

Arguments: `$ARGUMENTS`

Run this from the repo the user is in. If the arguments hold `--min N`, use
that N instead of 2. Read the full output before saying anything:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/suggest-guards.py" --min 2
```

It reads this project's own Claude Code transcripts, and no other project's:
it keeps only lines whose `cwd` is this project, even when another project
shares the folder name.
It finds the messages where the person corrected the agent ("no,", "don't",
"I told you", "wrong"...) and groups them by the tool and command they
corrected. Each cluster shows a count, the tool and command, and one example
with secrets redacted. The script is read-only.

- `No past sessions found for this project` is not a failure. Say so and stop.
- `No correction repeats` means nothing came up twice. Say so and stop: a
  one-off is an incident, not a pattern.
- Report skipped lines or files as the numbers given.

For each cluster, propose the cheapest layer that would hold it. Use the
ladder in `references/grow.md` of the `adopt-bendit` skill:

| # | pattern | count | layer | proposal |
|---|---|---|---|---|

- **delete** (L0): remove the thing that invites the mistake.
- **structure** (L1): a type, a shared helper or a file layout.
- **guard** (L2): a machine can refuse it from the tool call alone. Give a
  guard name (lowercase, hyphens).
- **prose** (L3): judgement no machine can make. One line in `AGENTS.md`.

A cluster can be noise: a correction that happened to follow the same
command. Say so instead of proposing anything for it. Quote only the example
the script printed; never open the transcripts to read more.

Then ask once which rows to build. Only on a yes, run `/bendit:new-guard <name>`
for each guard row the person picked, and say what the other picked rows need.
Write nothing otherwise: no file, no setting, no note.

Adapted from the `ruminate` idea in poteto's brainmaxxing.
