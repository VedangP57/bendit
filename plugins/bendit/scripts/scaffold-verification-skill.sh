#!/usr/bin/env bash
# Scaffold a verify harness for a repo, by detecting what is actually there.
#
# Always writes  .claude/verify-harness  -- the command the Stop gate runs.
# For a web app, also writes  .claude/skills/verify-<name>/  -- the app harness
# (bin/verify-<name> with doctor/up/drive/verify, probe helpers, a smoke
# scenario) that scripts/verify.sh launches, waits on and drives -- and
# .env.verify.example, the committed list of what a local, optional
# .env.verify.local may override. Nothing it writes needs a local-only file, so
# a fresh clone verifies with what git gave it.
#
# Shapes:
#   web      launch the dev server on this repo's registry port, wait until it
#            serves, run every scenario, tear down -- plus any lint/typecheck/test
#   cli      lint/typecheck/test, plus a smoke run of the entrypoint (--help)
#   library  lint/typecheck/test
#
# NEVER GUESSES SILENTLY. Whatever it cannot detect becomes a TODO line at the
# top of the generated harness that prints what to fill in and exits 2, and
# this script exits 3 naming the same TODOs. A generated harness cannot pass
# by doing nothing.
#
# usage: scaffold-verification-skill.sh <repo-path> [options]
#   --name <name>      skill name (default: the project's own name -- package.json
#                      "name" without its @scope, pyproject [project].name, go.mod
#                      module's last segment, Cargo.toml [package].name -- else
#                      the folder; lowercased, anything but a-z 0-9 - becomes -)
#   --kind <k>         web | cli | library   (default: detected)
#   --dev '<command>'  how to serve the web app; "$PORT" stays literal and is
#                      expanded at run time, e.g. --dev 'uvicorn app:app --port "$PORT"'
#   --pm <pm>          npm | pnpm | yarn | bun   (default: from the lockfile)
#   --force            overwrite an existing harness (scenarios are kept)
#   --dry-run          print what was detected; write nothing
#
# exit: 0 generated, nothing left to fill in
#       3 generated, with TODOs (the harness refuses until they are done)
#       2 refused: bad arguments, not a git repo, or a harness already exists
set -euo pipefail

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

REPO_ARG=""; NAME=""; KIND_OVER=""; DEV_OVER=""; PM_OVER=""; FORCE=""; DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:?--name needs a value}"; shift 2 ;;
    --kind)    KIND_OVER="${2:?--kind needs a value}"; shift 2 ;;
    --dev)     DEV_OVER="${2:?--dev needs a command}"; shift 2 ;;
    --pm)      PM_OVER="${2:?--pm needs a value}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    -*)        echo "scaffold: unknown option $1" >&2; usage ;;
    *)         if [ -z "$REPO_ARG" ]; then REPO_ARG="$1"
               elif [ -z "$NAME" ]; then NAME="$1"   # legacy: <repo-path> [name]
               else echo "scaffold: unexpected argument $1" >&2; usage; fi
               shift ;;
  esac
done
[ -n "$REPO_ARG" ] || usage
case "$KIND_OVER" in ''|web|cli|library) ;; *) echo "scaffold: --kind must be web, cli or library (got '$KIND_OVER')" >&2; exit 2 ;; esac
case "$PM_OVER" in ''|npm|pnpm|yarn|bun) ;; *) echo "scaffold: --pm must be npm, pnpm, yarn or bun (got '$PM_OVER')" >&2; exit 2 ;; esac
REPO="$(cd "$REPO_ARG" 2>/dev/null && pwd)" || { echo "scaffold: no such directory: $REPO_ARG" >&2; exit 2; }
# The Stop gate and verify.sh both find the repo through git, so a harness in a
# folder git does not know would never be run.
if ! git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "scaffold: $REPO is not inside a git repository; the Stop gate finds harnesses through git. Run 'git init' first." >&2; exit 2
fi
# An explicit --name is checked, never rewritten: a name someone typed is one
# they will type again. A detected one is sanitised (see detect).
NAME_WHY="--name"
if [ -n "$NAME" ]; then
  case "$NAME" in *[!a-z0-9-]*) echo "scaffold: --name must be lowercase letters, digits and '-' (got '$NAME')" >&2; exit 2 ;; esac
