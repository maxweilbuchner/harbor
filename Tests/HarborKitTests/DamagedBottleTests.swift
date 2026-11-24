import Foundation
import Testing
@testable import HarborKit

/// A bottle whose settings or list of programs can't be read: nothing of it is thrown away (#62).
@Suite struct DamagedBottleTests {
    let fm = FileManager.default

    /// With a bottle that couldn't be read, the shortcuts of programs missing from the library stay.
    @Test func shortcutsOfProgramsThatCouldNotBeLoadedAreKept() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let shortcuts = AppShortcuts(directory: dir)
        var a = Program(name: "Alpha", windowsPath: #"C:\a.exe"#)
        let b = Program(name: "Beta", windowsPath: #"C:\b.exe"#), c = Program(name: "Gamma", windowsPath: #"C:\c.exe"#)
        shortcuts.sync([a, b]) { _ in nil }
        // Beta's bottle can't be read any more. The readable programs are still kept in step: a rename, a new one.
        a.name = "Alpha Two"
        shortcuts.sync([a, c], keepingOthers: true) { _ in nil }
        #expect(Set(shortcuts.existing().values.map(\.lastPathComponent)) == ["Alpha Two.app", "Beta.app", "Gamma.app"])
        #expect(shortcuts.existing()[b.id]?.lastPathComponent == "Beta.app")
        // Everything readable again, and Beta really gone: now its shortcut is a leftover.
        shortcuts.sync([a, c]) { _ in nil }
        #expect(Set(shortcuts.existing().values.map(\.lastPathComponent)) == ["Alpha Two.app", "Gamma.app"])
    }

    @Test func aScheduledSyncKeepsThemToo() async throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let shortcuts = AppShortcuts(directory: dir)
        let a = Program(name: "Alpha", windowsPath: #"C:\a.exe"#), b = Program(name: "Beta", windowsPath: #"C:\b.exe"#)
        shortcuts.sync([a, b]) { _ in nil }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            shortcuts.scheduleSync([a], keepingOthers: true, icon: { _ in nil }, done: { finished.resume() })
        }
        #expect(Set(shortcuts.existing().keys) == [a.id, b.id])
    }

    func bottle() throws -> Bottle {
        try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-damaged-\(UUID().uuidString)")).create(name: "Thing")
    }

    /// A list with an entry that can't be read isn't rewritten from the entries that can.
    @Test func aListOfProgramsWithUnreadableEntriesIsNotRewritten() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        #expect(!b.hasUnreadablePrograms)                       // no list yet
        let good = Program(name: "Good", windowsPath: #"C:\g.exe"#)
        try b.savePrograms([good])
        #expect(!b.hasUnreadablePrograms)
        try b.changePrograms { $0[0].isGame = true }
        #expect(b.programs().map(\.isGame) == [true])

        var text = try String(contentsOf: b.programsFile, encoding: .utf8)
        text = text.replacingOccurrences(of: "[", with: #"[{"id":"not-a-uuid","name":"Lost"},"#)
        try text.write(to: b.programsFile, atomically: true, encoding: .utf8)
        #expect(b.hasUnreadablePrograms && !b.programsFileIsDamaged)
        #expect(b.programs().map(\.name) == ["Good"])
        #expect(throws: UnreadableProgramsError.self) { try b.changePrograms { $0.removeAll() } }
        #expect(try String(contentsOf: b.programsFile, encoding: .utf8) == text)

        try Data("garbage".utf8).write(to: b.programsFile)
        #expect(b.hasUnreadablePrograms && b.programsFileIsDamaged)
        #expect(throws: UnreadableProgramsError.self) { try b.changePrograms { $0.append(good) } }
        #expect(try Data(contentsOf: b.programsFile) == Data("garbage".utf8))
    }

    /// What the app's status line is made from: the folder of a bottle whose settings can't be read.
    @Test func aBottleWithUnreadableSettingsIsReportedNotDropped() throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-damaged-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: store.directory) }
        let broken = try store.create(name: "Broken")
        _ = try store.create(name: "Fine")
        try Data("{".utf8).write(to: broken.settingsFile)
        let found = store.scan()
        #expect(found.bottles.map(\.settings.name) == ["Fine"])
        #expect(found.damaged.map(\.folder.lastPathComponent) == ["broken"])
    }
}
