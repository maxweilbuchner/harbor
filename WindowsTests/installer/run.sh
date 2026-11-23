#!/bin/sh
# The add-program flow with an installer in several files (setup.exe + data file + subfolder), on the current
# runtime: the installer must find its files inside the bottle, and Harbor must find what it installed.
#   WindowsTests/installer/run.sh [target]     # default "C:\Program Files\Harbor Fixture"
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
TARGET="${1:-C:\\Program Files\\Harbor Fixture}"
MEDIA="build/WindowsTests/installer/Fixture Disc $$"
mkdir -p "$MEDIA/Redist"
"$CC" -O2 -Wall -mwindows -o "$MEDIA/setup.exe" WindowsTests/installer/setup.c || exit 1
cp Tests/HarborKitTests/Fixtures/app64.exe "$MEDIA/data-01.bin"
printf '%s\n' "$TARGET" > "$MEDIA/target.txt"
: > "$MEDIA/Redist/marker"
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BEFORE=$("$CLI" list | awk -F'\t' '{ print $NF }')
OUT=$("$CLI" add "$PWD/$MEDIA/setup.exe" 2>&1)
ADDED=$(printf '%s\n' "$OUT" | grep '^added ')
if printf '%s\n' "$ADDED" | grep -qF "$TARGET\\Fixture App.exe"; then echo "PASS $ADDED"; status=0
else echo "FAIL"; printf '%s\n' "$OUT"; status=1; fi
# Remove the bottle this run made (a failed add can leave one too): whatever the list didn't hold before.
"$CLI" list | awk -F'\t' '{ print $NF }' | while read -r ROOT; do
  printf '%s\n' "$BEFORE" | grep -qxF "$ROOT" && continue
  "$CLI" stop "$(basename "$ROOT")" >/dev/null 2>&1
  rm -rf "$ROOT"
done
rm -rf "$MEDIA"
exit $status
