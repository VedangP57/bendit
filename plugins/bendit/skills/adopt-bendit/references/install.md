# Install

You are running this skill, so the kit is loaded in *this* session already. The
question here is how the **project** gets it, so that every session in it
(teammates, cloud sessions, a fresh clone) runs the same guards.

## 0. Check the CLI before relying on it

```bash
claude plugin --help               # must list: marketplace, install, list
claude plugin marketplace --help   # must list: add
claude plugin install --help       # must show --scope (user, project, local)
claude plugin list                 # is bendit already installed, and at what scope?
```

If a subcommand or flag is missing, the CLI is older or newer than this guide:
stop and show the user the help output rather than guessing a spelling.

`<source>` below is the kit's git URL from its README (the user may also have a
fork or a local clone; ask if unsure).

## Route A: marketplace, project scope (default)

Reachable when `git ls-remote <source> HEAD` succeeds (ask before this network
call). Show the two commands, get a yes, run them, read the output:

```bash
claude plugin marketplace add <source> --scope project
claude plugin install bendit@bendit --scope project
```

Project scope writes to the project's `.claude/settings.json`; show the user
that diff afterwards. That file is the record of this route: it names the
marketplace and the plugin, and Claude Code reads it. Write nothing else.

Already installed at user scope only? Ask whether to add project scope too
*[yes: otherwise the guards exist only on this machine]*.

## Route B: vendor (no network, or the user wants it pinned in the repo)

Copy the kit into the project so it is versioned with the code:

1. Get a clean copy of the kit repository: an existing clone the user names, or
   `git clone --depth 1 <source>` into a temporary directory (ask first). Refuse
   a working tree with uncommitted changes (`git status --porcelain` not empty):
   the recorded commit would not describe what was copied.
2. Record its commit: `git -C <clone> rev-parse HEAD`.
3. Copy the marketplace manifest and the plugin, nothing else, into
   `.claude/vendor/bendit/`:

   ```bash
   mkdir -p .claude/vendor/bendit/.claude-plugin
   cp <clone>/.claude-plugin/marketplace.json .claude/vendor/bendit/.claude-plugin/
   cp -R <clone>/plugins .claude/vendor/bendit/
   ```

4. Register it as a local marketplace at project scope and install from it:

   ```bash
   claude plugin marketplace add ./.claude/vendor/bendit --scope project
   claude plugin install bendit@bendit --scope project
   ```

   Then read `.claude/settings.json`: if the marketplace path was stored as an
   absolute path, it will not work in another checkout. Report that under "not
   possible here" rather than hand-editing it.
5. Record where the copy came from, beside the copy, as plain text:

   ```bash
   printf 'source: %s\ncommit: %s\n' "<source>" "$(git -C <clone> rev-parse HEAD)" \
     > .claude/vendor/bendit/VENDORED_FROM
   ```

   `VENDORED_FROM` is how anyone tells which version the project runs (the
   README shows users how to check it against upstream); nothing else records
   it. Updating later means repeating these steps with a new commit.
   The generated app harness finds this copy on its own
   (`.claude/skills/verify-<name>/bin/verify-<name> kit` says so).

## After either route

```bash
claude plugin list        # bendit, enabled, at project scope
```

Hooks load at session start. Tell the user the live proof in `prove.md` step 3
needs a **new session** (or `/plugin` reload) if the install just happened.

## Neither route works

Stop. Report the failing command and its output. Do not hand-copy hooks into
`.claude/settings.json` as a workaround: that is a second, drifting copy of
every guard.
