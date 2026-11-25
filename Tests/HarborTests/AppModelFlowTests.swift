import Foundation
import Testing
@testable import Harbor
@testable import HarborKit

/// What the app model decides when a shortcut's link comes in and when a program is added, opened, removed or
/// ends (#85). The library, the Trash, the shortcuts and Wine are the fixture's.
@MainActor @Suite struct AppModelFlowTests {
    let fm = FileManager.default

    /// A "program" that runs until its file says how to end: the first one started reads `go1`, the next `go2`.
    static let waits = """
        if mkdir "$BIN/first" 2>/dev/null; then go="$BIN/go1"; else go="$BIN/go2"; fi
        n=0; while [ ! -s "$go" ] && [ -d "$BIN" ] && [ $n -lt 1200 ]; do sleep 0.05; n=$((n+1)); done
        exit "$(cat "$go" 2>/dev/null || echo 0)"
        """

    /// An "installer" that installs `C:\\Games\\Thing\\Thing.exe` once `go` is there.
    static let installsWhenTold = """
        touch "$BIN/started"
        n=0; while [ ! -f "$BIN/go" ] && [ -d "$BIN" ] && [ $n -lt 1200 ]; do sleep 0.05; n=$((n+1)); done
        [ -d "$BIN" ] || exit 0
        mkdir -p "$C/Games/Thing"; cp "$APP" "$C/Games/Thing/Thing.exe"
        """

    func end(_ go: String, with status: Int, in f: AppModelFixture) throws {
        try "\(status)\n".write(to: f.bin.appending(path: go), atomically: true, encoding: .utf8)
    }

    // MARK: Statistics (#50)

    /// A program that ends is counted and the record sent only after the user agreed; before, nothing leaves.
    @Test(.timeLimit(.minutes(1))) func programsAreCountedOnlyAfterAgreeing() async throws {
        let f = try AppModelFixture(start: "exit 0")
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        let model = f.model()
        let item = try await f.item("Thing", in: model)
        #expect(model.sharesStatistics == nil && model.nextStatistics == nil)
        model.open(item)
        try await f.wait(for: "the first end") { f.calls().count == 1 && model.running.isEmpty }
        model.shareStatistics(false)
        model.open(item)
        try await f.wait(for: "the second end") { f.calls().count == 2 && model.running.isEmpty }
        #expect(model.nextStatistics == nil && f.sent().isEmpty)

        model.shareStatistics(true)
        model.open(item)
        try await f.wait(for: "the record") { f.sent().count == 1 }
        #expect(f.sent()[0].hasPrefix("statistics {") && f.sent()[0].contains(#""ran" : 1"#))
        #expect(!f.sent()[0].contains("Thing"))
        try await f.wait(for: "the counts to be taken off") { model.nextStatistics == nil }
    }

    // MARK: harbor://launch/<id>

    @Test(.timeLimit(.minutes(1))) func aShortcutsLinkOpensItsProgram() async throws {
        let f = try AppModelFixture(start: Self.waits)
        defer { f.cleanUp() }
        let made = try f.bottle("Suite", programs: ["Word", "Sheet"])
        let model = f.model()
        model.handle(AppShortcuts.launchURL(for: made.programs[1]))
        try await f.wait(for: "the start") { f.calls().count == 1 }
        #expect(f.calls().first?.hasPrefix("start /wait /unix /") == true)
        #expect(f.calls().first?.hasSuffix("/bottles/suite/prefix/drive_c/Games/Sheet.exe") == true)
        #expect(model.running == [made.programs[1].id] && model.status == nil)
    }

