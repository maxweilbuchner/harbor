#!/bin/sh
# Publishes build/dist/runtime (scripts/package-runtime.sh) plus the corresponding source archives to the
# GitHub release tagged `runtime`, which the app downloads from:
#   https://github.com/maxweilbuchner/harbor/releases/download/runtime/runtime.json
# The release is never marked "latest", so app releases keep that slot. New archives go up before the
# manifest and old ones are removed after it, so the live manifest never points at missing files.
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.env
REPO=maxweilbuchner/harbor
TAG=runtime
DIST=build/dist/runtime
DL=build/download
export PATH="/opt/homebrew/bin:$PATH"
[ -f "$DIST/runtime.json.sig" ] || { echo "publish-runtime: run scripts/package-runtime.sh first" >&2; exit 1; }
# The Harbor commit whose build scripts and Wine patches made this runtime (written by scripts/build-wine.sh).
COMMIT=$(sed -n 's/^commit=\([0-9a-f]\{40\}\)$/\1/p' "$DIST/.harbor-source" 2>/dev/null) || true
[ -n "$COMMIT" ] || { echo "publish-runtime: $DIST/.harbor-source is missing; rebuild and package the runtime again" >&2; exit 1; }
BUILT_FROM="Harbor commit [$COMMIT](https://github.com/$REPO/commit/$COMMIT)"
if ! grep -qx 'dirty=no' "$DIST/.harbor-source"; then
  echo "publish-runtime: WARNING: this runtime was built with uncommitted changes in scripts/; the notes say so" >&2
  BUILT_FROM="$BUILT_FROM plus changes to scripts/ that were not committed"
fi

# Source code for every copyleft component in the runtime (LGPL/GPL/MPL), next to the binaries.
SOURCES="$DL/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz $DL/freetype-$FREETYPE_VERSION.tar.xz
$DL/nettle-$NETTLE_VERSION.tar.gz $DL/gnutls-$GNUTLS_VERSION.tar.xz $DL/libtasn1-$LIBTASN1_VERSION.tar.gz
$DL/wine-mono-$WINE_MONO_VERSION-src.tar.xz $DL/wine-gecko-$WINE_GECKO_VERSION-src.tar.xz"
for f in $SOURCES; do [ -f "$f" ] || { echo "publish-runtime: missing source archive $f (scripts/fetch-sources.sh)" >&2; exit 1; }; done
echo "$WINE_MONO_SRC_SHA256  $DL/wine-mono-$WINE_MONO_VERSION-src.tar.xz" | shasum -a 256 -c - >/dev/null
echo "$WINE_GECKO_SRC_SHA256  $DL/wine-gecko-$WINE_GECKO_VERSION-src.tar.xz" | shasum -a 256 -c - >/dev/null

NOTES=build/dist/runtime-release-notes.md
cat > "$NOTES" <<EOF
Windows support for Harbor: the files the app downloads when you click **Download Windows Support**.
You don't need to download anything here by hand.

| Component | Version | License |
|---|---|---|
| Wine (CodeWeavers' CrossOver $CROSSOVER_SOURCES_VERSION sources), with FreeType, GnuTLS, Nettle, GMP, libtasn1, MoltenVK, Wine Mono, Wine Gecko | $CROSSOVER_SOURCES_VERSION-$RUNTIME_REVISION | LGPL-2.1+ and others, see THIRD_PARTY_NOTICES.md |
| DXMT (Direct3D 10/11 on Metal; upstream's prebuilt release, unmodified, inside the Wine archive at lib/dxmt) | $DXMT_VERSION | MIT; LICENSE inside |
| Apple D3DMetal (Game Porting Toolkit, unmodified) | $D3DMETAL_VERSION | Apple's GPTK license: non-commercial use on Apple-branded systems only; License.rtf inside |

**Source code** for the copyleft components is attached to this release: CrossOver's sources (Wine, GMP)
and the upstream archives for FreeType, Nettle, GnuTLS, libtasn1, Wine Mono and Wine Gecko. Harbor's Wine
patches and build scripts are in the repository (scripts/patches/wine, scripts/fetch-sources.sh,
scripts/build-wine.sh); this runtime was built from $BUILT_FROM, which the Wine archive also records in
.harbor-source. MoltenVK and DXMT are used unmodified from their upstream releases (Apache-2.0, MIT).

The Wine binaries are signed with Harbor's Developer ID and notarized by Apple. runtime.json is signed with
Harbor's Ed25519 key (scripts/runtime-signing.pub); the app rejects anything else.
EOF

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" -R "$REPO" --title "Harbor Windows support (runtime)" --notes-file "$NOTES" --latest=false >/dev/null
else
  gh release create "$TAG" -R "$REPO" --title "Harbor Windows support (runtime)" --notes-file "$NOTES" --latest=false >/dev/null
fi

ARCHIVES=$(ls "$DIST"/*.tar.xz)
# Order matters for apps downloading meanwhile: new archives first, then the manifest that points at them,
# and only then remove archives that no manifest references any more.
# Skip files the release already has with the same SHA-256 (the source archives rarely change: ~750 MB).
# Name and size aren't enough: a repack of the same size would stay unpublished under a manifest carrying its
# hash. A file GitHub reports no digest for is uploaded again.
present=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[] | "\(.name) \(.digest // "unknown")"')
for f in $ARCHIVES $SOURCES; do
  sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ -n "$sum" ] || { echo "publish-runtime: can't hash $f" >&2; exit 1; }
  if echo "$present" | grep -qxF "$(basename "$f") sha256:$sum"; then echo "unchanged: $(basename "$f")"; continue; fi
  gh release upload "$TAG" -R "$REPO" --clobber "$f"
done
# The list and its signature are two assets. GitHub replaces neither a pair at once nor one asset in place:
# --clobber deletes each and uploads it again under its name. Both go in this one call on purpose: gh replaces
# them side by side, so the time in which one is missing or the two don't belong together is what one small
# upload takes. Replacing them one after the other, in either order, would make that time about twice as long
# and help nobody: the app fetches the list, then the signature, and between the two replacements it gets a pair
# that doesn't verify whichever of them is new first. A check in that time fails ("not signed by Harbor", or not
# found) and changes nothing on that Mac, since the signature covers the list's exact bytes; the app tries again
# (docs/RELEASING.md).
gh release upload "$TAG" -R "$REPO" --clobber "$DIST/runtime.json" "$DIST/runtime.json.sig"
keep=$(for f in $ARCHIVES $SOURCES; do basename "$f"; done; echo runtime.json; echo runtime.json.sig)
gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name' | while read -r name; do
  echo "$keep" | grep -qxF "$name" || { gh release delete-asset "$TAG" "$name" -R "$REPO" -y >/dev/null && echo "removed old $name"; }
done
echo "publish-runtime: https://github.com/$REPO/releases/tag/$TAG"
