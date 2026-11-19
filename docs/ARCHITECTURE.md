# Harbor architecture

Harbor is a free, non-commercial, native macOS app that runs Windows programs — games and general apps,
any `.exe` or installer — with a UX simple enough for almost anyone. Status: plan, 2026-11-19.

## 1. Principles

1. **Apps, not bottles.** Users see their Windows programs in a library, launch them like Mac apps, and
   never have to learn what a Wine prefix is. Bottles exist, but are an implementation detail surfaced
   only under "Advanced".
2. **Native everywhere.** SwiftUI (AppKit where SwiftUI falls short), system controls, Spotlight, Dock,
   Launchpad, Finder "Open With", per-program `.app` shims. No WebViews, no Perl/Python runtime.
3. **Zero configuration by default, all configuration available.** Harbor picks Windows version, graphics
   layer and dependencies itself; every decision is visible and overridable per program.
4. **Explain failures in plain language** with a one-click fix where one exists.
5. **Latest kits.** Newest Xcode/SDK/Swift, newest stable component releases (pinned in `scripts/versions.env`).
6. **From scratch, legally.** We reuse open-source code (Wine, DXMT, DXVK, MoltenVK, CodeWeavers' LGPL
   Wine sources) and Apple's redistributable D3DMetal. We do **not** decompile or copy CrossOver's
   proprietary front end, tools or CrossTie data (CrossOver license §3), and never inspect or modify
   D3DMetal (GPTK license §2D).

## 2. Prior art: how Wine front ends are usually put together

Notes from research into existing Wine front ends for the Mac and their public documentation, and what Harbor
does with each idea. Nothing here comes from anyone's proprietary code; Harbor's implementation is its own.

| Common practice | Harbor |
|---|---|
| A front end in several languages, with helper command-line tools | One SwiftUI app; the engine is the `HarborKit` Swift modules, also driven by `harbor-cli` |
| Bottle templates for each Windows version | Bottle presets (win7/10/11), created on demand |
| A bottle is a Wine prefix plus a configuration file; the Wine build is shared | Same split: `bottle.json` + `prefix/` |
| Graphics layers (DXVK, DXMT, Apple's D3DMetal) kept beside Wine | Runtime components, composed into derived runtimes (§5) |
| Install recipes for programs that need extra components | Harbor's own declarative recipes (§7) |
| Sparkle for app updates | Sparkle 2.10.x for the app; own signed manifest for runtimes |

Harbor ships D3DMetal 4.0b3.

## 3. Verified so far (on M4 Pro, macOS 27.3 beta, 2026-11-19)

- Gcenx Wine 11.21 (x86_64, ad-hoc signed, runs under Rosetta, wow64 layout) creates a win10 prefix in ~31 s;
  `cmd /c ver` reports `Microsoft Windows 10.0.19045`.
- D3DMetal 4.0b3 redist: every Mach-O carries Apple's first-party signature (`Software Signing` → Apple Root CA).
- In the derived Wine+D3DMetal runtime, loading `d3d12.dll` pulls in Apple's `D3DMetal.framework`,
  `libmetalirconverter.dylib`, `libdxccontainer.dylib` and `libd3dshared.dylib` (DYLD_PRINT_LIBRARIES).
- **Not yet verified:** a D3D12 frame rendering; any real game; DXMT/DXVK; stock-Wine vs CrossOver-Wine
  compatibility under load.

## 4. Module layout

```
Harbor.app (SwiftUI)          Library · Program detail · Add-program flow · Settings · Diagnostics
  └─ HarborKit (Swift)
       Model        Program, Bottle, BottleSettings (versioned JSON + migrations)
       Store        BottleStore, ProgramIndex (scans prefix Start Menu .lnk → Programs)
       Runtime      WineRuntime, component registry, derived-runtime builder, runtime downloader
       Analyze      PE reader (arch, subsystem, imports, version info, icons), installer-type detection
       Launch       WineLauncher, per-bottle supervisor (wineserver lifetime, process tree, logs)
       Recipes      dependency installers (VC++ runtimes, .NET, fonts, DirectX redist…) with hashes
       MacIntegration  app shims, icons, file associations, harbor:// URL scheme, Dock/Spotlight
       Diagnose     Wine log → known-issue matcher → plain-language explanation + fix action
  harbor-cli          developer CLI over HarborKit (exists)
```

## 5. Runtimes and graphics

> Revised by review (§12.2): layers are selected per launch, not per bottle; the per-bottle text below is superseded.

**Runtime = base Wine + zero or one graphics layer**, materialised as an APFS clone (copy-on-write, cheap)
under `~/Library/Application Support/Harbor/Runtimes/<base-hash>-<layer>-<version>/`. Implemented for D3DMetal.

- Wine builtins with the same names (`dxgi`, `d3d10`, `d3d11`, `d3d12`) are provided by each layer, so a
  layer is chosen **per bottle**, not per process: all processes of a prefix share one wineserver and one runtime.
- Because Harbor defaults to **one bottle per program** (§6), per-bottle selection is effectively per-program.
- **Automatic selection** (planned) from PE imports of the main executable:
  - D3D12 → D3DMetal
  - D3D11/D3D10 → D3DMetal, fall back to DXMT on known-bad titles
  - D3D9/D3D8 → DXVK (+MoltenVK) or wined3d
  - OpenGL/GDI-only (most general apps) → plain Wine
  Launchers that load D3D dynamically won't show imports → per-program override + known-title table.
- **Base Wine plan:** move from stock Wine 11.21 to our own build of CodeWeavers' LGPL CrossOver 26.3
  Wine sources (what D3DMetal's glue targets; explicitly permitted by CrossOver's license §2). Built in CI,
  reproducible, versioned.

## 6. Programs and bottles (UX model)

- **Add program:** drag an `.exe`/`.msi`/folder onto the window or Dock icon → Harbor analyses it →
  creates a bottle named after the product (from PE version info) with the right Windows version and
  graphics layer → runs the installer → detects new Start Menu entries → adds them to the Library.
- **Portable exe** (not an installer): copied/linked into the bottle and added directly.
- **Library item** = a Program (bottle + Windows path + args + icon). Launch from Harbor, from a generated
  `~/Applications/Harbor/<Program>.app` shim (real Mac app: icon, Dock, Spotlight, Launchpad), or via
  `harbor://launch/<id>`.
- **Advanced:** share one bottle between programs (e.g. Steam + games), duplicate/export/import bottles,
  open `C:` in Finder, run winecfg/regedit, environment variables.

## 7. Recipes (dependencies)

Declarative JSON, written by us (not CrossTie, not winetricks code): id, title, download URL from the vendor,
SHA-256, install steps (run installer with silent flags / extract / register DLL / registry edits), applicable
Windows versions. Triggered by Diagnose (e.g. missing `MSVCP140.dll` → "Install Visual C++ 2015–2022") or a
known-program table. Downloads cached in `Caches/Harbor`.

## 8. Process model, signing, distribution

- Outside the Mac App Store (Wine needs unsandboxed file/process access). Developer ID + notarization +
  hardened runtime; Sparkle for app updates.
- Wine/graphics runtimes are **downloaded on first run** from Harbor's own release manifest (pinned versions,
  SHA-256, signature check), not embedded: keeps the app small and lets runtimes update independently.
  D3DMetal stays unmodified and Apple-signed; its license files ship next to it.
