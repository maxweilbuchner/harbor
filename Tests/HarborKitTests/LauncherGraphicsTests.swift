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
}
