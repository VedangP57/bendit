#!/usr/bin/env bash
# Copy the repo's install.sh into both wrappers. Run after editing install.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../install.sh"
for dest in "$here/npm/install.sh" "$here/pypi/src/bendit/install.sh"; do
  cp "$src" "$dest"
  chmod +x "$dest"
  echo "synced $dest"
done
