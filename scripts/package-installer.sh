#!/bin/sh
# Wraps build/app/Harbor.app (signed, notarized and stapled: scripts/bundle-app.sh, scripts/notarize.sh) in an
# installer package that puts it in /Applications. When it is done, macOS's Installer offers to move the
# package to the Trash. Notarize the result with scripts/notarize.sh --installer <pkg>.
#
#   scripts/package-installer.sh <version> [out-dir]     # build/release/Harbor-<version>.pkg, signed with
#                                                        # the "Developer ID Installer" identity
#   INSTALLER_IDENTITY=- scripts/package-installer.sh …  # unsigned, to look at locally (Gatekeeper refuses it)
set -eu
cd "$(dirname "$0")/.."
VERSION="$1"; OUT="${2:-build/release}"
IDENTITY="${INSTALLER_IDENTITY:-Developer ID Installer}"
BUNDLE_ID="io.github.maxweilbuchner.harbor"
APP=build/app/Harbor.app
PKG="$OUT/Harbor-$VERSION.pkg"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
[ -d "$APP" ] || { echo "package-installer: $APP is missing (scripts/bundle-app.sh)" >&2; exit 1; }
BUNDLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$BUNDLED" = "$VERSION" ] || { echo "package-installer: $APP is version $BUNDLED, not $VERSION" >&2; exit 1; }
if [ "$IDENTITY" != "-" ]; then
  # What the installer puts on a Mac must open there without a network connection.
  xcrun stapler validate "$APP" >/dev/null 2>&1 || { echo "package-installer: $APP isn't notarized and stapled (scripts/notarize.sh --app-only)" >&2; exit 1; }
  security find-identity -v | grep -q "\"$IDENTITY" || { echo "package-installer: no \"$IDENTITY\" certificate in the keychain (docs/RELEASING.md)" >&2; exit 1; }
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/packages" "$OUT"
ditto "$APP" "$WORK/root/Applications/Harbor.app"
# Not relocatable: otherwise the Installer looks for a Harbor.app anywhere on the Mac (an older copy in Downloads,
# a build folder) and updates that one instead of installing into /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Delete :0:BundleIsRelocatable' "$WORK/component.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts scripts/installer \
  --identifier "$BUNDLE_ID" --version "$VERSION" --install-location / "$WORK/packages/Harbor.pkg" >/dev/null
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Harbor</title>
  <options customize="never" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
  <choices-outline><line choice="harbor"/></choices-outline>
  <choice id="harbor" title="Harbor"><pkg-ref id="$BUNDLE_ID"/></choice>
  <pkg-ref id="$BUNDLE_ID" version="$VERSION">Harbor.pkg</pkg-ref>
</installer-gui-script>
XML
rm -f "$PKG"
if [ "$IDENTITY" = "-" ]; then
  productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages" "$PKG" >/dev/null
else
  productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages" \
    --sign "$IDENTITY" --timestamp "$PKG" >/dev/null
  pkgutil --check-signature "$PKG" | grep -q 'Developer ID Installer' || { echo "package-installer: $PKG isn't signed" >&2; exit 1; }
fi
echo "package-installer: $PKG ($(du -h "$PKG" | cut -f1))"
