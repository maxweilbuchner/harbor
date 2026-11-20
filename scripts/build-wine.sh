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
  exec arch -x86_64 /bin/sh "$ROOT/scripts/build-wine.sh" "$@"   # absolute: we already cd'ed
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
  # Explicit exits: `make && make install` doesn't stop the script under `set -e` when make fails.
  make -j"$JOBS" || { echo "build-wine: freetype failed to build" >&2; exit 1; }
  make install || exit 1
  cd "$ROOT"
fi

# --- MoltenVK (Vulkan on Metal; CrossOver's Wine requires Vulkan on macOS). Upstream universal release. ---
MVK="$B/src/moltenvk-$MOLTENVK_VERSION/MoltenVK/MoltenVK"
if [ ! -f "$DEPS/lib/libMoltenVK.dylib" ]; then
  mkdir -p "$DEPS/lib" "$DEPS/include"
  cp -R "$MVK/include/vulkan" "$MVK/include/vk_video" "$MVK/include/MoltenVK" "$DEPS/include/"
  cp "$MVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$DEPS/lib/"
fi

# --- GnuTLS stack (TLS for Windows programs: bcrypt, secur32, crypt32). GMP from CrossOver's sources;
# Nettle (CrossOver's copy has no generated configure) and GnuTLS (CrossOver's 3.8.3 fails to link here)
# from their upstream releases. ---
GT="$SRC/gnutls"
build_dep() { # $1 = name, $2 = source dir, $3... = configure args
  name=$1; srcdir=$2; shift 2
  rm -rf "$B/obj/$name" && mkdir -p "$B/obj/$name" && cd "$B/obj/$name"
  CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
    "$srcdir/configure" --prefix="$DEPS" --host=x86_64-apple-darwin --disable-static "$@" || exit 1
  # Explicit exits: the callers run this as `[ -f … ] || build_dep …`, where `set -e` doesn't apply.
  make -j"$JOBS" || { echo "build-wine: $name failed to build" >&2; exit 1; }
  make install || exit 1
  cd "$ROOT"
}
[ -f "$DEPS/lib/libgmp.dylib" ] || build_dep gmp "$GT/gmp" --enable-shared
[ -f "$DEPS/lib/libnettle.dylib" ] || build_dep nettle "$B/src/nettle-$NETTLE_VERSION" --enable-shared \
  --disable-documentation --disable-openssl --with-include-path="$DEPS/include" --with-lib-path="$DEPS/lib"
[ -f "$DEPS/lib/libtasn1.dylib" ] || build_dep libtasn1 "$B/src/libtasn1-$LIBTASN1_VERSION" --enable-shared --disable-doc
[ -f "$DEPS/lib/libgnutls.dylib" ] || build_dep gnutls "$B/src/gnutls-$GNUTLS_VERSION" --enable-shared \
  --with-included-unistring --without-p11-kit --without-idn --without-zstd \
  --without-brotli --without-tpm --without-tpm2 --disable-doc --disable-tests --disable-tools --disable-cxx \
  --disable-guile --disable-nls \
  NETTLE_CFLAGS="-I$DEPS/include" NETTLE_LIBS="-L$DEPS/lib -lnettle" HOGWEED_CFLAGS="-I$DEPS/include" \
  HOGWEED_LIBS="-L$DEPS/lib -lhogweed" GMP_CFLAGS="-I$DEPS/include" GMP_LIBS="-L$DEPS/lib -lgmp" --disable-gost  # GnuTLS 3.8.3 bundles GOST code that clashes with Nettle 3.10

