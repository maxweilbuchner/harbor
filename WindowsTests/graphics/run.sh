#!/bin/sh
# Runs the graphics proof programs in a throwaway bottle against the current Wine runtime
# (build/out/wine unless HARBOR_WINE_ROOT is set) and prints PASS/FAIL per backend and API.
# Needs a logged-in GUI session: the programs open small windows for about a second.
#
#   WindowsTests/graphics/run.sh            # d3dmetal + wined3d
#   WindowsTests/graphics/run.sh d3dmetal   # one backend
#   WindowsTests/graphics/run.sh dxmt       # DXMT (D3D11 only: its dxgi replaces the one Wine's D3D12 needs)
set -u
cd "$(dirname "$0")/../.."
WindowsTests/graphics/build.sh >/dev/null || exit 1   # never test executables left from an earlier build
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
[ -x "$CLI" ] || { echo "run: build harbor-cli first (scripts/check.sh)" >&2; exit 1; }
OUT="build/WindowsTests/graphics/results"
BOTTLE="graphics-test-$$"
mkdir -p "$OUT"
# The throwaway bottle goes however the run ends, an interruption included.
cleanup() { "$CLI" stop "$BOTTLE" 2>/dev/null; rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
status=0
for backend in ${1:-d3dmetal wined3d}; do
  "$CLI" stop "$BOTTLE"
  tests="d3d11tri d3d12tri"; [ "$backend" = dxmt ] && tests="d3d11tri"
  for test in $tests; do
    win_out="Z:$(printf '%s' "$PWD/$OUT/$backend-$test" | tr / '\\')"
    # run-with picks the layer's runtime itself and fails if the layer isn't installed.
    # The program's exit status is kept (a pipe into grep would report grep's): each program has two checks,
    # offscreen and window, and one that passes the first and crashes in the second has failed.
    all=$("$CLI" run-with "$BOTTLE" "$backend" "$PWD/build/WindowsTests/graphics/$test.exe" "$win_out" 2>/dev/null); rc=$?
    result=$(printf '%s\n' "$all" | grep -E '^(PASS|FAIL)')
    [ -n "$result" ] || result="FAIL $test: no result (crashed?)"
    echo "$backend: $result" | sed 's/ -> .*//'
    echo "$result" | grep -q FAIL && status=1
    passed=$(printf '%s\n' "$result" | grep -c '^PASS')
    [ $rc -eq 0 ] && [ "$passed" -eq 2 ] || { echo "$backend: FAIL $test: $passed of 2 checks passed, exit status $rc"; status=1; }
  done
done
echo "images: $OUT"
exit $status
