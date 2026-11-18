# Prove it

Adoption is done only when both parts below have been **run** and their output
read. One FAIL means the report says **NOT COMPLETE**, names the failure, shows
its output and says what the next step is. If you fix something, rerun the whole
step, not just the check that failed: a fix can break a neighbour.

Do not improvise these checks with hand-written payloads, scratch repos or
`rm` in the project. That is what the script is for: improvised probes hit
permission prompts (Claude Code treats writes under `.claude/` as sensitive) and
left a Stop-gate marker behind in the project they were proving.

## 1. The script: `prove.sh`

```bash
bash "$KIT/scripts/prove.sh" "$(git rev-parse --show-toplevel)"
```

`KIT` is the plugin root (see SKILL.md). It writes nothing inside the project:
every probe, the scratch repo and the temp files live under one `mktemp -d`
that a trap removes. It prints a table, `check | result | evidence rung`, then
the details of any failure, and exits non-zero if any check failed.

What its rows mean:

| rows | what was run | a FAIL means |
|---|---|---|
| `<guard>: refuses ...` | the hook from `hooks.json`, fed a known-bad payload: must exit 2 with a reason on stderr that begins `[bendit]` or `BLOCKED by bendit` | the guard lets the bad case through, or refuses without saying so, or under a name that is not this kit's |
| `<guard>: allows ...` / `silent ...` | the same hook, fed a known-good payload: must exit 0 | the guard would block ordinary work and get uninstalled |
| `<script>: has a probe` | a hook in `hooks.json` that `prove.sh` has no payloads for | the kit gained a hook nobody taught `prove.sh` to test; it cannot vouch for it |
| `Stop gate: ...` | a throwaway git repo: an edit is marked, a harness that exits 1 must be refused (exit 2), one that exits 0 must be allowed | the gate cannot refuse, or cannot be satisfied |
| `harness: ...` | the project's `.claude/verify-harness`, as the Stop gate runs it | the harness is red, missing, only comments, too slow, or it changed the working tree |
| `privacy: ...` | `privacy-scan.py` over `AGENTS.md`, `CLAUDE.md`, `.claude/verify-harness`, `.env.verify.example`, `.claude/skills/` | a home path or a real email in a file meant to be committed (also a portability bug: it fails on every other machine) |

Rows marked `(advice)` are `PostToolUse` hooks: they speak after the tool ran
and cannot block, so in the report they go under ADVICE, not ENFORCED, however
they score here. The zsh guard is probed with `SHELL=zsh` forced; if the user's
shell is not zsh, report it as "inactive here" in the hand-over, not as enforced.

Every row is rung 4 (ran it, read the output). Copy the table into the report
as printed. Do not re-run a failing row by hand to get a different answer:
read its failure detail, fix the cause, rerun the script.

## 2. Live wiring, in this session (rung 5)

The script proves the hook *scripts*. It cannot prove that Claude Code *runs*
them on a real tool call. In a session started after the install, run this
through the Bash tool, exactly:

```bash
git push --force bendit-probe HEAD
```

It is harmless either way: the remote does not exist, so if nothing refuses it,
git fails with `'bendit-probe' does not appear to be a git repository`.

Read **who** refused it. Several kits can guard one session, and their messages
look alike; the first hook to refuse is the one you see.

| what came back | result |
|---|---|
| a refusal whose message names bendit (`BLOCKED by bendit ...`, `[bendit] ...`) | **PASS**, rung 5 |
| git's own "does not appear to be a git repository" error | **FAIL**: the guard is not wired. Check `claude plugin list` and that this session started after the install |
| a refusal from a different kit or hook (its message names another plugin) | **inconclusive: another guard answered first**. Not a pass and not a fail: bendit's hook may be wired and simply never got the call. Report it as that, with the message you saw |
| this session started before the install | **pending a new session**: say so, do not mark it either way |

Project guards added with `/new-guard` get the same pair: their own suite
(`.claude/hooks/<name>.test.sh`), then a live probe of their own.

## Report

The `prove.sh` table as printed, plus one row for the live check with its result
from the table above. Any FAIL: NOT COMPLETE. An inconclusive live check is
reported as inconclusive; it does not make adoption complete or incomplete by
itself, and the report says what would settle it.
