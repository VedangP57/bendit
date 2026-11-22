# Detect (read-only)

Nothing in this step writes a file or runs a project command. Reading files,
`git` queries that do not touch the network, and `command -v <tool>` are fine.

Record every finding with the `file:line` (or command) it came from. A finding
with no source is a guess: mark it `?` and it becomes an interview question.

## 1. Where am I

```bash
git rev-parse --show-toplevel        # project root; not a repo -> ask (see SKILL.md)
basename "${SHELL:-}"                 # zsh enables the zsh word-split guard
uname -s                              # Darwin or Linux; anything else: say so
python3 -c 'import sys; print(sys.version)'   # hooks need 3.9+
```

## 2. Ecosystem, package manager, commands

Look at the root first, then one level down for monorepo members. A task runner
(`Makefile`, `justfile`, `Taskfile.yml`) or the CI workflow **wins** over an
inferred command, because it is what people actually run. Record the exact
command line, not just "has tests".

| ecosystem | identify by | package manager | test | lint | typecheck | build | dev / run |
|---|---|---|---|---|---|---|---|
| Node | `package.json` | `packageManager` field wins; else lockfile: `pnpm-lock.yaml` pnpm, `package-lock.json` npm, `yarn.lock` yarn, `bun.lock`/`bun.lockb` bun | `scripts.test` | `scripts.lint` | `scripts.typecheck` / `type-check` / `tc` / `check-types` (a bare `tsc --noEmit` may skip codegen the script runs) | `scripts.build` | `scripts.dev`, else `scripts.start` |
| Python | `pyproject.toml`, `setup.py`, `requirements*.txt` | `uv.lock` uv (`uv run …`); `poetry.lock` or `[tool.poetry]` poetry (`poetry run …`); `Pipfile` pipenv; else pip in a venv | pytest if `[tool.pytest…]`, `pytest.ini`, `conftest.py` or pytest in deps; else `python -m unittest` | ruff (`[tool.ruff]`, `ruff.toml`), else flake8 / pylint config | mypy (`[tool.mypy]`, `mypy.ini`), pyright (`pyrightconfig.json`, `[tool.pyright]`) | only with a `[build-system]`: `uv build` / `poetry build` / `python -m build` | `manage.py runserver`, a `uvicorn`/`gunicorn` line in `Procfile`/`Makefile`, `[project.scripts]` |
| Go | `go.mod` | go | `go test ./...` | `golangci-lint run` if `.golangci.*`, else `go vet ./...` | `go build ./...` | `go build ./...` | `go run ./cmd/<name>` for each `cmd/*/main.go` |
| Rust | `Cargo.toml` | cargo | `cargo test` | `cargo clippy -- -D warnings` (if `cargo clippy -V` works) | `cargo check` | `cargo build` | `cargo run` (ask which bin if several) |
| other | `Gemfile`, `pom.xml`, `build.gradle*`, `*.csproj`, `mix.exs`, `composer.json`, `Package.swift`, `pubspec.yaml`, … | the ecosystem's own | read the task runner or CI | same | same | same | same |

If two lockfiles disagree (say `package-lock.json` and `pnpm-lock.yaml`), that is
a finding, not a choice you make: ask.

For "other", do not guess commands from memory. Read the task runner and CI;
if neither names a command, it becomes an interview question.

**Probe that each tool exists** (`command -v pnpm`, `cargo clippy -V`): a gate
whose binary is missing reports nothing, which reads as a pass.

## 3. Monorepo

Signals: `pnpm-workspace.yaml`, `workspaces` in `package.json`, `turbo.json`,
`nx.json`, `lerna.json`, `go.work`, `[workspace]` in `Cargo.toml`,
`[tool.uv.workspace]`. Prefer the root-level command that runs every member
(`pnpm -r test`, `turbo run test`, `cargo test --workspace`, `go test ./...`
from the `go.work` root). If none exists, list the members and ask which matter.

## 4. Branches

```bash
git symbolic-ref --quiet --short refs/remotes/origin/HEAD   # integration branch
git branch -r                                               # what exists remotely
git rev-parse --abbrev-ref HEAD                             # where the user is
```

