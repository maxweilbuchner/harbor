# Releasing Harbor

Two things are released independently: the **app** (Harbor.app, updated through Sparkle) and the **Windows
runtime** (Wine + D3DMetal + DXMT, updated by Harbor itself from a signed list). Both reach existing
installations without anything to download by hand. Keys: the runtime list is signed with
`~/.config/harbor/runtime-signing.key` (Ed25519), app updates with the Sparkle key in the login keychain;
the app and the runtime with the "Developer ID Application" certificate, the installer package with the
"Developer ID Installer" certificate (a separate one: Xcode > Settings > Accounts > Manage Certificates > + ,
or developer.apple.com > Certificates); notarization uses the `harbor-notary` keychain profile. None of these are in the repository.

The "Developer ID Application" certificate **expires 2027-02-01**. What is signed and timestamped before then
stays valid; nothing new can be signed after it, so renew it earlier (an Apple Developer account action). While
the renewed certificate and the old one are both in the keychain the scripts refuse to sign, because the name
matches two: set `SIGN_IDENTITY` to the SHA-1 of the one to use (`security find-identity -v -p codesigning`), and
`INSTALLER_IDENTITY` likewise for the installer certificate.

## Runtime only (a Wine patch, a new D3DMetal or DXMT)

1. Commit everything; bump `RUNTIME_REVISION` in `scripts/versions.env` (the runtime records the commit it was
   built from, and packaging refuses a build without that record).
2. `scripts/fetch-sources.sh` (it also fetches the Wine Mono and Wine Gecko source archives that are published
   beside the runtime), `scripts/build-wine.sh`, copy `build/out/wine` to a clean folder,
   `scripts/sign-runtime.sh <folder>`, `scripts/notarize.sh --runtime-only <folder>` (no app bundle needed).
3. D3DMetal comes from Apple's own image: `scripts/import-d3dmetal.sh <Game_Porting_Toolkit .dmg>` (pinned by
   SHA-256 in `versions.env`).
4. Run the Wine tests against it (`HARBOR_WINE_ROOT=<folder>`): `WindowsTests/abi/run.sh`, `xproc/run.sh`,
   `net/run.sh`, `user/run.sh`, `graphics/run.sh "d3dmetal dxmt"`.
5. `scripts/package-runtime.sh <wine folder> <d3dmetal folder>` then `scripts/publish-runtime.sh`. Packaging
   refuses a runtime that was built with uncommitted changes in `scripts/` or that Apple doesn't know as
   notarized (sign, then notarize, and don't sign again). The list gets a new `sequence`; installations refuse
   older lists.
6. Check a fresh download: `harbor-cli install-runtime <list URL> --into <scratch>` and rerun the tests on it.

Installed copies pick it up within six hours of use and switch when no Windows program is running.

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
