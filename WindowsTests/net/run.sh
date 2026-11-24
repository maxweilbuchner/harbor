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
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
# The program's own exit status counts as well as its lines (a pipe into grep would report grep's): one that
# prints PASS and then crashes has failed, and so has one that printed fewer results than it has checks.
all=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/net/https.exe" "${1:-example.com}" 2>/dev/null); rc=$?
out=$(printf '%s\n' "$all" | grep -E '^(PASS|FAIL)')
printf '%s\n' "$out"
status=0
printf '%s\n' "$out" | grep -q '^FAIL' && status=1
passed=$(printf '%s\n' "$out" | grep -c '^PASS')
[ "$passed" -eq 1 ] || { echo "FAIL: $passed of 1 checks passed"; status=1; }
[ $rc -eq 0 ] || { echo "FAIL: https.exe ended with status $rc"; status=1; }
exit $status
