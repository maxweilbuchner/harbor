#!/bin/sh
# Checks what reaches the screen from a swap chain in a child window (WindowsTests/graphics/childswap.c), through
# wined3d's OpenGL renderer, which is what Office uses (#94). Captures the test program's own window by its
# window number, so other windows in front of it or another Space being shown don't matter, and samples three
# places in it. Modes: blt and alpha (worked before the patches), flip (0029), none (0030), stack (0031),
# still (0034).
# Needs Screen Recording permission for the terminal and a GUI session.
#
#   WindowsTests/graphics/childswap.sh               # all six modes
#   WindowsTests/graphics/childswap.sh "flip none"   # some of them
set -u
cd "$(dirname "$0")/../.."
WindowsTests/graphics/build.sh >/dev/null || exit 1   # never test an executable left from an earlier build
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
OUT=build/WindowsTests/graphics/childswap
BOTTLE="childswap-test-$$"
mkdir -p "$OUT"
RUN=""
cleanup() { [ -z "$RUN" ] || kill "$RUN" 2>/dev/null; "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
"$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\Direct3D' /v renderer /d gl /f >/dev/null 2>&1 || exit 1
"$CLI" stop "$BOTTLE" 2>/dev/null
status=0
for mode in ${1:-blt alpha flip none stack still}; do
  log="$OUT/$mode.log"; : > "$log"
  "$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/graphics/childswap.exe" "$mode" > "$log" 2>/dev/null &
  RUN=$!
  i=0; while [ $i -lt 60 ] && ! grep -q '^READY' "$log"; do sleep 0.5; i=$((i+1)); done
  grep -q '^READY' "$log" || { echo "FAIL $mode: the program never got to its last frame: $(grep '^FAIL' "$log" | head -1)"; status=1; kill $RUN 2>/dev/null; RUN=""; "$CLI" stop "$BOTTLE"; continue; }
  sleep 1.5
  # --all: the window may be on another Space than the one in front (a fullscreen app, say).
  id=$(swift WindowsTests/tools/windows.swift wine --all 2>/dev/null | grep 'Harbor child swap test' | head -1 | cut -d' ' -f1)
  [ -n "$id" ] || { echo "FAIL $mode: the program's window wasn't found"; status=1; kill $RUN 2>/dev/null; RUN=""; "$CLI" stop "$BOTTLE"; continue; }
  screencapture -x -o -l "$id" "$OUT/$mode.png"
  sips -s format bmp "$OUT/$mode.png" --out "$OUT/$mode.bmp" >/dev/null 2>&1
  # The image is the window with its title bar; the client area is 640x480 points at the bottom of it.
  python3 - "$OUT/$mode.bmp" "$mode" <<'PY' || status=1
import struct, sys
data = open(sys.argv[1], 'rb').read(); mode = sys.argv[2]
off = struct.unpack('<I', data[10:14])[0]; w, h = struct.unpack('<ii', data[18:26]); bpp = struct.unpack('<H', data[28:30])[0] // 8
top_down = h < 0; h = abs(h); row = (w * bpp + 3) // 4 * 4
scale = w / 640.0; title = h - 480 * scale
def at(x, y):   # client coordinates in points -> (r, g, b)
    px, py = int(x * scale), int(title + y * scale)
    line = py if top_down else h - 1 - py
    b, g, r = data[off + line * row + px * bpp: off + line * row + px * bpp + 3]
    return (r, g, b)
def near(c, want): return all(abs(a - b) <= 40 for a, b in zip(c, want))
# Two places in the child (in its own coordinates) and the colours wanted there. For "none" both are near the
# green block's right edge at x = 200: scaled down with the 500-wide buffer, the edge would be at 160.
# For "stack" the first is in the inner window, the second beside it in the outer one.
places = {'blt': ((100, 150), (300, 150)), 'alpha': ((100, 150), (300, 150)), 'flip': ((100, 150), (300, 150)),
          'none': ((185, 75), (215, 75)), 'stack': ((200, 150), (50, 150)), 'still': ((100, 150), (300, 150))}[mode]
want = {'blt': ((0, 0, 255), (0, 0, 255)), 'alpha': ((0, 0, 255), (0, 0, 255)), 'flip': ((0, 255, 0), (255, 0, 0)),
        'none': ((0, 255, 0), (255, 0, 0)), 'stack': ((0, 255, 0), (255, 0, 0)), 'still': ((0, 0, 255), (0, 0, 255))}[mode]
outside = at(30, 30)
first, second = (at(120 + x, 80 + y) for x, y in places)
ok = near(outside, (255, 255, 255)) and near(first, want[0]) and near(second, want[1])
print("%s %s: outside the child %s, at %s %s, at %s %s (expected white, %s, %s)" % ("PASS" if ok else "FAIL", mode, outside, places[0], first, places[1], second, want[0], want[1]))
sys.exit(0 if ok else 1)
PY
  kill $RUN 2>/dev/null; RUN=""; "$CLI" stop "$BOTTLE"
done
echo "images: $OUT"
exit $status
