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
    /// Apple's D3DMetal from the Game Porting Toolkit (user-installed; not redistributed).
    case d3dmetal
}

public enum WindowsVersion: String, Codable, Sendable, CaseIterable {
    case win7, win10, win11
}

/// User-editable settings, stored as `bottle.json` next to the Wine prefix.
public struct BottleSettings: Codable, Sendable, Equatable {
    public var name: String
    public var windowsVersion: WindowsVersion = .win10
    public var graphics: GraphicsBackend = .automatic
    /// Extra environment variables for advanced users.
    public var environment: [String: String] = [:]

    public init(name: String) {
        self.name = name
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

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }
}
