#!/bin/bash
# Builds Gauge and packages it for installation.
#
#   ./Scripts/package.sh            both a .dmg and a .pkg
#   ./Scripts/package.sh dmg        drag-to-Applications disk image only
#   ./Scripts/package.sh pkg        double-click installer only
#
# Output goes next to the built app, outside the project directory, because
# this tree lives in a synced folder.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${GAUGE_SCRATCH:-$HOME/.cache/gauge-build}"
# The built app stays in the cache — it is rewritten on every build and there
# is no reason to sync ten megabytes of it. The finished installers land in
# the project so they are somewhere findable.
APP_OUTPUT="${GAUGE_OUTPUT:-$SCRATCH/out}"
OUTPUT_DIR="${GAUGE_PACKAGE_OUTPUT:-$PROJECT_DIR/package}"
APP="$APP_OUTPUT/Gauge.app"
WHAT="${1:-all}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
           "$PROJECT_DIR/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
         "$PROJECT_DIR/Resources/Info.plist")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
              "$PROJECT_DIR/Resources/Info.plist")"

# Kept beside the app's own constants in Sources/Gauge/Diagnostics.swift so the
# installer and the About pane say the same thing.
AUTHOR="Wefreefly"
AUTHOR_EMAIL="wefreefly@thaisimply.com"
BUILT_WITH="Built with Claude Code"

echo "▸ Gauge $VERSION (build $BUILD)"

"$PROJECT_DIR/build.sh" release
mkdir -p "$OUTPUT_DIR"

[ -d "$APP" ] || { echo "✗ No app at $APP"; exit 1; }

# ---------------------------------------------------------------- disk image

make_dmg() {
  local staging dmg
  dmg="$OUTPUT_DIR/Gauge-$VERSION.dmg"
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  echo "▸ Building disk image…"
  cp -R "$APP" "$staging/"
  # The symlink is what makes the window a drag-and-drop install.
  ln -s /Applications "$staging/Applications"

  cat > "$staging/Read me first.txt" <<TXT
Gauge $VERSION

Install
  Drag Gauge to the Applications folder beside it.

First launch
  Gauge is signed ad-hoc, not with a paid Developer ID, so macOS will refuse
  the first double-click. Right-click (or Control-click) Gauge in Applications
  and choose Open, then confirm. macOS remembers the choice; afterwards it
  opens normally.

  If macOS still refuses, clear the download flag:
      xattr -dr com.apple.quarantine /Applications/Gauge.app

What it does
  Gauge lives in the menu bar. It reads CPU, GPU, memory, disks, network,
  sensors and battery directly from this Mac. Nothing is sent anywhere unless
  weather or the public-IP lookup is switched on, and both are off by default.

Uninstall
  Run Uninstall Gauge.command from this disk image, or delete the app and
  these files:
      ~/Library/Preferences/com.gauge.app.plist
      ~/Library/Application Support/Gauge

Quit
  Click any Gauge menu bar item and use the power button at the bottom of the
  panel, or right-click a menu bar item and choose Quit Gauge.

$AUTHOR <$AUTHOR_EMAIL>
$BUILT_WITH
TXT

  cp "$PROJECT_DIR/Scripts/uninstall.sh" "$staging/Uninstall Gauge.command"
  chmod +x "$staging/Uninstall Gauge.command"

  rm -f "$dmg"
  hdiutil create -volname "Gauge $VERSION" \
                 -srcfolder "$staging" \
                 -fs HFS+ \
                 -format UDZO -imagekey zlib-level=9 \
                 -quiet "$dmg"
  verify_dmg "$dmg"
  echo "✓ $dmg  ($(du -h "$dmg" | cut -f1))"
}

# Packaging tools report success on output nobody has opened. These mount and
# unpack what was actually produced.
verify_dmg() {
  local dmg="$1" mount
  mount="$(mktemp -d)"
  echo "  verifying…"
  hdiutil attach "$dmg" -nobrowse -readonly -quiet -mountpoint "$mount"
  local failed=0
  [ -d "$mount/Gauge.app" ] || { echo "  ✗ no Gauge.app inside"; failed=1; }
  [ -L "$mount/Applications" ] || { echo "  ✗ no Applications shortcut"; failed=1; }
  if [ -x "$mount/Gauge.app/Contents/MacOS/Gauge" ]; then
    "$mount/Gauge.app/Contents/MacOS/Gauge" --version >/dev/null 2>&1 \
      || { echo "  ✗ the app in the image does not run"; failed=1; }
  else
    echo "  ✗ no executable inside the app"; failed=1
  fi
  hdiutil detach "$mount" -quiet || true
  rmdir "$mount" 2>/dev/null || true
  [ "$failed" -eq 0 ] || exit 1
}

