import Foundation
import Testing
@testable import HarborKit

/// A switch to downloaded Windows support in which a folder can't be moved (#85): with two components, the one
/// already switched goes back too.
@Suite struct RuntimeSwitchRollbackTests {
    let fm = FileManager.default
    let updates = RuntimeUpdateTests()

    /// D3DMetal is switched first. Then Wine's move fails: of the staged one into place (the installed one is
    /// aside already), or of the installed one aside. `stuck` is the folder that can't be moved.
    @Test(arguments: [".ready-wine", "wine"]) func aMoveThatFailsHalfWayPutsEveryComponentBack(stuck: String) async throws {
        let (root, installed) = try await updates.installedV1()
        defer { try? fm.removeItem(at: root) }
        let list = try updates.serve([("wine", "2", "wine v2"), ("d3dmetal", "2", "d3d v2")], sequence: 200, in: root)
        let inst = try updates.installer(list, installed: installed)
        let manifest = try await inst.fetchManifest()
        try await inst.stage(manifest, appBuild: nil)

        // A locked folder (Finder's "Locked") can't be renamed.
        let folder = installed.appending(path: stuck)
        try fm.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: folder.path) }
        #expect(throws: CocoaError.self) { try inst.activateStaged { _ in Issue.record("the half-made switch was tried out"); return true } }
        #expect(updates.marker("wine", in: installed) == "wine v1" && updates.marker("d3dmetal", in: installed) == "d3d v1")
        #expect(inst.installedVersion(of: "wine") == "1" && inst.installedVersion(of: "d3dmetal") == "1")
        #expect(inst.installedSequence == 100 && inst.failedSequence == nil)
        // Nothing waits to be switched to or finished, and nothing was left aside.
        #expect(!inst.hasStagedUpdate)
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".old-") || $0 == RuntimeInstaller.switchNote })
        try inst.activateStaged { _ in Issue.record("switched without a finished download"); return true }
        #expect(updates.marker("wine", in: installed) == "wine v1" && updates.marker("d3dmetal", in: installed) == "d3d v1")

        // Unlocked, the same list is taken up again. Wine is still there from the first download (its archive
        // is gone from the server); D3DMetal, which was put back, is fetched again.
        try fm.setAttributes([.immutable: false], ofItemAtPath: folder.path)
        try fm.removeItem(at: list.deletingLastPathComponent().appending(path: "wine-2.tar.xz"))
        #expect(inst.decision(for: manifest, appBuild: nil) == .available(manifest.components))
        try await inst.stage(manifest, appBuild: nil)
        try inst.activateStaged()
        #expect(updates.marker("wine", in: installed) == "wine v2" && updates.marker("d3dmetal", in: installed) == "d3d v2")
        #expect(inst.installedSequence == 200 && !inst.hasStagedUpdate)
    }
}
