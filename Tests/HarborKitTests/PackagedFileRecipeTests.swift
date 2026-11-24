import Foundation
import Testing
@testable import HarborKit

/// A component without an installer: files taken out of one of Microsoft's packages by their place in it (#89).
@Suite struct PackagedFileRecipeTests {
    let fm = FileManager.default
    let recipes = RecipeInstallTests()

    /// A stand-in package: some bytes, then `content` deflated as a zip stores it, then more bytes.
    func package(holding content: Data, in folder: URL) throws -> (url: URL, offset: Int, length: Int) {
        let stored = try (content as NSData).compressed(using: .zlib) as Data
        let lead = Data(repeating: 0x50, count: 777)
        let url = folder.appending(path: "package.nupkg")
        try (lead + stored + Data(repeating: 0x4b, count: 99)).write(to: url)
        return (url, lead.count, stored.count)
    }

    func recipe(_ pack: (url: URL, offset: Int, length: Int), sha256: String) -> Recipe {
        Recipe(id: "filetest", name: "Test", downloads: [], overrides: ["d3dcompiler_47"], marker: "d3dcompiler_47.dll",
               files: [.init(package: pack.url, offset: pack.offset, length: pack.length, sha256: sha256,
                             destination: "windows/system32/d3dcompiler_47.dll")])
    }

    @Test func theFileComesOutOfThePackageIntoTheBottleWithItsOverride() async throws {
        let f = try recipes.fixture(exits: "")
        defer { try? fm.removeItem(at: f.cache.deletingLastPathComponent()) }
        let content = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let pack = try package(holding: content, in: f.cache.deletingLastPathComponent())
        let recipe = recipe(pack, sha256: WineLauncher.sha256(content))
        // Wine's own copy is in the way first, as in every new bottle.
        let target = f.bottle.driveC.appending(path: "windows/system32/d3dcompiler_47.dll")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ Wine builtin DLL".utf8).write(to: target)
        #expect(!recipe.isInstalled(in: f.bottle))

        try await f.launcher.install(recipe, in: f.bottle, cache: f.cache)
        #expect(try Data(contentsOf: target) == content)
        #expect(recipe.isInstalled(in: f.bottle))
        // The override went in through Wine (the only thing run: there is no installer).
        let calls = try String(contentsOf: f.calls, encoding: .utf8)
        #expect(calls.contains("reg import") && !calls.contains("/quiet"))
        // A second install takes the file from the cache: the package may be gone.
        try fm.removeItem(at: pack.url)
        try fm.removeItem(at: target)
        try await f.launcher.install(recipe, in: f.bottle, cache: f.cache)
        #expect(try Data(contentsOf: target) == content)
    }

    @Test func aFileThatIsntThePinnedOneChangesNothingInTheBottle() async throws {
        let f = try recipes.fixture(exits: "")
        defer { try? fm.removeItem(at: f.cache.deletingLastPathComponent()) }
        let pack = try package(holding: Data("something else".utf8), in: f.cache.deletingLastPathComponent())
        let recipe = recipe(pack, sha256: WineLauncher.sha256(Data("what was pinned".utf8)))
        let target = f.bottle.driveC.appending(path: "windows/system32/d3dcompiler_47.dll")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ Wine builtin DLL".utf8).write(to: target)
        await #expect(throws: RecipeError.checksumMismatch("d3dcompiler_47.dll")) {
            try await f.launcher.install(recipe, in: f.bottle, cache: f.cache)
        }
        // Wine's copy is still there and nothing was run.
        #expect(try Data(contentsOf: target) == Data("MZ Wine builtin DLL".utf8))
        #expect(!fm.fileExists(atPath: f.calls.path))
        // Bytes cut short (the place is past the package's end) are refused the same way.
        let short = self.recipe((pack.url, pack.offset, pack.length + 5_000), sha256: WineLauncher.sha256(Data("something else".utf8)))
        await #expect(throws: RecipeError.checksumMismatch("d3dcompiler_47.dll")) {
            try await f.launcher.install(short, in: f.bottle, cache: f.cache)
        }
    }

    @Test func aShaderThatWinesCompilerCantBuildOffersMicrosofts() {
        // What Veloren printed before it stopped (wgpu on DirectX 12, Wine's d3dcompiler_47).
        let log = """
            ERROR wgpu::backend::wgpu_core: Shader translation error for stage ShaderStages(FRAGMENT): FXC D3DCompile error (Not implemented. (0x80004001)): ui-frag:61:14: E5017: Aborting due to not yet implemented feature: Shader model 5.1+ resource array.
            ERROR veloren_voxygen::panic_handler: VOXYGEN HAS PANICKED
            """
        let diagnosis = Diagnosis.analyze(log, program: #"C:\Program Files\veloren voxygen\veloren-voxygen.exe"#)
        #expect(diagnosis?.cause == .shaderCompiler && diagnosis?.recipe == .d3dcompiler47)
        #expect(diagnosis?.message(for: "Veloren").contains("Microsoft’s Direct3D shader compiler") == true)
        // Not offered again once it is installed, and not for a log without that line.
        #expect(Diagnosis.analyze(log, installed: { $0 == .d3dcompiler47 }) == nil)
        #expect(Diagnosis.analyze("ERROR something else: E5016") == nil)
    }

    @Test func theShippedRecipePutsOneFileInEachSystemFolder() {
        let recipe = Recipe.d3dcompiler47
        #expect(Recipe.named("d3dcompiler47") == recipe && recipe.downloads.isEmpty)
        #expect(recipe.files.map(\.destination) == ["windows/system32/d3dcompiler_47.dll", "windows/syswow64/d3dcompiler_47.dll"])
        #expect(recipe.files.allSatisfy { $0.package.scheme == "https" && $0.package.host() == "api.nuget.org" && $0.sha256.count == 64 })
    }
}
