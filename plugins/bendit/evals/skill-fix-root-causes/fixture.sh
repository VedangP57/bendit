#!/usr/bin/env bash
# A billing report that crashes on a None name. The traceback points at
# billing/report.py, where neighbouring code already defaults a missing value
# (`c.email or ""`), so the one-token fix is right there. The None is made in
# billing/loader.py: the legacy loader asks for a column (`customer_name`)
# that the legacy export does not have (it is `cust_name`), so every legacy
# customer loses its name. Fixing the loader restores the names; defaulting in
# the report prints blank names for every legacy account.
#
# Python 3 standard library only. Run it: python3 -m billing.report
set -euo pipefail

mkdir -p billing data

cat > billing/__init__.py <<'PY'
PY

cat > billing/loader.py <<'PY'
"""Load customer records from the CSV exports in data/."""
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

DATA = Path(__file__).resolve().parent.parent / "data"


@dataclass
class Customer:
    id: str
    name: Optional[str]
    email: Optional[str]
    plan: str


def _read(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def load_current():
    return [
        Customer(r["id"], r.get("name"), r.get("email"), r["plan"])
        for r in _read(DATA / "customers.csv")
    ]


def load_legacy():
    # Accounts still billed through the old system.
    return [
        Customer(r["cust_id"], r.get("customer_name"), r.get("email_addr"), r["plan_code"])
        for r in _read(DATA / "legacy_customers.csv")
    ]


def load_customers():
    return load_current() + load_legacy()
PY

cat > billing/report.py <<'PY'
"""Monthly billing report. Run: python3 -m billing.report"""
from billing.loader import load_customers


def format_line(c):
    email = (c.email or "").lower()
    return f"{c.name.strip().title():<24} {email:<32} {c.plan}"


def main():
    customers = load_customers()
    print(f"Monthly report: {len(customers)} customers")
    for c in sorted(customers, key=lambda c: c.id):
        print(format_line(c))


if __name__ == "__main__":
    main()
PY

cat > data/README.md <<'MD'
# data/

Both CSVs are regenerated every night by the billing exports and overwritten
in place. Edits made here by hand are lost on the next export.
MD

cat > data/customers.csv <<'CSV'
id,name,email,plan
C-1001,ada lovelace,Ada@example.com,pro
C-1002,grace hopper,grace@example.com,team
C-1003,alan turing,,basic
CSV

cat > data/legacy_customers.csv <<'CSV'
cust_id,cust_name,email_addr,plan_code
L-0007,edsger dijkstra,edsger@example.com,LEGACY-PRO
L-0019,barbara liskov,barbara@example.com,LEGACY-BASIC
CSV
