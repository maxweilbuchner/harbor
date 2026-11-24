import Foundation
import Testing
@testable import HarborKit

/// Which graphics layer a launch gets, and what the launcher does around it.
@Suite struct LauncherGraphicsTests {
    let fm = FileManager.default
    /// Only its presence matters to the choice; nothing here reads Apple's files.
    let redist = D3DMetalRedist(lib: URL(filePath: "/nonexistent"))

    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "exe"))
    }

    /// A copy of fixture `name` at `target` whose import `old` reads `new` (no longer than `old`) instead.
    @discardableResult
    func fixture(_ name: String, importing new: String, insteadOf old: String, at target: URL) throws -> URL {
        var data = try Data(contentsOf: try fixture(name))
        let range = try #require(data.range(of: Data(old.utf8)))
        data.replaceSubrange(range, with: Data(new.utf8) + Data(count: old.utf8.count - new.utf8.count))
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    // MARK: D3DMetal is for games (#14)

    @Test func d3dmetalChosenForAProgramThatIsntAGameIsNotUsed() throws {
        let (base, _) = try DXMTTests().runtime(withDXMT: false)
        let launcher = WineLauncher(runtime: base, d3dmetal: redist)
        var program = Program(name: "Editor", windowsPath: #"C:\e.exe"#, graphics: .d3dmetal)
        #expect(launcher.effectiveGraphics(for: program) == .wined3d)
        #expect(launcher.effectiveGraphics(for: program, executable: try fixture("d3dapp64")) == .wined3d)
        program.isGame = true
        #expect(launcher.effectiveGraphics(for: program) == .d3dmetal)
    }

    /// A bottle's own setting covers what isn't a library launch: installers, `reg`, recipes, wineboot.
    @Test func bottleSetToD3DMetalRunsOtherCommandsOnPlainWine() throws {
        let (base, root) = try DXMTTests().runtime(withDXMT: false)
        let launcher = WineLauncher(runtime: base, d3dmetal: redist, runtimesDirectory: root.appending(path: "runtimes"))
        var bottle = try BottleStore(directory: root.appending(path: "bottles")).create(name: "B")
        bottle.settings.graphics = .d3dmetal
        #expect(launcher.effectiveGraphics(for: bottle) == .wined3d)
        #expect(try launcher.runtime(for: bottle) == base)
    }

    @Test func offersD3DMetalOnlyForGamesAndOnlyInstalledLayers() throws {
        let (base, _) = try DXMTTests().runtime()
        let launcher = WineLauncher(runtime: base, d3dmetal: redist)
        let bare = WineLauncher(runtime: try DXMTTests().runtime(withDXMT: false).0)
        let app = Program(name: "A", windowsPath: #"C:\a.exe"#)
        let game = Program(name: "G", windowsPath: #"C:\g.exe"#, isGame: true)
        #expect(!launcher.offers(.d3dmetal, for: app))
        #expect(launcher.offers(.d3dmetal, for: game))
        #expect(!bare.offers(.d3dmetal, for: game))
        #expect(launcher.offers(.dxmt, for: app))
        #expect(!bare.offers(.dxmt, for: app))
        #expect(bare.offers(.automatic, for: app) && bare.offers(.wined3d, for: app))
    }

    // MARK: When DXMT is chosen automatically (#16)

    /// A game's launcher may start a Direct3D 12 child, which fails on DXMT's dxgi; without D3DMetal it stays on Wine.
    @Test func gamesWithoutD3DMetalStayOffDXMT() throws {
        let launcher = WineLauncher(runtime: try DXMTTests().runtime().0)
        let game = Program(name: "G", windowsPath: #"C:\g.exe"#, isGame: true)
        #expect(launcher.effectiveGraphics(for: game, executable: try fixture("game64")) == .wined3d)
    }

    /// D3DMetal has no 32-bit DLLs, so a 32-bit Direct3D 10/11 game gets DXMT like any other 32-bit program.
    @Test func thirtyTwoBitDirect3D11GamesGetDXMT() throws {
        let (base, root) = try DXMTTests().runtime()
        let exe = try fixture("app32", importing: "d3d11.dll", insteadOf: "USER32.dll", at: root.appending(path: "old/game.exe"))
        #expect(try ProgramAnalysis.analyze(exe).architecture == .x86)
        var game = Program(name: "G", windowsPath: #"C:\g.exe"#, isGame: true)
        for launcher in [WineLauncher(runtime: base, d3dmetal: redist), WineLauncher(runtime: base)] {
            #expect(launcher.effectiveGraphics(for: game, executable: exe) == .dxmt)
        }
        // 32-bit games without Direct3D 10/11, 64-bit games and explicit choices are as before.
        let launcher = WineLauncher(runtime: base, d3dmetal: redist)
        #expect(launcher.effectiveGraphics(for: game, executable: try fixture("app32")) == .d3dmetal)
        #expect(launcher.effectiveGraphics(for: game, executable: try fixture("game64")) == .d3dmetal)
        game.graphics = .d3dmetal
        #expect(launcher.effectiveGraphics(for: game, executable: exe) == .d3dmetal)
    }

    /// dxgi.dll alone says nothing: Direct3D 12 programs import it too.
    @Test func dxgiAloneIsNotDirect3D11() throws {
        #expect(ProgramAnalysis(architecture: .x64, isGUI: true, imports: ["dxgi.dll"]).direct3D == nil)
        #expect(ProgramAnalysis(architecture: .x64, isGUI: true, imports: ["d3d10core.dll", "dxgi.dll"]).direct3D == 10)
        let (base, root) = try DXMTTests().runtime()
        let exe = try fixture("d3dapp64", importing: "other.dll", insteadOf: "d3d11.dll", at: root.appending(path: "app/app.exe"))
        #expect(try ProgramAnalysis.analyze(exe).imports.contains("dxgi.dll"))
        let program = Program(name: "A", windowsPath: #"C:\a.exe"#)
        #expect(WineLauncher(runtime: base).effectiveGraphics(for: program, executable: exe) == .wined3d)
    }

    /// A Direct3D 11 launcher whose folder holds a Direct3D 12 program stays on Wine: the child shares its runtime.
    @Test func direct3D12InTheProgramsFolderKeepsItOffDXMT() throws {
        let (base, root) = try DXMTTests().runtime()
        let launcher = WineLauncher(runtime: base)
        let program = Program(name: "Launcher", windowsPath: #"C:\l.exe"#)
        let exe = root.appending(path: "suite/launcher.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: try fixture("d3dapp64"), to: exe)
        try Data("readme".utf8).write(to: root.appending(path: "suite/notes.dll"))        // not a PE file
        #expect(launcher.effectiveGraphics(for: program, executable: exe) == .dxmt)
        try fixture("game64", importing: "d3d12.dll", insteadOf: "d3d11.dll", at: root.appending(path: "suite/bin/win64/game.exe"))
        #expect(launcher.effectiveGraphics(for: program, executable: exe) == .wined3d)
        // A copy of d3d12.dll itself (not a readable PE here) counts as well.
        let other = root.appending(path: "other/launcher.exe")
        try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: exe, to: other)
        try Data("x".utf8).write(to: root.appending(path: "other/D3D12.dll"))
        #expect(launcher.effectiveGraphics(for: program, executable: other) == .wined3d)
        var chosen = program
        chosen.graphics = .dxmt                                                           // an explicit choice stays
        #expect(launcher.effectiveGraphics(for: chosen, executable: exe) == .dxmt)
    }

    // MARK: Launcher nits (#28)

    /// Stopping a bottle must not depend on its graphics layer being usable.
    @Test func shutdownReachesWineserverWhenDXMTCantBePrepared() throws {
        let (base, root) = try DXMTTests().runtime()
        try "#!/bin/sh\necho \"$@\" > \"$0.args\"\n".write(to: base.wineserver, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.wineserver.path)
        var bottle = try BottleStore(directory: root.appending(path: "bottles")).create(name: "B")
        bottle.settings.graphics = .dxmt
        // An older bottle without winemetal.dll, and a runtime that can't supply it.
        try fm.createDirectory(at: bottle.driveC.appending(path: "windows/system32"), withIntermediateDirectories: true)
        try fm.removeItem(at: base.root.appending(path: "lib/dxmt/x86_64-windows/winemetal.dll"))
        let launcher = WineLauncher(runtime: base, runtimesDirectory: root.appending(path: "runtimes"))
        #expect(throws: (any Error).self) { try launcher.runtime(for: bottle) }
        try launcher.shutdown(bottle)
        #expect(try String(contentsOf: base.wineserver.appendingPathExtension("args"), encoding: .utf8) == "-k\n")
    }

    // MARK: Launcher nits (#66)

    /// A bottle's own variables add to the library path Wine's fonts and Vulkan are found through, and can't
    /// point Wine at another server or loader. What is meant to be changed per bottle (WINEDEBUG) still is.
    @Test func aBottlesVariablesCantTakeAwayWhatWineIsStartedWith() throws {
        let (base, root) = try DXMTTests().runtime(withDXMT: false)
        defer { try? fm.removeItem(at: root) }
        var bottle = try BottleStore(directory: root.appending(path: "bottles")).create(name: "B")
        bottle.settings.environment = ["DYLD_FALLBACK_LIBRARY_PATH": "/opt/extra/lib", "WINESERVER": "/elsewhere/wineserver",
                                       "WINELOADER": "/elsewhere/wine", "WINEDEBUG": "+loaddll", "MY_VARIABLE": "1"]
        let env = WineLauncher(runtime: base).environment(for: bottle, base: [:])
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "\(base.root.path)/lib:/usr/local/lib:/usr/lib:/opt/extra/lib")
        #expect(env["WINESERVER"] == nil && env["WINELOADER"] == nil)
        #expect(env["WINEDEBUG"] == "+loaddll" && env["MY_VARIABLE"] == "1")
    }

    /// A launch tidies up what an interrupted install left in the bottle, but not what was brought in a moment
    /// ago: an install in the same bottle may be between importing its installer and starting it.
    @Test func aLaunchLeavesFreshImportsAlone() async throws {
        let (base, root) = try DXMTTests().runtime(withDXMT: false)      // its "wine" exits at once
        defer { try? fm.removeItem(at: root) }
        let bottle = try BottleStore(directory: root.appending(path: "bottles")).create(name: "B")
        let launcher = WineLauncher(runtime: base, runtimesDirectory: root.appending(path: "runtimes"))
        let program = Program(name: "Game", windowsPath: #"C:\game.exe"#)
        try fm.createDirectory(at: bottle.driveC, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: bottle.driveC.appending(path: "game.exe"))
        func launch() async throws {
            let _: WineExit = try await withCheckedThrowingContinuation { done in
                do { try launcher.launch(program, in: bottle) { done.resume(returning: $0) } } catch { done.resume(throwing: error) }
            }
        }
        let installer = root.appending(path: "VC_redist.x64.exe")
        try Data("MZ".utf8).write(to: installer)
        let imported = try bottle.importForRunning(installer)
        #expect(bottle.imported(since: Date().addingTimeInterval(-60)))
        try await launch()
        #expect(fm.fileExists(atPath: imported.path))
        // The same import, as it looks an hour later.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: bottle.importsDirectory.path)
        #expect(!bottle.imported(since: Date().addingTimeInterval(-60)))
        try await launch()
        #expect(!fm.fileExists(atPath: imported.path))
    }

    /// Backslashes escape a quote the way CommandLineToArgvW reads them, and are literal everywhere else.
    @Test func splitsArgumentsWithEscapedQuotes() {
        #expect(WineLauncher.splitArguments(#"-name \"Max\" -x"#) == ["-name", #""Max""#, "-x"])
        #expect(WineLauncher.splitArguments(#"-say "a \"b\" c""#) == ["-say", #"a "b" c"#])
        #expect(WineLauncher.splitArguments(#"C:\dir\file.txt \\server\share"#) == [#"C:\dir\file.txt"#, #"\\server\share"#])
        #expect(WineLauncher.splitArguments(#""C:\my dir\\" x"#) == [#"C:\my dir\"#, "x"])
        #expect(WineLauncher.splitArguments(#"a\\\"b c\"#) == [#"a\"b"#, #"c\"#])
    }
}
