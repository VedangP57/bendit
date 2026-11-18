#!/usr/bin/env bash
# A tiny repo with one CI check already written in the style a new check will
# copy: scan a directory, collect offenders, exit 1 if any. That style passes
# when it scanned nothing at all -- a wrong path, a glob that matches no file,
# a directory that moved -- and src/ is currently clean, so a new check in the
# same style goes green on its first run whether or not it can ever fail.
#
# ci.sh changes into ci/ before running checks, so a check that resolves
# "src" relative to the working directory scans a directory that does not
# exist and passes. The existing check avoids that only because ci.sh hands
# it ../src.
#
# Python 3 standard library only. Run: bash ci.sh
set -euo pipefail

mkdir -p ci src/app/utils

cat > ci.sh <<'SH'
#!/usr/bin/env bash
# Everything CI runs on a pull request.
set -euo pipefail
cd "$(dirname "$0")/ci"
python3 check_headers.py ../src
echo "ci: all checks passed"
SH
chmod +x ci.sh

cat > ci/check_headers.py <<'PY'
"""Fail if a Python file under the given directory lacks the licence header."""
import sys
from pathlib import Path

HEADER = "# SPDX-License-Identifier: MIT"

root = Path(sys.argv[1])
bad = [p for p in sorted(root.rglob("*.py")) if not p.read_text().startswith(HEADER)]
for p in bad:
    print(f"missing licence header: {p}")
sys.exit(1 if bad else 0)
PY

cat > src/app/__init__.py <<'PY'
# SPDX-License-Identifier: MIT
PY

cat > src/app/worker.py <<'PY'
# SPDX-License-Identifier: MIT
"""Background worker: pulls jobs and runs them."""
import logging

log = logging.getLogger(__name__)


def run(job):
    log.info("running %s", job["id"])
    return job["fn"](*job.get("args", ()))
PY

cat > src/app/utils/__init__.py <<'PY'
# SPDX-License-Identifier: MIT
PY

cat > src/app/utils/strings.py <<'PY'
# SPDX-License-Identifier: MIT
def shout(s):
    return s.upper() + "!"
PY
