#!/bin/sh
# The Mac's Quit regression test (quitprobe.c) in a throwaway bottle on the current runtime (HARBOR_WINE_ROOT to
# pick another): a Quit asks a program's windows to close, as their close buttons would, instead of ending the
# process; a program without a window to close is still ended. The Quit is the quit Apple Event
# (NSRunningApplication's terminate), which reaches winemac's applicationShouldTerminate: exactly as Cmd-Q,
# the menu's Quit and the Dock's do, and needs no Accessibility permission. Opens small windows; needs a GUI
# session (~40 s). Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
OUT=build/WindowsTests/quit
mkdir -p "$OUT"
"$CC" -O2 -Wall -o "$OUT/quitprobe.exe" WindowsTests/quit/quitprobe.c || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="quit-test-$$"
# The program and its throwaway bottle go however the run ends, an interruption included.
RUN=""
cleanup() { [ -z "$RUN" ] || kill "$RUN" 2>/dev/null; "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1

status=0; ran=0
pass() { ran=$((ran + 1)); echo "PASS: $1"; }
fail() { ran=$((ran + 1)); echo "FAIL: $1"; status=1; }
# The Windows program's Mac process: the newest one naming it (harbor-cli, which names it too, is older).
probe_pid() { pgrep -n -f 'quitprobe.exe' || true; }
quit() { # $1 = pid; prints "sent" when the process is a Mac app that took the request
  osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); a.isNil() ? 'no app' : (a.terminate ? 'sent' : 'not sent')" 2>&1
}
start() { # $1 = mode ("" for none); sets LOG, RUN, PID once the program printed READY
  LOG="$OUT/${1:-close}.log"; PID=""
  "$CLI" run "$BOTTLE" "$PWD/$OUT/quitprobe.exe" $1 > "$LOG" 2>/dev/null &
  RUN=$!
  i=0; while ! grep -q '^READY' "$LOG" 2>/dev/null; do sleep 0.2; i=$((i + 1)); [ $i -gt 300 ] && return 1; done
  sleep 2   # the window is on screen and the process registered as a Mac app
  PID=$(probe_pid); [ -n "$PID" ]
}
gone() { # waits up to $1 seconds for the program's run to end
  i=0; while kill -0 "$RUN" 2>/dev/null; do sleep 0.5; i=$((i + 1)); [ $i -gt $(($1 * 2)) ] && return 1; done; return 0
}
finish() { kill "$RUN" 2>/dev/null; "$CLI" stop "$BOTTLE" 2>/dev/null; RUN=""; }
seen() { tr -d '\r' < "$LOG" | grep -aE '^(READY|WM_|EXIT|FAIL)' | tr '\n' ';'; }   # the program's own lines (Wine logs there too)
lines() { tr -d '\r' < "$LOG" | grep -c "^$1" ; }

# 1. A window that closes when asked: the program is asked, and ends by itself.
if start ""; then
  sent=$(quit "$PID")
  if [ "$sent" != sent ]; then fail "Quit closes a program's window: the Quit wasn't delivered ($sent)"
  elif gone 15 && [ "$(lines 'WM_CLOSE main')" -eq 1 ] && [ "$(lines 'EXIT clean')" -eq 1 ]; then
    pass "Quit closes a program's window: it got WM_CLOSE and ended by itself"
  else fail "Quit closes a program's window: got '$(seen)' (expected WM_CLOSE main, EXIT clean)"; fi
else fail "Quit closes a program's window: the program didn't start"; fi
finish

# 2. A window that stays open when asked (a cancelled "save changes?"): the program keeps running, every time.
if start keep; then
  sent=$(quit "$PID"); sleep 4; sent2=$(quit "$PID"); sleep 4
  if [ "$sent" != sent ] || [ "$sent2" != sent ]; then fail "Quit leaves a program that declines running: the Quit wasn't delivered ($sent, $sent2)"
  elif kill -0 "$PID" 2>/dev/null && [ "$(lines 'WM_CLOSE main')" -eq 2 ]; then
    pass "Quit leaves a program that declines running: it got WM_CLOSE twice and is still there"
  else fail "Quit leaves a program that declines running: got '$(seen)', running: $(kill -0 "$PID" 2>/dev/null && echo yes || echo no)"; fi
else fail "Quit leaves a program that declines running: the program didn't start"; fi
finish

# 3. A main window disabled behind a dialog it owns: neither is asked (their close buttons couldn't be used
# either), and the program keeps running.
if start dialog; then
  sent=$(quit "$PID"); sleep 4
  if [ "$sent" != sent ]; then fail "Quit leaves a program showing a dialog alone: the Quit wasn't delivered ($sent)"
  elif kill -0 "$PID" 2>/dev/null && [ "$(lines 'WM_')" -eq 0 ]; then
    pass "Quit leaves a program showing a dialog alone: no message, still running"
  else fail "Quit leaves a program showing a dialog alone: got '$(seen)', running: $(kill -0 "$PID" 2>/dev/null && echo yes || echo no)"; fi
else fail "Quit leaves a program showing a dialog alone: the program didn't start"; fi
finish

# 4. No window to close: the program is ended, as before.
if start hidden; then
  sent=$(quit "$PID")
  if [ "$sent" != sent ]; then fail "Quit ends a program without windows: the Quit wasn't delivered ($sent)"
  elif gone 15 && [ "$(lines 'WM_CLOSE')" -eq 0 ]; then pass "Quit ends a program without windows"
  else fail "Quit ends a program without windows: got '$(seen)', running: $(kill -0 "$PID" 2>/dev/null && echo yes || echo no)"; fi
else fail "Quit ends a program without windows: the program didn't start"; fi
finish

[ "$ran" -eq 4 ] || { echo "FAIL: $ran of 4 checks ran"; status=1; }
exit $status