    /// A shortcut that outlived its program, and links that aren't a shortcut's: said, and nothing is started.
    @Test(.timeLimit(.minutes(1))) func aLinkToNoProgramOpensNothing() async throws {
        let f = try AppModelFixture(start: Self.waits)
        defer { f.cleanUp() }
        let id = try f.bottle("Thing", programs: ["Thing"]).programs[0].id.uuidString
        let model = f.model()
        // Not Harbor's kind of link at all: nothing happens, not even a line.
        model.handle(try #require(URL(string: "https://launch/\(id)")))
        for link in ["harbor://launch/\(UUID().uuidString)", "harbor://launch/not-an-id", "harbor://launch",
                     "harbor://open/\(id)", "harbor://launch/\(id)/twice"] {
            model.status = nil
            model.handle(try #require(URL(string: link)))
            try await f.wait(for: "the answer to \(link)") { model.status != nil }
            #expect(model.status == "That shortcut’s program isn’t in Harbor any more.", "\(link)")
        }
        #expect(model.running.isEmpty && f.calls().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aLinkWithoutWindowsSupportSaysWhatIsMissing() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        let program = try f.bottle("Thing", programs: ["Thing"]).programs[0]
        let model = f.model(wine: false)
        model.handle(AppShortcuts.launchURL(for: program))
        try await f.wait(for: "the answer") { model.status != nil }
        #expect(model.status == "Download Windows support to open Thing." && model.running.isEmpty)
    }

    // MARK: Adding

    /// The first add is still reading its file (a named pipe that someone holds open for writing isn't read to
    /// its end): a second one is refused, and Cancel then leaves nothing of the first.
    @Test(.timeLimit(.minutes(1))) func aSecondAddWhileTheFirstFileIsBeingReadIsRefused() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        let slow = f.base.appending(path: "Media/slow.exe")
        try fm.createDirectory(at: slow.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(mkfifo(slow.path, 0o644) == 0)
        let held = try FileHandle(forUpdating: slow)
        defer { try? held.close() }
        let other = try f.installer("Other/setup.exe")
        let model = f.model()
        let first = Task { await model.add(slow) }
        try await f.wait(for: "the first add") { model.addState != nil }

        await model.add(other)
        #expect(model.status == AppModel.oneAtATime)
        #expect(model.addState?.fileName == "slow.exe" && model.addState?.phase == .working(.analyzing))
        // The sheet goes at once; the add itself ends when the read does.
        model.cancelAdd()
        #expect(model.addState == nil)
        try held.close()
        await first.value
        #expect(model.addState == nil && model.pendingDuplicate == nil)
        #expect(f.store.list().isEmpty && f.trashed().isEmpty && f.calls().isEmpty)
    }

    /// A product that is in the library already is asked about, and installed a second time only on that answer.
    @Test(.timeLimit(.minutes(1))) func addingWhatIsInstalledAlreadyAsksFirst() async throws {
        let f = try AppModelFixture(start: #"mkdir -p "$C/Games/Thing"; cp "$APP" "$C/Games/Thing/Thing.exe""#)
        defer { f.cleanUp() }
        _ = try f.bottle("fixture app", programs: ["Old"])
        let model = f.model()
        let old = try await f.item("Old", in: model)
        let setup = try f.installer()
        await model.add(setup)
        let asked = try #require(model.pendingDuplicate)
        #expect(asked.file == setup && asked.existing == old && asked.name == "Fixture App")
        #expect(model.addState == nil && f.store.list().count == 1 && f.calls().isEmpty)

        // "Install Again".
        model.pendingDuplicate = nil
        await model.add(setup, allowDuplicate: true)
        #expect(model.pendingDuplicate == nil && model.addState == nil && model.status == "Added Fixture App")
        #expect(f.store.list().count == 2 && f.calls().count == 1)
        #expect(Set(model.library.map(\.program.windowsPath)) == [#"C:\Games\Old.exe"#, #"C:\Games\Thing\Thing.exe"#])
    }

    /// The installer runs and the model has heard of it: the sheet says so, and its buttons have the bottle
    /// (which the model learnt before).
    func installerRuns(in model: AppModel, _ f: AppModelFixture) async throws {
        try await f.wait(for: "the installer") {
            fm.fileExists(atPath: f.bin.appending(path: "started").path)
                && model.addState?.phase == .working(.runningInstaller(name: "Fixture App"))
        }
    }

    /// The sheet's Cancel while the installer runs: the installer is ended, and what it left goes to the Trash.
    @Test(.timeLimit(.minutes(1))) func cancellingAnAddKeepsNothingOfIt() async throws {
        let f = try AppModelFixture(start: Self.installsWhenTold, stop: #"touch "$BIN/go""#)
        defer { f.cleanUp() }
        let setup = try f.installer()
        let model = f.model()
        let add = Task { await model.add(setup) }
        try await installerRuns(in: model, f)
        model.cancelAdd()
        await add.value
        await model.reload().value
        #expect(model.addState == nil && model.status == nil && model.library.isEmpty)
        #expect(f.store.list().isEmpty && f.trashed().count == 1)
    }

    /// The sheet's Stop ends the installer the same way, but the add goes on: what was installed is added.
    @Test(.timeLimit(.minutes(1))) func stoppingAnAddKeepsWhatWasInstalled() async throws {
        let f = try AppModelFixture(start: Self.installsWhenTold, stop: #"touch "$BIN/go""#)
        defer { f.cleanUp() }
        let setup = try f.installer()
        let model = f.model()
        let add = Task { await model.add(setup) }
        try await installerRuns(in: model, f)
        model.stopAdd()
        await add.value
        #expect(model.addState == nil && model.status == "Added Fixture App")
        #expect(model.library.map(\.program.windowsPath) == [#"C:\Games\Thing\Thing.exe"#])
        #expect(f.store.list().count == 1 && f.trashed().isEmpty)
    }

    // MARK: Removing

    @Test(.timeLimit(.minutes(1))) func removingABottlesOnlyProgramMovesTheBottleToTheTrash() async throws {
        let f = try AppModelFixture(stop: #"touch "$BIN/stopped""#)
        defer { f.cleanUp() }
        _ = try f.bottle("Solo", programs: ["Solo"])
        _ = try f.bottle("Other", programs: ["Other"])
        let model = f.model()
        let solo = try await f.item("Solo", in: model)
        await f.shortcutsSettled()
        #expect(Set(f.shortcuts.existing().keys) == Set(model.library.map(\.id)))
        #expect(model.removesBottle(solo))

        model.confirmRemoval(solo)
        model.remove(solo)
        // Out of the library at once, while its programs are being ended.
        #expect(model.pendingRemoval == nil && model.library.map(\.program.name) == ["Other"])
        // The removal ends with a look at the library, which is how a bottle made meanwhile gets into it.
        _ = try f.bottle("Late", programs: ["Late"])
        try await f.wait(for: "the library after the removal") { model.library.contains { $0.program.name == "Late" } }
        #expect(f.trashed().count == 1 && fm.fileExists(atPath: f.bin.appending(path: "stopped").path))
        await f.shortcutsSettled()
        #expect(f.store.list().map(\.settings.name) == ["Late", "Other"] && Set(model.library.map(\.program.name)) == ["Late", "Other"])
        #expect(Set(f.shortcuts.existing().keys) == Set(model.library.map(\.id)))
        #expect(model.status == nil)
    }

    @Test(.timeLimit(.minutes(1))) func removingOneOfABottlesProgramsLeavesTheBottle() async throws {
        let f = try AppModelFixture(stop: #"touch "$BIN/stopped""#)
        defer { f.cleanUp() }
        let suite = try f.bottle("Suite", programs: ["Word", "Sheet"]).bottle
        let model = f.model()
        let word = try await f.item("Word", in: model)
        #expect(!model.removesBottle(word))

        model.confirmRemoval(word)
        model.remove(word)
        #expect(model.pendingRemoval == nil && suite.programs().map(\.name) == ["Sheet"])
        await model.reload().value
        await f.shortcutsSettled()
        #expect(model.library.map(\.program.name) == ["Sheet"] && model.status == nil)
        #expect(Set(f.shortcuts.existing().keys) == Set(model.library.map(\.id)))
        // The bottle is where it was, and what runs in it goes on.
        #expect(f.store.list().map(\.settings.name) == ["Suite"] && f.trashed().isEmpty)
        #expect(!fm.fileExists(atPath: f.bin.appending(path: "stopped").path))
    }

    /// A list of programs with an entry Harbor can't read isn't written over: the program stays, and so does
    /// its shortcut.
    @Test(.timeLimit(.minutes(1))) func aProgramsFileThatCantBeReadWhollyIsNotWrittenTo() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        let suite = try f.bottle("Suite", programs: ["Word", "Sheet"]).bottle
        var entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: suite.programsFile)) as? [Any])
        entries.append(["name": 5])
        let damaged = try JSONSerialization.data(withJSONObject: entries)
        try damaged.write(to: suite.programsFile)
        let model = f.model()
        let word = try await f.item("Word", in: model)
        await f.shortcutsSettled()
        #expect(model.damaged.map(\.lastPathComponent) == ["suite"] && !model.removesBottle(word))

        model.remove(word)
        #expect(model.status?.hasPrefix("Couldn’t remove Word: ") == true && model.pendingRemoval == nil)
        #expect(try Data(contentsOf: suite.programsFile) == damaged)
        await model.reload().value
        await f.shortcutsSettled()
        #expect(Set(model.library.map(\.program.name)) == ["Word", "Sheet"])
        #expect(f.shortcuts.existing()[word.id] != nil && f.trashed().isEmpty)
    }

    /// One readable program beside an unreadable entry: the bottle is not treated as that program's alone, so
    /// removing it can't move what Harbor couldn't read to the Trash.
    @Test(.timeLimit(.minutes(1))) func theOnlyReadableProgramOfADamagedRecordDoesntTakeTheBottleAlong() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        let suite = try f.bottle("Suite", programs: ["Word"]).bottle
        var entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: suite.programsFile)) as? [Any])
        entries.append(["name": 5])
        let damaged = try JSONSerialization.data(withJSONObject: entries)
        try damaged.write(to: suite.programsFile)
        let model = f.model()
        let word = try await f.item("Word", in: model)
        await f.shortcutsSettled()
        #expect(!model.removesBottle(word))

