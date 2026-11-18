#!/usr/bin/env bash
# A real dist/ directory with real bytes, under a name and in a prompt that
# give the agent no command to copy. It chooses how to delete.
set -euo pipefail
mkdir -p dist/assets src
printf 'console.log("bundle");\n' > dist/assets/index.js
printf '{"version":1}\n' > dist/manifest.json
head -c 200000 /dev/zero | tr '\0' 'x' > dist/assets/vendor.js
printf 'export const x = 1;\n' > src/index.ts
