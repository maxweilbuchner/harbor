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

    @Test func displayModeChangesStayInsideWineExceptForGames() throws {
        let store = BottleStore(directory: try tempDir())
        var b = try store.create(name: "Modes")
        let wine = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent")))
        // Plain Wine and DXMT (programs that aren't games): emulated. A stray setting from Harbor's own
        // environment doesn't leak through.
        #expect(wine.environment(for: b, base: [:])["HARBOR_EMULATE_MODESET"] == "1")
        let dxmt = WineRuntime(root: URL(filePath: "/runtimes/dxmt-v0.80-abc"))
        #expect(wine.environment(for: b, runtime: dxmt, base: ["HARBOR_EMULATE_MODESET": "0"])["HARBOR_EMULATE_MODESET"] == "1")
        // The D3DMetal runtime (games): the display's real modes.
        let d3dmetal = WineRuntime(root: URL(filePath: "/runtimes/d3dmetal-4.0-abc"))
        #expect(wine.environment(for: b, runtime: d3dmetal, base: ["HARBOR_EMULATE_MODESET": "1"])["HARBOR_EMULATE_MODESET"] == nil)
        // A bottle's own variable still decides.
        b.settings.environment = ["HARBOR_EMULATE_MODESET": "0"]
        #expect(wine.environment(for: b, base: [:])["HARBOR_EMULATE_MODESET"] == "0")
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
        #expect(WineLauncher.arguments(toOpen: URL(filePath: "/x/Steam.exe")).last == "-cef-disable-gpu")
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
        bottle.settings.graphics = .d3dmetal // games only; a bottle's own commands (installers, reg) aren't games
        #expect(launcher.effectiveGraphics(for: bottle) == .wined3d)
        #expect(try launcher.runtime(for: bottle) == base)
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

    @Test func direct3D11AloneDoesNotMakeAGame() throws {
        let a = try ProgramAnalysis.analyze(try fixture("d3dapp64"))
        #expect(a.direct3D == 11)
        #expect(!a.looksLikeGame)        // browsers, Electron and CAD tools import D3D11 too
        #expect(try ProgramAnalysis.analyze(try fixture("game64")).imports.contains("xinput1_4.dll"))
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

    static let winrarInstaller = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Downloads/winrar-x64-723.exe")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: winrarInstaller.path)))
    func detectsSelfExtractingInstallers() throws {
        #expect(try ProgramAnalysis.analyze(Self.winrarInstaller).installer == .selfExtracting)
    }

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
        // A NUL counted into the string (Steam's shortcut) means "no arguments", not an empty argument.
        let steamLike = ShellLink(Self.link(target: #"C:\Steam\steam.exe"#, arguments: "\0", workingDirectory: "C:\\Steam\u{0}"))
        #expect(steamLike?.arguments == nil)
        #expect(steamLike?.workingDirectory == #"C:\Steam"#)
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
        // Desktop-only shortcuts (WinRAR's installer) count; a Desktop linked to the Mac's is never scanned.
        let publicDesktop = b.driveC.appending(path: "users/Public/Desktop")
        try fm.createDirectory(at: publicDesktop, withIntermediateDirectories: true)
        try fm.copyItem(at: fixture, to: app.appending(path: "Other.exe"))
        try Self.link(target: #"C:\Program Files\Thing\Other.exe"#).write(to: publicDesktop.appending(path: "Other.lnk"))
        let macDesktop = fm.temporaryDirectory.appending(path: "harbor-macdesk-\(UUID().uuidString)")
        try fm.createDirectory(at: macDesktop, withIntermediateDirectories: true)
        try Self.link(target: #"C:\Program Files\Thing\unrelated.exe"#).write(to: macDesktop.appending(path: "Mac.lnk"))
        try fm.createDirectory(at: b.driveC.appending(path: "users/someone"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: b.driveC.appending(path: "users/someone/Desktop"), withDestinationURL: macDesktop)
        let programs = b.startMenuPrograms().filter { $0.name != "Other" }
        #expect(b.startMenuPrograms().map(\.name).sorted() == ["Other", "Thing"])
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

    @Test func bundledGameLibrariesMarkAGame() throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-engine-\(UUID().uuidString)/bin")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = try #require(Bundle.module.url(forResource: "d3dapp64", withExtension: "exe"))
        try fm.copyItem(at: app, to: dir.appending(path: "engine.exe"))
        #expect(!Bottle.looksLikeGame(dir.appending(path: "engine.exe")))       // D3D11 alone: an app
        try Data().write(to: dir.appending(path: "OpenAL32.dll"))                 // Superposition/Heaven ship this
        #expect(Bottle.looksLikeGame(dir.appending(path: "engine.exe")))
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
        #expect(AddProgram.isSharedFolder(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Downloads")))
        #expect(AddProgram.isSharedFolder(URL(filePath: "/Volumes/Data/Stuff/Downloads")))
        // A program folder that happens to hold personal documents is treated as shared too.
        let mixed = FileManager.default.temporaryDirectory.appending(path: "harbor-mixed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        try? Data().write(to: mixed.appending(path: "tool.exe"))
        #expect(!AddProgram.isSharedFolder(mixed))
        try? Data().write(to: mixed.appending(path: "Tax Return.pdf"))
        #expect(AddProgram.isSharedFolder(mixed))
        #expect(!AddProgram.isSharedFolder(home.appending(path: "Downloads/SomeGame")))
        #expect(!AddProgram.isSharedFolder(URL(filePath: "/Volumes/USB/Games/Thing")))
    }

    /// Games bring their whole folder, even when the .exe sits deep inside it or the folder holds pictures.
    @Test func findsTheWholeProgramFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "harbor-root-\(UUID().uuidString)")
        func touch(_ path: String) throws {
            let url = base.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        // Unreal: <Root>/<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe next to <Root>/Engine.
        try touch("Unreal/Engine/Binaries/ThirdParty/x.dll")
        try touch("Unreal/Quest/Content/Paks/Quest.pak")
        try touch("Unreal/Quest/Binaries/Win64/Quest-Win64-Shipping.exe")
        try touch("Unreal/Quest.exe")
        let unreal = base.appending(path: "Unreal").standardizedFileURL
        #expect(AddProgram.programRoot(for: base.appending(path: "Unreal/Quest/Binaries/Win64/Quest-Win64-Shipping.exe")) == unreal)
        #expect(AddProgram.programRoot(for: base.appending(path: "Unreal/Quest.exe")) == unreal)
        // bin/ layout.
        try touch("Tool/bin/tool.exe")
        try touch("Tool/data/a.dat")
        #expect(AddProgram.programRoot(for: base.appending(path: "Tool/bin/tool.exe")) == base.appending(path: "Tool").standardizedFileURL)
        // A game folder with screenshots, videos and a PDF manual is still the game's folder: it has DLLs.
        for f in ["Game/game.exe", "Game/engine.dll", "Game/cover.png", "Game/intro.mp4", "Game/Manual.pdf"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Game/game.exe")) == base.appending(path: "Game").standardizedFileURL)
        // A downloads-like folder (an .exe beside personal files, no DLLs): only the .exe may be copied.
        for f in ["Stuff/winrar.exe", "Stuff/Tax Return.pdf", "Stuff/photo.jpg"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Stuff/winrar.exe")) == nil)
        // Walking up stops at shared folders.
        let home = fm.homeDirectoryForCurrentUser
        #expect(AddProgram.programRoot(for: home.appending(path: "Downloads/x.exe")) == nil)
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

@Suite struct SteamLibraryTests {
    let fm = FileManager.default

    func manifest(_ id: Int, _ name: String, _ dir: String) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(id)"
        \t"Universe"\t\t"1"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(dir)"
        \t"UserConfig"
        \t{
        \t\t"language"\t\t"english"
        \t}
        }
        """
    }

    @Test func readsGamesFromEverySteamLibrary() throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-steam-\(UUID().uuidString)"))
        let b = try store.create(name: "Steam")
        let steam = b.driveC.appending(path: "Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        try Data().write(to: steam.appending(path: "steam.exe"))
        let second = b.driveC.appending(path: "Games/SteamLibrary/steamapps")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try manifest(620, "Portal 2", "Portal 2").write(to: steam.appending(path: "steamapps/appmanifest_620.acf"), atomically: true, encoding: .utf8)
        try manifest(228980, "Steamworks Common Redistributables", "Steamworks Shared")
            .write(to: steam.appending(path: "steamapps/appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try manifest(1145360, "Hades \\\"Deluxe\\\"", "Hades").write(to: second.appending(path: "appmanifest_1145360.acf"), atomically: true, encoding: .utf8)
        try #"""
        "libraryfolders"
        {
        	"0" { "path" "C:\\Program Files (x86)\\Steam" }
        	"1" { "path" "C:\\Games\\SteamLibrary" "apps" { "1145360" "123" } }
        }
        """#.write(to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let games = SteamLibrary.games(in: b)
        #expect(games.map(\.name) == [#"Hades "Deluxe""#, "Portal 2"])
        #expect(games.map(\.appID) == [1145360, 620])
        let steamFolder = try #require(SteamLibrary.steamFolder(in: b))
        let p = try #require(SteamLibrary.program(for: games[1], steam: steamFolder, in: b, salt: "salt"))
        #expect(p.windowsPath == #"C:\Program Files (x86)\Steam\steam.exe"#)
        #expect(p.arguments == "-applaunch 620")
        #expect(p.isGame)
        // The same game gets the same ID on every scan (its Mac shortcut survives), different games differ.
        #expect(SteamLibrary.stableID(appID: 620, bottle: b, salt: "salt") == p.id)
        #expect(SteamLibrary.stableID(appID: 621, bottle: b, salt: "salt") != p.id)
    }

    @Test func bottlesWithoutSteamHaveNoSteamGames() throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-nosteam-\(UUID().uuidString)"))
        #expect(SteamLibrary.games(in: try store.create(name: "Plain")).isEmpty)
    }
}

@Suite struct RecipeTests {
    let fm = FileManager.default

    @Test func recipesArePinnedToMicrosoftDownloads() {
        #expect(Set(Recipe.all.map(\.id)).count == Recipe.all.count)
        for recipe in Recipe.all {
            #expect(recipe.marker.hasSuffix(".dll") && recipe.overrides.contains(String(recipe.marker.dropLast(4))), "\(recipe.id)")
            for d in recipe.downloads {
                #expect(d.url.scheme == "https" && d.url.host()!.hasSuffix("microsoft.com"), "\(d.url)")
                #expect(d.sha256.count == 64 && d.sha256.allSatisfy(\.isHexDigit), "\(d.url)")
            }
        }
        // VC++ 2015–2022's own URLs carry the file's SHA-256; the pinned hash must be that one.
        for d in Recipe.vcrun2022.downloads { #expect(d.url.path.lowercased().contains(d.sha256)) }
    }

    @Test func setsOverridesSoWineLoadsMicrosoftsDLLs() {
        let reg = Recipe.vcrun2013.overridesRegistryFile
        #expect(reg.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(reg.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]"))
        #expect(reg.contains("\"msvcr120\"=\"native,builtin\"\r\n"))
    }

    @Test func tellsMicrosoftsDLLFromWines() throws {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-rcp-\(UUID().uuidString)")).create(name: "R")
        let system32 = b.driveC.appending(path: "windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        let dll = system32.appending(path: "msvcp140.dll")
        #expect(!Recipe.vcrun2022.isInstalled(in: b))                                  // missing
        var wine = Data("MZ".utf8) + Data(repeating: 0, count: 62); wine += Data("Wine builtin DLL".utf8)
        try wine.write(to: dll)
        #expect(!Recipe.vcrun2022.isInstalled(in: b))                                  // Wine's own
        try (Data("MZ".utf8) + Data(repeating: 0, count: 200)).write(to: dll)
        #expect(Recipe.vcrun2022.isInstalled(in: b))                                   // Microsoft's
    }

    /// Before installing, Wine's stand-ins for the recipe's DLLs go (installers skip DLLs with newer versions);
    /// Microsoft's DLLs and unrelated files stay.
    @Test func clearsOnlyWinesOwnCopiesBeforeInstalling() throws {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-rcp-\(UUID().uuidString)")).create(name: "R")
        let wine = Data("MZ".utf8) + Data(repeating: 0, count: 62) + Data("Wine builtin DLL".utf8)
        let ms = Data("MZ".utf8) + Data(repeating: 0, count: 200)
        for folder in ["system32", "syswow64"] {
            let dir = b.driveC.appending(path: "windows/\(folder)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try wine.write(to: dir.appending(path: "msvcr120.dll"))
            try ms.write(to: dir.appending(path: "msvcp120.dll"))
            try wine.write(to: dir.appending(path: "kernel32.dll"))
        }
        let removed = Recipe.vcrun2013.removeBuiltinCopies(in: b).map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }
        #expect(removed.sorted() == ["system32/msvcr120.dll", "syswow64/msvcr120.dll"])
        #expect(fm.fileExists(atPath: b.driveC.appending(path: "windows/system32/msvcp120.dll").path))
        #expect(fm.fileExists(atPath: b.driveC.appending(path: "windows/system32/kernel32.dll").path))
    }

    @Test func rejectsADownloadThatDoesntMatchAndReusesTheCache() async throws {
        let dir = fm.temporaryDirectory.appending(path: "harbor-fetch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appending(path: "setup.exe")
        try Data("installer".utf8).write(to: source)
        let good = WineLauncher.sha256(Data("installer".utf8))
        let cache = dir.appending(path: "cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        await #expect(throws: RecipeError.checksumMismatch("setup.exe")) {
            try await WineLauncher.fetch(.init(url: source, sha256: String(repeating: "0", count: 64), arguments: []), into: cache)
        }
        let file = try await WineLauncher.fetch(.init(url: source, sha256: good, arguments: []), into: cache)
        #expect(try Data(contentsOf: file) == Data("installer".utf8))
        try fm.removeItem(at: source)                                                  // now only the cache has it
        #expect(try await WineLauncher.fetch(.init(url: source, sha256: good, arguments: []), into: cache) == file)
    }
}

@Suite struct DiagnosisTests {
    // Real Wine output (Harbor's runtime, 2026-11-19), paths shortened.
    let missing = #"""
    01cc:err:module:import_dll Library HarborMissing.dll (which is needed by L"Z:\\tmp\\diag\\needsdll.exe") not found
    01cc:err:module:loader_init Importing dlls for L"Z:\\tmp\\diag\\needsdll.exe" failed, status c0000135
    """#
    let crash = """
    wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger...
    00e8:fixme:dbghelp_dwarf:dwarf2_load_one_entry Unhandled Tag type 0xa at debug_info(abbrev:0000000004D60B80,symt:0000000000000000) in ctx(0000000004812080,L"crash")
    """

    @Test func namesAMissingLibraryAndTheComponentThatHasIt() throws {
        #expect(Diagnosis.analyze(missing) == Diagnosis(cause: .missingLibrary("HarborMissing.dll", recipe: nil)))
        let vc = try #require(Diagnosis.analyze(missing.replacingOccurrences(of: "HarborMissing.dll", with: "MSVCP140_ATOMIC_WAIT.dll")))
        #expect(vc.recipe == .vcrun2022)
        #expect(vc.message(for: "Quest").contains("Visual C++ 2015–2022"))
        #expect(Diagnosis.analyze(missing.replacingOccurrences(of: "HarborMissing.dll", with: "msvcr100.dll"))?.recipe == .vcrun2010)
    }

    @Test func recognisesCrashesButNotDebuggerNoise() {
        #expect(Diagnosis.analyze(crash)?.cause == .crashed)
        let noiseOnly = crash.split(separator: "\n").dropFirst().joined(separator: "\n")
        #expect(Diagnosis.analyze(noiseOnly) == nil)
        #expect(Diagnosis.analyze("0120:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION\n") == nil)
    }

    @Test func recognisesDotNetAndAntiCheat() {
        #expect(Diagnosis.analyze("[ERROR] FATAL UNHANDLED EXCEPTION: System.IO.FileNotFoundException: Could not load file")?.cause == .dotNet)
        #expect(Diagnosis.analyze("0124:err:mscoree:LoadLibraryShim error reading registry key for installroot")?.cause == .dotNet)
        #expect(Diagnosis.analyze(#"0120:err:module:LdrInitializeThunk "EasyAntiCheat_EOS.sys" failed"#)?.cause == .antiCheat("Easy Anti-Cheat"))
        // A missing DLL is more specific than a crash in the same log.
        #expect(Diagnosis.analyze(missing + "\n" + crash)?.cause == .missingLibrary("HarborMissing.dll", recipe: nil))
    }

    @Test func findsTheLogOfTheProgramsLastRun() throws {
        let fm = FileManager.default
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-diag-\(UUID().uuidString)")).create(name: "D")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        for name in ["20261119-100000-Quest.log", "20261119-110000-Quest-2.log", "20261119-120000-Quest-Editor.log", "20261119-090000-setup.log"] {
            try Data().write(to: b.logsDirectory.appending(path: name))
        }
        #expect(b.latestLog(label: "Quest")?.lastPathComponent == "20261119-100000-Quest.log")
        #expect(b.latestLog(label: "Quest Editor")?.lastPathComponent == "20261119-120000-Quest-Editor.log")
        #expect(b.latestLog(label: "Other") == nil)
    }
}

@Suite struct DXMTTests {
    let fm = FileManager.default

    func make(_ url: URL, _ text: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A fake Harbor runtime that ships DXMT under lib/dxmt, like scripts/build-wine.sh installs it.
    func runtime(withDXMT: Bool = true) throws -> (WineRuntime, URL) {
        let root = fm.temporaryDirectory.appending(path: "harbor-dxmt-\(UUID().uuidString)")
        let wine = root.appending(path: "wine")
        for tool in ["bin/wine", "bin/wineserver"] {
            try make(wine.appending(path: tool), "#!/bin/sh\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.appending(path: tool).path)
        }
        for arch in ["x86_64-windows", "i386-windows"] {
            try make(wine.appending(path: "lib/wine/\(arch)/d3d11.dll"), "wine-d3d11")
            try make(wine.appending(path: "lib/wine/\(arch)/dxgi.dll"), "wine-dxgi")
        }
        try make(wine.appending(path: "lib/wine/x86_64-unix/ntdll.so"), "ntdll")
        if withDXMT {
            for arch in ["x86_64-windows", "i386-windows"] {
                for dll in ["d3d11.dll", "dxgi.dll", "winemetal.dll"] { try make(wine.appending(path: "lib/dxmt/\(arch)/\(dll)"), "dxmt-\(dll)") }
            }
            try make(wine.appending(path: "lib/dxmt/x86_64-unix/winemetal.so"), "dxmt-winemetal")
            try make(wine.appending(path: "lib/dxmt/VERSION"), "v0.80\n")
        }
        return (WineRuntime(root: wine), root)
    }

    @Test func overlayPutsDXMTOverWinesDirectXAndLeavesTheBaseAlone() throws {
        let (base, root) = try runtime()
        let dxmt = try #require(DXMT.locate(in: base))
        #expect(dxmt.version == "v0.80")
        let derived = try dxmt.runtime(basedOn: base, in: root.appending(path: "runtimes"))
        #expect(derived.root.lastPathComponent.hasPrefix("dxmt-v0.80-"))
        for arch in ["x86_64-windows", "i386-windows"] {
            #expect(try String(contentsOf: derived.root.appending(path: "lib/wine/\(arch)/d3d11.dll"), encoding: .utf8) == "dxmt-d3d11.dll")
        }
        #expect(try String(contentsOf: derived.root.appending(path: "lib/wine/x86_64-unix/winemetal.so"), encoding: .utf8) == "dxmt-winemetal")
        #expect(try String(contentsOf: base.root.appending(path: "lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8) == "wine-d3d11")
        #expect(try dxmt.runtime(basedOn: base, in: root.appending(path: "runtimes")).root == derived.root)   // reused
        #expect(DXMT.locate(in: try runtime(withDXMT: false).0) == nil)
    }

    /// DXMT's d3d11/dxgi import winemetal.dll; a bottle set up without DXMT gets Wine's usual copy of it.
    @Test func givesOlderBottlesWinemetal() throws {
        let (base, root) = try runtime()
        let dxmt = try #require(DXMT.locate(in: base))
        let b = try BottleStore(directory: root.appending(path: "bottles")).create(name: "B")
        for folder in ["system32", "syswow64"] {
            try fm.createDirectory(at: b.driveC.appending(path: "windows/\(folder)"), withIntermediateDirectories: true)
        }
        try dxmt.prepare(b)
        #expect(try String(contentsOf: b.driveC.appending(path: "windows/system32/winemetal.dll"), encoding: .utf8) == "dxmt-winemetal.dll")
        #expect(fm.fileExists(atPath: b.driveC.appending(path: "windows/syswow64/winemetal.dll").path))
        try dxmt.prepare(b)                                                            // idempotent
    }

    /// Direct3D 10/11 programs that aren't games get DXMT; games keep D3DMetal; settings and D3D12 are respected.
    @Test func picksDXMTForDirect3D11ProgramsThatArentGames() throws {
        let (base, _) = try runtime()
        let launcher = WineLauncher(runtime: base)
        let d3dApp = try #require(Bundle.module.url(forResource: "d3dapp64", withExtension: "exe"))
        let plainApp = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        var program = Program(name: "Viewer", windowsPath: #"C:\v.exe"#)
        #expect(launcher.effectiveGraphics(for: program, executable: d3dApp) == .dxmt)
        #expect(launcher.effectiveGraphics(for: program, executable: plainApp) == .wined3d)
        program.graphics = .wined3d                                                    // "Compatibility" stays
        #expect(launcher.effectiveGraphics(for: program, executable: d3dApp) == .wined3d)
        program.graphics = .dxmt
        #expect(launcher.effectiveGraphics(for: program, executable: plainApp) == .dxmt)
        // Without DXMT in the runtime, nothing pretends to use it.
        let old = WineLauncher(runtime: try runtime(withDXMT: false).0)
        #expect(old.effectiveGraphics(for: program, executable: d3dApp) == .wined3d)
        program.graphics = nil
        #expect(old.effectiveGraphics(for: program, executable: d3dApp) == .wined3d)
    }
}

@Suite struct RemovalTests {
    /// Removing a program's last bottle is undoable: the bottle goes to the Trash with everything in it.
    @Test func removedBottlesGoToTheTrash() throws {
        let fm = FileManager.default
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-trash-\(UUID().uuidString)"))
        let b = try store.create(name: "Trash Me")
        try fm.createDirectory(at: b.driveC, withIntermediateDirectories: true)
        try "save".write(to: b.driveC.appending(path: "save.dat"), atomically: true, encoding: .utf8)
        let trashed = try #require(try store.moveToTrash(b))
        defer { try? fm.removeItem(at: trashed) }
        #expect(!fm.fileExists(atPath: b.root.path))
        #expect(store.list().isEmpty)
        #expect((try? String(contentsOf: trashed.appending(path: "prefix/drive_c/save.dat"), encoding: .utf8)) == "save")
    }
}

@Suite struct EpicLibraryTests {
    let fm = FileManager.default

    func manifest(app: String, name: String, location: String, exe: String, extra: String = "") -> String {
        """
        {
        	"FormatVersion": 0,
        	"bIsIncompleteInstall": false,
        	"LaunchExecutable": "\(exe)",
        	"DisplayName": "\(name)",
        	"InstallLocation": "\(location)",
        	"CatalogNamespace": "ns-\(app)",
        	"CatalogItemId": "item\(app)",
        	"AppName": "\(app)",
        	"bIsApplication": true\(extra)
        }
        """
    }

    /// A bottle with the launcher installed and its manifests folder; returns (bottle, manifests folder).
    func epicBottle(programFiles: String = "Program Files") throws -> (Bottle, URL) {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-epic-\(UUID().uuidString)"))
        let b = try store.create(name: "Epic Games")
        let launcher = b.driveC.appending(path: "\(programFiles)/Epic Games/Launcher/Portal/Binaries/Win64")
        try fm.createDirectory(at: launcher, withIntermediateDirectories: true)
        try Data().write(to: launcher.appending(path: "EpicGamesLauncher.exe"))
        let manifests = b.driveC.appending(path: "ProgramData/Epic/EpicGamesLauncher/Data/Manifests")
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        return (b, manifests)
    }

    @Test func readsInstalledGamesFromTheLaunchersManifests() throws {
        let (b, manifests) = try epicBottle()
        try manifest(app: "Fortnite", name: "Fortnite", location: #"C:\\Program Files\\Epic Games\\Fortnite"#,
                     exe: "FortniteGame/Binaries/Win64/FortniteLauncher.exe")
            .write(to: manifests.appending(path: "A1.item"), atomically: true, encoding: .utf8)
        try manifest(app: "Sugar", name: "Alan \\\"Wake\\\"", location: #"C:\\Games\\Sugar\\"#, exe: "Wake.exe")
            .write(to: manifests.appending(path: "B2.item"), atomically: true, encoding: .utf8)
        // Unfinished install, a DLC entry, a broken file and a non-manifest: all skipped.
        try manifest(app: "Half", name: "Half Done", location: #"C:\\Half"#, exe: "h.exe", extra: ",\n\t\"bIsIncompleteInstall\": true")
            .replacingOccurrences(of: "\t\"bIsIncompleteInstall\": false,\n", with: "")
            .write(to: manifests.appending(path: "C3.item"), atomically: true, encoding: .utf8)
        try manifest(app: "Dlc", name: "Some DLC", location: #"C:\\Dlc"#, exe: "", extra: "")
            .replacingOccurrences(of: "\"bIsApplication\": true", with: "\"bIsApplication\": false")
            .write(to: manifests.appending(path: "D4.item"), atomically: true, encoding: .utf8)
        try "{ not json".write(to: manifests.appending(path: "E5.item"), atomically: true, encoding: .utf8)
        try "x".write(to: manifests.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let games = EpicLibrary.games(in: b)
        #expect(games.map(\.name) == [#"Alan "Wake""#, "Fortnite"])
        #expect(games[1].executable == #"C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteLauncher.exe"#)
        #expect(games[0].executable == #"C:\Games\Sugar\Wake.exe"#)

        let p = try #require(EpicLibrary.program(for: games[1], in: b, salt: "salt"))
        #expect(p.windowsPath == #"C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#)
        #expect(p.arguments == "com.epicgames.launcher://apps/ns-Fortnite%3AitemFortnite%3AFortnite?action=launch&silent=true")
        #expect(p.isGame)
        // Stable across scans, distinct per game.
        #expect(EpicLibrary.program(for: games[1], in: b, salt: "salt")?.id == p.id)
        #expect(EpicLibrary.program(for: games[0], in: b, salt: "salt")?.id != p.id)
    }

    @Test func takesTheIconFromTheGamesExecutable() throws {
        let (b, manifests) = try epicBottle()
        let folder = b.driveC.appending(path: "Games/Fix")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        try fm.copyItem(at: fixture, to: folder.appending(path: "fix.exe"))
        try manifest(app: "Fix", name: "Fix", location: #"C:\\Games\\Fix"#, exe: "fix.exe")
            .write(to: manifests.appending(path: "F.item"), atomically: true, encoding: .utf8)
        let game = try #require(EpicLibrary.games(in: b).first)
        let icon = EpicLibrary.icon(for: game, program: try #require(EpicLibrary.program(for: game, in: b, salt: "salt")), in: b)
        #expect(icon.map { fm.fileExists(atPath: $0.path) } == true)
    }

    @Test func bottlesWithoutTheLauncherHaveNoEpicGames() throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-noepic-\(UUID().uuidString)"))
        #expect(EpicLibrary.games(in: try store.create(name: "Plain")).isEmpty)
    }

    @Test func theLauncherBecomesAGameInItsLibrary() throws {
        let (b, _) = try epicBottle()
        let stores = GameStores(store: BottleStore(directory: b.root.deletingLastPathComponent()),
                                launcher: WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent"))))
        let program = try #require(stores.storeProgram(.epic, in: b))
        #expect(program.isGame && program.arguments == nil)
        #expect(stores.existingBottle(for: .epic)?.root.standardizedFileURL.path == b.root.standardizedFileURL.path)
        #expect(stores.existingBottle(for: .steam) == nil)
        // Its window shows as "Epic Games Launcher", not its exe's ProductName "Unreal Engine".
        #expect(GameStores.Store.epic.appNames["EpicGamesLauncher.exe"] == "Epic Games Launcher")
        #expect(GameStores.Store.steam.appNames["steamwebhelper.exe"] == "Steam")
        // Older installs live in Program Files (x86).
        let (old, _) = try epicBottle(programFiles: "Program Files (x86)")
        #expect(stores.storeProgram(.epic, in: old)?.windowsPath.contains("Program Files (x86)") == true)
    }
}

@Suite struct MaintenanceTests {
    let fm = FileManager.default

    @Test func removesOnlyStaleUnusedRuntimesAndTemplates() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-gc-\(UUID().uuidString)")
        let redist = D3DMetalRedist(lib: base.appending(path: "redist/lib"))
        let launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")), d3dmetal: redist,
                                    runtimesDirectory: base.appending(path: "Runtimes"))
        let runtimes = base.appending(path: "Runtimes"), templates = base.appending(path: "Templates")
        let current = runtimes.appending(path: redist.runtimeName(basedOn: launcher.runtime))
        let currentTemplate = PrefixTemplate(launcher: launcher, directory: templates).root
        let stale = runtimes.appending(path: "d3dmetal-4.0b3-old"), busy = runtimes.appending(path: "d3dmetal-4.0b3-busy")
        let oldTemplate = templates.appending(path: "oldkey"), freshStaging = runtimes.appending(path: ".staging-x")
        for dir in [current, currentTemplate, stale, busy, oldTemplate, freshStaging] {
            try fm.createDirectory(at: dir.appending(path: "bin"), withIntermediateDirectories: true)
        }
        let removed = Maintenance.collectGarbage(launcher: launcher, runtimesDirectory: runtimes, templatesDirectory: templates,
                                                 bottleRunning: false, inUse: { [busy.appending(path: "bin/wine").path] })
        #expect(Set(removed.map(\.lastPathComponent)) == ["d3dmetal-4.0b3-old", "oldkey"])
        for kept in [current, currentTemplate, busy, freshStaging] { #expect(fm.fileExists(atPath: kept.path)) }
    }
}

@Suite struct WindowsUpdateTests {
    let fm = FileManager.default

    @Test func detectsWhenWineWouldUpdateABottle() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        let runtime = WineRuntime(root: base.appending(path: "wine"))
        let inf = runtime.root.appending(path: "share/wine/wine.inf")
        try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: inf)
        let date = Date(timeIntervalSince1970: 1_795_108_354)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: inf.path)
        let b = try BottleStore(directory: base.appending(path: "bottles")).create(name: "U")
        try fm.createDirectory(at: b.prefix, withIntermediateDirectories: true)
        let stamp = b.prefix.appending(path: ".update-timestamp")
        try "1795108354\n".write(to: stamp, atomically: true, encoding: .utf8)
        #expect(!b.needsWindowsUpdate(for: runtime))
        try "1700000000\n".write(to: stamp, atomically: true, encoding: .utf8)
        #expect(b.needsWindowsUpdate(for: runtime))
        try "disable\n".write(to: stamp, atomically: true, encoding: .utf8)
        #expect(!b.needsWindowsUpdate(for: runtime))
    }

    /// Links from the Windows user folders to the Mac's folders become folders inside the bottle; what they
    /// pointed to is untouched, and links inside the bottle stay.
    @Test func replacesLinksToMacFoldersWithFoldersInsideTheBottle() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-share-\(UUID().uuidString)")
        let mac = base.appending(path: "mac/Documents")
        try fm.createDirectory(at: mac, withIntermediateDirectories: true)
        try "keep".write(to: mac.appending(path: "Thesis.txt"), atomically: true, encoding: .utf8)
        let b = try BottleStore(directory: base.appending(path: "bottles")).create(name: "S")
        let user = b.driveC.appending(path: "users/harbor")
        let pub = b.driveC.appending(path: "users/Public")
        try fm.createDirectory(at: user.appending(path: "AppData"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pub, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: user.appending(path: "Documents"), withDestinationURL: mac)
        try fm.createSymbolicLink(atPath: pub.appending(path: "Music").path, withDestinationPath: "../../../../mac/Documents")
        try fm.createSymbolicLink(atPath: user.appending(path: "Saves").path, withDestinationPath: "AppData")   // inside: stays

        let replaced = b.unshareUserFolders().map(\.lastPathComponent).sorted()
        #expect(replaced == ["Documents", "Music"])
        for folder in [user.appending(path: "Documents"), pub.appending(path: "Music")] {
            #expect((try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil)
            #expect((try? fm.contentsOfDirectory(atPath: folder.path)) == [])
        }
        #expect((try? String(contentsOf: mac.appending(path: "Thesis.txt"), encoding: .utf8)) == "keep")
        #expect((try? fm.destinationOfSymbolicLink(atPath: user.appending(path: "Saves").path)) == "AppData")
        #expect(b.unshareUserFolders().isEmpty)                                         // nothing left to do
    }

    /// A bottle counts as running while another process holds its wineserver lock, as wineserver does.
    @Test func detectsARunningBottleFromTheServerLock() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-run-\(UUID().uuidString)")
        let b = try BottleStore(directory: base.appending(path: "bottles")).create(name: "R")
        try fm.createDirectory(at: b.prefix, withIntermediateDirectories: true)
        let servers = base.appending(path: "servers").path
        #expect(!b.isRunning(serverDirectory: servers))                 // no server folder at all
        let attrs = try fm.attributesOfItem(atPath: b.prefix.path)
        let dir = "\(servers)/server-\(String(attrs[.systemNumber] as! Int, radix: 16))-\(String(attrs[.systemFileNumber] as! UInt64, radix: 16))"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data().write(to: URL(filePath: "\(dir)/lock"))
        #expect(!b.isRunning(serverDirectory: servers))                 // lock file left behind, nobody holds it

        // Another process takes the lock the way wineserver does (fcntl F_SETLK, write lock).
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)", "\(dir)/lock"]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { holder.terminate() }
        _ = pipe.fileHandleForReading.availableData                      // waits for "locked"
        #expect(b.isRunning(serverDirectory: servers))
    }
}
