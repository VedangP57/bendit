# bendit reference

The [README](../README.md) is the short path. This page is everything else:
installer internals, the full enforced-and-advice table, the Stop gate, growing
your own guards, measuring a rule, and where bendit keeps its state.

- [Installer](#installer)
- [The install runbook for an agent](#the-install-runbook-for-an-agent)
- [What setup writes](#what-setup-writes)
- [Vendoring bendit into your repository](#vendoring-bendit-into-your-repository)
- [How setup proves itself](#how-setup-proves-itself)
- [Enforced and advice in full](#enforced-and-advice-in-full)
- [The Bash guard](#the-bash-guard)
- [The Stop gate in detail](#the-stop-gate-in-detail)
- [Per-project features in detail](#per-project-features-in-detail)
- [Grow your own guard](#grow-your-own-guard)
- [What fires: the refusal log](#what-fires-the-refusal-log)
- [The ladder](#the-ladder)
- [Measuring whether a rule works](#measuring-whether-a-rule-works)
- [More on the evidence](#more-on-the-evidence)
- [Platform support](#platform-support)
- [Not included](#not-included)
- [Where bendit keeps state](#where-bendit-keeps-state)
- [Repository layout](#repository-layout)

## Installer

Four spellings, one installer. `npx bendit` (`packages/npm`) and
`pipx run bendit` / `uvx bendit` (`packages/pypi`) wrap the same `install.sh`,
kept identical by `packages/sync.sh`. Each wrapper needs `bash`. The Homebrew
formula (`packages/homebrew`) installs `install.sh` itself as `bendit`.

```bash
curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh | bash
npx bendit
pipx run bendit        # or: uvx bendit
```

```bash
brew install vedangp57/tap/bendit
bendit                 # run in your project folder
```

That URL is "latest". To pin a release, put its tag in the URL, for example
`https://raw.githubusercontent.com/VedangP57/bendit/v0.5.0/install.sh`
(`/<tag>/` for any other release).

**What it does.** The installer checks that your machine has what bendit needs
(`claude`, `git`, `python3` 3.9 or newer; for a web app also `node` 20 or newer
and Google Chrome; Chromium alone cannot be driven), fetches bendit at the
matching release tag into `${XDG_CACHE_HOME:-~/.cache}/bendit/`, and starts
Claude Code on `/bendit:adopt`. Run it from inside your project folder: it
refuses to run from your home folder or `/`.

- **It asks before every install.** The default answer is no, there is no
  `--yes`, and a `sudo` command is shown in the question before it can run. It
  asks on the terminal (`/dev/tty`), never on piped input.
  With no terminal to ask on, it installs nothing, lists what is missing and
  exits 1; if nothing is missing, it fetches bendit and prints the
  `claude --plugin-dir <cache>/v<version>/plugins/bendit "/bendit:adopt"` command to
  run instead of starting Claude Code. Playwright, for a web app's browser
  driver, is not the installer's: `/bendit:adopt` asks about it.
- **The installer itself writes only under the cache folder above**: nothing
  in your project and no Claude Code settings. The install commands you
  approve (a package manager, or the Claude Code installer) write wherever they
  normally do, system-wide or under `~/.local`. After the hand-over,
  `/bendit:adopt` (which asks before each step) is what changes your project.
- **Read it first** if you prefer not to pipe into a shell:

  ```bash
  f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh -o "$f" && less "$f" && bash "$f"
  ```

  `mktemp` makes a new file only you can write, outside your project, so
  nobody else on the machine can swap the script between `less` and `bash`,
  and it leaves nothing in your project.
- **Check without installing:**
  `curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh | bash -s -- --check`
  prints what is missing ("Nothing is missing." or "Missing: …") and installs nothing.

| Flag | Effect |
|---|---|
| `--check` | report what is missing, install nothing |
| `--version` | print `bendit installer <version>` |
| `--help`, `-h` | usage |
| anything else | exit 2, `Unknown option: <x> (try --help)` |

| Exit code | Meaning |
|---|---|
| 0 | ready, or `--check` found nothing missing |
| 1 | something required is missing or failed, there was no terminal to ask on, or the fetch failed |
| 2 | usage error, refused location (your home folder or `/`), unsupported system (Windows is not supported yet), or `HOME` unset; the wrappers also exit 2 if `bash` is missing |

| Setting | Default | Meaning |
|---|---|---|
| `BENDIT_SOURCE` | `https://github.com/VedangP57/bendit.git` | git URL or path to fetch bendit from |
| `BENDIT_REF` | `v` plus the installer's version | tag or branch to fetch |
| `BENDIT_CACHE` | `${XDG_CACHE_HOME:-~/.cache}/bendit` | cache folder |

### Manual install

```bash
claude plugin marketplace add https://github.com/VedangP57/bendit
claude plugin install bendit@bendit
```

Then, in your project:

```
/bendit:adopt              # one question, then one approval line
/bendit:adopt --detailed   # the full interview, every choice yours
```

The marketplace lists two plugins: `bendit` and the web add-on `bendit-web`.

## The install runbook for an agent

[`INSTALL.md`](../INSTALL.md) at the repository root is the same install,
written for the agent in Claude Code to follow. A person pastes
`Install bendit in this project by following https://raw.githubusercontent.com/VedangP57/bendit/main/INSTALL.md`
and the agent works through six numbered steps: check the tools; show the
person one summary and wait for a yes, then fetch bendit into a temporary
folder and run `install-route.sh route` and `install-route.sh conflict` (the
same checks `/bendit:adopt` runs: marketplace names are global to the
computer, so a `bendit` that already points at another copy is a question,
never a silent switch); add the marketplace and install the plugin at project
scope, by the route chosen; run `/bendit:adopt`; the person's approval of the
check; then reopen and run `/bendit:doctor`.

Each step has a `Skip if:` command whose exit 0 means "already done",
so an install that stopped half way resumes from step 1 without redoing
anything. The checks only read. Steps 2 and 3 share one: the computer's
plugin-source list (`~/.claude/plugins/known_marketplaces.json`) must point
`bendit` at `github.com/VedangP57/bendit` or at this project's
`.claude/vendor/bendit`, and `claude plugin list --json`, run from the
project, must show `bendit@bendit` on for this project at any scope. The
others read `.claude/bendit.json` and the approval list
(`trusted-harnesses.json`; no `.claude/verify-harness` means nothing to
approve). The runbook never installs a
missing tool (it points the person at `install.sh`, which asks), never
answers `/bendit:adopt`'s question, and never runs the `--trust` approval;
the Bash guard refuses that from the agent anyway. The step layout, a
`Skip if:` check per step, is adapted from the `INSTALL.md` of poteto's noodle.

## What setup writes

The default asks one plain question, then installs and writes only what its
summary listed. It decides everything else itself (the check is your test
command, typecheck or build; all guards on; no CI), writes `AGENTS.md` (new, or
a bendit section added to yours; never rewritten), `CLAUDE.md` (one line,
`@AGENTS.md`), `.claude/settings.json` (the plugin, installed for this project
only), `.claude/verify-harness` (only if absent) and `.claude/bendit.json`
(written last, because its existence means "set up"). For a web app it also
writes a verification skill, `.claude/skills/verify-<name>/` (the AI starts your
app and clicks through it when you ask), with the committed
`.env.verify.example`. It adds `.claude/.bendit-state/` to `.gitignore`, and
offers `git init` if the folder is not a git repository. It never edits
`~/.claude`, never commits and never pushes. It ends by running
`scripts/prove.sh`, then prints the one approval command.

If no test command is found it asks for one ("type it; otherwise reply skip").
A project already set up gets "bendit is already set up here" and a pointer to
`/bendit:doctor`; use `/bendit:adopt --detailed` to change it.

`--detailed` is the full interview: it detects your stack (Node with
pnpm/npm/yarn/bun, Python with uv/poetry/pip, Go, Rust; anything else it asks
about), asks only what it could not detect, one question at a time, shows every
file before writing it, and builds the same project layer, with the
verification skill and CI as your choice.

**Expect permission prompts.** Claude Code asks before writes under a
project's `.claude/` folder. That is expected, not an error. The verification
scaffold does those writes itself, in one command, so the agent rarely has to
write there file by file.

A web app's generated verify harness needs nothing local: a fresh clone runs
`.claude/skills/verify-<name>/bin/verify-<name> verify`, which finds the kit
itself (`BENDIT_KIT_ROOT`, a vendored copy, or the installed plugin). Local
overrides are optional and go in `.env.verify.local`; the committed
`.env.verify.example` lists them.

## Vendoring bendit into your repository

To pin the kit inside your repository instead (no fetch at session time),
`/bendit:adopt` can vendor it under `.claude/vendor/bendit/` and write where it
came from to `.claude/vendor/bendit/VENDORED_FROM`. To check which version you
run against upstream:

```bash
cat .claude/vendor/bendit/VENDORED_FROM     # source: <url>, commit: <sha>
git ls-remote <url> HEAD                    # is upstream past that commit?
```

## How setup proves itself

Both adopt modes end by running `scripts/prove.sh`: every guard is fed one
known-bad payload and must refuse it (and a known-good one it must allow), the
Stop gate is dry-run in a throwaway repo, the harness is run, every feature
that is on is run, and the result is printed as a table with the evidence rung
of each row. A feature that is off is `UNUSED`, which is not a failure; a
feature that is on and does not work is a `FAIL`. Neither mode calls adoption
complete if any check fails. Then adopt runs one live check in your session,
`git push --force bendit-probe HEAD`, which must be refused by a message
naming bendit.

Run the same check yourself at any time. It only reads; it writes nothing in
your project:

```bash
bash <plugin folder>/scripts/prove.sh .
```

`prove.sh` is a health check, one payload per hook. The full behaviour of each
guard is pinned by its test suite (`plugins/bendit/scripts/*.test.sh`).

## Enforced and advice in full

| | What | How |
|---|---|---|
| **Enforced** | destructive shell commands (see [the Bash guard](#the-bash-guard)) | `PreToolUse` hook, exit 2 |
| **Enforced** | zsh word-splitting mistakes, when your shell is zsh | `PreToolUse` hook, exit 2 (plugin option `zshGuard`, default on) |
| **Enforced** | parsing the output of `ls` (a pipe into `wc`, `$(ls)`, a `for` list), only in a project whose `.claude/bendit.json` turns `ls-guard` on because `ls` there is a formatting alias or function; not yet measured | `PreToolUse` hook, exit 2 |
| **Enforced** | edits in the primary checkout (not a `git worktree`) while it is on the integration branch (the `integrationBranch` field of the `primary-checkout-guard` entry in `.claude/bendit.json`, else `origin/HEAD`), only where `.claude/bendit.json` turns `primary-checkout-guard` on; the refusal gives the exact `git worktree add` command; not yet measured | `PreToolUse` hook on Edit, Write, MultiEdit and NotebookEdit, exit 2 |
| **Enforced** | edits to files named `*.gen.*` ("edit the generator, not its output"); allocations in `*.hot.*` files (code that runs every frame or tick) | `PreToolUse` hook, exit 2 (opt in by file name; nothing fires until you rename a file) |
| **Enforced** | ending a turn that edited code without running the project's verification command | `Stop` hook runs `.claude/verify-harness`; an escape exists and is always shown to you |
| **Enforced** | a web app's behaviour in a real browser: a `scenarios/<name>.json` in the generated verify skill is run in Google Chrome by `lib/drive/drive.mjs` (Playwright 1.65.1, which `scripts/drive-setup.sh` installs into bendit's cache, never into the project; no browser is downloaded); only as far as your harness runs the verify skill's `verify`; not yet measured | the Stop gate runs the harness, `verify` runs every scenario, and a failing scenario fails the harness |
| Check | that every guard can still run and refuse (python3 missing, a folder macOS made unreadable, a broken install) | `SessionStart` hook: silent when healthy; otherwise tells you and the agent which guards are off and how to fix it. Run `/bendit:doctor` any time |
| Advice | a session-start brief: branch, push state, uncommitted files, other worktrees (other checkouts of the same repo) with unfinished work, and only the liveness probes the project lists; only where `session-brief` is on; not yet measured | `SessionStart` hook (startup and clear); it never blocks, and a malformed config is an alarm in the brief |
| Advice | after an edit: band-aid patterns (a `catch` that returns success, an added `@ts-ignore`, comments excusing a workaround, `?? {}` or an empty `try/catch` as the only change), a `NEXT_PUBLIC_*` key used to authorize, a `'use client'` file touching a service-role credential, an RLS-bypassing client without `server-only`, and shell traps (exit status after a pipe, `timeout` absent on macOS) | `PostToolUse` hook: speaks after the tool ran and cannot block; ends "Address these now or say explicitly why each does not apply." |
| Advice | after an edit: a plan under `docs/superpowers/plans/` is linted for the sections and task shape the plan format requires; a TypeScript module in a plugin mod (a directory holding `hooks.json`) is checked for a sibling export it uses but never imports; not yet measured | folded into the post-edit review; a note to the agent, never a block, and a crash in either check yields no note |
| Advice | a command that hid its errors (`2>/dev/null`) and printed nothing: "that command hid its errors and returned nothing, so it has told you nothing." | `PostToolUse` hook; warns, never blocks, because hiding errors is often legitimate |
| Advice | skills: `checks-that-can-lie` (measured), `encode-lessons-in-structure`, `engineering-habits`, `create-verification-skill`, `adopt-bendit` (drives `/bendit:adopt`) | loaded when relevant; the agent may ignore them |
| Advice | the verify skill `create-verification-skill` generates carries a **Proof bar** ("it opens" is not proof: name the trigger and the end state, check one side effect), a **What this harness cannot drive** list (OS file drops, native dialogs, third-party sign-in, reported as `blocked`), a **Gotchas** list, and `references/features/README.md` and `references/journeys.md` stubs for a feature map; adapted from poteto's verification-skill-example; not yet measured | prose in the generated `SKILL.md`; a re-scaffold without `--force` overwrites none of it |
| Advice | skill `blast-radius`: before a change to auth, payments, database policies, migrations, secrets, webhooks or customer data, map what else it reaches and state the evidence rung of each claim; not yet measured | its `paths:` globs (auth, session, secrets, policies, migrations, webhooks, payments, `.env*`, CI workflows) are meant to let Claude Code offer it; that this happens is assumed, not observed; the agent may ignore it |
| Advice | skill `ux-design-laws`, in the add-on `bendit-web`: 20 UX laws (Hick, Fitts, Jakob, Miller, Doherty and more) applied to any interface the agent builds or reviews; not yet measured | only in a project where `/bendit:adopt` installed `bendit-web` with `--scope project` (a web app); the agent may ignore it |
| Advice | a controlled vocabulary for agent prose (`scripts/controlled-vocabulary.py`, `/bendit:vocabulary`): flags inflated wording, requirements phrased as advice, and completion claims that name no observation; its `slop` category flags phrasing that reads as machine-written (puffery, promotional words, vague attribution, chatbot phrases, em dashes), adapted from the unslop list in poteto's noodle; no hook is wired; not yet measured | `/bendit:vocabulary` or `--check FILE` in your own CI; it reports and never blocks. `slop` findings never fail `--check` and `--fix` never edits them |
| Advice | the refusal log, `.claude/.bendit-state/fires.jsonl`, and `/bendit:guard-report` (see [What fires](#what-fires-the-refusal-log)) | each guard appends a line after it refuses; the report only reads |
| Advice | `/bendit:suggest-guards`: repeated corrections in this project's past sessions (and, with `--git`, its fix and revert commits), each with a proposed layer (see [Grow your own guard](#grow-your-own-guard)); not yet measured | read-only; it writes nothing unless you pick rows to build |
| Advice | commands: `/bendit:ship`, `/bendit:review-diff` (each finding sorted into Act on, Consider, Noted or Dismissed, then a lead judgment that accepts or rejects each with a reason and names every check that ran), `/bendit:verify`, `/bendit:doctor`, `/bendit:vocabulary`, `/bendit:guard-report`, `/bendit:suggest-guards` | checklists the agent runs when asked |

Every hook runs as `python3 <plugin>/scripts/<name>.py` with a 10-second timeout
(the Stop gate: 360 seconds). A blocking hook exits 2 with its reason on
stderr; Claude Code then refuses the call and shows the reason to the model. A
crash also exits 2, so a broken guard refuses rather than waves things through.
That includes a guard whose own helper module cannot load (a syntax error, a
missing file, or a helper that exits 0 on import): it refuses, naming
itself, and `/bendit:doctor` reports it as broken, not ok
(`guard-startup.test.sh`). Not covered: a helper that calls `os._exit(0)` ends
the process before any handler runs.

Plugin options: `integrationBranch` (the branch `/bendit:ship` and
`/bendit:review-diff` compare against; empty means detect) and `zshGuard` (default on).

## The Bash guard

`block-dangerous-bash.py`, always on. Its threat model, in its own words: "a
well-meaning but HASTY agent, not a malicious one".

It refuses:

- recursive deletes, with or without `-f`: `rm -rf ./build`, `rm -r dist`,
  `cd /tmp && rm -rf node_modules`, node and python one-liners
  (`fs.rmSync` recursive, `shutil.rmtree`), `rimraf`, `find -delete`. Only a
  folder inside `/tmp` or `$TMPDIR` (including macOS's `/var/folders/…/T/`)
  may be deleted;
- destructive SQL through a database client: `DROP`, `TRUNCATE`,
  `ALTER TABLE … DROP`, `DELETE` with no `WHERE`;
- `supabase db push` and `supabase db reset`; `prisma migrate reset` and
  `prisma db push --force-reset`;
- force pushes (`--force`, `-f`, `+refspec`, `--mirror`, `--delete`, `:branch`);
- `git reset --hard`, `git checkout .`, `git restore .`, `git clean -f`;
- deleting the folder the shell is in, or a parent of it;
- live secrets typed into a command: Stripe live secret and restricted keys,
  Supabase secret keys and access tokens, GitHub personal access tokens;
- approving a check (`--trust`), writing bendit's approval list, or
  pre-answering the bendit installer;
- a payload it cannot read.

It allows, among others: `git push --force-with-lease`, `git clean -n`,
`rm -rf /tmp/scratch`, `rm file`, `rmdir build`, `supabase db diff`, a Stripe
test key, `grep -r "DROP TABLE" supabase/migrations`, and commit messages or
heredoc bodies that only mention `rm -rf`.

Shell commands are read with a small lexer (`shell_text.py`), so a rule asks
about the command that would actually run: through `sudo`, `env`, `command`,
`nohup`, `time`, `xargs`, package runners, `VAR=x`, `sh -c`, `eval`,
`find -exec`, heredocs, `echo … | sh` and `trap` bodies. Quoted text is an
argument, so `git commit -m "explain rm -rf"` is allowed.

**Known gaps** (listed in the guard's header): a command behind a variable, a
script file (`bash clean.sh`), `ssh host 'rm …'`, brace expansion,
`busybox`/`parallel`/`flock`/`docker run`, `psql -f drop.sql`, symlinks,
perl and ruby one-liners, and forging bendit's own state files.

The test suite feeds it more than 360 commands and snapshots every message
([`block-dangerous-bash.expected`](../plugins/bendit/scripts/block-dangerous-bash.expected)).
An adversarial review of v0.2.0 tried 64 bypasses: 11 of the 64 were blocked
before the fixes, 49 of the 64 after.

## The Stop gate in detail

`require-verification.py`: "Refuse to end a turn that edited code without
verifying it". When the agent tries to end its turn, the gate decides, in this
order:

1. a `verified` stamp newer than the edits (written by a full passing
   `/bendit:verify`) allows the stop;
2. a skip note newer than the edits, with a one-line reason, allows the stop,
   and the reason is shown to you;
3. `.claude/verify-harness`, a shell file the gate runs from the repo root, but
   only once a person approved that exact file for that repo. Exit 0 verifies;
   anything else refuses the stop and shows the agent the output;
4. otherwise it asks the agent for a verification skill, a scaffold, or a
   recorded reason.

What counts as code: source files in most languages, SQL, shell, Prisma,
CSS and HTML, plus build files (`package.json`, lockfiles, `compose.yaml`).
Markdown, `node_modules` and build output do not count. Each session's edits
are tracked separately, so one session's edits never block another.

**Approval.** You approve a check with
`python3 <plugin>/scripts/require-verification.py --trust <repo>`, in your own
terminal: it shows the file and asks y/N, and refuses with no terminal ("No
TTY, no approval"). Any change to the file needs approval again, and approval
in one repo does not carry to another. Why: the gate runs the file
unsandboxed, and anything that can write the repo can write it. Before v0.2.0,
a cloned repo could get code run on your machine with no prompt.

The harness has a 300-second budget (`BENDIT_HARNESS_TIMEOUT`), kept below the
hook's own timeout.

**The escape hatch is visible.** The agent can record
`echo "<one-line reason>" > <repo>/.claude/.bendit-state/skipped-<session>`;
you see "verification skipped: …". A second stop in the same turn is allowed
once, and shown. Any stop that rests on evidence a file could fake is said to
you, for example `[bendit] <name>: verified by /bendit:verify at <time>`.

**Known gaps** (in the gate's header): forging its stamps, hand-writing
`verified`, deleting the marks log, writing the approval list directly or
faking a terminal. "The gate stops an agent that is hasty, not one set on lying."

**Generating a harness.** `scripts/scaffold-verification-skill.sh <repo>
[--dry-run] [--kind web|cli|library] [--dev] [--pm npm|pnpm|yarn|bun] [--name] [--force]
[--keep-harness]` always writes `.claude/verify-harness`; for a web app it adds
the `verify-<name>` skill (`doctor`, `up`, `drive`, `verify`, and
`scenarios/smoke.sh`). It never guesses: anything it could not detect becomes a
`TODO` line that fails, and the scaffold exits 3.

**`/bendit:verify` on a web app** takes this checkout's port from a registry
(`~/.config/bendit/ports.json`; each worktree gets the next free port), starts
the app, waits until it serves (a 5xx is not ready), runs every
`scenarios/*.sh`, and tears it down. A named scenario is a partial run and does
not clear the gate; zero scenarios is a failure.

## Per-project features in detail

Five pieces are optional, and each project gets only the ones that fit it.
`/bendit:adopt` detects them, asks before installing anything a feature needs,
and records the result in `.claude/bendit.json` (committed, so the team shares
it), one line per feature: on or off, and why, citing what it found
(`package.json:6 next`, `type ls in zsh: ls is a shell function`).

| feature | what it does | `/bendit:adopt` turns it on when | it needs | measured? |
|---|---|---|---|---|
| `browser-driver` | JSON browser scenarios for `/bendit:verify`, run in a real Chrome | a web app: `package.json` names `next`, `react`, `vue`, `svelte`, `@sveltejs/kit`, `nuxt`, `astro`, `vite`, `@angular/core`, `solid-js` or `@remix-run/react` as a dependency, or the root has `index.html` | Node 20+, Google Chrome (Chromium cannot be driven), and Playwright, which `/bendit:adopt` offers to install with `scripts/drive-setup.sh` | not yet measured |
| `ux-design-laws` | the `ux-design-laws` skill | a web app (the same signal) | the `bendit-web` add-on, installed with `--scope project` so it loads in this project only | not yet measured |
| `session-brief` | the session-start brief (where the repo stands) | the project is a git repository | nothing | not yet measured |
| `ls-guard` | the guard against parsing `ls` | `ls` in your shell is an alias or a function, not the real `ls` | nothing | not yet measured |
| `primary-checkout-guard` | refuses an edit in the primary checkout while it is on the integration branch, with the exact `git worktree add` command to use instead (inspired by the "Worktree First" rule in poteto's noodle) | never on its own: only when you say yes in `/bendit:adopt --detailed` (the quick path leaves it off) | a git project | not yet measured |

- **Who reads the file.** The `ls-guard`, `session-brief` and
  `primary-checkout-guard` hooks act only when their feature is on. For `browser-driver` and `ux-design-laws` the file
  records the choice; what makes them work is the dependency (a JSON scenario
  runs wherever one exists, and the skill loads wherever the add-on is
  installed).
- **Saying no is fine.** Declining a dependency turns its feature off with why
  `you declined <it>`; it never stops adoption.
- **`prove.sh` checks every feature that is on**, by running it: the browser
  driver's selftest in a real browser, the add-on installed for this project,
  the ls guard refusing `ls | wc -l`, the brief naming the checked-out branch,
  the primary-checkout guard refusing an edit on the integration branch in a
  scratch primary checkout and allowing it from a worktree.
  `/bendit:doctor` prints the table.
- **A malformed `bendit.json` is never read as "all off"**: every reader
  refuses and names the file. The one exception: the primary-checkout guard
  allows an edit to `bendit.json` itself, because that is how it is fixed.
- **The primary-checkout guard in detail.** The integration branch is
  `integrationBranch` on the feature in `.claude/bendit.json` (record it with
  `features.py integration-branch <project> <branch>`), else `origin/HEAD`;
  with neither it allows every edit and `prove.sh` fails its row, saying why.
  With the feature off, or outside a git repository, it allows without running
  git. With it on, a git that is missing or fails refuses the edit. An edit to
  a file outside the project's repository, in a linked worktree, on another
  branch or on a detached HEAD is allowed.

The browser driver runs `node drive.mjs <scenario.json> [--out] [--headed]
[--base] [--accept] [--require-baseline]`: exit 0 verified, 1 not verified, 2
could not run. `BENDIT_BROWSER_CHANNEL` picks another browser.

## Grow your own guard

The kit's guards cover common mistakes. The ones that cost *your* project are
found by using it: the second time you correct the same mistake, run

```
/bendit:new-guard no-skip-hooks
```

That scaffolds `.claude/hooks/no-skip-hooks.py` (a fail-closed `PreToolUse`
guard) and `no-skip-hooks.test.sh` (block / allow / crash cases with a message
snapshot). It never overwrites a file and never edits your settings: it prints
the `.claude/settings.json` snippet for you to add. The adopt skill's
[`references/grow.md`](../plugins/bendit/skills/adopt-bendit/references/grow.md)
walks through writing cases from the real transcript, replaying your history to
count false positives, and turning it on.

To find candidates, run `/bendit:suggest-guards` (adapted from the `ruminate`
idea in poteto's brainmaxxing). Its script, `scripts/suggest-guards.py`,
reads this project's Claude Code transcripts under `~/.claude/projects/`, and
only lines whose `cwd` is this project, so a different project that maps to
the same folder name is left out. It works in two steps, so that meaning is
read by Claude, never guessed from keywords. First it lists every reply you
typed right after an agent tool call (a stable id, the tool, the command
head, the redacted text cut to 160 characters; newest sessions first, at
most 200). Claude reads every row and picks the ids that correct the agent,
saying how many it read, confirmed and dropped. Then `--confirm <ids>`
clusters only those ids, by the tool call before them and shared words
(labels are whole words), and shows every example, with secrets redacted
before anything
else happens. A correction seen once is left out (`--min 2`). The command then
proposes the cheapest layer for each cluster (delete, structure, guard or
prose, from [the ladder](#the-ladder)), asks once which rows to build, and
runs `/bendit:new-guard` only for the guard rows you pick, one PR per row.

`--git` adds this repo's own history (adapted from the `correct` skill in
poteto's pstack): one read-only `git log` of the last 2,000 commits. A commit
is a candidate when its subject starts with fix or revert, or when it touches
a file again within an hour of the last commit to it. Candidates group by
file (files fixed by nearly the same commits, Jaccard 0.6 or more, are one
row), marked `source: git`, with one redacted subject as the example. Git
rows rank by 3 per revert, 2 per fix and 1 per follow-up, scaled by how much
of the file's history is fixes; docs-only rows come last, session rows always
come first, and text mode prints the top 8 git rows (`--json` has all). Only
commits under the project folder count (`git log -- .`). The script writes
nothing. What it prints, already redacted, is read by the agent like any other
command output.

## What fires: the refusal log

Each blocking `PreToolUse` guard (block-dangerous-bash, block-zsh-wordsplit,
block-ls-parsing, path-contracts, block-primary-checkout) appends one JSON
line to `.claude/.bendit-state/fires.jsonl` in the project every time it
refuses. The `--pre` hooks of require-verification and post-edit-review never
refuse, so they log nothing:

```json
{"ts": "2026-11-21T10:00:00Z", "guard": "block-dangerous-bash", "rule": "rm-recursive", "preview": "rm -rf ./build"}
```

- **Best-effort, after the decision.** A guard writes the line only once its
  exit code and message are final, and any failure to write is swallowed
  (with a 1.5-second limit), so the log can never change what a guard decides.
- **The preview is redacted first, then cut to 120 characters.** Private
  keys, the live keys the Bash guard refuses and bare token shapes (GitLab,
  Slack, AWS key ids, JWTs) become `[REDACTED]`. The values of URL passwords,
  `PASSWORD=` style assignments, `-p`/`-a`/`-u user:` passwords, Bearer and
  Basic credentials and long random-looking strings become `***`. If the
  redaction patterns cannot be read, the preview is left out.
- **Git never sees it.** The state folder gets a `.gitignore` of `*` when it
  has none, so the log cannot be committed in a project `/bendit:adopt` never
  set up.
- **Nothing is created where there was nothing.** A folder with no `.claude/`
  gets none, and outside a git repository nothing is logged.

`/bendit:guard-report` runs `scripts/guard-report.py --days 30`: a table of
guard, rule and count for the window, then every rule that never fired in
it. The list of rules is read from each guard's source, without running it.
Exit 2 means the log exists but cannot be read, and the report says fires
are unknown, never zero. The command suggests what is worth a look (rules
that never fire, rules you often override) and never removes, turns off or
edits a guard: that stays your call, through `/bendit:adopt --detailed`.

## The ladder

For every recurring failure, use the cheapest layer that holds it:

| layer | what | example |
|---|---|---|
| L0 | delete the thing | remove a dead config file instead of documenting it |
| L1 | structure / types / one definition | one shared helper instead of nine copies |
| L2 | deterministic enforcement | a blocking hook, a CI gate, a lint rule |
| L3 | prose | a skill or `AGENTS.md` line, only for judgement a machine cannot make |

A check that can pass for the wrong reason is worse than no check, so every gate
here **fails closed** (a crash refuses) and refuses to report success having
checked nothing. The full method and twelve generic failure classes, each with
the layer that holds it, are in [ladder.md](ladder.md).

## Measuring whether a rule works

[plugins/bendit/evals/README.md](../plugins/bendit/evals/README.md)
is the method: run a task that tempts the mistake many times with and without
the rule, and believe the difference only if it survives the listed traps.

- Sweep cases by `--tag`, never untagged: `_falsify/` holds cases built to
  FAIL and is discovered like any other case. To write a new case, copy
  `plugins/bendit/templates/eval-case/` into `evals/` and edit it.
- Always pass `--no-publish`; otherwise the HTML report is published to
  claude.ai by default where your account supports it.
- Grant the tools under test with `--allow-tools`. Without the grant, every case
  that needs to edit or run something can score perfectly while measuring
  nothing.

```bash
claude plugin eval ./plugins/bendit --tag smoke --scaffold --allow-tools Bash --no-publish
```

Run the smoke case first: if it fails with the plugin loaded, the harness is
wrong (grant, scaffold, plugin path) and no other number is worth reading.

These flags come from CLI 2.1.326, the version of the first sweep
([INDEX.md](../plugins/bendit/evals/results/INDEX.md)); check your CLI's own help.

## More on the evidence

All numbers: [`evals/results/INDEX.md`](../plugins/bendit/evals/results/INDEX.md).
The v0.2.0 sweep froze its inputs in
`plugins/bendit/evals/freezes/v2-final.json` (inputs at commit `a5d6be0`;
total cost $34.71). The guard and the Stop gate changed after the sweep, so
`eval-freeze.py verify v2-final` on a later tree lists them as CHANGED:
reproduce at `a5d6be0`. Raw run folders are not committed.

- **The v0.2.0 sweep** ran on 2026-11-19.
- **The same guard on v0.1.0** (2026-11-17): 12/12 and 12/12 against 0/12.
- **Liveness.** In the guard cases, the agent attempted the deletion in 12 of
  12 runs in every arm, so no arm is a run that measured nothing.
- **The one deletion that got through** used `rm -r -- ./dist`: recursive,
  without `-f`. The guard then allowed that on purpose so routine cleanups kept
  working; the sweep measured the cost (1 agent in 12 chose it unprompted), and
  since `-f` changes almost nothing in an agent's shell, recursive deletes are
  now refused with or without it. Deleting a scratch folder inside a temp
  location stays allowed.
- **Skills.** `checks-that-can-lie` is the first skill with a measured effect:
  a 30-runs-per-arm test, decisive at p = 2.3e-13. Its judged criterion ("made
  the check fail once") went the other way (21/30 vs 28/30), but the
  deterministic grader that sees the same fact in the full trace passed 30/30
  in both arms; the LLM judge sees only the first and last 12 trace events, and
  the kit's hook messages push that evidence into the part it cannot see. The
  other skills showed no difference in 3-runs-per-arm pressure tests, which are
  a direction check, not a measurement: the model already did the right thing
  without them. Four of them were therefore folded into one,
  `engineering-habits`, to cut the per-session listing cost.
- **Cost of the kit.** In the earlier v0.1.0 skill sweep, 6 of 18 with-kit runs
  ran out of turns (0 of 18 without): the Stop gate in a project with no
  harness yet, and the guard refusing a scratch-folder cleanup. After two fixes
  it was 0 of 6 on the two worst cases (a small sample), and 2 of 18 in the
  v0.2.0 sweep. `/bendit:adopt` writes a harness, which removes the first of
  those causes; whether that removes the cost has not been measured.
- **Falsification twins.** Judges built to fail did fail (0/3 each, three valid
  twins; one twin was invalid), and the must-pass twin passed 2/3.
- **The author's earlier evaluation.** In the author's own evaluation, done
  privately before this repo existed and **not reproducible from it** (no data
  here backs it), the same instruction was tested two ways: as guidance (a
  skill), it changed behaviour in roughly one run in five, and even that figure
  was confounded by measuring the agent's narration rather than its work; as a
  hook that refuses the action, it held 12 times out of 12. Treat it as the
  motivation, not as evidence.

## Platform support

- macOS and Linux; bash 3.2+ or zsh. The installer refuses Windows ("Windows
  is not supported yet.").
- Python 3.9+ (standard library only) for every hook.
- Network: the hooks make no network calls of their own, with one exception:
  the session brief's DNS/TCP liveness probes of the hosts and ports your
  project's `brief` config lists. With nothing listed (the default) there are
  none. The installer fetches bendit from GitHub; your approved verify harness
  does whatever its commands do.
- Any language project; `/bendit:adopt` detects Node, Python, Go and Rust and
  asks about anything else.
- The browser driver (web apps only) needs Node 20+ and Google Chrome.
- Claude Code only.

## Not included

Multi-session orchestration and database-policy helpers. They exist in the
private kit bendit was extracted from but are unproven or stack-specific; each
may ship later, only with a measured result. No GUI, and no support for agents
other than Claude Code.

In v0.2.0 this list also included session-start project briefs and a browser
driver; both now ship as per-project features (not yet measured).

## Where bendit keeps state

Per-user state never lives in the plugin folder.

| Where | What |
|---|---|
| `.claude/.bendit-state/` in your project | which files changed, verified stamps, skip notes, the refusal log `fires.jsonl` (git-ignored) |
| `~/.cache/bendit/v<version>/` | the copy the installer fetched |
| `~/.cache/bendit/drive/<version>/` | Playwright, if you accepted it |
| `~/.cache/bendit/verify-sessions/`, `live-sessions/` | per-session index, and markers that let `/bendit:doctor` say whether bendit is live in this window (live markers removed after 30 days; stale verify entries after 7) |
| `~/.config/bendit/trusted-harnesses.json` | your check approvals |
| `~/.config/bendit/ports.json` | each web project's port |
| `.git/bendit-ports.json` in your project | which port each worktree holds |

Paths follow `XDG_CACHE_HOME` and `XDG_CONFIG_HOME`; other overrides:
`BENDIT_CACHE`, `BENDIT_CONFIG_DIR`, `BENDIT_VERIFY_INDEX`, `BENDIT_LIVE_DIR`,
`BENDIT_HARNESS_TIMEOUT`, `BENDIT_KIT_ROOT`, `BENDIT_BROWSER_CHANNEL`,
`BENDIT_VOCAB`; for CI, `BENDIT_CI_JOBS` and `BENDIT_CI_SUITE_TIMEOUT`.

## Repository layout

```
.claude-plugin/marketplace.json
docs/ladder.md                      the method and failure classes F1-F12
docs/design.md                      design decisions for v1
docs/reference.md                   this page
install.sh                          the one-command installer
INSTALL.md                          the same install as a runbook for the agent
packages/                           npx and pipx wrappers around install.sh, plus the Homebrew formula template
plugins/bendit/
  hooks/hooks.json                  which guard runs on which tool
  scripts/                          guards, gates, test suites (*.test.sh)
  skills/                           adopt-bendit, checks-that-can-lie, engineering-habits,
                                    encode-lessons-in-structure, blast-radius,
                                    create-verification-skill
  commands/                         /bendit:adopt /bendit:new-guard /bendit:ship /bendit:review-diff /bendit:verify
                                    /bendit:doctor /bendit:vocabulary /bendit:guard-report /bendit:suggest-guards
  lib/drive/                        the real-browser driver (drive.mjs) and its selftest
  templates/                        guard, AGENTS.md skeleton, verify-harness, eval case
  evals/                            measuring whether a rule changes behaviour
plugins/bendit-web/                 add-on for web apps: the ux-design-laws skill
```

Every behaviour has a shell test suite (`scripts/*.test.sh`) using snapshot
tests of what the hooks actually say; `.github/workflows/ci.sh` runs them all
(stages `shell`, `imports`, `privacy`, `validate`) and fails if any stage ran
nothing. CI runs it on Ubuntu and macOS.

The `validate` stage runs `claude plugin validate`, then
`scripts/plugin-lint.py <plugin dir>` on every plugin, for what validate
lets through: every `${CLAUDE_PLUGIN_ROOT}/...` path in `hooks/hooks.json`
must be an existing file in the plugin (executable when the command runs it
directly), and every skill and command `description` must be non-empty and at
most 300 characters. A hook whose script is missing would otherwise be a
guard that is silently off.
