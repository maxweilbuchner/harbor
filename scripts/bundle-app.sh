#!/bin/sh
# Builds build/app/Harbor.app (release), signs it with the Developer ID identity under the hardened runtime,
# and verifies the signature. Notarize afterwards with scripts/notarize.sh.
#
#   scripts/bundle-app.sh            # sign with "Developer ID Application"
#   SIGN_IDENTITY=- scripts/bundle-app.sh   # ad-hoc (local testing only)
#   HARBOR_RUNTIME_MANIFEST_URL=http://127.0.0.1:8765/runtime.json scripts/bundle-app.sh   # test server
set -eu
cd "$(dirname "$0")/.."
VERSION="${HARBOR_VERSION:-0.1.0}"
BUILD="${HARBOR_BUILD:-$(git rev-list --count HEAD)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
BUNDLE_ID="io.github.maxweilbuchner.harbor"
# Published by scripts/publish-runtime.sh; override to test against another server.
RUNTIME_MANIFEST_URL="${HARBOR_RUNTIME_MANIFEST_URL:-https://github.com/maxweilbuchner/harbor/releases/download/runtime/runtime.json}"
# Sparkle appcast, committed in the public repo (scripts/release-app.sh updates it).
UPDATE_FEED_URL="${HARBOR_UPDATE_FEED_URL:-https://raw.githubusercontent.com/maxweilbuchner/harbor/main/updates/appcast.xml}"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi

# Native build system: the default one records the deployment target as the SDK version (see scripts/check.sh).
swift build -c release --build-system native --product Harbor 2>&1 | grep -v "has been deprecated"
BIN="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/Harbor"

APP=build/app/Harbor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Harbor"
# Sparkle (app updates): SwiftPM links it via @loader_path; a bundle keeps frameworks in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Harbor"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Harbor</string>
  <key>CFBundleDisplayName</key><string>Harbor</string>
  <key>CFBundleExecutable</key><string>Harbor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free, non-commercial software. See THIRD_PARTY_NOTICES.md.</string>
  <key>HarborRuntimePublicKey</key><string>$(cat scripts/runtime-signing.pub)</string>
  <key>HarborRuntimeManifestURL</key><string>$RUNTIME_MANIFEST_URL</string>
  <key>SUFeedURL</key><string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$(cat scripts/sparkle-public.key)</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>harbor</string></array>
  </dict></array>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Hardened runtime, secure timestamp. Harbor spawns Wine as separate processes, so it needs no
# JIT/unsigned-memory/library-validation exceptions itself.
TS="--timestamp"; [ "$IDENTITY" = "-" ] && TS=""
sign() { codesign --force --options runtime $TS --sign "$IDENTITY" "$@"; }
# Sparkle's helpers first, innermost out, as Sparkle's documentation prescribes (no --deep).
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|flags|TeamIdentifier' | sed -E 's/TeamIdentifier=.*/TeamIdentifier=(set)/'
echo "bundle-app: $APP ($VERSION build $BUILD)"
