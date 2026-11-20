import Foundation
import Testing
@testable import HarborKit

@Suite struct WineAppsTests {
    let fm = FileManager.default
    let runtimes = [URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes"),
                    URL(filePath: "/Users/me/Library/Application Support/Harbor/Installed")]

    @Test func recognisesProgramsStartedThroughALoaderLink() {
        // What Wine's loader link folder holds: a symlink to the runtime's ntdll.so next to the program's link.
        let harbor: (URL) -> URL = { url in
            url.lastPathComponent == "ntdll.so" && url.path.contains("winetemp-")
                ? URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes/d3dmetal-4.0b3-ed28/lib/wine/x86_64-unix/ntdll.so") : url
        }
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                      runtimes: runtimes, resolve: harbor))
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/private/var/folders/x/T/winetemp-1-2-3-4/Wine Explorer"),
                                      runtimes: runtimes, resolve: harbor))
        // Another Wine's loader links (CrossOver uses the same folder names) aren't Harbor's.
        let other: (URL) -> URL = { url in
            url.lastPathComponent == "ntdll.so" ? URL(filePath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so") : url
        }
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                       runtimes: runtimes, resolve: other))
        // A link folder without the ntdll.so symlink.
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                       runtimes: runtimes, resolve: { $0 }))
    }

    @Test func recognisesProcessesRunFromTheRuntimeItself() {
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Installed/wine/bin/wine"),
                                      runtimes: runtimes, resolve: { $0 }))
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes/dxmt-1/bin/wineserver"),
                                      runtimes: runtimes, resolve: { $0 }))
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/Applications/Safari.app/Contents/MacOS/Safari"),
                                       runtimes: runtimes, resolve: { $0 }))
        // A sibling folder that merely starts with a runtime folder's name.
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes-old/bin/wine"),
                                       runtimes: runtimes, resolve: { $0 }))
    }

    @Test func followsTheLoaderLinkFoldersSymlinkOnDisk() throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-wineapps-\(UUID().uuidString)")
        let unix = root.appending(path: "Runtimes/d3dmetal-1/lib/wine/x86_64-unix")
        let links = root.appending(path: "T/winetemp-1-2-3-4"), foreign = root.appending(path: "T/winetemp-5-6-7-8")
        for dir in [unix, links, foreign, root.appending(path: "Elsewhere")] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for file in [unix.appending(path: "ntdll.so"), root.appending(path: "Elsewhere/ntdll.so"),
                     links.appending(path: "Portal 2"), foreign.appending(path: "Portal 2")] { try Data().write(to: file) }
        try fm.createSymbolicLink(at: links.appending(path: "ntdll.so"), withDestinationURL: unix.appending(path: "ntdll.so"))
        try fm.createSymbolicLink(at: foreign.appending(path: "ntdll.so"), withDestinationURL: root.appending(path: "Elsewhere/ntdll.so"))
        let runtimes = [root.appending(path: "Runtimes")]
        #expect(WineApps.isHarborWine(executable: links.appending(path: "Portal 2"), runtimes: runtimes))
        #expect(!WineApps.isHarborWine(executable: foreign.appending(path: "Portal 2"), runtimes: runtimes))
    }

    @Test func readsAProcessStartTimeFromTheKernel() throws {
        let before = Date()
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let started = try #require(WineApps.startDate(of: child.processIdentifier))
        #expect(started >= before.addingTimeInterval(-1) && started <= Date().addingTimeInterval(1))
        // This test process started before its child.
        #expect(try #require(WineApps.startDate(of: ProcessInfo.processInfo.processIdentifier)) <= started)
        #expect(WineApps.startDate(of: 99_999_999) == nil)
    }
}

@Suite struct ShortcutSyncTests {
    let fm = FileManager.default

    func names(in dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
    }

