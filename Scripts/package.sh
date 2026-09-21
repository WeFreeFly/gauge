#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
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
# Signing and notarisation are optional: without a certificate the packages
# are still built, just ad-hoc signed, and the first launch needs a
# right-click. With one they open like any other app.
#
#   GAUGE_SIGN_IDENTITY      "Developer ID Application: …"  (else auto-detected)
#   GAUGE_INSTALLER_IDENTITY "Developer ID Installer: …"    (else auto-detected)
#   GAUGE_NOTARY_PROFILE     a notarytool keychain profile  (else no notarising)
#
# Create the profile once with:
#   xcrun notarytool store-credentials gauge --apple-id you@example.com \
#         --team-id TEAMID --password <app-specific-password>
APP_IDENTITY="${GAUGE_SIGN_IDENTITY:-}"
if [ -z "$APP_IDENTITY" ]; then
  APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

INSTALLER_IDENTITY="${GAUGE_INSTALLER_IDENTITY:-}"
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null \
    | grep "Developer ID Installer" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
NOTARY_PROFILE="${GAUGE_NOTARY_PROFILE:-}"

AUTHOR="Wefreefly"
AUTHOR_EMAIL="wefreefly@thaisimply.com"
BUILT_WITH="Built with Claude Code"

echo "▸ Gauge $VERSION (build $BUILD)"

"$PROJECT_DIR/build.sh" release
mkdir -p "$OUTPUT_DIR"

[ -d "$APP" ] || { echo "✗ No app at $APP"; exit 1; }

# Notarise and staple the app itself, before it goes into anything.
#
# Stapling the disk image is enough for Gatekeeper when the Mac can reach
# Apple. A ticket on the app travels with it once it is dragged out of the
# image, so a first launch works with no network at all.
notarise_app() {
  [ -n "$NOTARY_PROFILE" ] || return 0
  if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "▸ App already carries a notarisation ticket"
    return 0
  fi

  echo "▸ Notarising the app…"
  local zip
  zip="$(mktemp -d)/Gauge.zip"
  # ditto keeps the bundle's symlinks and metadata; zip(1) does not.
  ditto -c -k --keepParent "$APP" "$zip"
  if xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" \
       --wait --timeout 30m 2>&1 | sed 's/^/    /'; then
    xcrun stapler staple "$APP" >/dev/null 2>&1 \
      && echo "  ✓ notarised and stapled" \
      || echo "  ✗ could not staple the app"
  else
    echo "  ✗ notarisation failed; continuing with the containers"
  fi
  rm -rf "$(dirname "$zip")"
}

notarise_app

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
      ~/Library/Preferences/com.thaisimply.gauge.plist
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
  # Apple recommends signing the image as well as its contents; it also lets
  # the signature be checked before the image is opened.
  if [ -n "$APP_IDENTITY" ]; then
    codesign --force --sign "$APP_IDENTITY" --timestamp "$dmg" 2>/dev/null \
      || echo "  ✗ could not sign the disk image"
  fi

  notarise "$dmg" "disk image"
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
  # The payload must name exactly one install path, and it must be the one we
  # expect — a relocated bundle is how the duplicate-icon problem showed up.
  local paths
  paths="$(pkgutil --payload-files "$pkg" 2>/dev/null | grep -c "^./Applications/Gauge.app$")"
  if [ "$paths" != "1" ]; then
    echo "  ✗ payload does not install to /Applications/Gauge.app"
    exit 1
  fi
  # A relocatable bundle is installed wherever the system thinks a copy
  # already lives. PackageInfo says so two ways; both are checked.
  local info="$expanded/component.pkg/PackageInfo"
  grep -q 'relocatable="false"' "$info" \
    || { echo "  ✗ the package is still marked relocatable"; exit 1; }
  grep -q "<relocate/>" "$info" \
    || { echo "  ✗ the package still lists a bundle to relocate"; exit 1; }

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

# ---------------------------------------------------------------- notarising

