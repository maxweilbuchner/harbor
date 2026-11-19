import Foundation
import ImageIO
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

@Suite struct ProgramAnalysisTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "exe"))
    }

    @Test func readsA64BitApp() throws {
        let a = try ProgramAnalysis.analyze(try fixture("app64"))
        #expect(a.architecture == .x64)
        #expect(a.isGUI)
        #expect(a.imports.contains("user32.dll"))
        #expect(a.direct3D == nil)
        #expect(!a.looksLikeGame)
        #expect(a.productName == "Fixture App")
        #expect(a.companyName == "Harbor Test Fixtures")
        #expect(a.productVersion == "2.5.0.1")
        #expect(a.installer == nil)
        #expect(a.displayName(fallback: URL(filePath: "/x/app64.exe")) == "Fixture App")
    }

    @Test func recognisesADirectX11Game() throws {
        let a = try ProgramAnalysis.analyze(try fixture("game64"))
        #expect(a.imports.isSuperset(of: ["d3d11.dll", "dxgi.dll"]))
        #expect(a.direct3D == 11)
        #expect(a.looksLikeGame)
        #expect(a.productName == "Fixture Game")
    }

    @Test func reads32BitPrograms() throws {
        let a = try ProgramAnalysis.analyze(try fixture("app32"))
        #expect(a.architecture == .x86)
        #expect(a.productName == "Fixture App 32")
    }

    @Test func extractsTheLargestIcon() throws {
        let png = try #require(try ProgramAnalysis.analyze(try fixture("app64")).iconPNG)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 48)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // The fixture icon: teal background with a white diagonal band through the centre.
        let rgba = try #require(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow
        let centre = rgba[(24 * row) + 24 * 4 ..< (24 * row) + 24 * 4 + 3]
        #expect(Array(centre) == [255, 255, 255])
    }

    @Test func rejectsDamagedFilesWithoutCrashing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "harbor-pe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let random = dir.appending(path: "random.exe")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: random)
        #expect(throws: (any Error).self) { try ProgramAnalysis.analyze(random) }
        // Every truncation of a real program either parses partially or throws; none may crash.
        let real = try Data(contentsOf: try fixture("game64"))
        for length in stride(from: 0, to: real.count, by: 997) {
            let cut = dir.appending(path: "cut.exe")
            try real.prefix(length).write(to: cut)
            _ = try? ProgramAnalysis.analyze(cut)
        }
    }

    /// A PE whose resource tree repeats 65535-entry directories pointing at themselves: the walk must stay bounded.
    @Test func hostileResourceTreesAreBounded() throws {
        var pe = try Data(contentsOf: try #require(Bundle.module.url(forResource: "app64", withExtension: "exe")))
        let file = try #require(PEFile(pe))
        let (rva, _) = try #require(file.directory(2))
        let root = try #require(file.offset(ofRVA: rva))
        func put16(_ v: UInt16, _ at: Int) { pe[at] = UInt8(v & 0xFF); pe[at + 1] = UInt8(v >> 8) }
        func put32(_ v: UInt32, _ at: Int) { for i in 0..<4 { pe[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        put16(0, root + 12); put16(0xFFFF, root + 14)
        // First entries: type 3 (RT_ICON) and 14, both subdirectories pointing back at the root.
        for i in 0..<64 where root + 24 + i * 8 <= pe.count {
            put32(i % 2 == 0 ? 3 : 14, root + 16 + i * 8); put32(0x8000_0000, root + 20 + i * 8)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "hostile-\(UUID().uuidString).exe")
        try pe.write(to: url)
        let start = Date()
        _ = try? ProgramAnalysis.analyze(url)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    static let heavenInstaller = WineRuntime.checkoutRoot.appending(path: "build/games/Unigine_Heaven-4.0.exe")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: heavenInstaller.path)))
    func detectsInnoSetupInstallers() throws {
        let a = try ProgramAnalysis.analyze(Self.heavenInstaller)
        #expect(a.installer == .innoSetup)
        #expect(a.architecture == .x86)
    }
}

@Suite struct ProgramsTests {
    let fm = FileManager.default

    /// Writes a minimal Shell Link with LinkInfo (local base path) and Unicode working dir + arguments.
    static func link(target: String, arguments: String? = nil, workingDirectory: String? = nil) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        var flags = 0x2 | 0x80
        if workingDirectory != nil { flags |= 0x10 }
        if arguments != nil { flags |= 0x20 }
        var d = u32(0x4C) + [UInt8](repeating: 0, count: 16) + u32(flags) + [UInt8](repeating: 0, count: 0x4C - 0x18)
        let base = Array(target.utf8) + [0]
        let header = 28
        let info = u32(header + base.count + 1) + u32(header) + u32(1) + u32(0) + u32(header) + u32(0)
            + u32(header + base.count) + base + [0]
        d += info
        for s in [workingDirectory, arguments].compactMap({ $0 }) {
            let units = Array(s.utf16)
            d += u16(units.count) + units.flatMap { u16(Int($0)) }
        }
        return Data(d)
    }

    @Test func parsesShellLinks() {
        let l = ShellLink(Self.link(target: #"C:\Games\Thing\thing.exe"#, arguments: #"-windowed "a b""#,
                                    workingDirectory: #"C:\Games\Thing"#))
        #expect(l == ShellLink(target: #"C:\Games\Thing\thing.exe"#, arguments: #"-windowed "a b""#,
                               workingDirectory: #"C:\Games\Thing"#))
        #expect(ShellLink(Data("not a link".utf8)) == nil)
        let real = Self.link(target: #"C:\x.exe"#)
        for n in 0..<real.count { _ = ShellLink(real.prefix(n)) }   // truncations never crash
    }

    @Test func dropsLeadingVerbsFromShortcutNames() {
        #expect(Bottle.libraryName(fromShortcut: "Run Superposition Benchmark") == "Superposition Benchmark")
        #expect(Bottle.libraryName(fromShortcut: "Play") == "Play")
        #expect(Bottle.libraryName(fromShortcut: "Startup Manager") == "Startup Manager")
    }

    @Test func splitsArgumentsLikeWindows() {
        #expect(WineLauncher.splitArguments(#"-a  "b c" d"#) == ["-a", "b c", "d"])
        #expect(WineLauncher.splitArguments("") == [])
        #expect(WineLauncher.splitArguments(#""""#) == [""])
    }

    func bottle() throws -> Bottle {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-prog-\(UUID().uuidString)"))
        return try store.create(name: "Programs")
    }

    @Test func findsStartMenuProgramsAndSkipsUninstallers() throws {
        let b = try bottle()
        let app = b.driveC.appending(path: "Program Files/Thing")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "game64", withExtension: "exe"))
        try fm.copyItem(at: fixture, to: app.appending(path: "Thing.exe"))
        try Data().write(to: app.appending(path: "unins000.exe"))
        let menu = b.driveC.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs/Thing")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        // Windows paths are case-insensitive; the shortcut uses different case than the folders.
        try Self.link(target: #"C:\PROGRAM FILES\thing\thing.exe"#).write(to: menu.appending(path: "Thing.lnk"))
        try Self.link(target: #"C:\Program Files\Thing\unins000.exe"#).write(to: menu.appending(path: "Uninstall Thing.lnk"))
        try Self.link(target: #"C:\Program Files\Thing\missing.exe"#).write(to: menu.appending(path: "Gone.lnk"))
        let programs = b.startMenuPrograms()
        #expect(programs.map(\.name) == ["Thing"])
        #expect(programs.first?.isGame == true)
        #expect(b.unixPath(forWindowsPath: #"c:\program files\THING\Thing.exe"#)?.lastPathComponent == "Thing.exe")
        #expect(b.unixPath(forWindowsPath: #"C:\..\etc\passwd"#) == nil)
        #expect(b.unixPath(forWindowsPath: #"D:\x.exe"#) == nil)
        try b.savePrograms(programs)
        #expect(b.programs() == programs)
    }

    @Test func readsLibrariesWrittenByNewerVersions() throws {
        let b = try bottle()
        let good = Program(name: "Good", windowsPath: #"C:\g.exe"#)
        try b.savePrograms([good])
        var text = try String(contentsOf: b.programsFile, encoding: .utf8)
        text = text.replacingOccurrences(of: "[", with: #"[{"id":"not-a-uuid"},{"id":"\#(UUID().uuidString)","name":"Future","windowsPath":"C:\\f.exe","graphics":"quantum","newField":1},"#)
        try text.write(to: b.programsFile, atomically: true, encoding: .utf8)
        let programs = b.programs()
        #expect(programs.map(\.name) == ["Future", "Good"])
        #expect(programs.first?.graphics == nil)
        #expect(!b.programsFileIsDamaged)
        try Data("garbage".utf8).write(to: b.programsFile)
        #expect(b.programsFileIsDamaged)
    }

    @Test func picksD3DMetalPerLaunchForGamesIncludingTheirLaunchers() throws {
        let fakeRedist = D3DMetalRedist(lib: URL(filePath: "/nonexistent"))
        let withD3DMetal = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/x")), d3dmetal: fakeRedist)
        let without = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/x")))
        var p = Program(name: "G", windowsPath: #"C:\g.exe"#, isGame: true)
        #expect(withD3DMetal.effectiveGraphics(for: p) == .d3dmetal)
        #expect(without.effectiveGraphics(for: p) == .wined3d)
        p.isGame = false
        #expect(withD3DMetal.effectiveGraphics(for: p) == .wined3d)      // licence: games only
        p.isGame = true; p.graphics = .wined3d
        #expect(withD3DMetal.effectiveGraphics(for: p) == .wined3d)      // user override
    }

    @Test func aLauncherNextToAGameCountsAsAGame() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-launcher-\(UUID().uuidString)/bin")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        let game = try #require(Bundle.module.url(forResource: "game64", withExtension: "exe"))
        try fm.copyItem(at: app, to: dir.appending(path: "launcher.exe"))
        #expect(!Bottle.looksLikeGame(dir.appending(path: "launcher.exe")))
        try fm.copyItem(at: game, to: dir.appending(path: "engine.exe"))
        #expect(Bottle.looksLikeGame(dir.appending(path: "launcher.exe")))
    }

    static let heavenBottle = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Harbor/Bottles/heaven")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: heavenBottle.appending(path: "bottle.json").path)))
    func findsHeavenInARealBottle() throws {
        let programs = try Bottle.load(from: Self.heavenBottle).startMenuPrograms()
        #expect(programs.map(\.name) == ["Heaven Benchmark 4.0"])
        #expect(programs.first?.windowsPath.hasSuffix(#"\heaven.bat"#) == true)
    }
}

@Suite struct AddProgramTests {
    func analysis(product: String) -> ProgramAnalysis {
        var a = ProgramAnalysis(architecture: .x64, isGUI: true, imports: [])
        a.productName = product
        return a
    }

    @Test func namesBottlesAfterTheProduct() {
        let f = URL(filePath: "/x/ThingSetup.exe")
        #expect(AddProgram.bottleName(for: analysis(product: "Thing Setup 2.1.0"), file: f) == "Thing")
        #expect(AddProgram.bottleName(for: analysis(product: "Big_Game Installer x64"), file: f) == "Big Game")
        #expect(AddProgram.bottleName(for: analysis(product: "Setup"), file: f) == "ThingSetup")
        #expect(AddProgram.safeFolderName(#"A: "B"/C?."#) == "A- -B--C-")
    }

    @Test func neverCopiesSharedFoldersIntoABottle() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for shared in ["Downloads", "Desktop", "Documents", ""] {
            #expect(AddProgram.isSharedFolder(home.appending(path: shared)), "\(shared)")
        }
        #expect(AddProgram.isSharedFolder(URL(filePath: "/Volumes/USB")))
        #expect(AddProgram.isSharedFolder(URL(filePath: "/Applications")))
        #expect(!AddProgram.isSharedFolder(home.appending(path: "Downloads/SomeGame")))
        #expect(!AddProgram.isSharedFolder(URL(filePath: "/Volumes/USB/Games/Thing")))
    }

    @Test func mapsMacPathsBackToWindowsPaths() throws {
        let store = BottleStore(directory: FileManager.default.temporaryDirectory.appending(path: "harbor-add-\(UUID().uuidString)"))
        let b = try store.create(name: "Paths")
        #expect(b.windowsPath(for: b.driveC.appending(path: "Program Files/A/a.exe")) == #"C:\Program Files\A\a.exe"#)
        #expect(b.windowsPath(for: URL(filePath: "/etc/passwd")) == nil)
    }
}

@Suite struct PrefixTemplateTests {
    let fm = FileManager.default

    @Test func clonesGiveEachBottleItsOwnMachineIDAndVersion() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-tpl-\(UUID().uuidString)")
        let launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")))
        let template = PrefixTemplate(launcher: launcher, directory: base.appending(path: "templates"))
        let store = BottleStore(directory: base.appending(path: "bottles"))

        var early = try store.create(name: "Early")
        #expect(try template.clone(into: early) == false)              // not built yet: caller falls back

        try fm.createDirectory(at: template.prefix.appending(path: "drive_c"), withIntermediateDirectories: true)
        try #"[Software\\Microsoft\\Cryptography] 1"# .appending("\n\"MachineGuid\"=\"aaaaaaaa-0000-0000-0000-000000000000\"\n")
            .write(to: template.prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try "[Software\\\\Wine] 1\n\"Version\"=\"win10\"\n"
            .write(to: template.prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        try Data().write(to: template.root.appending(path: D3DMetalRedist.markerName))
        #expect(template.isReady)

        early.settings.windowsVersion = .win7
        #expect(try template.clone(into: early))
        let a = try String(contentsOf: early.prefix.appending(path: "system.reg"), encoding: .utf8)
        #expect(!a.contains("aaaaaaaa-0000"))
        #expect(try String(contentsOf: early.prefix.appending(path: "user.reg"), encoding: .utf8).contains(#""Version"="win7""#))
        let other = try store.create(name: "Other")
        #expect(try template.clone(into: other))
        let b = try String(contentsOf: other.prefix.appending(path: "system.reg"), encoding: .utf8)
        #expect(a != b)                                                 // distinct machine IDs
        #expect(try String(contentsOf: other.prefix.appending(path: "user.reg"), encoding: .utf8).contains(#""Version"="win10""#))
        #expect(fm.fileExists(atPath: other.driveC.path))
    }
}

@Suite struct AppShortcutsTests {
    let fm = FileManager.default

    func icon() throws -> URL {
        let exe = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        let png = try #require(try ProgramAnalysis.analyze(exe).iconPNG)
        let url = fm.temporaryDirectory.appending(path: "harbor-icon-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    @Test func createsASignedShortcutThatOpensHarbor() throws {
        let shortcuts = AppShortcuts(directory: fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)"))
        let program = Program(name: "Thing: Deluxe", windowsPath: #"C:\t.exe"#, isGame: true)
        let app = try shortcuts.create(for: program, iconPNG: try icon())
        #expect(app.lastPathComponent == "Thing- Deluxe.app")
        let plist = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == "Thing: Deluxe")
        #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(fm.fileExists(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path))
        let script = try String(contentsOf: app.appending(path: "Contents/MacOS/launch"), encoding: .utf8)
        #expect(!script.contains("Thing"))                                  // no names in the script
        #expect(try String(contentsOf: app.appending(path: "Contents/Resources/harbor-shortcut"), encoding: .utf8)
                == program.id.uuidString)
        #expect(fm.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/launch").path))
        let verify = Process()
        verify.executableURL = URL(filePath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", app.path]
        try verify.run(); verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
        // Directory URLs from contentsOfDirectory carry a trailing slash; compare the bundle names.
        #expect(shortcuts.existing().mapValues(\.lastPathComponent) == [program.id: app.lastPathComponent])
    }

    @Test func namesCannotCarryControlCharacters() {
        #expect(Program.cleanName("Notes\ntouch /tmp/PWNED\n: ") == "Notes touch /tmp/PWNED :")
        #expect(Program.cleanName("\u{1B}[31mRed\t Game ") == "[31mRed Game")
        #expect(Program.cleanName("\n\n") == "Windows Program")
        #expect(Program(name: "A\nB", windowsPath: #"C:\a.exe"#).name == "A B")
    }

    @Test func sameNamedProgramsKeepTheirShortcuts() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        let a = Program(name: "Steam", windowsPath: #"C:\a.exe"#), b = Program(name: "Steam", windowsPath: #"C:\b.exe"#)
        shortcuts.sync([a, b]) { _ in nil }
        let first = try fm.attributesOfItem(atPath: dir.appending(path: "Steam 2.app").path)[.systemFileNumber] as? Int
        shortcuts.sync([a, b]) { _ in nil }
        let second = try fm.attributesOfItem(atPath: dir.appending(path: "Steam 2.app").path)[.systemFileNumber] as? Int
        #expect(first != nil && first == second)                         // not deleted and recreated
    }

    @Test func syncAddsRenamesAndRemovesOnlyItsOwnShortcuts() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-apps-\(UUID().uuidString)")
        let shortcuts = AppShortcuts(directory: dir)
        var a = Program(name: "Alpha", windowsPath: #"C:\a.exe"#)
        let b = Program(name: "Beta", windowsPath: #"C:\b.exe"#)
        try fm.createDirectory(at: dir.appending(path: "Someone Else.app"), withIntermediateDirectories: true)
        shortcuts.sync([a, b]) { _ in nil }
        #expect(Set(shortcuts.existing().values.map(\.lastPathComponent)) == ["Alpha.app", "Beta.app"])
        a.name = "Alpha Two"
        shortcuts.sync([a]) { _ in nil }
        #expect(shortcuts.existing().values.map(\.lastPathComponent) == ["Alpha Two.app"])
        #expect(fm.fileExists(atPath: dir.appending(path: "Someone Else.app").path))   // not Harbor's: untouched
    }
}
