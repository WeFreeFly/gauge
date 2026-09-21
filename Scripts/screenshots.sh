#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Regenerates the screenshots in docs/.
#
# Liquid Glass is composited by the window server and comes out empty in an
# offscreen render, so each panel is put on screen over a fixed backdrop and
# captured by window id. Capturing one window needs no screen-recording
# permission, unlike capturing a region of the display.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${GAUGE_SCRATCH:-$HOME/.cache/gauge-build}"
APP="${GAUGE_OUTPUT:-$SCRATCH/out}/Gauge.app/Contents/MacOS/Gauge"
DOCS="$PROJECT_DIR/docs"
MATERIAL="${GAUGE_SHOT_MATERIAL:-clearGlass}"
MODULES=("${@:-cpu sensors memory network combined weather}")

[ -x "$APP" ] || { echo "✗ No app at $APP — run ./build.sh first"; exit 1; }
mkdir -p "$DOCS"

echo "▸ Material: $MATERIAL"
for module in ${MODULES[*]}; do
  printf '  %-9s ' "$module"
  log="$(mktemp)"
  "$APP" --panel "$module" 14 --material "$MATERIAL" --backdrop >"$log" 2>&1 &
  app_pid=$!

  # Wait for the window to exist and report itself.
  window=""
  for _ in $(seq 1 60); do
    # Under `set -e` a failed substitution would end the script, and the
    # first few passes always fail — the window does not exist yet.
    window="$(grep -o 'window-id: [0-9]*' "$log" 2>/dev/null | head -1 | awk '{print $2}' || true)"
    [ -n "$window" ] && break
    sleep 0.25
  done

  if [ -z "$window" ]; then
    echo "✗ no window"
    kill "$app_pid" 2>/dev/null || true
    rm -f "$log"
    continue
  fi

  # Give the material a moment to settle before the shutter.
  sleep 2
  screencapture -x -o -l "$window" "$DOCS/$module.png" 2>/dev/null || true
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  rm -f "$log"

  if [ -f "$DOCS/$module.png" ]; then
    size=$(sips -g pixelWidth -g pixelHeight "$DOCS/$module.png" 2>/dev/null \
           | tail -2 | awk '{print $2}' | paste -sd'x' -)
    echo "✓ ${size}px"
  else
    echo "✗ capture failed"
  fi
done

echo
echo "Written to $DOCS"