    @Test func overlappingSyncsLeaveOneShortcutPerProgram() async {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        let programs = ["Alpha", "Beta", "Gamma"].map { Program(name: $0, windowsPath: #"C:\p.exe"#) }
        // Two reloads in quick succession: the second sync is asked for while the first is still signing.
        await withCheckedContinuation { finished in
            shortcuts.scheduleSync(programs) { _ in nil }
            shortcuts.scheduleSync(programs, icon: { _ in nil }, done: { finished.resume() })
        }
        #expect(names(in: dir) == ["Alpha.app", "Beta.app", "Gamma.app"])
    }

    @Test func scheduledSyncsRunInTheOrderAskedFor() async {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        let a = Program(name: "Alpha", windowsPath: #"C:\a.exe"#), b = Program(name: "Beta", windowsPath: #"C:\b.exe"#)
        await withCheckedContinuation { finished in
            shortcuts.scheduleSync([a, b]) { _ in nil }
            shortcuts.scheduleSync([a]) { _ in nil }
            shortcuts.scheduleSync([b], icon: { _ in nil }, done: { finished.resume() })
        }
        #expect(names(in: dir) == ["Beta.app"])   // the last request wins
    }

    @Test func syncRemovesDuplicateShortcutsOfOneProgram() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        let game = Program(name: "Game 3", windowsPath: #"C:\g.exe"#), twin = Program(name: "Game 3", windowsPath: #"C:\h.exe"#)
        // What overlapping syncs used to leave behind: two shortcuts carrying the same program ID.
        try shortcuts.create(for: game, iconPNG: nil)
        try shortcuts.create(for: game, iconPNG: nil)
        try shortcuts.create(for: twin, iconPNG: nil)
        #expect(names(in: dir) == ["Game 3 2.app", "Game 3 3.app", "Game 3.app"])
        shortcuts.sync([game, twin]) { _ in nil }
        #expect(names(in: dir) == ["Game 3 3.app", "Game 3.app"])   // the other program of that name keeps its own
        #expect(shortcuts.existing().mapValues(\.lastPathComponent) == [game.id: "Game 3.app", twin.id: "Game 3 3.app"])
    }

    @Test func removeDeletesEveryShortcutOfTheProgram() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        let game = Program(name: "Game", windowsPath: #"C:\g.exe"#), other = Program(name: "Other", windowsPath: #"C:\o.exe"#)
        try shortcuts.create(for: game, iconPNG: nil)
        try shortcuts.create(for: game, iconPNG: nil)
        try shortcuts.create(for: other, iconPNG: nil)
        shortcuts.remove(game.id)
        #expect(names(in: dir) == ["Other.app"])
    }
}

@Suite struct LibraryScanTests {
    let fm = FileManager.default

    /// A bottle holding Steam with one game, the Epic Games Launcher with one game, and one program of its own.
    func mixedBottle() throws -> (bottle: Bottle, steamManifest: URL, epicManifest: URL) {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-library-\(UUID().uuidString)"))
        let b = try store.create(name: "Steam")
        let steam = b.driveC.appending(path: "Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        let steamManifest = steam.appending(path: "steamapps/appmanifest_620.acf")
        try #""AppState" { "appid" "620" "name" "Portal 2" "installdir" "Portal 2" }"#
            .write(to: steamManifest, atomically: true, encoding: .utf8)
        let launcher = b.driveC.appending(path: "Program Files/Epic Games/Launcher/Portal/Binaries/Win64")
        try fm.createDirectory(at: launcher, withIntermediateDirectories: true)
        try Data().write(to: launcher.appending(path: "EpicGamesLauncher.exe"))
        let manifests = b.driveC.appending(path: "ProgramData/Epic/EpicGamesLauncher/Data/Manifests")
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        let epicManifest = manifests.appending(path: "A1.item")
        try #"{ "AppName": "Sugar", "DisplayName": "Alan Wake", "bIsApplication": true }"#
            .write(to: epicManifest, atomically: true, encoding: .utf8)
        try b.savePrograms([Program(name: "Steam", windowsPath: #"C:\Program Files (x86)\Steam\steam.exe"#, isGame: true)])
        return (b, steamManifest, epicManifest)
    }

    /// This Mac's ID salt, kept out of the real Application Support folder.
    let salt = LaunchSalt(file: FileManager.default.temporaryDirectory.appending(path: "harbor-salt-\(UUID().uuidString)/launch-salt"))

    @Test func aSteamBottleKeepsItsEpicGames() throws {
        let (b, _, _) = try mixedBottle()
        let entries = Library.scan([b], salt: salt)
        #expect(Set(entries.map(\.program.name)) == ["Steam", "Portal 2", "Alan Wake"])
        #expect(Set(entries.filter(\.managedByStore).map(\.program.name)) == ["Portal 2", "Alan Wake"])
        #expect(entries.allSatisfy { $0.bottle == b })
    }

    @Test func storeGamesKeepTheirDateAcrossScans() throws {
        let (b, steamManifest, epicManifest) = try mixedBottle()
        // Installed a while ago: the manifests are older than the program the user added just now.
        let installed = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.creationDate: installed], ofItemAtPath: steamManifest.path)
        try fm.setAttributes([.creationDate: installed.addingTimeInterval(60)], ofItemAtPath: epicManifest.path)
        let first = Library.scan([b], salt: salt)
        #expect(first.map(\.program.name) == ["Steam", "Alan Wake", "Portal 2"])   // newest first
        #expect(first.first { $0.program.name == "Portal 2" }?.program.addedAt == installed)
        #expect(first.first { $0.program.name == "Alan Wake" }?.program.addedAt == installed.addingTimeInterval(60))
        #expect(Library.scan([b], salt: salt) == first)
    }
}

@Suite struct RosettaInstallTests {
    @Test func appleScriptRunsOutsideTheCallingThread() async {
        // From a background task, as the app does it: nothing here may need the main thread.
        let (ok, failed) = await Task.detached {
            (Rosetta.runAppleScript("return 1"), Rosetta.runAppleScript(#"error "Not today" number -128"#))
        }.value
        #expect(ok == nil)
        #expect(failed == "Not today")
    }

    @Test func readsTheMessageFromOsascriptsError() {
        #expect(Rosetta.errorMessage(fromOsascript: "0:112: execution error: User canceled. (-128)\n") == "User canceled.")
        #expect(Rosetta.errorMessage(fromOsascript: "0:90: execution error: Install failed (try again) (1)") == "Install failed (try again)")
        #expect(Rosetta.errorMessage(fromOsascript: "something else went wrong") == "something else went wrong")
        #expect(Rosetta.errorMessage(fromOsascript: "\n") == nil)
    }
}

@Suite struct LaunchSaltTests {
    let fm = FileManager.default

    func saltFile() -> URL { fm.temporaryDirectory.appending(path: "harbor-salt-\(UUID().uuidString)/Harbor/launch-salt") }

    @Test func theSaltIsRandomPerInstallAndStableAfterwards() throws {
        let file = saltFile()
        let salt = LaunchSalt(file: file).value()
        #expect(salt.count == 64)
        #expect(try String(contentsOf: file, encoding: .utf8) == salt)
        #expect(LaunchSalt(file: file).value() == salt)                // read back, not made again
        #expect(LaunchSalt(file: saltFile()).value() != salt)          // another install has another
        #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        // A damaged file is replaced rather than used as a weak salt.
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(LaunchSalt(file: file).value().count == 64)
        #expect(LaunchSalt.defaultFile.path.hasSuffix("/Library/Application Support/Harbor/launch-salt"))
    }

    @Test func storeGameIDsDependOnTheSalt() throws {
        let (b, _, _) = try LibraryScanTests().mixedBottle()
        let mine = LaunchSalt(file: saltFile()), theirs = LaunchSalt(file: saltFile())
        let ids = { (salt: LaunchSalt) in
            Dictionary(uniqueKeysWithValues: Library.scan([b], salt: salt).filter(\.managedByStore).map { ($0.program.name, $0.program.id) })
        }
        let first = ids(mine)
        #expect(first.count == 2 && Set(first.values).count == 2)
        #expect(ids(mine) == first)                                     // stable on this Mac: shortcuts keep working
        let other = ids(theirs)
        #expect(other["Portal 2"] != first["Portal 2"] && other["Alan Wake"] != first["Alan Wake"])
        // Knowing the bottle and the app ID isn't enough any more.
        #expect(SteamLibrary.stableID(appID: 620, bottle: b, salt: "") != first["Portal 2"])
        #expect(SteamLibrary.stableID(appID: 620, bottle: b, salt: mine.value()) == first["Portal 2"])
        // Still a well-formed name-based UUID, which `harbor://launch/<id>` parses.
        #expect(first.values.allSatisfy { Array($0.uuidString)[14] == "5" })
    }
}
