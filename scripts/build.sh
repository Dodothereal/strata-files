#!/usr/bin/env bash
# Builds build/Strata.app.
#
# Signs with $STRATA_SIGNING_IDENTITY, else the first "Developer ID Application" identity in your keychain, else ad-hoc.
# A stable signature matters: macOS ties privacy grants (Desktop, Documents, Full Disk Access) to it, so ad-hoc builds
# ask again after every rebuild.
#
#   scripts/build.sh            # release
#   scripts/build.sh debug
#   scripts/build.sh release --open
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --arch arm64 --product Strata
swift build -c "$config" --arch arm64 --product StrataCLI
bins="$(swift build -c "$config" --arch arm64 --show-bin-path)"

app=build/Strata.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bins/Strata" "$app/Contents/MacOS/Strata"
# The command-line tool lives in Helpers: "strata" would clash with "Strata" in MacOS on a case-insensitive disk.
cp "$bins/StrataCLI" "$app/Contents/Helpers/strata"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi

identity="${STRATA_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
codesign --force --options runtime --sign "${identity:--}" "$app/Contents/Helpers/strata" >/dev/null
codesign --force --options runtime --sign "${identity:--}" "$app" >/dev/null
if [[ -n "$identity" ]]; then signer="Developer ID"; else signer="ad-hoc"; fi
echo "Built $app ($config, signed $signer)"

if [[ "${2:-}" == "--open" ]]; then
  # Quit the running copy and wait for it to exit, so `open` launches this build instead of reactivating the old one.
  osascript -e 'tell application id "dev.strata.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -x Strata >/dev/null || break; sleep 0.1; done
  pkill -x Strata 2>/dev/null || true
  while pgrep -x Strata >/dev/null; do sleep 0.1; done
  open "$app"
fi
