import CryptoKit
import Foundation

/// Windows components a program may need that Wine doesn't provide in full: Microsoft's own Visual C++
/// runtimes. Installed on request into one bottle, from Microsoft's download servers, hash-checked, silently.
///
/// Wine has built-in versions of these DLLs and keeps preferring them, so a recipe also sets Wine's DLL
/// overrides to "native,builtin" for the DLLs it installs (the same lists winetricks uses); without them
/// installing changes nothing (checked: EpicOnlineServicesHost.exe loads Wine's msvcp140 until the override).
public struct Recipe: Sendable, Identifiable, Equatable {
    public struct Download: Sendable, Equatable {
        public let url: URL
        public let sha256: String
        public let arguments: [String]
        /// A command to run after the download itself, for packages that only unpack (a Windows path and its
        /// arguments).
        public var followUp: [String] = []
        /// The Windows version to present while this installer runs ("winxp64", "win7"), for installers that refuse
        /// newer ones. The bottle's own version is restored afterwards.
        public var windowsVersion: String?
    }

    public let id: String
    public let name: String
    public let downloads: [Download]
    /// DLLs set to "native,builtin" after installing.
    public let overrides: [String]
    /// A DLL in system32 that only Microsoft's installer puts there (Wine's copy is built-in).
    public let marker: String
    /// A folder in the bottle the installation unpacks into, removed afterwards (Windows path).
    public var temporaryFolder: String?
    /// Whether Wine Mono (Wine's own .NET) is uninstalled first: Microsoft's .NET can't share a bottle with it.
    public var replacesWineMono = false
    /// More registry settings, in .reg form (sections only), applied after the installers have run.
    public var registryAfterInstall = ""

    public static let all: [Recipe] = [vcrun2022, vcrun2013, vcrun2010, directx2010, dotnet48]

    /// Microsoft's .NET Framework 4.8 in place of Wine Mono, for programs Mono can't run.
    ///
    /// Three things make it install and keep working (each found by trying it on Harbor's Wine):
    /// - .NET 4.8's installer says "already installed" on Windows 10, where it is part of the system, so Windows 7
    ///   is presented while it runs. It doesn't bring `mscoree.dll` (part of Windows since 7), the entry point of
    ///   every .NET program, so .NET 4.0 is installed first, with Windows XP presented, which does.
    /// - Wine's stand-in for `mscoree.dll` is removed first and overridden, or Microsoft's is never used.
    /// - Wine re-registers `mscoree.dll` with rundll32 on every prefix update. Microsoft's answers that with an
    ///   error dialog nobody sees, and the update waits forever; for rundll32 alone the DLL is therefore disabled.
    ///   Only after the installation: .NET's own installer uses rundll32 with mscoree and fails without it.
    public static let dotnet48 = Recipe(
        id: "dotnet48", name: ".NET Framework 4.8",
        downloads: [
            Download(url: URL(string: "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe")!,
                     sha256: "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f",
                     arguments: ["/q", "/norestart"], windowsVersion: "winxp64"),
            Download(url: URL(string: "https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe")!,
                     sha256: "0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40",
                     arguments: ["/sfxlang:1027", "/q", "/norestart"], windowsVersion: "win7"),
        ],
        overrides: ["mscoree"],
        marker: "mscoree.dll",
        replacesWineMono: true,
        registryAfterInstall: "[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\rundll32.exe\\DllOverrides]\r\n\"mscoree\"=\"\"\r\n")

