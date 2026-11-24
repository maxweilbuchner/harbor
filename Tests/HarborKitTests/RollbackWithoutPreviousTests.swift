import Foundation
import Testing
@testable import HarborKit

/// An interrupted switch whose new Wine doesn't start is put back only while there is something to put back:
/// the one runtime on disk is never deleted (#51).
@Suite struct RollbackWithoutPreviousTests {
    let fm = FileManager.default
    let updates = RuntimeUpdateTests()

    @Test func theNewRuntimeStaysWhenThePreviousOneIsGone() async throws {
        let (root, crashed, list) = try await updates.interruptedSwitch(copies: ["gone"])
        defer { try? fm.removeItem(at: root) }
        let installed = crashed[0]
        for name in try fm.contentsOfDirectory(atPath: installed.path) where name.hasPrefix(".old-") {
            try fm.removeItem(at: installed.appending(path: name))
        }
        let inst = try updates.installer(list, installed: installed)
        #expect(throws: RuntimeInstallError.unprovenUpdateKept) { try inst.activateStaged { _ in false } }
        // Both components are the new list's: not one of them deleted, not half of them put back.
        #expect(updates.marker("wine", in: installed) == "wine v2" && updates.marker("d3dmetal", in: installed) == "d3d v2")
        #expect(inst.installedVersion(of: "wine") == "2")
        // Recorded like any update that didn't start, and settled: nothing waits to be switched to again.
        #expect(inst.failedSequence == 200 && !inst.hasStagedUpdate)
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".ready-") })
        // The next check finds what the list offers installed, so nothing is downloaded over it.
        #expect(inst.decision(for: try await inst.fetchManifest(), appBuild: nil) == .upToDate)
        try inst.activateStaged { _ in false }                            // nothing left to switch or to roll back
        #expect(updates.marker("wine", in: installed) == "wine v2")
    }

    /// Only one component's previous version is gone: the runtime still isn't taken apart.
    @Test func oneMissingPreviousVersionKeepsTheWholeUpdate() async throws {
        let (root, crashed, list) = try await updates.interruptedSwitch(copies: ["gone"])
        defer { try? fm.removeItem(at: root) }
        let installed = crashed[0]
        let aside = try #require(try fm.contentsOfDirectory(atPath: installed.path).first { $0.hasPrefix(".old-wine-") })
        try fm.removeItem(at: installed.appending(path: aside))
        let inst = try updates.installer(list, installed: installed)
        #expect(throws: RuntimeInstallError.unprovenUpdateKept) { try inst.activateStaged { _ in false } }
        #expect(updates.marker("wine", in: installed) == "wine v2" && updates.marker("d3dmetal", in: installed) == "d3d v2")
    }

    /// With the previous versions on disk the same failure still ends with them in place.
    @Test func thePreviousRuntimeComesBackWhenItIsThere() async throws {
        let (root, crashed, list) = try await updates.interruptedSwitch(copies: ["there"])
        defer { try? fm.removeItem(at: root) }
        let inst = try updates.installer(list, installed: crashed[0])
        #expect(throws: RuntimeInstallError.verificationFailed) { try inst.activateStaged { _ in false } }
        #expect(updates.marker("wine", in: crashed[0]) == "wine v1" && updates.marker("d3dmetal", in: crashed[0]) == "d3d v1")
        #expect(inst.failedSequence == 200 && inst.installedSequence == 100 && !inst.hasStagedUpdate)
    }

    @Test func theMessageSaysWhatWasKept() {
        let text = RuntimeInstallError.message(for: RuntimeInstallError.unprovenUpdateKept)
        #expect(text == RuntimeInstallError.unprovenUpdateKept.description && text != RuntimeInstallError.verificationFailed.description)
        #expect(!text.contains("Wine") && !text.contains("previous version was kept"))
    }
}
