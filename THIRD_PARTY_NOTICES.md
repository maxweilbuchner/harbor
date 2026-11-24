# Third-party components

Harbor is free, non-commercial software; its own code is licensed under the GPL-3.0 (see LICENSE).
It bundles or downloads:

| Component | License | Source |
|---|---|---|
| Wine (CodeWeavers' CrossOver 26.3 sources: Wine 11.0 + CrossOver patches, plus Harbor's patches in `scripts/patches/wine/`), built by `scripts/build-wine.sh` | LGPL-2.1-or-later | https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz + this repository |
| FreeType 2.13.3 | FreeType License (BSD-style) or GPL-2.0 | https://download.savannah.gnu.org/releases/freetype/ |
| MoltenVK 1.4.2 | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| DXMT v0.80 (Direct3D 10/11 on Metal, by Feifan He for CodeWeavers), prebuilt release, unmodified; inside the runtime at `lib/dxmt` with its licence | MIT (v0.80 is the last MIT release; later ones are LGPL-2.1-or-later) | https://github.com/3Shain/dxmt |
| GnuTLS 3.8.14 | LGPL-2.1-or-later | https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/ |
| Nettle 3.10 (libnettle, libhogweed) | LGPL-3.0-or-later or GPL-2.0-or-later | https://ftp.gnu.org/gnu/nettle/ |
| GMP 6.3.0 (from CrossOver 26.3 sources) | LGPL-3.0-or-later or GPL-2.0-or-later | https://gmplib.org/ |
| libtasn1 4.21.0 | LGPL-2.1-or-later | https://ftp.gnu.org/gnu/libtasn1/ |
| Wine Mono 10.4.1 (the project's installer, unmodified) | Mixed (MIT, LGPL, GPL with exceptions, MS-PL, zlib; its `COPYING` says which part has which) | https://dl.winehq.org/wine/wine-mono/10.4.1/ |
| Wine Gecko 2.47.4 (the project's installers, unmodified) | MPL-2.0, and the licences of the code in it (its `toolkit/content/license.html`) | https://dl.winehq.org/wine/wine-gecko/2.47.4/ |
| Sparkle 2.10.1 (app updates; the framework inside Harbor.app, the project's release, unmodified) | MIT; its `LICENSE` also holds the licences of the code it embeds (bsdiff, sais-lite, Ed25519, SUSignatureVerifier) | https://github.com/sparkle-project/Sparkle |
| D3DMetal (Apple Game Porting Toolkit `/redist/lib`) | Apple Software License Agreement for Game Porting Toolkit — non-commercial redistribution only, Apple-branded systems only (§2A(iii), §2C). Shipped unmodified with Apple's `License.rtf` and `Acknowledgements.rtf`. | https://developer.apple.com/games/game-porting-toolkit/ |

Harbor.app carries this file and Harbor's `LICENSE` in its Resources folder, and from 0.1.6
Sparkle's `LICENSE` in `Resources/licenses/sparkle/`. From runtime revision 8 the Wine runtime carries the
licence texts of Wine, GMP, Nettle, GnuTLS, libtasn1, FreeType and MoltenVK in `share/licenses/`, beside a copy
of this file; DXMT's is at `lib/dxmt/LICENSE`. From revision 9 it also carries Wine Mono's and Wine
Gecko's licence files there, taken from their source archives.

D3DMetal is Apple's software, not Harbor's, and is not covered by Harbor's own license. Harbor never
modifies, patches or reverse engineers it (§2D).

The source code of every LGPL/GPL/MPL component in the runtime is published beside it, on the same GitHub
release (`scripts/publish-runtime.sh`): CrossOver's sources (Wine, GMP) and the upstream archives of FreeType,
Nettle, GnuTLS, libtasn1, Wine Mono and Wine Gecko. The Wine runtime records the Harbor commit its patches and
build scripts came from in `.harbor-source`; the runtime release notes name it too. Not built in yet: GStreamer,
SDL2 — add rows when they ship.
