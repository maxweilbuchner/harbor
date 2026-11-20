import Foundation

/// Games installed by the Epic Games Launcher inside a bottle, read from the launcher's own install manifests, so
/// they appear in Harbor's library next to everything else. Each launches through the launcher (its
/// `com.epicgames.launcher://apps/…?action=launch` link), which keeps sign-in, updates and cloud saves working, and
/// runs on the launcher's runtime (D3DMetal, since the launcher counts as a game).
public enum EpicLibrary {
    /// Where the launcher installs: today's 64-bit MSI uses Program Files, older installs Program Files (x86).
    static let launcherPaths = [#"C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#,
                                #"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#]
    static let manifestsPath = #"C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"#

    /// Windows path of the launcher in a bottle, if the Epic Games Launcher is installed there.
    public static func launcherPath(in bottle: Bottle) -> String? {
        launcherPaths.first { path in
            bottle.unixPath(forWindowsPath: path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    public struct Game: Equatable, Sendable {
        public var appName: String
        public var namespace: String
        public var catalogItemID: String
        public var name: String
        /// Windows path of the game's own executable (for its icon).
        public var executable: String
        /// When the launcher wrote the game's manifest (the file's creation), nil if unknown.
        public var installedAt: Date?
    }

    /// Installed games, one manifest (`<id>.item`, JSON) per installation. Skips manifests of unfinished installs
    /// and add-ons that aren't applications.
    public static func games(in bottle: Bottle) -> [Game] {
        guard launcherPath(in: bottle) != nil, let folder = bottle.unixPath(forWindowsPath: manifestsPath) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        return files.filter { $0.pathExtension.lowercased() == "item" }
            .compactMap { file -> Game? in
                var game = (try? Data(contentsOf: file)).flatMap(parseManifest)
                game?.installedAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return game
            }
            .filter { seen.insert($0.appName).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ data: Data) -> Game? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let appName = json["AppName"] as? String, !appName.isEmpty,
              let name = json["DisplayName"] as? String, !name.isEmpty else { return nil }
        if json["bIsIncompleteInstall"] as? Bool == true { return nil }
        if let isApplication = json["bIsApplication"] as? Bool, !isApplication { return nil }
        let location = (json["InstallLocation"] as? String) ?? ""
        let launch = (json["LaunchExecutable"] as? String) ?? ""
        let executable = location.isEmpty || launch.isEmpty ? "" :
            (location.hasSuffix(#"\"#) ? location : location + #"\"#) + launch.replacingOccurrences(of: "/", with: #"\"#)
        return Game(appName: appName, namespace: (json["CatalogNamespace"] as? String) ?? "",
                    catalogItemID: (json["CatalogItemId"] as? String) ?? "", name: name, executable: executable)
    }

    /// A library entry for an Epic game. The ID is derived from the app name, so it stays the same across scans,
    /// like its date.
    public static func program(for game: Game, in bottle: Bottle) -> Program? {
        guard let launcher = launcherPath(in: bottle) else { return nil }
        // namespace:catalogItemId:appName (":" escaped), the form the launcher's own desktop shortcuts use.
        let id = [game.namespace, game.catalogItemID, game.appName].filter { !$0.isEmpty }.joined(separator: "%3A")
        var program = Program(name: game.name, windowsPath: launcher,
                              arguments: "com.epicgames.launcher://apps/\(id)?action=launch&silent=true", isGame: true)
        program.id = SteamLibrary.stableID(seed: "epic:\(bottle.root.lastPathComponent):\(game.appName)")
        program.addedAt = game.installedAt ?? .distantPast
        return program
    }

    /// The game's icon, taken from its executable once and kept with the bottle's other icons.
    public static func icon(for game: Game, program: Program, in bottle: Bottle) -> URL? {
        let file = bottle.iconFile(for: program)
        if !FileManager.default.fileExists(atPath: file.path), !game.executable.isEmpty, let exe = bottle.unixPath(forWindowsPath: game.executable) {
            bottle.saveIcon(for: program, from: exe)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
