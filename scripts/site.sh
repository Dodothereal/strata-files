#!/usr/bin/env bash
# Assembles the website (stratafiles.app) into build/site: site/ plus the README's screenshots, which stay in one
# place so the two never drift apart. The Website workflow publishes the result to GitHub Pages.
#
#   scripts/site.sh            # build/site
#   scripts/site.sh --serve    # and serve it at http://localhost:8000
#
# Needs cwebp (brew install webp, or apt-get install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cwebp >/dev/null || { echo "cwebp is needed: brew install webp (or apt-get install webp)" >&2; exit 1; }

out=build/site
rm -rf "$out"
mkdir -p "$out/screenshots"
cp -R site/. "$out/"

# The screenshots as WebP (about a fifth of the PNG's size, transparent shadow kept), under names that say what they
# show. Wide shots also get 800 and 1100 px versions (phones, 1x screens); index.html and sitemap.xml use these names.
#   source:name:widths   ("1400,800" adds the smaller versions)
shots=(
  "hero:strata-mac-file-manager-list-view:1400,800"
  "search:strata-plain-english-file-search:1400,800"
  "palette:strata-command-palette:1400,800"
  "treemap:strata-disk-usage-map:1400,800"
  "grid:strata-icon-view-thumbnails:1400,800"
  "dual:strata-dual-pane:1400,800"
  "devmode:strata-git-status-code-preview:1400,800"
  "project:strata-project-inspector:1400,800"
  "shortcuts:strata-keyboard-shortcuts:full"
)
webp=(-quiet -q 86 -alpha_q 85 -m 6 -sharp_yuv -metadata none)
for shot in "${shots[@]}"; do
  IFS=: read -r source name widths <<< "$shot"
  cwebp "${webp[@]}" "docs/screenshots/$source.png" -o "$out/screenshots/$name.webp"
  if [[ "$widths" == *800* ]]; then
    for width in 800 1100; do
      cwebp "${webp[@]}" -resize "$width" 0 "docs/screenshots/$source.png" -o "$out/screenshots/$name-$width.webp"
    done
  fi
done

# The stylesheet goes inline so the first paint doesn't wait for another request (404.html still links it).
python3 - "$out/index.html" "$out/styles.css" <<'PY'
import sys
page, css = sys.argv[1], open(sys.argv[2]).read()
html = open(page).read()
link = '<link rel="stylesheet" href="styles.css">'
assert html.count(link) == 1, "index.html should link styles.css exactly once"
open(page, "w").write(html.replace(link, "<style>\n" + css + "</style>"))
PY
echo "Built $out ($(du -sh "$out" | cut -f1))"

if [[ "${1:-}" == "--serve" ]]; then
  echo "Serving http://localhost:8000"
  cd "$out" && exec python3 -m http.server 8000 --bind 127.0.0.1
fi
