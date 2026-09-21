#!/bin/bash
# Builds Gauge.app from the SwiftPM product.
#
# The scratch directory is kept outside the project on purpose: this tree lives
# in a synced folder, and build artefacts have no business being uploaded.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-release}"
SCRATCH="${GAUGE_SCRATCH:-$HOME/.cache/gauge-build}"
APP_DIR="$PROJECT_DIR/build/Gauge.app"

echo "▸ Building ($CONFIG)…"
swift build --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH" -c "$CONFIG"

if [ "${GAUGE_SKIP_TESTS:-0}" != "1" ]; then
  echo "▸ Running tests…"
  "$SCRATCH/$CONFIG/GaugeTests" | tail -3
fi

BINARY="$SCRATCH/$CONFIG/Gauge"
[ -f "$BINARY" ] || { echo "✗ No binary at $BINARY"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/Gauge"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Enough to run locally and to keep the SMC/IOKit calls
# working; a Developer ID signature would be needed only for distribution.
echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 \
  || echo "  (signing skipped)"

echo "✓ $APP_DIR"
echo
echo "  Run:      open '$APP_DIR'"
echo "  Install:  cp -R '$APP_DIR' /Applications/"
echo "  Inspect:  '$APP_DIR/Contents/MacOS/Gauge' --dump"
