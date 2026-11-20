import CryptoKit
import Foundation

/// A random secret made once per Mac and mixed into the library IDs of store games. Those IDs are derived (so
/// they survive rescans), and `harbor://launch/<id>` starts a program: derived from the bottle and app ID alone,
/// any web page could name an installed game.
public struct LaunchSalt: Sendable {
    public let file: URL

    public init(file: URL = LaunchSalt.defaultFile) {
        self.file = file
    }

    /// `~/Library/Application Support/Harbor/launch-salt`.
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Harbor/launch-salt")
    }

    /// The salt, made and saved on first use. The same on every later call, so IDs stay stable on this Mac.
    public func value() -> String {
        if let saved = saved() { return saved }
        let fresh = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(fresh.utf8).write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return saved() ?? fresh
    }

    private func saved() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let salt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return salt.count >= 32 ? salt : nil   // anything shorter isn't one of ours: replace it
    }
}

/// Games installed by Steam inside a bottle, read from Steam's own records, so they appear in Harbor's library
/// next to everything else. Each launches through Steam (`steam.exe -applaunch <id>`), which keeps Steam's
/// updates, cloud saves and overlay working, and runs on the same runtime as Steam (D3DMetal for games).
public enum SteamLibrary {
    /// Steam's install folder in a bottle, if Steam is installed there.
    public static func steamFolder(in bottle: Bottle) -> URL? {
        for candidate in [#"C:\Program Files (x86)\Steam"#, #"C:\Program Files\Steam"#] {
            if let url = bottle.unixPath(forWindowsPath: candidate),
               FileManager.default.fileExists(atPath: url.appending(path: "steam.exe").path) { return url }
        }
        return nil
    }

    public struct Game: Equatable, Sendable {
        public var appID: Int
        public var name: String
        /// Folder name under steamapps/common.
        public var installDirectory: String
        /// When Steam wrote the game's record (its manifest file's creation), nil if unknown.
        public var installedAt: Date?
    }

    /// Installed games from every Steam library folder (`steamapps/libraryfolders.vdf`), skipping tools such
    /// as "Steamworks Common Redistributables" and Proton/runtime entries.
    public static func games(in bottle: Bottle) -> [Game] {
        guard let steam = steamFolder(in: bottle) else { return [] }
        var libraries = [steam.appending(path: "steamapps")]
        if let vdf = try? String(contentsOf: steam.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for path in KeyValues.values(forKey: "path", in: vdf) {
                if let url = bottle.unixPath(forWindowsPath: path) { libraries.append(url.appending(path: "steamapps")) }
            }
        }
        var games: [Game] = [], seen = Set<Int>()
        for library in libraries {
            let files = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8), var game = parseManifest(text),
                      seen.insert(game.appID).inserted, !isTool(game) else { continue }
                game.installedAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ text: String) -> Game? {
        guard let id = KeyValues.values(forKey: "appid", in: text).first.flatMap(Int.init),
              let name = KeyValues.values(forKey: "name", in: text).first, !name.isEmpty else { return nil }
        return Game(appID: id, name: name, installDirectory: KeyValues.values(forKey: "installdir", in: text).first ?? "")
    }

    /// App IDs Steam installs for its own use rather than as games.
    static let toolIDs: Set<Int> = [228980]   // Steamworks Common Redistributables
    static func isTool(_ game: Game) -> Bool {
        toolIDs.contains(game.appID) || game.name.hasPrefix("Proton") || game.name.hasPrefix("Steam Linux Runtime")
    }

    /// A library entry for a Steam game. The ID is derived from the app ID and this Mac's `salt`, so it stays the same across scans
    /// (its Mac shortcut and settings survive); so does its date, or every scan would sort it as just added.
    public static func program(for game: Game, steam: URL, in bottle: Bottle, salt: String) -> Program? {
        guard let steamExe = bottle.windowsPath(for: steam.appending(path: "steam.exe")) else { return nil }
        var program = Program(name: game.name, windowsPath: steamExe, arguments: "-applaunch \(game.appID)",
                              workingDirectory: bottle.windowsPath(for: steam), isGame: true)
        program.id = stableID(appID: game.appID, bottle: bottle, salt: salt)
        program.addedAt = game.installedAt ?? .distantPast
        return program
    }

    static func stableID(appID: Int, bottle: Bottle, salt: String) -> UUID {
        stableID(seed: "steam:\(bottle.root.lastPathComponent):\(appID)", salt: salt)
    }

    /// Name-based ID: the first 16 bytes of SHA-256 over `salt` and `seed`. Without the salt it can't be guessed.
    static func stableID(seed: String, salt: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((salt + "\n" + seed).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 layout (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Steam's cached artwork for a game: the library icon if present, else its header image.
    public static func iconSource(for game: Game, steam: URL) -> URL? {
        let cache = steam.appending(path: "appcache/librarycache")
        let fm = FileManager.default
        let candidates = [cache.appending(path: "\(game.appID)_icon.jpg"),
                          cache.appending(path: "\(game.appID)/logo.png"),
                          cache.appending(path: "\(game.appID)_library_600x900.jpg"),
                          cache.appending(path: "\(game.appID)/library_600x900.jpg"),
                          cache.appending(path: "\(game.appID)_header.jpg")]
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return found }
        // Newer caches keep hashed file names inside the app's folder.
        let folder = cache.appending(path: "\(game.appID)")
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .first { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
    }
}

/// Minimal reader for Valve's KeyValues text format ("key" "value" pairs in nested { } blocks).
enum KeyValues {
    /// Every value stored under `key` (case-insensitive), at any depth.
    static func values(forKey key: String, in text: String) -> [String] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var token = ""
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != "\"" {
                    if text[j] == "\\", text.index(after: j) < text.endIndex {
                        j = text.index(after: j)
                        token.append(text[j] == "\\" ? "\\" : text[j])
                    } else {
                        token.append(text[j])
                    }
                    j = text.index(after: j)
                }
                tokens.append(token)
                i = j < text.endIndex ? text.index(after: j) : j
            } else if c == "{" || c == "}" {
                tokens.append(String(c))
                i = text.index(after: i)
            } else {
                i = text.index(after: i)
            }
        }
        var out: [String] = []
        for (n, token) in tokens.enumerated() where n + 1 < tokens.count && token.caseInsensitiveCompare(key) == .orderedSame {
            let value = tokens[n + 1]
            if value != "{" && value != "}" { out.append(value) }
        }
        return out
    }
}
