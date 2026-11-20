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
    }

    public let id: String
    public let name: String
    public let downloads: [Download]
    /// DLLs set to "native,builtin" after installing.
    public let overrides: [String]
    /// A DLL in system32 that only Microsoft's installer puts there (Wine's copy is built-in).
    public let marker: String

    public static let all: [Recipe] = [vcrun2022, vcrun2013, vcrun2010]

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

    public var description: String {
        switch self {
        case .checksumMismatch(let file): "The download of \(file) didn’t match Microsoft’s published file. Nothing was installed."
        }
    }
}

extension WineLauncher {
    /// Downloads (or reuses from the cache), verifies and silently runs a recipe's installers in `bottle`, then
    /// sets its DLL overrides. Every installer runs (32-bit programs need theirs even when the 64-bit one
    /// failed); the first real failure is thrown afterwards.
    public func install(_ recipe: Recipe, in bottle: Bottle,
                        cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Harbor/Recipes")) async throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let files = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (n, download) in recipe.downloads.enumerated() { group.addTask { (n, try await Self.fetch(download, into: cache)) } }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
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
        for (n, download) in recipe.downloads.enumerated() {
            do {
                let local = try bottle.importForRunning(files[n]!)
                try await execute(bottle, arguments: [bottle.windowsPath(for: local) ?? local.path] + download.arguments, label: recipe.id)
            } catch let error as WineExitError {
                if !Recipe.installerSucceeded(error.status) { failure = failure ?? error }
            }
        }
        if let failure { throw failure }
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
