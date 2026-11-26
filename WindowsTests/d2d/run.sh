#!/bin/sh
# Direct2D regression test (d2d.cpp) in a throwaway bottle on the current runtime
# (HARBOR_WINE_ROOT to pick another). Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++"
mkdir -p build/WindowsTests/d2d
"$CC" -O2 -Wall -static -o build/WindowsTests/d2d/d2d.exe WindowsTests/d2d/d2d.cpp -ld2d1 -lole32 -lwindowscodecs -luuid || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="d2d-test-$$"
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
# Direct2D draws through wined3d, and wined3d's Vulkan renderer (the default here) can't create the device it
# asks for: use the OpenGL one, as an Excel bottle does.
"$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\Direct3D' /v renderer /d gl /f >/dev/null 2>&1 || exit 1
"$CLI" stop "$BOTTLE" 2>/dev/null
# The program's own exit status counts as well as its lines (a pipe into grep would report grep's): one that
# prints PASS and then crashes has failed, and so has one that printed fewer results than it has checks.
all=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/d2d/d2d.exe" 2>/dev/null); rc=$?
out=$(printf '%s\n' "$all" | grep -E '^(PASS|FAIL)')
printf '%s\n' "$out"
status=0
printf '%s\n' "$out" | grep -q '^FAIL' && status=1
passed=$(printf '%s\n' "$out" | grep -c '^PASS')
[ "$passed" -eq 4 ] || { echo "FAIL: $passed of 4 checks passed"; status=1; }
[ $rc -eq 0 ] || { echo "FAIL: d2d.exe ended with status $rc"; status=1; }
exit $status
