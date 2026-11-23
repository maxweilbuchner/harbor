# Harbor

A native macOS app for running Windows programs, games and everyday apps alike, made to be simple enough
for almost anyone: drop in an `.exe` or installer and run it.

Harbor is free, non-commercial software built on [Wine](https://www.winehq.org) (compiled from the LGPL source code
CodeWeavers publishes for CrossOver), Apple's [D3DMetal](https://developer.apple.com/games/game-porting-toolkit/) for
DirectX 11/12 games and [DXMT](https://github.com/3Shain/dxmt) for other Direct3D 10/11 programs.

Website: [maxweilbuchner.github.io/harbor](https://maxweilbuchner.github.io/harbor/) (source in `site/`).

> **Status: early release (0.1).** Adding programs and installers, Steam and the Epic Games Store, DirectX 11/12
> games on D3DMetal and automatic updates work; expect rough edges and programs that don't run yet. See
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the plan and verified results, and the
> [issues](https://github.com/maxweilbuchner/harbor/issues) for what's known.

## Download

Get **Harbor-x.y.z.zip** from the [latest release](https://github.com/maxweilbuchner/harbor/releases/latest),
unzip it and move Harbor to Applications. On first start Harbor downloads its Windows support (about 400 MB).
Both the app and the Windows support update themselves afterwards. Harbor > Settings… shows the
installed versions and whether an update is downloading or waiting.

## What works today

- **Add a program by dropping it in:** installers run with their own windows and what they install appears in the
  library; programs that need no installer are copied in. A program's whole folder can be dropped too (the
  contents of a disc, an unpacked download), and installers find the files that came with them, also on a
  mounted disk image. Each gets its own Windows environment ("bottle"), ready in under a second.
- **Steam and the Epic Games Store** in one click; the games they install appear in the library.
- **DirectX 11 and 12 through D3DMetal 4**, offscreen and in windows, including fullscreen, Space switches
  and Mission Control.
- **Direct3D 10 and 11 through DXMT** for programs that aren't games.
- **Signed, notarized distribution.** The app and its separately downloaded Wine runtime pass Gatekeeper
  even when quarantined. Downloads are verified with an Ed25519-signed manifest and SHA-256 checksums.
- **HTTPS from Windows programs** through GnuTLS.

## Requirements

- macOS 26 or later
- A Mac with Apple silicon and Rosetta, which Harbor offers to install (Intel Macs aren't supported yet)

## Building

Development needs Xcode 27 or later.

```sh
scripts/check.sh            # build, unit tests, newest-SDK check (the full bar)
scripts/fetch-sources.sh    # CrossOver/Wine sources and toolchain into build/ (pinned, checksummed)
scripts/build-wine.sh       # Harbor's Wine runtime into build/out/wine (~20 min)
WindowsTests/graphics/run.sh d3dmetal   # D3D11/D3D12 rendering proof (import D3DMetal from Apple's image with scripts/import-d3dmetal.sh)
```

The app runs from `swift run Harbor`; `harbor-cli` drives the same engine from the terminal.
Distribution: `scripts/bundle-app.sh`, `scripts/sign-runtime.sh`, `scripts/notarize.sh`,
`scripts/package-runtime.sh`.

## License

Harbor's own code is licensed under the [GNU General Public License v3.0](LICENSE).

Harbor bundles or downloads third-party components under their own licenses: Wine (LGPL-2.1+), MoltenVK,
DXMT, FreeType, GnuTLS and its dependencies, Wine Mono and Wine Gecko. It also downloads Apple's D3DMetal, which is
Apple's software, redistributed unmodified for **non-commercial use on Apple-branded systems only** under
Apple's Game Porting Toolkit license, which forbids reverse engineering it. For this reason Harbor itself must
stay non-commercial. Details and source locations are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Harbor is not affiliated with Apple, CodeWeavers or the Wine project.
