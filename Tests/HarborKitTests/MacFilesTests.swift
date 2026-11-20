import Foundation
import Testing
@testable import HarborKit

@Suite struct MacFilesTests {
    let fm = FileManager.default

    func bottle(_ name: String = "M") throws -> Bottle {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-mac-\(UUID().uuidString)")).create(name: name)
        try fm.createDirectory(at: b.prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: b.driveC, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: b.prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: b.prefix.appending(path: "dosdevices/z:").path, withDestinationPath: "/")   // as Wine makes it
        return b
    }

    /// Drive Z: (the whole Mac) is gone unless the bottle allows it; C: is never touched.
    @Test func theMacDriveFollowsTheBottlesSetting() throws {
        var b = try bottle()
        let z = b.prefix.appending(path: "dosdevices/z:").path
        #expect(!b.settings.macFilesAccess)
        b.applyMacFilesAccess()
        #expect((try? fm.destinationOfSymbolicLink(atPath: z)) == nil)
        #expect((try? fm.destinationOfSymbolicLink(atPath: b.prefix.appending(path: "dosdevices/c:").path)) == "../drive_c")
        #expect(fm.fileExists(atPath: "/usr"))                                         // the link went, not the Mac
        b.applyMacFilesAccess()                                                        // again: nothing to do

        b.settings.macFilesAccess = true
        try b.save()
        b.applyMacFilesAccess()
        #expect((try? fm.destinationOfSymbolicLink(atPath: z)) == "/")
        // The setting survives saving and loading; older bottle.json files without it mean "off".
        #expect(try Bottle.load(from: b.root).settings.macFilesAccess)
        let old = try JSONDecoder().decode(BottleSettings.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!old.macFilesAccess)
    }

    @Test func aBottleWithoutAPrefixIsLeftAlone() throws {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-mac-\(UUID().uuidString)")).create(name: "N")
        b.applyMacFilesAccess()
        #expect(!fm.fileExists(atPath: b.prefix.appending(path: "dosdevices").path))
    }

    /// An installer on the Mac is run from a copy inside the bottle, with the parts that belong to it and nothing else.
    @Test func filesToRunAreBroughtIntoTheBottle() throws {
        let b = try bottle()
        let downloads = b.root.deletingLastPathComponent().appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in ["setup_game.exe", "setup_game-1.bin", "setup_game-2.bin", "Tax Return.pdf", "other.exe"] {
            try Data(name.utf8).write(to: downloads.appending(path: name))
        }
        try fm.createDirectory(at: downloads.appending(path: "setup_game_extras"), withIntermediateDirectories: true)

        let copy = try b.importForRunning(downloads.appending(path: "setup_game.exe"))
        #expect(copy.path.hasPrefix(b.driveC.path + "/"))
        #expect(b.windowsPath(for: copy)?.hasPrefix(#"C:\windows\temp\harbor-import\"#) == true)
        #expect(try fm.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path).sorted()
                == ["setup_game-1.bin", "setup_game-2.bin", "setup_game.exe"])
        #expect(fm.fileExists(atPath: downloads.appending(path: "setup_game.exe").path))   // copied, not moved

        // A file already in the bottle is used where it is.
        #expect(try b.importForRunning(copy) == copy)
        // msiexec gets the Windows path of the copy.
        let msi = b.driveC.appending(path: "windows/temp/x.msi")
        #expect(WineLauncher.arguments(toOpen: msi, windowsPath: b.windowsPath(for: msi)) == ["msiexec", "/i", #"C:\windows\temp\x.msi"#])

        b.clearImports()
        #expect(!fm.fileExists(atPath: copy.path))
    }
}
