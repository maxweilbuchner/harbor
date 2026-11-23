import Foundation

/// Adds a dropped Windows file to the library: one bottle per program, named after the product.
///
/// - Installers (MSI, Inno, NSIS, InstallShield, WiX, or a setup-named .exe) run with their normal UI; the
///   programs they leave in the Start Menu become library items. If an installer creates no shortcuts, new
///   executables under Program Files are offered instead.
/// - Anything else is treated as a program that runs as-is: it goes into the bottle (with its folder, unless
///   that's a shared folder like Downloads) and becomes the library item.
public struct AddProgram: Sendable {
    public enum Step: Sendable, Equatable {
        case analyzing
        case preparingWindows(name: String)
        /// The installer's own window is open; the user finishes it.
        case runningInstaller(name: String)
        case findingPrograms
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAWindowsProgram
        case installerFoundNothing(name: String)

        public var description: String {
            switch self {
            case .notAWindowsProgram: "This doesn’t look like a Windows program or installer."
            case .installerFoundNothing(let n): "The \(n) installer finished, but Harbor couldn’t find what it installed."
            }
        }
    }

    public let store: BottleStore
    public let launcher: WineLauncher
    /// New bottles clone this pre-built prefix when it's ready (under a second instead of about 25 s).
    public var template: PrefixTemplate?

    public init(store: BottleStore, launcher: WineLauncher, template: PrefixTemplate? = nil) {
        self.store = store
        self.launcher = launcher
        self.template = template ?? PrefixTemplate(launcher: launcher)
    }

    /// Returns the bottle and the programs added to it.
    public func add(_ file: URL, progress: @Sendable (Step) -> Void = { _ in }) async throws -> (Bottle, [Program]) {
        progress(.analyzing)
        guard ["exe", "msi"].contains(file.pathExtension.lowercased()),
              let analysis = try? ProgramAnalysis.analyze(file) else { throw Failure.notAWindowsProgram }
        let name = Self.bottleName(for: analysis, file: file)

        progress(.preparingWindows(name: name))
        let (launcher, template) = (self.launcher, self.template)
        let bottle = try await store.create(name: name) { try await launcher.initialize($0, template: template) }
        let programs: [Program]
        do {
            if analysis.installer != nil {
                programs = try await install(file, name: name, into: bottle, progress: progress)
            } else {
                programs = [try place(file, analysis: analysis, name: name, in: bottle)]
            }
        } catch Failure.installerFoundNothing(let n) {
            // Something may well be installed; keep the bottle rather than delete it (Advanced can reach it).
            throw Failure.installerFoundNothing(name: n)
        } catch {
            try? launcher.shutdown(bottle)
            try? FileManager.default.removeItem(at: bottle.root)
            throw error
        }
        // A finished install is never deleted because saving the library entry failed.
        try bottle.savePrograms(programs)
        return (bottle, programs)
    }

