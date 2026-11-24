import Foundation
import os
import Testing
@testable import HarborKit

/// What the add sheet's Cancel and the component sheet's Stop rely on: a cancelled task keeps nothing and starts
/// nothing further (#56).
@Suite struct CancelInstallTests {
    let fm = FileManager.default
    let installs = AddProgramInstallTests()

    func wait(for file: URL, containing text: String = "") async throws {
        func there() -> Bool {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.isEmpty || content.contains(text)
        }
        for _ in 0..<1000 where !there() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(there(), "\(file.lastPathComponent) never appeared")
    }

    func trashed(_ base: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: base.appending(path: "trash").path)) ?? []
    }

    /// Cancel while Windows is being set up: the installer never starts, and the new bottle is removed.
    @Test(.timeLimit(.minutes(1))) func cancelledBeforeTheInstallerStartsLeavesNothing() async throws {
        let f = try installs.fixture(installer: #"touch "$BIN/started"; mkdir -p "$C/Games/Thing"; cp "$APP" "$C/Games/Thing/Thing.exe""#)
        defer { try? fm.removeItem(at: f.base) }
        let setup = try installs.program("Media/setup.exe", in: f.base)
        let (flow, made) = (f.flow, OSAllocatedUnfairLock<Bottle?>(initialState: nil))
        let task = Task {
            try await flow.add(setup, progress: { step in
                if case .preparingWindows = step { withUnsafeCurrentTask { $0?.cancel() } }
            }, created: { bottle in made.withLock { $0 = bottle } })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        // The caller learnt the bottle while it was being set up (to end what runs in it).
        let bottle = try #require(made.withLock { $0 })
        #expect(!fm.fileExists(atPath: bottle.root.path))
        #expect(f.store.list().isEmpty && trashed(f.base).isEmpty)
        #expect(!fm.fileExists(atPath: f.base.appending(path: "wine/bin/started").path))
    }

    /// Cancel while the installer runs: once it has ended (the app ends it), the bottle goes to the Trash with
    /// what was installed, and nothing is added.
    @Test(.timeLimit(.minutes(1))) func cancelledWhileTheInstallerRunsTrashesTheBottle() async throws {
        let f = try installs.fixture(installer: """
            touch "$BIN/started"
            while [ ! -f "$BIN/go" ]; do sleep 0.05; done
            mkdir -p "$C/Games/Thing"; cp "$APP" "$C/Games/Thing/Thing.exe"
            """)
        defer { try? fm.removeItem(at: f.base) }
        let setup = try installs.program("Media/setup.exe", in: f.base)
        let flow = f.flow
        let task = Task { try await flow.add(setup) }
        let bin = f.base.appending(path: "wine/bin")
        try await wait(for: bin.appending(path: "started"))
        task.cancel()
        try Data().write(to: bin.appending(path: "go"))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(f.store.list().isEmpty)
        #expect(trashed(f.base).count == 1)
    }

    /// The same installer left to finish is added: it is the cancelling that discards it.
    @Test(.timeLimit(.minutes(1))) func anInstallerThatWasOnlyWaitedForIsAdded() async throws {
        let f = try installs.fixture(installer: """
            touch "$BIN/started"
            while [ ! -f "$BIN/go" ]; do sleep 0.05; done
            mkdir -p "$C/Games/Thing"; cp "$APP" "$C/Games/Thing/Thing.exe"
            """)
        defer { try? fm.removeItem(at: f.base) }
        let setup = try installs.program("Media/setup.exe", in: f.base)
        let flow = f.flow
        let task = Task { try await flow.add(setup) }
        let bin = f.base.appending(path: "wine/bin")
        try await wait(for: bin.appending(path: "started"))
        try Data().write(to: bin.appending(path: "go"))
        let (_, programs) = try await task.value
        #expect(programs.map(\.windowsPath) == [#"C:\Games\Thing\Thing.exe"#])
        #expect(trashed(f.base).isEmpty)
    }

    /// Stop during a component's first installer: the second one doesn't start.
    @Test(.timeLimit(.minutes(1))) func aCancelledComponentInstallStartsNoFurtherInstaller() async throws {
        let recipes = RecipeInstallTests()
        let go = fm.temporaryDirectory.appending(path: "harbor-go-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: go) }
        let f = try recipes.fixture(exits: "*vc_x64.exe*) while [ ! -f '\(go.path)' ]; do sleep 0.05; done;;")
        defer { try? fm.removeItem(at: f.cache.deletingLastPathComponent()) }
        let (launcher, bottle, recipe, cache) = (f.launcher, f.bottle, f.recipe, f.cache)
        let task = Task { try await launcher.install(recipe, in: bottle, cache: cache) }
        try await wait(for: f.calls, containing: "vc_x64.exe")
        task.cancel()
        try Data().write(to: go)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try recipes.installersRun(f.calls) == ["x64"])
    }
}
