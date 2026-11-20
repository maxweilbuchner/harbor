#!/bin/sh
# Downloads the development runtime into Runtime/ (gitignored):
#  - Wine: Gcenx's macOS builds of upstream Wine (LGPL-2.1+), https://github.com/Gcenx/macOS_Wine_builds
#  - D3DMetal: not downloaded here. It is taken from Apple's own Game Porting Toolkit image by
#    scripts/import-d3dmetal.sh (unmodified, redistributed non-commercially under Apple's license §2A(iii), §2C).
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env

mkdir -p "Runtime/download" "Runtime/wine-$WINE_VERSION"
TARBALL="Runtime/download/wine-devel-$WINE_VERSION-osx64.tar.xz"
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" \
  "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VERSION/wine-devel-$WINE_VERSION-osx64.tar.xz"
echo "$WINE_SHA256  $TARBALL" | shasum -a 256 -c -
tar -xJf "$TARBALL" -C "Runtime/wine-$WINE_VERSION"

# D3DMetal comes from Apple's own disk image, which needs an Apple ID to download: scripts/import-d3dmetal.sh.
[ -d "Runtime/d3dmetal-$D3DMETAL_VERSION/lib" ] && scripts/verify-d3dmetal.sh "Runtime/d3dmetal-$D3DMETAL_VERSION/lib" ||
  echo "fetch-runtime: no D3DMetal yet; download Apple's Game Porting Toolkit image and run scripts/import-d3dmetal.sh <dmg>" >&2

echo "Runtime ready: Runtime/wine-$WINE_VERSION"
