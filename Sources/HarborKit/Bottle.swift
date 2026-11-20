import Foundation

/// The graphics translation layer a bottle uses for Direct3D.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    /// Let Harbor choose per program.
    case automatic
    /// Wine's built-in wined3d (OpenGL). Always available, slowest.
    case wined3d
    /// DXMT: D3D10/11 → Metal.
    case dxmt
    /// DXVK over MoltenVK: D3D8–11 → Vulkan → Metal.
    case dxvk
    /// Apple's D3DMetal from the Game Porting Toolkit, shipped unmodified for non-commercial use. Games only.
    case d3dmetal
}

public enum WindowsVersion: String, Codable, Sendable, CaseIterable {
    case win7, win10, win11
}

/// User-editable settings, stored as `bottle.json` next to the Wine prefix.
///
/// Decoding is tolerant: missing keys and unknown enum values fall back to defaults, so files written by newer or
/// older Harbor versions still load. Bump `currentSchemaVersion` and migrate in `init(from:)` for breaking changes.
public struct BottleSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = BottleSettings.currentSchemaVersion
    public var name: String
    public var windowsVersion: WindowsVersion = .win10
    public var graphics: GraphicsBackend = .automatic
    /// Extra environment variables for advanced users.
    public var environment: [String: String] = [:]
    /// Whether Windows programs in this bottle see the Mac's whole file system as drive Z:. Off by default: programs
    /// and installers then only find the bottle's own drive C:. For programs that open or save files anywhere on
    /// the Mac (an archiver, an editor).
    public var macFilesAccess = false

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, name, windowsVersion, graphics, environment, macFilesAccess
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        windowsVersion = (try? c.decodeIfPresent(String.self, forKey: .windowsVersion))
            .flatMap(WindowsVersion.init(rawValue:)) ?? .win10
        graphics = (try? c.decodeIfPresent(String.self, forKey: .graphics))
            .flatMap(GraphicsBackend.init(rawValue:)) ?? .automatic
        environment = (try? c.decodeIfPresent([String: String].self, forKey: .environment)) ?? [:]
        macFilesAccess = (try? c.decodeIfPresent(Bool.self, forKey: .macFilesAccess)) ?? false
    }
}

/// A self-contained Windows environment: `<root>/bottle.json` plus a Wine prefix in `<root>/prefix`.
public struct Bottle: Sendable, Equatable, Identifiable {
    public let root: URL
    public var settings: BottleSettings

    public var id: URL { root }
    public var prefix: URL { root.appending(path: "prefix") }
    public var settingsFile: URL { root.appending(path: "bottle.json") }
    public var driveC: URL { prefix.appending(path: "drive_c") }

    public init(root: URL, settings: BottleSettings) {
        self.root = root
        self.settings = settings
    }

    public static func load(from root: URL) throws -> Bottle {
        let data = try Data(contentsOf: root.appending(path: "bottle.json"))
        return Bottle(root: root, settings: try JSONDecoder().decode(BottleSettings.self, from: data))
    }

    public var logsDirectory: URL { root.appending(path: "logs") }

    /// Log files, newest first.
    public func logs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Creates `logs/<timestamp>-<label>.log` for one run and keeps only the newest `keep` logs. A second run in
    /// the same second gets `<timestamp>.2-<label>.log`: the counter can't be mistaken for part of a label (a
    /// program called "Quest 2" logs as `…-Quest-2.log`) and sorts after the first run's log.
    func newLog(label: String, keep: Int = 20) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        for old in logs().dropFirst(keep - 1) { try? fm.removeItem(at: old) }
        let stamp = Self.logStamp.string(from: Date())
        let safeLabel = Self.logLabel(label)
        var url = logsDirectory.appending(path: "\(stamp)-\(safeLabel).log")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = logsDirectory.appending(path: "\(stamp).\(n)-\(safeLabel).log")
            n += 1
        }
        fm.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    /// The label part of a log's file name.
    static func logLabel(_ label: String) -> String {
        String(label.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
    }

    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }
}
