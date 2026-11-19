import Foundation

/// Adds a dropped Windows file to the library: one bottle per program, named after the product.
///
/// - Installers (MSI, Inno, NSIS, InstallShield, WiX, or a setup-named .exe) run with their normal UI; the
///   programs they leave in the Start Menu become library items. If an installer creates no shortcuts, new
///   executables under Program Files are offered instead.
/// - Anything else is treated as a program that runs as-is: its folder goes into the bottle (copied when small,
///   linked when large) and the program itself becomes the library item.
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
    /// Folders larger than this are linked into the bottle instead of copied.
    public var copyLimit: Int64 = 512 * 1024 * 1024

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
        do {
            let programs: [Program]
            if analysis.installer != nil {
                programs = try await install(file, name: name, into: bottle, progress: progress)
            } else {
                programs = [try place(file, analysis: analysis, name: name, in: bottle)]
            }
            try bottle.savePrograms(programs)
            return (bottle, programs)
        } catch {
            try? launcher.shutdown(bottle)
            try? FileManager.default.removeItem(at: bottle.root)
            throw error
        }
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

    /// Puts a program that needs no installer into `C:\Program Files\<name>\` (its whole folder, since programs
    /// usually need the files next to them).
    private func place(_ file: URL, analysis: ProgramAnalysis, name: String, in bottle: Bottle) throws -> Program {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        let programFiles = bottle.driveC.appending(path: analysis.architecture == .x86 ? "Program Files (x86)" : "Program Files")
        try fm.createDirectory(at: programFiles, withIntermediateDirectories: true)
        let destination = programFiles.appending(path: Self.safeFolderName(name))
        if Self.size(of: folder, limit: copyLimit) <= copyLimit {
            try fm.copyItem(at: folder, to: destination)
        } else {
            try fm.createSymbolicLink(at: destination, withDestinationURL: folder)
        }
        let programFolderName = analysis.architecture == .x86 ? "Program Files (x86)" : "Program Files"
        let windows = #"C:\\#(programFolderName)\\#(Self.safeFolderName(name))\\#(file.lastPathComponent)"#
        let program = Program(name: analysis.displayName(fallback: file), windowsPath: windows,
                              isGame: Bottle.looksLikeGame(file))
        bottle.saveIcon(for: program, from: file)
        return program
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

    /// Total size of `folder`, stopping early once it exceeds `limit`.
    static func size(of folder: URL, limit: Int64) -> Int64 {
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            if total > limit { return total }
        }
        return total
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
