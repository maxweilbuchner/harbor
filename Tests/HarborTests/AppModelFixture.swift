import Foundation
import Testing
@testable import Harbor
@testable import HarborKit

/// An app model's surroundings for a test: a library, a Trash, a shortcuts folder and a "wine" of its own (a
/// script, as in HarborKit's tests), all under `base`. Call `cleanUp` at the end.
@MainActor struct AppModelFixture {
    let fm = FileManager.default
    let base: URL
    let store: BottleStore
    let launcher: WineLauncher
    let shortcuts: AppShortcuts
    var bin: URL { base.appending(path: "wine/bin") }

    /// `start`: shell run in place of any program Wine is asked to start (`$C` is drive C:, `$APP` a Windows
    /// program to copy, `$BIN` Wine's folder). `stop`: shell run when the bottle's programs are ended
    /// (`wineserver -k`). A script that waits must end by itself: when `$BIN` is gone, or after a minute.
    init(start: String = "", stop: String = "") throws {
        base = fm.temporaryDirectory.appending(path: "harbor-model-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: base.appending(path: "wine/bin"), withIntermediateDirectories: true)
        let wine = """
        #!/bin/sh
        C="$WINEPREFIX/drive_c"; APP='\(Self.app.path)'; BIN="$(dirname "$0")"
        case "$1" in
        wineboot) mkdir -p "$C/windows" "$WINEPREFIX/dosdevices";;
        start) printf '%s\\n' "$*" >> "$BIN/calls"
        \(start)
        ;;
        esac
        """
        let wineserver = """
        #!/bin/sh
        BIN="$(dirname "$0")"
        case "$1" in
        -k) :
        \(stop)
        ;;
        esac
        """
        for (name, script) in [("wine", wine), ("wineserver", wineserver)] {
            try script.write(to: base.appending(path: "wine/bin/\(name)"), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appending(path: "wine/bin/\(name)").path)
        }
        launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")),
                                runtimesDirectory: base.appending(path: "runtimes"))
        store = BottleStore(directory: base.appending(path: "bottles"), trash: base.appending(path: "trash"))
        shortcuts = AppShortcuts(directory: base.appending(path: "shortcuts"))
    }

    /// HarborKit's test program (its tests' fixture; this target has no resources of its own).
    static let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "HarborKitTests/Fixtures/app64.exe")

    /// A model on this library that starts nothing by itself. The secret for store games' IDs is never saved:
    /// a rescan that ends after `cleanUp` would bring the folder back with it.
    func model(wine: Bool = true, installer: RuntimeInstaller? = nil, minimum: Int? = nil) -> AppModel {
        AppModel(store: store, launcher: wine ? launcher : nil, runtimeInstaller: installer, minimumRuntimeSequence: minimum,
                 shortcuts: shortcuts.directory, salt: LaunchSalt(file: URL(filePath: "/dev/null/launch-salt")),
                 templates: base.appending(path: "templates"), statistics: statistics, service: service, background: false)
    }

    /// Statistics kept in settings of the fixture's own, never the test runner's.
    var statistics: UsageStatistics { UsageStatistics(defaults: UserDefaults(suiteName: base.lastPathComponent)!) }
    /// Stands in for Harbor's service: accepts everything and writes each request's path and body to `sent`.
    var service: HarborService {
        let sent = base.appending(path: "sent")
        return HarborService { request in
            let line = (request.url?.lastPathComponent ?? "") + " " + String(decoding: request.httpBody ?? Data(), as: UTF8.self).filter { !$0.isNewline } + "\n"
            let old = (try? Data(contentsOf: sent)) ?? Data()
            try (old + Data(line.utf8)).write(to: sent)
            return (Data(#"{"reference":"AAAA-BBBB-CCCC-DDDD"}"#.utf8), 201)
        }
    }
    func sent() -> [String] {
        ((try? String(contentsOf: base.appending(path: "sent"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A bottle whose library holds `names`, each at `C:\Games\<name>.exe`, with Windows marked as up to date
    /// (so a start is a start, without the update that comes first otherwise).
    func bottle(_ name: String, programs names: [String]) throws -> (bottle: Bottle, programs: [Program]) {
        let bottle = try store.create(name: name)
        try fm.createDirectory(at: bottle.driveC.appending(path: "Games"), withIntermediateDirectories: true)
        try "disable".write(to: bottle.prefix.appending(path: ".update-timestamp"), atomically: true, encoding: .utf8)
        let programs = try names.map { name in
            try Data("MZ".utf8).write(to: bottle.driveC.appending(path: "Games/\(name).exe"))
            return Program(name: name, windowsPath: #"C:\Games\\#(name).exe"#)
        }
        try bottle.savePrograms(programs)
        return (bottle, programs)
    }

    /// An installer to drop, at `path` below `base`.
    func installer(_ path: String = "Media/setup.exe") throws -> URL {
        let url = base.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.app, to: url)
        return url
    }

    /// The model's item for the program called `name`, once the library has been read.
    func item(_ name: String, in model: AppModel) async throws -> LibraryItem {
        await model.reload().value
        return try #require(model.library.first { $0.program.name == name })
    }

    /// What Wine was asked to start so far, one line per start.
    func calls() -> [String] {
        ((try? String(contentsOf: bin.appending(path: "calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func trashed() -> [String] { (try? fm.contentsOfDirectory(atPath: base.appending(path: "trash").path)) ?? [] }

    func wait(for what: String, until done: () -> Bool) async throws {
        for _ in 0..<1000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(done(), "\(what) never happened")
    }

    /// Every shortcut the model asked for so far has been made or removed.
    func shortcutsSettled() async {
        await withCheckedContinuation { done in
            shortcuts.scheduleSync([], keepingOthers: true, icon: { _ in nil }) { done.resume() }
        }
    }

    /// Removes everything, after the shortcuts being made in the background. The scripts that wait end with it.
    nonisolated func cleanUp() {
        let settled = DispatchSemaphore(value: 0)
        shortcuts.scheduleSync([], keepingOthers: true, icon: { _ in nil }) { settled.signal() }
        settled.wait()
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: base.lastPathComponent)
    }
}