fi
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# --- detect ---------------------------------------------------------------
# Python (3.9 stdlib) rather than node or jq: it is the one interpreter this
# kit already requires, and a Python or Go repo has no node. It prints shell
# assignments, every value shlex-quoted, so nothing in a repo's files can
# inject into this script.
# A FUNCTION, not a heredoc inside $( ): bash 3.2 (stock macOS) mis-parses
# quotes inside a heredoc nested in command substitution.
detect() {
python3 - "$REPO" "$PM_OVER" "$KIND_OVER" "$DEV_OVER" <<'PY'
import json, os, re, shlex, sys

repo, pm_over, kind_over, dev_over = sys.argv[1:5]
todos, notes, gates = [], [], []        # gates: (label, command, source)
kinds = []                              # (kind, why)
ecos, frameworks = [], []
up_line, smoke = '', ''
SKIP = {'.git', 'node_modules', '.venv', 'venv', 'target', 'dist', 'build', '.tox', '__pycache__'}


def has(*p):
    return os.path.exists(os.path.join(repo, *p))


def read(*p):
    try:
        with open(os.path.join(repo, *p), encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return ''


def walk(max_depth=4):
    for d, dirs, files in os.walk(repo):
        rel = os.path.relpath(d, repo)
        depth = 0 if rel == '.' else rel.count(os.sep) + 1
        dirs[:] = [x for x in dirs if x not in SKIP and depth < max_depth]
        for f in files:
            yield os.path.join(rel, f) if rel != '.' else f


def section(text, name):
    """Body of a TOML [section], up to the next header. No tomllib on 3.9."""
    m = re.search(r'^\[' + re.escape(name) + r'\]\s*$(.*?)(?=^\[|\Z)', text, re.M | re.S)
    return m.group(1) if m else ''


files = list(walk())


def sanitise(n):
    return re.sub(r'[^a-z0-9]+', '-', str(n).lower()).strip('-')


# ---- the project's own name, for verify-<name> ----
# The folder is whatever someone cloned into ("app", "repo", a temp dir); the
# manifest says what the project calls itself. First usable source wins.
def project_name():
    cands = []
    if has('package.json'):
        try:
            n = json.loads(read('package.json')).get('name')
        except (ValueError, AttributeError):
            n = None
        if isinstance(n, str):
            cands.append((n.split('/', 1)[1] if n.startswith('@') and '/' in n else n,
                          'package.json "name"'))
    m = re.search(r'^\s*name\s*=\s*["\']([^"\']+)', section(read('pyproject.toml'), 'project'), re.M)
    if m:
        cands.append((m.group(1), 'pyproject.toml [project].name'))
    m = re.search(r'^\s*module\s+(\S+)', read('go.mod'), re.M)
    if m:
        segs = [x for x in m.group(1).strip('"').split('/') if x]
        # example.com/org/svc/v2 is svc: /vN is a major version, not a name.
        if len(segs) > 1 and re.fullmatch(r'v[0-9]+', segs[-1]):
            segs = segs[:-1]
        cands.append((segs[-1] if segs else '', 'go.mod module'))
    m = re.search(r'^\s*name\s*=\s*["\']([^"\']+)', section(read('Cargo.toml'), 'package'), re.M)
    if m:
        cands.append((m.group(1), 'Cargo.toml [package].name'))
    for raw, src in cands:
        if sanitise(raw):
            return sanitise(raw), src
        notes.append(f'{src} ({raw!r}) has no letters or digits to name the skill by -- skipped')
    return sanitise(os.path.basename(repo)), 'folder name; no project name found'


name, name_why = project_name()

# ---- node ----
if has('package.json'):
    ecos.append('node')
    try:
        pkg = json.loads(read('package.json'))
    except ValueError:
        pkg = {}
        todos.append('package.json is not valid JSON, so nothing in it was detected -- fix it and re-run')
    pkg = pkg if isinstance(pkg, dict) else {}
    scripts = pkg.get('scripts') if isinstance(pkg.get('scripts'), dict) else {}
    deps = set()
    for k in ('dependencies', 'devDependencies'):
        if isinstance(pkg.get(k), dict):
            deps |= set(pkg[k])
    locks = [(f, m) for f, m in (('pnpm-lock.yaml', 'pnpm'), ('yarn.lock', 'yarn'),
                                  ('bun.lockb', 'bun'), ('bun.lock', 'bun'),
                                  ('package-lock.json', 'npm')) if has(f)]
    managers = sorted({m for _, m in locks})
    pm = 'npm'
    if pm_over:
        pm = pm_over
        notes.append(f'package manager: {pm} (--pm)')
    elif len(managers) == 1:
        pm = managers[0]
        notes.append(f'package manager: {pm} ({", ".join(f for f, _ in locks)})')
    elif len(managers) > 1:
        todos.append(f'several lockfiles ({", ".join(f for f, _ in locks)}) -- re-run with --pm '
                     f'to say which package manager this repo uses')
    else:
        m = re.match(r'(npm|pnpm|yarn|bun)@', str(pkg.get('packageManager') or ''))
        if m:
            pm = m.group(1)
            notes.append(f'package manager: {pm} (package.json "packageManager")')
        else:
            notes.append('package manager: npm (no lockfile, no "packageManager" field; '
                         'npm is the default -- re-run with --pm to change)')

    def run(s):
        return f'{pm} run {s}'

    if 'lint' in scripts:
        gates.append(('lint', run('lint'), 'package.json scripts.lint'))
    for s in ('typecheck', 'type-check', 'tc', 'check-types', 'types'):
        if s in scripts:
            gates.append(('typecheck', run(s), f'package.json scripts.{s}'))
            break
    t = str(scripts.get('test') or '')
    if t and 'no test specified' not in t:
        gates.append(('test', run('test'), 'package.json scripts.test'))
    elif t:
        notes.append('package.json scripts.test is npm\'s "no test specified" placeholder -- ignored')

    SERVER = {'next', 'nuxt', 'vite', 'astro', '@sveltejs/kit', 'express', 'fastify', 'koa',
              'hono', '@hono/node-server', '@remix-run/dev', 'react-scripts', 'expo',
              '@angular/cli', 'gatsby', '@nestjs/core', 'webpack-dev-server', 'http-server', 'serve'}
    for f in ('next', 'nuxt', 'vite', 'astro', '@sveltejs/kit', 'expo', 'express', 'fastify'):
        if f in deps:
            frameworks.append(f)
    dev = str(scripts.get('dev') or '')
    start = str(scripts.get('start') or '')
    server_dep = sorted(deps & SERVER)
    serves = bool(server_dep) or bool(re.search(r'serve|server|--port|(^|\s)-p(\s|=)|PORT', dev))
    script = ''
    if 'expo' in deps:
        kinds.append(('web', 'package.json depends on expo'))
        up_line = 'exec npx expo start --web --port "$PORT"'
    elif dev and serves:
        kinds.append(('web', f'package.json scripts.dev ({dev})'
                      + (f' and depends on {server_dep[0]}' if server_dep else '')))
        script = 'dev'
    elif start and server_dep:
        kinds.append(('web', f'package.json scripts.start and depends on {server_dep[0]}'))
        script = 'start'
    elif pkg.get('bin'):
        kinds.append(('cli', 'package.json has "bin"'))
        b = pkg['bin']
        path = b if isinstance(b, str) else (next(iter(b.values()), '') if isinstance(b, dict) else '')
        if path:
            smoke = f'node {shlex.quote(path)} --help'
    elif dev:
        kinds.append(('unknown', f'package.json has a dev script ({dev}) but nothing says it '
                                 f'serves HTTP -- re-run with --kind web (and --dev if needed) '
                                 f'or --kind library'))
    else:
        kinds.append(('library', 'package.json has no dev script, server dependency or "bin"'))
    if script:
        text = scripts[script]
        if re.search(r'--port[ =]', text):
            flag = '--port'
        elif re.search(r'(^|\s)-p[ =]', text):
            flag = '-p'
        elif re.search(r'\bvite\b|astro dev|ng serve|svelte-kit dev', text):
            # These ignore $PORT: without the flag the app comes up on its own
            # default port while verify.sh waits on the registry's.
            flag = '--port'
        else:
            flag = ''
            notes.append(f'"{text}" names no port flag: the harness exports PORT and assumes '
                         f'the server reads it (next, nuxt and most express apps do); '
                         f'verify.sh says "never answered" if it does not')
        extra = ''
        if flag:
            extra = f' {flag} "$PORT"' + (' --strictPort' if re.search(r'\bvite\b', text) else '')
            if pm == 'npm':
                extra = ' --' + extra
        up_line = f'exec {run(script)}{extra}'

# ---- python ----
PYFILES = ('pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile')
# Loose .py files count only at the root of a repo nothing else claimed: a
# helper script in a node repo must not demand Python tests.
if any(has(f) for f in PYFILES) or (not ecos and any(f.endswith('.py') and os.sep not in f for f in files)):
    ecos.append('python')
    pyproject = read('pyproject.toml')
    text = '\n'.join(read(f) for f in ('pyproject.toml', 'setup.cfg', 'setup.py', 'Pipfile', 'tox.ini'))
    text += '\n'.join(read(f) for f in files if re.match(r'requirements[^/]*\.txt$', f))
    if has('uv.lock') and has('poetry.lock'):
        todos.append('both uv.lock and poetry.lock exist -- replace the python commands below with '
                     'the runner this repo really uses')
    if has('uv.lock'):
        py, how = 'uv run python', 'uv.lock'
    elif has('poetry.lock') or '[tool.poetry]' in pyproject:
        py, how = 'poetry run python', 'poetry.lock / [tool.poetry]'
    elif has('.venv', 'bin', 'python'):
        py, how = '.venv/bin/python', '.venv/bin/python'
    else:
        py, how = 'python3', 'no uv.lock, poetry.lock or .venv: python3 on PATH, which must have the dev dependencies'
    notes.append(f'python runner: {py} ({how})')
    tests = [f for f in files if f.endswith('.py') and
             (os.path.basename(f).startswith('test_') or f.endswith('_test.py'))]
    if re.search(r'\bpytest\b', text) or has('pytest.ini') or has('conftest.py'):
        if tests or has('tests'):
            gates.append(('test', f'{py} -m pytest', 'pytest configured'))
        else:
            todos.append('pytest is configured but no test_*.py / *_test.py files exist -- '
                         'pytest would pass having run nothing; write a test')
    elif tests:
        # -s tests, no -t: with -t . a tests/ folder that is not a package is
        # "not importable". `python -m` already puts the repo root on sys.path.
        start = ' -s tests' if has('tests') else ''
        gates.append(('test', f'{py} -m unittest discover{start}', f'{len(tests)} test files, no pytest config'))
    else:
        todos.append('no Python tests found (test_*.py / *_test.py) -- add tests, or put the '
                     'command that proves this project works here')
    if '[tool.ruff' in pyproject or has('ruff.toml') or has('.ruff.toml'):
        gates.append(('lint', f'{py} -m ruff check .', 'ruff configured'))
    if '[tool.mypy' in pyproject or has('mypy.ini') or '[mypy' in read('setup.cfg'):
        gates.append(('typecheck', f'{py} -m mypy .', 'mypy configured'))
    elif '[tool.pyright' in pyproject or has('pyrightconfig.json'):
        gates.append(('typecheck', f'{py} -m pyright', 'pyright configured'))
    web = re.search(r'\b(fastapi|flask|uvicorn|starlette|aiohttp|sanic|quart|gunicorn)\b', text, re.I)
    scripts_sec = section(pyproject, 'project.scripts') or section(pyproject, 'tool.poetry.scripts')
    entry = re.search(r'^\s*"?([A-Za-z0-9_.-]+)"?\s*=', scripts_sec, re.M)
    mains = sorted(f for f in files if os.path.basename(f) == '__main__.py' and f.count(os.sep) == 1)
    if has('manage.py'):
        kinds.append(('web', 'manage.py (django)'))
        frameworks.append('django')
        up_line = f'exec {py} manage.py runserver "127.0.0.1:$PORT"'
    elif web:
        kinds.append(('web', f'python dependencies mention {web.group(1)}'))
        frameworks.append(web.group(1).lower())
    elif entry or mains:
        kinds.append(('cli', 'pyproject [project.scripts]' if entry else mains[0]))
        if entry and py in ('uv run python', 'poetry run python'):
            smoke = f'{py.rsplit(" ", 1)[0]} {entry.group(1)} --help'
        elif entry and has('.venv', 'bin', entry.group(1)):
            smoke = f'.venv/bin/{entry.group(1)} --help'
        elif mains:
            smoke = f'{py} -m {os.path.dirname(mains[0])} --help'
        else:
            notes.append(f'CLI "{entry.group(1)}" is not installed in a venv this script can see, '
                         f'so no smoke run was generated')
    else:
        kinds.append(('library', 'python project with no entrypoint or web framework'))

# ---- go ----
if has('go.mod'):
    ecos.append('go')
    gates.append(('lint', 'go vet ./...', 'go.mod'))
    if any(f.endswith('_test.go') for f in files):
        gates.append(('test', 'go test ./...', '*_test.go files'))
    else:
        todos.append('no Go tests (*_test.go) -- `go test ./...` would pass having run nothing; write a test')
    mains = [f for f in files if f.endswith('.go') and not f.endswith('_test.go')
             and re.search(r'^package main\b', read(f), re.M)]
    if mains:
        d = os.path.dirname(sorted(mains, key=lambda f: (f.count(os.sep), f))[0])
        target = '.' if not d else './' + d
        if any('ListenAndServe' in read(f) for f in mains):
            kinds.append(('web', f'package main calling ListenAndServe ({target})'))
            up_line = f'exec go run {target}'
            notes.append('the Go server must listen on $PORT (os.Getenv("PORT")); '
                         'verify.sh says "never answered" if it does not')
        else:
            kinds.append(('cli', f'package main in {target}'))
            smoke = f'go run {target} --help'
    else:
        kinds.append(('library', 'go module with no package main'))

# ---- rust ----
if has('Cargo.toml'):
    ecos.append('rust')
    gates.append(('typecheck', 'cargo check --all-targets', 'Cargo.toml'))
    rs = [f for f in files if f.endswith('.rs')]
    if any('#[test]' in read(f) for f in rs) or has('tests'):
        gates.append(('test', 'cargo test', '#[test] / tests/'))
    else:
        todos.append('no Rust tests (#[test] or tests/) -- `cargo test` would pass having run nothing; write a test')
    main = read('src', 'main.rs')
    if main and re.search(r'\b(axum|actix_web|rocket|warp|hyper|tide|poem)\b', main):
        kinds.append(('web', 'src/main.rs uses a web framework'))
        up_line = 'exec cargo run --quiet'
        notes.append('the Rust server must listen on $PORT; verify.sh says "never answered" if it does not')
    elif main or has('src', 'bin'):
        kinds.append(('cli', 'src/main.rs' if main else 'src/bin/'))
        smoke = 'cargo run --quiet -- --help'
    else:
        kinds.append(('library', 'Cargo.toml with src/lib.rs only'))

# ---- Makefile: fills only the gates nothing else supplied ----
mk = read('Makefile') or read('makefile')
if mk:
    if not ecos:
        ecos.append('make')
        # No ecosystem to say what the project is: its Makefile targets are
        # the harness (tests-only shape). A Makefile with no usable target
        # still ends in the "no test command" TODO below.
        kinds.append(('library', 'only a Makefile: its targets are the harness'))
    labels = {g[0] for g in gates}
    for target, label in (('test', 'test'), ('lint', 'lint'), ('typecheck', 'typecheck'), ('check', 'typecheck')):
        if label not in labels and re.search(r'^' + target + r'\s*:', mk, re.M):
            gates.append((label, f'make {target}', f'Makefile target {target}'))
            labels.add(label)
    if 'test' in labels:
        # A Makefile test target supersedes the "no tests found" TODO from an
        # ecosystem whose own detection could not see them.
        todos[:] = [t for t in todos if not t.startswith('no ') or 'test' not in t]

# ---- kind ----
why = ''
if kind_over:
    kind, why = kind_over, '--kind'
elif not kinds:
    kind = 'unknown'
    if not ecos:
        todos.append('no package.json, pyproject.toml, setup.py, go.mod, Cargo.toml or Makefile -- '
                     'write the commands that prove this project works, and re-run with --kind')
else:
    order = ['web', 'unknown', 'cli', 'library']
    kind, why = sorted(kinds, key=lambda k: order.index(k[0]))[0]
    if kind == 'unknown':
        todos.append(why)
if dev_over:
    up_line = 'exec ' + dev_over
if kind == 'web' and not up_line:
    todos.append('no command to serve this web app was detected -- re-run with '
                 '--dev \'<command that serves on "$PORT">\'')
if kind in ('cli', 'library') and not any(g[0] == 'test' for g in gates) \
        and not any('test' in t for t in todos):
    todos.append('no test command found -- a harness with nothing to run cannot verify anything; '
                 'add the command that proves this project works')

# Order: lint, typecheck, test -- cheapest first, so a failure is reported fast.
rank = {'lint': 0, 'typecheck': 1, 'test': 2}
gates.sort(key=lambda g: rank.get(g[0], 9))
q = shlex.quote
print(f'NAME_DETECTED={q(name)}')
print(f'NAME_DETECTED_WHY={q(name_why)}')
print(f'KIND={q(kind)}')
print(f'KIND_WHY={q(why)}')
print(f'ECOS={q(" ".join(ecos))}')
print(f'FRAMEWORKS={q(" ".join(frameworks))}')
print(f'UP_LINE={q(up_line)}')
print(f'SMOKE={q(smoke if kind == "cli" else "")}')
print(f'GATES={q(chr(10).join(chr(9).join(g) for g in gates))}')
print(f'TODOS={q(chr(10).join(todos))}')
print(f'NOTES={q(chr(10).join(notes))}')
PY
}
DETECTED="$(detect)" || { echo "scaffold: detection failed (python3 above)" >&2; exit 2; }
eval "$DETECTED"
if [ -z "$NAME" ]; then NAME="$NAME_DETECTED"; NAME_WHY="$NAME_DETECTED_WHY"; fi
if [ -z "$NAME" ]; then
  echo "scaffold: nothing to name the skill by (no project name, and the folder name has no letters or digits) -- pass --name" >&2; exit 2
fi

lines() { [ -n "$1" ] && printf '%s\n' "$1" | sed "s/^/$2/"; return 0; }
report() {
  echo "  name      : $NAME ($NAME_WHY)"
  echo "  kind      : $KIND${KIND_WHY:+ ($KIND_WHY)}"
  echo "  ecosystem : ${ECOS:-none detected}${FRAMEWORKS:+ ($FRAMEWORKS)}"
  if [ -n "$GATES" ]; then printf '%s\n' "$GATES" | awk -F'\t' '{printf "  %-10s: %s   [%s]\n", $1, $2, $3}'
  else echo "  gates     : none detected"; fi
  [ "$KIND" = web ] && echo "  launch    : ${UP_LINE:-none detected}"
  [ -n "$SMOKE" ] && echo "  smoke     : $SMOKE"
  lines "$NOTES" '  note      : '
  lines "$TODOS" '  TODO      : '
}

if [ -n "$DRY" ]; then
  echo "detected (dry run, nothing written): $REPO"
  report
  [ -z "$TODOS" ] || exit 3
  exit 0
fi

HARNESS="$REPO/.claude/verify-harness"
SK="$REPO/.claude/skills/verify-$NAME"
if [ -z "$FORCE" ]; then
  for f in "$HARNESS" "$SK"; do
    if [ -e "$f" ]; then
      echo "scaffold: ${f#$REPO/} already exists -- refusing to overwrite a harness someone may have edited. Re-run with --force to regenerate it (scenarios are kept)." >&2
      exit 2
    fi
  done
fi

# --- port: allocated from the machine-wide registry, never guessed ----------
# Only an app needs one. `ports.py add` is idempotent: re-scaffolding never
# moves a repo's port.
PORT=""
if [ "$KIND" = web ]; then
  PORT="$(python3 "$SCRIPTS/ports.py" add "$REPO")" || { echo "scaffold: could not allocate a port block for $REPO" >&2; exit 2; }
  case "$PORT" in ''|*[!0-9]*) echo "scaffold: registry returned a non-number: '$PORT'" >&2; exit 2 ;; esac
