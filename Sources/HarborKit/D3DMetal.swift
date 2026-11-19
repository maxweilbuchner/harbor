import Foundation

/// Apple's D3DMetal redistributable (`/redist/lib` of the Game Porting Toolkit): `external/` holds
/// D3DMetal.framework and libd3dshared.dylib, `wine/` holds the dxgi/d3d10/d3d11/d3d12 builtins that replace Wine's.
///
/// Shipped unmodified for non-commercial use under Apple's GPTK license (§2A(iii), §2C). The license also
/// forbids reverse engineering it (§2D), so Harbor only copies these files, never inspects or patches them.
public struct D3DMetalRedist: Sendable, Equatable {
    public let lib: URL

    public init(lib: URL) {
        self.lib = lib
    }

    public var framework: URL { lib.appending(path: "external/D3DMetal.framework") }
    public var sharedLibrary: URL { lib.appending(path: "external/libd3dshared.dylib") }

    public var version: String? {
        let plist = framework.appending(path: "Resources/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    public var isValid: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: sharedLibrary.path)
            && fm.fileExists(atPath: lib.appending(path: "wine/x86_64-unix/d3d12.so").path)
            && fm.fileExists(atPath: lib.appending(path: "wine/x86_64-windows/d3d12.dll").path)
            && version != nil
    }

    /// Looks in `$HARBOR_D3DMETAL_LIB`, the app bundle's `Resources/d3dmetal/lib`, then the checkout's `Runtime/d3dmetal-*`.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        devRoot: URL? = nil
    ) -> D3DMetalRedist? {
        var candidates: [URL] = []
        if let override = environment["HARBOR_D3DMETAL_LIB"] {
            candidates.append(URL(filePath: override))
        }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: "d3dmetal/lib"))
        }
        let runtimeDir = (devRoot ?? WineRuntime.checkoutRoot).appending(path: "Runtime")
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: runtimeDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("d3dmetal-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for dir in dirs {
            candidates.append(dir.appending(path: "lib"))
            for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                candidates.append(child.appending(path: "lib"))
            }
        }
        return candidates.lazy.map(D3DMetalRedist.init(lib:)).first(where: \.isValid)
    }

    /// Returns a Wine runtime with D3DMetal installed, creating it under `directory` on first use.
    ///
    /// The runtime is an APFS clone of `base` (cheap, copy-on-write) with D3DMetal's builtins copied over Wine's and
    /// `external/` placed at `lib/external`, matching the Game Porting Toolkit layout. Apple ships the unix-side
    /// glue (`d3d12.so`, `dxgi.so`, …) as relative symlinks to `../../external/libd3dshared.dylib`, which resolve
    /// in that layout unchanged.
    ///
    /// Safe to call concurrently from several processes: creation is serialised with a lock file, built in a
    /// unique staging folder that carries its completion marker, and published by an atomic rename. An existing
    /// runtime is never deleted here, because programs may be running from it.
    public func runtime(basedOn base: WineRuntime, in directory: URL) throws -> WineRuntime {
        let fm = FileManager.default
        let key = Self.fingerprint(of: [base.wine, base.root.appending(path: "lib/wine/x86_64-unix/ntdll.so"),
                                        framework.appending(path: "Versions/A/D3DMetal"), sharedLibrary])
        let name = "d3dmetal-\(version ?? "unknown")-\(key)"
        let root = directory.appending(path: name)
        let overlay = WineRuntime(root: root)
        if Self.isComplete(root), overlay.isValid { return overlay }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try withLock(directory.appending(path: ".lock")) {
            if Self.isComplete(root), overlay.isValid { return overlay }
            if fm.fileExists(atPath: root.path) {
                // Incomplete leftover from a crashed build: move it aside rather than delete it.
                try fm.moveItem(at: root, to: directory.appending(path: ".stale-\(UUID().uuidString)"))
            }
            let staging = directory.appending(path: ".staging-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: base.root, to: staging) // clonefile(2) on APFS
                for arch in ["x86_64-unix", "x86_64-windows"] {
                    let source = lib.appending(path: "wine/\(arch)")
                    let destination = staging.appending(path: "lib/wine/\(arch)")
                    for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        let target = destination.appending(path: file.lastPathComponent)
                        try? fm.removeItem(at: target)
                        try fm.copyItem(at: file, to: target)
                    }
                }
                let external = staging.appending(path: "lib/external")
                try? fm.removeItem(at: external)
                try fm.copyItem(at: lib.appending(path: "external"), to: external)
                try removeQuarantine(under: staging)
                try Data((version ?? "").utf8).write(to: staging.appending(path: Self.markerName))
                try fm.moveItem(at: staging, to: root)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            return overlay
        }
    }

    static let markerName = ".harbor-complete"

    static func isComplete(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: markerName).path)
    }

    /// Identifies file contents cheaply by path, size and modification date, so an in-place update of the base Wine
    /// or the redist yields a new derived runtime instead of a stale one.
    static func fingerprint(of files: [URL]) -> String {
        files.map { url -> String in
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.standardizedFileURL.path)|\(size)|\(date)"
        }.joined(separator: "\n").stableHash
    }
}

/// Runs `body` while holding an exclusive `flock` on `lockFile` (shared across processes).
func withLock<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T {
    let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path]) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
    defer { flock(fd, LOCK_UN) }
    return try body()
}

/// Strips `com.apple.quarantine` from a tree Harbor installed itself (after verifying it), so Gatekeeper doesn't
/// re-assess every library Wine loads.
func removeQuarantine(under root: URL) throws {
    let attribute = "com.apple.quarantine"
    removexattr(root.path, attribute, XATTR_NOFOLLOW)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return }
    for case let relative as String in walker {
        removexattr(root.appending(path: relative).path, attribute, XATTR_NOFOLLOW)
    }
}

extension String {
    /// FNV-1a, stable across launches (unlike `hashValue`), for naming cached runtimes.
    var stableHash: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