- Entitlements for spawned Wine processes are an open question (§11).
- Launching: the app spawns `wine` via the Launch module; a per-bottle supervisor tracks the process tree so
  quitting Harbor doesn't kill running programs, and "Force Quit" maps to `wineserver -k`.

## 9. Filesystem and privacy

- Wine maps `Z:` to `/` by default, giving every Windows program the whole Mac filesystem. Harbor removes
  `Z:` and instead maps the user's Documents, Downloads and Desktop (and the folder of a dropped file), so
  installers still find their files. Advanced setting to restore `Z:`.
- `winemenubuilder` disabled (Harbor does its own Mac integration). (Done.)

## 10. Diagnose

Every launch logs to the bottle (`last-run.log`, rotated). A matcher table maps Wine log signatures (missing DLL,
unimplemented function, D3D device creation failure, crash in known module) to an explanation and an action
(install recipe, switch graphics layer, change Windows version). Users can export a redacted report.

## 11. Open risks and questions

1. **Rosetta future** — Wine's x86 code depends on Rosetta; Apple's post-macOS-27 Rosetta scope must be confirmed.
2. **D3DMetal 4 is beta**; license is non-commercial — Harbor must stay non-commercial (no paid tier, no ads).
3. **Stock Wine vs CrossOver Wine** with D3DMetal under real games (glue loads on stock 11.21; rendering unverified).
4. **Hardened runtime vs Wine**: spawned ad-hoc-signed Wine binaries, DYLD paths, JIT/unsigned executable
   memory; whether runtimes must be re-signed with Harbor's Developer ID.
5. **Deployment target**: currently macOS 27; lowering to 26 widens reach (D3DMetal 4 minimum OS unconfirmed).
6. **Steam/anti-cheat**: many online games' anti-cheat refuses Wine; set expectations in the UI.

## 12. Independent review (2026-11-19) — what changes

An independent review re-checked the plan against the code and runtime. Items marked ✔ were re-verified by hand.

1. **Stock Wine likely can't present D3DMetal frames.** ✔ Gcenx 11.21 `winemac.so` exports only the two
   unix-call tables; CrossOver's LGPL `winemac.so` also exports `macdrv_functions`, the likely surface hook.
   → Our own CrossOver-LGPL Wine build moves *before* the rendering proof (new M1).
2. **Graphics layer is per process, not per bottle.** The reviewer ran base and derived runtimes in one prefix
   under one wineserver. → Select the layer **per launch**, keyed on the program's exe; this also fixes Steam
   (one shared bottle, many games). §5's "per bottle" rationale is withdrawn.
3. **D3DMetal only for games.** GPTK §2A(i) grants use solely for developing/testing/evaluating games.
   → Never the default for general apps; Automatic uses D3DMetal only for programs classified as games.
