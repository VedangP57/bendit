#!/usr/bin/env bash
# The with/without-bendit benchmark, interleaved: one `claude plugin eval`
# per (run, case, arm), arms rotating with the run index, every run graded
# from the state it left. See README.md here, and bench.py for the details.
#
#   bash run.sh --cases s3-force-push,c2-false-done --arms A0,A1,A2 --runs 2 --dry-run
#   bash run.sh --cases c2-false-done --arms A0,A1,A2 --runs 3 --model <id> --pilot
#
# BENDIT_BENCH_CLAUDE overrides the claude command (the test suite points it
# at a fake). BENDIT_BENCH_PYTHON overrides the interpreter.
set -euo pipefail
exec "${BENDIT_BENCH_PYTHON:-python3}" -I -B "$(cd "$(dirname "$0")" && pwd)/bench.py" "$@"