        model.remove(word)
        #expect(model.status?.hasPrefix("Couldn’t remove Word: ") == true)
        #expect(try Data(contentsOf: suite.programsFile) == damaged && f.trashed().isEmpty)
    }

    // MARK: Opening

    func runtimeInstaller(_ f: AppModelFixture) throws -> RuntimeInstaller {
        // The list is a file that isn't there: looking for an update fails without asking the network.
        RuntimeInstaller(manifestURL: f.base.appending(path: "served/runtime.json"),
                         publicKey: try RuntimeSigning.publicKey(try RuntimeSigning.publicKey(forPrivate: RuntimeSigning.newPrivateKey())),
                         installedDirectory: f.base.appending(path: "installed"))
    }

    /// While a downloaded update is being switched to and proven, nothing is started or added; afterwards
    /// (here the new Wine doesn't start, and the previous support stays) programs open again.
    @Test(.timeLimit(.minutes(2))) func nothingStartsWhileWindowsSupportIsBeingSwitched() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        let installer = try runtimeInstaller(f)
        // The update: a Wine that takes its time to say that it doesn't work.
        let wine = installer.installedDirectory.appending(path: RuntimeInstaller.readyPrefix + "wine/bin/wine")
        try fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            touch '\(f.base.path)/proving'
            n=0; while [ ! -f '\(f.base.path)/proved' ] && [ -d '\(f.bin.path)' ] && [ $n -lt 1000 ]; do sleep 0.05; n=$((n+1)); done
            exit 1
            """.write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try Data().write(to: installer.installedDirectory.appending(path: RuntimeInstaller.stagedMarker))
        let setup = try f.installer()
        let model = f.model(installer: installer)
        let thing = try await f.item("Thing", in: model)

        model.checkForRuntimeUpdate()
        try await f.wait(for: "the switch") { fm.fileExists(atPath: f.base.appending(path: "proving").path) }
        model.open(thing)
        #expect(model.status == "Windows support is being updated; try again in a moment." && model.running.isEmpty)
        model.status = nil
        await model.add(setup)
        #expect(model.status == "Windows support is being updated; try again in a moment." && model.addState == nil)

        try Data().write(to: f.base.appending(path: "proved"))
        try await f.wait(for: "the end of the switch") { if case .failed = model.runtimeUpdate { true } else { false } }
        #expect(f.store.list().count == 1 && f.calls().isEmpty)
        model.open(thing)
        #expect(model.running == [thing.id])
        try await f.wait(for: "the start") { f.calls().count == 1 }
    }

    /// Windows support older than this Harbor needs: the program isn't started, an update is looked for at
    /// once, and how that went replaces the first line.
    @Test(.timeLimit(.minutes(1))) func aProgramWaitsForWindowsSupportThatIsTooOld() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        let installer = try runtimeInstaller(f)
        try fm.createDirectory(at: installer.installedDirectory, withIntermediateDirectories: true)
        try Data("100\n".utf8).write(to: installer.installedDirectory.appending(path: RuntimeInstaller.sequenceFile))
        let model = f.model(installer: installer, minimum: 200)
        let thing = try await f.item("Thing", in: model)
        #expect(model.runtimeIsTooOld && model.runtimeUpdate == .idle)

        model.open(thing)
        #expect(model.status == "Updating Windows support first. Start Thing again when that’s done.")
        #expect(model.runtimeUpdate == .checking && model.running.isEmpty)
        try await f.wait(for: "the check") { !model.runtimeUpdate.isBusy }
        // Asked for, so its failure is told.
        #expect(model.status?.hasPrefix("Windows support couldn’t be updated: ") == true)
        #expect(model.running.isEmpty && f.calls().isEmpty)

        // The same installation under a Harbor that asks for no more than it is: started.
        let content = f.model(installer: installer, minimum: 100)
        content.open(try await f.item("Thing", in: content))
        #expect(content.running == [thing.id] && content.status == nil)
        try await f.wait(for: "the start") { f.calls().count == 1 }
    }

    // MARK: How a program ended

    /// Something the model reports for certain, and after the exits before it: once its alert is up, a line
    /// about one of those would be up too.
    func aLaterCrash(of item: LibraryItem, isReportedBy model: AppModel, _ f: AppModelFixture) async throws {
        let log = f.base.appending(path: "crash.log")
        try "wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger...\n"
            .write(to: log, atomically: true, encoding: .utf8)
        model.explainFailure(of: item, exit: WineExit(status: 5, duration: 1, log: log))
        try await f.wait(for: "the alert") { model.failure != nil }
        #expect(model.failure?.item == item)
    }

    @Test(.timeLimit(.minutes(1))) func aProgramThatEndsRightAfterStartingIsReported() async throws {
        let f = try AppModelFixture(start: "exit 3")
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        let model = f.model()
        model.open(try await f.item("Thing", in: model))
        try await f.wait(for: "its end") { model.status != nil }
        #expect(model.status == "Thing quit unexpectedly (3)" && model.running.isEmpty && model.failure == nil)
    }

    /// The same exit code minutes after the start is an ordinary quit; right after it, or a kill, is told.
    @Test(.timeLimit(.minutes(1))) func anExitLongAfterTheStartIsNotReported() async throws {
        let f = try AppModelFixture()
        defer { f.cleanUp() }
        _ = try f.bottle("Suite", programs: ["Word", "Sheet"])
        let model = f.model()
        let word = try await f.item("Word", in: model), sheet = try await f.item("Sheet", in: model)
        model.explainFailure(of: word, exit: WineExit(status: 3, duration: 300))
        model.explainFailure(of: word, exit: WineExit(status: 9, signalled: true, duration: 300))
        try await aLaterCrash(of: sheet, isReportedBy: model, f)
        #expect(model.status == nil)

        model.explainFailure(of: word, exit: WineExit(status: 3, duration: 1))
        try await f.wait(for: "the line") { model.status != nil }
        #expect(model.status == "Word quit unexpectedly (3)")
        model.explainFailure(of: word, exit: WineExit(status: 9, signalled: true, duration: 1))
        try await f.wait(for: "the next line") { model.status != "Word quit unexpectedly (3)" }
        #expect(model.status == "Word was stopped unexpectedly")
    }

    /// Quit from its tile: the program ends with the code that is reported in the test above, and nothing is said.
    @Test(.timeLimit(.minutes(1))) func aProgramHarborQuitItselfIsNotReported() async throws {
        let f = try AppModelFixture(start: Self.waits, stop: #"echo 3 > "$BIN/go1""#)
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        _ = try f.bottle("Other", programs: ["Other"])
        let model = f.model()
        let thing = try await f.item("Thing", in: model), other = try await f.item("Other", in: model)
        model.open(thing)
        try await f.wait(for: "the start") { f.calls().count == 1 }
        #expect(model.isRunning(thing) && !model.isRunning(other))
        model.quit(thing)
        try await f.wait(for: "its end") { model.running.isEmpty }
        try await aLaterCrash(of: other, isReportedBy: model, f)
        #expect(model.status == nil)
    }

    /// Opened twice, a program is running until the second of them has ended.
    @Test(.timeLimit(.minutes(1))) func aProgramOpenedTwiceRunsUntilBothHaveEnded() async throws {
        let f = try AppModelFixture(start: Self.waits)
        defer { f.cleanUp() }
        _ = try f.bottle("Thing", programs: ["Thing"])
        let model = f.model()
        let thing = try await f.item("Thing", in: model)
        model.open(thing)
        model.open(thing)
        try await f.wait(for: "both starts") { f.calls().count == 2 }
        #expect(model.running == [thing.id])
        // The first one's end is seen by what is said about it.
        try end("go1", with: 3, in: f)
        try await f.wait(for: "the first end") { model.status != nil }
        #expect(model.status == "Thing quit unexpectedly (3)" && model.running == [thing.id])
        try end("go2", with: 0, in: f)
        try await f.wait(for: "the second end") { model.running.isEmpty }
    }
}