fi

# Per-checkout state stays out of the repo's history: the Stop gate's state and
# the optional local overrides. .git/info/exclude is per-clone and never
# committed, so this edits no tracked file -- and nothing generated may DEPEND
# on what it hides, because a fresh clone has none of it.
EXCLUDE="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$EXCLUDE" in /*) ;; *) EXCLUDE="$REPO/$EXCLUDE" ;; esac
EXCLUDE="$EXCLUDE/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
if ! grep -q 'bendit verification state' "$EXCLUDE" 2>/dev/null; then
  printf '\n# bendit verification state -- local only, never this repo'"'"'s history.\n.claude/.verify-state/\n.env.verify.local\n' >> "$EXCLUDE"
fi

# --- .claude/verify-harness -------------------------------------------------
mkdir -p "$REPO/.claude"
{
  cat <<HEOF
# What verifies $NAME. The Stop gate (bendit's require-verification.py)
# runs this file when code changed and nothing has verified it: every line that
# is not a comment, as one sh script, from the repo root. Exit 0 means verified;
# anything else keeps the turn from ending as "done". /verify runs it too when
# the repo has no app harness.
#
# Generated by bendit's scaffold-verification-skill.sh -- shape: $KIND${KIND_WHY:+ ($KIND_WHY)}.
# It is yours to edit, and it is meant to be committed. Keep the one rule it was
# generated under: exit non-zero whenever anything is unverified, and never pass
# having checked nothing. See the kit's templates/verify-harness for examples.
set -e
HEOF
  if [ -n "$TODOS" ]; then
    echo
    echo "# TODO: each line below stops this harness until you replace it with the"
    echo "# real check it names. Delete a line only once its check exists."
    printf '%s\n' "$TODOS" | python3 -c '
import shlex, sys
for t in sys.stdin.read().splitlines():
    print("echo %s >&2; exit 2" % shlex.quote("TODO(bendit): " + t))'
  fi
  if [ -n "$GATES" ]; then
    echo
    printf '%s\n' "$GATES" | awk -F'\t' '{ printf "# %s  [%s]\n%s\n", $1, $3, $2 }'
  fi
  if [ -n "$SMOKE" ]; then
    cat <<HEOF

# CLI smoke: the entrypoint starts and prints its usage. If it has no --help,
# replace this with an invocation that exercises real behaviour.
$SMOKE >/dev/null
HEOF
  fi
  if [ "$KIND" = web ]; then
    cat <<HEOF

# The app: \`verify\` finds bendit -- BENDIT_KIT_ROOT, else
# CLAUDE_PLUGIN_ROOT when it is this kit, else a copy vendored in this repo,
# else the newest installed copy -- and runs its verify.sh: start the app on
# this repo's registry port, wait until it SERVES (a 5xx is not ready), run
# doctor, run every scenario in .claude/skills/verify-$NAME/scenarios/, tear it
# down. \`.claude/skills/verify-$NAME/bin/verify-$NAME kit\` says which copy it found.
"\$(git rev-parse --show-toplevel)/.claude/skills/verify-$NAME/bin/verify-$NAME" verify
HEOF
  fi
} > "$HARNESS"

# --- the app harness (web only) ----------------------------------------------
if [ "$KIND" = web ]; then
  mkdir -p "$SK/bin" "$SK/lib" "$SK/scenarios" "$SK/artifacts"
  echo '*' > "$SK/artifacts/.gitignore"
  # COMMITTED, and documentation only: nothing reads it. The harness works with
  # no env file at all; .env.verify.local (local, git-excluded) is where a
  # checkout puts overrides. Never overwritten: it may hold the project's keys.
  if [ ! -f "$REPO/.env.verify.example" ]; then
    cat > "$REPO/.env.verify.example" <<ENVEOF
# What the verify harness (.claude/skills/verify-$NAME) lets a checkout override.
# Commit this file. To override anything, copy it to .env.verify.local (local
# only: .git/info/exclude keeps it out of git) and uncomment what you need. With
# no .env.verify.local the harness runs on its defaults -- a fresh clone needs
# nothing here.
#
# \`up\` loads .env.verify.local, when it exists, into the app's environment --
# never .env or .env.local, so a verify run cannot pick up real credentials by
# accident. Every *_URL and every scheme:// value in it must point at this
# machine (loopback: 127.0.0.1, localhost, ::1): doctor refuses anything else. Set
# external services to invalid placeholders so an accidental call fails loudly.
#
# PORT is NOT read from this file: it comes from the machine's port registry
# (bendit's ports.py; this repo's default is $PORT), so two checkouts
# never fight over one port. Set PORT=... in the shell to run by hand elsewhere.
#
# App settings, for example:
# DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/app_verify
# API_BASE_URL=http://127.0.0.1:9/unused
#
# Harness knobs are read from the shell, not this file:
#   VERIFY_KEEP_RUNS=10       evidence runs kept per scenario
#   PROBE_TIMEOUT=10          seconds per probe request
#   BENDIT_APP_WAIT=90   seconds verify.sh waits for the app to serve
ENVEOF
  fi

  BIN="$SK/bin/verify-$NAME"
  cat > "$BIN.tmpl" <<'BINEOF'
#!/usr/bin/env bash
# App harness for @@NAME@@. Generated by bendit; edit freely.
#   verify [scenario]             find bendit, run its verify.sh (all of it)
#   kit                           say which bendit copy verify would use
#   doctor                        read-only preflight; non-zero with a reason
#   up                            serve the app on $PORT (+ .env.verify.local if present)
#   drive <scenario> [--base URL] run scenarios/<scenario>.sh, leave evidence
# scripts/verify.sh drives doctor/up/drive in order; run them by hand to debug.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# The checkout under test is the one you stand in, found through git -- never
# this script's own path, which for a harness shared by symlink between
# worktrees is the CANONICAL checkout: a worktree run would verify the wrong
# code while reporting success. Refuse (exit 2, never guess) unless the
# checkout's own .claude/skills/verify-@@NAME@@ resolves to this same harness.
REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO" ]; then
  echo "refusing: not inside a git checkout (cwd: $PWD), so the repo under test is unknown" >&2
  exit 2
fi
MINE="$(cd "$HERE" && pwd -P)"
THEIRS="$(cd "$REPO/.claude/skills/verify-@@NAME@@" 2>/dev/null && pwd -P)"
if [ -z "$THEIRS" ]; then
  echo "refusing: no harness at $REPO/.claude/skills/verify-@@NAME@@ (cwd: $PWD) -- looked for this harness ($MINE) in the checkout you are standing in" >&2
  exit 2
fi
if [ "$THEIRS" != "$MINE" ]; then
  echo "refusing: $REPO/.claude/skills/verify-@@NAME@@ resolves to $THEIRS, but this harness is $MINE -- running it here would verify a different checkout than the one you are in" >&2
  exit 2
fi
cd "$REPO" || exit 1
# EXPORTED: a dev server reads PORT from its environment. verify.sh passes the
# registry's port for this checkout; the default is the main checkout's.
export PORT="${PORT:-@@PORT@@}"
SELF="verify-@@NAME@@"
VERIFY_ENV="$REPO/.env.verify.local"
STATE="$REPO/.claude/.verify-state"
SIDECAR="$STATE/server-$PORT"
# Evidence runs kept per scenario; nothing else ever deletes one.
KEEP="${VERIFY_KEEP_RUNS:-10}"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi; }
# The pid listening on $1. lsof is missing on some Linux images, so ss is the
# fallback; with neither, the answer is "unknown" and callers refuse.
have_listener_tool() { command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1; }
listener_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
  fi
}

# --- Guard 1: no URL may leave this machine -----------------------------------
# A verify env that carries one live external URL lets a scenario pass by
# reaching production. Every *_URL (and any value that is a scheme://) must
# resolve to loopback. The host is PARSED, not pattern-matched:
# `http://localhost@evil.example` and `localhost.evil.example` both begin with
# "localhost" and both leave the machine. Prints NAME(host) for each offender.
nonloopback() {
  local line name val rest host
  [ -f "$VERIFY_ENV" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; line="${line#export }"
    case "$line" in ''|'#'*) continue;; esac
    case "$line" in *=*) ;; *) continue;; esac
    name="${line%%=*}"; val="${line#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val#[\"\']}"; val="${val%[\"\']}"
    [ -n "$val" ] || continue
    if [[ "$name" != *_URL ]] && ! [[ "$val" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then continue; fi
    rest="${val#*://}"; rest="${rest%%[/?#]*}"; rest="${rest##*@}"
    if [ "${rest#\[}" != "$rest" ]; then host="${rest#\[}"; host="${host%%]*}"; else host="${rest%%:*}"; fi
    case "$host" in
      127.0.0.1|localhost|::1) ;;
      *) printf '%s(%s) ' "$name" "$host";;
    esac
  done < "$VERIFY_ENV"
}

# --- Guard 2: the check must be about the process it reports on ---------------
# Validating the env file ON DISK while reporting on whatever listens on $PORT
# passes against a server started hours earlier with a different env. `up`
# records what it started; doctor and drive refuse unless the listener IS that
# process, in this checkout, started from the env file as it is now, built from
# the code now.
envhash() { if [ -f "$VERIFY_ENV" ]; then sha256 < "$VERIFY_ENV"; else echo absent; fi; }
# HEAD plus a hash of uncommitted changes (tracked diff + the untracked file
# LIST). A repo with no commit yields "nocommit", never an empty field.
codestate() {
  printf '%s %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo nocommit)" \
    "$({ git diff HEAD 2>/dev/null; git status --porcelain --untracked-files=all 2>/dev/null | grep '^??'; } | sha256 | cut -c1-12)"
}
descends() {   # is pid $1 the process $2 or one of its descendants?
  local p="$1"
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    if [ "$p" = "$2" ]; then return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}
# A missing sidecar is a REFUSAL, not a pass: without it the server's env is unknown.
sidecar_check() {   # prints ok/FAIL lines; returns non-zero on any FAIL
  local f=0 spid srepo shash scode sverb now lpid
  if [ ! -f "$SIDECAR" ]; then
    echo "FAIL  no sidecar for :$PORT -- this server was not started by '$SELF up', so its env is unknown"; return 1
  fi
  spid=$(sed -n 's/^pid=//p' "$SIDECAR"); srepo=$(sed -n 's/^repo=//p' "$SIDECAR"); shash=$(sed -n 's/^envhash=//p' "$SIDECAR")
  scode=$(sed -n 's/^code=//p' "$SIDECAR"); sverb=$(sed -n 's/^verb=//p' "$SIDECAR"); now=$(codestate)
  if kill -0 "$spid" 2>/dev/null; then echo "ok    sidecar pid $spid is alive"
  else echo "FAIL  sidecar pid $spid is gone -- the server that sidecar describes no longer exists"; f=1; fi
  if ! have_listener_tool; then
    echo "FAIL  neither lsof nor ss is installed, so which process listens on :$PORT cannot be checked"; f=1
  else
    lpid=$(listener_pid "$PORT")
    if [ -n "$lpid" ] && [ -n "$spid" ] && descends "$lpid" "$spid"; then echo "ok    listener on :$PORT (pid $lpid) was started by sidecar pid $spid"
    else echo "FAIL  listener on :$PORT (pid ${lpid:-none}) is not the process the sidecar recorded (${spid:-none})"; f=1; fi
  fi
  if [ "$srepo" = "$REPO" ]; then echo "ok    server was started from this checkout"
  else echo "FAIL  server was started from '$srepo', not $REPO"; f=1; fi
  if [ "$shash" = "$(envhash)" ]; then echo "ok    server was started with .env.verify.local exactly as it is on disk$([ -f "$VERIFY_ENV" ] || echo ' (absent: no overrides)')"
  else echo "FAIL  .env.verify.local changed since this server started -- it is running a different config; restart with: $SELF up"; f=1; fi
  if [ -z "$scode" ]; then echo "FAIL  sidecar records no code state -- which commit it serves is unknown; restart with: $SELF up"; f=1
  elif [ "$scode" = "$now" ]; then echo "ok    server was started from the code checked out now ($now)"
  elif [ "$sverb" = up ]; then echo "note  code moved since start ($scode -> $now); a dev server hot-reloads, so this is expected"
  else echo "FAIL  code moved since this '$sverb' build ($scode -> $now) -- it serves older code than this checkout; restart it"; f=1; fi
  return "$f"
}
# drive refuses with doctor's own reasons, not a bare "doctor failed".
preflight() {
  local out; out=$(doctor) && return 0
  printf '%s\n' "$out" | grep '^FAIL' >&2
  echo "refusing: doctor failed for :$PORT (full output: PORT=$PORT $SELF doctor)" >&2
  exit 2
}

# --- Guard 3: evidence does not accumulate forever ----------------------------
# Keep the newest $2 runs of scenario $1 and delete the rest; $3 is the run being
# written and is NEVER deleted, even if clock skew sorts it out of the newest $2.
# Names are <scenario>-<YYYYMMDDTHHMMSS>, which sorts chronologically as text.
# The match is anchored: pruning scenario "a" must never touch "a-b-<ts>".
prune_runs() {
  local sc="$1" keep="$2" cur="$3" d n=0 gone=0 pat
  pat="^$(printf '%s' "$sc" | sed 's/[][\.*^$/+?(){}|]/\\&/g')-[0-9]{8}T[0-9]{6}\$"
  while IFS= read -r d; do
    if [ "$HERE/artifacts/$d" = "$cur" ] || [ "$n" -lt "$keep" ]; then n=$((n+1)); continue; fi
    rm -rf "${HERE:?}/artifacts/${d:?}"
    if [ -e "$HERE/artifacts/$d" ]; then echo "FAIL  could not prune $d" >&2; return 1; fi
    echo "pruned: $d"; gone=$((gone+1))
  done < <(/bin/ls -1 "$HERE/artifacts" | grep -E "$pat" | sort -r)
  echo "prune: $sc kept $n, removed $gone (VERIFY_KEEP_RUNS=$keep)"
}

doctor() {
  local fail=0 ext
  # Optional. Absent means no overrides -- the state of every fresh clone -- and
  # the app still never sees .env/.env.local through this harness.
  if [ ! -f "$VERIFY_ENV" ]; then echo "ok    no .env.verify.local: no overrides, the app runs on its defaults (see .env.verify.example)"
  else
    ext=$(nonloopback)
    if [ -z "$ext" ]; then echo "ok    every URL in .env.verify.local is loopback"
    else echo "FAIL  non-loopback URL(s) would reach a real service: $ext"; fail=1; fi
  fi
  if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT"; then
    echo "ok    app answering on :$PORT"
    sidecar_check || fail=1
  else
    echo "FAIL  nothing on :$PORT -- run: $SELF up"; fail=1
  fi
  if [ "$fail" -eq 0 ]; then echo "doctor: PASS"; else echo "doctor: FAIL"; fi
  return "$fail"
}

# --- Where bendit is ---------------------------------------------------
# `verify` needs the kit's verify.sh. A harness that only works when someone
# exported a variable fails on every fresh clone and every plain terminal, so it
# looks, in order, and stops at the first:
#   1. $BENDIT_KIT_ROOT -- explicit. Set but wrong is REFUSED: silently
#      running some other copy is not what the person who set it meant.
#   2. $CLAUDE_PLUGIN_ROOT, only when it IS bendit: every plugin's
#      hooks get one, and another kit's verify.sh is not this one.
#   3. a copy vendored in this repo (.claude/vendor/bendit): the repo
#      pinned it, so it beats whatever this machine happens to have installed.
#   4. the newest installed copy, ${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/cache.
is_kit() { [ -f "$1/scripts/verify.sh" ] && grep -qE '"name"[[:space:]]*:[[:space:]]*"bendit"' "$1/.claude-plugin/plugin.json" 2>/dev/null; }
# Version order (0.10.0 after 0.9.0). Not every sort has -V; the fallback
# compares the first three dotted fields numerically.
vsort() { if printf '1\n' | sort -V >/dev/null 2>&1; then sort -V; else sort -t. -k1,1n -k2,2n -k3,3n; fi; }
find_kit() {   # prints "<dir><TAB><where it came from>", or refuses (2) listing every place searched
  local d f best cache="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/cache"
  if [ -n "${BENDIT_KIT_ROOT:-}" ]; then
    if is_kit "$BENDIT_KIT_ROOT"; then printf '%s\tBENDIT_KIT_ROOT\n' "$BENDIT_KIT_ROOT"; return 0; fi
    echo "refusing: BENDIT_KIT_ROOT=$BENDIT_KIT_ROOT is not the bendit plugin folder (it needs scripts/verify.sh and a .claude-plugin/plugin.json named bendit) -- fix it or unset it" >&2
    return 2
  fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && is_kit "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\tCLAUDE_PLUGIN_ROOT\n' "$CLAUDE_PLUGIN_ROOT"; return 0
  fi
  for d in "$REPO/.claude/vendor/bendit/plugins/bendit" "$REPO/.claude/vendor/bendit"; do
    if is_kit "$d"; then printf '%s\tvendored in this repo\n' "$d"; return 0; fi
  done
  best=$(for f in "$cache"/*/bendit/*/scripts/verify.sh; do
           [ -f "$f" ] || continue
           d="${f%/scripts/verify.sh}"; printf '%s\t%s\n' "${d##*/}" "$d"
         done | vsort | tail -1 | cut -f2)
  if [ -n "$best" ]; then printf '%s\tinstalled plugin, newest in %s\n' "$best" "$cache"; return 0; fi
  {
    echo "refusing: cannot find bendit's scripts/verify.sh. Searched, in order:"
    echo "  \$BENDIT_KIT_ROOT  unset"
    echo "  \$CLAUDE_PLUGIN_ROOT    ${CLAUDE_PLUGIN_ROOT:-unset}${CLAUDE_PLUGIN_ROOT:+ (not bendit)}"
    echo "  $REPO/.claude/vendor/bendit/plugins/bendit"
    echo "  $REPO/.claude/vendor/bendit"
    echo "  $cache/*/bendit/*/scripts/verify.sh"
    echo "Install the plugin (claude plugin install bendit@bendit), or set BENDIT_KIT_ROOT to its folder."
  } >&2
  return 2
}

