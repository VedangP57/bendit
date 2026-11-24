# Install bendit: a runbook for Claude Code

This file is for the AI agent in Claude Code. A person pasted a line like
"Install bendit in this project by following <this file's URL>". Follow the
steps below in order.

## How to follow this runbook

- Work in the person's project folder: the folder Claude Code was opened in.
  Run every command from there and read its full output. If that folder is
  the person's home folder or `/`, stop and ask them to open Claude Code in
  the project instead: bendit is set up per project.
- Each step has a **Skip if:** check. Run it before doing anything else in
  the step. If it exits 0, the step is already done: say so in one line and go
  to the next step. Any other result, an error included, means do the step.
  So a run that stopped half way can start again from step 1 and pick up
  where it left off.
- If a step fails, stop. Show the person the command, its output and what you
  think went wrong. Do not try a different way of doing the step.
- Some steps are the person's alone. Never answer a question meant for them,
  and never run the approval command yourself.
- Never edit files under `~/.claude` yourself (the `claude plugin` commands
  below update Claude Code's own records there), never commit and never push.

## 1. Check the tools

bendit needs `claude`, `git` and `python3` 3.9 or newer, on macOS or Linux.

**Skip if:**

```bash
command -v claude && command -v git && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
```

Otherwise, find out what is missing. This installs nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/v0.5.3/install.sh | bash -s -- --check
```

Tell the person what it printed, then stop. Do not install the tools yourself.
The person can run the installer in their own terminal, where it asks before
each install:

```bash
curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/v0.5.3/install.sh | bash
```

## 2. Show the plan, then check that the name `bendit` is free

Claude Code keeps one list of plugin sources for the whole computer, not one
per project. If another project already uses the name `bendit` for a
different copy, adding it here would quietly switch that project too. This
step checks for that before anything is installed.

**Skip if:** the installed check exits 0 (bendit is already installed for
this project, from the right place):

```bash
claude plugin list --json | python3 -c '
import json, os, re, sys
root = os.path.realpath(".")
reg = os.environ.get("BENDIT_KNOWN_MARKETPLACES") or os.path.expanduser("~/.claude/plugins/known_marketplaces.json")
src = (json.load(open(reg)).get("bendit") or {}).get("source") or {}
if src.get("source") == "directory":
    right_source = os.path.realpath(src.get("path") or "/") == os.path.join(root, ".claude", "vendor", "bendit")
else:
    m = re.match(r"^(?:https?://(?:[^/@]*@)?github\.com/|(?:ssh://)?git@github\.com[:/])?([^/:@]+/[^/]+?)(?:\.git)?/*$", src.get("repo") or src.get("url") or "")
    right_source = bool(m) and m.group(1).lower() == "vedangp57/bendit"
on_here = any(p.get("id") == "bendit@bendit" and p.get("projectEnabled") is True
              and (p.get("scope") == "user" or os.path.realpath(p.get("projectPath") or "/") == root)
              for p in json.load(sys.stdin))
sys.exit(0 if right_source and on_here else 1)'
```

It reads two things: the computer's list of plugin sources
(`~/.claude/plugins/known_marketplaces.json`), which must point `bendit` at
`github.com/VedangP57/bendit` or at this project's own `.claude/vendor/bendit`
copy; and Claude Code's plugin list, which must show `bendit@bendit` turned on
for this project, at any scope.

Otherwise:

1. **Show the person one summary and wait for their answer.** Say this, in
   these words:

   > To install bendit in this project I will:
   > - download bendit from GitHub into a temporary folder, to run its checks;
   > - add bendit to Claude Code's list of plugin sources on this computer;
   > - install the bendit plugin for this project only (this changes
   >   `.claude/settings.json`).
   >
   > After that, `/bendit:adopt` shows you every file it will add, and asks
   > before writing them. Go ahead? (yes or no)

   Only a clear yes goes on. No reply, or anything else, means stop.
2. **Fetch bendit** into a new temporary folder:

   ```bash
   K="$(mktemp -d)" && git clone --depth 1 --branch v0.5.3 https://github.com/VedangP57/bendit "$K/bendit" && echo "KIT=$K/bendit"
   ```

   The folder you download for this setup is the exact release, `v0.5.3`.
   Note the path after `KIT=`. Shell variables do not last from one command
   to the next, so in the commands below, write that path where `<KIT>` is.

3. **Choose the route.** It only reads:

   ```bash
   bash "<KIT>/plugins/bendit/scripts/install-route.sh" route https://github.com/VedangP57/bendit
   ```

   It prints `github <reason>` or `vendor <reason>`. Tell the person the
   reason in plain words. The source for the next command is
   `https://github.com/VedangP57/bendit` for `github`, and the absolute path of
   this project's `.claude/vendor/bendit` for `vendor`.
4. **Check the name.** It only reads:

   ```bash
   bash "<KIT>/plugins/bendit/scripts/install-route.sh" conflict <source>
   ```

   - Exit 0 and no output: go on.
   - Exit 0 and a line starting `switch:`: tell the person that sentence, then
     go on.
   - Any other exit: show the person its message exactly as printed, and stop.
     Go on only if they then say yes. Never remove or change the other
     source yourself.

## 3. Install bendit for this project

**Skip if:** the installed check from step 2 exits 0.

Do this only after step 2 ended in "go on". Follow the route it chose.

- `github`: bendit installs from its main branch, which only changes when a
  new release is published. So the person gets the newest release, and later
  updates keep working. Do not add a version or branch to these commands.

  ```bash
  claude plugin marketplace add https://github.com/VedangP57/bendit --scope project
  claude plugin install bendit@bendit --scope project
  ```

- `vendor`: tell the person "This copy of bendit works on this computer only;
  teammates and fresh clones won't get it until they install bendit
  themselves." Then follow "Route B" in
  `<KIT>/plugins/bendit/skills/adopt-bendit/references/install.md`, steps 2
  to 5, with `<KIT>` as the clean copy.

The install may say that 2 bendit settings are not set. That is expected:
bendit then uses its standard settings. Do not pass `--config` and do not run
`claude plugin configure`.

Then remove the temporary folder from step 2: `rm -r` followed by the path
`<KIT>` without its last `/bendit`, written out in full (the folder `mktemp`
made, never anything else). Then run the installed check again. It
must exit 0 now. If it does not, stop and show the person what each part
printed.

## 4. Run `/bendit:adopt`

`/bendit:adopt` looks at the project, shows the person one summary of what it
will add and install, and asks one question. It then writes the project's
bendit files and prints one approval command for the person.

**Skip if:** (only this file means bendit is set up here)

```bash
test -f .claude/bendit.json
```

Otherwise, Claude Code only notices a new plugin when it reloads. If
`/bendit:adopt` is already among the commands you can run, run it. If not, ask
the person to type `/reload-plugins` and then `/bendit:adopt`. No restart is
needed for this.

Either way, `/bendit:adopt` asks the person its question. Wait for their
reply. Never reply for them. A run that stops part way is safe to repeat: it
writes `.claude/bendit.json` last.

## 5. The person approves the check

The Stop gate runs the project's check (`.claude/verify-harness`) on the
person's computer with their permissions. So a person, not the agent, approves
it, with a command that `/bendit:adopt` prints. It looks like this:

```bash
python3 <bendit's installed folder>/scripts/require-verification.py --trust <project folder>
```

`<bendit's installed folder>` is the copy Claude Code installed in step 3. It
is not the temporary download, which step 3 deleted. This prints it, and only
reads (it works from any folder inside the project, and from a git worktree):

```bash
python3 -c '
import json, os, subprocess, sys
def git(*a):
    try:
        return subprocess.check_output(("git",) + a, text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return ""
# The project is the MAIN checkout: a worktree loads the main checkout'"'"'s install.
first = git("worktree", "list", "--porcelain").split("\n\n")[0].splitlines()
if first and first[0].startswith("worktree ") and "bare" not in first:
    root = first[0][len("worktree "):]
else:
    root = git("rev-parse", "--show-toplevel").strip() or "."
root = os.path.realpath(root)
reg = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "plugins", "installed_plugins.json")
try:
    es = json.load(open(reg)).get("plugins", {}).get("bendit@bendit", [])
except (OSError, ValueError):
    es = []
here = [e["installPath"] for e in es if e.get("scope") == "project" and os.path.realpath(e.get("projectPath") or "/") == root]
anyw = [e["installPath"] for e in es if e.get("scope") == "user"]
print((here or anyw or [sys.exit("bendit is not installed for this project")])[0])'
```

Write that path into the command you hand over, in full, with both the path
and the project folder in double quotes (paths can contain spaces), and check that
`require-verification.py` exists under its `scripts` folder. If `/bendit:adopt`
already printed the command with a path you can see exists, use that one.

Never run it yourself. bendit's own guard refuses it from the agent anyway. Ask
the person to open a new Terminal window (not the chat), paste the command
that `/bendit:adopt` printed, and type `y`.

If `/bendit:adopt` printed no approval command because the project has no
check yet, there is nothing to approve and this step is done.

**Skip if:** (there is no check, or the approval list holds this exact check
for this project)

```bash
python3 - <<'PY'
import hashlib, json, os, subprocess, sys
root = os.path.realpath(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
cfg = os.environ.get('BENDIT_CONFIG_DIR') or os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'bendit')
harness = os.path.join(root, '.claude', 'verify-harness')
if not os.path.isfile(harness):
    sys.exit(0)  # no check yet, so nothing to approve
sha = hashlib.sha256(open(harness, 'rb').read()).hexdigest()
trusted = json.load(open(os.path.join(cfg, 'trusted-harnesses.json')))['trusted']
sys.exit(0 if any(e.get('repo') == root and e.get('sha256') == sha for e in trusted) else 1)
PY
```

This check only reads. Run it again after the person says they are done.

## 6. Reopen and run `/bendit:doctor`

**Skip if:** never. This is the step that shows the others worked, in the
window the person will use.

Ask the person to close Claude Code, open it again in this project and type
`/bendit:doctor`. Restart here, even though `/reload-plugins` exists: a reload may not
make bendit protect a window that is already open, and this check must run in
the window the person will use. When bendit protects the window, the check ends with:

> bendit is active in this window: it just stopped a test force-push, as it should.

If it ends with "What to do next:", follow its numbered steps, or show them to
the person when they are the person's to do.

## If something goes wrong

- `/bendit:doctor` says which guards are off, and why.
- "Unknown command": type the prefix, `/bendit:adopt`, not `/adopt`.
- To undo everything, the report from `/bendit:adopt` ends with a "How to undo
  all of it" section with the exact commands for this project.
- More detail: [README](README.md) and [docs/reference.md](docs/reference.md).
