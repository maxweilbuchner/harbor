#!/bin/sh
# Packs a signed + notarized Wine runtime and Apple's D3DMetal into .tar.xz archives with a signed
# runtime.json (Ed25519, key from `harbor-cli gen-runtime-key`), ready to upload next to each other.
#
#   scripts/package-runtime.sh <wine-dir> <d3dmetal-dir> [out-dir]
#     wine-dir:     signed (scripts/sign-runtime.sh) and notarized (scripts/notarize.sh) runtime, with the
#                   .harbor-source record scripts/build-wine.sh writes (which Harbor commit it was built from)
#     d3dmetal-dir: folder containing lib/ (Apple's /redist/lib) plus License.rtf and Acknowledgements.rtf
#   WINE_RUNTIME_VERSION overrides the Wine component version (default cx<CrossOver version>-<RUNTIME_REVISION>).
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env
WINE="$1"; D3D="$2"; OUT="${3:-build/dist/runtime}"
WVER="${WINE_RUNTIME_VERSION:-cx$CROSSOVER_SOURCES_VERSION-$RUNTIME_REVISION}"
DVER="$D3DMETAL_VERSION"
[ -x "$WINE/bin/wine" ] || { echo "package-runtime: $WINE has no bin/wine" >&2; exit 1; }
[ -f "$D3D/lib/external/libd3dshared.dylib" ] && [ -f "$D3D/License.rtf" ] || { echo "package-runtime: $D3D needs lib/ and License.rtf" >&2; exit 1; }
grep -q '^commit=[0-9a-f]\{40\}$' "$WINE/.harbor-source" 2>/dev/null || { echo "package-runtime: $WINE has no .harbor-source (rebuild with scripts/build-wine.sh)" >&2; exit 1; }
codesign -dv --verbose=2 "$WINE/bin/wine" 2>&1 | grep -q 'Authority=Developer ID Application' || { echo "package-runtime: Wine isn't Developer ID-signed (scripts/sign-runtime.sh)" >&2; exit 1; }
# Apple's files must still be Apple's when they ship.
scripts/verify-d3dmetal.sh "$D3D/lib"
rm -rf "$OUT" && mkdir -p "$OUT"

pack() { # $1 = archive name, $2 = source dir
  # No extended attributes: they would carry quarantine flags (and Finder metadata) into the archive.
  tar --no-xattrs --no-mac-metadata --exclude .harbor-version --options xz:threads=0 -cJf "$OUT/$1" -C "$2" .
  echo "  $1 $(du -h "$OUT/$1" | cut -f1)"
}
echo "package-runtime: packing (xz takes a few minutes)"
pack "wine-$WVER.tar.xz" "$WINE"
pack "d3dmetal-$DVER.tar.xz" "$D3D"
cp "$WINE/.harbor-source" "$OUT/.harbor-source"   # for the release notes (scripts/publish-runtime.sh)

RUNTIME_MIN_APP_BUILD="${RUNTIME_MIN_APP_BUILD:-}" python3 -I - "$OUT" "$WVER" "$DVER" <<'PY'
import hashlib, json, os, sys, time
out, wver, dver = sys.argv[1:4]
def entry(cid, version, name):
    path = os.path.join(out, name)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return {"id": cid, "version": version, "url": name, "sha256": h.hexdigest(), "size": os.path.getsize(path)}
# sequence: grows with every list; installed runtimes refuse smaller ones (no downgrade by replaying an old list).
# minimumAppBuild: set RUNTIME_MIN_APP_BUILD in versions.env when these components need a newer Harbor.
manifest = {"schema": 1, "sequence": int(time.time()),
            "components": [entry("wine", wver, f"wine-{wver}.tar.xz"), entry("d3dmetal", dver, f"d3dmetal-{dver}.tar.xz")]}
if os.environ.get("RUNTIME_MIN_APP_BUILD"): manifest["minimumAppBuild"] = int(os.environ["RUNTIME_MIN_APP_BUILD"])
with open(os.path.join(out, "runtime.json"), "w") as f: json.dump(manifest, f, indent=2, sort_keys=True)
PY
CLI="$(swift build --build-system native --show-bin-path 2>/dev/null)/harbor-cli"
"$CLI" sign-manifest "$OUT/runtime.json"
echo "package-runtime: $OUT (wine $WVER, d3dmetal $DVER; Harbor $(tr '\n' ' ' < "$OUT/.harbor-source"))"
