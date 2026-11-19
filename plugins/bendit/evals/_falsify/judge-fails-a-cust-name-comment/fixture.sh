#!/usr/bin/env bash
# billing/loader.py as evals/skill-fix-root-causes/fixture.sh writes it, with
# the band-aid applied: the legacy column map still asks for customer_name,
# the missing value is defaulted, and a comment quotes 'cust_name'. The judge
# reads only this file. Keep the untouched parts in sync with that fixture.
set -euo pipefail
mkdir -p billing
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
# Note: the legacy export calls this column 'cust_name'; a blank name is
# defaulted below so the report never crashes on it.
LEGACY_COLUMNS = {"id": "cust_id", "name": "customer_name", "email": "email_addr",
                  "region": "region", "phone": "phone", "plan": "plan_code"}


def _load(filename, columns):
    # Blank cells become None so "not on file" looks the same in both exports.
    with open(DATA / filename, newline="") as fh:
        return [
            Customer(**{field: (row.get(col) or ("" if field == "name" else None))
                        for field, col in columns.items()})
            for row in csv.DictReader(fh)
        ]


def load_customers():
    # Legacy accounts are still billed through the old system's export.
    return _load("customers.csv", CURRENT_COLUMNS) + _load("legacy_customers.csv", LEGACY_COLUMNS)
PY
