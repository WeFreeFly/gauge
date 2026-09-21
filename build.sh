#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Builds Gauge.app from the SwiftPM product.
#
# The scratch directory is kept outside the project on purpose: this tree lives
# in a synced folder, and build artefacts have no business being uploaded.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-release}"
SCRATCH="${GAUGE_SCRATCH:-$HOME/.cache/gauge-build}"
# The app bundle goes outside the project as well. This tree sits in a synced
# folder, and a ten-megabyte binary rewritten on every build keeps the sync
# client busy for no reason. Override with GAUGE_OUTPUT.
OUTPUT_DIR="${GAUGE_OUTPUT:-$SCRATCH/out}"
APP_DIR="$OUTPUT_DIR/Gauge.app"

echo "▸ Building ($CONFIG)…"
swift build --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH" -c "$CONFIG"

if [ "${GAUGE_SKIP_TESTS:-0}" != "1" ]; then
  echo "▸ Running tests…"
  "$SCRATCH/$CONFIG/GaugeTests" | tail -3
fi

BINARY="$SCRATCH/$CONFIG/Gauge"
[ -f "$BINARY" ] || { echo "✗ No binary at $BINARY"; exit 1; }

echo "▸ Assembling bundle…"
mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/Gauge"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Sign with a Developer ID if one is installed, otherwise ad-hoc.
#
# A Developer ID signature plus notarisation is what removes the
# right-click-to-open step on other people's Macs. Ad-hoc is enough to run
# here. Set GAUGE_SIGN_IDENTITY to choose between several certificates.
IDENTITY="${GAUGE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep "Developer ID Application" | head -1 \
              | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "▸ Signing as ${IDENTITY}…"
  # The hardened runtime is required before Apple will notarise anything.
  codesign --force --deep --options runtime --timestamp \
           --sign "$IDENTITY" "$APP_DIR"
  codesign --verify --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/  /'
else
  echo "▸ Signing (ad-hoc — no Developer ID certificate found)…"
  codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 \
    || echo "  (signing skipped)"
fi

echo "✓ $APP_DIR"
echo
if [ -n "$IDENTITY" ]; then
  echo "  Signed with a Developer ID. Notarise with: ./Scripts/package.sh"
fi
echo "  Run:      open '$APP_DIR'"
echo "  Install:  cp -R '$APP_DIR' /Applications/"
echo "  Inspect:  '$APP_DIR/Contents/MacOS/Gauge' --dump"
