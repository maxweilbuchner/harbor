import Foundation
import Testing
@testable import HarborKit

/// Bringing a file into a bottle tidies up what earlier installs left there, but not what another operation
/// brought in a moment ago (#66).
@Suite struct ImportRaceTests {
    let fm = FileManager.default

    @Test func anImportLeavesFreshImportsAlone() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let bottle = try BottleStore(directory: base.appending(path: "bottles")).create(name: "B")
        try fm.createDirectory(at: bottle.driveC, withIntermediateDirectories: true)
        for name in ["VC_redist.x64.exe", "setup.exe", "later.exe"] {
            try Data("MZ".utf8).write(to: base.appending(path: name))
        }
        // A component's installer was brought in and isn't started yet; an add in the same bottle imports its own.
        let first = try bottle.importForRunning(base.appending(path: "VC_redist.x64.exe"))
        let second = try bottle.importForRunning(base.appending(path: "setup.exe"))
        #expect(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path))
        // The same imports, as they look an hour later: left behind by something that never cleared them.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: bottle.importsDirectory.path)
        let later = try bottle.importForRunning(base.appending(path: "later.exe"))
        #expect(!fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: second.path))
        #expect(fm.fileExists(atPath: later.path))
    }
}
