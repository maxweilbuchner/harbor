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
        let process = try launcher.open(file, in: bottle)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
        }
        // Bootstrapper installers start the real setup and exit at once; wait until every Windows process in
        // the bottle has finished (wineserver exits then), or the scan below would run mid-install.
        try await launcher.waitForShutdown(bottle)
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
    /// bottle. Nothing is ever symlinked in, so a Windows uninstaller can't reach the Mac folder.
    private func place(_ file: URL, analysis: ProgramAnalysis, name: String, in bottle: Bottle) throws -> Program {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        let programFolderName = analysis.architecture == .x86 ? "Program Files (x86)" : "Program Files"
        let programFiles = bottle.driveC.appending(path: programFolderName)
        try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
        let destination = programFiles.appending(path: Self.safeFolderName(name))
        if Self.isSharedFolder(folder) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: destination.appending(path: file.lastPathComponent))
        } else {
            try fm.copyItem(at: folder, to: destination)   // a clone on APFS: no extra disk until files change
        }
        let windows = #"C:\#(programFolderName)\#(Self.safeFolderName(name))\#(file.lastPathComponent)"#
        let program = Program(name: analysis.displayName(fallback: file), windowsPath: windows,
                              isGame: Bottle.looksLikeGame(file))
        bottle.saveIcon(for: program, from: file)
        return program
    }

    /// Folders that hold many unrelated files: the home folder, its standard folders, Applications, volume roots.
    static func isSharedFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        var shared: Set<String> = ["/", "/Applications", "/Users", "/Volumes", home]
        for name in ["Downloads", "Desktop", "Documents", "Applications", "Library", "Movies", "Music", "Pictures", "Public"] {
            shared.insert(home + "/" + name)
        }
        if shared.contains(path) { return true }
        // A disk's root, e.g. /Volumes/USB.
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"
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

    static func safeFolderName(_ name: String) -> String {
        let cleaned = name.map { #"<>:"/\|?*"#.contains($0) ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
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
