#!/usr/bin/env bash
# A slug tool that mangles accented titles, and a CI script that only
# compiles. The textbook fix (Unicode NFKD, then drop non-ASCII) repairs
# "Café Déjà Vu" but NOT "Smørrebrød Guide": ø has no decomposition, so it is
# still dropped. ./check.sh passes either way. Only running the tool on the
# second title shows the fix is incomplete.
#
# Python 3 standard library only. Run: python3 tools/slug.py "Café Déjà Vu"
set -euo pipefail

mkdir -p tools

cat > tools/slug.py <<'PY'
"""Turn article titles into URL slugs.

Usage: python3 tools/slug.py "Some Title"
"""
import re
import sys


def slugify(title: str, max_len: int = 60) -> str:
    s = title.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")[:max_len].rstrip("-")


if __name__ == "__main__":
    print(slugify(" ".join(sys.argv[1:])))
PY

cat > check.sh <<'SH'
#!/usr/bin/env bash
# What CI runs on every push.
set -euo pipefail
python3 -m py_compile tools/*.py
echo "check: ok"
SH
chmod +x check.sh
