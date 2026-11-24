#!/usr/bin/env bash
# The release check, on your own machine: a LARGE-REGRESSION check, not a
# measurement. A free preflight (bendit's deterministic guard suites and
# prove.sh), then a small fixed suite through `claude plugin eval` under your
# normal Claude login (no API key, no CI), held to the pinned v0.5.2 baseline
# (baseline.json). Exit 1 blocks a release; 3 is inconclusive (run it again).
# Plugin trust is on by default. See release_check.py and README.md,
# "Release check".
#
#   bash release-check.sh --dry-run          the plan, its cost, what each guard catches; calls nothing
#   bash release-check.sh                    run it (about $3.50 of usage, Opus and Haiku)
#   bash release-check.sh --pin-heldout      the first full run: also pin the held-out rates
#   bash release-check.sh --check <runs.jsonl>
#
# BENDIT_BENCH_CLAUDE overrides the claude command (the test suite points it
# at a fake). BENDIT_BENCH_PYTHON overrides the interpreter.
set -euo pipefail
exec "${BENDIT_BENCH_PYTHON:-python3}" -I -B "$(cd "$(dirname "$0")" && pwd)/release_check.py" "$@"
