# Quick adopt: one plain question

The default for `/bendit:adopt`. The person who runs it may not be an
engineer: they get **one** question, a summary of everything that will happen
in everyday words, ending "Go ahead? Reply yes, or just press Enter." Every
answer the `--detailed` interview asks for is decided here by detection plus a
safe default. `KIT` is as in SKILL.md; `ROOT` is the project folder (§1).

Rules for the whole path:

- **One question.** The only other questions allowed are the two in §3, each
  asked before the summary, in plain words, with a default. Never ask about
  the project folder, guards, generated files, invariants, branches, CI, the
  install route or which package list to use.
- **Nothing outside the summary.** Every file written and every command that
  installs something is listed in the summary first, in everyday words (the
  `.git/info/exclude` lines are the "private list" in the `.gitignore` row, and
  the port note is "remember it on this computer"; the report's record section
  names the exact paths). If a step turns out to
  need something the summary did not list, stop and say so; do not add it.
- **No per-step shows.** The detailed flow's "show, then write" is replaced by
  the summary. Instead, the final report lists every file written and every
  command run.
- **Failures stay named.** Plain words never hide a failure: say what failed,
  show its output, and give the fix. Stop at the first failure (§5).
- Never edit user-level settings (`~/.claude/…`), never commit, never push.
  Never overwrite an existing `AGENTS.md`, `CLAUDE.md`, `.claude/verify-harness`,
  hook or workflow. (A harness `--harness-owner` calls `own` is bendit's
  unfinished one, not the person's: §5 step 6 replaces it.)
- **Every command runs from ROOT**: start each Bash call with `cd "$ROOT" &&`.

## 0. Already adopted?

Only `.claude/bendit.json` means bendit is already set up here (§5 writes it
after every other file, so a run that stopped early never leaves it). Then write and
install nothing, and print:

> bendit is already set up here. To check it still works, run `/bendit:doctor`.
> If the last setup said "bendit is NOT fully set up", run `/bendit:doctor`
> now: it shows what is still open and how to fix it.
> To change anything (the test check, or which parts are on), run
> `/bendit:adopt --detailed`.

If `.claude/verify-harness` is missing, add one plain line: "There is no test
check yet; `/bendit:adopt --detailed` can add one."

**Set up by an older bendit.** No `.claude/bendit.json`, but bendit is
already installed for this project (`claude plugin list --json` from ROOT,
§1) and `AGENTS.md` has bendit's section (a line starting `- bendit guards:`):
a bendit older than 0.3.0 set this project up, and its files may hold the
person's own changes. Write and install nothing, and print:

> An older version of bendit set up this project. Its files may have your own
> changes in them, so I won't touch them here. To bring it up to date, run
> `/bendit:adopt --detailed`: it shows you each change before making it.

Anything else bendit-like without `.claude/bendit.json` (the plugin already
installed for this project, a `.claude/verify-harness`, a vendored copy) is an
earlier run that did not finish, or a harness someone wrote: carry on with the
quick path. Steps already done are skipped and the summary says "already
installed" or "(kept)" for them. Such a run is a **retry**.

## 1. Detect, then decide (internal, never shown as a table)

**The project folder.** `git rev-parse --show-toplevel` is ROOT. Stop, with
"Run this from inside your project's folder.", when ROOT is `$HOME` or `/`.
Not a git repository: stop the same way when the current folder is `$HOME`,
`/`, or has no project files (none of `package.json`, `pyproject.toml`,
`setup.py`, `requirements*.txt`, `go.mod`, `Cargo.toml`, `Makefile`,
`Gemfile`, `pom.xml`, `build.gradle*`, `*.csproj`, `composer.json`, `mix.exs`,
`Package.swift`, `pubspec.yaml`, `index.html`, `src/`); otherwise ROOT is the
current folder and the summary lists `git init`.

Run detection exactly as `detect.md` §1, §2, §3, §4, §6 and §8 describe
(read-only), plus:

```bash
cd "$ROOT" && test -d node_modules && echo node_modules   # Node: packages installed?
cd "$ROOT" && bash "$KIT/scripts/scaffold-verification-skill.sh" "$ROOT" --harness-owner <step 6's options>   # absent | own | kept
"$KIT/scripts/install-route.sh" route https://github.com/VedangP57/bendit
"$KIT/scripts/install-route.sh" conflict <the source the route will add>   # see below
claude plugin list --json                                 # from ROOT: SKILL.md 3b's rule
```

The `conflict` source is the URL for `github`, or `"$ROOT/.claude/vendor/bendit"`
for `vendor`. `--harness-owner` writes nothing; give it exactly the
`--pm`/`--kind`/`--dev` that §5 step 6 will pass, because `own` means "byte for
byte what the scaffold would write now". Not a git repository yet: skip it; an
existing `.claude/verify-harness` there counts as `kept`. Then fill this table
in your head; the summary is built from it.

| answer | rule (first match wins) |
|---|---|
| package manager | Node: `packageManager` field, else the one lockfile. Two or more lockfiles and no `packageManager`: the one git changed most recently (`git log -1 --format=%ct -- <file>`; untracked counts as newest), decided silently and stated in the summary. Python: `uv.lock` uv, `poetry.lock` poetry, else plain `python3`. |
| test | detect.md §2. A Node `scripts.test` that only prints "no test specified" and exits 1 is **no test**. Python: pytest only when detect.md §2's pytest signals are present; else `<python> -m unittest` (the reused environment's python, else `python3`) only when a `test*.py` file exists. |
| typecheck | detect.md §2. |
| build | detect.md §2 (only used when there is no test and no typecheck). |
| the check (`.claude/verify-harness`) | `--harness-owner` printed `kept`: keep it, unchanged ("your existing test check (kept)"). That includes a harness an older bendit generated that someone has since edited or committed, and any harness git tracks, even one with a `TODO(bendit):` line: the generated header alone never makes it bendit's. `own` (untracked, and either a `TODO(bendit):` line or exactly the scaffold's output, as an earlier run that stopped leaves it) or `absent`: typecheck `&&` test when both exist; else test; else typecheck; else build. None of the four: §3 question A. Lint is never in it. The app is never in it (the web verify skill is still generated, for use on request). |
| command form | Node: `<pm> run <script>` (so `bun run test`, never `bun test`, which is bun's own runner). Python: uv `uv run <tool>`, poetry `poetry run <tool>`, a Python environment (below) `<env>/bin/python -m <tool>`, else `python3 -m <tool>`. A task-runner target (`make test`) wins, as detect.md §2 says. |
| Python environment | Reuse, in order: `$VIRTUAL_ENV`, then `.venv/`, `venv/`, `env/` in ROOT (each with `bin/python`). |
| project packages | Only what the check needs, from the lockfile, never changing it. Node, `node_modules/` missing, or a retry (§0; an install that failed can leave a half-filled `node_modules/`): bun `bun install --frozen-lockfile`, pnpm `pnpm install --frozen-lockfile`, npm `npm ci`, yarn `yarn install --immutable` (Yarn 2+) or `yarn install --frozen-lockfile` (Yarn 1). uv `uv sync --locked`; poetry `poetry install`. Plain Python, and only when the check uses pytest and `<python> -m pytest --version` fails: install into the reused environment, else a new `.venv/` (`python3 -m venv .venv`). In either, first `<python> -m pip install -U pip` (the pip a Python 3.9 environment starts with, 21.2, cannot install a project that has only a `pyproject.toml`; listed in the summary), then `<python> -m pip install -e . pytest` when there is a `pyproject.toml` or `setup.py` (this also writes `<name>.egg-info/` in the project when setuptools builds it: list it), else `<python> -m pip install -r <each requirements*.txt> pytest`. A new `.venv/` is added to `.gitignore` unless `git check-ignore -q .venv` already ignores it. Packages already present: nothing. Node with no lockfile: nothing (an install would create one); the report says the check needs `<pm> install` first. |
| package manager missing | `command -v <pm>` fails: macOS with Homebrew `brew install <pm>` (`pnpm`, `yarn`, `bun`, `uv` and `poetry` are all Homebrew formulas; never `corepack enable`, because Homebrew's Node does not include corepack), only if not already installed. It runs in §5 step 5, before the packages, and a failure stops there. No Homebrew: say it is missing and that the test check cannot run until it is installed (adoption will be NOT COMPLETE). |
| integration branch | `origin/HEAD`; unset: `main` if it exists (remote or local), else the current branch. |
| production branches | none, unless a deploy config or a CI deploy job names a branch explicitly (detect.md §4). |
| guards | all on. The zsh guard is active when `$SHELL` is zsh. Protected paths: none. |
| invariants | none. |
| CI | **not added**, whatever detection found. The report says how to add it. |
| features | detect.md §8, unchanged. |
| web add-on | `ux-design-laws` on and the add-on not already installed for ROOT (SKILL.md step 3b's rule): install it. |
| feature dependencies | `browser-driver` on: Node 20+ missing → `brew install node` (macOS with Homebrew); Chrome missing → `brew install --cask google-chrome`; `drive-setup.sh --check` exits 1 → `bash "$KIT/scripts/drive-setup.sh"`. Each only if not already installed. No Homebrew for a missing Node or Chrome: the feature is off with why `Node not found` / `Chrome not found (Chromium cannot be driven)`, and the summary says so. |
| install route | Already installed for this project at project scope: nothing. `install-route.sh route` prints `github` → bendit from GitHub (anyone else who downloads this project gets it too). `vendor` → a copy inside the project, stated as "works on this computer only". |
| marketplace conflict | `conflict` exit 0 and silent: nothing. Exit 0 with `switch: <sentence>`: proceed, and put the sentence in the summary and report. Non-zero: §3 question B. |
| existing AGENTS.md / CLAUDE.md | Absent: create (`AGENTS.md` from `KIT/templates/AGENTS.md`, placeholders with no answer deleted with their line; `CLAUDE.md` the single line `@AGENTS.md`). Present: add only what is missing (project-layer.md §1), never rewrite. |
| dead configuration (detect.md §6) | Not changed. Listed in the report as found. |

## 2. The one question

Build it from the table. Only include lines that apply; give each "lines
added" count as it will really be. Template:

```
Here is what I'll set up in <project name> (<ROOT>):

What you get
  • A safety check that stops risky commands, like deleting folders or overwriting work saved on GitHub.
  • A check that runs your tests before the AI says it's done: <the check> | your existing test check (kept)
  • Browser testing for your web app: the AI can open it in Chrome and click through it.   (web apps)
  • Design advice for screens and layouts while the AI works on your web app.               (web apps)
  • A short note about the project each time you open Claude in this project.
  • <ls-guard on:> A file-list check, so the AI doesn't misread lists of files.

Files I'll add or change in your project
  AGENTS.md                     the project's rules for AI assistants (new | a bendit section added)
  CLAUDE.md                     one line telling Claude to read AGENTS.md (new | one line added)
  .claude/settings.json         turns bendit on for this project
  .claude/vendor/bendit/        the copy of bendit                         (copy route)
  .claude/verify-harness        the test check above                       (new only)
  .claude/bendit.json           which parts are on, and why
  .claude/skills/verify-<name>/ and .env.verify.example   browser testing  (web apps, also when the test check is kept)
  .gitignore                    keeps bendit's working notes out of your project's saved history (<n> lines added;
                                a few more go in a private list only this computer reads)
  .venv/                        a private folder for your project's Python packages (only when §1 creates it)
  <name>.egg-info/              a small folder Python's installer writes   (only when §1's install makes it)

What I'll do on this computer
  • Start tracking changes in this folder (git init); nothing is saved yet.        (not a git project)
  • Install bendit for this project only, from GitHub, so anyone else who downloads this project gets it too.
    | Install bendit as a copy inside this project. This works on this computer only;
      anyone else who downloads this project won't get it until they install bendit themselves.
  • <the switch sentence, verbatim: "Your other project, <name>, uses its own copy of bendit. bendit on
    this computer will now point at the public version on GitHub; <name> may switch back to its own copy
    the next time you open Claude there. Nothing in <name>'s files changes.">
  • The design-advice part (bendit's web add-on).                          (web apps)
  • Pick a web address number for your app that none of your other projects use, and remember it
    on this computer.                                                       (web apps, unless already noted)
  • A helper (Playwright) that lets the AI use Chrome, stored in bendit's own folder, not in your project.   (only if not already installed)
  • Install <tool>, which your project uses for <purpose> (with Homebrew).   (only if not already installed;
    e.g. "Install Google Chrome, which browser testing uses to open your app (with Homebrew).")
  • Update Python's package installer (pip) in <env>, so it can install your project.   (only when §1 does)
  • Your project's packages, so the tests can run: <bun install --frozen-lockfile>
  <two package lists: "Your project has package lists for both <npm> and <pnpm>; I'll use <pnpm>, the one changed most recently.">

Not included (add later with /bendit:adopt --detailed): automatic checks on GitHub each time someone proposes a change.
<a feature that is off, e.g. "Browser testing is off: Chrome isn't installed and Homebrew isn't available.">

Nothing is saved to your project's history or uploaded.
Claude may ask permission to change a few files in the .claude folder. Say yes.

Go ahead? Reply yes, or just press Enter.
```

**Replies.** "yes", "y", "yep", "yeah", "sure", "ok", "okay", "go ahead",
"do it" or an empty reply is a yes.
An explicit "no" (or "stop", "cancel") is §4. Anything else, such as a
question, is answered in plain words, and then the summary is shown again with
the same closing line; it is neither a yes nor a no.

## 3. The only extra questions

Ask one only when its condition holds; each comes before the summary, one per
message, and its answer is folded into the summary. A question back is
answered, then the same question is asked again.

**A. No way to check the project works** (no test, typecheck or build command,
no task-runner target, and no existing `.claude/verify-harness`):

> I couldn't find a way to check that this project still works. If you know
> the command your project uses to test itself, type it; otherwise reply skip.

On "skip", no `.claude/verify-harness` is written and no verify scaffold runs
(so a web app gets no browser testing yet either, and the summary leaves those
lines out), the summary says "No test check: none was found, and you chose to skip it",
and the report is NOT COMPLETE for that one reason, with the fix
(`/bendit:adopt --detailed`).

**B. Another copy of bendit is set up on this computer** (`conflict` exited
non-zero): show the sentence it printed, verbatim, then "[no]". It reads:

> bendit is already set up in another project on this computer (<name>) from
> a different copy. Setting it up here makes <name> use this one too. Go ahead? [no]

"yes" means proceed: the summary and report name the other project.
"no", or an empty reply, is the §4 path.

## 4. A "no"

An explicit no to "Go ahead?", or the default/no to question B: write
nothing, install nothing, run nothing more, and print exactly one line:

> Nothing changed.

## 5. Do it, in this order, with no further questions

Each step runs only if the summary listed it, from ROOT. Read every command's
output. On a failure, stop: do not run later steps, and go straight to the
report (§6) with NOT COMPLETE, the failing command, its output, and the fix.

1. `git init` (not a repository only).
2. **Install bendit.** `github`: `claude plugin marketplace add
   https://github.com/VedangP57/bendit --scope project` then `claude plugin
   install bendit@bendit --scope project`. It may print that bendit's 2
   options (`userConfig`) are not yet set. That is expected: unset, they mean
   their defaults (the zsh check on; the main branch found from the project).
   Do not pass `--config` or run `claude plugin configure`: both save the values
   in `~/.claude/settings.json`, which quick never edits. Say it once, right
   after the install, in one plain line: "Claude says 2 bendit settings aren't
   set yet. That's fine: bendit uses its standard settings. Nothing to do." `vendor`: install.md Route B steps
   1–5 (clone into a `mktemp -d`, copy, register, install, `VENDORED_FROM`),
   then remove the temporary clone (`rm -r <that mktemp dir>`).
3. **Web add-on.** `claude plugin install bendit-web@bendit --scope project`.
   If it fails, `ux-design-laws` is off with why `bendit-web install failed`;
   say so in the report and carry on (it is advice, not a guard).
4. **Feature dependencies.** The listed `brew install …` for browser testing
   (Node, Chrome), then `bash "$KIT/scripts/drive-setup.sh"`. A failure turns
   that feature off with its why (`Playwright install failed`); say so and
   carry on.
5. **Project packages.** First the package manager, when §1 listed it
   (`brew install pnpm`), then `<python> -m pip install -U pip` when listed,
   then the listed install command (e.g. `bun install --frozen-lockfile`).
   Any of them failing: stop (the test check cannot run without them).
6. **The test check.** `bash "$KIT/scripts/scaffold-verification-skill.sh"
   "$ROOT" --keep-harness`, with `--pm <pm>` for a Node project only (it
   accepts npm, pnpm, yarn or bun, and refuses anything else, so never pass it
   for Python), and `--kind`/`--dev` when detection settled them: the same
   options the §1 `--harness-owner` call got. `--keep-harness` leaves a
   `.claude/verify-harness` and a whole `.claude/skills/verify-<name>/` exactly
   as they are, and generates only what is missing (a `verify-<name>/` with no
   `bin/verify-<name>` is completed, its existing files kept), so a retry
   after a late failure resumes instead of being refused. Skip this step when
   question A was skipped. Then, **only if §1's `--harness-owner` printed
   `own` or `absent`**, in one Bash call, rewrite `.claude/verify-harness` to
   the decided check: its comment header, `set -e`, and the one command line.
   A `kept` harness is never touched. The scaffold also writes
   `.git/info/exclude` lines and, for a web app, `.claude/skills/verify-<name>/`
   and `.env.verify.example`.
   Exit 0 is done. Exit 3 means it left TODOs, and is expected, not a failure,
   in exactly these cases: (a) the harness is rewritten next (`own` or
   `absent`), because the rewrite replaces every TODO line in it (a project
   with only a build script gets "no test command found" here); (b) the
   harness is `kept` and the project is not a web app, because then the
   scaffold wrote no file its TODOs are in; (c) the harness is `kept` and
   every TODO is "no command to serve this web app was detected", because
   browser testing is for on-request use. Name any TODO left in
   `.claude/skills/verify-<name>/` in the report. Any other exit 3, and every
   exit 2, is a failure: stop.
7. **Project files.** `AGENTS.md` (integration branch, production branches
   `none`, the commands, the check, no invariants), `CLAUDE.md`, and
   `.gitignore` (`.claude/.bendit-state/`, plus `!.env.verify.example` if the
   scaffold warned it is ignored, plus `.venv/` when §1 created one).
8. **Features, last of all the writes.** One Bash call of
   `python3 "$KIT/scripts/features.py" set …` lines and `show`, as SKILL.md
   step 3b, with the real state and why. `.claude/bendit.json` is written
   last on purpose: §0 treats it as "set up", so it exists only once every
   earlier step finished. prove.sh (next) reads it for its feature rows.
9. **Prove it.** `bash "$KIT/scripts/prove.sh" "$ROOT"`, then
   `python3 "$KIT/scripts/selfcheck.py" --session` (is bendit running in this
   Claude window? `window: live`, `not live` or `unknown`). Only when it says
   `live` or `unknown`, run the live force-push check, exactly as prove.md
   says; `not live` means the live check waits until Claude is reopened.
   prove.sh's "approved by you" row fails until the person does last step 1
   in §6, and the live check may wait for a reopened Claude: those two alone
   are expected, and are reported as the last steps, not as a pass. This
   window counts as already protected only when the live check was refused by
   bendit; then last step 2 is left out.

## 6. The report

Plain words first, the evidence after. The header is the first that applies:

- a FAIL other than the two expected rows, or question A skipped:
  `bendit is NOT fully set up: <what failed, plainly>. To fix it: <the fix>.`
- only the expected rows open: `bendit is almost set up: two last steps.`
  (or `one last step.`). The last steps block shows, with only the steps still
  open.
- everything passed (the harness already approved, and the live check refused
  by bendit in this window): `bendit is set up in <project>.` The last steps
  block is left out, and the report ends with "Nothing else to do."

**What is on screen last.** The report is long, and the person reads its end.
The full report comes first; the LAST lines are only what the person must do
next, with nothing after them:

- both steps open: the "Two last steps:" block, exactly as in the template.
- only step 2 (the check was already approved, as on a re-run):
  `One last step:` then, on the next line, `  Close Claude and open it again in
  this project. Then type /bendit:doctor.`
- only step 1 (this window is already protected): `One last step:` then the
  step 1 lines, unnumbered.
- NOT COMPLETE: the last line repeats `To fix it: <the fix>.`

Template:

```
<header>

What you got
  • Safety check for risky commands: on. Tested: <n> of <n> checks passed.
  • Test check before "done": <the check>. Ran it: <passed in Ns | failed: …>.
  • Browser testing / design advice / project note / file-list check: on or off, with why.
  <the switch sentence, if any>

How to use it
  /bendit:verify       run the full check now (for a web app: start it and click through it)
  /bendit:ship         check everything, then send your changes to GitHub for review after you say yes
  /bendit:review-diff  review your changes before you send them
  /bendit:doctor       check bendit is still working
  /bendit:new-guard    the second time you correct the AI on the same mistake, make it a rule it can't break
  /bendit:vocabulary   keep one word for one meaning across the project

How to change it
  Edit .claude/verify-harness to change the test check (you will be asked to approve it again).
  /bendit:adopt --detailed to add automatic checks on GitHub each time someone proposes a change, or to turn parts on or off.

How to undo all of it (paste into a Terminal window)
  cd "<ROOT>"
  claude plugin uninstall bendit-web@bendit --scope project      (if installed)
  claude plugin uninstall bendit@bendit --scope project
  claude plugin marketplace remove bendit --scope project
  rm <every file this run created, by exact path>
  rm -r <every folder this run created, by exact path: .claude/skills/verify-<name>, .claude/vendor/bendit, .venv, <name>.egg-info>
  rm -r .claude/.bendit-state      (bendit's working notes; only if it was not there before this run)
  rmdir .claude/skills .claude/vendor .claude     (only the ones this run created; rmdir refuses a folder that still has anything else in it, so nothing else is lost)
  python3 -I -c 'import sys
  for a in sys.argv[1:]:
      f, line = a.split(":", 1)
      s = open(f).read().split("\n")
      if line in s:
          i = s.index(line)
          del s[i:i + (2 if f == "CLAUDE.md" and i + 2 < len(s) and s[i + 1] == "" else 1)]
          open(f, "w").write("\n".join(s))' 'CLAUDE.md:@AGENTS.md' '.gitignore:.claude/.bendit-state/'
  <AGENTS.md, when this run added bendit's section to an existing one: the exact lines to delete from it>
  rm -rf .git      (only if this run started tracking the folder; this also deletes anything saved to the project's history since)
  rm -r "<cache dir>/drive"                                      (only if this run installed Playwright)
  Left installed, because other apps may use them: <each install this run did, with its undo:
  brew uninstall <tool> / brew uninstall --cask google-chrome>.
  <pip updated in a reused environment: "pip in <env> was updated; it is left updated.">
  <reused Python environment: "pytest and your project (pip install -e .) were added to <env>;
  to remove them: <env>/bin/python -m pip uninstall -y pytest <project name>">
  Left behind, harmless: the web address number this project's app uses, and your test-check
  approval, both in ~/.config/bendit.
  Your project's packages (node_modules, …) came from your project's own package list and are left as they are.

What I did (for the record; no action needed)
  Files written: <every path, new or changed>
  Commands run:  <every command, in order, with its exit status>
  prove.sh:      <its table, as printed>
  Live check:    <PASS / FAIL / inconclusive / waits until you reopen Claude>
  Also noted:    <.git/info/exclude: the lines added; the port, in ~/.config/bendit/ports.json (web apps)>
  Found, not changed: <dead configuration, other tools' privacy notices>

Two last steps:
  1. Open a new Terminal window (not this chat), paste this, and type y:
       <the exact --trust command prove.sh printed, e.g. python3 "<KIT>/scripts/require-verification.py" --trust "<ROOT>">
  2. Close Claude and open it again in this project. Then type /bendit:doctor.
```

The undo list names real paths from this run, never a placeholder, and
leaves out lines that do not apply. The `python3 -I -c` command removes
lines this run added, by their exact text (from `CLAUDE.md`, the `@AGENTS.md`
line and the blank line after it); it runs the same on macOS and Linux. Give
it one `'<file>:<line>'` argument per line this run added to `CLAUDE.md`,
`.gitignore` or `.git/info/exclude` (so also `'.gitignore:.venv/'` and
`'.gitignore:!.env.verify.example'` when this run added them), and leave out a
file this run created: `rm` removes that one. `claude plugin marketplace remove bendit
--scope project` also removes bendit from the computer's list of plugin
sources (`~/.claude/plugins/known_marketplaces.json`; seen 2026-11-20 with
one project). Another project that still names bendit in its own
`.claude/settings.json` keeps that declaration; whether Claude Code re-adds
the source for it on its next start was not checked, so say: "If another
project on this computer uses bendit and stops finding it, run
`/bendit:doctor` there."
"Two last steps" step 1 appears only when a `.claude/verify-harness` exists
and prove.sh says it is not approved; you must never run `--trust` yourself
(the Bash guard refuses it, by design).
