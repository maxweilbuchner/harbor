import Foundation

/// A Wine build Harbor can launch: a directory containing `bin/wine`, `bin/wineserver` and `lib/wine`.
public struct WineRuntime: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var wine: URL { root.appending(path: "bin/wine") }
    public var wineserver: URL { root.appending(path: "bin/wineserver") }

    /// The development checkout this file was compiled from; only meaningful in dev builds.
    static let checkoutRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    public var isValid: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wine.path) && fm.isExecutableFile(atPath: wineserver.path)
    }

    /// Looks for a runtime in, in order: `$HARBOR_WINE_ROOT`, the app bundle's `Resources/wine`, the development
    /// checkout's own Wine build (`build/out/wine`, from `scripts/build-wine.sh`), and its `Runtime/` folder
    /// (filled by `scripts/fetch-runtime.sh`).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        devRoot: URL? = nil
    ) -> WineRuntime? {
        var candidates: [URL] = []
        if let override = environment["HARBOR_WINE_ROOT"] {
            candidates.append(URL(filePath: override))
        }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: "wine"))
        }
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
        return candidates.lazy.map(WineRuntime.init(root:)).first(where: \.isValid)
    }
}