case "${1:-help}" in
  kit)    k=$(find_kit) || exit 2
          printf 'bendit: %s  (%s)\n' "${k%%$'\t'*}" "${k#*$'\t'}" ;;
  verify) shift
          k=$(find_kit) || exit 2
          echo "$SELF: using bendit at ${k%%$'\t'*} (${k#*$'\t'})" >&2
          exec bash "${k%%$'\t'*}/scripts/verify.sh" "$@" ;;
  doctor) doctor ;;
  up)     if have_listener_tool; then
            if [ -n "$(listener_pid "$PORT")" ]; then echo "refusing: :$PORT is already in use -- pick another PORT=" >&2; exit 2; fi
          elif curl -s -o /dev/null --max-time 2 "http://localhost:$PORT"; then
            echo "refusing: :$PORT is already answering -- pick another PORT=" >&2; exit 2
          fi
          # Overrides, when there are any. PORT is put back afterwards: the
          # port was checked free above, and serving on another would leave
          # verify.sh waiting on this one.
          if [ -f "$VERIFY_ENV" ]; then
            ext=$(nonloopback)
            if [ -n "$ext" ]; then echo "refusing: .env.verify.local has non-loopback URL(s) that would reach a real service: $ext" >&2; exit 2; fi
            keep_port="$PORT"; set -a; . "$VERIFY_ENV"; set +a; export PORT="$keep_port"
          fi
          # $$ survives exec, so this pid is the process that will own the listener.
          mkdir -p "$STATE"
          printf 'pid=%s\nport=%s\nrepo=%s\nenvhash=%s\ncode=%s\nverb=%s\nstarted=%s\n' \
            "$$" "$PORT" "$REPO" "$(envhash)" "$(codestate)" up "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SIDECAR"
          @@UP_LINE@@ ;;
  drive)  shift
          want="${1:?usage: $SELF drive <scenario> [--base URL]}"; shift
          base="http://localhost:$PORT"
          while [ $# -gt 0 ]; do
            case "$1" in
              --base) base="${2:?--base needs a URL}"; shift 2 ;;
              *) echo "refusing: unknown drive option '$1'" >&2; exit 2 ;;
            esac
          done
          sc="$want"; [ -f "$sc" ] || sc="$HERE/scenarios/$want.sh"
          [ -f "$sc" ] || { echo "refusing: no scenario '$want' in $HERE/scenarios/" >&2; exit 2; }
          case "$KEEP" in ''|*[!0-9]*|0) echo "refusing: VERIFY_KEEP_RUNS must be a positive integer (got '$KEEP')" >&2; exit 2;; esac
          preflight
          name="$(basename "${sc%.sh}")"
          out="$HERE/artifacts/$name-$(date +%Y%m%dT%H%M%S)"
          mkdir -p "$out"; : > "$out/checks.log"
          BASE_URL="$base" OUT="$out" PROBE="$HERE/lib/probe.sh" bash "$sc" > "$out/output.log" 2>&1; rc=$?
          cat "$out/output.log"
          nok=$(grep -c '^ok ' "$out/checks.log"); nbad=$(grep -c '^FAIL ' "$out/checks.log")
          # VERIFIED needs all three: the script exited 0, it made at least one
          # check, and no check failed. A scenario that checked nothing is not
          # a pass, however cleanly it exited.
          if [ "$rc" -eq 0 ] && [ "$nok" -gt 0 ] && [ "$nbad" -eq 0 ]; then
            verdict="VERDICT: VERIFIED ($nok checks)"
          elif [ "$nok" -eq 0 ] && [ "$nbad" -eq 0 ]; then
            verdict="VERDICT: NOT VERIFIED -- the scenario made no checks (use the helpers in lib/probe.sh)"
          else
            verdict="VERDICT: NOT VERIFIED -- $nbad failed check(s), script exit $rc"
          fi
          printf '%s\nscenario: %s\nbase: %s\ncode: %s\n' "$verdict" "$sc" "$base" "$(codestate)" > "$out/verdict.txt"
          echo "$verdict"; echo "evidence: $out"
          case "$verdict" in *": VERIFIED"*) rc=0 ;; *) rc=1 ;; esac
          # Prune after the run, excluding it. A prune failure must not hide the
          # verdict, but it must not pass silently either.
          if ! prune_runs "$name" "$KEEP" "$out" >&2; then
            if [ "$rc" -eq 0 ]; then rc=2; fi
          fi
          exit "$rc" ;;
  *)      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
