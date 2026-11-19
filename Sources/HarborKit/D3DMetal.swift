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
    /// `external/` placed at `lib/external`, matching the Game Porting Toolkit layout. The glue libraries load
    /// libd3dshared.dylib from their own folder (`@rpath` = `@loader_path`), so it is symlinked into `x86_64-unix`.
    public func runtime(basedOn base: WineRuntime, in directory: URL) throws -> WineRuntime {
        let name = "\(base.root.standardizedFileURL.path.stableHash)-d3dmetal-\(version ?? "unknown")"
        let root = directory.appending(path: name)
        let overlay = WineRuntime(root: root)
        let marker = root.appending(path: ".harbor-complete")
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path), overlay.isValid { return overlay }

        try? fm.removeItem(at: root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".\(name).partial")
        try? fm.removeItem(at: staging)
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
        try fm.createSymbolicLink(
            atPath: staging.appending(path: "lib/wine/x86_64-unix/libd3dshared.dylib").path,
            withDestinationPath: "../../external/libd3dshared.dylib")

        try fm.moveItem(at: staging, to: root)
        fm.createFile(atPath: marker.path, contents: Data((version ?? "").utf8))
        return overlay
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
