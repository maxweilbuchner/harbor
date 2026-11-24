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
    /// beside it that are named as its parts (GOG's `setup_game.exe` + `setup_game-1.bin`; `isInstallerPart`).
    /// `withFolder`: for an installer, bring its whole folder (data files under other names, subfolders) when the
    /// folder is the installer's own; from a shared folder such as Downloads only the named parts come, as above.
    /// A folder on a disk that can't be written to (a disc, a mounted disk image) isn't copied: it becomes drive
    /// D: until `clearImports`, and the installer is returned at its place on that drive (`runsFromItsDisk`).
    /// `mediaRoot`: the folder the user dropped, when the installer was found inside it (`AddProgram.entry`).
    /// That folder comes along instead of the installer's own, and the installer is returned at its place below
    /// it, so `Setup\setup.exe` finds `..\Data`.
    public func importForRunning(_ file: URL, withFolder: Bool = false, mediaRoot: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let source = file.standardizedFileURL.resolvingSymlinksInPath()
        if source.path.hasPrefix(driveC.standardizedFileURL.resolvingSymlinksInPath().path + "/") { return file }
        if !isRunning() { clearImports() }     // copies from earlier runs, now that nothing can be using them
        if withFolder, let media = droppedFolder(mediaRoot, holding: source) ?? installerFolder(of: source) {
            let readOnly = (try? media.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
            let asDrive = Self.runsFromItsDisk(media, onBottlesDisk: isOnBottlesDisk(media), readOnly: readOnly)
            if let local = try bringFolder(media, of: source, asDrive: asDrive) { return local }
        }
        let folder = importsDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        let stem = source.deletingPathExtension().lastPathComponent
        let siblings = (try? fm.contentsOfDirectory(at: source.deletingLastPathComponent(),
                                                    includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for sibling in siblings.prefix(5000) where sibling.lastPathComponent != source.lastPathComponent
            && Self.isInstallerPart(sibling.lastPathComponent, of: stem)
            && (try? sibling.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try fm.copyItem(at: sibling, to: folder.appending(path: sibling.lastPathComponent))
        }
        return copy
    }

    /// Whether the file `name` is a part of the installer named `stem`: the installer's name, then a separator
    /// or a number (`setup-1.bin`, `setup.cab`, `setup1.cab`, `setup 2.bin`), whatever the case, and not a
    /// document's type. "Setup notes.docx" beside `Setup.exe` in Downloads is someone's notes.
    static func isInstallerPart(_ name: String, of stem: String) -> Bool {
        guard let start = name.range(of: stem, options: [.anchored, .caseInsensitive]) else { return false }
        let rest = name[start.upperBound...]
        guard let next = rest.first, "-_.".contains(next) || next.isNumber
                || (next == " " && rest.dropFirst().first?.isNumber == true) else { return false }
        return !AddProgram.personalDocumentExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether an installer's folder is linked as drive D: instead of being copied. On the bottles' own disk a
    /// copy is a free clone. On another disk the link is for what can't be written to (a disc, a mounted disk
    /// image): through it the installer, and whatever it starts, reaches the folder itself. A folder on a
    /// writable disk is copied, so nothing beside the installer can be changed. Only one too large to copy
    /// (`files`, `bytes`) is linked all the same, rather than have the install fail or take the disk's time
    /// and space twice.
    static func runsFromItsDisk(_ media: URL, onBottlesDisk: Bool, readOnly: Bool,
                                files: Int = AddProgram.unprovenFolderLimit, bytes: Int = 2 << 30) -> Bool {
        if onBottlesDisk { return false }
        if readOnly { return true }
        guard let walker = FileManager.default.enumerator(at: media, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        var seen = 0, size = 0
        for case let url as URL in walker {
            seen += 1
            size += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if seen > files || size > bytes { return true }
        }
        return false
    }

    /// Makes the installer's folder `media` available in the bottle and returns the installer `source` there:
    /// as a clone in the import area, or (`asDrive`) linked as drive D: without copying anything. The link is
    /// the one way a Windows program reaches a Mac folder without the bottle's Mac-files setting; it exists for
    /// the install only. Nil if drive D: is taken (another install is running in this bottle).
    func bringFolder(_ media: URL, of source: URL, asDrive: Bool) throws -> URL? {
        let fm = FileManager.default
        // Where the installer sits below `media`: its name, or `Setup/setup.exe` in a dropped folder.
        let place = String(source.path.dropFirst(media.path.count + 1))
        if asDrive {
            guard (try? fm.attributesOfItem(atPath: mediaDrive.path)) == nil else { return nil }
            try fm.createSymbolicLink(atPath: mediaDrive.path, withDestinationPath: media.path)
            return mediaDrive.appending(path: place)
        }
        let folder = importsDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: media, to: folder)
        try AddProgram.removeLinks(leadingOutOf: folder)      // nothing in the bottle points back at the Mac
        return folder.appending(path: place)
    }

    /// The folder the user dropped, if `file` lies below it. Their word settles what `installerFolder` has to
    /// guess from dot-files; shared places stay out all the same (`AddProgram.entry` refuses them first).
    private func droppedFolder(_ root: URL?, holding file: URL) -> URL? {
        guard let root = root?.standardizedFileURL.resolvingSymlinksInPath(), file.path.hasPrefix(root.path + "/"),
              Self.isInstallDisc(root) || !AddProgram.isSharedPlace(root) else { return nil }
        return root
    }

    /// The folder `file` sits in, if it may be given to the installer whole: not in a shared place and not a
    /// synced or working folder (dot-files). The top of an install disc counts although it is a disk's root.
    /// What the folder holds doesn't matter as it does for a program copied in for good: install media ships
    /// manuals, pictures and videos beside the installer, and it is in the bottle only for the install.
    private func installerFolder(of file: URL) -> URL? {
        let folder = file.deletingLastPathComponent()
        if Self.isInstallDisc(folder) { return folder }
        guard !AddProgram.isSharedPlace(folder) else { return nil }
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