    /// The DirectX End-User Runtimes of June 2010: the D3DX helper libraries and old shader compilers that games
    /// of the DirectX 9–11 era ship against. Microsoft's package unpacks its cabinets, then its DXSETUP installs
    /// them. Only the helper libraries are switched to Microsoft's versions; controller and audio libraries
    /// (XInput, XAudio2, X3DAudio, XACT) stay Wine's, because Microsoft's need Windows' own drivers.
    public static let directx2010 = Recipe(
        id: "directx2010", name: "DirectX 9–11 Extras (June 2010)",
        downloads: [
            Download(url: URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!,
                     sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b",
                     arguments: ["/Q", #"/T:C:\windows\temp\harbor-directx"#],
                     followUp: [#"C:\windows\temp\harbor-directx\DXSETUP.exe"#, "/silent"]),
        ],
        overrides: (24...43).map { "d3dx9_\($0)" } + ["d3dx10"] + (33...43).map { "d3dx10_\($0)" } + ["d3dx11_42", "d3dx11_43"]
            + (33...43).map { "d3dcompiler_\($0)" },
        marker: "d3dx9_43.dll",
        temporaryFolder: #"C:\windows\temp\harbor-directx"#)

    public static let vcrun2022 = Recipe(
        id: "vcrun2022", name: "Visual C++ 2015–2022",
        downloads: [
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!,
                     sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b", arguments: ["/install", "/quiet", "/norestart"]),
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!,
                     sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64", arguments: ["/install", "/quiet", "/norestart"]),
        ],
        overrides: ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
                    "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"],
        marker: "msvcp140.dll")

    public static let vcrun2013 = Recipe(
        id: "vcrun2013", name: "Visual C++ 2013",
        downloads: [
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/10912041/cee5d6bca2ddbcd039da727bf4acb48a/vcredist_x64.exe")!,
                     sha256: "a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c", arguments: ["/install", "/quiet", "/norestart"]),
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/10912113/5da66ddebb0ad32ebd4b922fd82e8e25/vcredist_x86.exe")!,
                     sha256: "53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd", arguments: ["/install", "/quiet", "/norestart"]),
        ],
        overrides: ["atl120", "msvcp120", "msvcr120", "vcomp120"],
        marker: "msvcr120.dll")

    public static let vcrun2010 = Recipe(
        id: "vcrun2010", name: "Visual C++ 2010",
        downloads: [
            Download(url: URL(string: "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe")!,
                     sha256: "f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3", arguments: ["/q", "/norestart"]),
            Download(url: URL(string: "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe")!,
                     sha256: "99dce3c841cc6028560830f7866c9ce2928c98cf3256892ef8e6cf755147b0d8", arguments: ["/q", "/norestart"]),
        ],
        overrides: ["atl100", "msvcp100", "msvcr100", "vcomp100"],
        marker: "msvcr100.dll")

    public static func named(_ id: String) -> Recipe? { all.first { $0.id == id } }

    /// Whether Microsoft's version is in the bottle (Wine's built-in DLLs say "Wine builtin DLL" in their header).
    public func isInstalled(in bottle: Bottle) -> Bool {
        let dll = bottle.driveC.appending(path: "windows/system32/\(marker)")
        return FileManager.default.fileExists(atPath: dll.path) && !Self.isWineBuiltin(dll)
    }

    /// Deletes Wine's built-in stand-ins for this recipe's DLLs from system32 and syswow64 (only files marked
    /// "Wine builtin DLL"; Microsoft's are never touched). Returns what it removed.
    @discardableResult
    func removeBuiltinCopies(in bottle: Bottle) -> [URL] {
        var removed: [URL] = []
        for folder in ["windows/system32", "windows/syswow64"] {
            for dll in overrides {
                let file = bottle.driveC.appending(path: "\(folder)/\(dll).dll")
                guard Self.isWineBuiltin(file), (try? FileManager.default.removeItem(at: file)) != nil else { continue }
                removed.append(file)
            }
        }
        return removed
    }

    /// Whether an installer's exit status means the component is there: 0, 1638 (this or a newer version is
    /// already installed) and 3010 (installed, wants a restart). A process's status reaches macOS as its low
    /// byte only, so Wine reports those two as 102 and 194.
    public static func installerSucceeded(_ status: Int32) -> Bool {
        [0, 1638, 3010, 1638 & 0xff, 3010 & 0xff].contains(status)
    }

    static func isWineBuiltin(_ dll: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 1024)) ?? Data()).range(of: Data("Wine builtin DLL".utf8)) != nil
    }

    /// The `.reg` file that sets this recipe's DLL overrides.
    var overridesRegistryFile: String {
        "Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n"
            + overrides.map { "\"\($0)\"=\"native,builtin\"\r\n" }.joined()
    }
}

