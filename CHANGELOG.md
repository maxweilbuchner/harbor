# Changelog

What changed in each Harbor release, newest first. The website's changelog page is built from this file.

## Unreleased

- Harbor has an app icon: a lighthouse.
- The Windows user in new bottles is named `harbor`. Bottles you already have keep their user and its folders. Takes effect with the next update of the Windows support.

## 0.1.4 (2026-11-23)

- A program's whole folder can be dropped in or chosen, such as the contents of a disc or an unpacked download. Harbor picks the installer or program inside it.
- Installers on a mounted disk image or another disk run from a temporary drive D:, so they find the files that came with them.
- An installer's own folder comes into the bottle with it, also when it holds a manual or pictures.
- Programs an installer puts outside Program Files are found.

## 0.1.3 (2026-11-23)

- A status message that is cut short in the sidebar opens in full with a click.

## 0.1.2 (2026-11-23)

- A Settings window shows the installed versions and whether an update is downloading or waiting.
- The status line sits at the bottom of the sidebar and stays visible when the sidebar is hidden.
- A program that changes the display mode no longer takes over the Mac's displays.
- A partly downloaded update of the Windows support is no longer installed as if it were complete.

## 0.1.1 (2026-11-20)

- Fullscreen programs get a macOS Space of their own, and Cmd-Q quits Windows programs, also ones that refuse to close.
- Microsoft's .NET Framework 4.8 and the DirectX 9 to 11 extras can be installed as Windows components.
- Windows programs only see their own drive C: unless you allow one to access your Mac's files.
- Store titles that aren't games stay off D3DMetal.
- A click selects a program at once.
- Changing the display mode no longer hangs a program.

## 0.1.0 (2026-11-20)

- First release. Add a program or installer by dropping it in, and Steam and the Epic Games Store in one click, with their games in the library.
- DirectX 11 and 12 games run through D3DMetal, other Direct3D 10 and 11 programs through DXMT.
- Every program in the library gets a Mac shortcut.
- Harbor and its Windows support update themselves.
