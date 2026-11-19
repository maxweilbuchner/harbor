import Foundation

/// Bottles live in `~/Library/Application Support/Harbor/Bottles/<slug>/`.
public struct BottleStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var `default`: BottleStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BottleStore(directory: support.appending(path: "Harbor/Bottles"))
    }

    public func list() -> [Bottle] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? Bottle.load(from: $0) }
            .sorted { $0.settings.name.localizedStandardCompare($1.settings.name) == .orderedAscending }
    }

    /// Creates the bottle folder and settings. The Wine prefix itself is created by `WineLauncher.initialize`.
    public func create(name: String) throws -> Bottle {
        var slug = Self.slug(for: name)
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: slug).path) {
            slug = "\(Self.slug(for: name))-\(n)"
            n += 1
        }
        let bottle = Bottle(root: directory.appending(path: slug), settings: BottleSettings(name: name))
        try bottle.save()
        return bottle
    }

    public func bottle(named name: String) -> Bottle? {
        list().first { $0.settings.name == name || $0.root.lastPathComponent == name }
    }

    static func slug(for name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "bottle" : collapsed
    }
}
