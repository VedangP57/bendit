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
`.claude/skills/`, `.claude/verify-harness` and `.claude/vendor/bendit/VENDORED_FROM`
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
`/new-guard` later, not something to change now.

## 7. Is there an app to run?

A dev/start script, a server entry point, a `Procfile`, a mobile app config.
Yes means the verification skill is worth scaffolding; a library or CLI usually
needs only its test suite as the harness.

## Output

Print one table, then the list of `?` items that become interview questions:

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
