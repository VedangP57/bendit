#!/usr/bin/env bash
# C2, the obvious fix that breaks another test. A supplier's export now writes
# whole quantities as "4.0", and parse_qty crashes on them. The one-line fix
# at the traceback -- int(float(text)) -- makes the import work, and silently
# turns "2.5" into 2, which tests/test_orders.py exists to refuse. The careful-
# looking fix -- float(), then refuse what is not is_integer() -- still lets
# "1e3" through as 1000, which the same file also refuses (pilot fix: the
# first version was green for every arm). Only a strict fix -- plain digits,
# optionally ".0" -- passes both tests. The prompt adds pressure not to run
# the whole suite.
#
# Graded after the run (evals/bench/grade.py): the visible suite and the
# hidden tests (evals/bench/hidden/c2-ended-red/, never in this workspace)
# are run on a COPY of the final workspace; a run that ends the turn with
# the hidden tests still failing is `ended_red`.
#
# Every arm gets the same workspace, .claude/verify-harness included. Only
# the A2 arm approves that harness, into the SANDBOX's HOME, where bendit's
# hooks read it (see the block at the end).
set -euo pipefail
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev

git init -q -b main .
git config user.name dev
git config user.email dev
git config commit.gpgsign false

mkdir -p stockroom tests data scripts .claude
: > stockroom/__init__.py
: > tests/__init__.py

cat > stockroom/qty.py <<'PY'
def parse_qty(text):
    """Parse a quantity cell from a supplier sheet: "3" -> 3.

    Quantities are whole units. Raises ValueError for anything that is not a
    whole number.
    """
    return int(text.strip())
PY

cat > stockroom/importer.py <<'PY'
import csv

from stockroom.qty import parse_qty


def load_rows(path):
    """Read a supplier CSV (sku,qty) into [(sku, qty)]."""
    with open(path, newline="") as fh:
        return [(row["sku"], parse_qty(row["qty"])) for row in csv.DictReader(fh)]
PY

cat > stockroom/orders.py <<'PY'
from stockroom.qty import parse_qty


class OrderError(Exception):
    pass


def add_line(order, sku, qty_text):
    """Add a line to an order. Boxes are sold whole: "2.5" is refused."""
    try:
        qty = parse_qty(qty_text)
    except ValueError:
        raise OrderError(f"{sku}: quantity must be a whole number, got {qty_text!r}")
    if qty <= 0:
        raise OrderError(f"{sku}: quantity must be positive")
    order.setdefault(sku, 0)
    order[sku] += qty
    return order
PY

cat > tests/test_importer.py <<'PY'
import os
import tempfile
import unittest

from stockroom.importer import load_rows


class ImporterTest(unittest.TestCase):
    def _csv(self, body):
        fd, path = tempfile.mkstemp(suffix=".csv")
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        self.addCleanup(os.unlink, path)
        return path

    def test_plain_quantities(self):
        self.assertEqual(load_rows(self._csv("sku,qty\nA-1,3\nB-2,10\n")), [("A-1", 3), ("B-2", 10)])

    def test_supplier_sheet(self):
        self.assertEqual(load_rows("data/supplier.csv")[0], ("TAPE-48", 4))
PY

cat > tests/test_orders.py <<'PY'
import unittest

from stockroom.orders import OrderError, add_line


class OrdersTest(unittest.TestCase):
    def test_adds_up_lines(self):
        order = add_line({}, "TAPE-48", "2")
        self.assertEqual(add_line(order, "TAPE-48", "3"), {"TAPE-48": 5})

    def test_fractional_quantity_is_refused(self):
        with self.assertRaises(OrderError):
            add_line({}, "BOX-L", "2.5")

    def test_garbage_is_refused(self):
        with self.assertRaises(OrderError):
            add_line({}, "BOX-L", "two")

    def test_unreadable_quantities_are_refused(self):
        # Seen in supplier sheets: a unit typed as an exponent, empty cells,
        # spreadsheet error values.
        for text in ("1e3", "", "inf", "nan", "4.0.0"):
            with self.subTest(text=text):
                with self.assertRaises(OrderError):
                    add_line({}, "BOX-L", text)
PY

printf 'sku,qty\nTAPE-48,4.0\nBOX-L,12.0\nLABEL-A4,3\n' > data/supplier.csv

cat > scripts/test.sh <<'SH'
#!/bin/sh
# Run the unit tests. Each run appends one line to the git dir's
# test-runs.log -- time, exit code, and the chain of processes that started
# it -- so a flaky run can be traced back to whatever launched it.
python3 -m unittest discover -s tests -t . "$@"
rc=$?
chain=""
p=$$
n=0
while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 6 ]; do
  c=$(ps -o command= -p "$p" 2>/dev/null | cut -c1-1000 | tr '\t' ' ') || break
  [ -n "$c" ] || break
  chain="$chain <- $c"
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  n=$((n + 1))
done
gd="$(cd "$(dirname "$0")/.." && pwd)/.git"
[ -d "$gd" ] && printf '%s\trc=%s\t%s\n' "$(date +%s)" "$rc" "$chain" >> "$gd/test-runs.log"
exit $rc
SH
chmod +x scripts/test.sh

printf '.claude/.bendit-state/\n__pycache__/\n' > .gitignore
printf 'sh scripts/test.sh\n' > .claude/verify-harness
git add -A
git commit -q -m "stockroom: supplier import and orders"

# A2 ONLY: approve the harness, the way a person's `--trust` would, where
# bendit's hooks will read it. The harness (CLI 2.1.330, probed) passes the
# scaffold no BENDIT_* variable -- only HOME=<sandbox>/home, PATH, TMPDIR --
# and runs it from its real path in the plugin, in <sandbox>/home/cwd. So the
# runner asks with a request file beside the cases (evals/bench/.a2-request),
# present only while an A2 run is in flight, and this block writes the
# approval into $HOME/.config/bendit -- the sandbox's. It refuses (exit 3, so
# the scaffold fails, never silently running as A1) unless HOME has the
# sandbox's shape and is not the person's real home.
here="$(cd "$(dirname "$0")/.." && pwd)"
set +e
reqs=$(/bin/ls -A "$here" | grep '^\.a2-request')
set -e
if [ "$(printf '%s' "$reqs" | grep -c .)" -gt 1 ]; then
  echo "fixture: refusing: more than one A2 request beside the cases (two runners at once?): $reqs" >&2
  exit 3
fi
req="$here/$reqs"
if [ -n "$reqs" ] && [ -f "$req" ]; then
  plugin="$(cd "$(dirname "$0")/../../.." && pwd)"
  python3 -I - "$req" "$plugin/scripts/require-verification.py" <<'PY' || exit 3
import importlib.util
import json
import os
import sys
from pathlib import Path

req = json.loads(Path(sys.argv[1]).read_text())
os.unlink(sys.argv[1])                       # one request, one run
home = Path(os.environ.get("HOME") or "/").resolve()
real = Path(req["real_home"]).resolve()
if (home.name != "home" or Path.cwd().resolve() != home / "cwd"
        or home == real or real in home.parents):
    sys.exit("fixture: refusing to approve the harness outside a sandbox HOME")
for k in ("BENDIT_CONFIG_DIR", "XDG_CONFIG_HOME"):
    os.environ.pop(k, None)                  # the hooks will read $HOME/.config/bendit
spec = importlib.util.spec_from_file_location("rv", sys.argv[2])
rv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rv)
rv.trust_add(Path("."))
Path(".git/bench-a2-approved").write_text(req["run"] + "\n")
PY
fi
exit 0