public enum RecipeError: Error, CustomStringConvertible, Equatable {
    case checksumMismatch(String)
    case bottleInUse
    /// A component that replaces Wine Mono failed after Mono was removed (the component's name, and why).
    case leftWithoutDotNet(String, reason: String)

    public var description: String {
        switch self {
        case .leftWithoutDotNet(let name, let reason):
            String(localized: "\(name) couldn’t be installed (\(reason)). Harbor’s built-in .NET was already removed to make room for it, so this program’s Windows environment has no .NET now. Install \(name) again to complete it.", bundle: Strings.bundle)
        case .checksumMismatch(let file): String(localized: "The download of \(file) didn’t match Microsoft’s published file. Nothing was installed.", bundle: Strings.bundle)
        case .bottleInUse: String(localized: "Quit this program, and any installed together with it, before installing this component.", bundle: Strings.bundle)
        }
    }
}

extension WineLauncher {
    /// Downloads (or reuses from the cache), verifies and silently runs a recipe's installers in `bottle`, then
    /// sets its DLL overrides. Every installer runs (32-bit programs need theirs even when the 64-bit one
    /// failed); the first real failure is thrown afterwards. Once the task is cancelled no further installer
    /// starts (a running one is the caller's to end, with `shutdown`).
    public func install(_ recipe: Recipe, in bottle: Bottle,
                        cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Harbor/Recipes")) async throws {
        var monoRemoved = false
        do {
            try await install(recipe, in: bottle, cache: cache, monoRemoved: &monoRemoved)
        } catch where monoRemoved {
            // Wine Mono isn't put back (Harbor has nothing that installs it into an existing bottle): whatever
            // went wrong after it was removed, the message says what the bottle is left with and what helps.
            // (An installer's failure is its status alone: the reason stands in brackets inside a sentence.)
            throw RecipeError.leftWithoutDotNet(recipe.name, reason: (error as? WineExitError).map { "status \($0.status)" }
                                                ?? String(describing: error))
        }
    }

