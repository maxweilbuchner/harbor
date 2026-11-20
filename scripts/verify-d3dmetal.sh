#!/bin/sh
# Checks that a D3DMetal folder (Apple's Game Porting Toolkit /redist/lib) is Apple's own, unmodified build:
# every Mach-O must carry Apple's signature. `anchor apple` = signed by Apple itself, checked cryptographically
# (authority names alone can be imitated). The Windows DLLs carry no signature; they are covered by the SHA-256
# of Apple's disk image they were taken from (scripts/import-d3dmetal.sh).
#
#   scripts/verify-d3dmetal.sh <lib-dir>
set -eu
LIB="${1:?usage: verify-d3dmetal.sh <lib-dir>}"
[ -f "$LIB/external/libd3dshared.dylib" ] || { echo "verify-d3dmetal: $LIB isn't a D3DMetal lib folder" >&2; exit 1; }
codesign --verify --deep --strict "$LIB/external/D3DMetal.framework" || { echo "verify-d3dmetal: D3DMetal.framework's signature is broken" >&2; exit 1; }
for f in "$LIB/external/libd3dshared.dylib" "$LIB"/wine/x86_64-unix/*.so "$LIB/external/D3DMetal.framework"; do
  codesign --verify --strict "$f" && codesign --verify -R='anchor apple' "$f" 2>/dev/null || { echo "verify-d3dmetal: not signed by Apple: $f" >&2; exit 1; }
done
