#!/bin/sh
# Takes D3DMetal from Apple's own Game Porting Toolkit disk image into Runtime/d3dmetal-<version>/ (gitignored).
# Apple's download needs an Apple ID, so it can't be fetched by a script: get "Game Porting Toolkit <version>"
# from https://developer.apple.com/download/all/ and pass the .dmg here.
#
#   scripts/import-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_4.0_beta_3.dmg
#
# The image must be exactly the pinned one (SHA-256 in versions.env), which is what covers the unsigned Windows
# DLLs; the Mach-O files must carry Apple's signature. Nothing is modified: the files are copied as they are.
set -eu
DMG="${1:?usage: import-d3dmetal.sh <Game_Porting_Toolkit .dmg>}"
cd "$(dirname "$0")/.."
. scripts/versions.env
[ -f "$DMG" ] || { echo "import-d3dmetal: no such file: $DMG" >&2; exit 1; }
echo "$D3DMETAL_DMG_SHA256  $DMG" | shasum -a 256 -c - >/dev/null || { echo "import-d3dmetal: not the pinned image (expected SHA-256 $D3DMETAL_DMG_SHA256)" >&2; exit 1; }

WORK=$(mktemp -d)
OUTER="$WORK/outer"; INNER="$WORK/inner"; mkdir "$OUTER" "$INNER"
cleanup() { hdiutil detach "$INNER" -quiet 2>/dev/null || true; hdiutil detach "$OUTER" -quiet 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$OUTER" -quiet < /dev/null
EVAL=$(find "$OUTER" -maxdepth 1 -name 'Evaluation environment for Windows games*.dmg' | head -1)
[ -n "$EVAL" ] || { echo "import-d3dmetal: no evaluation environment image inside $DMG" >&2; exit 1; }
hdiutil attach "$EVAL" -nobrowse -readonly -noautoopen -mountpoint "$INNER" -quiet < /dev/null
scripts/verify-d3dmetal.sh "$INNER/redist/lib"
build=$(/usr/libexec/PlistBuddy -c 'Print :BuildVersion' "$INNER/redist/lib/external/D3DMetal.framework/Versions/A/Resources/version.plist")
short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INNER/redist/lib/external/D3DMetal.framework/Resources/Info.plist")
[ "$short-$build" = "$D3DMETAL_VERSION" ] || { echo "import-d3dmetal: image holds $short-$build, versions.env pins $D3DMETAL_VERSION" >&2; exit 1; }

DEST="Runtime/d3dmetal-$D3DMETAL_VERSION"
rm -rf "$DEST" && mkdir -p "$DEST"
cp -R "$INNER/redist/lib" "$DEST/lib"
cp "$INNER/License.rtf" "$INNER/Acknowledgements.rtf" "$DEST/"
xattr -cr "$DEST"
scripts/verify-d3dmetal.sh "$DEST/lib"
echo "import-d3dmetal: $DEST (D3DMetal $D3DMETAL_VERSION from Apple's image)"
