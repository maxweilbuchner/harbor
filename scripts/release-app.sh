#!/bin/sh
# Builds, signs and notarizes Harbor.app at a version, zips it, signs the zip for Sparkle (EdDSA key in the
# login keychain, account io.github.maxweilbuchner.harbor) and adds an item to an appcast. A real release also
# gets an installer package (scripts/package-installer.sh): the zip is what installed copies update from, the
# installer is what the website offers for a first download.
#
#   scripts/release-app.sh 0.2.0 --publish
#       real release: GitHub release v0.2.0 (marked latest) with Harbor-0.2.0.zip and Harbor-0.2.0.pkg, item in
#       updates/appcast.xml (commit and push that file afterwards; apps read it from the main branch).
#       Refuses unless everything is committed and pushed and the version is new (release, tag, feed, changelog).
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
  --publish) unset HARBOR_RUNTIME_MANIFEST_URL HARBOR_UPDATE_FEED_URL HARBOR_UPDATE_TEST; PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"; OUT=build/release; APPCAST=updates/appcast.xml ;;
  --local) PREFIX="$2"; OUT="$3"; APPCAST="$OUT/appcast.xml"; mkdir -p "$OUT"; [ -f "$APPCAST" ] || cp updates/appcast.xml "$APPCAST" ;;
  *) echo "usage: release-app.sh <version> --publish | --local <url-prefix> <dir>" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
# Before the build, not after it: a release without its installer would leave the website's button on the old one.
if [ "$MODE" = --publish ] && ! security find-identity -v | grep -qF "${INSTALLER_IDENTITY:-\"Developer ID Installer}"; then
  echo "release-app: no \"Developer ID Installer\" certificate in the keychain (docs/RELEASING.md)" >&2; exit 1
fi
MARKER="<!-- items: newest first, added by scripts/release-app.sh -->"
if [ "$MODE" = --publish ]; then
  # Refused here, before anything is built or published: the release is tagged at this commit, so the commit
  # must be all that is built (nothing uncommitted) and be on GitHub, and the version must be new everywhere.
  no() { echo "release-app: $1" >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || no "there are uncommitted changes; commit them first"
  HEAD_SHA=$(git rev-parse HEAD)
  [ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$HEAD_SHA" ] || no "HEAD isn't what origin's main is at; push (or pull) first"
  grep -q "^## $VERSION (" CHANGELOG.md || no "CHANGELOG.md has no \"## $VERSION (<date>)\" section"
  grep -qF -- "$MARKER" "$APPCAST" || no "$APPCAST has lost its marker line for new items"
  ! grep -qF "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || no "$APPCAST already has an item for $VERSION"
  [ -z "$(git ls-remote origin "refs/tags/v$VERSION")" ] || no "the tag v$VERSION exists already"
  ! gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 || no "the release v$VERSION exists already"
fi
BUILD=$(git rev-list --count HEAD)
[ "$MODE" = --local ] && BUILD="${HARBOR_BUILD:-$BUILD}"

HARBOR_VERSION="$VERSION" HARBOR_BUILD="$BUILD" scripts/bundle-app.sh
if [ "$MODE" = --publish ]; then
  # Belt and braces: what is about to be published must point at the real servers and carry no test flag.
  plist=build/app/Harbor.app/Contents/Info.plist
  feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist"); manifest=$(/usr/libexec/PlistBuddy -c 'Print :HarborRuntimeManifestURL' "$plist")
  case "$feed$manifest" in *127.0.0.1*|*localhost*|*http://*) echo "release-app: bundle points at a test server ($feed, $manifest)" >&2; exit 1 ;; esac
  if /usr/libexec/PlistBuddy -c 'Print :HarborUpdateTest' "$plist" >/dev/null 2>&1; then echo "release-app: bundle carries the update-test flag" >&2; exit 1; fi
fi
scripts/notarize.sh --app-only
ZIP="$OUT/Harbor-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/app/Harbor.app "$ZIP"
SIG=$("$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$ZIP")   # sparkle:edSignature="…" length="…"
case "$SIG" in *edSignature*length*) ;; *) echo "release-app: sign_update failed: $SIG" >&2; exit 1 ;; esac
# The installer, for first downloads. Sparkle doesn't know the element and skips it; the website reads it
# (site/src/lib/release.ts).
INSTALLER=""; PKG=""
if [ "$MODE" = --publish ]; then
  scripts/package-installer.sh "$VERSION" "$OUT"
  PKG="$OUT/Harbor-$VERSION.pkg"
  scripts/notarize.sh --installer "$PKG"
  INSTALLER="
      <harbor:installer url=\"$PREFIX$(basename "$PKG")\" length=\"$(stat -f%z "$PKG")\"/>"
fi

ITEM="    <item>
      <title>Harbor $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$PREFIX$(basename "$ZIP")\" $SIG type=\"application/octet-stream\"/>$INSTALLER
    </item>"
if [ "$MODE" = --publish ]; then
  # The release first, tagged at the commit that was built (without --target GitHub tags whatever main is by
  # then); the feed only points at it once it exists.
  gh release create "v$VERSION" -R "$REPO" --target "$HEAD_SHA" --title "Harbor $VERSION" --latest \
    --notes "Harbor $VERSION. Download Harbor-$VERSION.pkg and open it: it installs Harbor in Applications. Harbor-$VERSION.zip is the same app without an installer, which installed copies update from." "$ZIP" "$PKG"
fi
python3 -I - "$APPCAST" "$ITEM" "$MARKER" <<'PY'
import sys
path, item, marker = sys.argv[1:4]
text = open(path).read()
assert marker in text, "appcast marker missing"
open(path, "w").write(text.replace(marker, marker + "\n" + item, 1))
PY
xmllint --noout "$APPCAST"
echo "release-app: $ZIP, item added to $APPCAST (build $BUILD)"
[ "$MODE" != --publish ] || echo "release-app: published v$VERSION; now commit and push $APPCAST"
