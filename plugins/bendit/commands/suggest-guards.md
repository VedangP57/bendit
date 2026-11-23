---
description: Find corrections you keep repeating in this project's past sessions (or, with --git, its commits), and propose guards
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/suggest-guards.py *)
---

Arguments: `$ARGUMENTS`

Run this from the repo the user is in. If the arguments hold `--min N`, use
that N instead of 2. If they hold `--git`, add `--git` to both runs below.

**Step 1: list.** Run:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/suggest-guards.py" --min 2
```

It reads this project's own Claude Code transcripts, and no other project's:
it keeps only lines whose `cwd` is this project, even when another project
shares the folder name. It lists every reply the person typed right after
an agent tool call: an id, the tool, the command head, and the text
(redacted, at most 160 characters). Newest sessions come first, and replies
that look like corrections come first; that is an ordering hint only. At
most 200 rows; it says how many more there are. It does not judge anything.

**Step 2: you judge.** Read every listed row.
Choose the ids whose text corrects the agent's action before it: blame, a
damage report, "undo", "put it back", "I told you", sarcasm about what broke.
Drop the rest: a question, an answer, an approval, a new request.
Then say in one line how many rows you read, how many you confirmed and how many you dropped.
Never confirm a row you have not read, and never guess an id.

**Step 3: cluster what you confirmed.** Run, with your ids comma-separated:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/suggest-guards.py" --min 2 --confirm <id,id,...>
```

Only the confirmed ids are clustered; nothing unconfirmed can count toward
`--min`. Each cluster shows every example. An id that is not one of this
project's replies is refused (exit 2): fix the list, never drop the check.
If you confirmed none, skip this step unless `--git` was asked; then run it
with `--confirm ""`.

With `--git` it also reads this repo's last 2,000 commits (one read-only
`git log`): commits whose subject starts with fix or revert, and commits that
touch a file again within an hour. These rows say `source: git` and name the
file (a file and its test fixed by nearly the same commits are one row).
They are candidates, ranked: reverts and fixes weigh more than quick
follow-ups, a file whose commits are mostly fixes ranks higher, and a
docs-only row comes last. Session rows always come first. Text mode prints
the top 8 git rows; `--json` has them all.

- `No past sessions found for this project` is not a failure. Say so, and
  stop unless `--git` rows follow.
- `No correction repeats` (or, for git rows, `No pattern repeats`) means
  nothing came up twice. Say so and stop: a
  one-off is an incident, not a pattern.
- Report skipped lines or files as the numbers given.

For each cluster, propose the cheapest layer that would hold it. Use the
ladder in `references/grow.md` of the `adopt-bendit` skill:

| # | source | pattern | count | layer | proposal |
|---|---|---|---|---|---|

- **delete** (L0): remove the thing that invites the mistake.
- **structure** (L1): a type, a shared helper or a file layout.
- **guard** (L2): a machine can refuse it from the tool call alone. Give a
  guard name (lowercase, hyphens).
- **prose** (L3): judgement no machine can make. One line in `AGENTS.md`.

A cluster can be noise: a correction that happened to follow the same
command, or a file that simply gets a lot of work. Say so instead of
proposing anything for it. Quote only the examples the script printed;
never open the transcripts to read more, and never read more commits or
diffs.

Propose git rows the same way as session rows.
Then ask once which rows to build. Each accepted row is its own change:
one PR per row.
Only on a yes, run `/bendit:new-guard <name>` for each guard row the person
picked, and say what the other picked rows need. Write nothing otherwise: no
file, no setting, no note.

Adapted from the `ruminate` idea in poteto's brainmaxxing, and from the
`correct` skill in poteto's pstack.
