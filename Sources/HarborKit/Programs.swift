import Foundation

/// A Windows shortcut (.lnk, Microsoft's Shell Link format), as installers create them in the Start Menu.
public struct ShellLink: Sendable, Equatable {
    /// Windows path of the target, e.g. `C:\Program Files\App\app.exe`.
    public var target: String
    public var arguments: String?
    public var workingDirectory: String?
    /// The shortcut's own icon (ICON_LOCATION), e.g. for a .bat target that has none.
    public var iconLocation: String?

    /// Parses the target from the LinkInfo block, and arguments/working directory from the string data.
    /// Returns nil for links without a local target (network paths, shell folders, damaged files).
    public init?(_ data: Data) {
        guard data.u32(0) == 0x4C, let flags = data.u32(0x14) else { return nil }
        var p = 0x4C
        if flags & 0x1 != 0 {                                      // HasLinkTargetIDList
            guard let size = data.u16(p) else { return nil }
            p += 2 + Int(size)
        }
        var target: String?
        if flags & 0x2 != 0 {                                      // HasLinkInfo
            guard let size = data.u32(p).map(Int.init), size >= 28, let infoFlags = data.u32(p + 8),
                  let baseOffset = data.u32(p + 16).map(Int.init),
                  let suffixOffset = data.u32(p + 24).map(Int.init) else { return nil }
            if infoFlags & 0x1 != 0 {                              // VolumeIDAndLocalBasePath
                let base = Self.ansiString(data, from: p + baseOffset, limit: p + size)
                let suffix = Self.ansiString(data, from: p + suffixOffset, limit: p + size)
                if let base, !base.isEmpty {
                    target = suffix.map { $0.isEmpty ? base : (base.hasSuffix("\\") ? base + $0 : base + "\\" + $0) } ?? base
                }
            }
            p += size
        }
        // StringData: NAME, RELATIVE_PATH, WORKING_DIR, ARGUMENTS, ICON_LOCATION, each present if flagged.
        let unicode = flags & 0x80 != 0
        var strings: [UInt32: String] = [:]
        for bit in [UInt32(0x4), 0x8, 0x10, 0x20, 0x40] where flags & bit != 0 {
            guard let count = data.u16(p).map(Int.init) else { return nil }
            p += 2
            let bytes = unicode ? count * 2 : count
            guard let raw = data.slice(p, bytes) else { return nil }
            strings[bit] = unicode ? String(decoding: (0..<count).compactMap { raw.u16($0 * 2) }, as: UTF16.self)
                                   : String(decoding: raw, as: UTF8.self)
            p += bytes
        }
        guard let target else { return nil }
        self.target = target
        arguments = strings[0x20].flatMap { $0.isEmpty ? nil : $0 }
        workingDirectory = strings[0x10].flatMap { $0.isEmpty ? nil : $0 }
        iconLocation = strings[0x40].flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(target: String, arguments: String? = nil, workingDirectory: String? = nil, iconLocation: String? = nil) {
        self.target = target
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.iconLocation = iconLocation
    }

    static func ansiString(_ data: Data, from offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < min(limit, data.count) else { return nil }
        let bytes = data[data.startIndex + offset ..< data.startIndex + min(limit, data.count)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A Windows program in Harbor's library: what to run in which bottle.
public struct Program: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Windows path of the executable, e.g. `C:\Program Files\App\app.exe`.
    public var windowsPath: String
    public var arguments: String?
    public var workingDirectory: String?
    /// Detected from the executable (`ProgramAnalysis.looksLikeGame`); the user can change it.
    public var isGame: Bool
    /// nil = choose automatically per launch.
    public var graphics: GraphicsBackend?
    public var addedAt: Date

    public init(name: String, windowsPath: String, arguments: String? = nil, workingDirectory: String? = nil,
                isGame: Bool = false, graphics: GraphicsBackend? = nil) {
        id = UUID()
        self.name = name
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.isGame = isGame
        self.graphics = graphics
        addedAt = Date()
    }
}

extension Bottle {
    var programsFile: URL { root.appending(path: "programs.json") }
    var iconsDirectory: URL { root.appending(path: "icons") }

    public func programs() -> [Program] {
        guard let data = try? Data(contentsOf: programsFile) else { return [] }
        // Default date coding (seconds as a Double) round-trips exactly; ISO 8601 drops fractions.
        return (try? JSONDecoder().decode([Program].self, from: data)) ?? []
    }

    public func savePrograms(_ programs: [Program]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(programs).write(to: programsFile, options: .atomic)
    }

    public func iconFile(for program: Program) -> URL { iconsDirectory.appending(path: "\(program.id.uuidString).png") }

    /// Extracts the icon of `source` (an .exe, or an .ico file) into the icon cache; tries `fallback` if needed.
    func saveIcon(for program: Program, from source: URL, fallback: URL? = nil) {
        func png(_ url: URL) -> Data? {
            if url.pathExtension.lowercased() == "ico", let data = try? Data(contentsOf: url) { return PEFile.pngFromICO(data) }
            return (try? ProgramAnalysis.analyze(url))?.iconPNG
        }
        guard let data = png(source) ?? fallback.flatMap(png) else { return }
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        try? data.write(to: iconFile(for: program))
    }

    /// Maps a Windows path in this bottle to the Mac file, matching names case-insensitively like Windows does.
    /// Only drive C: (the bottle's own drive) is resolved.
    public func unixPath(forWindowsPath windowsPath: String) -> URL? {
        var parts = windowsPath.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let drive = parts.first, drive.lowercased() == "c:" else { return nil }
        parts.removeFirst()
        var url = driveC
        let fm = FileManager.default
        for part in parts where !part.isEmpty && part != "." {
            guard part != ".." else { return nil }
            let exact = url.appending(path: part)
            if fm.fileExists(atPath: exact.path) { url = exact; continue }
            guard let match = (try? fm.contentsOfDirectory(atPath: url.path))?
                    .first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
            url = url.appending(path: match)
        }
        return url
    }

    /// The bottle's Start Menu folders (all users and the Windows user Wine created).
    var startMenuFolders: [URL] {
        var folders = [driveC.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = driveC.appending(path: "users")
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            folders.append(users.appending(path: "\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        return folders
    }

    /// Programs the Start Menu offers: .lnk shortcuts to existing .exe/.bat/.cmd files, minus uninstallers, docs and
    /// duplicates. Names come from the shortcut file name, which installers choose for people to read.
    public func startMenuPrograms() -> [Program] {
        var found: [Program] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for folder in startMenuFolders {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "lnk" {
                guard let data = try? Data(contentsOf: file), let link = ShellLink(data) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                // .bat/.cmd too: some launch through a script (Unigine Heaven's shortcut targets heaven.bat).
                guard Self.launchableExtensions.contains(where: { link.target.lowercased().hasSuffix($0) }),
                      !Self.isAuxiliary(name: name, target: link.target),
                      seen.insert(link.target.lowercased()).inserted,
                      let exe = unixPath(forWindowsPath: link.target), fm.fileExists(atPath: exe.path) else { continue }
                let program = Program(name: name, windowsPath: link.target, arguments: link.arguments,
                                      workingDirectory: link.workingDirectory, isGame: Self.looksLikeGame(exe))
                // The shortcut's icon first (it's what Windows shows), else the target's own.
                let iconSource = link.iconLocation.flatMap { unixPath(forWindowsPath: $0) } ?? exe
                saveIcon(for: program, from: iconSource, fallback: exe)
                found.append(program)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static let launchableExtensions = [".exe", ".bat", ".cmd"]

    /// Whether `file` or a program installed next to it is a game. Launchers often have no DirectX imports
    /// themselves, so the folder counts: up to 40 executables, two levels below the target's folder.
    public static func looksLikeGame(_ file: URL) -> Bool {
        if (try? ProgramAnalysis.analyze(file))?.looksLikeGame == true { return true }
        let folder = file.deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return false }
        var checked = 0
        for case let candidate as URL in walker {
            if walker.level > 2 { walker.skipDescendants(); continue }
            guard candidate.pathExtension.lowercased() == "exe", candidate != file,
                  !isAuxiliary(name: candidate.lastPathComponent, target: candidate.lastPathComponent) else { continue }
            checked += 1
            if (try? ProgramAnalysis.analyze(candidate))?.looksLikeGame == true { return true }
            if checked >= 40 { break }
        }
        return false
    }

    static func isAuxiliary(name: String, target: String) -> Bool {
        let n = name.lowercased()
        let t = (target.split(separator: "\\").last.map(String.init) ?? target).lowercased()
        let words = ["uninstall", "deinstall", "remove ", "readme", "read me", "manual", "help", "documentation",
                     "license", "website", "support", "release notes", "changelog"]
        return words.contains { n.contains($0) } || t.hasPrefix("unins") || t.contains("uninstall")
    }
}
