#!/bin/sh
# Launches build/app/Harbor.app with the given environment, sizes its window, and captures only that window.
# Fails if Harbor's window isn't there (so it can't capture whatever is behind a crashed app).
#   WindowsTests/ui-screenshot.sh <out.png> [VAR=value ...]
set -eu
cd "$(dirname "$0")/.."
OUT="$1"; shift
pkill -f 'build/app/Harbor.app/Contents/MacOS/Harbor' 2>/dev/null || true; sleep 1
envs=""; for kv in "$@"; do envs="$envs --env $kv"; done
open $envs build/app/Harbor.app
for i in $(seq 1 20); do
  sleep 0.5
  n=$(osascript -e 'tell application "System Events" to count (windows whose name is "Harbor") of (first process whose name is "Harbor")' 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && break
done
[ "${n:-0}" -gt 0 ] || { echo "ui-screenshot: Harbor has no window (crashed?)" >&2; exit 1; }
osascript -e 'tell application "System Events" to tell (first process whose name is "Harbor")
  set frontmost to true
  set position of window "Harbor" to {120, 80}
  set size of window "Harbor" to {900, 600}
end tell' >/dev/null
sleep 1.5
screencapture -x -o -R 120,80,900,600 "$OUT"
echo "ui-screenshot: $OUT"
