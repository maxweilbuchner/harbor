#!/bin/sh
# Signs every Mach-O file in a Wine runtime with the Developer ID identity under the hardened runtime
# (executables get scripts/wine.entitlements), so it can be notarized and runs even when quarantined.
# Apple's D3DMetal files are never touched: they are already Apple-signed and must stay unmodified.
#
#   scripts/sign-runtime.sh <runtime-dir>                 # e.g. build/out/wine
#   SIGN_IDENTITY=- scripts/sign-runtime.sh <runtime-dir> # ad-hoc + hardened (local testing)
set -eu
cd "$(dirname "$0")/.."
DIR="$1"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
# Exactly one certificate may match: with a renewed certificate beside the old one, codesign calls the bare name
# ambiguous. SIGN_IDENTITY then takes the SHA-1 of the one to use (security find-identity -v -p codesigning).
if [ "$IDENTITY" != "-" ]; then
  n=$(security find-identity -v -p codesigning | grep -cF "$IDENTITY" || true)
  [ "$n" -eq 1 ] || { echo "sign-runtime: $n certificates in the keychain match \"$IDENTITY\"; set SIGN_IDENTITY (docs/RELEASING.md)" >&2; exit 1; }
fi
ENT="$PWD/scripts/wine.entitlements"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
TS="--timestamp"; [ "$IDENTITY" = "-" ] && TS=""

count=0
# Libraries first, then executables (a signature covers nothing inside other files, so order only
# matters for bundles; kept for clarity).
find "$DIR" -type f \( -name '*.dylib' -o -name '*.so' \) -not -path '*/D3DMetal.framework/*' -not -name 'libd3dshared.dylib' |
while read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  codesign --force --options runtime $TS --sign "$IDENTITY" "$f" 2>/dev/null
done
find "$DIR/bin" -type f -perm -u+x | while read -r f; do
  file -b "$f" | grep -q 'Mach-O.*executable' || continue
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$f" 2>/dev/null
done
# Wine's preloader/loader live in lib/wine/x86_64-unix too.
find "$DIR/lib/wine" -type f -perm -u+x -not -name '*.so' | while read -r f; do
  file -b "$f" | grep -q 'Mach-O.*executable' || continue
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$f" 2>/dev/null
done

# Verify: every Mach-O except Apple's must now carry a hardened, valid signature.
bad=0
find "$DIR" -type f -not -path '*/D3DMetal.framework/*' -not -name 'libd3dshared.dylib' | while read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  if ! codesign --verify --strict "$f" 2>/dev/null || ! codesign -dv "$f" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "sign-runtime: not hardened/valid: $f" >&2; echo bad
  fi
done | grep -q bad && { echo "sign-runtime: FAILED" >&2; exit 1; }
n=$(find "$DIR" -type f -not -path '*/D3DMetal.framework/*' -not -name 'libd3dshared.dylib' -exec file -b {} + 2>/dev/null | grep -c 'Mach-O' || true)
echo "sign-runtime: $n Mach-O files signed (hardened) in $DIR"
