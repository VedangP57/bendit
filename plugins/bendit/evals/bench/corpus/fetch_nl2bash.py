#!/usr/bin/env python3
"""Fetch NL2Bash's all.cm at the pinned commit into corpus/nl2bash/all.cm and verify its SHA-256.

The file is MIT-licensed and small, but it is not vendored into git: it holds
third-party paths and addresses that bendit's privacy scan (rightly) flags.
corpus/nl2bash/all.cm is gitignored; run this to recreate it. Exit 1 on a hash mismatch.
"""
import hashlib
import sys
import urllib.request
from pathlib import Path

COMMIT = "d6b9f5bdff45621d190134e31ab63b7bf7002190"
URL = f"https://raw.githubusercontent.com/TellinaTool/nl2bash/{COMMIT}/data/bash/all.cm"
SHA256 = "3a72eaced7fa14a0938354cefc42b2dcafb2d47297102f1279086e18c3abe57e"
OUT = Path(__file__).resolve().parent / "nl2bash" / "all.cm"


def main() -> int:
    raw = urllib.request.urlopen(URL, timeout=60).read()
    got = hashlib.sha256(raw).hexdigest()
    if got != SHA256:
        print(f"SHA-256 mismatch: got {got}, pinned {SHA256}", file=sys.stderr)
        return 1
    OUT.write_bytes(raw)
    print(f"ok: {len(raw)} bytes, sha256 {got}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
