#!/bin/sh
# Builds the Windows graphics test programs with llvm-mingw into build/WindowsTests/graphics.
set -eu
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
OUT=build/WindowsTests/graphics
mkdir -p "$OUT"
"$CC" -O2 -Wall -o "$OUT/d3d11tri.exe" WindowsTests/graphics/d3d11tri.c -ld3d11 -ldxgi -luser32
"$CC" -O2 -Wall -o "$OUT/d3d12tri.exe" WindowsTests/graphics/d3d12tri.c -ld3d12 -ldxgi -luser32
"$CC" -O2 -Wall -o "$OUT/d3d11fs.exe" WindowsTests/graphics/d3d11fs.c -ld3d11 -ldxgi -luser32
"$CC" -O2 -Wall -o "$OUT/modeset.exe" WindowsTests/graphics/modeset.c -luser32
"$CC" -O2 -Wall -o "$OUT/spaceprobe.exe" WindowsTests/graphics/spaceprobe.c -luser32 -lgdi32
echo "graphics tests: $OUT"
