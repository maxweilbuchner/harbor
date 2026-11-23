import Foundation

/// What a bottle's Windows programs can reach of the Mac.
///
/// Wine maps the whole Mac file system as drive Z: in every new prefix. Harbor removes that drive unless the bottle
/// has `macFilesAccess`: installers, uninstallers, file dialogs and programs that scan drives then find only the
/// bottle's own C:. This is tidiness and protection against ordinary Windows software, not a sandbox: Wine also
/// resolves `\\?\unix\…` paths, which software written for Wine could use.
///
/// Without Z: Wine can't start a program by its Mac path, so files to run are first brought into the bottle
/// (`importForRunning`).
extension Bottle {
    var macDrive: URL { prefix.appending(path: "dosdevices/z:") }

    /// Makes drive Z: match `settings.macFilesAccess`. Call while the bottle isn't running.
    public func applyMacFilesAccess() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix.appending(path: "dosdevices").path) else { return }   // prefix not set up yet
        let target = try? fm.destinationOfSymbolicLink(atPath: macDrive.path)
        if settings.macFilesAccess {
            if target != "/" {
                try? fm.removeItem(at: macDrive)
                try? fm.createSymbolicLink(atPath: macDrive.path, withDestinationPath: "/")
            }
        } else if target != nil {
            try? fm.removeItem(at: macDrive)     // the link only, never what it points to
        }
    }

    var importsDirectory: URL { driveC.appending(path: "windows/temp/harbor-import") }
    /// Drive D:, which exists only while an installer runs from a folder on another disk.
    var mediaDrive: URL { prefix.appending(path: "dosdevices/d:") }

    /// Brings a Mac file into the bottle so Wine can run it, and returns the copy (a clone on APFS: no extra disk).
    /// Files already inside the bottle are returned as they are. Parts of a multi-file installer come along: files
    /// beside it whose names start with its name (GOG's `setup_game.exe` + `setup_game-1.bin`).
    /// `withFolder`: for an installer, bring its whole folder (data files under other names, subfolders) when the
    /// folder is the installer's own; from a shared folder such as Downloads only the named parts come, as above.
    /// A folder on another disk (a mounted disk image, an external drive) isn't copied: it becomes drive D: until
    /// `clearImports`, and the installer is returned at its place on that drive.
    public func importForRunning(_ file: URL, withFolder: Bool = false) throws -> URL {
        let fm = FileManager.default
        let source = file.standardizedFileURL.resolvingSymlinksInPath()
        if source.path.hasPrefix(driveC.standardizedFileURL.resolvingSymlinksInPath().path + "/") { return file }
        if !isRunning() { clearImports() }     // copies from earlier runs, now that nothing can be using them
        if withFolder, let media = installerFolder(of: source),
           let local = try bringFolder(media, of: source, asDrive: !isOnBottlesDisk(media)) {
            return local
        }
        let folder = importsDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        let stem = source.deletingPathExtension().lastPathComponent
        let siblings = (try? fm.contentsOfDirectory(at: source.deletingLastPathComponent(),
                                                    includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for sibling in siblings.prefix(5000) where sibling.lastPathComponent != source.lastPathComponent
            && sibling.lastPathComponent.hasPrefix(stem)
            && (try? sibling.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try fm.copyItem(at: sibling, to: folder.appending(path: sibling.lastPathComponent))
        }
        return copy
    }

    /// Makes the installer's folder `media` available in the bottle and returns the installer `source` there:
    /// as a clone in the import area, or (`asDrive`) linked as drive D: without copying anything. The link is
    /// the one way a Windows program reaches a Mac folder without the bottle's Mac-files setting; it exists for
    /// the install only. Nil if drive D: is taken (another install is running in this bottle).
    func bringFolder(_ media: URL, of source: URL, asDrive: Bool) throws -> URL? {
        let fm = FileManager.default
        if asDrive {
            guard (try? fm.attributesOfItem(atPath: mediaDrive.path)) == nil else { return nil }
            try fm.createSymbolicLink(atPath: mediaDrive.path, withDestinationPath: media.path)
            return mediaDrive.appending(path: source.lastPathComponent)
        }
        let folder = importsDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: media, to: folder)
        try AddProgram.removeLinks(leadingOutOf: folder)      // nothing in the bottle points back at the Mac
        return folder.appending(path: source.lastPathComponent)
    }

    /// The folder `file` sits in, if it may be given to the installer whole: not a shared folder and not a synced
    /// or working folder (dot-files). The top of an install disc counts although it is a disk's root.
    private func installerFolder(of file: URL) -> URL? {
        let folder = file.deletingLastPathComponent()
        if Self.isInstallDisc(folder) { return folder }
        guard !AddProgram.isSharedFolder(folder) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard !names.contains(where: { $0.hasPrefix(".") && $0 != ".DS_Store" && !$0.hasPrefix("._") }) else { return nil }
        return folder
    }

    /// Whether `folder` is the top of a disc or disk image with an installer on it rather than a disk of the
    /// user's files: a volume that can't be written to, or one with an `autorun.inf`.
    static func isInstallDisc(_ folder: URL) -> Bool {
        let parts = folder.standardizedFileURL.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "Volumes" else { return false }
        if (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.lowercased() == "autorun.inf" }
    }

    /// On the bottle's own disk a copy is a clone that takes no space.
    private func isOnBottlesDisk(_ folder: URL) -> Bool {
        var here = stat(), there = stat()
        return stat(folder.path, &here) == 0 && stat(driveC.path, &there) == 0 && here.st_dev == there.st_dev
    }

    /// Removes everything `importForRunning` brought in. Call when the bottle has stopped.
    public func clearImports() {
        try? FileManager.default.removeItem(at: importsDirectory)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: mediaDrive.path)) != nil {
            try? FileManager.default.removeItem(at: mediaDrive)      // the link only, never what it points to
        }
    }
}
