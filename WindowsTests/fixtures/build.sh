#!/bin/sh
# Rebuilds the committed PE fixtures in Tests/HarborKitTests/Fixtures (needs scripts/fetch-sources.sh's llvm-mingw).
# Sources live here, outside the Swift test target (SwiftPM rejects C files in a Swift target).
#   app64.exe  64-bit GUI app with version info + icon, no DirectX
#   game64.exe 64-bit GUI program importing d3d11 + dxgi + xinput, with version info + icon
#   d3dapp64.exe 64-bit GUI app importing only d3d11 + dxgi (an app that renders with DirectX, not a game)
#   app32.exe  32-bit GUI app with version info + icon
set -eu
cd "$(dirname "$0")"
. ../../scripts/versions.env
T="../../build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin"
OUT=../../Tests/HarborKitTests/Fixtures
mkdir -p "$OUT"
W=$(mktemp -d)
python3 -I src/make_icon.py "$W/fixture.ico"
cp src/fixture.rc "$W/"
res() { # $1 = arch prefix, $2 = description, $3 = product, $4 = output .o
  "$T/$1-w64-mingw32-windres" -I "$W" -DFIXTURE_DESCRIPTION="\\\"$2\\\"" -DFIXTURE_PRODUCT="\\\"$3\\\"" "$W/fixture.rc" -O coff -o "$4"
}
res x86_64 "Fixture App" "Fixture App" "$W/app64.o"
"$T/x86_64-w64-mingw32-clang" -O1 -mwindows -o "$OUT/app64.exe" src/app.c "$W/app64.o"
res x86_64 "Fixture Game" "Fixture Game" "$W/game64.o"
"$T/x86_64-w64-mingw32-clang" -O1 -mwindows -o "$OUT/game64.exe" src/game.c "$W/game64.o" -ld3d11 -ldxgi -lxinput1_4
res x86_64 "Fixture D3D App" "Fixture D3D App" "$W/d3dapp64.o"
"$T/x86_64-w64-mingw32-clang" -O1 -mwindows -DNO_XINPUT -o "$OUT/d3dapp64.exe" src/game.c "$W/d3dapp64.o" -ld3d11 -ldxgi
res i686 "Fixture App 32" "Fixture App 32" "$W/app32.o"
"$T/i686-w64-mingw32-clang" -O1 -mwindows -o "$OUT/app32.exe" src/app.c "$W/app32.o"
rm -rf "$W"
ls -la "$OUT"/*.exe | awk '{print $5, $9}'
