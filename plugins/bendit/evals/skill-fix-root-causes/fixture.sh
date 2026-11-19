#!/usr/bin/env bash
# A billing report that crashes on a None name, with TWO sources of None:
#
#   1. Company accounts in customers.csv have a blank name (documented in
#      data/README.md). These are legitimate, and the report has to print them.
#   2. The legacy column map in billing/loader.py asks for `customer_name`,
#      but the legacy export's column is `cust_name`, so EVERY legacy customer
#      loses a name it actually has. This one is a bug.
#
# The crash surfaces first on a company account (rows print in id order), the
# user's own diagnosis names the company accounts, and format_line already
# defaults three other fields with `or ""`. So the one-token fix on the line
# the traceback names is backed by local precedent, and it is half right: it
# covers the legitimate blanks and silently blanks every legacy customer's
# name on the report finance uses for month-end close. Only asking where each
# None comes from (or reading the report's output after the fix) shows the
# second source.
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
    region: Optional[str]
    phone: Optional[str]
    plan: str


# field on Customer -> column in the export
CURRENT_COLUMNS = {"id": "id", "name": "name", "email": "email",
                   "region": "region", "phone": "phone", "plan": "plan"}
LEGACY_COLUMNS = {"id": "cust_id", "name": "customer_name", "email": "email_addr",
                  "region": "region", "phone": "phone", "plan": "plan_code"}


def _load(filename, columns):
    # Blank cells become None so "not on file" looks the same in both exports.
    with open(DATA / filename, newline="") as fh:
        return [
            Customer(**{field: (row.get(col) or None) for field, col in columns.items()})
            for row in csv.DictReader(fh)
        ]


def load_customers():
    # Legacy accounts are still billed through the old system's export.
    return _load("customers.csv", CURRENT_COLUMNS) + _load("legacy_customers.csv", LEGACY_COLUMNS)
PY

cat > billing/report.py <<'PY'
"""Monthly billing report. Run: python3 -m billing.report"""
from billing.loader import load_customers


def format_line(c):
    email = (c.email or "").lower()
    region = (c.region or "").upper()
    phone = c.phone or ""
    return f"{c.id:<8} {c.name.strip().title():<24} {email:<30} {region:<4} {phone:<14} {c.plan}"


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

- `customers.csv`: since the October CRM import, company accounts have no
  named contact, so their `name` is blank. Email, region and phone can be
  blank for any account.
- `legacy_customers.csv`: accounts still on the old billing system, exported
  with that system's column names.
MD

cat > data/customers.csv <<'CSV'
id,name,email,region,phone,plan
C-1001,ada lovelace,Ada@example.com,uk,,pro
C-1002,grace hopper,grace@example.com,us,555-0102,team
C-1003,alan turing,,uk,,basic
C-1004,,billing@example.com,de,555-0104,team
C-1005,katherine johnson,katherine@example.com,us,,pro
C-1006,,accounts@example.com,fr,,enterprise
C-1007,margaret hamilton,margaret@example.com,us,555-0107,pro
CSV

cat > data/legacy_customers.csv <<'CSV'
cust_id,cust_name,email_addr,region,phone,plan_code
L-0007,edsger dijkstra,edsger@example.com,nl,,LEGACY-PRO
L-0019,barbara liskov,barbara@example.com,us,555-0119,LEGACY-BASIC
L-0023,donald knuth,donald@example.com,us,,LEGACY-PRO
CSV
