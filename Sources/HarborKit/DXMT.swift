import Foundation

/// DXMT (CodeWeavers' open-source Direct3D 10/11 → Metal layer), shipped inside Harbor's Wine runtime under
/// `lib/dxmt/` (scripts/build-wine.sh): d3d11, d3d10core, dxgi and winemetal for both architectures, plus
/// `winemetal.so` for Wine's Unix side.
///
/// It's for Direct3D 10/11 programs that aren't games (games get D3DMetal): Wine's own D3D11 on MoltenVK stops at
/// feature level 9.3, so shader model 5 programs fail there (WindowsTests/graphics: wined3d fails d3d11tri, DXMT
/// passes it). Its dxgi replaces Wine's, which Wine's Direct3D 12 (vkd3d) needs, so it's never used for D3D12.
public struct DXMT: Sendable, Equatable {
    public let lib: URL

    /// DXMT inside `runtime`, if the runtime ships it.
    public static func locate(in runtime: WineRuntime) -> DXMT? {
        let dxmt = DXMT(lib: runtime.root.appending(path: "lib/dxmt"))
        return dxmt.isValid ? dxmt : nil
    }

    var isValid: Bool {
        let fm = FileManager.default
        return ["x86_64-unix/winemetal.so", "x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll", "i386-windows/d3d11.dll"]
            .allSatisfy { fm.fileExists(atPath: lib.appending(path: $0).path) }
    }

    public var version: String {
        (try? String(contentsOf: lib.appending(path: "VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// Folder name of the derived runtime for `base`; changes whenever Wine or DXMT does.
    public func runtimeName(basedOn base: WineRuntime) -> String {
        let unix = base.root.appending(path: "lib/wine/x86_64-unix")
        let key = D3DMetalRedist.fingerprint(of: [base.wine, unix.appending(path: "ntdll.so"), unix.appending(path: "win32u.so"),
                                                  unix.appending(path: "winemac.so"), lib.appending(path: "x86_64-unix/winemetal.so"),
                                                  lib.appending(path: "x86_64-windows/d3d11.dll")])
        return "dxmt-\(version)-\(key)"
    }

    /// Gives `bottle` the entry for DXMT's winemetal.dll that Wine's setup gives every built-in DLL (a copy in
    /// system32/syswow64): DXMT's d3d11 and dxgi import it, and Wine won't load a built-in the prefix doesn't list.
    /// Bottles set up on a runtime with DXMT get it from wineboot; older ones get it here.
    public func prepare(_ bottle: Bottle) throws {
        let fm = FileManager.default
        for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let target = bottle.driveC.appending(path: "windows/\(folder)/winemetal.dll")
            guard fm.fileExists(atPath: target.deletingLastPathComponent().path), !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: lib.appending(path: "\(arch)/winemetal.dll"), to: target)
        }
    }

    /// A Wine runtime with DXMT's builtins over Wine's, created under `directory` on first use.
    public func runtime(basedOn base: WineRuntime, in directory: URL) throws -> WineRuntime {
        try derivedRuntime(named: runtimeName(basedOn: base), basedOn: base, in: directory, marker: version) { staging in
            let fm = FileManager.default
            for arch in ["x86_64-unix", "x86_64-windows", "i386-windows"] {
                let destination = staging.appending(path: "lib/wine/\(arch)")
                for file in try fm.contentsOfDirectory(at: lib.appending(path: arch), includingPropertiesForKeys: nil) {
                    let target = destination.appending(path: file.lastPathComponent)
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: file, to: target)
                }
            }
        }
    }
}