BINEOF
  # Placeholders are filled by literal replacement, so nothing in a --dev
  # command is ever re-read as shell by this script.
  python3 - "$BIN.tmpl" "$BIN" "$NAME" "$PORT" "$UP_LINE" <<'PY'
import sys
src, dst, name, port, up = sys.argv[1:6]
if not up:
    up = ('echo "refusing: no command to serve this app was detected when this harness '
          'was generated -- re-scaffold with --dev, or write this line by hand" >&2; exit 2')
s = open(src).read().replace('@@NAME@@', name).replace('@@PORT@@', port).replace('@@UP_LINE@@', up)
open(dst, 'w').write(s)
PY
  rm -f "$BIN.tmpl"
  chmod +x "$BIN"

  cat > "$SK/lib/probe.sh" <<'PROBEEOF'
# Probe helpers for scenarios. A scenario sources this file:  . "$PROBE"
# It runs with BASE_URL (the app), PORT, and OUT (this run's evidence folder).
#
# Every helper records one line in $OUT/checks.log -- "ok <what>" or
# "FAIL <what>" -- and returns non-zero on FAIL. The harness counts that log:
# a scenario is VERIFIED only if it exits 0, recorded at least one ok, and
# recorded no FAIL. Response bodies are kept in $OUT as evidence.
: "${BASE_URL:?run scenarios through the harness: verify-<name> drive <scenario>}"
: "${OUT:?run scenarios through the harness: verify-<name> drive <scenario>}"
_probe_n=0

