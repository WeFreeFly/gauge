#!/bin/bash
# Removes Gauge and everything it wrote.
#
# Double-clickable from the disk image, so it explains itself and waits for a
# confirmation rather than deleting on sight.
set -uo pipefail

APP="/Applications/Gauge.app"
PREFS="$HOME/Library/Preferences/com.gauge.app.plist"
SUPPORT="$HOME/Library/Application Support/Gauge"
CACHES="$HOME/Library/Caches/com.gauge.app"
STATE="$HOME/Library/HTTPStorages/com.gauge.app"
SAVED="$HOME/Library/Saved Application State/com.gauge.app.savedState"

echo "This removes Gauge and its settings:"
echo
for path in "$APP" "$PREFS" "$SUPPORT" "$CACHES" "$STATE" "$SAVED"; do
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
for path in "$APP" "$PREFS" "$SUPPORT" "$CACHES" "$STATE" "$SAVED"; do
  if [ -e "$path" ]; then
    rm -rf "$path" 2>/dev/null || sudo rm -rf "$path"
  fi
done

echo "▸ Removing the keychain item…"
security delete-generic-password -s "com.gauge.app" >/dev/null 2>&1

# Preferences are cached by the system; without this they can come back.
defaults read com.gauge.app >/dev/null 2>&1 && defaults delete com.gauge.app 2>/dev/null
killall cfprefsd 2>/dev/null

echo
echo "✓ Gauge has been removed."
[ -t 0 ] && read -r -p "Press return to close." _
