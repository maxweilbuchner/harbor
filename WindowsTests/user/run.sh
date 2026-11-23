#!/bin/sh
# Windows user name regression test (username.c) on the current runtime (HARBOR_WINE_ROOT to pick another):
# a new bottle's user is "harbor"; a bottle that has a "crossover" profile folder, as bottles made on runtimes
# up to revision 6 do, keeps that user. Exit 0 = pass.
set -u
cd "$(dirname "$0")/../.."
. scripts/versions.env
CC="build/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
mkdir -p build/WindowsTests/user
"$CC" -O2 -Wall -o build/WindowsTests/user/username.exe WindowsTests/user/username.c || exit 1
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
BOTTLE="user-test-$$"
USERS="$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE/prefix/drive_c/users"
rc=0
check() { # $1 = label, $2 = expected user
  out=$("$CLI" run "$BOTTLE" "$PWD/build/WindowsTests/user/username.exe" 2>/dev/null | tr -d '\r' | grep '^user=')
  want="user=$2 ansi=$2 profile=C:\\users\\$2 env=C:\\users\\$2"
  # printf, not echo: sh's echo reads the backslashes in the paths as escapes.
  if [ "$out" = "$want" ]; then printf '%s\n' "PASS: $1: $out"; else printf '%s\n' "FAIL: $1: got '$out', expected '$want'"; rc=1; fi
  "$CLI" stop "$BOTTLE"
}
"$CLI" create "$BOTTLE" --mac-files >/dev/null || exit 1
check "new bottle" harbor
[ -d "$USERS/harbor" ] && [ ! -e "$USERS/crossover" ] || { echo "FAIL: new bottle: users/ holds $(ls "$USERS" | tr '\n' ' ')"; rc=1; }
# An older bottle: the profile folder is named crossover.
[ -d "$USERS/harbor" ] && mv "$USERS/harbor" "$USERS/crossover"
check "bottle with a crossover profile" crossover
[ ! -e "$USERS/harbor" ] || { echo "FAIL: bottle with a crossover profile: a second profile users/harbor appeared"; rc=1; }
rm -rf "$HOME/Library/Application Support/Harbor/Bottles/$BOTTLE"
exit $rc