_record() { printf '%s %s\n' "$1" "$2" >> "$OUT/checks.log"; printf '%s %s\n' "$1" "$2"; [ "$1" = ok ]; }
_fetch() { # <path>  -> $_code, $_body
  _probe_n=$((_probe_n+1)); _body="$OUT/response-$_probe_n.txt"
  _code=$(curl -s -o "$_body" -w '%{http_code}' --max-time "${PROBE_TIMEOUT:-10}" "$BASE_URL$1" 2>/dev/null)
  _code="${_code:-000}"
}

# expect_ok <path>               status is 2xx or 3xx
expect_ok() {
  _fetch "$1"
  case "$_code" in [23][0-9][0-9]) _record ok "GET $1 -> $_code" ;; *) _record FAIL "GET $1 -> $_code, wanted 2xx/3xx" ;; esac
}
# expect_status <path> <regex>   e.g. 404, '30[12]', '2[0-9][0-9]'
expect_status() {
  _fetch "$1"
  if printf '%s\n' "$_code" | grep -qE "^($2)\$"; then _record ok "GET $1 -> $_code"
  else _record FAIL "GET $1 -> $_code, wanted $2"; fi
}
# expect_text <path> <text>      2xx/3xx and the body contains text
expect_text() {
  _fetch "$1"
  case "$_code" in [23][0-9][0-9]) ;; *) _record FAIL "GET $1 -> $_code, wanted a page containing '$2'"; return 1 ;; esac
  if grep -qF -- "$2" "$_body"; then _record ok "GET $1 contains '$2'"
  else _record FAIL "GET $1 does not contain '$2' (body: $_body)"; fi
}
# expect_no_text <path> <text>   2xx/3xx and the body does NOT contain text
expect_no_text() {
  _fetch "$1"
  case "$_code" in [23][0-9][0-9]) ;; *) _record FAIL "GET $1 -> $_code, wanted a page without '$2'"; return 1 ;; esac
  if grep -qF -- "$2" "$_body"; then _record FAIL "GET $1 contains '$2' (body: $_body)"
  else _record ok "GET $1 does not contain '$2'"; fi
}
# check <description> <command...>   any other assertion; passes when the command exits 0
check() {
  local what="$1"; shift
  if "$@" >> "$OUT/check-output.log" 2>&1; then _record ok "$what"; else _record FAIL "$what (output: $OUT/check-output.log)"; fi
}
PROBEEOF

  if [ -z "$(/bin/ls -A "$SK/scenarios" 2>/dev/null)" ]; then
    cat > "$SK/scenarios/smoke.sh" <<'SCEOF'
