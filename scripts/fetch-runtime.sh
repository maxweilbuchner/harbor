#!/bin/sh
# Downloads the development runtime into Runtime/ (gitignored):
#  - Wine: Gcenx's macOS builds of upstream Wine (LGPL-2.1+), https://github.com/Gcenx/macOS_Wine_builds
#  - D3DMetal: Apple's Game Porting Toolkit /redist/lib, unmodified, redistributed non-commercially under
#    Apple's license (§2A(iii), §2C). Every Mach-O in it must carry Apple's own signature or the fetch fails.
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env

mkdir -p "Runtime/download" "Runtime/wine-$WINE_VERSION"
TARBALL="Runtime/download/wine-devel-$WINE_VERSION-osx64.tar.xz"
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" \
  "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VERSION/wine-devel-$WINE_VERSION-osx64.tar.xz"
echo "$WINE_SHA256  $TARBALL" | shasum -a 256 -c -
tar -xJf "$TARBALL" -C "Runtime/wine-$WINE_VERSION"

D3D_DIR="Runtime/download/d3dmetal-$D3DMETAL_VERSION"
D3D_TARBALL="$D3D_DIR/nightforge-d3dmetal-$D3DMETAL_VERSION.tar.gz"
mkdir -p "$D3D_DIR" "Runtime/d3dmetal-$D3DMETAL_VERSION"
[ -f "$D3D_TARBALL" ] || curl -fL -o "$D3D_TARBALL" \
  "https://github.com/LordHayne/Nightforge/releases/download/d3dmetal-$D3DMETAL_VERSION/nightforge-d3dmetal-$D3DMETAL_VERSION.tar.gz"
echo "$D3DMETAL_SHA256  $D3D_TARBALL" | shasum -a 256 -c -
tar -xzf "$D3D_TARBALL" -C "Runtime/d3dmetal-$D3DMETAL_VERSION"
LIB="Runtime/d3dmetal-$D3DMETAL_VERSION/nightforge-d3dmetal-$D3DMETAL_VERSION/lib"
codesign --verify --deep --strict "$LIB/external/D3DMetal.framework"
for f in "$LIB/external/libd3dshared.dylib" "$LIB"/wine/x86_64-unix/*.so "$LIB/external/D3DMetal.framework"; do
  codesign --verify --strict "$f"
  codesign -dv --verbose=2 "$f" 2>&1 | grep -q '^Authority=Apple Root CA$' || { echo "not Apple-signed: $f" >&2; exit 1; }
  codesign -dv --verbose=2 "$f" 2>&1 | grep -q '^Authority=Software Signing$' || { echo "not Apple first-party: $f" >&2; exit 1; }
done

echo "Runtime ready: Runtime/wine-$WINE_VERSION, Runtime/d3dmetal-$D3DMETAL_VERSION"
