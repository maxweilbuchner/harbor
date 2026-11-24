# Releasing Harbor

Two things are released independently: the **app** (Harbor.app, updated through Sparkle) and the **Windows
runtime** (Wine + D3DMetal + DXMT, updated by Harbor itself from a signed list). Both reach existing
installations without anything to download by hand. Keys: the runtime list is signed with
`~/.config/harbor/runtime-signing.key` (Ed25519), app updates with the Sparkle key in the login keychain;
the app and the runtime with the "Developer ID Application" certificate, the installer package with the
"Developer ID Installer" certificate (a separate one: Xcode > Settings > Accounts > Manage Certificates > + ,
or developer.apple.com > Certificates); notarization uses the `harbor-notary` keychain profile. None of these are in the repository.

The "Developer ID Application" certificate was renewed on 2026-11-24: the new one **expires 2027-12-24**, the
previous one on 2027-02-01. What is signed and timestamped before a certificate expires stays valid; nothing new
can be signed with it afterwards, so renew earlier (an Apple Developer account action; the request file comes
from `openssl req -new -newkey rsa:2048` or Keychain Access). While both certificates are in the keychain the
scripts refuse to sign, because the name matches two: set `SIGN_IDENTITY` to the SHA-1 of the new one
(`security find-identity -v -p codesigning`; `F38A49201551AA9021F89173E2535CD8EA3CBC3B`) until the old one has
been deleted from the keychain, and `INSTALLER_IDENTITY` likewise if the installer certificate is ever doubled.

## Runtime only (a Wine patch, a new D3DMetal or DXMT)

1. Commit everything; bump `RUNTIME_REVISION` in `scripts/versions.env` (the runtime records the commit it was
   built from, and packaging refuses a build without that record).
2. `scripts/fetch-sources.sh` (it also fetches the Wine Mono and Wine Gecko source archives that are published
   beside the runtime), `scripts/build-wine.sh`, copy `build/out/wine` to a clean folder,
   `scripts/sign-runtime.sh <folder>`, `scripts/notarize.sh --runtime-only <folder>` (no app bundle needed).
3. D3DMetal comes from Apple's own image: `scripts/import-d3dmetal.sh <Game_Porting_Toolkit .dmg>` (pinned by
   SHA-256 in `versions.env`). It leaves a list of every file it took beside them (`.harbor-files.sha256`), and
   packaging refuses a D3DMetal folder that has no list (one imported before the list existed) or that no longer
   matches it: import again.
4. Run the Wine tests against it (`HARBOR_WINE_ROOT=<folder>`): `WindowsTests/abi/run.sh`, `xproc/run.sh`,
   `net/run.sh`, `user/run.sh`, `appname/run.sh`, `installer/run.sh`, `quit/run.sh`, `graphics/modeset.sh`,
   `graphics/run.sh "d3dmetal dxmt"`, `graphics/fullscreen.sh`, `graphics/spaces.sh` (`quit/run.sh` and the last
   three open windows, `fullscreen.sh` and `spaces.sh` fullscreen ones, and switch Spaces: leave the Mac alone
   while they run). `graphics/run.sh` and `graphics/fullscreen.sh` test D3DMetal and need it in the checkout:
   step 3's import (`Runtime/d3dmetal-<version>`). An installed copy of Harbor's runtime is found before that
   folder, so name it to be sure which one is tested: `HARBOR_D3DMETAL_LIB=$PWD/Runtime/d3dmetal-<version>/lib`.
   Without D3DMetal `fullscreen.sh` stops at once and says so; `run.sh` reports its D3DMetal tests as "no result".
5. `scripts/package-runtime.sh <wine folder> <d3dmetal folder>` then `scripts/publish-runtime.sh`. Packaging
   refuses a runtime that was built with uncommitted changes in `scripts/` or that Apple doesn't know as
   notarized (sign, then notarize, and don't sign again). The list gets a new `sequence`; installations refuse
   older lists.
6. Check a fresh download: `harbor-cli install-runtime <list URL> --into <scratch>` and rerun the tests on it.

Installed copies pick it up within six hours of use and switch when no Windows program is running.

`runtime.json` and `runtime.json.sig` are two files on GitHub, which can't replace a pair at once:
`publish-runtime.sh` replaces both side by side as its last upload, and for the moment that takes one of them is
missing or the two don't belong together. An installation that checks right then gets "not signed by Harbor" (or
not found); nothing changes on that Mac, and the check is repeated: once right away when the signature didn't
match, and again at the next regular check. A failed check during a publication is therefore expected, not a
sign of a bad list.

## App only

0. In `CHANGELOG.md`, turn `## Unreleased` into `## <version> (<date>)`. The website builds its changelog and its
   list of releases from that file.
1. Commit and push everything. `scripts/release-app.sh <version> --publish` first checks that nothing is
   uncommitted, that `HEAD` is what `main` is at on GitHub, that the changelog has the version's section and that
   no release, tag or feed item for the version exists; then it builds, signs, notarizes, zips, signs the zip
   for Sparkle, builds and notarizes the installer package (`scripts/package-installer.sh`), creates the GitHub
   release with both, tagged at that commit, and only then adds the item to `updates/appcast.xml`. Installed
   copies update from the zip; the website's button downloads the installer.
2. Commit and push `updates/appcast.xml`: apps read the feed from the main branch. The push also republishes the
   website (`site/`, deployed by `.github/workflows/site.yml`), whose download button reads the feed.

To rehearse an update first: build the new version with `scripts/release-app.sh <version> --local <url> <dir>`
and an older one with `HARBOR_UPDATE_FEED_URL=<url>/appcast.xml HARBOR_UPDATE_TEST=1 scripts/bundle-app.sh`,
serve `<dir>`, start the older one: it must replace itself. Release builds read no such settings from their
environment, and `--publish` refuses a bundle built with them.

## Both, when they depend on each other

- **The new runtime needs the new app** (for example a new component the old app can't use): release the app
  first, then publish the runtime with `RUNTIME_MIN_APP_BUILD=<the app's build number>` set for
  `package-runtime.sh`. Older apps keep their runtime and tell the user to update Harbor.
- **The new app needs the new runtime:** publish the runtime first, note the `sequence` in its `runtime.json`, set
  `RUNTIME_MIN_SEQUENCE` to it in `scripts/versions.env`, then release the app. An app that finds an older runtime
  installed updates it at once and holds program starts until that's done.

A runtime update whose Wine doesn't start on a Mac is rolled back there and that list isn't tried again on that
Mac; publish a fixed runtime (a new list, with a new sequence) to reach it.
