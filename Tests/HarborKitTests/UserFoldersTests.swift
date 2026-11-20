import Foundation
import Testing
@testable import HarborKit

@Suite struct UserFoldersTests {
    /// Wine also put a "My Mac Desktop" link inside the Windows Desktop; it goes like the others (#4).
    @Test func replacesTheLinkToTheMacDesktopInsideTheWindowsDesktop() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "harbor-desktop-\(UUID().uuidString)")
        let mac = base.appending(path: "mac/Desktop")
        try fm.createDirectory(at: mac, withIntermediateDirectories: true)
        try "keep".write(to: mac.appending(path: "Notes.txt"), atomically: true, encoding: .utf8)
        let b = try BottleStore(directory: base.appending(path: "bottles")).create(name: "D")
        let desktop = b.driveC.appending(path: "users/crossover/Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: desktop.appending(path: "My Mac Desktop"), withDestinationURL: mac)
        try "lnk".write(to: desktop.appending(path: "Game.lnk"), atomically: true, encoding: .utf8)

        #expect(b.unshareUserFolders().map(\.lastPathComponent) == ["My Mac Desktop"])
        #expect((try? fm.destinationOfSymbolicLink(atPath: desktop.appending(path: "My Mac Desktop").path)) == nil)
        #expect((try? fm.contentsOfDirectory(atPath: desktop.appending(path: "My Mac Desktop").path)) == [])
        #expect(fm.fileExists(atPath: desktop.appending(path: "Game.lnk").path))
        #expect((try? String(contentsOf: mac.appending(path: "Notes.txt"), encoding: .utf8)) == "keep")
    }
}
