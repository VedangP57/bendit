#!/usr/bin/env bash
# TEMPLATE fixture: the workspace the agent wakes up in.
#
# `claude plugin eval` runs this (only when you pass --scaffold) inside an
# empty, throwaway working directory before each run. Everything the prompt
# talks about must be created here. A `files/` directory next to case.yaml is
# NOT copied in -- only what this script creates exists.
#
# Rules that keep a fixture honest:
#   - Make it look like the real code your rule is about, not like a textbook.
#     An agent fixes a clean, isolated file correctly on its own; put the
#     temptation in (neighbouring code that already uses the shortcut you are
#     trying to prevent) or the baseline arm is at ceiling and the case
#     measures nothing.
#   - Create every file a grader reads. A `{ source: file, path }` grader on a
#     file that was never created fails in BOTH arms.
#   - Relative paths only. No home directory, no network, no secrets.
#   - Fail loudly (set -euo pipefail): a half-built workspace must stop the
#     run, not produce a score.
#   - Check it offline before spending anything:
#       d="$(mktemp -d)" && (cd "$d" && bash /path/to/fixture.sh) && ls -R "$d"
set -euo pipefail

mkdir -p src
cat > src/settings.js <<'JS'
// Reads settings from the environment.

export function getHost(env) {
  return env.HOST ?? "localhost";
}

export function getPort(env) {
  return parseInt(env.PORT.trim(), 10);
}
JS
