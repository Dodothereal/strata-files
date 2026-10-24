#!/usr/bin/env bash
# Assembles the website (stratafiles.app) into build/site: site/ plus the README's screenshots, which stay in one
# place so the two never drift apart. The Website workflow publishes the result to GitHub Pages.
#
#   scripts/site.sh            # build/site
#   scripts/site.sh --serve    # and serve it at http://localhost:8000
#   scripts/site.sh --refresh-readme  # also update the shared README WebP images
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
  "quicklook:strata-quick-look-folders-archives:1400,800"
  "grid:strata-icon-view-thumbnails:1400,800"
  "list:strata-list-view-folders-sizes:1400,800"
  "columns:strata-column-view:1400,800"
  "gallery:strata-gallery-view:1400,800"
  "disk-usage:strata-disk-usage-view:1400,800"
  "dual:strata-dual-pane:1400,800"
  "devmode:strata-git-status-code-preview:1400,800"
  "project:strata-project-inspector:1400,800"
  "themes:strata-color-themes:3960,2360,1400,800"
  "appearance:strata-appearance-theme-selection:1264,800"
  "shortcuts:strata-keyboard-shortcuts:full"
)
webp=(-quiet -q 86 -alpha_q 85 -m 6 -sharp_yuv -metadata none)
for shot in "${shots[@]}"; do
  IFS=: read -r source name widths <<< "$shot"
  options=("${webp[@]}")
  largest_width=0
  sizes=(800 1100)
  # Preserve the opening screenshot's text and gradients exactly; size it for phones and Retina screens.
  if [[ "$source" == "themes" ]]; then
    options=(-quiet -lossless -z 9 -exact -metadata none)
    sizes=(800 1100 1400 2360)
  elif [[ "$source" == "appearance" ]]; then
    options=(-quiet -lossless -z 9 -exact -metadata icc)
    sizes=(480 800 1100)
  elif [[ "$source" =~ ^(quicklook|grid|list|columns|gallery|disk-usage|dual)$ ]]; then
    # Two pixels per point at the largest displayed width, keeping full alpha precision and source color profiles.
    options=(-quiet -q 95 -alpha_q 100 -m 6 -sharp_yuv -metadata icc)
    largest_width=2120
    sizes=(480 800 1100 1400)
  fi
  primary=("${options[@]}")
  if [[ "$largest_width" -gt 0 ]]; then primary+=(-resize "$largest_width" 0); fi
  cwebp "${primary[@]}" "docs/screenshots/$source.png" -o "$out/screenshots/$name.webp"
  if [[ "$widths" == *800* ]]; then
    for width in "${sizes[@]}"; do
      cwebp "${options[@]}" -resize "$width" 0 "docs/screenshots/$source.png" -o "$out/screenshots/$name-$width.webp"
    done
  fi
  if [[ "${1:-}" == "--refresh-readme" && "$source" =~ ^(appearance|quicklook|grid|list|columns|gallery|treemap|disk-usage|dual)$ ]]; then
    cp "$out/screenshots/$name.webp" "docs/screenshots/$source.webp"
  fi
done

# Build every language before fingerprinting the shared assets.
python3 scripts/site-localize.py build "$out"

# CI retains previous fingerprinted assets so cached pages keep working after an update.
if [[ -n "${SITE_PREVIOUS_ORIGIN:-}" ]]; then
  python3 scripts/site-assets.py "$out" --previous-origin "$SITE_PREVIOUS_ORIGIN"
else
  python3 scripts/site-assets.py "$out"
fi
echo "Built $out ($(du -sh "$out" | cut -f1))"

if [[ "${1:-}" == "--serve" ]]; then
  echo "Serving http://localhost:8000"
  cd "$out" && exec python3 -m http.server 8000 --bind 127.0.0.1
fi