4. **Licensing wording corrected.** CrossOver §2's grant is for use *with CrossOver*; our right to build
   CodeWeavers' Wine comes from the LGPL itself. The GPTK license text is EA18380 (8/17/2023) ✔, the copy is
   from a third-party mirror, and the PE DLLs aren't covered by the Apple signature check. → Prefer extracting
   from Apple's own DMG in the release pipeline; keep D3DMetal a separate, removable download; full LGPL source
   offer for every hosted binary (GStreamer, freetype, gmp, wine-mono, gecko…); legal read before public beta.
5. **Runtime cache is unsafe.** Fixed staging name races (reproduced: 3/4 concurrent first launches crashed),
   a missing marker deletes a runtime that may be in use, and the cache key ignores in-place base/redist changes.
   → UUID staging, marker inside staging, atomic rename (EEXIST = success), content-manifest key, lock, GC.
6. **Launch tracking is wrong.** `start /unix` returns immediately; the held `Process` isn't the program.
   → `start /wait` (or wineserver-based tracking); append-mode rotated logs; diagnostic WINEDEBUG channels;
   fix the double-resume race in `waitUntilExitAsync`.
7. **Deployment target.** D3DMetal 4.0b3 needs macOS 14 ✔ (`LSMinimumSystemVersion`); nothing forces 27.
   → Target macOS 26 (built with the 27.2 SDK). Add Rosetta detection + install prompt.
8. **Z: removal is tidiness, not privacy.** Wine also auto-maps mounted volumes (d:, e:) and symlinks home
   folders. → Present it honestly; handle external-drive game libraries explicitly.
9. **Settings robustness.** Versioned `bottle.json` with tolerant decoding (unknown enums → defaults), never
   silently drop bottles, protect reserved env vars, roll back failed bottle creation.
10. **Quarantine** ✔ on downloaded runtime files propagates into clones → strip/verify at install.
11. **Per-bottle disk** ~330 MB → clone a pre-booted template prefix (near-instant creation, CoW).
12. **Launchers are first-class.** Steam/Epic/Battle.net get a shared-bottle flow in the main UX, not "Advanced".

## 13. Development

- `scripts/fetch-runtime.sh` — downloads and verifies the dev Wine + D3DMetal runtime into `Runtime/`.
- `scripts/fetch-sources.sh` + `scripts/build-wine.sh` — Harbor's own Wine from CodeWeavers' CrossOver 26.3
  LGPL sources (x86_64 + i386 wow64, llvm-mingw for PE, freetype, MoltenVK, wine-mono, wine-gecko) into
  `build/out/wine`. Runs in an `arch -x86_64` shell; ~2.5 GB of build/. Not yet built: GnuTLS, GStreamer, SDL2.
- `scripts/check.sh` — the full bar (build, tests, newest-SDK guard); CI runs the same script.
  SwiftPM's default build system records the deployment target as the SDK version, so the script uses the
  native build system until the app moves to an Xcode project (M4).

## 14. Milestones (revised after review)

1. **M0 (done):** HarborKit bottles + launcher, CLI, D3DMetal derived runtime, unit tests, Wine smoke test.
2. **M1 — foundations:** fix review items 5, 6, 9, 10; deployment target 26; first commit + CI (build, unit tests).
3. **M2 — own Wine (done 2026-11-19, local build; CI later):** CrossOver 26.3 Wine builds; `winemac.so` exports
   `macdrv_functions`; bottles in 23 s from a relocated copy with mono/gecko installed silently; D3DMetal 4.0b3
   and MoltenVK load. Open: GnuTLS (HTTPS inside Windows apps), GStreamer (media), SDL2 (controllers).
4. **M3 — rendering proof (test programs done 2026-11-19; real games pending):** `tests/graphics/run.sh`.
   On Harbor's CrossOver Wine + D3DMetal 4.0b3, D3D11 and D3D12 triangles render correctly offscreen and through
   a windowed flip-model swap chain (30 presented frames). On stock Wine 11.21 + D3DMetal both crash at device
   creation, which confirms the reason for M2. Plain Wine: D3D12 (vkd3d → MoltenVK) passes; D3D11 only reaches
   feature level 9.3 on MoltenVK, so SM5 shaders fail, which is why DXMT/DXVK matter for D3D11 without D3DMetal.
   Original plan: self-built console, D3D11 and D3D12 triangle test exes that write a PNG;
   env-gated integration tests on a self-hosted Mac; then one real DX11 and one DX12 game.
5. **M4 — signing spike:** Developer ID app bundle (Xcode project or bundling script), notarization,
   spawning a downloaded runtime outside the bundle, URL scheme, Sparkle.
6. **M5 — add-program flow:** PE analysis, game/app classification, per-launch layer selection, template
   prefixes, program index, Library UI, app shims (prototype Dock identity early), launcher bottles.
7. **M6:** DXMT + DXVK/MoltenVK layers; Recipes + Diagnose; drive-mapping policy.
8. **M7:** Runtime downloader + source offers, legal review, first public beta.
