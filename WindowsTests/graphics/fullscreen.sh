#!/bin/sh
# Checks what actually reaches the screen across fullscreen transitions (WindowsTests/graphics/d3d11fs.c).
# Samples only an 8x8 block at the screen centre (in phase 1 a second one lower down) and compares its colour;
# nothing else is recorded. In phase 2 it moves the pointer to a known place and back, to check where Windows
# sees it. Needs Screen Recording and Accessibility permission for the terminal and a GUI session; don't touch
# the Mac while it runs (~70 s). Phase 3 briefly activates Finder and switches back (Cmd-Tab); phase 4 switches
# Spaces away and back, then opens/closes Mission Control (three-finger swipes).
#
#   WindowsTests/graphics/fullscreen.sh [backend] [passive|guided]   # default d3dmetal
#   OWN_SPACE=n WindowsTests/graphics/fullscreen.sh dxmt passive     # without a fullscreen Space of its own
#   EMULATE_MODESET=n WindowsTests/graphics/fullscreen.sh dxmt passive   # the program's mode change is real
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
# EMULATE_MODESET=y|n sets Wine's display-mode emulation (a program's mode change never reaches the real display).
if [ -n "${EMULATE_MODESET:-}" ]; then
  "$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\X11 Driver' /v EmulateModeset /d "$EMULATE_MODESET" /f >/dev/null 2>&1
  "$CLI" stop "$BOTTLE"
fi

# Screen centre in points of the main display (the one with the menu bar), where fullscreen games appear.
# (Finder's desktop bounds span all displays.)
read -r SW SH <<EOF
$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.screens.objectAtIndex(0).frame; f.size.width + " " + f.size.height')
EOF
case "${SW:-}${SH:-}" in ''|*[!0-9.]*) echo "FAIL: couldn't read the screen size"; exit 1;; esac
SW=${SW%.*}; SH=${SH%.*}
CX=$((SW / 2 - 4)); CY=$((SH / 2 - 4))
# A second block low on the screen: a low-resolution fullscreen program must fill the screen, not sit in its middle.
# Phase 1 takes both from one capture (a strip from the centre block down to this one): the phase is short.
LY=$((SH * 85 / 100))

ran=0
sample() { # $1 = label, $2 = expected r,g,b (0/255); $3 = top|bottom of an existing capture $4 instead of a new one
  ran=$((ran + 1))
  [ -n "${3:-}" ] || screencapture -x -R "$CX,$CY,8,8" -t bmp "$OUT/$1.bmp" 2>/dev/null
  python3 -I - "${4:-$OUT/$1.bmp}" "$1" "$2" "${3:-}" <<'PY'
import struct, sys
path, label, want, where = sys.argv[1], sys.argv[2], tuple(int(v) for v in sys.argv[3].split(",")), sys.argv[4]
d = open(path, "rb").read()
off, = struct.unpack_from("<I", d, 10); w, h = struct.unpack_from("<ii", d, 18); bpp, = struct.unpack_from("<H", d, 28)
stride = ((w * bpp // 8) + 3) & ~3
rows = abs(h)
from_top = {"top": 4, "bottom": rows - 5}.get(where, rows // 2)  # 4 px in: inside the 8-point block at 1x and 2x
y = rows - 1 - from_top if h > 0 else from_top                    # a positive height means bottom-up rows
x = w // 2
b, g, r = d[off + y * stride + x * (bpp // 8): off + y * stride + x * (bpp // 8) + 3]
ok = all(abs(a - e) <= 40 for a, e in zip((r, g, b), want))
if label.endswith("-away"):  # while switched away, the game's colour must NOT be on screen
    ok = not ok
    want = ("not",) + want
print(f"{'PASS' if ok else 'FAIL'} {label}: screen rgb=({r},{g},{b}) expected={want}")
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
wait_for "PHASE 1" && front && sleep 2.5 && {
  screencapture -x -R "$CX,$CY,8,$((LY - CY + 8))" -t bmp "$OUT/$BACKEND-1-strip.bmp" 2>/dev/null
  sample "$BACKEND-1-fullscreen" 0,255,0 top "$OUT/$BACKEND-1-strip.bmp" || status=1
  sample "$BACKEND-1-fullscreen-low" 0,255,0 bottom "$OUT/$BACKEND-1-strip.bmp" || status=1; }
wait_for "PHASE 2" && sleep 2.5 && { sample "$BACKEND-2-reentered" 255,255,0 || status=1; }
# The pointer, put a quarter in from the left and a quarter up from the bottom of the Mac's screen: the program
# reports where Windows sees it at the end of phase 2 (pointer_check below). It is put back afterwards.
PX=$((SW / 4)); PY=$((SH * 3 / 4))
WAS=$(osascript -l JavaScript -e "ObjC.import('CoreGraphics'); var p = \$.CGEventGetLocation(\$.CGEventCreate(null)); \$.CGWarpMouseCursorPosition(\$.CGPointMake($PX, $PY)); Math.round(p.x) + ',' + Math.round(p.y)" 2>/dev/null)
pointer_check() { # the CURSOR line against where the pointer was put, through the scaling of an emulated mode
  ran=$((ran + 1))
  python3 -I - "$LOG" "$SW" "$SH" "$PX" "$PY" "$BACKEND" <<'PY'
import re, sys
log, sw, sh, px, py, backend = sys.argv[1], *map(float, sys.argv[2:6]), sys.argv[6]
m = re.search(r"^CURSOR (-?\d+) (-?\d+) of (\d+)x(\d+)", open(log, errors="replace").read(), re.M)
if not m:
    print(f"FAIL {backend}-2-pointer: the program reported no pointer position"); sys.exit(1)
x, y, w, h = map(float, m.groups())
scale = min(sw / w, sh / h)                       # the mode keeps its shape: bars at the sides or top and bottom
ex, ey = (px - (sw - w * scale) / 2) / scale, (py - (sh - h * scale) / 2) / scale
# Loose enough for the camera housing's strip in a fullscreen Space, far tighter than an unscaled position.
ok = abs(x - ex) <= 0.05 * w and abs(y - ey) <= 0.08 * h
print(f"{'PASS' if ok else 'FAIL'} {backend}-2-pointer: Windows sees ({x:.0f},{y:.0f}) of {w:.0f}x{h:.0f}, "
      f"expected about ({ex:.0f},{ey:.0f}) for ({px:.0f},{py:.0f}) of {sw:.0f}x{sh:.0f}")
sys.exit(0 if ok else 1)
PY
}
if wait_for "PHASE 3"; then
  pointer_check || status=1
  [ -n "$WAS" ] && osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($WAS))" >/dev/null 2>&1
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
# A program that never got to a phase (or wasn't found to bring to the front) must not pass with fewer checks.
expected=7; [ "$MODE" = guided ] && expected=9
[ "$ran" -eq "$expected" ] || { echo "FAIL: $ran of $expected checks ran"; status=1; }
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
exit $status