# --- Wine ---
# Harbor's patches on top of CrossOver's sources (LGPL; published in this repo), applied in order. The source tree
# records what it has in .harbor-patches (name and SHA-256), because a patch can't be recognised by test-reversing
# it once a later patch changes the same file. A patch that changed after it was applied stops the build.
STAMP="$SRC/wine/.harbor-patches"
touch "$STAMP"
for p in "$ROOT"/scripts/patches/wine/*.patch; do
  [ -f "$p" ] || continue
  name=$(basename "$p"); sum=$(shasum -a 256 "$p" | cut -d' ' -f1)
  if grep -qxF "$name $sum" "$STAMP"; then continue; fi
  if grep -q "^$name " "$STAMP"; then
    echo "build-wine: $name changed since it was applied; remove $SRC/wine and run scripts/fetch-sources.sh" >&2; exit 1
  fi
  if patch -d "$SRC/wine" -p1 -s -f --no-backup-if-mismatch --dry-run < "$p" >/dev/null 2>&1; then
    patch -d "$SRC/wine" -p1 -s -f --no-backup-if-mismatch < "$p" || exit 1
    echo "build-wine: applied $name"
  elif ! patch -d "$SRC/wine" -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
    # Neither applies nor reverses: not this tree's state (trees patched before the record existed pass the reverse test).
    echo "build-wine: $name doesn't apply" >&2; exit 1
  fi
  echo "$name $sum" >> "$STAMP"
done
mkdir -p "$OBJ" && cd "$OBJ"
if [ ! -f Makefile ] || [ "${1:-}" = configure ]; then
  "$SRC/wine/configure" --prefix="$OUT" \
    --enable-archs=i386,x86_64 --with-mingw \
    --disable-tests --without-x --without-wayland \
    --without-gstreamer --without-sdl \
    --without-capi --without-cups --without-dbus --without-gphoto --without-gssapi --without-krb5 \
    --without-netapi --without-oss --without-pcap --without-pcsclite --without-sane --without-udev \
    --without-usb --without-v4l2 --without-inotify \
    CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
    BISON=/opt/homebrew/opt/bison/bin/bison \
    ac_cv_func_pipe2=no   # in the macOS 27 SDK but not on older macOS; Wine calls it unguarded (weak import = crash)
fi
[ "${1:-}" = configure ] && exit 0
make -j"$JOBS"
rm -rf "$OUT" && make install
# Libraries Wine loads at runtime travel with the runtime.
RUNTIME_LIBS="libfreetype.6.dylib libMoltenVK.dylib libgnutls.30.dylib libnettle.8.dylib libhogweed.6.dylib libgmp.10.dylib libtasn1.6.dylib"
for lib in $RUNTIME_LIBS; do cp -L "$DEPS/lib/$lib" "$OUT/lib/"; done
ln -sf libfreetype.6.dylib "$OUT/lib/libfreetype.dylib"
# Make the copies relocatable: they reference each other by absolute build paths; point those at
# @loader_path, then re-sign (install_name_tool invalidates the signature).
for lib in $RUNTIME_LIBS; do
  f="$OUT/lib/$lib"
  install_name_tool -id "@rpath/$lib" "$f" 2>/dev/null
  for dep in $(otool -L "$f" | awk 'NR>1{print $1}' | grep "^$DEPS/lib/"); do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done
  codesign -f -s - "$f" 2>/dev/null
done
# (otool -L's first line per file is the file's own path, which is under $B, so skip it.)
for f in "$OUT"/lib/*.dylib; do
  # otool must succeed: under `arch -x86_64` the /usr/bin shim can fail to load libxcrun and print nothing,
  # which would make this check pass without checking anything.
  deps=$(otool -arch x86_64 -L "$f") || { echo "build-wine: otool failed on $f" >&2; exit 1; }
  left=$(printf '%s\n' "$deps" | awk 'NR>1{print $1}' | grep "^$B/" || true)
  if [ -n "$left" ]; then
    echo "build-wine: absolute build path left in $f: $left" >&2; exit 1
  fi
done
# Add-ons Wine installs into new prefixes from $WINEDATADIR (set by Wine relative to itself, so relocatable).
mkdir -p "$OUT/share/wine/mono" "$OUT/share/wine/gecko"
cp "$B/download/wine-mono-$WINE_MONO_VERSION-x86.msi" "$OUT/share/wine/mono/"
cp "$B/download/wine-gecko-$WINE_GECKO_VERSION-x86.msi" "$B/download/wine-gecko-$WINE_GECKO_VERSION-x86_64.msi" "$OUT/share/wine/gecko/"
# DXMT (Direct3D 10/11 on Metal) beside Wine's own DLLs, not over them: Harbor overlays it per launch for
# programs that need it (Sources/HarborKit/DXMT.swift), since its dxgi would break Wine's Direct3D 12.
DXS="$B/src/dxmt-$DXMT_VERSION/$DXMT_VERSION"
[ -d "$DXS" ] || { echo "build-wine: run scripts/fetch-sources.sh first (DXMT)" >&2; exit 1; }
mkdir -p "$OUT/lib/dxmt"
for arch in x86_64-windows i386-windows x86_64-unix; do cp -R "$DXS/$arch" "$OUT/lib/dxmt/"; done
cp "$B/download/dxmt-$DXMT_VERSION-LICENSE" "$OUT/lib/dxmt/LICENSE"
printf '%s\n' "$DXMT_VERSION" > "$OUT/lib/dxmt/VERSION"
codesign -f -s - "$OUT/lib/dxmt/x86_64-unix/winemetal.so" 2>/dev/null
echo "build-wine: installed $OUT"
