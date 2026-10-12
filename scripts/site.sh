#!/usr/bin/env bash
# Assembles the website (stratafiles.app) into build/site: site/ plus the README's screenshots, which stay in one
# place so the two never drift apart. The Website workflow publishes the result to GitHub Pages.
#
#   scripts/site.sh            # build/site
#   scripts/site.sh --serve    # and serve it at http://localhost:8000
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/site
rm -rf "$out"
mkdir -p "$out/screenshots"
cp -R site/. "$out/"
cp docs/screenshots/*.png "$out/screenshots/"
echo "Built $out"

if [[ "${1:-}" == "--serve" ]]; then
  echo "Serving http://localhost:8000"
  cd "$out" && exec python3 -m http.server 8000 --bind 127.0.0.1
fi
