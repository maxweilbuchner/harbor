import Foundation
import Testing
@testable import HarborKit

/// What the app does with bottles that never reached the library, each time it looks at the library (#57).
@Suite struct RecoverUnrecordedTests {
    let fm = FileManager.default

    @Test func interruptedInstallsAreAdoptedAndOnlyOldEmptyBottlesGoToTheTrash() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-recover-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let store = BottleStore(directory: base.appending(path: "bottles"), trash: base.appending(path: "trash"))
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        func bottle(_ name: String, _ files: [String]) throws -> Bottle {
            let b = try store.create(name: name)
            try fm.createDirectory(at: b.driveC.appending(path: "windows"), withIntermediateDirectories: true)
            for file in files {
                let url = b.driveC.appending(path: file)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: app, to: url)
            }
            return b
        }
        let wines = ["Program Files/Internet Explorer/iexplore.exe", "windows/notepad.exe"]
        let interrupted = try bottle("Interrupted", wines + ["Games/Thing/Thing.exe"])
        let cancelled = try bottle("Cancelled", wines)
        // Something was installed that Harbor can't name (here: only an uninstaller): not Harbor's to throw away.
        let unnamed = try bottle("Unnamed", wines + ["Games/Tool/unins000.exe"])
        let adding = try bottle("Adding", wines)
        let release = adding.claim()
        defer { release() }
        func trash() -> [String] { (try? fm.contentsOfDirectory(atPath: base.appending(path: "trash").path)) ?? [] }

        // Just made: the empty ones are left alone, the interrupted install is recorded.
        let first = AddProgram.recoverUnrecorded(in: store)
        #expect(first.adopted.map(\.settings.name) == ["Interrupted"] && first.trashed.isEmpty)
        #expect(interrupted.programs().map(\.windowsPath) == [#"C:\Games\Thing\Thing.exe"#])
        #expect(fm.fileExists(atPath: cancelled.root.path) && trash().isEmpty)

        // Minutes later: the bottle nothing was installed into goes to the Trash, and nothing else.
        let later = AddProgram.recoverUnrecorded(in: store, now: Date().addingTimeInterval(AddProgram.abandonedAfter + 60))
        #expect(later.adopted.isEmpty && later.trashed.map(\.settings.name) == ["Cancelled"])
        #expect(!fm.fileExists(atPath: cancelled.root.path))
        #expect(trash().count == 1 && trash()[0].hasPrefix("cancelled-"))
        for kept in [interrupted, unnamed, adding] { #expect(fm.fileExists(atPath: kept.root.path)) }
        #expect(unnamed.programs().isEmpty)
    }
}
