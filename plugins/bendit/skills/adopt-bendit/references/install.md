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

`<source>` below is the kit's public address,
`https://github.com/VedangP57/bendit` (a fork or a local clone also works; ask
only if unsure).

## Deciding the route (no question needed)

Ask the helper, which only reads and never installs:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/install-route.sh route <source>   # prints: github|vendor <reason>
```

`github` means anyone can download the kit with no sign-in. The probe is an
anonymous `curl` of `<source>.git/info/refs?service=git-upload-pack` (`-q`
first so `~/.curlrc` is ignored, `--netrc-file /dev/null`, no credentials of any
kind; git is deliberately not used, since its config, askpass and URL rewrites
can authenticate). Only HTTP 200 counts; any other answer, a timeout, or no
`curl` means `vendor`. Only a `https://github.com/<owner>/<repo>` source can be
`github`. Use Route A for
`github`, Route B for `vendor`, and give the person the reason in plain words.
`--detailed` still shows both routes and lets the person pick.

**Route B says this, in these words:** "This copy of bendit works on this
computer only; teammates and fresh clones won't get it until they install
bendit themselves." Claude Code records a vendored marketplace as this
machine's absolute path, so a portable vendored copy is not possible today.

## Before any `claude plugin marketplace add`

Marketplace names are global to the computer (`~/.claude/plugins/known_marketplaces.json`),
so adding `bendit` here silently re-points every other project that uses it.
Run, with the exact source about to be added (the URL, or the vendored
directory's absolute path):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/install-route.sh conflict <source-or-directory>
```

Silent and exit 0: go on (no entry, or the same source). Exit 0 with a line
`switch: <sentence>`: go on too (another project's vendored copy of bendit is
being replaced by the public GitHub repo, which loses it nothing); say the
sentence to the person and put it in the report. **Any non-zero exit
means stop and ask**: it printed a plain sentence (naming the other project, or
saying the registry could not be checked); show it and add nothing unless the
person says yes. Same-source re-adds never stop.

## Route A: marketplace, project scope (default)

Chosen when the route probe above says `github`. Show the two commands, get a yes, run them, read the output:

```bash
claude plugin marketplace add <source> --scope project
claude plugin install bendit@bendit --scope project
```

For a web app, SKILL.md step 3b adds the `bendit-web` add-on from the same
marketplace, after its own yes:

```bash
claude plugin install bendit-web@bendit --scope project
```

Project scope writes to the project's `.claude/settings.json`; show the user
that diff afterwards. That file is the record of this route: it names the
marketplace and the plugin, and Claude Code reads it. Write nothing else.

Already installed at user scope only? Ask whether to add project scope too
*[yes: otherwise the guards exist only on this machine]*.

## Route B: vendor (the probe says `vendor`, or the user wants it pinned in the repo)

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

   The copy already holds every plugin under `plugins/`, so for a web app step
   3b's add-on comes from it too, after its own yes:
   `claude plugin install bendit-web@bendit --scope project`.

   Claude Code stores that path as an absolute one, which only works on this
   computer: say the sentence above and do not hand-edit it.
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
