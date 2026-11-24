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
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
# The program's own exit status counts as well as its lines (a pipe into grep would report grep's): one that
# prints PASS and then crashes has failed, and so has one that printed fewer results than it has checks.
all=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/xproc/xprocdraw.exe" 2>/dev/null); rc=$?
out=$(printf '%s\n' "$all" | grep -E '^(PASS|FAIL)')
printf '%s\n' "$out"
status=0
printf '%s\n' "$out" | grep -q '^FAIL' && status=1
passed=$(printf '%s\n' "$out" | grep -c '^PASS')
[ "$passed" -eq 1 ] || { echo "FAIL: $passed of 1 checks passed"; status=1; }
[ $rc -eq 0 ] || { echo "FAIL: xprocdraw.exe ended with status $rc"; status=1; }
exit $status
