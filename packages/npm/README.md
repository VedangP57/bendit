# bendit

Enforced rules for coding agents: guard hooks that refuse risky commands
(force-pushes, deleting folders, overwriting saved work), and a check that runs
your project's tests before the AI is allowed to say it is done. It is a plugin
for [Claude Code](https://claude.com/claude-code).

## Use it

From inside your project folder, on macOS or Linux:

```bash
npx bendit
curl -fsSL https://raw.githubusercontent.com/VedangP57/bendit/main/install.sh | bash
pipx run bendit        # or: uvx bendit
brew install vedangp57/tap/bendit && bendit
```

Any one of these does the same thing: it checks your machine, asks before
installing anything, and opens Claude Code on `/bendit:adopt`: one question,
then one approval line. Engineers who want every choice can run
`/bendit:adopt --detailed`.

Needs `claude`, `git` and `python3` 3.9 or newer. Source, docs and the
changelog: https://github.com/VedangP57/bendit
