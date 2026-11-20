#!/bin/sh
# Byte-sized syscall argument regression test (narrowargs.c) in a throwaway bottle on the current runtime
# (HARBOR_WINE_ROOT to pick another). Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
mkdir -p build/WindowsTests/abi
"$CC" -O2 -Wall -o build/WindowsTests/abi/narrowargs.exe WindowsTests/abi/narrowargs.c || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="abi-test-$$"
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
out=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/abi/narrowargs.exe" 2>/dev/null | grep -E '^(PASS|FAIL)')
echo "$out"
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
echo "$out" | grep -q FAIL && exit 1
[ -n "$out" ] || { echo "FAIL: no result"; exit 1; }
exit 0
