import Foundation

/// One-click setup for game stores. Each store gets its own bottle; the games it installs appear in the library
/// (through `SteamLibrary` / `EpicLibrary`) and run on the store's runtime (D3DMetal, since stores count as games).
public struct GameStores: Sendable {
    public enum Step: Sendable, Equatable {
        case downloading
        case preparingWindows
        case installing
    }

    /// A game store Harbor sets up in one click.
    public enum Store: String, Sendable, CaseIterable {
        case steam, epic

        public var name: String { self == .steam ? "Steam" : "Epic Games Store" }
        /// Who the installer comes from, for progress text.
        public var vendor: String { self == .steam ? "Valve" : "Epic Games" }
        var bottleName: String { self == .steam ? "Steam" : "Epic Games" }
        var installerURL: URL {
            switch self {
            // Valve's official installer (32-bit NSIS stub; it downloads the current client on first start).
            case .steam: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
            // Epic's official MSI (redirects to the current EpicInstaller-<version>.msi, about 260 MB).
            case .epic: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
            }
        }
        var installerKind: ProgramAnalysis.Installer { self == .steam ? .nsis : .msi }
        var installerExtension: String { self == .steam ? "exe" : "msi" }
        /// Names for the Dock, Cmd-Tab and the menu bar where an executable's own ProductName is wrong (read by
        /// Harbor's Wine patch 0006): Steam's windows belong to "Steam Client WebHelper", Epic's launcher calls
        /// itself "Unreal Engine".
        var appNames: [String: String] {
            self == .steam ? ["steamwebhelper.exe": "Steam"] : ["EpicGamesLauncher.exe": "Epic Games Launcher"]
        }
        func silentInstall(_ installer: String) -> [String] {
            self == .steam ? [installer, "/S"] : ["msiexec", "/i", installer, "/qn"]
        }
    }

    public let store: BottleStore
    public let launcher: WineLauncher
    public var template: PrefixTemplate?

    public init(store: BottleStore, launcher: WineLauncher, template: PrefixTemplate? = nil) {
        self.store = store
        self.launcher = launcher
        self.template = template ?? PrefixTemplate(launcher: launcher)
    }

    /// The bottle a store is already installed in, if any.
    public func existingBottle(for which: Store) -> Bottle? {
        store.list().first { storeProgram(which, in: $0) != nil }
    }

    /// Downloads and silently installs a store into its own bottle and adds its launcher to that bottle's
    /// library. Returns the existing bottle instead if the store is already set up.
    public func install(_ which: Store, progress: @Sendable (Step) -> Void = { _ in }) async throws -> (Bottle, Program) {
        if let bottle = existingBottle(for: which), let program = storeProgram(which, in: bottle) { return (bottle, program) }
        progress(.downloading)
        let (download, response) = try await URLSession.shared.download(from: which.installerURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let installer = FileManager.default.temporaryDirectory
            .appending(path: "\(which.rawValue)-setup-\(UUID().uuidString).\(which.installerExtension)")
        try FileManager.default.moveItem(at: download, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        guard (try? ProgramAnalysis.analyze(installer))?.installer == which.installerKind else { throw URLError(.cannotDecodeContentData) }

        progress(.preparingWindows)
        let (launcher, template) = (self.launcher, self.template)
        let bottle = try await store.create(name: which.bottleName) { try await launcher.initialize($0, template: template) }
        do {
            progress(.installing)
            try await launcher.execute(bottle, arguments: which.silentInstall(installer.path), label: "\(which.name) setup")
            try await nameWindows(of: which, in: bottle)
            try await launcher.waitForShutdown(bottle)
            guard let program = storeProgram(which, in: bottle) else { throw AddProgram.Failure.installerFoundNothing(name: which.name) }
            try bottle.savePrograms([program])
            return (bottle, program)
        } catch {
            try? launcher.shutdown(bottle)
            try? FileManager.default.removeItem(at: bottle.root)
            throw error
        }
    }

    func storeProgram(_ which: Store, in bottle: Bottle) -> Program? {
        switch which {
        case .steam:
            return SteamLibrary.steamFolder(in: bottle) == nil ? nil : steamProgram(in: bottle)
        case .epic:
            guard let path = EpicLibrary.launcherPath(in: bottle) else { return nil }
            let isLauncher: (Program) -> Bool = { $0.windowsPath.caseInsensitiveCompare(path) == .orderedSame && $0.arguments == nil }
            var program = bottle.programs().first(where: isLauncher) ?? bottle.startMenuPrograms().first(where: isLauncher)
                ?? Program(name: "Epic Games Launcher", windowsPath: path)
            program.isGame = true      // its games inherit its runtime, so it must be the D3DMetal one
            return program
        }
    }

    public func nameWindows(of which: Store, in bottle: Bottle) async throws {
        for (exe, name) in which.appNames.sorted(by: { $0.key < $1.key }) {
            try await launcher.execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine\AppDefaults\"# + exe + #"\Mac Driver"#,
                                                           "/v", "AppName", "/d", name, "/f"], label: "\(which.name) name")
        }
    }

    /// The Steam client as a library entry: from the bottle's library if present, else from its Start Menu.
    /// Always a game: a fresh install holds only the bootstrapper (steam_api etc. arrive with its first update),
    /// and Steam's runtime is what its games inherit, so it must be the D3DMetal one.
    func steamProgram(in bottle: Bottle) -> Program? {
        let isSteam: (Program) -> Bool = { $0.windowsPath.lowercased().hasSuffix(#"\steam.exe"#) && $0.arguments == nil }
        guard var program = bottle.programs().first(where: isSteam) ?? bottle.startMenuPrograms().first(where: isSteam)
        else { return nil }
        program.isGame = true
        return program
    }
}
