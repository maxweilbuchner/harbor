import Foundation
import Testing
@testable import HarborKit

/// `importForRunning` from a folder on another disk, with a real one (a disk image of the test's own): copied
/// when the disk can be written to, drive D: when it can't (#61, #85).
@Suite struct ImportFromDiskTests {
    let fm = FileManager.default

    /// Runs `hdiutil` and returns whether it succeeded.
    func hdiutil(_ arguments: [String]) throws -> Bool {
        let tool = Process()
        tool.executableURL = URL(filePath: "/usr/bin/hdiutil")
        tool.arguments = arguments
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.runAndWait()
        return tool.terminationStatus == 0
    }

    @Test(.timeLimit(.minutes(2))) func anInstallersFolderOnAnotherDiskIsCopiedOrLinkedByWhetherTheDiskCanBeWritten() throws {
        let b = try MacFilesTests().bottle()
        let base = b.root.deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        // The disk, mounted inside the test's folder and shown nowhere else.
        let image = base.appending(path: "disc.dmg"), disk = base.appending(path: "disk")
        let mount = ["attach", image.path, "-mountpoint", disk.path, "-nobrowse", "-noautoopen", "-noverify", "-noautofsck"]
        try fm.createDirectory(at: disk, withIntermediateDirectories: true)
        try #require(try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "Harbor Test", image.path]))
        defer { _ = try? hdiutil(["detach", disk.path, "-force"]) }
        try #require(try hdiutil(mount))
        // On it, an installer in a folder of its own.
        let setup = disk.appending(path: "Thing Disc/setup.exe")
        try fm.createDirectory(at: disk.appending(path: "Thing Disc/Data"), withIntermediateDirectories: true)
        for name in ["setup.exe", "data-01.bin", "Data/data1.cab"] { try Data(name.utf8).write(to: disk.appending(path: "Thing Disc/\(name)")) }
        let drive = b.prefix.appending(path: "dosdevices/d:")

        // Writable: a copy in the bottle, as from the bottles' own disk; the installer can't change the original.
        let copy = try b.importForRunning(setup, withFolder: true)
        #expect(b.windowsPath(for: copy)?.hasPrefix(#"C:\windows\temp\harbor-import\"#) == true)
        #expect(b.windowsPath(for: copy)?.hasSuffix(#"\setup.exe"#) == true)
        #expect(fm.fileExists(atPath: copy.deletingLastPathComponent().appending(path: "Data/data1.cab").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: drive.path)) == nil)

        // The same disk, read-only: nothing is copied, the folder is drive D: and the installer runs from there.
        try #require(try hdiutil(["detach", disk.path, "-force"]))
        try #require(try hdiutil(mount + ["-readonly"]))
        let linked = try b.importForRunning(setup, withFolder: true)
        #expect(b.windowsPath(for: linked) == #"D:\setup.exe"#)
        #expect(!fm.fileExists(atPath: b.importsDirectory.path))                       // the earlier copy went, none was made
        #expect(fm.fileExists(atPath: drive.appending(path: "Data/data1.cab").path))
        #expect(try URL(filePath: fm.destinationOfSymbolicLink(atPath: drive.path)).resolvingSymlinksInPath().path
                == disk.appending(path: "Thing Disc").resolvingSymlinksInPath().path)
        #expect(WineLauncher.arguments(toOpen: linked, windowsPath: b.windowsPath(for: linked)) == ["start", "/wait", "/unix", linked.path])
        // Without its folder (a file to run that isn't an installer) the disk isn't linked: the file is copied,
        // and the link of the import before goes like its copies would.
        let alone = try b.importForRunning(setup)
        #expect(b.windowsPath(for: alone)?.hasPrefix(#"C:\windows\temp\harbor-import\"#) == true)
        #expect(try fm.contentsOfDirectory(atPath: alone.deletingLastPathComponent().path) == ["setup.exe"])
        #expect((try? fm.destinationOfSymbolicLink(atPath: drive.path)) == nil)
        #expect(fm.fileExists(atPath: setup.path))                                     // the link went, never the disk's files
    }
}
