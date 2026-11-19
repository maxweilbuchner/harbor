#!/bin/sh
# Harbor's full bar: build, test, and verify every product links against the newest installed SDK.
#
# Uses the newest Xcode in /Applications unless DEVELOPER_DIR is set (the Command Line Tools lack the
# SwiftUI macro plugins). Builds with SwiftPM's native build system because the default one (Swift Build)
# records the deployment target as the SDK version in LC_BUILD_VERSION, which opts the app out of newer
# framework behaviour. Revisit when the app moves to an Xcode project (milestone M4).
set -eu
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ]; then
  XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | while read -r app; do
    printf '%s\t%s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$app"
  done | sort -V | tail -1 | cut -f2)
  [ -n "$XCODE" ] || { echo "check: no Xcode found in /Applications" >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
SDK=$(xcrun --sdk macosx --show-sdk-version)
echo "check: $(xcodebuild -version | head -1), macOS SDK $SDK"

BUILD="swift build --build-system native"
TEST="swift test --build-system native"
# Run each step, keep its real exit status, then show its output without the native-build deprecation note.
# (Piping straight into grep would report grep's status and let a failed build pass.)
run() {
  log=$(mktemp)
  "$@" > "$log" 2>&1; rc=$?
  grep -v "has been deprecated" "$log"; rm -f "$log"
  [ $rc -eq 0 ] || { echo "check: FAILED: $*" >&2; exit $rc; }
}
run $BUILD
run $TEST

BIN=$(swift build --build-system native --show-bin-path 2>/dev/null)
for product in Harbor harbor-cli; do
  RECORDED=$(otool -l "$BIN/$product" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; exit}')
  if [ "$RECORDED" != "$SDK" ]; then
    echo "check: $product records SDK $RECORDED, expected $SDK" >&2
    exit 1
  fi
done
echo "check: all products link against macOS SDK $SDK"
