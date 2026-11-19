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

# Source code for every copyleft component in the runtime (LGPL/GPL/MPL), next to the binaries.
SOURCES="$DL/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz $DL/freetype-$FREETYPE_VERSION.tar.xz
$DL/nettle-$NETTLE_VERSION.tar.gz $DL/gnutls-$GNUTLS_VERSION.tar.xz $DL/libtasn1-$LIBTASN1_VERSION.tar.gz
$DL/wine-mono-$WINE_MONO_VERSION-src.tar.xz $DL/wine-gecko-$WINE_GECKO_VERSION-src.tar.xz"
for f in $SOURCES; do [ -f "$f" ] || { echo "publish-runtime: missing source archive $f" >&2; exit 1; }; done
echo "$WINE_MONO_SRC_SHA256  $DL/wine-mono-$WINE_MONO_VERSION-src.tar.xz" | shasum -a 256 -c - >/dev/null
echo "$WINE_GECKO_SRC_SHA256  $DL/wine-gecko-$WINE_GECKO_VERSION-src.tar.xz" | shasum -a 256 -c - >/dev/null

NOTES=build/dist/runtime-release-notes.md
cat > "$NOTES" <<EOF
Windows support for Harbor: the files the app downloads when you click **Download Windows Support**.
You don't need to download anything here by hand.

| Component | Version | License |
|---|---|---|
| Wine (CodeWeavers' CrossOver $CROSSOVER_SOURCES_VERSION sources), with FreeType, GnuTLS, Nettle, GMP, libtasn1, MoltenVK, Wine Mono, Wine Gecko | cx$CROSSOVER_SOURCES_VERSION-$RUNTIME_REVISION | LGPL-2.1+ and others, see THIRD_PARTY_NOTICES.md |
| Apple D3DMetal (Game Porting Toolkit, unmodified) | $D3DMETAL_VERSION | Apple's GPTK license: non-commercial use on Apple-branded systems only; License.rtf inside |

**Source code** for the copyleft components is attached to this release: CrossOver's sources (Wine, GMP)
and the upstream archives for FreeType, Nettle, GnuTLS, libtasn1, Wine Mono and Wine Gecko. Harbor's build
scripts are in the repository (scripts/fetch-sources.sh, scripts/build-wine.sh). MoltenVK is used unmodified
from its upstream release (Apache-2.0).

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
# Skip files the release already has at the same size (the source archives rarely change: ~750 MB).
present=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[] | "\(.name) \(.size)"')
for f in $ARCHIVES $SOURCES; do
  if echo "$present" | grep -qxF "$(basename "$f") $(stat -f %z "$f")"; then echo "unchanged: $(basename "$f")"; continue; fi
  gh release upload "$TAG" -R "$REPO" --clobber "$f"
done
gh release upload "$TAG" -R "$REPO" --clobber "$DIST/runtime.json" "$DIST/runtime.json.sig"
keep=$(for f in $ARCHIVES $SOURCES; do basename "$f"; done; echo runtime.json; echo runtime.json.sig)
gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name' | while read -r name; do
  echo "$keep" | grep -qxF "$name" || { gh release delete-asset "$TAG" "$name" -R "$REPO" -y >/dev/null && echo "removed old $name"; }
done
echo "publish-runtime: https://github.com/$REPO/releases/tag/$TAG"
