# Third-party components

Harbor is free, non-commercial software; its own code is licensed under the GPL-3.0 (see LICENSE).
It bundles or downloads:

| Component | License | Source |
|---|---|---|
| Wine (CodeWeavers' CrossOver 26.3 sources: Wine 11.0 + CrossOver patches), built by `scripts/build-wine.sh` | LGPL-2.1-or-later | https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz |
| FreeType 2.13.3 | FreeType License (BSD-style) or GPL-2.0 | https://download.savannah.gnu.org/releases/freetype/ |
| MoltenVK 1.4.2 | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| GnuTLS 3.8.14 | LGPL-2.1-or-later | https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/ |
| Nettle 3.10 (libnettle, libhogweed) | LGPL-3.0-or-later or GPL-2.0-or-later | https://ftp.gnu.org/gnu/nettle/ |
| GMP 6.3.0 (from CrossOver 26.3 sources) | LGPL-3.0-or-later or GPL-2.0-or-later | https://gmplib.org/ |
| libtasn1 4.21.0 | LGPL-2.1-or-later | https://ftp.gnu.org/gnu/libtasn1/ |
| Wine Mono 10.4.1 | Mixed (MIT, LGPL, GPL with exceptions; see its sources) | https://dl.winehq.org/wine/wine-mono/10.4.1/ |
| Wine Gecko 2.47.4 | MPL-2.0 | https://dl.winehq.org/wine/wine-gecko/2.47.4/ |
| D3DMetal (Apple Game Porting Toolkit `/redist/lib`) | Apple Software License Agreement for Game Porting Toolkit — non-commercial redistribution only, Apple-branded systems only (§2A(iii), §2C). Shipped unmodified with Apple's `License.rtf` and `Acknowledgements.rtf`. | https://developer.apple.com/games/game-porting-toolkit/ |

D3DMetal is Apple's software, not Harbor's, and is not covered by Harbor's own license. Harbor never
modifies, patches or reverse engineers it (§2D).

Before public release, every LGPL/GPL/MPL binary Harbor hosts needs a matching source offer hosted by Harbor
(see ARCHITECTURE §12.4). Planned: DXMT, DXVK, GStreamer, SDL2 — add rows when they ship.
