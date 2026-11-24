#!/bin/sh
# The add-program flow with an installer in several files (setup.exe + data file + subfolder), on the current
# runtime: the installer must find its files inside the bottle, and Harbor must find what it installed.
#   WindowsTests/installer/run.sh [--disk-image] [--folder] [target]     # default target "C:\Program Files\Harbor Fixture"
# --disk-image: the installer sits on a mounted read-only disk image, which must become drive D: for the
# install (nothing copied) and be gone afterwards. Without it the folder is cloned into the bottle.
# --folder: the installer's folder is what gets added, not setup.exe itself.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
IMAGE=""; [ "${1:-}" = "--disk-image" ] && { IMAGE=yes; shift; }
ENTRY="/setup.exe"; [ "${1:-}" = "--folder" ] && { ENTRY=""; shift; }
TARGET="${1:-C:\\Program Files\\Harbor Fixture}"
WORK="$PWD/build/WindowsTests/installer"
MEDIA="$WORK/Fixture Disc $$"
# The bottle this run made (a failed add can leave one too): among what the list didn't hold before, the one
# the fixture installer marked with this run's number. Another new bottle is somebody else's (the app, a second
# session) and is never touched.
INSTALLED="prefix/drive_c/$(printf '%s' "$TARGET" | sed 's/^C:\\//; s/\\/\//g')"
mine() {
  "$CLI" list | awk -F'\t' '{ print $NF }' | while read -r ROOT; do
    printf '%s\n' "$BEFORE" | grep -qxF "$ROOT" && continue
    [ "$(cat "$ROOT/$INSTALLED/installed-by.txt" 2>/dev/null)" = "$$" ] || { echo "not this run's, left alone: $ROOT" >&2; continue; }
    printf '%s\n' "$ROOT"
  done
}
# The media, the image and that bottle go however the run ends, an interruption included. A run interrupted
# before its installer marked the bottle can't tell it from somebody else's: that one is named and stays.
LISTED=""; SEEN=""; MOUNTED=""
cleanup() {
  [ -z "$LISTED" ] || { if [ -n "$SEEN" ]; then printf '%s\n' "$NEW"; else mine; fi; } | while read -r ROOT; do
    [ -n "$ROOT" ] || continue
    "$CLI" stop "$(basename "$ROOT")" >/dev/null 2>&1
    rm -rf "$ROOT"
  done
  [ -z "$MOUNTED" ] || hdiutil detach -quiet "$FROM"
  rm -rf "$MEDIA" "$WORK/disc-$$.dmg"
}
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
mkdir -p "$MEDIA/Redist"
"$CC" -O2 -Wall -mwindows -o "$MEDIA/setup.exe" WindowsTests/installer/setup.c || exit 1
cp Tests/HarborKitTests/Fixtures/app64.exe "$MEDIA/data-01.bin"
printf '%s\n' "$TARGET" > "$MEDIA/target.txt"
: > "$MEDIA/Redist/marker"
: > "$MEDIA/Manual.pdf"      # install media ships documents too; the folder still comes along
printf '%s' "$$" > "$MEDIA/run.txt"   # the installer leaves it in the bottle: how this run knows its own bottle
FROM="$MEDIA"; EXPECT='C:\windows\temp\harbor-import\'
if [ -n "$IMAGE" ]; then
  hdiutil create -quiet -srcfolder "$MEDIA" -volname "HarborFixture$$" -format UDZO "$WORK/disc-$$.dmg" || exit 1
  hdiutil attach -quiet -nobrowse -readonly "$WORK/disc-$$.dmg" || exit 1
  FROM="/Volumes/HarborFixture$$"; EXPECT='D:'; MOUNTED=yes
fi
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BEFORE=$("$CLI" list | awk -F'\t' '{ print $NF }'); LISTED=yes
OUT=$("$CLI" add "$FROM$ENTRY" 2>&1)
ADDED=$(printf '%s\n' "$OUT" | grep '^added ')
status=1
if printf '%s\n' "$ADDED" | grep -qF "$TARGET\\Fixture App.exe"; then status=0; fi
NEW=$(mine); SEEN=yes
[ -n "$NEW" ] || { echo "no bottle carries this run's mark"; status=1; }
while read -r ROOT; do
  [ -n "$ROOT" ] || continue
  RAN=$(cat "$ROOT/$INSTALLED/installed-from.txt" 2>/dev/null)
  case "$RAN" in "$EXPECT"*) ;; *) echo "ran from: ${RAN:-?} (expected $EXPECT…)"; status=1 ;; esac
  [ -e "$ROOT/prefix/dosdevices/d:" ] || [ -L "$ROOT/prefix/dosdevices/d:" ] && { echo "drive D: is still there"; status=1; }
  [ -e "$ROOT/prefix/drive_c/windows/temp/harbor-import" ] && { echo "the import area is still there"; status=1; }
done <<EOF
$NEW
EOF
if [ $status -eq 0 ]; then printf 'PASS %s\tran from %s\n' "$ADDED" "$EXPECT"; else echo "FAIL"; printf '%s\n' "$OUT"; fi
exit $status
