import Foundation
import Testing
@testable import HarborKit

@Suite struct RuntimeUpdateTests {
    let fm = FileManager.default
    let key = RuntimeSigning.newPrivateKey()

    /// A served folder with a signed list and one archive per component, each holding `marker` with `contents`.
    func serve(_ components: [(id: String, version: String, contents: String)], sequence: Int?, minimumAppBuild: Int? = nil,
               in root: URL) throws -> URL {
        let folder = root.appending(path: "served-\(UUID().uuidString)")
        var entries: [RuntimeManifest.Component] = []
        for c in components {
            let payload = folder.appending(path: "payload-\(c.id)")
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try Data(c.contents.utf8).write(to: payload.appending(path: "marker"))
            let archive = folder.appending(path: "\(c.id)-\(c.version).tar.xz")
            let tar = Process()
            tar.executableURL = URL(filePath: "/usr/bin/tar")
            tar.arguments = ["-cJf", archive.path, "-C", payload.path, "."]
            try tar.run(); tar.waitUntilExit()
            let size = (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            entries.append(.init(id: c.id, version: c.version, url: archive.lastPathComponent,
                                 sha256: try RuntimeInstaller.sha256(of: archive), size: size))
        }
        let url = folder.appending(path: "runtime.json")
        let data = try JSONEncoder().encode(RuntimeManifest(components: entries, sequence: sequence, minimumAppBuild: minimumAppBuild))
        try data.write(to: url)
        try Data(try RuntimeSigning.sign(data, privateKey: key).utf8).write(to: url.appendingPathExtension("sig"))
        return url
    }

    func installer(_ manifest: URL, installed: URL) throws -> RuntimeInstaller {
        RuntimeInstaller(manifestURL: manifest, publicKey: try RuntimeSigning.publicKey(try RuntimeSigning.publicKey(forPrivate: key)),
                         installedDirectory: installed)
    }

    func marker(_ id: String, in installed: URL) -> String? {
        try? String(contentsOf: installed.appending(path: "\(id)/marker"), encoding: .utf8)
    }

    /// Installs list 1 (wine 1, d3dmetal 1, sequence 100) the first-run way and returns the folders.
    func installedV1() async throws -> (root: URL, installed: URL) {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        let installed = root.appending(path: "installed")
        let first = try installer(try serve([("wine", "1", "wine v1"), ("d3dmetal", "1", "d3d v1")], sequence: 100, in: root), installed: installed)
        try await first.installPending(try await first.fetchManifest())
        #expect(first.installedSequence == 100)
        return (root, installed)
    }

    @Test func aNewerListIsStagedWithoutTouchingWhatRunsThenSwitchedTo() async throws {
        let (root, installed) = try await installedV1()
        let inst = try installer(try serve([("wine", "2", "wine v2"), ("d3dmetal", "1", "d3d v1")], sequence: 200, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        #expect(inst.decision(for: manifest, appBuild: 10) == .available([manifest.components[0]]))
        #expect(!inst.hasStagedUpdate)

        try await inst.stage(manifest, appBuild: 10)
        #expect(inst.hasStagedUpdate)
        #expect(marker("wine", in: installed) == "wine v1")              // still the running one
        #expect(inst.installedVersion(of: "wine") == "1")

        try inst.activateStaged()
        #expect(marker("wine", in: installed) == "wine v2")
        #expect(marker("d3dmetal", in: installed) == "d3d v1")
        #expect(inst.installedVersion(of: "wine") == "2")
        #expect(inst.installedSequence == 200)
        #expect(!inst.hasStagedUpdate)
        #expect(inst.decision(for: manifest, appBuild: 10) == .upToDate)
        // The previous version waits aside until nothing can be using it.
        #expect(try fm.contentsOfDirectory(atPath: installed.path).contains { $0.hasPrefix(".old-wine-") })
        inst.removeOldVersions()
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".old-") || $0.hasPrefix(".ready-") || $0.hasPrefix(".staging-") })
    }

    @Test func aNewRuntimeThatDoesntStartIsRolledBack() async throws {
        let (root, installed) = try await installedV1()
        let inst = try installer(try serve([("wine", "2", "broken"), ("d3dmetal", "2", "d3d v2")], sequence: 200, in: root), installed: installed)
        try await inst.stage(try await inst.fetchManifest(), appBuild: nil)
        #expect(throws: RuntimeInstallError.verificationFailed) {
            try inst.activateStaged { dir in (try? String(contentsOf: dir.appending(path: "wine/marker"), encoding: .utf8)) != "broken" }
        }
        #expect(marker("wine", in: installed) == "wine v1")
        #expect(marker("d3dmetal", in: installed) == "d3d v1")
        #expect(inst.installedVersion(of: "wine") == "1")
        #expect(inst.installedSequence == 100)
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".ready-") })   // nothing left staged
    }

    @Test func anOlderSignedListCantDowngrade() async throws {
        let (root, installed) = try await installedV1()
        // Correctly signed, but older than what's installed; and one without any sequence.
        for sequence in [50, nil] as [Int?] {
            let inst = try installer(try serve([("wine", "0", "wine v0")], sequence: sequence, in: root), installed: installed)
            let manifest = try await inst.fetchManifest()
            #expect(inst.decision(for: manifest, appBuild: nil) == .refusedOlder)
            await #expect(throws: RuntimeInstallError.olderThanInstalled) { try await inst.stage(manifest, appBuild: nil) }
            #expect(!inst.hasStagedUpdate)
        }
        #expect(marker("wine", in: installed) == "wine v1")
    }

    @Test func componentsThatNeedANewerHarborWait() async throws {
        let (root, installed) = try await installedV1()
        let inst = try installer(try serve([("wine", "2", "wine v2")], sequence: 200, minimumAppBuild: 80, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        #expect(inst.decision(for: manifest, appBuild: 79) == .needsNewerApp(80))
        await #expect(throws: RuntimeInstallError.needsNewerApp(80)) { try await inst.stage(manifest, appBuild: 79) }
        #expect(inst.decision(for: manifest, appBuild: 80) == .available(manifest.components))
    }

    /// Installations from before sequences existed accept the first sequenced list.
    @Test func anInstallationWithoutASequenceAcceptsTheFirstSequencedList() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        let installed = root.appending(path: "installed")
        let old = try installer(try serve([("wine", "1", "wine v1")], sequence: nil, in: root), installed: installed)
        try await old.installPending(try await old.fetchManifest())
        #expect(old.installedSequence == nil)
        let inst = try installer(try serve([("wine", "2", "wine v2")], sequence: 200, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        try await inst.stage(manifest, appBuild: nil)
        try inst.activateStaged()
        #expect(marker("wine", in: installed) == "wine v2")
        #expect(inst.installedSequence == 200)
    }
}
