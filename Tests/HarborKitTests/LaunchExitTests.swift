import Foundation
import Testing
@testable import HarborKit

/// How a launch ended, what is said about it, and which log is its own (#63).
@Suite struct LaunchExitTests {
    let fm = FileManager.default
    let crashed = Diagnosis(cause: .crashed)
    let missing = Diagnosis(cause: .missingLibrary("MSVCP140.dll", recipe: "vcrun2022"))

    // MARK: What is reported

    @Test func aCleanExitReportsNothing() {
        #expect(WineExit(status: 0, duration: 1).report(diagnosis: crashed, stoppedByHarbor: false) == .nothing)
    }

    /// Many Windows programs return a non-zero code from an ordinary quit; the log of a long session may hold a
    /// helper's crash or a .NET complaint that has nothing to do with it.
    @Test func aNonZeroExitAfterMinutesReportsNothing() {
        let exit = WineExit(status: 1, duration: 300)
        #expect(exit.report(diagnosis: nil, stoppedByHarbor: false) == .nothing)
        #expect(exit.report(diagnosis: crashed, stoppedByHarbor: false) == .nothing)
        #expect(exit.report(diagnosis: Diagnosis(cause: .dotNet), stoppedByHarbor: false) == .nothing)
        #expect(exit.report(diagnosis: Diagnosis(cause: .antiCheat("BattlEye")), stoppedByHarbor: false) == .nothing)
        // A library the program itself couldn't load is about this program whenever it ended.
        #expect(exit.report(diagnosis: missing, stoppedByHarbor: false) == .cause(missing))
    }

    @Test func aProgramThatEndsRightAfterStartingIsReported() {
        let exit = WineExit(status: 53, duration: 2)
        #expect(exit.report(diagnosis: nil, stoppedByHarbor: false) == .unexplained)
        #expect(exit.report(diagnosis: crashed, stoppedByHarbor: false) == .cause(crashed))
        #expect(exit.report(diagnosis: missing, stoppedByHarbor: false) == .cause(missing))
        #expect(WineExit(status: 53, duration: WineExit.quickExit - 0.1).report(diagnosis: nil, stoppedByHarbor: false) == .unexplained)
        #expect(WineExit(status: 53, duration: WineExit.quickExit).report(diagnosis: nil, stoppedByHarbor: false) == .nothing)
    }

    /// Removing a running program stops its bottle (`wineserver -k`): Wine dies by SIGKILL, and that is no failure.
    @Test func whatHarborStoppedItselfReportsNothing() {
        for exit in [WineExit(status: 9, signalled: true, duration: 2), WineExit(status: 9, signalled: true, duration: 300),
                     WineExit(status: 1, duration: 2)] {
            #expect(exit.report(diagnosis: nil, stoppedByHarbor: true) == .nothing)
            #expect(exit.report(diagnosis: crashed, stoppedByHarbor: true) == .nothing)
            #expect(exit.report(diagnosis: missing, stoppedByHarbor: true) == .nothing)
        }
        // Killed by something else: told like any other end, soon after starting only.
        #expect(WineExit(status: 9, signalled: true, duration: 2).report(diagnosis: nil, stoppedByHarbor: false) == .unexplained)
        #expect(WineExit(status: 9, signalled: true, duration: 300).report(diagnosis: nil, stoppedByHarbor: false) == .nothing)
        // Signal 0 doesn't exist, but an end by signal is never a clean exit.
        #expect(WineExit(status: 0, signalled: true, duration: 2).report(diagnosis: nil, stoppedByHarbor: false) == .unexplained)
    }

    // MARK: What `run` tells its exit handler

    /// A launcher whose "wine" is the given shell script, and a bottle. Everything is under the returned folder.
    func fixture(wine script: String) throws -> (launcher: WineLauncher, bottle: Bottle, base: URL) {
        let base = fm.temporaryDirectory.appending(path: "harbor-exit-\(UUID().uuidString)")
        let wine = base.appending(path: "wine/bin/wine")
        try fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + script + "\n").write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let bottle = try BottleStore(directory: base.appending(path: "bottles")).create(name: "E")
        return (WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine"))), bottle, base)
    }

    func exit(of launcher: WineLauncher, in bottle: Bottle, arguments: [String], label: String = "run") async throws -> WineExit {
        try await withCheckedThrowingContinuation { done in
            do { try launcher.run(bottle, arguments: arguments, label: label) { done.resume(returning: $0) } } catch { done.resume(throwing: error) }
        }
    }

