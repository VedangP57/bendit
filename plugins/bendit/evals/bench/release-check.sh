#!/usr/bin/env bash
# The release check, on your own machine: a small fixed suite through
# `claude plugin eval` under your normal Claude login (no API key, no CI),
# held to the pinned v0.5.2 baseline (baseline.json). Exit 1 blocks a
# release; 3 is inconclusive (run it again). See release_check.py and
# README.md, "Release check".
#
#   bash release-check.sh --dry-run          the plan and its estimated cost; calls nothing
#   bash release-check.sh                    run it (about $3 of usage on claude-opus-5-5)
#   bash release-check.sh --check <runs.jsonl>
#
# BENDIT_BENCH_CLAUDE overrides the claude command (the test suite points it
# at a fake). BENDIT_BENCH_PYTHON overrides the interpreter.
set -euo pipefail
exec "${BENDIT_BENCH_PYTHON:-python3}" -I -B "$(cd "$(dirname "$0")" && pwd)/release_check.py" "$@"