# Uploads to Apple, waits for the verdict, and staples it so the result
# travels with the file and works offline. Skipped when no profile is set —
# an unsigned build has nothing to notarise.
notarise() {
  local file="$1" kind="$2"
  [ -n "$NOTARY_PROFILE" ] || return 0

  echo "  notarising the $kind (this takes a few minutes)…"
  if ! xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
       --wait --timeout 30m 2>&1 | sed 's/^/    /'; then
    echo "  ✗ notarisation failed; the $kind is signed but not notarised"
    return 0
  fi
  if xcrun stapler staple "$file" >/dev/null 2>&1; then
    echo "  ✓ notarised and stapled"
  else
    echo "  ✗ could not staple; the $kind still validates online"
  fi
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

  # Two jobs before the payload lands:
  #
  #   1. Stop a running copy, or the old process ends up holding a deleted
  #      bundle.
  #   2. Remove anything already installed. Gauge shipped briefly under the
  #      identifier com.gauge.app, and PackageKit refuses to overwrite a
  #      bundle whose identifier does not match the package — it relocates the
  #      new one into /Applications/Gauge.localized/Gauge.app instead, leaving
  #      two Gauge icons. Clearing the old copy and its receipt first means the
  #      payload installs exactly where it says.
  cat > "$scripts/preinstall" <<'PRE'
#!/bin/bash
pkill -x Gauge 2>/dev/null || true
sleep 1

rm -rf "/Applications/Gauge.app" 2>/dev/null || true
rm -rf "/Applications/Gauge.localized" 2>/dev/null || true

for receipt in com.gauge.app; do
  pkgutil --pkgs | grep -qx "$receipt" && pkgutil --forget "$receipt" >/dev/null 2>&1
done
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

  # Without this the bundle is marked relocatable, and the installer will put
  # it wherever it thinks an existing copy lives rather than where the payload
  # says. That is what produced Gauge.localized.
  local components
  components="$(mktemp -d)/components.plist"
  pkgbuild --analyze --root "$root" "$components" >/dev/null
  /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$components" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$components" >/dev/null 2>&1

  pkgbuild --root "$root" \
           --identifier "$IDENTIFIER" \
           --version "$VERSION" \
           --scripts "$scripts" \
           --component-plist "$components" \
           --install-location / \
           "$component" >/dev/null
  rm -rf "$(dirname "$components")"

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

  # An installer package is signed with its own kind of certificate.
  if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "  signing with ${INSTALLER_IDENTITY}…"
    local signed="${pkg%.pkg}-signed.pkg"
    if productsign --sign "$INSTALLER_IDENTITY" --timestamp "$pkg" "$signed" 2>/dev/null; then
      mv "$signed" "$pkg"
    else
      rm -f "$signed"
      echo "  ✗ could not sign the package; leaving it unsigned"
    fi
  fi

  # Apple will not notarise a package that is not signed with a Developer ID
  # Installer certificate, so saying why beats a rejection from the service.
  if [ -n "$NOTARY_PROFILE" ] && [ -z "$INSTALLER_IDENTITY" ]; then
    echo "  skipping notarisation: a package needs a Developer ID Installer"
    echo "    certificate, and none is installed. The disk image does not."
  else
    notarise "$pkg" "package"
  fi
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
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Signed and notarised — these open on any Mac without a right-click."
elif [ -n "$APP_IDENTITY" ] || [ -n "$INSTALLER_IDENTITY" ]; then
  echo "Signed with:"
  [ -n "$APP_IDENTITY" ]       && echo "  app       $APP_IDENTITY"
  [ -n "$INSTALLER_IDENTITY" ] && echo "  installer $INSTALLER_IDENTITY"
  echo
  echo "Not notarised yet — Gatekeeper still refuses a signed build Apple has"
  echo "not seen. Finish with:"
  echo "  GAUGE_NOTARY_PROFILE=<profile> ./Scripts/package.sh"
else
  echo "Not signed with a Developer ID, so the first launch needs"
  echo "right-click → Open. Install a Developer ID Application certificate"
  echo "and re-run to remove that step."
fi
echo
echo "  open '$OUTPUT_DIR'"
echo
echo "The app bundle itself stays in $APP_OUTPUT."
