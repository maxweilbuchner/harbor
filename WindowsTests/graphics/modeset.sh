#!/bin/sh
# What a program's display mode change leaves behind in its bottle (modeset.c), on the current runtime
# (HARBOR_WINE_ROOT to pick another). Changes no real display mode: with Harbor's Wine the mode is emulated.
# Passes if a fullscreen-style change (CDS_FULLSCREEN) is gone once the program has ended, a permanent one stays
# until it is reset, and neither reaches the next Windows session: what Windows does.
# Known gap, not covered: a program started in the moment after every other program of the bottle has ended sees a
# permanent change that a reset no longer undoes, until the session ends (seen 2026-11-23, cause not found).
set -u
cd "$(dirname "$0")/../.."
WindowsTests/graphics/build.sh >/dev/null || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
EXE="$PWD/build/WindowsTests/graphics/modeset.exe"
BOTTLE="modeset-test-$$"
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
# Never without emulation: these steps would change the Mac's real display mode.
"$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\X11 Driver' /v EmulateModeset /d y /f >/dev/null 2>&1
"$CLI" stop "$BOTTLE"
run() { "$CLI" run "$BOTTLE" "$EXE" "$1" 2>/dev/null | grep -E '^(MODE|INFO|FAIL)'; }
mode() { echo "$out" | sed -n "s/^MODE $1 current=\\([0-9x]*\\) .*/\\1/p"; }
out=$(run all); echo "$out"
# A permanent change that nobody undoes, then a new Windows session (the bottle is stopped, like a restart of
# Windows): what it starts with.
run set
"$CLI" stop "$BOTTLE"
later=$(run get); echo "$later"
native=$(mode start); status=0
[ -n "$native" ] || { echo "FAIL: no result"; exit 1; }
check() { if [ "$2" = "$3" ]; then echo "PASS $1: $2"; else echo "FAIL $1: $2, expected $3"; status=1; fi; }
check "after a fullscreen-style change and exit" "$(mode after-set-fs)" "$native"
check "after a permanent change and exit (Windows keeps it)" "$(mode after-set)" 640x480
check "after a reset" "$(mode after-reset)" "$native"
check "in the next session after a permanent change" "$(echo "$later" | sed -n 's/^MODE get current=\([0-9x]*\) .*/\1/p')" "$native"
exit $status
