#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Removes Gauge and everything it wrote.
#
# Double-clickable from the disk image, so it explains itself and waits for a
# confirmation rather than deleting on sight.
set -uo pipefail

APP="/Applications/Gauge.app"
# An install of the renamed package over the old one was relocated here by
# PackageKit rather than replacing it; clean that up as well.
RELOCATED="/Applications/Gauge.localized"
# Builds before 1.0 used com.gauge.app; clean both up.
LEGACY_ID="com.gauge.app"
BUNDLE_ID="com.thaisimply.gauge"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
LEGACY_PREFS="$HOME/Library/Preferences/$LEGACY_ID.plist"
SUPPORT="$HOME/Library/Application Support/Gauge"
CACHES="$HOME/Library/Caches/$BUNDLE_ID"
LEGACY_CACHES="$HOME/Library/Caches/$LEGACY_ID"
STATE="$HOME/Library/HTTPStorages/$BUNDLE_ID"
SAVED="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

echo "This removes Gauge and its settings:"
echo
for path in "$APP" "$RELOCATED" "$PREFS" "$LEGACY_PREFS" "$SUPPORT" "$CACHES" \
            "$LEGACY_CACHES" "$STATE" "$SAVED"; do
  [ -e "$path" ] && echo "  $path"
done
echo "  the AccuWeather key in your login keychain, if you added one"
echo "  the login item, if Gauge was set to open at login"
echo
read -r -p "Remove them? [y/N] " answer
case "$answer" in
  [yY]*) ;;
  *) echo "Nothing was removed."; exit 0 ;;
esac

echo "▸ Quitting Gauge…"
pkill -x Gauge 2>/dev/null

echo "▸ Removing the login item…"
# Registered through SMAppService, so it goes away with the bundle; this is
# for the older-style entry in case one was ever created.
osascript -e 'tell application "System Events" to delete login item "Gauge"' 2>/dev/null

echo "▸ Removing files…"
for path in "$APP" "$RELOCATED" "$PREFS" "$LEGACY_PREFS" "$SUPPORT" "$CACHES" \
            "$LEGACY_CACHES" "$STATE" "$SAVED"; do
  if [ -e "$path" ]; then
    rm -rf "$path" 2>/dev/null || sudo rm -rf "$path"
  fi
done

echo "▸ Forgetting installer receipts…"
for receipt in "$BUNDLE_ID" "$LEGACY_ID"; do
  pkgutil --pkgs | grep -qx "$receipt" && sudo pkgutil --forget "$receipt" >/dev/null 2>&1
done

echo "▸ Removing the keychain item…"
security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1
security delete-generic-password -s "$LEGACY_ID" >/dev/null 2>&1

# Preferences are cached by the system; without this they can come back.
for domain in "$BUNDLE_ID" "$LEGACY_ID"; do
  defaults read "$domain" >/dev/null 2>&1 && defaults delete "$domain" 2>/dev/null
done
killall cfprefsd 2>/dev/null

echo
echo "✓ Gauge has been removed."
[ -t 0 ] && read -r -p "Press return to close." _
