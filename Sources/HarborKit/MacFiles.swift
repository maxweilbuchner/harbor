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

    /// Brings a Mac file into the bottle so Wine can run it, and returns the copy (a clone on APFS: no extra disk).
    /// Files already inside the bottle are returned as they are. Parts of a multi-file installer come along: files
    /// beside it whose names start with its name (GOG's `setup_game.exe` + `setup_game-1.bin`).
    public func importForRunning(_ file: URL) throws -> URL {
        let fm = FileManager.default
        let source = file.standardizedFileURL.resolvingSymlinksInPath()
        if source.path.hasPrefix(driveC.standardizedFileURL.resolvingSymlinksInPath().path + "/") { return file }
        if !isRunning() { clearImports() }     // copies from earlier runs, now that nothing can be using them
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

    /// Removes everything `importForRunning` brought in. Call when the bottle has stopped.
    public func clearImports() {
        try? FileManager.default.removeItem(at: importsDirectory)
    }
}
