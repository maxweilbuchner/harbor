#!/bin/sh
# HTTPS from a Windows program (WinHTTP → secur32 → GnuTLS) in a throwaway bottle on the current runtime.
#   WindowsTests/net/run.sh [host]     # default example.com; needs network access
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
mkdir -p build/WindowsTests/net
"$CC" -O2 -Wall -o build/WindowsTests/net/https.exe WindowsTests/net/https.c -lwinhttp || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="net-test-$$"
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
"$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/net/https.exe" "${1:-example.com}" 2>/dev/null | grep -E '^(PASS|FAIL)'
status=$?
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
exit $status
