#!/bin/sh
# Checks what actually reaches the screen across fullscreen transitions (WindowsTests/graphics/d3d11fs.c).
# Samples only an 8x8 block at the screen centre at each phase and compares its colour; nothing else is
# recorded. Needs Screen Recording and Accessibility permission for the terminal and a GUI session; don't
# touch the Mac while it runs (~70 s). Phase 3 briefly activates Finder and switches back (Cmd-Tab);
# phase 4 switches Spaces away and back, then opens/closes Mission Control (three-finger swipes).
#
#   WindowsTests/graphics/fullscreen.sh [backend] [passive|guided]   # default d3dmetal
#   OWN_SPACE=n WindowsTests/graphics/fullscreen.sh dxmt passive     # without a fullscreen Space of its own
#     passive = the app ignores reactivation; guided = voice-prompted real three-finger swipe to another Space
set -u
cd "$(dirname "$0")/../.."
BACKEND="${1:-d3dmetal}"
MODE="${2:-}"
WindowsTests/graphics/build.sh >/dev/null
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
OUT=build/WindowsTests/graphics/fullscreen
BOTTLE="fullscreen-test-$$"
mkdir -p "$OUT"
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
# OWN_SPACE=n runs with Wine's raised-window fullscreen instead of a macOS fullscreen Space (Harbor's patch 0011).
if [ -n "${OWN_SPACE:-}" ]; then
  "$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\Mac Driver' /v FullscreenInOwnSpace /d "$OWN_SPACE" /f >/dev/null 2>&1
  "$CLI" stop "$BOTTLE"
fi

# Screen centre in points of the main display (the one with the menu bar), where fullscreen games appear.
# (Finder's desktop bounds span all displays.)
read -r SW SH <<EOF
$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.screens.objectAtIndex(0).frame; f.size.width + " " + f.size.height')
EOF
CX=$((SW / 2 - 4)); CY=$((SH / 2 - 4))

sample() { # $1 = label, $2 = expected r,g,b (0/255)
  screencapture -x -R "$CX,$CY,8,8" -t bmp "$OUT/$1.bmp" 2>/dev/null
  python3 -I - "$OUT/$1.bmp" "$1" "$2" <<'PY'
import struct, sys
path, label, want = sys.argv[1], sys.argv[2], tuple(int(v) for v in sys.argv[3].split(","))
d = open(path, "rb").read()
off, = struct.unpack_from("<I", d, 10); w, h = struct.unpack_from("<ii", d, 18); bpp, = struct.unpack_from("<H", d, 28)
stride = ((w * bpp // 8) + 3) & ~3
y = abs(h) // 2; x = w // 2
b, g, r = d[off + y * stride + x * (bpp // 8): off + y * stride + x * (bpp // 8) + 3]
ok = all(abs(a - e) <= 40 for a, e in zip((r, g, b), want))
if label.endswith("-away"):  # while switched away, the game's colour must NOT be on screen
    ok = not ok
    want = ("not",) + want
print(f"{'PASS' if ok else 'FAIL'} {label}: screen centre rgb=({r},{g},{b}) expected={want}")
sys.exit(0 if ok else 1)
PY
}

LOG="$OUT/$BACKEND${MODE:+-$MODE}.log"
"$CLI" run-with "$BOTTLE" "$BACKEND" "$PWD/build/WindowsTests/graphics/d3d11fs.exe" $([ "$MODE" = passive ] && echo passive) > "$LOG" 2>&1 &
RUN=$!
wait_for() { i=0; while ! grep -q "$1" "$LOG" 2>/dev/null; do sleep 0.2; i=$((i + 1)); [ $i -gt 600 ] && return 1; done; return 0; }

status=0
front() { PID=$(pgrep -n -f 'd3d11fs.exe' || true)
  [ -n "$PID" ] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; }
# A program started from a terminal isn't activated by macOS; bring it to the front first (Harbor must too).
wait_for "PHASE 1" && front && sleep 2.5 && { sample "$BACKEND-1-fullscreen" 0,255,0 || status=1; }
wait_for "PHASE 2" && sleep 2.5 && { sample "$BACKEND-2-reentered" 255,255,0 || status=1; }
if wait_for "PHASE 3"; then
  sleep 1.5
  osascript -e 'tell application "Finder" to activate' >/dev/null
  sleep 2
  front
  sleep 3
  sample "$BACKEND${MODE:+-$MODE}-3-after-focus-switch" 0,255,255 || status=1
fi
if wait_for "PHASE 4"; then
  sleep 1.5
  if [ "$MODE" = guided ]; then
    # A real three-finger swipe to another Space and back, prompted by voice (the game covers the screen).
    say "Swipe three fingers to another space now."; sleep 4
    sample "$BACKEND-guided-4-space-away" 255,255,255 || { status=1; echo "  (still on the game: no Space switch happened)"; }
    say "Now swipe back to the white screen."; sleep 5
    sample "$BACKEND-guided-4-after-space-switch" 255,255,255 || status=1
  fi
  # Mission Control (three-finger swipe up). Opened via its app, which works even with shortcuts disabled.
  open -a "Mission Control"; sleep 2
  sample "$BACKEND${MODE:+-$MODE}-5-mission-control-away" 255,255,255 || { status=1; echo "  (Mission Control didn't open)"; }
  open -a "Mission Control"; sleep 3
  sample "$BACKEND${MODE:+-$MODE}-5-after-mission-control" 255,255,255 || status=1
fi
wait "$RUN"
grep -E '^(INFO|FAIL)' "$LOG" | sed 's/^/  /'
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
exit $status
