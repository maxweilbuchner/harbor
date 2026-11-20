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
}