    private func install(_ file: URL, name: String, into bottle: Bottle,
                         progress: @Sendable (Step) -> Void) async throws -> [Program] {
        let before = Set(bottle.startMenuPrograms().map { $0.windowsPath.lowercased() })
        let exesBefore = programFilesExecutables(in: bottle)
        progress(.runningInstaller(name: name))
        // The exit handler is installed before the installer starts, so its end can't be missed.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            do { try launcher.open(file, in: bottle, withFolder: true) { _ in done.resume() } } catch { done.resume(throwing: error) }
        }
        // Bootstrapper installers start the real setup and exit at once; wait until every Windows process in
        // the bottle has finished (wineserver exits then), or the scan below would run mid-install. That
        // includes a program the installer starts at its end; the sheet asks the user to quit it.
        try await launcher.waitForShutdown(bottle)
        bottle.clearImports()          // the installer's copy inside the bottle
        progress(.findingPrograms)
        let new = bottle.startMenuPrograms().filter { !before.contains($0.windowsPath.lowercased()) }
        if !new.isEmpty { return new }
        // No shortcuts: offer the main executables the installer added.
        let added = programFilesExecutables(in: bottle).subtracting(exesBefore)
        let candidates = added.compactMap { exe -> Program? in
            guard let analysis = try? ProgramAnalysis.analyze(exe), analysis.isGUI, analysis.installer == nil,
                  !Bottle.isAuxiliary(name: exe.lastPathComponent, target: exe.lastPathComponent),
                  let windows = bottle.windowsPath(for: exe) else { return nil }
            let program = Program(name: analysis.displayName(fallback: exe), windowsPath: windows,
                                  isGame: Bottle.looksLikeGame(exe))
            bottle.saveIcon(for: program, from: exe)
            return program
        }
        guard !candidates.isEmpty else { throw Failure.installerFoundNothing(name: name) }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Puts a program that needs no installer into `C:\Program Files\<name>\`. Its folder comes along (programs
    /// usually need the files next to them), except when the program sits directly in a shared folder such as
    /// Downloads or Desktop: then only the program is copied, so unrelated personal files never enter the
    /// bottle. Nothing is ever symlinked in, so a Windows uninstaller can't reach the Mac folder: links are
    /// followed for the program itself and dropped from its folder when they lead out of it.
    func place(_ file: URL, analysis: ProgramAnalysis, name: String, in bottle: Bottle) throws -> Program {
        let fm = FileManager.default
        let programFolderName = analysis.architecture == .x86 ? "Program Files (x86)" : "Program Files"
        let programFiles = bottle.driveC.appending(path: programFolderName)
        try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
        let folderName = Self.safeFolderName(name, fallback: file.deletingPathExtension().lastPathComponent)
        let destination = programFiles.appending(path: folderName)
        // The whole program comes along: for a game whose .exe sits in Binaries\Win64, that's the game's folder.
        let relative: [String]
        if let root = Self.programRoot(for: file) {
            // A clone on APFS: no extra disk until files change.
            try fm.copyItem(at: root.resolvingSymlinksInPath(), to: destination)
            try Self.removeLinks(leadingOutOf: destination)
            relative = Array(file.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: file.resolvingSymlinksInPath(), to: destination.appending(path: file.lastPathComponent))
            relative = [file.lastPathComponent]
        }
        let windows = (["C:", programFolderName, folderName] + relative).joined(separator: "\\")
        let program = Program(name: analysis.displayName(fallback: file), windowsPath: windows,
                              isGame: Bottle.looksLikeGame(file))
        bottle.saveIcon(for: program, from: file)
        return program
    }

    /// Deletes the symbolic links below `folder` whose target lies outside it (`copyItem` copies links as links).
    static func removeLinks(leadingOutOf folder: URL) throws {
        let fm = FileManager.default
        let inside = folder.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var outward: [URL] = []
        for case let url as URL in walker {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let path = URL(filePath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                .resolvingSymlinksInPath().path
            if path != inside && !path.hasPrefix(inside + "/") { outward.append(url) }
        }
        for link in outward { try fm.removeItem(at: link) }
    }

    /// The folder that holds the whole program `file` belongs to, or nil if it sits in a shared folder or in one
    /// that isn't recognisably the program's own (then only the file itself may be copied). Walks up from
    /// folders like `Binaries/Win64` or `bin`, which hold a game's executable while its data sits higher up
    /// (Unreal: `<Root>/<Game>/Binaries/Win64`, `<Root>/Engine`); every folder on the way must be the program's.
    static func programRoot(for file: URL) -> URL? {
        let fm = FileManager.default
        var folder = file.deletingLastPathComponent().standardizedFileURL
        guard !isSharedFolder(folder), holdsOneProgram(folder) else { return nil }
        let binaryFolders: Set<String> = ["bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "x86_64",
                                          "amd64", "release", "shipping", "retail"]
        while true {
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path, !isSharedFolder(parent) else { break }
            let isBinaryFolder = binaryFolders.contains(folder.lastPathComponent.lowercased())
            let besideEngine = fm.fileExists(atPath: parent.appending(path: "Engine").path)   // Unreal's root
            guard isBinaryFolder || besideEngine, holdsOneProgram(parent, apartFrom: folder) else { break }
            folder = parent
        }
        return folder
    }

    /// Whether `folder` with everything below it is one program's, so that it may be copied whole. DLLs beside
    /// the program or an Unreal `Engine` folder show it. Without them, the subfolders (other than `own`, the
    /// one the program was found in) must hold nothing that looks like someone else's: no other programs (a
    /// folder of games), no personal documents, no dot-files (a synced or working folder), and few enough
    /// files to tell. The folder's own files are `isSharedFolder`'s to judge.
    static func holdsOneProgram(_ folder: URL, apartFrom own: URL? = nil) -> Bool {
        let fm = FileManager.default
        if containsLibraries(folder) || fm.fileExists(atPath: folder.appending(path: "Engine").path) { return true }
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        var seen = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }      // Finder's, on any disk
            if name.hasPrefix(".") { return false }
            if walker.level == 1 {
                if name == own?.lastPathComponent { walker.skipDescendants() }
                continue
            }
            seen += 1
            let type = url.pathExtension.lowercased()
            if seen > unprovenFolderLimit || ["exe", "msi"].contains(type) || personalDocumentExtensions.contains(type) {
                return false
            }
        }
        return true
    }

    /// Folders that hold unrelated files, from which only the program itself may be copied: the home folder, its
    /// standard folders, iCloud Drive and other cloud storage, any Downloads/Desktop/Documents folder,
    /// Applications, disk roots, and any folder containing personal documents (a program's own folder doesn't
    /// hold PDFs and photos).
    static func isSharedFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        let cloudStorage = home + "/Library/CloudStorage"                  // Dropbox, Google Drive, OneDrive, …
        var shared: Set<String> = ["/", "/Applications", "/Users", "/Volumes", home, iCloud, cloudStorage]
        for name in ["Downloads", "Desktop", "Documents", "Applications", "Library", "Movies", "Music", "Pictures", "Public"] {
            shared.insert(home + "/" + name)
        }
        if shared.contains(path) { return true }
        let name = folder.lastPathComponent.lowercased()
        if ["downloads", "desktop", "documents"].contains(name) { return true }
        if path.hasPrefix(iCloud + "/") && path.dropFirst(iCloud.count + 1).split(separator: "/").count <= 1 { return true }
        // A provider's root and the drive inside it (`GoogleDrive-<account>/My Drive`).
        if path.hasPrefix(cloudStorage + "/") && path.dropFirst(cloudStorage.count + 1).split(separator: "/").count <= 2 { return true }
        let parts = path.split(separator: "/")
        if parts.count == 2 && parts[0] == "Volumes" { return true }             // a disk's root, e.g. /Volumes/USB
        // Games ship pictures, videos and manuals too; a folder with DLLs next to the program is the program's.
        return containsPersonalDocuments(folder) && !containsLibraries(folder)
    }

    /// More files than this below a folder without DLLs: too many to check that they're all the program's.
    static let unprovenFolderLimit = 5000

    static func containsLibraries(_ folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.prefix(2000).contains { $0.pathExtension.lowercased() == "dll" }
    }

    static let personalDocumentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "rtf",
        "jpg", "jpeg", "heic", "png", "gif", "tiff", "raw", "mov", "mp4", "m4v", "mp3", "m4a", "wav",
        "zip", "dmg", "pkg", "eml", "csv", "epub"]

    /// True if the folder itself (not its subfolders) holds personal documents.
    static func containsPersonalDocuments(_ folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.prefix(500).contains { personalDocumentExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func programFilesExecutables(in bottle: Bottle) -> Set<URL> {
        var found = Set<URL>()
        for name in ["Program Files", "Program Files (x86)"] {
            let root = bottle.driveC.appending(path: name)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                if walker.level > 4 { walker.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe" { found.insert(url.standardizedFileURL) }
            }
        }
        return found
    }

    /// The name a dropped file's bottle will get, or nil if it isn't a Windows program. Lets the app notice
    /// that something is already installed before adding it again.
    public static func suggestedName(for file: URL) -> String? {
        guard ["exe", "msi"].contains(file.pathExtension.lowercased()),
              let analysis = try? ProgramAnalysis.analyze(file) else { return nil }
        return bottleName(for: analysis, file: file)
    }

    /// "Thing Setup 2.1" → "Thing": product name without installer words and version numbers.
    static func bottleName(for analysis: ProgramAnalysis, file: URL) -> String {
        var name = analysis.displayName(fallback: file)
        for word in ["setup", "installer", "install", "installation", "x64", "x86", "64-bit", "32-bit"] {
            name = name.replacingOccurrences(of: "\\b\(word)\\b", with: "", options: [.regularExpression, .caseInsensitive])
        }
        name = name.replacingOccurrences(of: "\\bv?\\d+(\\.\\d+)+\\b", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? file.deletingPathExtension().lastPathComponent : name
    }

    /// A name Windows accepts for a folder. Names with nothing usable in them ("..") give `fallback`, cleaned
    /// the same way.
    static func safeFolderName(_ name: String, fallback: String = "") -> String {
        for candidate in [name, fallback] {
            let cleaned = candidate.map { #"<>:"/\|?*"#.contains($0) ? "-" : $0 }
            let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
            if !trimmed.isEmpty { return trimmed }
        }
        return "Program"
    }
}

extension Bottle {
    /// Windows path (`C:\…`) for a file inside this bottle's drive C, or nil if it's elsewhere.
    public func windowsPath(for file: URL) -> String? {
        let root = driveC.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return "C:" + path.dropFirst(root.count).replacingOccurrences(of: "/", with: "\\")
    }
}
