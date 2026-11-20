import Foundation
import Testing
@testable import HarborKit

@Suite struct DiagnosisMisfireTests {
    let fm = FileManager.default
    let missing = #"01cc:err:module:import_dll Library HarborMissing.dll (which is needed by L"Z:\\tmp\\diag\\needsdll.exe") not found"#
    let crash = "wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger..."

    func bottle() throws -> Bottle {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-diag-\(UUID().uuidString)")).create(name: "D")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        return b
    }

    @Test func aGameFolderCalledVanguardIsNotAntiCheat() {
        let log = #"""
        0128:err:module:loader_init Importing dlls for L"C:\\Games\\Call of Duty Vanguard\\Vanguard.exe" failed, status c0000135
        wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger...
        00e8:fixme:dbghelp_dwarf:dwarf2_load_one_entry Unhandled Tag type 0xa in ctx(0000000004812080,L"C:\\Games\\Call of Duty Vanguard\\Vanguard.exe")
        00e8:err:seh:dispatch_exception easyanticheat and battleye mentioned outside a module load
        """#
        #expect(Diagnosis.analyze(log)?.cause == .crashed)
    }

    @Test func antiCheatIsStillRecognisedWhereItsModulesLoad() {
        #expect(Diagnosis.analyze(#"0120:err:module:load_dll failed to load L"C:\\Program Files\\Riot Vanguard\\vgk.sys""# + "\n" + crash)?.cause
                == .antiCheat("Riot Vanguard"))
        #expect(Diagnosis.analyze(#"0044:err:winedevice:async_create_driver failed to create driver L"BEService": c0000135"#)?.cause
                == .antiCheat("BattlEye"))
        #expect(Diagnosis.analyze(#"0044:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\EasyAntiCheat": c0000135"#)?.cause
                == .antiCheat("Easy Anti-Cheat"))
    }

    @Test func missingLibraryNamesKeepTheirSpaces() {
        let log = missing.replacingOccurrences(of: "HarborMissing.dll", with: "My Lib.dll")
        #expect(Diagnosis.analyze(log) == Diagnosis(cause: .missingLibrary("My Lib.dll", recipe: nil)))
    }

    @Test func aLogThatIsNotUTF8IsStillDiagnosed() throws {
        let b = try bottle()
        let log = b.logsDirectory.appending(path: "20261119-100000-Quest.log")
        try (Data("Gr".utf8) + Data([0xFC, 0xDF, 0x65, 0x0A]) + Data(missing.utf8) + Data([0x0A, 0xFF])).write(to: log)
        #expect(throws: (any Error).self) { try String(contentsOf: log, encoding: .utf8) }
        let found = try #require(b.diagnosis(forLatestRunOf: "Quest"))
        #expect(found.diagnosis.cause == .missingLibrary("HarborMissing.dll", recipe: nil))
        #expect(found.log.lastPathComponent == log.lastPathComponent)
        #expect(b.diagnosis(forLatestRunOf: "Other") == nil)
    }

    @Test func aProgramsLogIsNotMistakenForItsNumberedSiblings() throws {
        let b = try bottle()
        for name in ["20261119-100000-Foo.log", "20261119-110000-Foo-2.log", "20261119-120000-Foo-2-3.log"] {
            try Data().write(to: b.logsDirectory.appending(path: name))
        }
        #expect(b.latestLog(label: "Foo")?.lastPathComponent == "20261119-100000-Foo.log")
        #expect(b.latestLog(label: "Foo 2")?.lastPathComponent == "20261119-110000-Foo-2.log")
        #expect(b.latestLog(label: "Foo-2 3")?.lastPathComponent == "20261119-120000-Foo-2-3.log")
        // A second run within the same second is counted before the label and is the newer one.
        try Data().write(to: b.logsDirectory.appending(path: "20261119-100000.2-Foo.log"))
        #expect(b.latestLog(label: "Foo")?.lastPathComponent == "20261119-100000.2-Foo.log")
        #expect(b.logs().first?.lastPathComponent == "20261119-120000-Foo-2-3.log")
    }

    @Test func runsInTheSameSecondGetLogsThatStayWithTheirProgram() throws {
        let b = try bottle()
        for (label, text) in [("Foo", "first"), ("Foo 2", "sibling"), ("Foo", "second"), ("Foo 2", "sibling again")] {
            let handle = try b.newLog(label: label)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        #expect(b.logs().count == 4)
        #expect(try String(contentsOf: #require(b.latestLog(label: "Foo")), encoding: .utf8) == "second")
        #expect(try String(contentsOf: #require(b.latestLog(label: "Foo 2")), encoding: .utf8) == "sibling again")
    }
}

@Suite struct RecipeInstallTests {
    let fm = FileManager.default

    @Test func alreadyInstalledAndRestartNeededCountAsInstalled() {
        for status: Int32 in [0, 1638, 3010, 102, 194] { #expect(Recipe.installerSucceeded(status)) }
        // 1603 is a fatal installer error (99 as Wine reports it), 1602 a cancelled one.
        for status: Int32 in [1, 99, 1602, 1603, -1, 255] { #expect(!Recipe.installerSucceeded(status)) }
    }

    /// A launcher whose "wine" is a script that records its arguments and exits as `exits` says, a bottle, and a
    /// recipe whose two installers are already in the download cache.
    func fixture(exits: String) throws -> (launcher: WineLauncher, bottle: Bottle, recipe: Recipe, cache: URL, calls: URL) {
        let base = fm.temporaryDirectory.appending(path: "harbor-recipe-\(UUID().uuidString)")
        let wine = base.appending(path: "wine/bin/wine"), cache = base.appending(path: "cache"), calls = base.appending(path: "calls")
        try fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"$*\" >> '\(calls.path)'\ncase \"$*\" in \(exits) esac\n".write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let downloads = try ["vc_x64.exe", "vc_x86.exe"].map { name in
            let data = Data(name.utf8), hash = WineLauncher.sha256(data)
            try data.write(to: cache.appending(path: "\(hash)-\(name)"))
            return Recipe.Download(url: URL(string: "https://example.invalid/\(name)")!, sha256: hash, arguments: ["/quiet"])
        }
        let recipe = Recipe(id: "vctest", name: "Test", downloads: downloads, overrides: ["msvcp140"], marker: "msvcp140.dll")
        let bottle = try BottleStore(directory: base.appending(path: "bottles")).create(name: "R")
        return (WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine"))), bottle, recipe, cache, calls)
    }

    func installersRun(_ calls: URL) throws -> [String] {
        try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").filter { $0.hasSuffix("/quiet") }
            .map { String($0.contains("vc_x64.exe") ? "x64" : "x86") }
    }

    @Test func anAlreadyInstalledRuntimeIsNotAFailureAndBothArchitecturesRun() async throws {
        // What VC_redist does when a newer version is present (1638) and when it wants a restart (3010).
        let f = try fixture(exits: "*vc_x64.exe*) exit 102;; *vc_x86.exe*) exit 194;;")
        try await f.launcher.install(f.recipe, in: f.bottle, cache: f.cache)
        #expect(try installersRun(f.calls) == ["x64", "x86"])
    }

    @Test func aFailedInstallerStillLetsTheOtherArchitectureRunAndIsReported() async throws {
        let f = try fixture(exits: "*vc_x64.exe*) exit 99;;")
        await #expect(throws: WineExitError.self) { try await f.launcher.install(f.recipe, in: f.bottle, cache: f.cache) }
        #expect(try installersRun(f.calls) == ["x64", "x86"])
    }
}

extension RecipeInstallTests {
    /// A package that only unpacks (DirectX) gets its follow-up command run next, and its unpack folder removed.
    @Test func unpackThenSetUpThenCleanUp() async throws {
        let f = try fixture(exits: "")
        var download = f.recipe.downloads[0]
        download.followUp = [#"C:\windows\temp\harbor-unpack\SETUP.exe"#, "/silent"]
        var recipe = Recipe(id: "dxtest", name: "Test", downloads: [download], overrides: ["d3dx9_43"], marker: "d3dx9_43.dll")
        recipe.temporaryFolder = #"C:\windows\temp\harbor-unpack"#
        let unpacked = f.bottle.driveC.appending(path: "windows/temp/harbor-unpack")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)        // as the package would leave it
        try Data().write(to: unpacked.appending(path: "SETUP.exe"))

        try await f.launcher.install(recipe, in: f.bottle, cache: f.cache)
        let calls = try String(contentsOf: f.calls, encoding: .utf8).split(separator: "\n").map(String.init)
        let unpack = try #require(calls.firstIndex { $0.hasSuffix("vc_x64.exe /quiet") })
        // (The stand-in's `echo` mangles the backslashes of the Windows path, so match the end.)
        let setUp = try #require(calls.firstIndex { $0.hasSuffix("SETUP.exe /silent") })
        #expect(unpack < setUp)
        #expect(!fm.fileExists(atPath: unpacked.path))
    }

    @Test func theDirectXComponentKeepsWinesControllerAndAudioLibraries() {
        let dx = Recipe.directx2010
        #expect(dx.overrides.contains("d3dx9_43") && dx.overrides.contains("d3dx9_24") && dx.overrides.contains("d3dcompiler_43"))
        #expect(!dx.overrides.contains { $0.hasPrefix("xinput") || $0.hasPrefix("xaudio") || $0.hasPrefix("x3daudio") || $0.hasPrefix("xact") })
        #expect(!dx.overrides.contains("d3dcompiler_47"))          // newer than this package; Wine's own
        #expect(dx.downloads[0].followUp.first?.hasSuffix("DXSETUP.exe") == true)
    }
}

@Suite struct RuntimeCollectionTests {
    let fm = FileManager.default

    /// A launcher plus an old derived runtime and an old template that nothing visibly uses.
    func fixture() throws -> (launcher: WineLauncher, runtimes: URL, templates: URL, stale: [URL]) {
        let base = fm.temporaryDirectory.appending(path: "harbor-gc-\(UUID().uuidString)")
        let runtimes = base.appending(path: "Runtimes"), templates = base.appending(path: "Templates")
        let launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")), runtimesDirectory: runtimes)
        let stale = [runtimes.appending(path: "d3dmetal-4.0b3-old"), templates.appending(path: "oldkey")]
        for dir in stale { try fm.createDirectory(at: dir.appending(path: "bin"), withIntermediateDirectories: true) }
        return (launcher, runtimes, templates, stale)
    }

    @Test func collectsNothingWhileWindowsIsRunningInABottle() throws {
        let f = try fixture()
        // What `ps` shows while Steam runs from the old derived runtime: Wine's processes under their Windows titles.
        let visible = ["/usr/sbin/cfprefsd", #"C:\Program Files (x86)\Steam\steam.exe"#]
        #expect(Maintenance.collectGarbage(launcher: f.launcher, runtimesDirectory: f.runtimes, templatesDirectory: f.templates,
                                           bottleRunning: true, inUse: { visible }).isEmpty)
        for kept in f.stale { #expect(fm.fileExists(atPath: kept.path)) }
        // Once nothing runs, the same folders go.
        let removed = Maintenance.collectGarbage(launcher: f.launcher, runtimesDirectory: f.runtimes, templatesDirectory: f.templates,
                                                 bottleRunning: false, inUse: { ["/usr/sbin/cfprefsd"] })
        #expect(Set(removed.map(\.lastPathComponent)) == ["d3dmetal-4.0b3-old", "oldkey"])
    }

    @Test func collectsNothingWhenRunningProcessesAreUnknown() throws {
        let f = try fixture()
        #expect(Maintenance.runningExecutables(ps: "/nonexistent/ps") == nil)
        #expect(Maintenance.runningExecutables(ps: "/usr/bin/false") == nil)
        #expect(Maintenance.runningExecutables()?.isEmpty == false)
        #expect(Maintenance.collectGarbage(launcher: f.launcher, runtimesDirectory: f.runtimes, templatesDirectory: f.templates,
                                           bottleRunning: false, inUse: { nil }).isEmpty)
        for kept in f.stale { #expect(fm.fileExists(atPath: kept.path)) }
    }
}
