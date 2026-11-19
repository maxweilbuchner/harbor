#!/bin/sh
# Downloads and verifies the sources and toolchain scripts/build-wine.sh needs, into build/ (gitignored).
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env
mkdir -p build/download build/src build/toolchain
SRC="build/download/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
[ -f "$SRC" ] || curl -fL -o "$SRC" "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
echo "$CROSSOVER_SOURCES_SHA256  $SRC" | shasum -a 256 -c -
# Only what the build uses, to save disk; add components here as they get built.
tar -xzf "$SRC" -C build/src sources/wine sources/gnutls
TS="build/download/libtasn1-$LIBTASN1_VERSION.tar.gz"
[ -f "$TS" ] || curl -fL -o "$TS" "https://ftp.gnu.org/gnu/libtasn1/libtasn1-$LIBTASN1_VERSION.tar.gz"
echo "$LIBTASN1_SHA256  $TS" | shasum -a 256 -c -
[ -d "build/src/libtasn1-$LIBTASN1_VERSION" ] || tar -xzf "$TS" -C build/src
GNT="build/download/gnutls-$GNUTLS_VERSION.tar.xz"
[ -f "$GNT" ] || curl -fL -o "$GNT" "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$GNUTLS_VERSION.tar.xz"
echo "$GNUTLS_SHA256  $GNT" | shasum -a 256 -c -
[ -d "build/src/gnutls-$GNUTLS_VERSION" ] || tar -xJf "$GNT" -C build/src
NT="build/download/nettle-$NETTLE_VERSION.tar.gz"
[ -f "$NT" ] || curl -fL -o "$NT" "https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VERSION.tar.gz"
echo "$NETTLE_SHA256  $NT" | shasum -a 256 -c -
[ -d "build/src/nettle-$NETTLE_VERSION" ] || tar -xzf "$NT" -C build/src
FT="build/download/freetype-$FREETYPE_VERSION.tar.xz"
[ -f "$FT" ] || curl -fL -o "$FT" "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
echo "$FREETYPE_SHA256  $FT" | shasum -a 256 -c -
[ -d "build/src/freetype-$FREETYPE_VERSION" ] || tar -xJf "$FT" -C build/src
MVK="build/download/MoltenVK-macos-$MOLTENVK_VERSION.tar"
[ -f "$MVK" ] || curl -fL -o "$MVK" "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-macos.tar"
echo "$MOLTENVK_SHA256  $MVK" | shasum -a 256 -c -
[ -d "build/src/moltenvk-$MOLTENVK_VERSION" ] || { mkdir -p "build/src/moltenvk-$MOLTENVK_VERSION" && tar -xf "$MVK" -C "build/src/moltenvk-$MOLTENVK_VERSION"; }
MINGW="build/download/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
[ -f "$MINGW" ] || curl -fL -o "$MINGW" "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
echo "$LLVM_MINGW_SHA256  $MINGW" | shasum -a 256 -c -
[ -d "build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal" ] || tar -xJf "$MINGW" -C build/toolchain
# DXMT (Direct3D 10/11 on Metal), prebuilt by its project; shipped inside the runtime under lib/dxmt.
DX="build/download/dxmt-$DXMT_VERSION-builtin.tar.gz"
[ -f "$DX" ] || curl -fL -o "$DX" "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz"
echo "$DXMT_SHA256  $DX" | shasum -a 256 -c -
DXL="build/download/dxmt-$DXMT_VERSION-LICENSE"
[ -f "$DXL" ] || curl -fL -o "$DXL" "https://raw.githubusercontent.com/3Shain/dxmt/$DXMT_VERSION/LICENSE"
echo "$DXMT_LICENSE_SHA256  $DXL" | shasum -a 256 -c -
[ -d "build/src/dxmt-$DXMT_VERSION" ] || { mkdir -p "build/src/dxmt-$DXMT_VERSION" && tar -xzf "$DX" -C "build/src/dxmt-$DXMT_VERSION"; }
# Wine add-ons, installed silently from the runtime's share/wine instead of Wine's download dialog.
fetch() { [ -f "build/download/$2" ] || curl -fL -o "build/download/$2" "https://dl.winehq.org/wine/$1/$2"; echo "$3  build/download/$2" | shasum -a 256 -c -; }
fetch "wine-mono/$WINE_MONO_VERSION" "wine-mono-$WINE_MONO_VERSION-x86.msi" "$WINE_MONO_SHA256"
fetch "wine-gecko/$WINE_GECKO_VERSION" "wine-gecko-$WINE_GECKO_VERSION-x86.msi" "$WINE_GECKO_X86_SHA256"
fetch "wine-gecko/$WINE_GECKO_VERSION" "wine-gecko-$WINE_GECKO_VERSION-x86_64.msi" "$WINE_GECKO_X86_64_SHA256"
# Sparkle's command-line tools (generate_keys, sign_update) for app releases.
SP="build/download/Sparkle-$SPARKLE_VERSION.tar.xz"
[ -f "$SP" ] || curl -fL -o "$SP" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $SP" | shasum -a 256 -c -
[ -x build/toolchain/sparkle/bin/sign_update ] || { mkdir -p build/toolchain/sparkle && tar -xJf "$SP" -C build/toolchain/sparkle; }
command -v /opt/homebrew/opt/bison/bin/bison >/dev/null || { echo "fetch-sources: brew install bison pkgconf" >&2; exit 1; }
echo "fetch-sources: ready"