    private func install(_ recipe: Recipe, in bottle: Bottle, cache: URL, monoRemoved: inout Bool) async throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let files = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (n, download) in recipe.downloads.enumerated() { group.addTask { (n, try await Self.fetch(download, into: cache)) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        // Wine Mono goes before anything else changes: its uninstaller needs Wine's own mscoree, which the steps
        // below take away (in the other order the uninstaller hangs).
        if recipe.replacesWineMono {
            // Swapping .NET under a running program can't work, and the wait below would never end.
            // (An idle session lingers for a few seconds after its last program; give it time to end.)
            for _ in 0..<40 where bottle.isRunning() { try await Task.sleep(for: .milliseconds(500)) }
            if bottle.isRunning() { throw RecipeError.bottleInUse }
            try await removeWineMono(from: bottle)
            monoRemoved = true
            // Microsoft's installer fails (1603) in the Wine session that removed Mono: let that session end first.
            try? await waitForShutdown(bottle)
        }
        // Overrides first, then Wine's built-in copies out of the way: Microsoft's installers skip a DLL whose
        // version is newer than theirs, and Wine's msvcr120 claims a newer one than VC++ 2013's. Without the copy
        // in system32, Wine still loads its built-in one from its own folder until the native one arrives.
        let temp = bottle.driveC.appending(path: "windows/temp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let reg = temp.appending(path: "harbor-\(recipe.id).reg")
        try recipe.overridesRegistryFile.write(to: reg, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: reg) }
        try await execute(bottle, arguments: ["reg", "import", #"C:\windows\temp\"# + reg.lastPathComponent], label: recipe.id)
        recipe.removeBuiltinCopies(in: bottle)
        var failure: WineExitError?
        var versionChanged = false
        func present(_ version: String) async throws {
            try await execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine"#, "/v", "Version", "/d", version, "/f"], label: recipe.id)
        }
        for (n, download) in recipe.downloads.enumerated() {
            do {
                try Task.checkCancellation()
                if let version = download.windowsVersion {
                    try await present(version)
                    versionChanged = true
                }
                let local = try bottle.importForRunning(files[n]!)
                try await execute(bottle, arguments: [bottle.windowsPath(for: local) ?? local.path] + download.arguments, label: recipe.id)
                if !download.followUp.isEmpty { try await execute(bottle, arguments: download.followUp, label: recipe.id) }
            } catch let error as WineExitError {
                if !Recipe.installerSucceeded(error.status) { failure = failure ?? error }
            } catch {
                // Anything but an installer's own failure ends the install here (the downloaded file is gone,
                // Wine can't be started). The bottle's Windows version comes back all the same, or every later
                // launch would see the older one.
                if versionChanged { try? await present(bottle.settings.windowsVersion.rawValue) }
                throw error
            }
        }
        if versionChanged { try await present(bottle.settings.windowsVersion.rawValue) }
        if failure == nil, !recipe.registryAfterInstall.isEmpty {
            let after = temp.appending(path: "harbor-\(recipe.id)-after.reg")
            try ("Windows Registry Editor Version 5.00\r\n\r\n" + recipe.registryAfterInstall).write(to: after, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: after) }
            try await execute(bottle, arguments: ["reg", "import", #"C:\windows\temp\"# + after.lastPathComponent], label: recipe.id)
        }
        if let folder = recipe.temporaryFolder.flatMap({ bottle.unixPath(forWindowsPath: $0) }) {
            try? FileManager.default.removeItem(at: folder)
        }
        if let failure { throw failure }
    }

    /// Uninstalls Wine Mono's packages (as `uninstaller --list` names them) from the bottle, without any UI.
    func removeWineMono(from bottle: Bottle) async throws {
        let listing = FileManager.default.temporaryDirectory.appending(path: "harbor-uninstall-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: listing.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: listing) }
        try await execute(bottle, arguments: ["uninstaller", "--list"], label: "components", output: try FileHandle(forWritingTo: listing))
        let text = String(decoding: (try? Data(contentsOf: listing)) ?? Data(), as: UTF8.self)
        for id in Self.wineMonoPackages(inUninstallerList: text) {
            // msiexec, quietly: Wine's `uninstaller --remove` asks in a message box when a package is already gone
            // (removing the runtime takes its support package along), and would wait for a click nobody can give.
            _ = try? await execute(bottle, arguments: ["msiexec", "/x", id, "/qn"], label: "components")
        }
    }

    /// The IDs of Wine Mono's packages in `uninstaller --list` output (`{GUID}|||Wine Mono Runtime`).
    static func wineMonoPackages(inUninstallerList text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 2, parts[1].hasPrefix("Wine Mono"), parts[0].hasPrefix("{"), parts[0].hasSuffix("}") else { return nil }
            return parts[0]
        }
    }

    /// The installer file, from the cache when its hash still matches.
    static func fetch(_ download: Recipe.Download, into cache: URL) async throws -> URL {
        let file = cache.appending(path: "\(download.sha256)-\(download.url.lastPathComponent)")
        if let data = try? Data(contentsOf: file), Self.sha256(data) == download.sha256 { return file }
        let (temp, response) = try await URLSession.shared.download(from: download.url)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        guard Self.sha256(try Data(contentsOf: temp)) == download.sha256 else {
            throw RecipeError.checksumMismatch(download.url.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
