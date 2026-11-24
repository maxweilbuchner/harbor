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
        /// The installer ended without adding a single program file (cancelled, or it failed); its bottle is gone.
        case nothingInstalled(name: String)
        /// A dropped folder with several programs or none at its top.
        case unclearFolder
        /// A dropped folder that isn't a program's: Downloads, Desktop, a disk.
        case sharedFolder

        public var description: String {
            switch self {
            case .notAWindowsProgram: "This doesn’t look like a Windows program or installer."
            case .unclearFolder: "Harbor couldn’t tell which program in this folder to add. Drop the program itself."
            case .sharedFolder: "This folder holds more than one program’s files. Drop the program itself."
            case .installerFoundNothing(let n): "The \(n) installer finished, but Harbor couldn’t find what it installed."
            case .nothingInstalled(let n): "The \(n) installer didn’t install anything."
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
    /// `file` may be a folder: then the installer or program at its top is added (`entry(in:)`).
    public func add(_ file: URL, progress: @Sendable (Step) -> Void = { _ in }) async throws -> (Bottle, [Program]) {
        progress(.analyzing)
        let folder = Self.isFolder(file) ? file.standardizedFileURL.resolvingSymlinksInPath() : nil
        let file = try folder.map { try Self.entry(in: $0) } ?? file
        guard ["exe", "msi"].contains(file.pathExtension.lowercased()),
              let analysis = try? ProgramAnalysis.analyze(file) else { throw Failure.notAWindowsProgram }
        let name = Self.bottleName(for: analysis, file: folder ?? file)

        progress(.preparingWindows(name: name))
        let (launcher, template) = (self.launcher, self.template)
        // Claimed until this add ends, so `adoptUnrecorded` doesn't take a bottle in the making for one left behind.
        var release: @Sendable () -> Void = {}
        defer { release() }
        let bottle = try await store.create(name: name) {
            release = $0.claim()
            try await launcher.initialize($0, template: template)
        }
        let programs: [Program]
        if analysis.installer != nil {
            programs = try await install(file, name: name, into: bottle, root: folder, progress: progress)
        } else {
            do {
                // A dropped folder is the program's by the user's word: all of it comes along.
                programs = [try place(file, analysis: analysis, name: name, in: bottle, root: folder)]
            } catch {
                delete(bottle)
                throw error
            }
        }
        // A finished install is never deleted because saving the library entry failed (`adoptUnrecorded`
        // records it at the next start).
        try bottle.savePrograms(programs)
        return (bottle, programs)
    }

    /// Removes a new bottle that nothing was installed into yet.
    private func delete(_ bottle: Bottle) {
        try? launcher.shutdown(bottle)
        try? FileManager.default.removeItem(at: bottle.root)
    }

    /// `root`: the folder the user dropped, if the installer was found in it; the installer gets all of it.
    private func install(_ file: URL, name: String, into bottle: Bottle, root: URL? = nil,
                         progress: @Sendable (Step) -> Void) async throws -> [Program] {
        let before = Set(bottle.startMenuPrograms(includingAuxiliary: true).map { $0.windowsPath.lowercased() })
        let exesBefore = Self.installedExecutables(in: bottle)
        progress(.runningInstaller(name: name))
        do {
            // As `WineLauncher.open` does it, but the import is made here, where the dropped folder is known.
            let local = try bottle.importForRunning(file, withFolder: true, mediaRoot: root)
            let arguments = WineLauncher.arguments(toOpen: local, windowsPath: bottle.windowsPath(for: local))
            // The exit handler is installed before the installer starts, so its end can't be missed.
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                do {
                    try launcher.run(bottle, arguments: arguments, label: file.deletingPathExtension().lastPathComponent) { _ in done.resume() }
                } catch { done.resume(throwing: error) }
            }
        } catch {
            delete(bottle)      // the installer never started: the bottle holds nothing
            throw error
        }
        // From here on the installer has run and the bottle may hold what it installed: no error deletes it.
        // If one keeps the programs from being recorded, `adoptUnrecorded` finds them at the next start.
        // Bootstrapper installers start the real setup and exit at once; wait until every Windows process in
        // the bottle has finished (wineserver exits then), or the scan below would run mid-install. That
        // includes a program the installer starts at its end; the sheet asks the user to quit it.
        try await launcher.waitForShutdown(bottle)
        bottle.clearImports()          // the installer's copy inside the bottle
        progress(.findingPrograms)
        let added = Self.installedExecutables(in: bottle).subtracting(exesBefore)
        let found = Self.installedPrograms(in: bottle, apartFrom: before, among: added)
        if !found.isEmpty { return found }
        guard !added.isEmpty else {
            // Not one new executable: the installer was cancelled or failed, and a bottle without a program
            // would never show in the library. To the Trash rather than deleted, should the guess be wrong.
            try? store.moveToTrash(bottle)
            throw Failure.nothingInstalled(name: name)
        }
        throw Failure.installerFoundNothing(name: name)
    }

    /// What an install left in `bottle`: the Start Menu shortcuts not among `before`; without any, the main
    /// programs among the executables `added`. If that leaves nothing, the same again with what only its name
    /// set aside (a game called "Manual Samuel", a `Support.exe`).
    static func installedPrograms(in bottle: Bottle, apartFrom before: Set<String> = [], among added: Set<URL>) -> [Program] {
        for includingAuxiliary in [false, true] {
            let new = bottle.startMenuPrograms(includingAuxiliary: includingAuxiliary)
                .filter { !before.contains($0.windowsPath.lowercased()) }
            if !new.isEmpty { return new }
            let candidates = Self.programs(among: added, in: bottle, includingAuxiliary: includingAuxiliary)
            if !candidates.isEmpty { return candidates }
        }
        return []
    }

    /// Gives bottles whose install never reached the library their programs: Harbor quit while the installer
    /// ran, or recording what it installed failed. Looks at every bottle in `store` that has no `programs.json`,
    /// holds no game store, isn't running and isn't being added to right now, and finds its programs the way
    /// `add` does once an installer has exited.
    ///
    /// Returns the bottles that now have programs recorded (`adopted`) and those in which nothing was found
    /// (`empty`: a cancelled install, a bottle that was never set up). The empty ones are left as they are;
    /// the caller decides (`BottleStore.moveToTrash`). Reads many files: call it off the main actor.
    public static func adoptUnrecorded(in store: BottleStore) -> (adopted: [Bottle], empty: [Bottle]) {
        let fm = FileManager.default
        var adopted: [Bottle] = [], empty: [Bottle] = []
        for bottle in store.list() where !fm.fileExists(atPath: bottle.programsFile.path) && !bottle.isClaimed
            && !bottle.isRunning() && SteamLibrary.steamFolder(in: bottle) == nil && EpicLibrary.launcherPath(in: bottle) == nil {
            let executables = installedExecutables(in: bottle).filter { !isWinesOwn($0, in: bottle) }
            let programs = installedPrograms(in: bottle, among: executables)
            if programs.isEmpty {
                empty.append(bottle)
            } else if (try? bottle.savePrograms(programs)) != nil {
                try? fm.removeItem(at: bottle.claimFile)       // what the interrupted add left
                adopted.append(bottle)
            }
        }
        return (adopted, empty)
    }

    /// How long an empty bottle is left alone after it was made: whoever made it may be about to use it.
    static let abandonedAfter: TimeInterval = 5 * 60

    /// What the app does at every look at the library: `adoptUnrecorded`, and of the empty bottles those go to
    /// the Trash that nobody will miss: no installer put a program file into them, they aren't running and
    /// weren't made in the last minutes. An empty bottle that holds an installer's files (programs Harbor
    /// couldn't name) stays. Reads many files: call it off the main actor.
    public static func recoverUnrecorded(in store: BottleStore, now: Date = Date()) -> (adopted: [Bottle], trashed: [Bottle]) {
        let found = adoptUnrecorded(in: store)
        let trashed = found.empty.filter { bottle in
            guard let made = (try? bottle.root.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  now.timeIntervalSince(made) > abandonedAfter,
                  installedExecutables(in: bottle).allSatisfy({ isWinesOwn($0, in: bottle) }),
                  !bottle.isRunning(), !bottle.isClaimed else { return false }
            return (try? store.moveToTrash(bottle)) != nil
        }
        return (found.adopted, trashed)
    }

    /// Whether `executable` is one every Wine prefix has outside its Windows folder (its stand-ins for Internet
    /// Explorer, WordPad and Media Player), which no installer put there.
    static func isWinesOwn(_ executable: URL, in bottle: Bottle) -> Bool {
        let parts = (bottle.windowsPath(for: executable) ?? "").lowercased().split(separator: "\\")
        return parts.count > 2 && parts[1].hasPrefix("program files")
            && ["internet explorer", "windows media player", "windows nt"].contains(parts[2])
    }

    /// The main programs among executables an installer added: with a window, not installers themselves, not
    /// uninstallers or other helpers (`includingAuxiliary`: only uninstallers are left out). Saves their icons.
    static func programs(among added: Set<URL>, in bottle: Bottle, includingAuxiliary: Bool = false) -> [Program] {
        let candidates = added.compactMap { exe -> Program? in
            let name = exe.lastPathComponent
            guard let analysis = try? ProgramAnalysis.analyze(exe), analysis.isGUI, analysis.installer == nil,
                  !(includingAuxiliary ? Bottle.isUninstaller(name: name, target: name) : Bottle.isAuxiliary(name: name, target: name)),
                  let windows = bottle.windowsPath(for: exe) else { return nil }
            let program = Program(name: analysis.displayName(fallback: exe), windowsPath: windows,
                                  isGame: Bottle.looksLikeGame(exe))
            bottle.saveIcon(for: program, from: exe)
            return program
        }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Puts a program that needs no installer into `C:\Program Files\<name>\`. Its folder comes along (programs
    /// usually need the files next to them), except when the program sits directly in a shared folder such as
    /// Downloads or Desktop: then only the program is copied, so unrelated personal files never enter the
    /// bottle. Nothing is ever symlinked in, so a Windows uninstaller can't reach the Mac folder: links are
    /// followed for the program itself and dropped from its folder when they lead out of it.
    /// `root`: the program's folder if the user named it (dropped the folder), instead of working it out.
    func place(_ file: URL, analysis: ProgramAnalysis, name: String, in bottle: Bottle, root: URL? = nil) throws -> Program {
        let fm = FileManager.default
        let programFolderName = analysis.architecture == .x86 ? "Program Files (x86)" : "Program Files"
        let programFiles = bottle.driveC.appending(path: programFolderName)
        try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
        let folderName = Self.safeFolderName(name, fallback: file.deletingPathExtension().lastPathComponent)
        let destination = programFiles.appending(path: folderName)
        // The whole program comes along: for a game whose .exe sits in Binaries\Win64, that's the game's folder.
        let relative: [String]
        if let root = root ?? Self.programRoot(for: file) {
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
        // Games ship pictures, videos and manuals too; a folder with DLLs next to the program is the program's.
        isSharedPlace(folder) || (containsPersonalDocuments(folder) && !containsLibraries(folder))
    }

    /// The part of `isSharedFolder` that goes by where the folder is, not by what it holds.
    static func isSharedPlace(_ folder: URL) -> Bool {
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
        return parts.count == 2 && parts[0] == "Volumes"                         // a disk's root, e.g. /Volumes/USB
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

    /// Executables where installers put programs: anywhere on drive C: (some install to `C:\Games\<name>` or
    /// `C:\<name>`) except Windows itself, the user folders and ProgramData, down to the depth of
    /// `Program Files\<vendor>\<product>\bin`.
    static func installedExecutables(in bottle: Bottle) -> Set<URL> {
        var found = Set<URL>()
        guard let walker = FileManager.default.enumerator(at: bottle.driveC, includingPropertiesForKeys: nil) else { return found }
        for case let url as URL in walker {
            if walker.level == 1, ["windows", "users", "programdata"].contains(url.lastPathComponent.lowercased()) {
                walker.skipDescendants(); continue
            }
            if walker.level > 5 { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe" { found.insert(url.standardizedFileURL) }
        }
        return found
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// What a dropped folder stands for: the installer or the program at its top. In this order: what the
    /// disc's `autorun.inf` opens; an installer named setup or install; the only program (redistributables'
    /// installers may sit beside it); the only installer; among several programs the one named like the folder.
    /// Uninstallers and other helpers never count.
    static func entry(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        // An install disc is a disk's root too; anything else there, or Downloads, isn't one program's folder.
        guard Bottle.isInstallDisc(folder) || !isSharedPlace(folder) else { throw Failure.sharedFolder }
        // Paths built on `folder`, so they stay below it as written (the system's listing may spell it differently).
        let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { folder.appending(path: $0) }
        if let autorun = files.first(where: { $0.lastPathComponent.lowercased() == "autorun.inf" }),
           let opened = autorunTarget(autorun, in: folder) { return opened }

        var installers: [URL] = [], programs: [URL] = []
        // If the names leave nothing ("Manual Samuel.exe" alone in its folder), only uninstallers are set aside.
        for isHelper in [Bottle.isAuxiliary, Bottle.isUninstaller] where installers.isEmpty && programs.isEmpty {
            for file in files.prefix(2000) where ["exe", "msi"].contains(file.pathExtension.lowercased())
                && !isHelper(file.lastPathComponent, file.lastPathComponent) {
                guard let analysis = try? ProgramAnalysis.analyze(file) else { continue }
                if analysis.installer != nil { installers.append(file) } else if analysis.isGUI { programs.append(file) }
            }
        }
        let stem = { (file: URL) in file.deletingPathExtension().lastPathComponent.lowercased() }
        let named = installers.filter { ["setup", "install", "installer"].contains(stem($0)) }
        if named.count == 1 { return named[0] }
        if programs.count == 1 { return programs[0] }
        if programs.isEmpty, installers.count == 1 { return installers[0] }
        let letters = { (name: String) in name.lowercased().filter { $0.isLetter || $0.isNumber } }
        let own = programs.filter { letters($0.deletingPathExtension().lastPathComponent) == letters(folder.lastPathComponent) }
        if own.count == 1 { return own[0] }
        throw Failure.unclearFolder
    }

    /// The program `open=` names in a disc's `autorun.inf`, if it is a Windows program inside `folder`.
    static func autorunTarget(_ autorun: URL, in folder: URL) -> URL? {
        guard let data = try? Data(contentsOf: autorun), data.count < 1_000_000 else { return nil }
        let text = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            ? String(data: data, encoding: .utf16) : String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        for line in (text ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "open" else { continue }
            // `open=Setup\setup.exe /auto`: the path ends with the program's extension, arguments follow.
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let end = [".exe", ".msi"].compactMap({ value.range(of: $0, options: .caseInsensitive)?.upperBound }).min() else { return nil }
            var url = folder
            for name in value[..<end].split(whereSeparator: { $0 == "\\" || $0 == "/" }) where name != "." {
                // Discs are written without regard to case; the Mac's disks may tell it apart.
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                guard name != "..", let match = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
                url.append(path: match)
            }
            return isFolder(url) ? nil : url
        }
        return nil
    }

    /// The name a dropped file's (or folder's) bottle will get, or nil if it isn't a Windows program. Lets the
    /// app notice that something is already installed before adding it again.
    public static func suggestedName(for file: URL) -> String? {
        let folder = isFolder(file) ? file : nil
        guard let file = folder.map({ try? entry(in: $0) }) ?? file,
              ["exe", "msi"].contains(file.pathExtension.lowercased()),
              let analysis = try? ProgramAnalysis.analyze(file) else { return nil }
        return bottleName(for: analysis, file: folder ?? file)
    }

    /// "Thing Setup 2.1" → "Thing": product name without installer words and version numbers. `file` gives the
    /// name when the program carries none: the program's file, or the folder that was dropped.
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
    var claimFile: URL { root.appending(path: ".adding") }

    /// Marks the bottle as being set up by this process; call the returned function when that is over. The mark
    /// is a lock, which the system drops when the process ends: a bottle left behind by a crash isn't claimed.
    func claim() -> @Sendable () -> Void {
        let file = claimFile
        let fd = open(file.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return {} }
        _ = flock(fd, LOCK_EX | LOCK_NB)
        return {
            try? FileManager.default.removeItem(at: file)
            close(fd)
        }
    }

    /// Whether some process is setting the bottle up right now (`claim`).
    var isClaimed: Bool {
        let fd = open(claimFile.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// Windows path (`C:\…`) for a file inside this bottle's drive C, or `D:\…` for one on the drive an installer
    /// runs from (`mediaDrive`); nil if it's elsewhere.
    public func windowsPath(for file: URL) -> String? {
        let path = file.standardizedFileURL.path
        for (letter, root) in [("C:", driveC.standardizedFileURL.path), ("D:", mediaDrive.standardizedFileURL.path)]
        where path.hasPrefix(root + "/") {
            return letter + path.dropFirst(root.count).replacingOccurrences(of: "/", with: "\\")
        }
        return nil
    }
}
