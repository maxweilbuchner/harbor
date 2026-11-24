#!/bin/sh
# Program file name regression test (hello.c) in a throwaway bottle on the current runtime (HARBOR_WINE_ROOT to
# pick another): programs whose file is named like an entry of the loader link directory ("ntdll.so.exe",
# "..exe") start, both directly and from another Windows program. Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
OUT=build/WindowsTests/appname
mkdir -p "$OUT"
"$CC" -O2 -Wall -o "$OUT/hello.exe" WindowsTests/appname/hello.c || exit 1
for name in ntdll.so.exe ..exe; do cp "$OUT/hello.exe" "$OUT/$name" || exit 1; done
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="appname-test-$$"
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
status=0; ran=0
check() { # $1 = label, $2 = expected lines, the rest = the program and its arguments
  label=$1; want=$2; shift 2; ran=$((ran + 1))
  all=$("$CLI" run "$BOTTLE" "$@" 2>/dev/null); rc=$?
  out=$(printf '%s\n' "$all" | tr -d '\r' | grep -E '^(HELLO|SPAWNED|FAIL)' | tr '\n' ' ')
  if [ "$out" = "$want " ] && [ $rc -eq 0 ]; then echo "PASS: $label"
  else echo "FAIL: $label: got '$out' (status $rc), expected '$want'"; status=1; fi
}
check "hello.exe starts (control)" "HELLO" "$PWD/$OUT/hello.exe"
for name in ntdll.so.exe ..exe; do
  check "$name starts" "HELLO" "$PWD/$OUT/$name"
  check "$name starts from another program" "HELLO SPAWNED 0" "$PWD/$OUT/hello.exe" spawn "$name"
done
[ "$ran" -eq 5 ] || { echo "FAIL: $ran of 5 checks ran"; status=1; }
exit $status
