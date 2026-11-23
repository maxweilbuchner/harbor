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

    @Test func aDownloadThatStoppedPartWayIsntSwitchedToAndContinuesLater() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let list = try serve([("wine", "2", "wine v2"), ("d3dmetal", "2", "d3d v2")], sequence: 200, in: root)
        let inst = try installer(list, installed: installed)
        let manifest = try await inst.fetchManifest()
        // The second archive arrives damaged: Wine is staged, D3DMetal isn't.
        let d3d = list.deletingLastPathComponent().appending(path: "d3dmetal-2.tar.xz")
        let good = try Data(contentsOf: d3d)
        try Data("damaged".utf8).write(to: d3d)
        await #expect(throws: RuntimeInstallError.checksumMismatch(component: "d3dmetal")) {
            try await inst.stage(manifest, appBuild: nil)
        }
        #expect(fm.fileExists(atPath: installed.appending(path: ".ready-wine").path))
        #expect(!inst.hasStagedUpdate)
        try inst.activateStaged()                                         // nothing to switch to
        #expect(marker("wine", in: installed) == "wine v1" && inst.installedSequence == 100)

        // Next time the download works. Wine isn't fetched again (its archive is gone from the server).
        try good.write(to: d3d)
        try fm.removeItem(at: list.deletingLastPathComponent().appending(path: "wine-2.tar.xz"))
        try await inst.stage(manifest, appBuild: nil)
        #expect(inst.hasStagedUpdate)
        try inst.activateStaged()
        #expect(marker("wine", in: installed) == "wine v2" && marker("d3dmetal", in: installed) == "d3d v2")
        #expect(inst.installedSequence == 200)
        #expect(!inst.hasStagedUpdate)
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

        // The same list isn't tried again...
        let manifest = try await inst.fetchManifest()
        #expect(inst.failedSequence == 200)
        #expect(inst.decision(for: manifest, appBuild: nil) == .failedBefore)
        try await inst.stage(manifest, appBuild: nil)
        #expect(!inst.hasStagedUpdate)
        // ...but a newer one is.
        let next = try installer(try serve([("wine", "3", "wine v3"), ("d3dmetal", "2", "d3d v2")], sequence: 300, in: root), installed: installed)
        let newer = try await next.fetchManifest()
        #expect(next.decision(for: newer, appBuild: nil) == .available(newer.components))
        try await next.stage(newer, appBuild: nil)
        try next.activateStaged()
        #expect(marker("wine", in: installed) == "wine v3" && next.installedSequence == 300)
    }

    /// An app can need a newer runtime than is installed; installations from before sequences count as older.
    @Test func comparesTheInstalledRuntimeWithTheAppsMinimum() async throws {
        let (_, installed) = try await installedV1()                     // sequence 100
        let inst = try installer(URL(filePath: "/nonexistent/runtime.json"), installed: installed)
        #expect(inst.meetsMinimum(nil) && inst.meetsMinimum(100) && inst.meetsMinimum(50))
        #expect(!inst.meetsMinimum(101))
        try fm.removeItem(at: installed.appending(path: ".harbor-sequence"))
        #expect(!inst.meetsMinimum(1) && inst.meetsMinimum(nil))
    }

    @Test func showsComponentVersionsInPlainForm() {
        #expect(RuntimeInstaller.displayVersion("26.3.0-7") == "26.3.0 (7)")
        #expect(RuntimeInstaller.displayVersion("cx26.3.0-5") == "26.3.0 (5)")   // runtimes up to revision 6
        #expect(RuntimeInstaller.displayVersion("4.0b3-2") == "4.0b3 (2)")
        // No revision, or a suffix that isn't one: unchanged.
        #expect(RuntimeInstaller.displayVersion("v0.80") == "v0.80")
        #expect(RuntimeInstaller.displayVersion("11.21-rc") == "11.21-rc")
        #expect(RuntimeInstaller.displayVersion("-5") == "-5")
        #expect(RuntimeInstaller.displayVersion("") == "")
    }

    @Test func knowsWhenTheInstalledRuntimeWasPutInPlace() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let first = try installer(installed.appending(path: "unused.json"), installed: installed)
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: then], ofItemAtPath: installed.appending(path: ".harbor-sequence").path)
        #expect(first.installedDate == then)
        // An installation from before sequences were recorded: the Wine folder's date.
        try fm.removeItem(at: installed.appending(path: ".harbor-sequence"))
        try fm.setAttributes([.modificationDate: then.addingTimeInterval(60)], ofItemAtPath: installed.appending(path: "wine").path)
        #expect(first.installedDate == then.addingTimeInterval(60))
        #expect(try installer(installed.appending(path: "unused.json"), installed: root.appending(path: "nowhere")).installedDate == nil)
    }

    @Test func aCheckOrDownloadCountsAsBusy() {
        #expect(RuntimeUpdateState.checking.isBusy)
        #expect(RuntimeUpdateState.downloading(0.4).isBusy)
        for state in [RuntimeUpdateState.idle, .ready, .needsNewerApp, .failedBefore, .failed("x")] { #expect(!state.isBusy) }
    }

    @Test func theInstallDateIsWhenAnUpdateWasSwitchedToNotWhenItWasDownloaded() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let inst = try installer(try serve([("wine", "2", "wine v2"), ("d3dmetal", "1", "d3d v1")], sequence: 200, in: root), installed: installed)
        try await inst.stage(try await inst.fetchManifest(), appBuild: nil)
        // Downloaded three days ago, switched to now.
        let downloaded = Date().addingTimeInterval(-3 * 86400)
        for name in [".ready-sequence", ".ready-wine"] {
            try fm.setAttributes([.modificationDate: downloaded], ofItemAtPath: installed.appending(path: name).path)
        }
        let before = Date().addingTimeInterval(-2)
        try inst.activateStaged()
        #expect(try #require(inst.installedDate) >= before)
        // Also for a list without a sequence, where only the Wine folder can tell.
        try fm.removeItem(at: installed.appending(path: ".harbor-sequence"))
        #expect(try #require(inst.installedDate) >= before)
    }

    @Test func updateErrorsReadAsSentences() {
        #expect(RuntimeInstallError.message(for: RuntimeInstallError.checksumMismatch(component: "wine"))
                == "The wine download is damaged (checksum mismatch).")
        let offline = RuntimeInstallError.message(for: URLError(.notConnectedToInternet))
        #expect(offline.hasPrefix("The update server couldn’t be reached"))
        #expect(!offline.contains("Domain") && !offline.contains("UserInfo"))
        // An error as URLSession delivers it, with its own sentence and a user info dump behind it.
        let lost = URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost.",
                                                               NSURLErrorFailingURLStringErrorKey: "https://example.com/x"])
        #expect(RuntimeInstallError.message(for: lost) == "The update server couldn’t be reached: The network connection was lost.")
        #expect(RuntimeInstallError.message(for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")))
                == "The update list couldn’t be read.")
        #expect(!RuntimeInstallError.message(for: CocoaError(.fileNoSuchFile)).contains("Error Domain"))
    }

    @Test func aFailedCheckKeepsWhatWasKnownUnlessTheUserAsked() {
        let offline = URLError(.notConnectedToInternet)
        // In the background: quiet, and an earlier finding isn't replaced by "up to date".
        #expect(RuntimeUpdateState.afterFailedCheck(offline, previous: .needsNewerApp, userAsked: false) == .needsNewerApp)
        #expect(RuntimeUpdateState.afterFailedCheck(offline, previous: .failed("x"), userAsked: false) == .failed("x"))
        #expect(RuntimeUpdateState.afterFailedCheck(offline, previous: .idle, userAsked: false) == .idle)
        #expect(RuntimeUpdateState.afterFailedCheck(offline, previous: .checking, userAsked: false) == .idle)
        // Asked: told why.
        #expect(RuntimeUpdateState.afterFailedCheck(offline, previous: .idle, userAsked: true)
                == .failed(RuntimeInstallError.message(for: offline)))
        #expect(RuntimeUpdateState.afterFailedCheck(RuntimeInstallError.badSignature, previous: .idle, userAsked: true)
                == .failed("The runtime list isn't signed by Harbor."))
        // A list in a newer format means a newer Harbor, asked or not.
        #expect(RuntimeUpdateState.afterFailedCheck(RuntimeInstallError.unsupportedSchema(9), previous: .idle, userAsked: false)
                == .needsNewerApp)
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
