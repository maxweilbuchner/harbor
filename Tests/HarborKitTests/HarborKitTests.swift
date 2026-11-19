import Foundation
import Synchronization
import Testing
@testable import HarborKit

@Suite struct BottleTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "harbor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func settingsRoundTrip() throws {
        let store = BottleStore(directory: try tempDir())
        var b = try store.create(name: "Office Apps")
        b.settings.graphics = .dxmt
        b.settings.environment = ["FOO": "1"]
        try b.save()
        #expect(try Bottle.load(from: b.root) == b)
        #expect(b.root.lastPathComponent == "office-apps")
    }

    @Test func slugsAreUnique() throws {
        let store = BottleStore(directory: try tempDir())
        let a = try store.create(name: "Games")
        let b = try store.create(name: "Games")
        #expect(a.root != b.root)
        #expect(store.list().count == 2)
        #expect(BottleStore.slug(for: "!!!") == "bottle")
    }

    @Test func environmentPointsAtPrefix() throws {
        let store = BottleStore(directory: try tempDir())
        var b = try store.create(name: "Env")
        b.settings.environment = ["WINEDEBUG": "+loaddll"]
        let wine = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent")))
        let env = wine.environment(for: b, base: ["WINEDLLOVERRIDES": "d3d9=n"])
        #expect(env["WINEPREFIX"] == b.prefix.path)
        #expect(env["WINEDEBUG"] == "+loaddll")
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;d3d9=n")
    }

    @Test func installersGoThroughMsiexec() {
        #expect(WineLauncher.arguments(toOpen: URL(filePath: "/x/Setup.MSI")) == ["msiexec", "/i", "/x/Setup.MSI"])
        #expect(WineLauncher.arguments(toOpen: URL(filePath: "/x/game.exe")) == ["start", "/wait", "/unix", "/x/game.exe"])
    }

    @Test func runtimeLocateRejectsInvalidRoots() throws {
        let empty = try tempDir()
        #expect(WineRuntime.locate(environment: ["HARBOR_WINE_ROOT": empty.path], bundle: Bundle(for: Marker.self), devRoot: empty) == nil)
    }
}

final class Marker {}

@Suite struct D3DMetalTests {
    let fm = FileManager.default

    func make(_ url: URL, _ text: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A fake base Wine and a fake redist with the real layout.
    func fixture() throws -> (WineRuntime, D3DMetalRedist, URL) {
        let root = fm.temporaryDirectory.appending(path: "harbor-d3d-\(UUID().uuidString)")
        let wine = root.appending(path: "wine")
        for tool in ["bin/wine", "bin/wineserver"] {
            try make(wine.appending(path: tool), "#!/bin/sh\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.appending(path: tool).path)
        }
        try make(wine.appending(path: "lib/wine/x86_64-unix/d3d12.so"), "wine-d3d12")
        try make(wine.appending(path: "lib/wine/x86_64-unix/ntdll.so"), "ntdll")
        try make(wine.appending(path: "lib/wine/x86_64-windows/d3d12.dll"), "wine-d3d12")

        let lib = root.appending(path: "redist/lib")
        try make(lib.appending(path: "external/libd3dshared.dylib"), "apple-d3dshared")
        try make(lib.appending(path: "external/D3DMetal.framework/Versions/A/D3DMetal"), "apple-framework")
        let plist = lib.appending(path: "external/D3DMetal.framework/Resources/Info.plist")
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "4.0b3"] as NSDictionary).write(to: plist, atomically: true)
        // Like Apple's redist: the unix glue is a relative symlink to libd3dshared.dylib.
        try fm.createDirectory(at: lib.appending(path: "wine/x86_64-unix"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: lib.appending(path: "wine/x86_64-unix/d3d12.so").path,
                                  withDestinationPath: "../../external/libd3dshared.dylib")
        try make(lib.appending(path: "wine/x86_64-windows/d3d12.dll"), "apple-d3d12")
        return (WineRuntime(root: wine), D3DMetalRedist(lib: lib), root)
    }

    @Test func overlayReplacesBuiltinsAndLeavesBaseAlone() throws {
        let (base, redist, root) = try fixture()
        #expect(redist.isValid)
        #expect(redist.version == "4.0b3")
        let overlay = try redist.runtime(basedOn: base, in: root.appending(path: "runtimes"))
        let unix = overlay.root.appending(path: "lib/wine/x86_64-unix")
        // The copied symlink resolves to the overlay's own lib/external.
        #expect(try String(contentsOf: unix.appending(path: "d3d12.so"), encoding: .utf8) == "apple-d3dshared")
        #expect(unix.appending(path: "d3d12.so").resolvingSymlinksInPath().path.hasPrefix(overlay.root.resolvingSymlinksInPath().path))
        #expect(try String(contentsOf: overlay.root.appending(path: "lib/wine/x86_64-windows/d3d12.dll"), encoding: .utf8) == "apple-d3d12")
        #expect(try String(contentsOf: unix.appending(path: "ntdll.so"), encoding: .utf8) == "ntdll")
        #expect(try String(contentsOf: base.root.appending(path: "lib/wine/x86_64-unix/d3d12.so"), encoding: .utf8) == "wine-d3d12")
        #expect(overlay.isValid)
        // Second call reuses the cached runtime.
        #expect(try redist.runtime(basedOn: base, in: root.appending(path: "runtimes")) == overlay)
    }

    @Test func concurrentFirstLaunchesShareOneRuntime() throws {
        let (base, redist, root) = try fixture()
        let runtimes = root.appending(path: "runtimes")
        let results = Mutex<[Result<URL, any Error>]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = Result { try redist.runtime(basedOn: base, in: runtimes).root }
            results.withLock { $0.append(result) }
        }
        let roots = try results.withLock { try $0.map { try $0.get() } }
        #expect(Set(roots).count == 1)
        let leftovers = try fm.contentsOfDirectory(atPath: runtimes.path).filter { $0.hasPrefix(".staging") }
        #expect(leftovers.isEmpty)
    }

    @Test func changedBaseWineGetsAFreshRuntime() throws {
        let (base, redist, root) = try fixture()
        let runtimes = root.appending(path: "runtimes")
        let first = try redist.runtime(basedOn: base, in: runtimes)
        try make(base.root.appending(path: "lib/wine/x86_64-unix/ntdll.so"), "ntdll-updated-build")
        let second = try redist.runtime(basedOn: base, in: runtimes)
        #expect(first != second)
        #expect(D3DMetalRedist.isComplete(first.root)) // the old one is left alone; it may still be in use
    }

    @Test func automaticPicksD3DMetalOnlyWhenInstalled() throws {
        let (base, redist, root) = try fixture()
        let store = BottleStore(directory: root.appending(path: "bottles"))
        let bottle = try store.create(name: "Game")
        let runtimes = root.appending(path: "runtimes")
        #expect(WineLauncher(runtime: base, runtimesDirectory: runtimes).effectiveGraphics(for: bottle) == .wined3d)
        let launcher = WineLauncher(runtime: base, d3dmetal: redist, runtimesDirectory: runtimes)
        #expect(launcher.effectiveGraphics(for: bottle) == .d3dmetal)
        let derived = try launcher.runtime(for: bottle).root
        #expect(derived.deletingLastPathComponent().path(percentEncoded: false) == runtimes.path(percentEncoded: false) + "/",
                "derived \(derived.path) vs \(runtimes.path)")
        var office = try store.create(name: "Office")
        office.settings.graphics = .wined3d
        #expect(try launcher.runtime(for: office) == base)
    }
}
