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
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
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
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        b.applyMacFilesAccess()
        #expect(!fm.fileExists(atPath: b.prefix.appending(path: "dosdevices").path))
    }

    /// An installer on the Mac is run from a copy inside the bottle, with the parts that belong to it and nothing else.
    @Test func filesToRunAreBroughtIntoTheBottle() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
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

    /// An installer in a folder of its own gets that whole folder: data files under any name and subfolders.
    @Test func anInstallersOwnFolderComesAlong() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let base = b.root.deletingLastPathComponent()
        let media = base.appending(path: "Thing Disc")
        try fm.createDirectory(at: media.appending(path: "Redist"), withIntermediateDirectories: true)
        for name in ["setup.exe", "data-01.bin", "data-02.bin", "Redist/vc.exe"] {
            try Data(name.utf8).write(to: media.appending(path: name))
        }
        try Data("private".utf8).write(to: base.appending(path: "private.txt"))
        try fm.createSymbolicLink(atPath: media.appending(path: "out").path, withDestinationPath: "../private.txt")
        try fm.createSymbolicLink(atPath: media.appending(path: "in").path, withDestinationPath: "data-01.bin")

        let copy = try b.importForRunning(media.appending(path: "setup.exe"), withFolder: true)
        #expect(b.windowsPath(for: copy)?.hasPrefix(#"C:\windows\temp\harbor-import\"#) == true)
        let folder = copy.deletingLastPathComponent()
        #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted()
                == ["Redist", "data-01.bin", "data-02.bin", "in", "setup.exe"])      // the link out of the folder is gone
        #expect(fm.fileExists(atPath: folder.appending(path: "Redist/vc.exe").path))
        #expect(fm.fileExists(atPath: media.appending(path: "data-01.bin").path))    // copied, not moved

        // Programs that aren't installers, and other callers, bring only the named parts.
        let plain = try b.importForRunning(media.appending(path: "setup.exe"))
        #expect(try fm.contentsOfDirectory(atPath: plain.deletingLastPathComponent().path) == ["setup.exe"])

        // A shared folder never comes along, nor does a synced or working folder (dot-files).
        let downloads = base.appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in ["setup_game.exe", "setup_game-1.bin", "notes.bin"] { try Data().write(to: downloads.appending(path: name)) }
        let shared = try b.importForRunning(downloads.appending(path: "setup_game.exe"), withFolder: true)
        #expect(try fm.contentsOfDirectory(atPath: shared.deletingLastPathComponent().path).sorted()
                == ["setup_game-1.bin", "setup_game.exe"])
        // A manual or pictures beside the installer are part of the install media (#46).
        try Data().write(to: media.appending(path: "Manual.pdf"))
        let withManual = try b.importForRunning(media.appending(path: "setup.exe"), withFolder: true)
        #expect(try fm.contentsOfDirectory(atPath: withManual.deletingLastPathComponent().path).sorted()
                == ["Manual.pdf", "Redist", "data-01.bin", "data-02.bin", "in", "setup.exe"])
        try Data().write(to: media.appending(path: ".git"))
        let working = try b.importForRunning(media.appending(path: "setup.exe"), withFolder: true)
        #expect(try fm.contentsOfDirectory(atPath: working.deletingLastPathComponent().path) == ["setup.exe"])
    }

    // MARK: #61

    /// Beside an installer in a shared place, only what is named as one of its parts comes along: the name,
    /// then a separator or a number. A document that merely starts the same way stays on the Mac.
    @Test func onlyNamedPartsComeAlongFromASharedPlace() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let base = b.root.deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let parts = ["Setup-1.bin", "setup-2.bin", "Setup.cab", "Setup1.cab", "Setup 2.bin", "Setup_data.bin"]
        for name in parts + ["Setup.exe", "Setup notes.docx", "Setupper.exe", "Setup.pdf", "Setup-photo.jpg", "Settings.ini"] {
            try Data().write(to: downloads.appending(path: name))
        }
        let copy = try b.importForRunning(downloads.appending(path: "Setup.exe"), withFolder: true)
        #expect(try fm.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path).sorted() == (parts + ["Setup.exe"]).sorted())
        // `a.exe` doesn't bring every file that starts with "a".
        for name in ["a.exe", "a1.bin", "apple.txt", "archive.bin"] { try Data().write(to: downloads.appending(path: name)) }
        let short = try b.importForRunning(downloads.appending(path: "a.exe"))
        #expect(try fm.contentsOfDirectory(atPath: short.deletingLastPathComponent().path).sorted() == ["a.exe", "a1.bin"])
    }

    /// A folder on another disk is drive D: only where nothing can be written to it; from a writable disk it is
    /// copied like one on the bottles' disk, unless it is too much to copy.
    @Test func onlyAReadOnlyDiskIsLinkedAsDriveD() throws {
        let media = fm.temporaryDirectory.appending(path: "harbor-mac-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: media) }
        try fm.createDirectory(at: media.appending(path: "Data"), withIntermediateDirectories: true)
        for name in ["setup.exe", "Data/a.bin", "Data/b.bin"] { try Data(count: 1000).write(to: media.appending(path: name)) }
        #expect(!Bottle.runsFromItsDisk(media, onBottlesDisk: true, readOnly: true))
        #expect(Bottle.runsFromItsDisk(media, onBottlesDisk: false, readOnly: true))
        #expect(!Bottle.runsFromItsDisk(media, onBottlesDisk: false, readOnly: false))
        // Too many files or too many bytes for a copy: the link, as before.
        #expect(Bottle.runsFromItsDisk(media, onBottlesDisk: false, readOnly: false, files: 2))
        #expect(Bottle.runsFromItsDisk(media, onBottlesDisk: false, readOnly: false, bytes: 2500))
        #expect(!Bottle.runsFromItsDisk(media, onBottlesDisk: false, readOnly: false, files: 4, bytes: 3000))
    }

    /// An installer found inside a folder the user dropped gets that folder, at the same layout (#60).
    @Test func aDroppedFolderComesAlongAroundAnInstallerInItsSubfolder() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let base = b.root.deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        let disc = base.appending(path: "Thing Disc"), setup = disc.appending(path: "Setup/setup.exe")
        for name in ["Setup/setup.exe", "Data/data1.cab", ".disc-id"] {
            try fm.createDirectory(at: disc.appending(path: name).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: disc.appending(path: name))
        }
        let copy = try b.importForRunning(setup, withFolder: true, mediaRoot: disc)
        #expect(b.windowsPath(for: copy)?.hasSuffix(#"\Setup\setup.exe"#) == true)
        #expect(fm.fileExists(atPath: copy.deletingLastPathComponent().appending(path: "../Data/data1.cab").path))
        // On another disk the same folder is drive D:.
        b.clearImports()
        let linked = try #require(try b.bringFolder(disc, of: setup, asDrive: true))
        #expect(b.windowsPath(for: linked) == #"D:\Setup\setup.exe"#)
        b.clearImports()
        // A folder the installer isn't in, or a shared place, is nobody's word: the installer's own folder.
        let downloads = base.appending(path: "Downloads")
        try fm.createDirectory(at: downloads.appending(path: "Sub"), withIntermediateDirectories: true)
        for name in ["Sub/setup.exe", "Sub/part.bin", "Tax Return.pdf"] { try Data().write(to: downloads.appending(path: name)) }
        for root in [downloads, base.appending(path: "Elsewhere")] {
            let own = try b.importForRunning(downloads.appending(path: "Sub/setup.exe"), withFolder: true, mediaRoot: root)
            #expect(try fm.contentsOfDirectory(atPath: own.deletingLastPathComponent().path).sorted() == ["part.bin", "setup.exe"])
            #expect(!fm.fileExists(atPath: own.deletingLastPathComponent().appending(path: "../Tax Return.pdf").path))
        }
    }

    /// An installer's folder on another disk isn't copied: it is drive D: for the install and gone afterwards.
    @Test func aFolderOnAnotherDiskBecomesDriveDForTheInstall() throws {
        let b = try bottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let media = b.root.deletingLastPathComponent().appending(path: "Thing Disc")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        for name in ["setup.exe", "setup.msi", "data-01.bin"] { try Data(name.utf8).write(to: media.appending(path: name)) }
        let drive = b.prefix.appending(path: "dosdevices/d:")

        let installer = try #require(try b.bringFolder(media, of: media.appending(path: "setup.exe"), asDrive: true))
        #expect(try fm.destinationOfSymbolicLink(atPath: drive.path) == media.path)
        #expect(installer == drive.appending(path: "setup.exe"))
        #expect(fm.fileExists(atPath: drive.appending(path: "data-01.bin").path))
        #expect(!fm.fileExists(atPath: b.importsDirectory.path))                        // nothing was copied
        #expect(b.windowsPath(for: installer) == #"D:\setup.exe"#)
        #expect(WineLauncher.arguments(toOpen: drive.appending(path: "setup.msi"),
                                       windowsPath: b.windowsPath(for: drive.appending(path: "setup.msi")))
                == ["msiexec", "/i", #"D:\setup.msi"#])
        // The drive is taken while that install runs.
        #expect(try b.bringFolder(media, of: media.appending(path: "setup.exe"), asDrive: true) == nil)

        b.clearImports()
        #expect((try? fm.destinationOfSymbolicLink(atPath: drive.path)) == nil)
        #expect(fm.fileExists(atPath: media.appending(path: "data-01.bin").path))       // the link went, not the folder
        // A folder someone made at D: is not Harbor's to remove.
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        b.clearImports()
        #expect(fm.fileExists(atPath: drive.path))
        #expect(try b.bringFolder(media, of: media.appending(path: "setup.exe"), asDrive: true) == nil)

        // Only the top of a disc counts as an installer's folder among disk roots.
        #expect(!Bottle.isInstallDisc(media))
        #expect(!Bottle.isInstallDisc(URL(filePath: "/Volumes")))
    }
}
