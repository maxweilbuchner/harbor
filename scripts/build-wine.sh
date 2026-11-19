#!/bin/sh
# Builds Harbor's Wine from CodeWeavers' LGPL CrossOver sources into build/out/wine.
#
#   scripts/build-wine.sh            # deps (if missing), configure, build, install
#   scripts/build-wine.sh configure  # stop after configure
#
# Wine on Apple silicon is an x86_64 program run by Rosetta, so the whole build runs in an x86_64 shell
# (`arch -x86_64`): configure then sees a native x86_64 host and Xcode's universal clang targets x86_64.
# Windows-side code (PE) is built with llvm-mingw for both i386 and x86_64 (wow64).
# Everything stays under build/ (gitignored); nothing is installed system-wide.
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env
ROOT=$(pwd)
B="$ROOT/build"
SRC="$B/src/sources"
DEPS="$B/deps/x86_64"
OUT="$B/out/wine"
OBJ="$B/obj/wine"
MINGW="$B/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin"
JOBS=$(sysctl -n hw.ncpu)

if [ "$(uname -m)" != x86_64 ]; then
  exec arch -x86_64 /bin/sh "$0" "$@"
fi

[ -d "$SRC/wine" ] || { echo "build-wine: run scripts/fetch-sources.sh first" >&2; exit 1; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$MINGW:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET="$WINE_MACOS_MIN"
# Absolute Xcode clang: llvm-mingw's bin/ also contains a `clang`, which can't link Mach-O.
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
export CC="$(/usr/bin/xcrun -f clang) -arch x86_64" CXX="$(/usr/bin/xcrun -f clang++) -arch x86_64"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
# build/ lives inside Harbor's git checkout; keep dependency build scripts from running git against it.
export GIT_CEILING_DIRECTORIES="$B"

# --- freetype (fonts; Wine loads it at runtime). Upstream release: CrossOver's copy lacks the dlg submodule. ---
if [ ! -f "$DEPS/lib/libfreetype.dylib" ]; then
  rm -rf "$B/obj/freetype" && mkdir -p "$B/obj/freetype" && cd "$B/obj/freetype"
  "$B/src/freetype-$FREETYPE_VERSION/configure" --prefix="$DEPS" --host=x86_64-apple-darwin \
    --without-harfbuzz --without-png --without-brotli --without-bzip2 --with-zlib=yes
  make -j"$JOBS" && make install
  cd "$ROOT"
fi

# --- MoltenVK (Vulkan on Metal; CrossOver's Wine requires Vulkan on macOS). Upstream universal release. ---
MVK="$B/src/moltenvk-$MOLTENVK_VERSION/MoltenVK/MoltenVK"
if [ ! -f "$DEPS/lib/libMoltenVK.dylib" ]; then
  mkdir -p "$DEPS/lib" "$DEPS/include"
  cp -R "$MVK/include/vulkan" "$MVK/include/vk_video" "$MVK/include/MoltenVK" "$DEPS/include/"
  cp "$MVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$DEPS/lib/"
fi

# --- Wine ---
mkdir -p "$OBJ" && cd "$OBJ"
if [ ! -f Makefile ] || [ "${1:-}" = configure ]; then
  "$SRC/wine/configure" --prefix="$OUT" \
    --enable-archs=i386,x86_64 --with-mingw \
    --disable-tests --without-x --without-wayland \
    --without-gstreamer --without-gnutls --without-sdl \
    --without-capi --without-cups --without-dbus --without-gphoto --without-gssapi --without-krb5 \
    --without-netapi --without-oss --without-pcap --without-pcsclite --without-sane --without-udev \
    --without-usb --without-v4l2 --without-inotify \
    CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
    BISON=/opt/homebrew/opt/bison/bin/bison
fi
[ "${1:-}" = configure ] && exit 0
make -j"$JOBS"
rm -rf "$OUT" && make install
# Libraries Wine loads at runtime travel with the runtime.
cp "$DEPS"/lib/libfreetype.6.dylib "$DEPS"/lib/libMoltenVK.dylib "$OUT/lib/"
ln -sf libfreetype.6.dylib "$OUT/lib/libfreetype.dylib"
# Add-ons Wine installs into new prefixes from $WINEDATADIR (set by Wine relative to itself, so relocatable).
mkdir -p "$OUT/share/wine/mono" "$OUT/share/wine/gecko"
cp "$B/download/wine-mono-$WINE_MONO_VERSION-x86.msi" "$OUT/share/wine/mono/"
cp "$B/download/wine-gecko-$WINE_GECKO_VERSION-x86.msi" "$B/download/wine-gecko-$WINE_GECKO_VERSION-x86_64.msi" "$OUT/share/wine/gecko/"
echo "build-wine: installed $OUT"
