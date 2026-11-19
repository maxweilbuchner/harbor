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
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/nonexistent/lib:/usr/local/lib:/usr/lib")
    }

    @Test func toleratesUnknownAndMissingSettings() throws {
        let dir = try tempDir().appending(path: "future")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"name":"Future","graphics":"quantum","windowsVersion":"win12","newField":true}"#.utf8)
            .write(to: dir.appending(path: "bottle.json"))
        let b = try Bottle.load(from: dir)
        #expect(b.settings.name == "Future")
        #expect(b.settings.graphics == .automatic)
        #expect(b.settings.windowsVersion == .win10)
        #expect(b.settings.schemaVersion == 1)
    }

    @Test func damagedBottlesAreReportedNotDropped() throws {
        let store = BottleStore(directory: try tempDir())
        _ = try store.create(name: "Good")
        let bad = store.directory.appending(path: "bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appending(path: "bottle.json"))
        let scan = store.scan()
        #expect(scan.bottles.map(\.settings.name) == ["Good"])
        #expect(scan.damaged.map(\.folder.lastPathComponent) == ["bad"])
    }

    @Test func failedSetUpRemovesTheBottle() async throws {
        struct Boom: Error {}
        let store = BottleStore(directory: try tempDir())
        await #expect(throws: Boom.self) {
            _ = try await store.create(name: "Broken") { _ in throw Boom() }
        }
        #expect(store.scan().bottles.isEmpty && store.scan().damaged.isEmpty)
    }

    @Test func userEnvironmentCannotBreakHarbor() throws {
        let store = BottleStore(directory: try tempDir())
        var b = try store.create(name: "Env2")
        b.settings.environment = ["WINEPREFIX": "/elsewhere", "WINEDLLOVERRIDES": "dinput8=n,b"]
        let env = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent"))).environment(for: b, base: [:])
        #expect(env["WINEPREFIX"] == b.prefix.path)
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;dinput8=n,b")
    }

    @Test func installersGoThroughMsiexec() {
        #expect(WineLauncher.arguments(toOpen: URL(filePath: "/x/Setup.MSI")) == ["msiexec", "/i", "/x/Setup.MSI"])
        #expect(WineLauncher.arguments(toOpen: URL(filePath: "/x/game.exe")) == ["start", "/wait", "/unix", "/x/game.exe"])
    }

    @Test func runtimeLocateRejectsInvalidRoots() throws {
        let empty = try tempDir()
        #expect(WineRuntime.locate(environment: ["HARBOR_WINE_ROOT": empty.path], bundle: Bundle(for: Marker.self),
                                    installed: empty, devRoot: empty) == nil)
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

    @Test func d3dmetalOnlyWhenChosenAndInstalled() throws {
        let (base, redist, root) = try fixture()
        let store = BottleStore(directory: root.appending(path: "bottles"))
        var bottle = try store.create(name: "Game")
        let runtimes = root.appending(path: "runtimes")
        let launcher = WineLauncher(runtime: base, d3dmetal: redist, runtimesDirectory: runtimes)
        // Automatic never picks D3DMetal: it is licensed for games only and apps aren't classified yet.
        #expect(launcher.effectiveGraphics(for: bottle) == .wined3d)
        bottle.settings.graphics = .dxmt // not shipped yet
        #expect(launcher.effectiveGraphics(for: bottle) == .wined3d)
        bottle.settings.graphics = .d3dmetal
        #expect(WineLauncher(runtime: base, runtimesDirectory: runtimes).effectiveGraphics(for: bottle) == .wined3d)
        #expect(launcher.effectiveGraphics(for: bottle) == .d3dmetal)
        let derived = try launcher.runtime(for: bottle).root
        #expect(derived.deletingLastPathComponent().path(percentEncoded: false) == runtimes.path(percentEncoded: false) + "/",
                "derived \(derived.path) vs \(runtimes.path)")
        var office = try store.create(name: "Office")
        office.settings.graphics = .wined3d
        #expect(try launcher.runtime(for: office) == base)
    }
}

@Suite struct RosettaTests {
    @Test func intelNeedsNoRosetta() {
        #expect(Rosetta.isAvailable(machine: "x86_64", runtimeExists: false))
        #expect(!Rosetta.isAvailable(machine: "arm64", runtimeExists: false))
        #expect(Rosetta.isAvailable(machine: "arm64", runtimeExists: true))
        #expect(Rosetta.isAvailable) // this Mac has it (Wine runs here)
    }
}

@Suite struct RuntimeInstallerTests {
    let fm = FileManager.default

