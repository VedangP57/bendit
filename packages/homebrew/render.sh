#!/usr/bin/env bash
# render.sh <version> <sha256> > bendit.rb
# Fills packages/homebrew/bendit.rb.tmpl. <version> is X.Y.Z with no leading v;
# <sha256> is the 64 hex digits of the vX.Y.Z tag tarball. Exits 2 on bad input.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -ne 2 ]; then
  echo "usage: render.sh <version> <sha256> > bendit.rb" >&2; exit 2
fi
version="$1"; sha="$2"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "render.sh: version must look like 1.2.3 (got: $version)" >&2; exit 2
fi
if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "render.sh: sha256 must be 64 lowercase hex digits" >&2; exit 2
fi
sed -e "s/@@VERSION@@/$version/" -e "s/@@SHA256@@/$sha/" "$HERE/bendit.rb.tmpl"
