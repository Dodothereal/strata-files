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
#
# Release builds (.github/workflows/release.yml) also set:
#   STRATA_VERSION, STRATA_BUILD_NUMBER   stamped into Info.plist (version like 1.2.3, build number digits)
#   STRATA_KEYCHAIN                       the keychain holding the signing identity
#   STRATA_TIMESTAMP=1                    a secure timestamp on the signature, which notarization requires
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
# Checked before anything is built or removed.
if [[ -n "${STRATA_VERSION:-}" && ! "$STRATA_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "STRATA_VERSION must look like 1.2.3" >&2; exit 1
fi
if [[ -n "${STRATA_BUILD_NUMBER:-}" && ! "$STRATA_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "STRATA_BUILD_NUMBER must be digits" >&2; exit 1
fi
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
if [[ -n "${STRATA_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STRATA_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${STRATA_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STRATA_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi

identity="${STRATA_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
sign=(--force --options runtime --sign "${identity:--}")
if [[ -n "${STRATA_KEYCHAIN:-}" ]]; then sign+=(--keychain "$STRATA_KEYCHAIN"); fi
if [[ "${STRATA_TIMESTAMP:-}" == 1 && -n "$identity" ]]; then sign+=(--timestamp); fi
# Inside out: the helper first, then the bundle that seals it.
codesign "${sign[@]}" "$app/Contents/Helpers/strata" >/dev/null
codesign "${sign[@]}" "$app" >/dev/null
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