`origin/HEAD` can be unset on old clones; do not run `git remote set-head`
(network) without asking. Production branch: look for deploy jobs and their
branch filters in CI, and deploy configs (`vercel.json`, `netlify.toml`,
`fly.toml`, `render.yaml`, `app.yaml`). Not found means ask.

## 5. CI

`.github/workflows/*.yml`, `.gitlab-ci.yml`, `.circleci/config.yml`,
`azure-pipelines.yml`, `Jenkinsfile`, `bitbucket-pipelines.yml`, `.buildkite/`.
For each: which gates it runs, on which events and branches. **A workflow
filtered to a branch nobody pushes to is dead config**: compare its branch
filters with the integration branch. A step with `continue-on-error: true` or
`|| true` is a badge, not a gate.

## 6. Existing agent configuration

`CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, `.claude/settings.local.json`
(personal, usually untracked), `.claude/hooks/`, `.claude/commands/`,
`.claude/skills/`, `.claude/verify-harness`, `.claude/bendit.json` and `.claude/vendor/bendit/VENDORED_FROM`
(a previous adoption: read them, and the `Integration branch:` line in
`AGENTS.md`, and treat this run as an update), plus other agents'
files (`.cursorrules`, `.github/copilot-instructions.md`) and git hooks
(`.husky/`, `.pre-commit-config.yaml`, `lefthook.yml`).

For every hook already configured, check it is alive. The commonest finding is
configuration that looks live and is dead:

- does the script it runs exist? (a `[ -f x ] || exit 0` guard hides a missing one)
- does a PreToolUse Bash guard read `tool_input.command` (not a top-level `command`)?
- does it print its refusal to **stderr** with exit 2?
- is `timeout` in seconds? Values of 1000 or more are almost always milliseconds.

For prose rules in `CLAUDE.md`/`AGENTS.md`, note any that a machine could check
(file length, forbidden flags, required commands): they are candidates for
`/bendit:new-guard` later, not something to change now.

## 7. Is there an app to run?

A dev/start script, a server entry point, a `Procfile`, a mobile app config.
Yes means the verification skill is worth scaffolding; a library or CLI usually
needs only its test suite as the harness.

## 8. Features

Five optional features exist, and only these (`FEATURES` in
`KIT/scripts/features.py`). Each is on when its signal is found, and its `why`
is that signal's source, written as you would cite it in the report.

| feature | on when | why (its source) | needs |
|---|---|---|---|
| `browser-driver` | web app: a `package.json` dependency key from the list below, or `index.html` at the root | `package.json:<line> <name>`, or `index.html` | Node 20+, Google Chrome (Chromium does not count), and Playwright installed by `scripts/drive-setup.sh`: `bash "$KIT/scripts/drive-setup.sh"` (SKILL.md step 3b asks first) |
| `ux-design-laws` | web app (same signal) | same as `browser-driver` | the `bendit-web` add-on (SKILL.md step 3b installs it) |
| `session-brief` | a git project | `git project (git rev-parse --show-toplevel)` | nothing |
| `ls-guard` | `ls` is not the real `ls` in the user's shell | `type ls in <shell>: ls is a shell function` or `…: ls is an alias` (`<shell>` is the basename of `$SHELL`) | nothing |
| `primary-checkout-guard` | never from detection: only a yes to interview.md question 7 (`--detailed`) | `off unless chosen in /bendit:adopt --detailed` | a git project |

A feature whose signal is absent is off, and its `why` says what was not found
(`no web framework in package.json`, `not a git repository`, `type ls in zsh: ls is the real ls`).

**Web app.** The names are the installer's (`is_web_project` in bendit's
`install.sh`): `next react vue svelte @sveltejs/kit nuxt astro vite
@angular/core solid-js @remix-run/react`, as a key of `dependencies` or
`devDependencies`. From the project root, these print the signal and its line,
or nothing:

```bash
test -e index.html && echo "index.html"
python3 -I -c '
import json
names = "next react vue svelte @sveltejs/kit nuxt astro vite @angular/core solid-js @remix-run/react".split()
text = open("package.json").read()
d = json.loads(text)
keys = set()
for k in ("dependencies", "devDependencies"):
    if isinstance(d.get(k), dict):
        keys.update(d[k])
