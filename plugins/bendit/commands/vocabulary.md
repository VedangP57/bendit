---
description: Report, fix or baseline this repo's controlled vocabulary: one word, one meaning
allowed-tools: Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/controlled-vocabulary.py *)
---

Check this repo's agent prose against its controlled vocabulary. The dictionary
is, first that exists: `$BENDIT_VOCAB`, `.claude/vocabulary.json`, then the
starter that ships with bendit. The baseline is `.claude/vocabulary-baseline`.

1. Find out which dictionary is in force:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/controlled-vocabulary.py" --report .
```

   Its first line says which one. If it says **the starter dictionary**, the
   repo has no vocabulary of its own. Ask the user, and wait for the answer,
   whether to run `--init` (default: no). It copies the starter to
   `.claude/vocabulary.json` so they can edit it, and it refuses to overwrite
   an existing file. Run it only on a yes:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/controlled-vocabulary.py" --init .
```

2. Print the report as it came out. Never write a file (`--init`, `--fix`,
   `--baseline`, `--html`) without the user's yes. Then explain the two writes
   they may want next:

   - `--fix [PATH]` applies only the `substitute` rule's one-for-one swaps
     (`in order to` becomes `to`). It edits files in place: show the count first.
   - `--baseline [PATH]` accepts every current finding under PATH, so later
     runs report only new prose. It writes `.claude/vocabulary-baseline`; commit it.

Other arguments: `--html FILE` (a readable page), `--check FILE` (one file, exit
2 with findings on stderr, for CI), `--dict` (print the dictionary), `--all`
(show baselined and suppressed findings too), `--strict` (every rule against
every document), `--json`.

## What it checks

Three rules, routed by what a document is for.

- **substitute**: register inflation with an exact equivalent. Runs everywhere.
- **obligation**: a requirement addressed to the agent but phrased as advice
  (`agents should treat...`, `where possible`). Instruction files only.
- **evidence**: a claim that work is done with no observation within three
  lines. Report files only. Evidence rungs: 1 said so, 2 pointed at the line,
  3 showed the bad case cannot happen, 4 ran it and read the output, 5
  reproduced it in the running app.

## Reading the result

- **A finding is a question, not a verdict.** It asks that a claim name its
  observation, or that a requirement be stated as one.
- **Disagree in the file, not by deleting the rule.**
  `<!-- vocab-ok: why this one is right -->` on the line or the line above. The
  reason is required and is printed in the report.
- **No hook runs this.** bendit wires no vocabulary hook, so nothing checks prose
  after an edit: run this command, or `--check FILE` in your own CI.
- A rule that misfires more than it catches: delete it from your
  `.claude/vocabulary.json`.
