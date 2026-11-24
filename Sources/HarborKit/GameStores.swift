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
        /// Where the installer may come from once redirects are followed: the vendor's domains with their
        /// subdomains, and single hosts by exact name. Epic's link ends on its Akamai host; `akamaized.net`
        /// itself is shared by Akamai's customers, so only that one name counts.
        var downloadSources: (domains: [String], hosts: [String]) {
            self == .steam ? (["steamstatic.com"], []) : (["epicgames.com"], ["epicgames-download1.akamaized.net"])
        }

        /// Whether a download that ended at `url` may be run as this store's installer. The vendors replace
        /// these files as they please, so no checksum can be pinned as the components' recipes do; that the
        /// file came over HTTPS from the vendor's own host is the protection there is.
        func trustsDownload(from url: URL?) -> Bool {
            guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
            let (domains, hosts) = downloadSources
            return hosts.contains(host) || domains.contains { host == $0 || host.hasSuffix("." + $0) }
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

    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The installer's download ended somewhere other than the vendor's servers.
        case untrustedDownload(Store, host: String)

        public var description: String {
            switch self {
            case .untrustedDownload(let store, let host):
                "The \(store.name) installer came from \(host), not from \(store.vendor). Harbor didn’t run it."
            }
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
    /// `created` and cancelling the task: as for `AddProgram.add`; a cancelled install leaves no bottle.
    public func install(_ which: Store, progress: @Sendable (Step) -> Void = { _ in },
                        created: @Sendable (Bottle) -> Void = { _ in }) async throws -> (Bottle, Program) {
        if let bottle = existingBottle(for: which), let program = storeProgram(which, in: bottle) { return (bottle, program) }
        progress(.downloading)
        let (download, response) = try await URLSession.shared.download(from: which.installerURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        // The installer runs unattended in the bottle: not one that a redirect fetched from somewhere else.
        guard which.trustsDownload(from: response.url) else {
            try? FileManager.default.removeItem(at: download)
            throw Failure.untrustedDownload(which, host: response.url?.host() ?? "an unknown server")
        }
        let installer = FileManager.default.temporaryDirectory
            .appending(path: "\(which.rawValue)-setup-\(UUID().uuidString).\(which.installerExtension)")
        try FileManager.default.moveItem(at: download, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        guard (try? ProgramAnalysis.analyze(installer))?.installer == which.installerKind else { throw URLError(.cannotDecodeContentData) }

        progress(.preparingWindows)
        let (launcher, template) = (self.launcher, self.template)
        // Claimed like a bottle `AddProgram` is adding to, or `adoptUnrecorded` would take it for one left behind.
        var release: @Sendable () -> Void = {}
        defer { release() }
        let bottle = try await store.create(name: which.bottleName) {
            release = $0.claim()
            created($0)
            try await launcher.initialize($0, template: template)
        }
        do {
            try Task.checkCancellation()
            progress(.installing)
            let local = try bottle.importForRunning(installer)     // Wine can't run it from the Mac's temp folder
            try await launcher.execute(bottle, arguments: which.silentInstall(bottle.windowsPath(for: local) ?? local.path),
                                       label: "\(which.name) setup")
            try await nameWindows(of: which, in: bottle)
            try await launcher.waitForShutdown(bottle)
            try Task.checkCancellation()
            bottle.clearImports()
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