for n in names:
    if n in keys:
        line = next(i for i, l in enumerate(text.splitlines(), 1) if "\"%s\"" % n in l)
        print("package.json:%d %s" % (line, n))
        break
'
```

With no `package.json` the second command fails with `FileNotFoundError`: that
means "no web framework in package.json", not an error to report.

**What `browser-driver` needs.** Read only; nothing is installed in this step:

```bash
node --version    # v20 or newer (the installer's NODE_MIN)
for c in google-chrome google-chrome-stable; do command -v "$c"; done
for d in /Applications "$HOME/Applications"; do
  test -e "$d/Google Chrome.app" && echo "$d/Google Chrome.app"
done
bash "$KIT/scripts/drive-setup.sh" --check   # exit 0: Playwright installed; 1: not (it installs nothing)
```

Chrome is found if either loop prints a line (the installer's `find_chrome`).
**Chromium does not count**, on `PATH` (`chromium`, `chromium-browser`) or as
`Chromium.app`: the driver launches Playwright browser channels (`chrome` by
default; `BENDIT_BROWSER_CHANNEL` names another, such as `msedge` or
`chrome-beta`), and none of them is a system Chromium. A machine with only
Chromium has no Chrome: if Google Chrome is not installed after step 3b,
`browser-driver` is off with why `Chrome not found (Chromium cannot be driven)`.
A missing dependency does not turn the feature off here: SKILL.md step 3b asks.

**`ls`.** Ask the user's interactive shell what `ls` is. Its rc files run, and
they can hang or prompt, so this runs with no stdin and a 5-second limit. The
whole process group is killed on timeout, so a background child cannot hold
the pipe open. It prints the state and the exact `why` to record, never the
raw `type` output: zsh's `from <file>` names a home path, and
`.claude/bendit.json` is committed.

```bash
python3 -I -c '
import os, signal, subprocess
sh = os.environ.get("SHELL") or "/bin/sh"
name = os.path.basename(sh)
try:  # a missing or non-executable $SHELL raises OSError: could not inspect
    p = subprocess.Popen([sh, "-ic", "type ls"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, _err = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        out = None
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
except OSError:
    out = None
first = (out.decode("utf-8", "replace").splitlines() or [""])[0].strip() if out is not None else ""
if out is not None and first.startswith("ls is") and "function" in first:
    print("on  | type ls in %s: ls is a shell function" % name)
elif out is not None and first.startswith("ls is") and "alias" in first:
    print("on  | type ls in %s: ls is an alias" % name)
elif first.startswith("ls is /") or first.startswith("ls is hashed (/"):
    print("off | type ls in %s: ls is the real ls" % name)
else:
    print("off | could not inspect the shell")
'
```

Only the first stdout line counts. Fish prints the whole function body after
it, and stderr carries rc-file startup warnings. Bash says `aliased`, zsh
`an alias for`, and fish `a function with definition`. A timeout, an empty
answer or anything unrecognised is `ls-guard` off with why
`could not inspect the shell`. Record the printed why exactly as it is.

## Output

Print one table, then the features table from §8 (`feature | on/off | why`),
then the list of `?` items that become interview questions:

```
finding              | value                      | source
ecosystem            | node (pnpm 9)              | package.json:5 packageManager
test                 | pnpm test                  | package.json:12
typecheck            | pnpm typecheck             | package.json:14
integration branch   | main                       | git symbolic-ref origin/HEAD
production branch    | ?                          | no deploy config found
CI                   | ci.yml runs lint+test on PRs to main | .github/workflows/ci.yml:3-9
existing hooks       | 1 PreToolUse, script missing (dead) | .claude/settings.json:8
shell                | zsh                        | $SHELL
app                  | yes, pnpm dev on :3000     | package.json:10
```
