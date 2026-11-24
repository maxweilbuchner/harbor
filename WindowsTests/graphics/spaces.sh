#!/bin/sh
# Which windows get a macOS fullscreen Space of their own, and who is in front after a Desktop comes back
# (WindowsTests/graphics/spaceprobe.c; Wine patches 0011 and 0017), in a throwaway bottle on the current runtime
# (HARBOR_WINE_ROOT to pick another).
#  1. A program's opaque screen-sized window gets a Space, also when it is topmost; a see-through, click-through,
#     tool or never-activated window of that size (a dimmer, a region picker, an overlay) doesn't; a window that
#     goes back to a small size while macOS still animates it ends up on the Desktop.
#  2. A fullscreen program without a Space of its own (FullscreenInOwnSpace=n) is out of view on another Space;
#     the user picks another app whose window is on its Desktop: that app is in front afterwards, not the
#     fullscreen program.
# Counts the Mac's fullscreen Spaces and reads the frontmost app; records nothing of the screen. Opens screen-sized
# windows and switches Spaces; needs a GUI session and, for part 2, permission to control System Events (as
# fullscreen.sh does). Don't touch the Mac while it runs (~3 min). Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
WindowsTests/graphics/build.sh >/dev/null || exit 1   # never test an executable left from an earlier build
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
G=build/WindowsTests/graphics
OUT=$G/spaces
BOTTLE="spaces-test-$$"
mkdir -p "$OUT"
# Part 2 runs three programs at once, told apart by their file names.
for n in small raised own; do cp "$G/spaceprobe.exe" "$G/spaceprobe-$n.exe" || exit 1; done
# The programs and their throwaway bottle go however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
"$CLI" run "$BOTTLE" reg add 'HKCU\Software\Wine\AppDefaults\spaceprobe-raised.exe\Mac Driver' /v FullscreenInOwnSpace /d n /f >/dev/null 2>&1
"$CLI" stop "$BOTTLE"

# "<fullscreen Spaces on all displays> <pid of the frontmost app>". The Spaces come from the window server's
# list of them (type 4 = a fullscreen Space); there is no public call for it.
mac() {
  osascript -l JavaScript -e '
    ObjC.import("AppKit");
    ObjC.bindFunction("CGSMainConnectionID", ["int", []]);
    ObjC.bindFunction("CGSCopyManagedDisplaySpaces", ["id", ["int"]]);
    var displays = $.CGSCopyManagedDisplaySpaces($.CGSMainConnectionID()), n = 0;
    for (var i = 0; i < displays.count; i++) {
      var spaces = displays.objectAtIndex(i).objectForKey("Spaces");
      for (var j = 0; j < spaces.count; j++) if (ObjC.unwrap(spaces.objectAtIndex(j).objectForKey("type")) == 4) n++;
    }
    n + " " + $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier' 2>/dev/null
}
fullscreen_spaces() { set -- $(mac); echo "${1:-?}"; }
frontmost() { set -- $(mac); echo "${2:-?}"; }
settle() { # waits until the Mac has $1 fullscreen Spaces again (a closed window's Space takes a moment to go)
  i=0; while [ "$(fullscreen_spaces)" != "$1" ]; do sleep 0.5; i=$((i + 1)); [ $i -gt 20 ] && return 1; done; return 0
}
start() { # $1 = program, $2 = kind, $3 = seconds; prints the program's Mac pid once its window is up
  "$CLI" run "$BOTTLE" "$PWD/$G/$1.exe" "$2" "$3" > "$OUT/$1-$2.log" 2>/dev/null &
  i=0; while ! grep -aq '^READY' "$OUT/$1-$2.log" 2>/dev/null; do sleep 0.2; i=$((i + 1)); [ $i -gt 300 ] && return 1; done
  sleep 1; pgrep -n -f "$1.exe"
}

# A program started from a terminal isn't activated by macOS while another app is in use; bring it to the front,
# as Harbor does, so that only the kind of window decides.
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" >/dev/null 2>&1; }
status=0; ran=0
pass() { ran=$((ran + 1)); echo "PASS $1"; }
fail() { ran=$((ran + 1)); echo "FAIL $1"; status=1; }

# 1. One window at a time; the Mac's fullscreen Spaces 4 s after it appeared, against just before.
BASE=$(fullscreen_spaces)
case "$BASE" in ''|*[!0-9]*) echo "FAIL: couldn't read the Mac's Spaces"; exit 1;; esac
for check in plain:1 topmost:1 dimmer:0 alpha:0 colorkey:0 perpixel:0 shaped:0 clickthrough:0 tool:0 noactivate:0 early:0; do
  kind=${check%:*}; want=${check#*:}
  if start spaceprobe "$kind" 8 > "$OUT/pid"; then
    front "$(cat "$OUT/pid")"; sleep 4
    got=$(($(fullscreen_spaces) - BASE))
    if [ "$got" -eq "$want" ]; then pass "$kind: $got Space of its own"; else fail "$kind: $got Space of its own, expected $want"; fi
  else fail "$kind: the program didn't start"; fi
  wait
  settle "$BASE" || { echo "FAIL: a fullscreen Space was left behind after $kind"; status=1; BASE=$(fullscreen_spaces); }
done

# 2. A small window's program and a raised-fullscreen program on this Desktop; a third program takes the screen
# to a Space of its own; 3 s later the small window's program is picked (as its Dock icon would).
SMALL=$(start spaceprobe-small small 45) && RAISED=$(start spaceprobe-raised plain 45) || SMALL=""
if [ -z "$SMALL" ] || [ -z "$RAISED" ]; then fail "picked app stays in front: the programs didn't start"
else
  front "$RAISED"; sleep 2
  before=$(frontmost)
  OWN=$(start spaceprobe-own plain 16); [ -z "$OWN" ] || front "$OWN"; sleep 5
  away=$(($(fullscreen_spaces) - BASE))
  sleep 3
  front "$SMALL"
  sleep 4
  after=$(frontmost)
  if [ "$before" != "$RAISED" ] || [ "$away" -ne 1 ]; then
    fail "picked app stays in front: couldn't set the scene (fullscreen program in front: $([ "$before" = "$RAISED" ] && echo yes || echo no), Spaces of the third program: $away)"
  elif [ "$after" = "$SMALL" ]; then pass "picked app stays in front when its Desktop comes back"
  elif [ "$after" = "$RAISED" ]; then fail "picked app stays in front: the fullscreen program took activation from it"
  else fail "picked app stays in front: frontmost is pid $after (picked $SMALL, fullscreen $RAISED, third ${OWN:-?})"; fi
fi
"$CLI" stop "$BOTTLE" 2>/dev/null
wait
[ "$ran" -eq 12 ] || { echo "FAIL: $ran of 12 checks ran"; status=1; }
exit $status
