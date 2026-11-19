#!/bin/sh
# Cross-process drawing regression test (xprocdraw.c: no white columns beside partial updates) in a throwaway bottle on the current runtime
# (HARBOR_WINE_ROOT to pick another). Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
mkdir -p build/WindowsTests/xproc
"$CC" -O2 -Wall -o build/WindowsTests/xproc/xprocdraw.exe WindowsTests/xproc/xprocdraw.c -lgdi32 || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="xproc-test-$$"
"$CLI" create "$BOTTLE" >/dev/null || exit 1
out=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/xproc/xprocdraw.exe" 2>/dev/null | grep -E '^(PASS|FAIL)')
echo "$out"
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
echo "$out" | grep -q FAIL && exit 1
[ -n "$out" ] || { echo "FAIL: no result"; exit 1; }
exit 0
