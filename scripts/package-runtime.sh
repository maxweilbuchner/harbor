#!/bin/sh
# Packs a signed + notarized Wine runtime and Apple's D3DMetal into .tar.xz archives with a signed
# runtime.json (Ed25519, key from `harbor-cli gen-runtime-key`), ready to upload next to each other.
#
#   scripts/package-runtime.sh <wine-dir> <d3dmetal-dir> [out-dir]
#     wine-dir:     signed (scripts/sign-runtime.sh) and notarized (scripts/notarize.sh) runtime, with the
#                   .harbor-source record scripts/build-wine.sh writes (which Harbor commit it was built from)
#     d3dmetal-dir: what scripts/import-d3dmetal.sh made (Runtime/d3dmetal-<version>): lib/ (Apple's
#                   /redist/lib), License.rtf, Acknowledgements.rtf and the list of them, .harbor-files.sha256
#   ALLOW_DIRTY_RUNTIME=1 packs a runtime built with uncommitted changes in scripts/ (refused otherwise).
#   WINE_RUNTIME_VERSION overrides the Wine component version (default <Wine sources version>-<RUNTIME_REVISION>).
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env
WINE="$1"; D3D="$2"; OUT="${3:-build/dist/runtime}"
WVER="${WINE_RUNTIME_VERSION:-$CROSSOVER_SOURCES_VERSION-$RUNTIME_REVISION}"
DVER="$D3DMETAL_VERSION"
[ -x "$WINE/bin/wine" ] || { echo "package-runtime: $WINE has no bin/wine" >&2; exit 1; }
[ -f "$D3D/lib/external/libd3dshared.dylib" ] && [ -f "$D3D/License.rtf" ] || { echo "package-runtime: $D3D needs lib/ and License.rtf" >&2; exit 1; }
grep -q '^commit=[0-9a-f]\{40\}$' "$WINE/.harbor-source" 2>/dev/null || { echo "package-runtime: $WINE has no .harbor-source (rebuild with scripts/build-wine.sh)" >&2; exit 1; }
# Built from a commit, all of it: the commit is what the release notes name as this runtime's source.
grep -qx 'dirty=no' "$WINE/.harbor-source" || [ -n "${ALLOW_DIRTY_RUNTIME:-}" ] || { echo "package-runtime: $WINE was built with uncommitted changes in scripts/; commit and rebuild (or ALLOW_DIRTY_RUNTIME=1)" >&2; exit 1; }
codesign -dv --verbose=2 "$WINE/bin/wine" 2>&1 | grep -q 'Authority=Developer ID Application' || { echo "package-runtime: Wine isn't Developer ID-signed (scripts/sign-runtime.sh)" >&2; exit 1; }
# Notarized as it is now (signing again after notarization changes the files): asks Apple, as Gatekeeper does on a
# Mac that downloads it. spctl can't judge a loose executable ("does not seem to be an app").
for f in wine wineserver; do
  codesign --verify -R='notarized' --check-notarization "$WINE/bin/$f" 2>/dev/null || { echo "package-runtime: $WINE/bin/$f isn't notarized (scripts/notarize.sh --runtime-only $WINE)" >&2; exit 1; }
done
# Apple's files must still be Apple's when they ship.
scripts/verify-d3dmetal.sh "$D3D/lib"
# The Windows DLLs in it carry no signature. They and everything else in the folder must be what
# scripts/import-d3dmetal.sh took from the pinned image: the list it left beside them (the image's SHA-256, then
# every file's) against the folder as it is now. A missing list, a file changed, added or gone, or a list from
# another image refuses. (That is a file changed since the import, by accident or in passing; somebody who
# rewrites the list as well is stopped only by importing again from the image.)
LIST="$D3D/.harbor-files.sha256"
[ -s "$LIST" ] || { echo "package-runtime: $D3D has no list of its files ($LIST); import it again with scripts/import-d3dmetal.sh" >&2; exit 1; }
files=$(scripts/d3dmetal-files.sh "$D3D") || exit 1
printf 'image %s\n%s\n' "$D3DMETAL_DMG_SHA256" "$files" | cmp -s - "$LIST" || {
  echo "package-runtime: $D3D isn't what scripts/import-d3dmetal.sh took from the pinned image (< as imported, > now); import it again:" >&2
  printf 'image %s\n%s\n' "$D3DMETAL_DMG_SHA256" "$files" | diff "$LIST" - | grep '^[<>]' >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"

pack() { # $1 = archive name, $2 = source dir
  # No extended attributes: they would carry quarantine flags (and Finder metadata) into the archive.
  # Nor D3DMetal's file list: the archive holds Apple's files and nothing of Harbor's.
  tar --no-xattrs --no-mac-metadata --exclude .harbor-version --exclude .harbor-files.sha256 --options xz:threads=0 -cJf "$OUT/$1" -C "$2" .
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
