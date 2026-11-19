#!/bin/sh
# Runs the graphics proof programs in a throwaway bottle against the current Wine runtime
# (build/out/wine unless HARBOR_WINE_ROOT is set) and prints PASS/FAIL per backend and API.
# Needs a logged-in GUI session: the programs open small windows for about a second.
#
#   WindowsTests/graphics/run.sh            # d3dmetal + wined3d
#   WindowsTests/graphics/run.sh d3dmetal   # one backend
set -u
cd "$(dirname "$0")/../.."
WindowsTests/graphics/build.sh >/dev/null
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
[ -x "$CLI" ] || { echo "run: build harbor-cli first (scripts/check.sh)" >&2; exit 1; }
OUT="build/WindowsTests/graphics/results"
BOTTLE="graphics-test-$$"
mkdir -p "$OUT"
"$CLI" create "$BOTTLE" >/dev/null || exit 1
CONF="$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE/bottle.json"
status=0
for backend in ${1:-d3dmetal wined3d}; do
  "$CLI" stop "$BOTTLE"
  sed -i '' -E "s/\"graphics\" : \"[a-z0-9]+\"/\"graphics\" : \"$backend\"/" "$CONF"
  for test in d3d11tri d3d12tri; do
    win_out="Z:$(printf '%s' "$PWD/$OUT/$backend-$test" | tr / '\\')"
    result=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/graphics/$test.exe" "$win_out" 2>/dev/null | grep -E '^(PASS|FAIL)')
    [ -n "$result" ] || result="FAIL $test: no result (crashed?)"
    echo "$backend: $result" | sed 's/ -> .*//'
    echo "$result" | grep -q FAIL && status=1
  done
done
"$CLI" stop "$BOTTLE"
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
echo "images: $OUT"
exit $status
