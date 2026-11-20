#!/bin/sh
# For "Steam's window comes to the front when returning to a fullscreen game" (#30): starts a Steam game the way
# Harbor's library does, with Wine's focus and window events logged, and records the window order while YOU
# reproduce it (a three-finger swipe can't be scripted).
#
#   WindowsTests/tools/steam-focus-probe.sh [steam-app-id]      # default 2570630 (20 Small Mazes)
#
# Then: wait for the game, make it fullscreen, swipe to another Desktop and back, twice, and quit the game.
# The script ends by itself after 3 minutes or when Steam's bottle stops. Logs: build/focus-probe/.
set -u
cd "$(dirname "$0")/../.."
APP="${1:-2570630}"
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
OUT=build/focus-probe; rm -rf "$OUT"; mkdir -p "$OUT"
STEAM="C:\\Program Files (x86)\\Steam"
if [ -z "${DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
swiftc -O -o "$OUT/focus-probe" WindowsTests/tools/focus-probe.swift 2>/dev/null || { echo "focus-probe: couldn't build the recorder" >&2; exit 1; }
"$CLI" list | grep -q "^Steam	.*	running" && { echo "focus-probe: quit Steam first (it must start with logging on)" >&2; exit 1; }
echo "Starting Steam and game $APP with logging. Reproduce: fullscreen, swipe to another Desktop and back (twice), then quit the game."
WINEDEBUG=+timestamp,+pid,+event,+macdrv "$CLI" run-with Steam d3dmetal start /d "$STEAM" "$STEAM\\steam.exe" -cef-disable-gpu -applaunch "$APP" > "$OUT/wine.log" 2>&1 &
"$OUT/focus-probe" 180 > "$OUT/windows.log" &
REC=$!
sleep 30
while "$CLI" list | grep -q "^Steam	.*	running" && kill -0 $REC 2>/dev/null; do sleep 2; done
kill $REC 2>/dev/null
echo "focus-probe: done. $(wc -l < "$OUT/windows.log" | tr -d ' ') window-order changes, $(wc -l < "$OUT/wine.log" | tr -d ' ') Wine log lines in $OUT/"
