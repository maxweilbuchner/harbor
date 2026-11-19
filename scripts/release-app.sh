#!/bin/sh
# Builds, signs and notarizes Harbor.app at a version, zips it, signs the zip for Sparkle (EdDSA key in the
# login keychain, account io.github.maxweilbuchner.harbor) and adds an item to an appcast.
#
#   scripts/release-app.sh 0.2.0 --publish
#       real release: GitHub release v0.2.0 (marked latest) with Harbor-0.2.0.zip, item in updates/appcast.xml
#       (commit and push that file afterwards; apps read it from the main branch)
#   scripts/release-app.sh 0.2.0 --local http://127.0.0.1:8766/ build/update-test
#       update test: zip + appcast in build/update-test, download URLs under the given prefix, nothing published
set -eu
cd "$(dirname "$0")/.."
VERSION="$1"; shift
MODE="${1:-}"
REPO=maxweilbuchner/harbor
ACCOUNT=io.github.maxweilbuchner.harbor
SPARKLE_BIN=build/toolchain/sparkle/bin
export PATH="/opt/homebrew/bin:$PATH"
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "release-app: Sparkle tools missing (scripts/fetch-sources.sh)" >&2; exit 1; }

case "$MODE" in
  # A real release must never carry test servers left in the environment.
  --publish) unset HARBOR_RUNTIME_MANIFEST_URL HARBOR_UPDATE_FEED_URL; PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"; OUT=build/release; APPCAST=updates/appcast.xml ;;
  --local) PREFIX="$2"; OUT="$3"; APPCAST="$OUT/appcast.xml"; mkdir -p "$OUT"; [ -f "$APPCAST" ] || cp updates/appcast.xml "$APPCAST" ;;
  *) echo "usage: release-app.sh <version> --publish | --local <url-prefix> <dir>" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
BUILD=$(git rev-list --count HEAD)
[ "$MODE" = --local ] && BUILD="${HARBOR_BUILD:-$BUILD}"

HARBOR_VERSION="$VERSION" HARBOR_BUILD="$BUILD" scripts/bundle-app.sh
scripts/notarize.sh --app-only
ZIP="$OUT/Harbor-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/app/Harbor.app "$ZIP"
SIG=$("$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$ZIP")   # sparkle:edSignature="…" length="…"
case "$SIG" in *edSignature*length*) ;; *) echo "release-app: sign_update failed: $SIG" >&2; exit 1 ;; esac

ITEM="    <item>
      <title>Harbor $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$PREFIX$(basename "$ZIP")\" $SIG type=\"application/octet-stream\"/>
    </item>"
python3 -I - "$APPCAST" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
marker = "<!-- items: newest first, added by scripts/release-app.sh -->"
text = open(path).read()
assert marker in text, "appcast marker missing"
open(path, "w").write(text.replace(marker, marker + "\n" + item, 1))
PY
xmllint --noout "$APPCAST"
echo "release-app: $ZIP, item added to $APPCAST (build $BUILD)"

if [ "$MODE" = --publish ]; then
  gh release create "v$VERSION" -R "$REPO" --title "Harbor $VERSION" --latest \
    --notes "Harbor $VERSION. Download Harbor-$VERSION.zip, unzip, and move Harbor to Applications." "$ZIP"
  echo "release-app: published v$VERSION; now commit and push $APPCAST"
fi
