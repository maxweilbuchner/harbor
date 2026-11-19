#!/bin/sh
# Notarizes Harbor.app and the signed Wine runtime with Apple, then staples the app.
# One-time setup (stores an app-specific password in the keychain; run it yourself):
#   xcrun notarytool store-credentials harbor-notary --apple-id <apple-id> --team-id U7YD5SS9RP
#
#   scripts/notarize.sh [runtime-dir]   # default: build/out/wine (sign it first with scripts/sign-runtime.sh)
set -eu
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-harbor-notary}"
RUNTIME="${1:-build/out/wine}"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
mkdir -p build/notarize

submit() { # $1 = zip
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$1.json" || true
  status=$(plutil -extract status raw "$1.json" 2>/dev/null || echo unknown)
  id=$(plutil -extract id raw "$1.json" 2>/dev/null || echo "?")
  echo "notarize: $(basename "$1") → $status ($id)"
  if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" 2>/dev/null | head -40
    exit 1
  fi
}

ditto -c -k --keepParent build/app/Harbor.app build/notarize/Harbor.zip
submit build/notarize/Harbor.zip
xcrun stapler staple build/app/Harbor.app
xcrun stapler validate build/app/Harbor.app

# Loose binaries can't be stapled; Gatekeeper fetches their notarization ticket online on first launch.
ditto -c -k --keepParent "$RUNTIME" build/notarize/runtime.zip
submit build/notarize/runtime.zip

spctl -a -vv build/app/Harbor.app 2>&1 | head -3
