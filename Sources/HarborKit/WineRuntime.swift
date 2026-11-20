import Foundation

/// A Wine build Harbor can launch: a directory containing `bin/wine`, `bin/wineserver` and `lib/wine`.
public struct WineRuntime: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var wine: URL { root.appending(path: "bin/wine") }
    public var wineserver: URL { root.appending(path: "bin/wineserver") }

    /// Where Harbor installs runtimes it downloads: `~/Library/Application Support/Harbor/Installed`.
    public static var installedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Harbor/Installed")
    }

    /// The development checkout this file was compiled from; only meaningful in dev builds.
    public static let checkoutRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Whether this Wine starts at all (`wine --version` exits 0 within `timeout` seconds). Used to prove a freshly
    /// installed runtime before the previous one is given up.
    public func starts(timeout: TimeInterval = 60) -> Bool {
        let process = Process()
        process.executableURL = wine
        process.arguments = ["--version"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = root.appending(path: "lib").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }

    public var isValid: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wine.path) && fm.isExecutableFile(atPath: wineserver.path)
    }

    /// Looks for a runtime in, in order: `$HARBOR_WINE_ROOT`, the app bundle's `Resources/wine`, Harbor's installed
    /// runtime (`installedDirectory/wine`), the development
    /// checkout's own Wine build (`build/out/wine`, from `scripts/build-wine.sh`), and its `Runtime/` folder
    /// (filled by `scripts/fetch-runtime.sh`).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        installed: URL = WineRuntime.installedDirectory,
        devRoot: URL? = nil
    ) -> WineRuntime? {
        var candidates: [URL] = []
        if let override = environment["HARBOR_WINE_ROOT"] {
            candidates.append(URL(filePath: override))
        }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: "wine"))
        }
        // Installed by Harbor (the runtime downloader's target), ahead of anything development-only.
        candidates.append(installed.appending(path: "wine"))
        #if DEBUG
        // Development only: a shipped (release) app must never pick up a build folder compiled into it.
        // Harbor's own build from CodeWeavers' LGPL sources (scripts/build-wine.sh) wins over downloaded ones.
        candidates.append((devRoot ?? checkoutRoot).appending(path: "build/out/wine"))
        let runtimeDir = (devRoot ?? checkoutRoot).appending(path: "Runtime")
        if let entries = try? FileManager.default.contentsOfDirectory(at: runtimeDir, includingPropertiesForKeys: nil) {
            for dir in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            where dir.lastPathComponent.hasPrefix("wine-") {
                if let app = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) {
                    candidates.append(app.appending(path: "Contents/Resources/wine"))
                }
            }
        }
        #endif
        return candidates.lazy.map(WineRuntime.init(root:)).first(where: \.isValid)
    }
}
