import Foundation

/// One-click setup for game stores. Steam gets its own bottle; the games it installs appear in the library
/// through `SteamLibrary` and run on Steam's runtime (D3DMetal, since Steam counts as a game).
public struct GameStores: Sendable {
    public enum Step: Sendable, Equatable {
        case downloading
        case preparingWindows
        case installing
    }

    /// Valve's official installer (32-bit NSIS stub; it downloads the current client on first start).
    public static let steamInstallerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    public let store: BottleStore
    public let launcher: WineLauncher
    public var template: PrefixTemplate?

    public init(store: BottleStore, launcher: WineLauncher, template: PrefixTemplate? = nil) {
        self.store = store
        self.launcher = launcher
        self.template = template ?? PrefixTemplate(launcher: launcher)
    }

    /// The bottle Steam is already installed in, if any.
    public func existingSteamBottle() -> Bottle? {
        store.list().first { SteamLibrary.steamFolder(in: $0) != nil }
    }

    /// Downloads and silently installs Steam into a new "Steam" bottle and adds it to that bottle's library.
    /// Returns the existing bottle instead if Steam is already set up.
    public func installSteam(progress: @Sendable (Step) -> Void = { _ in }) async throws -> (Bottle, Program) {
        if let bottle = existingSteamBottle(), let program = steamProgram(in: bottle) { return (bottle, program) }
        progress(.downloading)
        let (download, response) = try await URLSession.shared.download(from: Self.steamInstallerURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let installer = FileManager.default.temporaryDirectory.appending(path: "SteamSetup-\(UUID().uuidString).exe")
        try FileManager.default.moveItem(at: download, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        guard (try? ProgramAnalysis.analyze(installer))?.installer == .nsis else { throw URLError(.cannotDecodeContentData) }

        progress(.preparingWindows)
        let (launcher, template) = (self.launcher, self.template)
        let bottle = try await store.create(name: "Steam") { try await launcher.initialize($0, template: template) }
        do {
            progress(.installing)
            try await launcher.execute(bottle, arguments: [installer.path, "/S"], label: "Steam setup")
            try await nameSteamWindows(in: bottle)
            try await launcher.waitForShutdown(bottle)
            guard let program = steamProgram(in: bottle) else { throw AddProgram.Failure.installerFoundNothing(name: "Steam") }
            try bottle.savePrograms([program])
            return (bottle, program)
        } catch {
            try? launcher.shutdown(bottle)
            try? FileManager.default.removeItem(at: bottle.root)
            throw error
        }
    }

    /// Steam's windows belong to steamwebhelper.exe ("Steam Client WebHelper"); show them as "Steam" in the Dock,
    /// Cmd-Tab and the menu bar (read by Harbor's Wine patch 0006).
    public func nameSteamWindows(in bottle: Bottle) async throws {
        try await launcher.execute(bottle, arguments: ["reg", "add", Self.steamWebHelperKey, "/v", "AppName", "/d", "Steam", "/f"],
                                   label: "Steam name")
    }

    static let steamWebHelperKey = #"HKCU\Software\Wine\AppDefaults\steamwebhelper.exe\Mac Driver"#

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