# Smoke: the app serves its root page. Generated -- a floor, not a proof that a
# feature works. Add one scenario per behaviour you need to trust (see SKILL.md).
. "$PROBE"
expect_ok /
SCEOF
  fi

  FW="${FRAMEWORKS:-unknown framework}"
  cat > "$SK/SKILL.md" <<MDEOF
---
name: verify-$NAME
description: Prove a change to $NAME works in the running app - launch it, probe it, leave evidence. Use for "verify this", "prove it works", or before shipping.
allowed-tools: Bash(\${CLAUDE_SKILL_DIR}/bin/verify-$NAME *)
---

# verify-$NAME

Empirical verification for \`$NAME\` ($FW, registry port **$PORT**). Evidence, not
assertion. The one-command path is \`/verify\`; the verbs below are for debugging.

## Launch and doctor

\`\`\`bash
bin/verify-$NAME verify    # everything: up, doctor, every scenario, teardown
bin/verify-$NAME kit       # which bendit copy \`verify\` uses
bin/verify-$NAME up        # serves on \$PORT (default $PORT)
bin/verify-$NAME doctor    # always before trusting a scenario
\`\`\`

Nothing local is required: a fresh clone verifies as it is. \`up\` adds
\`.env.verify.local\` to the app's environment when that file exists (optional
overrides; \`.env.verify.example\` lists them) and never reads \`.env\` or
\`.env.local\`. Doctor refuses when any URL in it is not loopback, and when the server on the port is not the process \`up\` started
from this checkout, with the env file as it is now, from the code checked out now.
A server you started by hand has no record and is refused.

## Scenarios

\`scenarios/<name>.sh\` is a bash script run with \`BASE_URL\`, \`PORT\` and \`OUT\`.
It sources the probe helpers and makes checks:

\`\`\`bash
. "\$PROBE"
expect_ok /                      # 2xx or 3xx
expect_status /admin '30[12]'    # logged out -> redirected
expect_text /pricing 'Pro plan'
expect_no_text / 'Internal Server Error'
check "health JSON says ok" sh -c 'curl -s "\$BASE_URL/health" | grep -q "\"ok\""'
\`\`\`

\`bin/verify-$NAME drive <name>\` prints \`VERDICT: VERIFIED\` only when the script
exits 0, made at least one check, and no check failed.

Prove a denial as well as a success: a harness that only ever passes cannot be
told apart from a broken one.

## Evidence

\`artifacts/<scenario>-<timestamp>/\`: \`verdict.txt\`, \`checks.log\`, \`output.log\`,
response bodies. A fresh directory per run; the newest 10 per scenario are kept
(\`VERIFY_KEEP_RUNS=n\`). Gitignored.

## Coverage

What each check covers, and the commit at which someone last read that code and
confirmed the check still describes it. \`Synced\` is **not** "when it last passed".

| Check | Covers | Synced |
| --- | --- | --- |
| \`smoke\` | the app's root route | |
| \`doctor\` | \`.env.verify.local\` (if any), the launch command | |

Before trusting a row: \`git log --oneline <synced>..HEAD -- <covers>\`. Empty means
the row is current; otherwise read that code before you believe the check.

## When a check fails: drift or defect

1. **Update from the code, not from the result.** Open what \`Covers\` names first.
2. **Re-falsify.** After any edit that makes a check pass, break the thing it
   checks and confirm it catches that.
3. **Never edit product code in a maintenance pass.** Report the regression.

A pass ends in exactly one of \`clean\` / \`changed\` / \`blocked\`. \`blocked\` is not a pass.

## TODO -- this harness is a scaffold until these are done

- [ ] Write one scenario per behaviour that matters, including a denial
- [ ] Fill the Coverage table, with a \`Synced\` sha per row
- [ ] Run \`/verify\` end to end and read the evidence it left
MDEOF
fi

# --- report ------------------------------------------------------------------
echo "scaffolded: $REPO"
echo "  harness   : .claude/verify-harness"
[ "$KIND" = web ] && echo "  app       : .claude/skills/verify-$NAME/ (port $PORT)"
[ "$KIND" = web ] && echo "  overrides : .env.verify.example (commit it; .env.verify.local is optional and local)"
report
# A committed example that the repo's own .gitignore swallows (a bare `.env*`
# rule does) would never reach a clone. Said, not silently fixed: .gitignore is
# the project's file.
if [ "$KIND" = web ] && git -C "$REPO" check-ignore -q .env.verify.example 2>/dev/null; then
  echo "  WARNING   : .env.verify.example is git-ignored here ($(git -C "$REPO" check-ignore -v .env.verify.example | cut -f1)); add '!.env.verify.example' to .gitignore so clones get it"
fi
# The Stop gate runs a harness only once the PERSON has approved its exact
# content, so a cloned repo cannot get code run unasked. Say how, every time.
echo
echo "  approve   : the Stop gate will not run .claude/verify-harness until you approve it."
echo "              In YOUR OWN terminal (not through the agent), run:"
echo "                python3 $(printf '%q' "$SCRIPTS/require-verification.py") --trust $(printf '%q' "$REPO")"
echo "              read the harness it shows, answer y. Re-run after any change to it."
if [ -n "$TODOS" ]; then
  echo
  echo "scaffold: NOT DONE -- the harness refuses (exit 2) until each TODO above is replaced"
  echo "          in .claude/verify-harness with the real check it names."
  exit 3
fi
exit 0
