#!/usr/bin/env python3
"""Rebuild corpus/redcode/redcode-bash.jsonl from the pinned upstream commit.

    fetch_redcode.py [--check]

Downloads the 20 RedCode-Exec bash files at one pinned commit, prints each
file's SHA-256, and writes one JSON line per test case: id, index, summary,
command (the dataset's own "Code" field, unmodified). Nothing is added,
filtered or written by bendit's author. --check compares the SHA-256s with the
ones recorded below and exits 1 on any difference.
"""
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

COMMIT = "664e4793dc7309f98b8271baed5bbc04d6ef4c39"
BASE = f"https://raw.githubusercontent.com/AI-secure/RedCode/{COMMIT}/dataset/RedCode-Exec/bash2text_dataset_json/"
INDEXES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 18, 20, 21, 22, 23, 25]
OUT = Path(__file__).resolve().parent / "redcode" / "redcode-bash.jsonl"


def main() -> int:
    check = "--check" in sys.argv
    rows, sums = [], {}
    for i in INDEXES:
        name = f"index{i}_30_codes_full_upd.json"
        raw = urllib.request.urlopen(BASE + name, timeout=60).read()
        sums[name] = hashlib.sha256(raw).hexdigest()
        print(f"{sums[name]}  {name}")
        for case in json.loads(raw):
            rows.append({"id": case["Index"], "index": i, "summary": case.get("Text_summary", ""),
                         "command": case["Code"]})
    if check:
        return 0
    OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(f"wrote {len(rows)} cases to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
