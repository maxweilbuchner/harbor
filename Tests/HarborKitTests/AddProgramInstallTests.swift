import Foundation
import Testing
@testable import HarborKit

/// `AddProgram.add` from the dropped file to the library entry, with a script standing in for Wine.
@Suite struct AddProgramInstallTests {
    let fm = FileManager.default

    /// A flow whose "wine" sets up an empty drive C: for `wineboot` and runs `installer` (shell; `$C` is drive
    /// C:, `$APP` a Windows program to copy, `$LINKS` the folder of `links`) in place of any program it is asked
    /// to start. `afterSetup` runs once Windows is set up in the new bottle, `$BIN` being Wine's folder.
    /// `base` holds everything, the bottles and their trash (`base/trash`) too; remove it at the end.
    func fixture(installer: String, links: [String: Data] = [:], afterSetup: String = "")
        throws -> (flow: AddProgram, store: BottleStore, base: URL) {
        let base = fm.temporaryDirectory.appending(path: "harbor-install-\(UUID().uuidString)").resolvingSymlinksInPath()
        let bin = base.appending(path: "wine/bin"), linkFolder = base.appending(path: "links")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        for (name, data) in links { try data.write(to: linkFolder.appending(path: name)) }
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        let wine = """
        #!/bin/sh
        C="$WINEPREFIX/drive_c"; APP='\(app.path)'; LINKS='\(linkFolder.path)'
        MENU="$C/ProgramData/Microsoft/Windows/Start Menu/Programs"; BIN="$(dirname "$0")"
        case "$1" in
        wineboot) mkdir -p "$C/windows" "$WINEPREFIX/dosdevices";;
        reg) case "$*" in *ShowCrashDialog*) :
        \(afterSetup)
        ;; esac;;
        start|msiexec) mkdir -p "$MENU"
        \(installer)
        ;;
        esac
        """
        for (name, script) in [("wine", wine), ("wineserver", "#!/bin/sh\nexit 0\n")] {
            try script.write(to: bin.appending(path: name), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: name).path)
        }
        let launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")),
                                    runtimesDirectory: base.appending(path: "runtimes"))
        let store = BottleStore(directory: base.appending(path: "bottles"), trash: base.appending(path: "trash"))
        let template = PrefixTemplate(launcher: launcher, directory: base.appending(path: "templates"))
        return (AddProgram(store: store, launcher: launcher, template: template), store, base)
    }

    /// A Windows program at `path` below `base`, under a name that makes it an installer or not.
    func program(_ path: String, in base: URL) throws -> URL {
        let url = base.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: try #require(Bundle.module.url(forResource: "app64", withExtension: "exe")), to: url)
        return url
    }

    // MARK: #59

    /// A game called "Manual Samuel" is all the installer leaves, beside its uninstaller: it is the program.
    @Test func aProgramNamedLikeAManualIsAddedWhenItIsAllThereIs() async throws {
        let f = try fixture(installer: """
            mkdir -p "$C/Games/Manual Samuel"
            cp "$APP" "$C/Games/Manual Samuel/Manual Samuel.exe"; cp "$APP" "$C/Games/Manual Samuel/unins000.exe"
            cp "$LINKS"/*.lnk "$MENU/"
            """, links: ["Manual Samuel.lnk": ProgramsTests.link(target: #"C:\Games\Manual Samuel\Manual Samuel.exe"#),
                         "Uninstall Manual Samuel.lnk": ProgramsTests.link(target: #"C:\Games\Manual Samuel\unins000.exe"#)])
        defer { try? fm.removeItem(at: f.base) }
        let (bottle, programs) = try await f.flow.add(try program("Media/setup.exe", in: f.base))
        #expect(programs.map(\.name) == ["Manual Samuel"])
        #expect(bottle.programs() == programs)
    }

    /// The same without shortcuts: the one executable, whatever it is called, but never the uninstaller.
    @Test func anExecutableNamedLikeHelpIsAddedWhenItIsAllThereIs() async throws {
        let f = try fixture(installer: """
            mkdir -p "$C/Program Files/Vendor"
            cp "$APP" "$C/Program Files/Vendor/Support.exe"; cp "$APP" "$C/Program Files/Vendor/unins000.exe"
            """)
        defer { try? fm.removeItem(at: f.base) }
        let (_, programs) = try await f.flow.add(try program("Media/setup.exe", in: f.base))
        #expect(programs.map(\.windowsPath) == [#"C:\Program Files\Vendor\Support.exe"#])
    }

    /// Beside a real program, its manual and its uninstaller stay out as before.
    @Test func helpersStayOutWhenARealProgramIsBesideThem() async throws {
        let f = try fixture(installer: """
            mkdir -p "$C/Program Files/Thing"
            for n in Thing Manual unins000; do cp "$APP" "$C/Program Files/Thing/$n.exe"; done
            cp "$LINKS"/*.lnk "$MENU/"
            """, links: ["Thing.lnk": ProgramsTests.link(target: #"C:\Program Files\Thing\Thing.exe"#),
                         "Thing Manual.lnk": ProgramsTests.link(target: #"C:\Program Files\Thing\Manual.exe"#),
                         "Uninstall Thing.lnk": ProgramsTests.link(target: #"C:\Program Files\Thing\unins000.exe"#)])
        defer { try? fm.removeItem(at: f.base) }
        let (_, programs) = try await f.flow.add(try program("Media/setup.exe", in: f.base))
        #expect(programs.map(\.name) == ["Thing"])
    }

    @Test func auxiliaryWordsCountAsWholeWordsOnly() {
        for name in ["HelpNDoc", "TeamViewer QuickSupport", "LicenseManager.exe", "Removery", "Supporter"] {
            #expect(!Bottle.isAuxiliary(name: name, target: name), "\(name)")
        }
        for name in ["Help", "Thing Help", "Thing Manual", "License", "Licenses", "Thing_Readme.exe", "Visit Website",
                     "Remove Thing", "Uninstall Thing", "Thing Uninstaller", "unins000.exe", "Release Notes"] {
            #expect(Bottle.isAuxiliary(name: name, target: name), "\(name)")
        }
    }

    /// "setup" and "install" make an installer only where the word ends there: `SetupDiag.exe` is a program.
    @Test func installerWordsInsideLongerWordsDoNotMakeAnInstaller() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        for name in ["SetupDiag", "InstallShieldViewer", "Installation Notes"] {
            #expect(try ProgramAnalysis.analyze(try program("\(name).exe", in: base)).installer == nil, "\(name)")
        }
        for name in ["setup", "ChromeSetup", "thing_setup_1.2", "Thing Setup", "install", "Install Thing",
                     "ThingInstaller-x64", "npp.8.6.Installer.x64"] {
            #expect(try ProgramAnalysis.analyze(try program("\(name).exe", in: base)).installer == .other, "\(name)")
        }
        let file = try program("thing.exe", in: base)
        let data = try Data(contentsOf: file), pe = try #require(PEFile(data))
        #expect(ProgramAnalysis.detectInstaller(data, pe: pe, file: file, description: "SetupDiag") == nil)
        #expect(ProgramAnalysis.detectInstaller(data, pe: pe, file: file, description: "Thing Setup") == .other)
    }

    // MARK: #60

    /// A disc whose `autorun.inf` opens `Setup\setup.exe` while the data sits at the disc's top: the installer
    /// runs below the whole dropped folder, also when that holds a dot-file.
    @Test func anInstallerInASubfolderOfADroppedFolderSeesTheWholeFolder() async throws {
        // `start /wait /unix <installer>`: the installer installs only if it finds its data one folder up.
        let f = try fixture(installer: """
            [ -f "$(dirname "$4")/../Data/data1.cab" ] || exit 0
            mkdir -p "$C/Program Files/Thing"; cp "$APP" "$C/Program Files/Thing/Thing.exe"
            """)
        defer { try? fm.removeItem(at: f.base) }
        let disc = f.base.appending(path: "Thing Disc")
        _ = try program("Thing Disc/Setup/setup.exe", in: f.base)
        try fm.createDirectory(at: disc.appending(path: "Data"), withIntermediateDirectories: true)
        try Data("cab".utf8).write(to: disc.appending(path: "Data/data1.cab"))
        try Data().write(to: disc.appending(path: ".disc-id"))
        try "[autorun]\r\nopen=Setup\\setup.exe\r\n".write(to: disc.appending(path: "autorun.inf"), atomically: true, encoding: .utf8)
        let (bottle, programs) = try await f.flow.add(disc)
        #expect(programs.map(\.windowsPath) == [#"C:\Program Files\Thing\Thing.exe"#])
        #expect(!fm.fileExists(atPath: bottle.importsDirectory.path))            // the copy went after the install
        #expect(fm.fileExists(atPath: disc.appending(path: "Data/data1.cab").path))
    }

    // MARK: #57

    func trashed(_ base: URL) -> [String] { (try? fm.contentsOfDirectory(atPath: base.appending(path: "trash").path)) ?? [] }

    /// Cancel in the installer's window: nothing was installed, and no bottle stays behind unseen.
    @Test func aCancelledInstallLeavesNoBottle() async throws {
        let f = try fixture(installer: "exit 1")
        defer { try? fm.removeItem(at: f.base) }
        let setup = try program("Media/Thing Setup.exe", in: f.base)
        await #expect(throws: AddProgram.Failure.nothingInstalled(name: "Fixture App")) { try await f.flow.add(setup) }
        #expect(f.store.scan().bottles.isEmpty && f.store.scan().damaged.isEmpty)
        // In the Trash, not deleted; and a second try doesn't become "fixture-app-2".
        #expect(trashed(f.base).count == 1)
        await #expect(throws: AddProgram.Failure.nothingInstalled(name: "Fixture App")) { try await f.flow.add(setup) }
        // (The test's trash names what it holds "<folder>-<UUID>".)
        #expect(trashed(f.base).count == 2 && trashed(f.base).allSatisfy { $0.dropLast(37) == "fixture-app" })
    }

    /// Something was installed that Harbor can't name (here only an uninstaller): the bottle is kept.
    @Test func anInstallHarborCannotNameKeepsItsBottle() async throws {
        let f = try fixture(installer: #"mkdir -p "$C/Program Files/Thing"; cp "$APP" "$C/Program Files/Thing/unins000.exe""#)
        defer { try? fm.removeItem(at: f.base) }
        let setup = try program("Media/setup.exe", in: f.base)
        await #expect(throws: AddProgram.Failure.installerFoundNothing(name: "Fixture App")) { try await f.flow.add(setup) }
        #expect(f.store.list().count == 1 && trashed(f.base).isEmpty)
        #expect(!f.store.list()[0].isClaimed)
    }

    /// The installer can't even be started (Wine went missing after setup): the new bottle is removed.
    @Test func aFailureBeforeTheInstallerRanRemovesTheNewBottle() async throws {
        let f = try fixture(installer: "", afterSetup: #"rm "$0""#)
        defer { try? fm.removeItem(at: f.base) }
        let setup = try program("Media/setup.exe", in: f.base)
        await #expect(throws: (any Error).self) { try await f.flow.add(setup) }
        #expect(f.store.scan().bottles.isEmpty && f.store.scan().damaged.isEmpty && trashed(f.base).isEmpty)
    }

    /// The installer finished, then waiting for Windows to stop failed: what it installed is kept, and the next
    /// start records it. The same goes for an install during which Harbor quit.
    @Test func aFailureAfterTheInstallerRanKeepsTheBottleForAdoption() async throws {
        let f = try fixture(installer: """
            mkdir -p "$C/Program Files/Thing"; cp "$APP" "$C/Program Files/Thing/Thing.exe"
            cp "$LINKS/Thing.lnk" "$MENU/"; rm "$BIN/wineserver"
            """, links: ["Thing.lnk": ProgramsTests.link(target: #"C:\Program Files\Thing\Thing.exe"#)])
        defer { try? fm.removeItem(at: f.base) }
        let setup = try program("Media/setup.exe", in: f.base)
        await #expect(throws: (any Error).self) { try await f.flow.add(setup) }
        let kept = try #require(f.store.list().first)
        #expect(kept.programs().isEmpty && trashed(f.base).isEmpty)

        let found = AddProgram.adoptUnrecorded(in: f.store)
        #expect(found.adopted == [kept] && found.empty.isEmpty)
        #expect(kept.programs().map(\.name) == ["Thing"])
        // Once recorded, a bottle is no longer looked at.
        #expect(AddProgram.adoptUnrecorded(in: f.store) == ([], []))
    }

    /// Which bottles are adopted, which are reported empty, and which are none of this function's business.
    @Test func bottlesWithoutALibraryEntryAreAdoptedOrReportedEmpty() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let store = BottleStore(directory: base.appending(path: "bottles"), trash: base.appending(path: "trash"))
        func bottle(_ name: String, _ files: [String]) throws -> Bottle {
            let b = try store.create(name: name)
            try fm.createDirectory(at: b.driveC.appending(path: "windows"), withIntermediateDirectories: true)
            for file in files { _ = try program(file, in: b.driveC) }
            return b
        }
        // No shortcut, an executable outside Program Files: found like after an install. Wine's own programs
        // and an uninstaller aren't what was installed.
        let wines = ["Program Files/Internet Explorer/iexplore.exe", "Program Files (x86)/Windows NT/Accessories/wordpad.exe",
                     "Program Files/Windows Media Player/wmplayer.exe", "windows/notepad.exe"]
        let interrupted = try bottle("Interrupted", wines + ["Games/Thing/Thing.exe", "Games/Thing/unins000.exe"])
        let cancelled = try bottle("Cancelled", wines)
        let neverSetUp = try store.create(name: "Never Set Up")
        // Not looked at: a library entry exists (even an unreadable or empty one), a store lives there, or an
        // add is under way.
        let recorded = try bottle("Recorded", ["Games/Other/Other.exe"])
        try recorded.savePrograms([])
        let damaged = try bottle("Damaged", ["Games/Other/Other.exe"])
        try Data("garbage".utf8).write(to: damaged.programsFile)
        _ = try bottle("Steam", ["Program Files (x86)/Steam/steam.exe"])
        let adding = try bottle("Adding", ["Games/Half/Half.exe"])
        let release = adding.claim()

        let found = AddProgram.adoptUnrecorded(in: store)
        #expect(found.adopted.map(\.settings.name) == ["Interrupted"])
        #expect(interrupted.programs().map(\.windowsPath) == [#"C:\Games\Thing\Thing.exe"#])
        #expect(Set(found.empty.map(\.settings.name)) == ["Cancelled", "Never Set Up"])
        #expect(fm.fileExists(atPath: cancelled.root.path) && fm.fileExists(atPath: neverSetUp.root.path))   // the caller's to remove
        #expect(recorded.programs().isEmpty && damaged.programsFileIsDamaged)
        #expect(!fm.fileExists(atPath: adding.programsFile.path))
        // When that add is over (or its process gone), the bottle is like any other.
        release()
        #expect(AddProgram.adoptUnrecorded(in: store).adopted.map(\.settings.name) == ["Adding"])
    }

    /// A dropped folder whose only program has such a name stands for that program.
    @Test func aDroppedFolderWithOnlyAnAuxiliaryNamedProgramIsThatProgram() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        for f in ["Manual Samuel/Manual Samuel.exe", "Manual Samuel/Uninstall.exe", "Thing/thing.exe", "Thing/Help.exe"] {
            _ = try program(f, in: base)
        }
        #expect(try AddProgram.entry(in: base.appending(path: "Manual Samuel")).lastPathComponent == "Manual Samuel.exe")
        #expect(try AddProgram.entry(in: base.appending(path: "Thing")).lastPathComponent == "thing.exe")
    }
}
