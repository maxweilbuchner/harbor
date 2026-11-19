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
        scan().bottles
    }

    /// Bottles plus folders whose `bottle.json` couldn't be read, so the UI can offer repair instead of
    /// the bottle silently disappearing.
    public func scan() -> (bottles: [Bottle], damaged: [(folder: URL, error: any Error)]) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var bottles: [Bottle] = []
        var damaged: [(URL, any Error)] = []
        for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do { bottles.append(try Bottle.load(from: folder)) } catch { damaged.append((folder, error)) }
        }
        bottles.sort { $0.settings.name.localizedStandardCompare($1.settings.name) == .orderedAscending }
        return (bottles, damaged)
    }

    /// Creates a bottle and runs `setUp` on it (normally `WineLauncher.initialize`); if that fails, the half-made
    /// bottle is removed again.
    public func create(name: String, setUp: (Bottle) async throws -> Void) async throws -> Bottle {
        let bottle = try create(name: name)
        do {
            try await setUp(bottle)
        } catch {
            try? FileManager.default.removeItem(at: bottle.root)
            throw error
        }
        return bottle
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