    @Test func anExitCodeAndAKillAreToldApart() async throws {
        let f = try fixture(wine: #"case "$1" in kill) kill -9 $$;; *) exit "$1";; esac"#)
        defer { try? fm.removeItem(at: f.base) }
        let code = try await exit(of: f.launcher, in: f.bottle, arguments: ["3"])
        #expect(code.status == 3 && !code.signalled)
        let killed = try await exit(of: f.launcher, in: f.bottle, arguments: ["kill"])
        #expect(killed.status == 9 && killed.signalled)
        let clean = try await exit(of: f.launcher, in: f.bottle, arguments: ["0"])
        #expect(clean.status == 0 && !clean.signalled && clean.duration >= 0)
        // `execute` still reports either as an error with that number.
        await #expect(throws: WineExitError.self) { try await f.launcher.execute(f.bottle, arguments: ["kill"]) }
    }

    /// Two launches under the same name: each exit handler gets the log its own launch wrote, whichever is newer.
    @Test func everyLaunchIsHandedItsOwnLog() async throws {
        let f = try fixture(wine: #"echo "this is $1""#)
        defer { try? fm.removeItem(at: f.base) }
        let first = try await exit(of: f.launcher, in: f.bottle, arguments: ["first"], label: "Game")
        let second = try await exit(of: f.launcher, in: f.bottle, arguments: ["second"], label: "Game")
        #expect(try String(contentsOf: #require(first.log), encoding: .utf8) == "this is first\n")
        #expect(try String(contentsOf: #require(second.log), encoding: .utf8) == "this is second\n")
        #expect(f.bottle.latestLog(label: "Game")?.lastPathComponent == second.log?.lastPathComponent)
        // Output sent elsewhere leaves no log to hand over.
        let elsewhere: WineExit = try await withCheckedThrowingContinuation { done in
            do { try f.launcher.run(f.bottle, arguments: ["x"], output: .nullDevice) { done.resume(returning: $0) } } catch { done.resume(throwing: error) }
        }
        #expect(elsewhere.log == nil)
    }

    /// The diagnosis of a launch reads that launch's log, not a newer one of the same name.
    @Test func aLaunchIsDiagnosedFromItsOwnLog() async throws {
        let f = try fixture(wine: #"[ "$1" = crash ] && echo "wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger..."; exit 5"#)
        defer { try? fm.removeItem(at: f.base) }
        let crash = try await exit(of: f.launcher, in: f.bottle, arguments: ["crash"], label: "Game")
        let quiet = try await exit(of: f.launcher, in: f.bottle, arguments: ["quiet"], label: "Game")
        #expect(f.bottle.diagnosis(ofLog: try #require(crash.log)) == crashed)
        #expect(f.bottle.diagnosis(ofLog: try #require(quiet.log)) == nil)
    }

    // MARK: Log rotation

    /// Ten and more runs within one second: the counter is a number, not text (".10" is newer than ".2").
    @Test func logsOfOneSecondAreOrderedByTheirCounter() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-exit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let b = try BottleStore(directory: base).create(name: "L")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        let names = ["20261119-100000-Foo.log"] + (2...11).map { "20261119-100000.\($0)-Foo.log" } + ["20261119-100001-Foo.log", "20261119-095959.3-Zed.log"]
        for name in names { try Data().write(to: b.logsDirectory.appending(path: name)) }
        #expect(b.logs().map(\.lastPathComponent)
                == ["20261119-100001-Foo.log"] + (2...11).reversed().map { "20261119-100000.\($0)-Foo.log" }
                    + ["20261119-100000-Foo.log", "20261119-095959.3-Zed.log"])
        #expect(b.latestLog(label: "Foo")?.lastPathComponent == "20261119-100001-Foo.log")
    }

    /// Rotation removes the oldest logs, but not one that a program still running is writing.
    @Test func rotationKeepsTheLogOfALaunchThatIsStillRunning() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-exit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let b = try BottleStore(directory: base).create(name: "L")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        let old = ["20200101-100000-Game.log", "20200101-100001-Tool.log", "20200101-100002-Tool.log"].map { b.logsDirectory.appending(path: $0) }
        for file in old { try Data().write(to: file) }
        Bottle.logsInUse.withLock { _ = $0.insert(old[0].resolvingSymlinksInPath().path) }
        defer { Bottle.logsInUse.withLock { _ = $0.remove(old[0].resolvingSymlinksInPath().path) } }
        let new = try b.newLog(label: "New", keep: 2).file
        #expect(Set(b.logs().map(\.lastPathComponent)) == [old[0].lastPathComponent, old[2].lastPathComponent, new.lastPathComponent])
    }

    /// While its program runs, a launch's log is marked as in use, and no longer once it has ended.
    @Test(.timeLimit(.minutes(1))) func aRunningLaunchKeepsItsLogThroughRotation() async throws {
        // A "program" that runs until the file it is given appears.
        let f = try fixture(wine: #"n=0; while [ ! -e "$1" ] && [ $n -lt 1200 ]; do sleep 0.05; n=$((n+1)); done"#)
        defer { try? fm.removeItem(at: f.base) }
        let go = f.base.appending(path: "go")
        let (exits, feed) = AsyncStream.makeStream(of: WineExit.self)
        try f.launcher.run(f.bottle, arguments: [go.path], label: "Game") { feed.yield($0); feed.finish() }
        let log = try #require(f.bottle.latestLog(label: "Game"))
        _ = try f.bottle.newLog(label: "Other", keep: 1)
        #expect(fm.fileExists(atPath: log.path))
        try Data().write(to: go)
        let ended = try #require(await exits.first { _ in true })
        #expect(ended.log?.lastPathComponent == log.lastPathComponent)
        // Once it has ended its log is rotated like any other.
        _ = try f.bottle.newLog(label: "Other", keep: 1)
        #expect(!fm.fileExists(atPath: log.path))
    }
}
