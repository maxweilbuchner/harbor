#!/bin/sh
# Prints what a D3DMetal folder (Runtime/d3dmetal-<version>: lib/ and Apple's licence files) holds: one line per
# file ("<SHA-256>  <path>") and per symbolic link ("link <target>  <path>"), sorted. scripts/import-d3dmetal.sh
# keeps this list beside the files it takes from Apple's image (.harbor-files.sha256), and
# scripts/package-runtime.sh compares it with the folder before packing: the Windows DLLs carry no signature
# that could be checked instead.
#
#   scripts/d3dmetal-files.sh <d3dmetal-dir>
set -eu
cd "${1:?usage: d3dmetal-files.sh <d3dmetal-dir>}"
# Without the list itself. A file that can't be read stops this: find passes on what `-exec … +` returns.
files=$(find . -type f ! -path ./.harbor-files.sha256 -exec shasum -a 256 {} +)
links=$(find . -type l -exec sh -c 'for f; do printf "link %s  %s\n" "$(readlink "$f")" "$f"; done' sh {} +)
other=$(find . ! -type f ! -type l ! -type d)
[ -z "$other" ] || { echo "d3dmetal-files: neither file, link nor folder: $other" >&2; exit 1; }
printf '%s\n%s\n' "$files" "$links" | grep . | LC_ALL=C sort
