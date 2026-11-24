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

    /// Harbor quit while `tar` unpacked: the half-unpacked folder goes with the next clean-up.
    @Test func anInterruptedUnpackIsClearedAway() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let leftover = installed.appending(path: ".staging-\(UUID().uuidString)/bin")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: leftover.appending(path: "wine"))
        try installer(installed.appending(path: "unused.json"), installed: installed).removeOldVersions()
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".staging-") })
        #expect(marker("wine", in: installed) == "wine v1")
    }

    /// What an earlier list left staged isn't installed along with a later list's update.
    @Test func aSwitchInstallsOnlyTheComponentsOfTheListThatWasStaged() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        // List A stages Wine 2 and fails on D3DMetal; then Wine 2 is withdrawn.
        let listA = try serve([("wine", "2", "wine v2"), ("d3dmetal", "2", "d3d v2")], sequence: 200, in: root)
        try Data("damaged".utf8).write(to: listA.deletingLastPathComponent().appending(path: "d3dmetal-2.tar.xz"))
        let a = try installer(listA, installed: installed)
        await #expect(throws: RuntimeInstallError.checksumMismatch(component: "d3dmetal")) {
            try await a.stage(try await a.fetchManifest(), appBuild: nil)
        }
        #expect(fm.fileExists(atPath: installed.appending(path: ".ready-wine").path))
        let b = try installer(try serve([("wine", "1", "wine v1"), ("d3dmetal", "3", "d3d v3")], sequence: 300, in: root), installed: installed)
        try await b.stage(try await b.fetchManifest(), appBuild: nil)
        #expect(!fm.fileExists(atPath: installed.appending(path: ".ready-wine").path))
        try b.activateStaged()
        #expect(marker("wine", in: installed) == "wine v1" && marker("d3dmetal", in: installed) == "d3d v3")
        #expect(b.installedVersion(of: "wine") == "1" && b.installedSequence == 300)
    }

    /// Staging again over a finished download (`harbor-cli update-runtime`): nothing of the first one is left
    /// marked complete, neither when the second fails nor in its sequence.
    @Test func stagingAgainStartsFromWhatTheNewListWants() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let installed = root.appending(path: "installed")
        let old = try installer(try serve([("wine", "1", "wine v1")], sequence: nil, in: root), installed: installed)
        try await old.installPending(try await old.fetchManifest())
        let a = try installer(try serve([("wine", "2", "wine v2")], sequence: 200, in: root), installed: installed)
        try await a.stage(try await a.fetchManifest(), appBuild: nil)
        #expect(a.hasStagedUpdate)

        let listB = try serve([("wine", "3", "wine v3")], sequence: nil, in: root)
        let b = try installer(listB, installed: installed)
        let manifest = try await b.fetchManifest()
        let archive = listB.deletingLastPathComponent().appending(path: "wine-3.tar.xz")
        let good = try Data(contentsOf: archive)
        try Data("damaged".utf8).write(to: archive)
        await #expect(throws: RuntimeInstallError.checksumMismatch(component: "wine")) { try await b.stage(manifest, appBuild: nil) }
        #expect(!b.hasStagedUpdate)
        try b.activateStaged()
        #expect(marker("wine", in: installed) == "wine v1")

        try good.write(to: archive)
        try await b.stage(manifest, appBuild: nil)
        try b.activateStaged()
        #expect(marker("wine", in: installed) == "wine v3")
        #expect(b.installedSequence == nil)                               // not list A's 200
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

    /// Downloading takes minutes and proving the new Wine up to one: "nothing is running" is asked right before
    /// the switch, and again before the previous runtime is removed.
    @Test func theSwitchAsksAgainWhetherAnythingRuns() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let inst = try installer(try serve([("wine", "2", "wine v2"), ("d3dmetal", "1", "d3d v1")], sequence: 200, in: root), installed: installed)
        try await inst.stage(try await inst.fetchManifest(), appBuild: nil)
        var asked = 0
        // A program was started since the download began: nothing is switched, the update stays.
        #expect(try !inst.activateStagedIfIdle({ asked += 1; return false }) { _ in Issue.record("switched"); return true })
        #expect(asked == 1 && inst.hasStagedUpdate && marker("wine", in: installed) == "wine v1")

        // One was started while the new Wine was being proven: it may run from the previous runtime, which stays.
        asked = 0
        #expect(try inst.activateStagedIfIdle({ asked += 1; return asked == 1 }) { _ in asked == 1 })
        #expect(asked == 2 && marker("wine", in: installed) == "wine v2" && inst.installedSequence == 200)
        #expect(try fm.contentsOfDirectory(atPath: installed.path).contains { $0.hasPrefix(".old-wine-") })

        // Nothing staged any more; with nothing running the previous runtime goes.
        #expect(try inst.activateStagedIfIdle({ true }))
        #expect(!(try fm.contentsOfDirectory(atPath: installed.path)).contains { $0.hasPrefix(".old-") })
    }

    /// The installed folder as it is while the new Wine is being proven: where a switch stands if Harbor quits,
    /// crashes or loses power then. Returns one copy per name in `copies`.
    func interruptedSwitch(copies: [String]) async throws -> (root: URL, crashed: [URL], manifest: URL) {
        let (root, installed) = try await installedV1()
        let list = try serve([("wine", "2", "wine v2"), ("d3dmetal", "2", "d3d v2")], sequence: 200, in: root)
        let inst = try installer(list, installed: installed)
        try await inst.stage(try await inst.fetchManifest(), appBuild: nil)
        let crashed = copies.map { root.appending(path: $0) }
        try inst.activateStaged { dir in
            for copy in crashed { try? FileManager.default.copyItem(at: dir, to: copy) }
            return true
        }
        return (root, crashed, list)
    }

    @Test func aSwitchInterruptedAfterTheSwapIsFinishedAtTheNextStart() async throws {
        let (root, crashed, list) = try await interruptedSwitch(copies: ["crashed"])
        defer { try? fm.removeItem(at: root) }
        let inst = try installer(list, installed: crashed[0])
        // The new components are in place, under the old sequence.
        #expect(marker("wine", in: crashed[0]) == "wine v2" && inst.installedSequence == 100)
        #expect(inst.decision(for: try await inst.fetchManifest(), appBuild: nil) == .upToDate)
        // The switch still counts as waiting, and the previous versions stay until it is settled.
        #expect(inst.hasStagedUpdate)
        inst.removeOldVersions()
        #expect(try fm.contentsOfDirectory(atPath: crashed[0].path).contains { $0.hasPrefix(".old-wine-") })

        try inst.activateStaged()
        #expect(marker("wine", in: crashed[0]) == "wine v2" && marker("d3dmetal", in: crashed[0]) == "d3d v2")
        #expect(inst.installedSequence == 200 && inst.meetsMinimum(200))
        #expect(!inst.hasStagedUpdate)
        inst.removeOldVersions()
        #expect(!(try fm.contentsOfDirectory(atPath: crashed[0].path)).contains { $0.hasPrefix(".old-") || $0.hasPrefix(".ready-") })
        try inst.activateStaged { _ in false }                            // nothing left to switch or to roll back
        #expect(marker("wine", in: crashed[0]) == "wine v2" && inst.installedSequence == 200)
    }

    @Test func anInterruptedSwitchWhoseWineDoesntStartIsRolledBackAtTheNextStart() async throws {
        let (root, crashed, list) = try await interruptedSwitch(copies: ["crashed"])
        defer { try? fm.removeItem(at: root) }
        let inst = try installer(list, installed: crashed[0])
        #expect(throws: RuntimeInstallError.verificationFailed) { try inst.activateStaged { _ in false } }
        #expect(marker("wine", in: crashed[0]) == "wine v1" && marker("d3dmetal", in: crashed[0]) == "d3d v1")
        #expect(inst.installedVersion(of: "wine") == "1" && inst.installedSequence == 100)
        #expect(inst.failedSequence == 200 && !inst.hasStagedUpdate)
        #expect(!(try fm.contentsOfDirectory(atPath: crashed[0].path)).contains { $0.hasPrefix(".old-") || $0.hasPrefix(".ready-") })
    }

    /// Interrupted between the components: Wine is the new one, D3DMetal still the old one with the new one staged.
    @Test func aSwitchInterruptedHalfWayIsFinishedOrRolledBackAsAWhole() async throws {
        let (root, crashed, list) = try await interruptedSwitch(copies: ["finish", "undo"])
        defer { try? fm.removeItem(at: root) }
        for dir in crashed {
            let aside = try #require(try fm.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix(".old-d3dmetal-") })
            try fm.moveItem(at: dir.appending(path: "d3dmetal"), to: dir.appending(path: ".ready-d3dmetal"))
            try fm.moveItem(at: dir.appending(path: aside), to: dir.appending(path: "d3dmetal"))
            #expect(marker("wine", in: dir) == "wine v2" && marker("d3dmetal", in: dir) == "d3d v1")
        }
        let finish = try installer(list, installed: crashed[0])
        try finish.activateStaged()
        #expect(marker("wine", in: crashed[0]) == "wine v2" && marker("d3dmetal", in: crashed[0]) == "d3d v2")
        #expect(finish.installedSequence == 200 && !finish.hasStagedUpdate)

        let undo = try installer(list, installed: crashed[1])
        #expect(throws: RuntimeInstallError.verificationFailed) { try undo.activateStaged { _ in false } }
        #expect(marker("wine", in: crashed[1]) == "wine v1" && marker("d3dmetal", in: crashed[1]) == "d3d v1")
        #expect(undo.installedSequence == 100 && !undo.hasStagedUpdate)
    }

    /// Every packaging run gets a new sequence, also with unchanged components. Nothing is pending then, so
    /// nothing would bring the newer sequence along, and an app that needs it would never see it installed.
    @Test func aListPackagedAgainWithTheSameComponentsIsRecorded() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: then], ofItemAtPath: installed.appending(path: ".harbor-sequence").path)
        let inst = try installer(try serve([("wine", "1", "wine v1"), ("d3dmetal", "1", "d3d v1")], sequence: 200, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        #expect(inst.decision(for: manifest, appBuild: nil) == .upToDate)
        #expect(!inst.meetsMinimum(200))
        try await inst.stage(manifest, appBuild: nil)
        #expect(inst.installedSequence == 200 && inst.meetsMinimum(200))
        #expect(!inst.hasStagedUpdate)
        #expect(inst.installedDate == then)                               // nothing was installed just now
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

    /// A program that can't start on Windows support that is too old is told what is really going on.
    @Test func theStatusForTooOldWindowsSupportSaysWhatIsHappening() {
        func status(_ state: RuntimeUpdateState, running: String? = nil) -> String {
            state.statusWhileTooOld(starting: "Paint", running: running)
        }
        #expect(status(.checking) == "Updating Windows support first. Start Paint again when that’s done.")
        #expect(status(.downloading(0.3)) == status(.checking))
        #expect(status(.ready, running: "Notepad") == "Quit Notepad to finish updating Windows support, then start Paint again.")
        #expect(status(.ready) == "Quit your Windows programs to finish updating Windows support, then start Paint again.")
        #expect(status(.failed("The update server couldn’t be reached.")) == "Windows support couldn’t be updated: The update server couldn’t be reached.")
        #expect(status(.needsNewerApp).contains("needs a newer Harbor"))
        #expect(status(.failedBefore).contains("didn’t start on this Mac"))
        // Only "checking" and "downloading" may say that an update is under way.
        for state in [RuntimeUpdateState.ready, .needsNewerApp, .failedBefore, .failed("x"), .idle] {
            #expect(!status(state).contains("Updating"))
        }
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

    @Test func aFirstInstallWaitsForANewerHarborToo() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let installed = root.appending(path: "installed")
        let inst = try installer(try serve([("wine", "1", "wine v1")], sequence: 100, minimumAppBuild: 80, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        await #expect(throws: RuntimeInstallError.needsNewerApp(80)) { try await inst.installPending(manifest, appBuild: 79) }
        #expect(marker("wine", in: installed) == nil && inst.installedSequence == nil)
        try await inst.installPending(manifest, appBuild: 80)
        #expect(marker("wine", in: installed) == "wine v1" && inst.installedSequence == 100)
    }

    /// A list with a component this build doesn't know: an older Harbor is told to update (the list says from
    /// which build on), a new enough one takes the components it knows.
    @Test func aComponentThisHarborDoesntKnowIsLeftToANewerOne() async throws {
        let (root, installed) = try await installedV1()
        defer { try? fm.removeItem(at: root) }
        let added = try installer(try serve([("wine", "1", "wine v1"), ("d3dmetal", "1", "d3d v1"), ("future", "1", "new")],
                                            sequence: 200, minimumAppBuild: 80, in: root), installed: installed)
        let onlyNew = try await added.fetchManifest()
        #expect(added.decision(for: onlyNew, appBuild: 79) == .needsNewerApp(80))
        #expect(added.decision(for: onlyNew, appBuild: 80) == .upToDate)

        let inst = try installer(try serve([("wine", "2", "wine v2"), ("d3dmetal", "1", "d3d v1"), ("future", "1", "new")],
                                           sequence: 300, minimumAppBuild: 80, in: root), installed: installed)
        let manifest = try await inst.fetchManifest()
        #expect(inst.decision(for: manifest, appBuild: 79) == .needsNewerApp(80))
        #expect(inst.decision(for: manifest, appBuild: 80) == .available([manifest.components[0]]))
        try await inst.stage(manifest, appBuild: 80)
        try inst.activateStaged()
        #expect(marker("wine", in: installed) == "wine v2" && inst.installedSequence == 300)
        #expect(!fm.fileExists(atPath: installed.appending(path: "future").path))

        // The same on a first install.
        let fresh = try installer(inst.manifestURL, installed: root.appending(path: "fresh"))
        await #expect(throws: RuntimeInstallError.needsNewerApp(80)) { try await fresh.installPending(manifest, appBuild: 79) }
        try await fresh.installPending(manifest, appBuild: 80)
        #expect(Set(try fm.contentsOfDirectory(atPath: fresh.installedDirectory.path).filter { !$0.hasPrefix(".") }) == ["wine", "d3dmetal"])
        #expect(fresh.installedSequence == 300)
    }

    @Test func aComponentWithoutAUsableAddressIsAnErrorNotACrash() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let inst = try installer(try serve([("wine", "1", "wine v1")], sequence: 100, in: root), installed: root.appending(path: "installed"))
        var component = try await inst.fetchManifest().components[0]
        for url in ["", "http://[not a host"] {
            component.url = url
            await #expect(throws: RuntimeInstallError.badURL(component: "wine")) { try await inst.install(component) }
        }
        #expect(marker("wine", in: inst.installedDirectory) == nil)
    }

    /// A missing list or a server's error page is a failed download, not a list signed by someone else.
    @Test func anHTTPErrorIsntTakenForAnAnswer() throws {
        let url = try #require(URL(string: "https://example.invalid/runtime.json"))
        for status in [404, 500, 302] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            #expect(throws: URLError.self) { try RuntimeInstaller.checkStatus(response) }
        }
        try RuntimeInstaller.checkStatus(try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        // A file has no status.
        try RuntimeInstaller.checkStatus(URLResponse(url: URL(filePath: "/x/runtime.json"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        #expect(RuntimeInstallError.message(for: URLError(.badServerResponse)).hasPrefix("The update server couldn’t be reached"))
    }

    /// Without its sequence an installation has no downgrade protection and counts as too old for any minimum.
    @Test func aSequenceThatCantBeWrittenFailsTheInstall() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-upd-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let installed = root.appending(path: "installed")
        let inst = try installer(try serve([("wine", "1", "wine v1")], sequence: 100, in: root), installed: installed)
        // A folder where the record belongs: it can't be written.
        try fm.createDirectory(at: installed.appending(path: ".harbor-sequence/x"), withIntermediateDirectories: true)
        let manifest = try await inst.fetchManifest()
        await #expect(throws: (any Error).self) { try await inst.installPending(manifest) }
        #expect(inst.installedSequence == nil)
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
