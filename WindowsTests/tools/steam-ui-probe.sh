#!/bin/sh
# Tries Steam launch options until its sign-in window shows real content (not a black rectangle).
# For each option set: restart Steam in the "Steam" bottle, find the "Sign in to Steam" window by its owning
# process, capture just that window, and measure how much of it is non-black.
#   WindowsTests/tools/steam-ui-probe.sh "<options 1>" "<options 2>" ...
set -u
cd "$(dirname "$0")/../.."
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
STEAM="$HOME/Library/Application Support/Harbor/Bottles/steam/prefix/drive_c/Program Files (x86)/Steam/steam.exe"
OUT=build/stores/probe
mkdir -p "$OUT"

window_id() { # CGWindowID of the on-screen "Sign in to Steam" window, if any
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift WindowsTests/tools/windows.swift wine 2>/dev/null | awk '/Sign in to Steam/ {print $1; exit}'
}

for options in "$@"; do
  "$CLI" stop Steam >/dev/null 2>&1; sleep 2
  # shellcheck disable=SC2086
  ("$CLI" run Steam start /unix "$STEAM" $options > "$OUT/run.log" 2>&1 &)
  id=""
  for i in $(seq 1 40); do sleep 2; id=$(window_id); [ -n "$id" ] && break; done
  if [ -z "$id" ]; then echo "[$options] no sign-in window after 80 s"; continue; fi
  sleep 8   # let the page render
  name=$(echo "$options" | tr -c 'a-z0-9' '_')
  screencapture -x -o -l "$id" "$OUT/$name.png"
  python3 -I - "$OUT/$name.png" "$options" <<'PY'
import subprocess, sys, struct, zlib
path, label = sys.argv[1], sys.argv[2]
bmp = path + ".bmp"
subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp], capture_output=True)
d = open(bmp, "rb").read()
off, = struct.unpack_from("<I", d, 10); w, h = struct.unpack_from("<ii", d, 18); bpp, = struct.unpack_from("<H", d, 28)
step = bpp // 8; stride = ((w * step) + 3) & ~3
lit = total = 0
for y in range(0, abs(h), 4):
    for x in range(0, w, 4):
        p = off + y * stride + x * step
        b, g, r = d[p], d[p + 1], d[p + 2]
        total += 1
        lit += (r + g + b) > 60
print(f"[{label}] window {w}x{abs(h)}: {100 * lit / max(total, 1):.0f}% non-black -> {path}")
PY
done
"$CLI" stop Steam >/dev/null 2>&1
