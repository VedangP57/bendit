# Build the project layer

Everything here lives in the project, never in the plugin folder. For each file:
show it (or the diff against what exists), get a yes, write it.

## 1. `AGENTS.md`

**Absent:** start from `KIT/templates/AGENTS.md` and replace every `{{…}}`
placeholder with an interview answer. A placeholder with no answer is deleted
with its line, never left in. Keep it short: the template is ordered by the
ladder, enforced things first, and prose only for judgement.

**Present:** do not rewrite it. Propose only what is missing, as a diff:
an `Integration branch:` line, the commands block, an Invariants section,
and the "Enforced" list. Rules already in it that a machine could check are
listed in the report as `/new-guard` candidates, not moved.

**Make sure Claude Code reads it.** Claude Code loads `CLAUDE.md`. If the project
has no `CLAUDE.md`, propose one containing the single line `@AGENTS.md` (an
import). If it has one, propose adding that line rather than copying rules
across: one definition per rule.

## 2. `.claude/verify-harness` (and a verification skill, if there is an app)

The harness is the command the Stop gate runs after any turn that edited code;
`#` lines in it are comments. The kit's scaffold writes it, and for a web app
also writes a verification skill that launches the app and drives it like a
user (evidence rung 5). Read its current flags rather than assuming them, and
look before writing:

```bash
bash KIT/scripts/scaffold-verification-skill.sh --help
bash KIT/scripts/scaffold-verification-skill.sh "$(git rev-parse --show-toplevel)" --dry-run   # writes nothing
```

Pass what the interview settled (kind, dev command, package manager) using the
flags `--help` lists. Show the user the dry-run, get a yes, run it without
`--dry-run`. It writes everything under `.claude/` itself, in that one command,
so it costs at most one permission prompt (for that command), not one per file. For a web app
it also writes a committed `.env.verify.example`; it never needs a local-only
file, so a fresh clone verifies as cloned. If it reports TODOs, fill each one with the user: the generated
harness refuses until they are done, by design. If a harness already exists,
the scaffold refuses; read the existing one and propose changes as a diff
instead of forcing.

Then compare the harness with interview answer 3 and propose a diff if they
differ. **Run it once and time it.** It must exit 0 on the current tree (if it
is red today, say so and ask: a harness that is always red blocks every turn),
must exit non-zero when something breaks, and must not need a TTY or network
credentials. For a web app, follow the `create-verification-skill` skill for the
parts that need judgement (which flows matter, what "ready" means).

## 3. Where the facts go (and why there is no config file)

Every fact detection and the interview settled is written where something
**reads** it, and nowhere else. A config file nothing reads is dead
configuration (failure class F1 in `docs/ladder.md`): it looks authoritative and
drifts from the truth on the first change.

| fact | lives in | read by |
|---|---|---|
| integration branch | `AGENTS.md`: `- Integration branch: \`<name>\`` | `/ship`, `/review-diff` |
| production branch(es) | `AGENTS.md`: `- Production branch(es): ...` | `/ship` |
| test / lint / typecheck / dev commands, package manager | `.claude/verify-harness` and the app harness the scaffold generated | the Stop gate, `/verify` |
| port | the machine's port registry (`scripts/ports.py`), allocated by the scaffold, or by the first `verify` on a machine that has not seen the repo | `verify.sh` |
| vendored kit's source + commit | `.claude/vendor/bendit/VENDORED_FROM` (route B only) | people, via the README's check |

If a fact has no reader here, do not record it: say it in the report.

## 4. `.gitignore`

The Stop gate keeps per-session state under `.claude/.verify-state/`. The
scaffold already lists it (and the optional local `.env.verify.local`) in
`.git/info/exclude`, which is per-clone; propose adding `.claude/.verify-state/`
to `.gitignore` too, so every clone ignores it
(`git check-ignore -q .claude/.verify-state/x`). If the scaffold warned that
`.env.verify.example` is ignored, propose `!.env.verify.example`: the example
must be committed so a fresh clone has it.

## 5. CI (only if absent, or never gating the integration branch)

GitHub: propose `.github/workflows/bendit.yml` running the same commands
as the harness, on `pull_request` and on `push` to the integration branch, with
the ecosystem's setup action and the lockfile-respecting install
(`pnpm install --frozen-lockfile`, `npm ci`, `uv sync --locked`, `poetry install`,
`go mod download`, `cargo fetch`). No `continue-on-error`. Pin tool versions
from the project (`packageManager`, `.nvmrc`, `.python-version`,
`rust-toolchain.toml`); if none exists, ask rather than picking one.

Other forges: print the commands and say a workflow was not written.

Remind the user that a workflow that is not a **required** status check is a
badge: making it required is a repository setting only they can change.

## 6. Dead configuration found in detect

For each dead hook or config (a missing script, a wrong payload path, a
millisecond timeout), propose the fix or the deletion (deleting is layer L0),
one at a time. Do not fold these into another file's change.
