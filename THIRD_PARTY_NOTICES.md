# Third-party components

Harbor is free, non-commercial software. It bundles:

| Component | License | Source |
|---|---|---|
| Wine | LGPL-2.1-or-later | https://gitlab.winehq.org/wine/wine (macOS build: https://github.com/Gcenx/macOS_Wine_builds) |
| D3DMetal (Apple Game Porting Toolkit `/redist/lib`) | Apple Software License Agreement for Game Porting Toolkit — non-commercial redistribution only, Apple-branded systems only (§2A(iii), §2C). Shipped unmodified with Apple's `License.rtf` and `Acknowledgements.rtf`. | https://developer.apple.com/games/game-porting-toolkit/ |

D3DMetal is Apple's software, not Harbor's, and is not covered by Harbor's own license. Harbor never
modifies, patches or reverse engineers it (§2D).

Planned: DXMT, DXVK, MoltenVK — add rows when they ship.