    /// A served folder with one signed manifest and a wine archive containing `bin/wine` with `contents`.
    func serve(version: String, contents: String, key: String) throws -> (manifest: URL, root: URL) {
        let root = fm.temporaryDirectory.appending(path: "harbor-dl-\(UUID().uuidString)")
        let payload = root.appending(path: "payload")
        try fm.createDirectory(at: payload.appending(path: "bin"), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: payload.appending(path: "bin/wine"))
        let archive = root.appending(path: "wine-\(version).tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", payload.path, "."]
        try tar.run(); tar.waitUntilExit()
        let size = (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let manifest = RuntimeManifest(components: [
            .init(id: "wine", version: version, url: archive.lastPathComponent,
                  sha256: try RuntimeInstaller.sha256(of: archive), size: size)])
        let url = root.appending(path: "runtime.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url)
        try Data(try RuntimeSigning.sign(data, privateKey: key).utf8).write(to: url.appendingPathExtension("sig"))
        return (url, root)
    }

    func installer(_ manifest: URL, key: String, installed: URL) throws -> RuntimeInstaller {
        RuntimeInstaller(manifestURL: manifest, publicKey: try RuntimeSigning.publicKey(try RuntimeSigning.publicKey(forPrivate: key)),
                         installedDirectory: installed)
    }

    @Test func installsVerifiedComponentAndSkipsCurrentOnes() async throws {
        let key = RuntimeSigning.newPrivateKey()
        let (manifestURL, root) = try serve(version: "1", contents: "wine v1", key: key)
        let installed = root.appending(path: "installed")
        let inst = try installer(manifestURL, key: key, installed: installed)
        let manifest = try await inst.fetchManifest()
        #expect(inst.pending(in: manifest).map(\.id) == ["wine"])
        let fractions = Mutex<[Double]>([])
        try await inst.installPending(manifest) { f in fractions.withLock { $0.append(f) } }
        #expect(try String(contentsOf: installed.appending(path: "wine/bin/wine"), encoding: .utf8) == "wine v1")
        #expect(inst.installedVersion(of: "wine") == "1")
        #expect(inst.pending(in: manifest).isEmpty)
        #expect(fractions.withLock { $0.last } == 1)
    }

    @Test func updateMovesOldVersionAside() async throws {
        let key = RuntimeSigning.newPrivateKey()
        let (m1, root) = try serve(version: "1", contents: "wine v1", key: key)
        let installed = root.appending(path: "installed")
        let first = try installer(m1, key: key, installed: installed)
        try await first.installPending(try await first.fetchManifest())
        let (m2, _) = try serve(version: "2", contents: "wine v2", key: key)
        let second = try installer(m2, key: key, installed: installed)
        try await second.installPending(try await second.fetchManifest())
        #expect(try String(contentsOf: installed.appending(path: "wine/bin/wine"), encoding: .utf8) == "wine v2")
        let names = try fm.contentsOfDirectory(atPath: installed.path)
        #expect(names.contains { $0.hasPrefix(".old-wine-") })
        second.removeOldVersions()
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".old-") })
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".staging-") })
    }

    @Test func rejectsWrongKeyAndTamperedManifest() async throws {
        let key = RuntimeSigning.newPrivateKey()
        let (manifestURL, root) = try serve(version: "1", contents: "x", key: key)
        let impostor = try installer(manifestURL, key: RuntimeSigning.newPrivateKey(), installed: root.appending(path: "i"))
        await #expect(throws: RuntimeInstallError.badSignature) { _ = try await impostor.fetchManifest() }
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\":\"1\"", with: "\"version\":\"9\"")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        let honest = try installer(manifestURL, key: key, installed: root.appending(path: "i"))
        await #expect(throws: RuntimeInstallError.badSignature) { _ = try await honest.fetchManifest() }
    }

    @Test func rejectsDamagedArchiveAndUnknownComponents() async throws {
        let key = RuntimeSigning.newPrivateKey()
        let (manifestURL, root) = try serve(version: "1", contents: "x", key: key)
        let installed = root.appending(path: "installed")
        let inst = try installer(manifestURL, key: key, installed: installed)
        var component = try await inst.fetchManifest().components[0]
        try Data("corrupted".utf8).write(to: root.appending(path: component.url))
        await #expect(throws: RuntimeInstallError.checksumMismatch(component: "wine")) { try await inst.install(component) }
        #expect(!fm.fileExists(atPath: installed.appending(path: "wine").path))
        component.id = "../../evil"
        await #expect(throws: RuntimeInstallError.invalidComponent("../../evil")) { try await inst.install(component) }
    }
}
