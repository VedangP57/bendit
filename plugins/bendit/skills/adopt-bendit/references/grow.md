# Grow your own guards

The kit's guards cover mistakes common to most projects. The ones that cost
*this* project are found by using it. The signal is a repeat: **the second time
you correct the same mistake, the correction is the symptom.**

To find the repeats, run `/bendit:suggest-guards`. It reads this project's past
sessions (read-only), groups the corrections you keep making by the command
they correct, and proposes a layer for each. It builds nothing without a yes.

## 1. Pick the cheapest layer that holds it

| layer | ask | example |
|---|---|---|
| L0 | can I delete the thing that invites the mistake? | remove the dead config the agent keeps editing |
| L1 | can a type, one shared helper, or a file layout make it unrepresentable? | a branded date type so the wrong parse stops compiling |
| L2 | can a machine refuse it deterministically? | a lint rule, a CI gate, a `PreToolUse` guard |
| L3 | is it judgement no machine can make? | one line in `AGENTS.md` |

Stop at the first layer that works. The `encode-lessons-in-structure` skill has
the reasoning; the rest of this file is L2 as a guard.

A guard fits when the mistake is visible **in the tool call itself**: a command
line (`Bash`) or a file path and content (`Write`/`Edit`). If deciding needs the
whole codebase (types, call graphs), it belongs in a lint rule or CI instead.

## 2. Scaffold it

```
/bendit:new-guard <name>
```

That runs `bash KIT/scripts/new-guard.sh <name>`, which writes
`.claude/hooks/<name>.py` and `<name>.test.sh` (plus the two helpers they share),
refuses to overwrite anything, and **prints** the `.claude/settings.json` snippet
instead of editing settings.

## 3. Write the cases before the rule

- **BLOCK cases from the real mistake.** Use the exact command or edit the agent
  made, copied from the transcript, not retyped from memory. A fixture you
  typed encodes what you believe the input looks like.
- **ALLOW cases, more of them.** Near-misses that must stay silent: the same
  words in a commit message, a quoted string, a different subcommand. A guard
  that fires on ordinary work gets uninstalled within a day.
- Keep the template's CRASH cases. Every guard fails closed.

Then edit `RULES` in `<name>.py` until the suite passes, record the message
snapshot with `--accept`, **read it**, and run again without `--accept`.

## 4. Count false positives before turning it on

Replay real history through it. Claude Code keeps session transcripts as JSONL
under `~/.claude/projects/<project-path-with-dashes>/`; this feeds every Bash
command recorded there to the guard and prints what it would have refused.
Transcripts hold secrets: print a command only through `fire_log.preview_of`
(redacted, then cut to 120 characters), never raw, as this does:

```bash
python3 - "$HOME/.claude/projects/<dir>" .claude/hooks/<name>.py KIT/scripts <<'PY'
import json, pathlib, subprocess, sys
src, guard = pathlib.Path(sys.argv[1]), sys.argv[2]
sys.path.insert(0, sys.argv[3])
from fire_log import preview_of  # no fire_log, no output: never print unredacted
seen = refused = 0
for f in sorted(src.glob('*.jsonl')):
    for line in f.open(errors='replace'):
        try:
            msg = json.loads(line).get('message') or {}
        except ValueError:
            continue
        for part in msg.get('content') or []:
            if isinstance(part, dict) and part.get('type') == 'tool_use' and part.get('name') == 'Bash':
                cmd = (part.get('input') or {}).get('command', '')
                seen += 1
                p = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': cmd}})
                r = subprocess.run(['python3', guard], input=p, capture_output=True, text=True)
                if r.returncode == 2:
                    refused += 1
                    print('REFUSED:', preview_of(cmd))
print(f'{refused} of {seen} commands refused')
PY
```

`0 of 0` means nothing was replayed, not that nothing would fire: check the
path. Read every REFUSED line. If most are legitimate work, narrow the rule or
pick another layer. A rule that fires ninety times to catch one real mistake is
worse than no rule.

## 5. Prove it on the real past command

The guard must refuse the command the agent really ran. Take it from
`/bendit:guard-report` (the `most recent` column) or from an example
`/bendit:suggest-guards` printed, or ask the person to paste it.
Never invent or retype a command to replay. Then:

```bash
bash KIT/scripts/new-guard.sh <name> --replay "<the real command>"
```

Every `--replay` must exit 2 with a reason, and every ordinary command must
exit 0: a built-in list of ~20 everyday commands, or the person's own with
`--allow-file <file>` (one per line). Exit 1 means not proven: fix the rule,
not the replay. It never writes settings, and prints commands redacted.
Adapted from poteto's pstack: prove each check catches a real past mistake
before you trust it.

## 6. Turn it on and prove it

1. Show the user the snippet `new-guard.sh` printed and the merged
   `.claude/settings.json`; write it only on a yes.
2. Run `prove.md` step 2 for the new guard (bad payload exits 2 with a reason,
   good payload exits 0), then step 3 live in a new session with a harmless
   instance of the mistake.
3. Add one line to the "Enforced" list in `AGENTS.md` naming the guard. Delete
   the prose rule it replaces: two definitions of one rule drift apart.
4. Add `bash .claude/hooks/<name>.test.sh` to CI so the guard cannot rot.

## 7. Measure whether it changed behaviour

A guard that passes its suite is proved to refuse. Whether the *agent* now makes
the mistake less often is a separate question, answered with an eval: a task
that tempts the mistake, run many times with and without the guard. The kit's
method, and the traps that make an eval report a perfect score while measuring
nothing, are in `KIT/evals/README.md`. Read it before believing any number,
including a good one.
