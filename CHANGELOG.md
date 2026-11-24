# Changelog

What changed in each Harbor release, newest first. The website's changelog page is built from this file.

## 0.1.6 (2026-11-24)

- A program that couldn't run can be reported from its message: Report Problem shows the whole report (versions, the cause and the end of the log, without your user name or your Mac's name) and opens it as a new issue on GitHub in your browser. Help > Report a Problem… does the same for problems with Harbor itself.
- An installation that never finishes can be left: the progress sheet has Stop (add what was installed) and Cancel (add nothing), and a running program can be quit from its tile's menu.
- The library works from the keyboard: Tab reaches the programs, the arrow keys move between them, Return opens one and Cmd-Delete removes it. File has Add Program… (Cmd-O), Open and Remove from Library….
- Harbor has a single library window: File > New Window is gone, and starting a program from its Mac shortcut no longer opens another window.
- A program whose installation was cut short (Harbor was force-quit or the Mac lost power) appears in the library the next time Harbor opens.
- Error messages for a failed download, a program that couldn't be added or opened, and a failed component install are plain sentences instead of technical error dumps.
- The question before removing a program says when the program is running and will be quit, and how many games go to the Trash with Steam or Epic. A finished component install, a shortcut whose program is gone and a few other outcomes that showed nothing now say what happened.
- A program whose data Harbor can't read no longer disappears silently: Harbor says so with a "Show in Finder" link, and keeps its shortcut in the Applications folder.
- Dropping a second program while one is being added, or several files at once, no longer starts two installs on top of each other; Harbor says "Add one program at a time."
- Cancelling an installer no longer leaves an invisible Windows environment behind; it is moved to the Trash.
- Programs whose name contains a word like "Help", "Manual" or "Support" are no longer skipped when adding, and a program such as `SetupDiag.exe` isn't mistaken for an installer.
- Dropping a folder whose installer sits in a subfolder (a disc with `Setup\setup.exe` and its data beside it) gives the installer the whole folder.
- An installer started from an external drive or USB stick can no longer change the files beside it, and unrelated files in Downloads that merely share the start of an installer's name stay out of the bottle.
- Quitting a program that returns an error code on exit, or removing a program while it runs, no longer shows a failure message. A program opened twice stays marked "Running" until both are closed.
- A program in a folder with accents or other non-English characters that is missing Visual C++ gets the offer to install it, and a component that is already installed isn't offered again.
- A Windows component whose installation fails no longer leaves the program's Windows version changed, and a failed .NET Framework install says that .NET is missing until it is installed again.
- An update to Windows support that was interrupted (Harbor quit, or the Mac lost power) is finished at the next start instead of leaving programs unable to start, and no longer leaves hundreds of megabytes behind. When a program has to wait for newer Windows support, Harbor says why.
- A program started at the very moment Windows support is being updated no longer fails to open; Harbor asks to try again in a moment.
- If an update to Windows support doesn't start and the previous version is no longer on disk, Harbor keeps the update and says so instead of ending up with no Windows support.
- A check for Windows support that happens to run while a new version is being published no longer reports that the list isn't signed by Harbor.
- When setting up Windows, a store's installer or a Windows component fails, the message reads "A Windows setup step ended with an error (status N)." instead of "Wine exited with status N".
- When the update server answers with an error, Settings says the server couldn't be reached instead of "The runtime list isn't signed by Harbor."

## 0.1.5 (2026-11-23)

- Harbor comes as an installer: open it and Harbor is in Applications; macOS then offers to move the installer to the Trash.
- Harbor has an app icon: a lighthouse.
- The Windows user in new bottles is named `harbor`. Bottles you already have keep their user and its folders.
- The licences of Harbor and of the components it downloads come with them.

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