verify_pkg() {
  local pkg="$1" expanded
  expanded="$(mktemp -d)/expanded"
  echo "  verifying…"
  pkgutil --expand-full "$pkg" "$expanded" >/dev/null 2>&1
  local app
  app="$(find "$expanded" -maxdepth 4 -name "Gauge.app" -type d | head -1)"
  if [ -z "$app" ]; then
    echo "  ✗ the package carries no Gauge.app"
    rm -rf "$(dirname "$expanded")"
    exit 1
  fi
  [ -x "$app/Contents/MacOS/Gauge" ] || { echo "  ✗ payload app has no executable"; exit 1; }
  rm -rf "$(dirname "$expanded")"
}

# ------------------------------------------------------------------ installer

make_pkg() {
  local root scripts pkg component
  pkg="$OUTPUT_DIR/Gauge-$VERSION.pkg"
  component="$(mktemp -d)/component.pkg"
  root="$(mktemp -d)"
  scripts="$(mktemp -d)"
  trap 'rm -rf "$root" "$scripts"' RETURN

  echo "▸ Building installer package…"
  mkdir -p "$root/Applications"
  cp -R "$APP" "$root/Applications/"

  # An install over a running copy leaves the old process holding a deleted
  # bundle, so it is stopped first and started again afterwards.
  cat > "$scripts/preinstall" <<'PRE'
#!/bin/bash
pkill -x Gauge 2>/dev/null || true
exit 0
PRE

  cat > "$scripts/postinstall" <<'POST'
#!/bin/bash
# Installers run as root; the app has to start as the person who is logged in.
USER_NAME="$(stat -f%Su /dev/console)"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != "root" ] && \
  launchctl asuser "$(id -u "$USER_NAME")" sudo -u "$USER_NAME" \
    open -a /Applications/Gauge.app 2>/dev/null || true
exit 0
POST

  chmod +x "$scripts/preinstall" "$scripts/postinstall"

  pkgbuild --root "$root" \
           --identifier "$IDENTIFIER" \
           --version "$VERSION" \
           --scripts "$scripts" \
           --install-location / \
           "$component" >/dev/null

  # A distribution package is what gives the installer a title and a
  # readable welcome pane instead of a bare component install.
  local resources distribution
  resources="$(mktemp -d)"
  distribution="$(mktemp -d)/distribution.xml"

  cat > "$resources/welcome.html" <<HTML
<html><body style="font-family:-apple-system;font-size:13px;">
<h2 style="margin-bottom:4px;">Gauge $VERSION</h2>
<p>A menu bar system monitor. It reads CPU, GPU, memory, disks, network,
sensors and battery directly from this Mac.</p>
<p>Nothing leaves the machine unless weather or the public-IP lookup is
switched on, and both are off by default.</p>
<p style="color:#888;">Gauge will be installed in Applications and started
when the installer finishes.</p>
<p style="color:#888;">$AUTHOR &lt;$AUTHOR_EMAIL&gt;<br/>$BUILT_WITH</p>
</body></html>
HTML

  cat > "$distribution" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Gauge $VERSION</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <pkg-ref id="$IDENTIFIER"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default"><pkg-ref id="$IDENTIFIER"/></choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

  rm -f "$pkg"
  productbuild --distribution "$distribution" \
               --resources "$resources" \
               --package-path "$(dirname "$component")" \
               "$pkg" >/dev/null
  rm -rf "$resources" "$(dirname "$distribution")" "$(dirname "$component")"
  verify_pkg "$pkg"
  echo "✓ $pkg  ($(du -h "$pkg" | cut -f1))"
}

case "$WHAT" in
  dmg) make_dmg ;;
  pkg) make_pkg ;;
  all) make_dmg; make_pkg ;;
  *) echo "usage: $0 [dmg|pkg|all]"; exit 1 ;;
esac

echo
echo "Neither is signed with a Developer ID, so the first launch needs"
echo "right-click → Open. That is the only difference from a paid-signed build."
echo
echo "  open '$OUTPUT_DIR'"
echo
echo "The app bundle itself stays in $APP_OUTPUT."
