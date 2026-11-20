import AppKit
import HarborKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@main
struct HarborApp: App {
    @State private var model = AppModel()

    init() {
        // Running from `swift run` has no bundle; make it a regular foreground app anyway.
        NSApplication.shared.setActivationPolicy(.regular)
        // Development: HARBOR_APPEARANCE=dark|light renders Harbor in that appearance regardless of the system's
        // (WindowsTests/ui-screenshot.sh uses it to check both).
        switch ProcessInfo.processInfo.environment["HARBOR_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        _ = Updates.shared
    }

    var body: some Scene {
        WindowGroup("Harbor") {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                    .disabled(!Updates.shared.isAvailable)
            }
        }
    }
}

/// Sparkle app updates. Only runs inside a real Harbor.app (not under `swift run`), whose Info.plist carries
/// SUFeedURL and SUPublicEDKey. `HARBOR_UPDATE_FEED_URL` overrides the feed for local update tests.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Update tests (scripts/test-update.sh): check now, download in the background, install immediately.
        if ProcessInfo.processInfo.environment["HARBOR_UPDATE_TEST"] != nil, let updater = controller?.updater {
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["HARBOR_UPDATE_FEED_URL"]
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard ProcessInfo.processInfo.environment["HARBOR_UPDATE_TEST"] != nil else { return false }
        immediateInstallationBlock()
        return true
    }
}

@MainActor @Observable
final class AppModel {
    let store = BottleStore.default
    private(set) var launcher = AppModel.makeLauncher()
    /// Download of Windows support (the Wine runtime); nil when idle.
    var runtimeDownload: RuntimeDownload?
    /// Total download size offered on the empty state, once the manifest has been read.
    var runtimeDownloadSize: Int64?

    enum RuntimeDownload: Equatable {
        case running(Double)
        case failed(String)
    }

    private static func makeLauncher() -> WineLauncher? {
        WineRuntime.locate().map { WineLauncher(runtime: $0, d3dmetal: D3DMetalRedist.locate()) }
    }

    /// Where Windows support is downloaded from, and the key its list must be signed with (Info.plist,
    /// overridable by environment for development).
    private var runtimeInstaller: RuntimeInstaller? {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        guard let url = (env["HARBOR_RUNTIME_MANIFEST_URL"] ?? info["HarborRuntimeManifestURL"] as? String)
                .flatMap(URL.init(string:)),
              let keyText = Self.debugOverride(env["HARBOR_RUNTIME_PUBLIC_KEY"]) ?? info["HarborRuntimePublicKey"] as? String,
              let key = try? RuntimeSigning.publicKey(keyText) else { return nil }
        return RuntimeInstaller(manifestURL: url, publicKey: key)
    }

    /// Development builds may take the runtime signing key from the environment; release builds always use the
    /// key in their Info.plist, so the environment can't swap in another signer.
    private static func debugOverride(_ value: String?) -> String? {
        #if DEBUG
        return value
        #else
        return nil
        #endif
    }

    var canDownloadRuntime: Bool { runtimeInstaller != nil }

    func loadRuntimeOffer() async {
        guard let installer = runtimeInstaller, let manifest = try? await installer.fetchManifest() else { return }
        runtimeDownloadSize = installer.pending(in: manifest).reduce(0) { $0 + $1.size }
    }

    func installRuntime() async {
        guard let installer = runtimeInstaller else { return }
        runtimeDownload = .running(0)
        do {
            let manifest = try await installer.fetchManifest()
            try await installer.installPending(manifest) { fraction in
                Task { @MainActor in self.runtimeDownload = .running(fraction) }
            }
            installer.removeOldVersions()
            launcher = Self.makeLauncher()
            runtimeDownload = nil
            prepareTemplate()
            updateBottlesInBackground()
        } catch {
            runtimeDownload = .failed(String(describing: error))
        }
    }
    var bottles: [Bottle] = []
    /// Every program in every bottle, newest first.
    var library: [LibraryItem] = []
    /// Programs whose Wine process is running.
    var running: Set<LibraryItem.ID> = []
    /// The add-program sheet; nil when hidden.
    var addState: AddState?
    /// Asks before removing a program (and its bottle, if it's the last program in it).
    var pendingRemoval: LibraryItem?
    /// A dropped file whose product is already in the library: asks before installing it a second time.
    var pendingDuplicate: (file: URL, existing: LibraryItem, name: String)?

    struct AddState: Identifiable, Equatable {
        enum Phase: Equatable { case working(AddProgram.Step), store(GameStores.Store, GameStores.Step), component(String), updating, failed(String) }
        let id = UUID()
        var fileName: String
        var phase: Phase
    }
    var status: String?
    var rosettaAvailable = Rosetta.isAvailable

    init() {
        // The first scan happens before the window exists, so the library never flashes its empty state.
        show(Self.scan(store))
        prepareTemplate()
        // Distribution checks: `open --env HARBOR_SMOKE_TEST=/path/result.txt Harbor.app` makes the real, signed
        // app (launched through LaunchServices, as Gatekeeper sees it) set up a bottle, run a Windows command,
        // write the outcome and quit.
        if let output = ProcessInfo.processInfo.environment["HARBOR_SMOKE_TEST"] {
            Task { await runSmokeTest(writingTo: URL(filePath: output)) }
        }
    }

    private func runSmokeTest(writingTo output: URL) async {
        var lines = ["bundle \(Bundle.main.bundlePath)", "rosetta \(Rosetta.isAvailable)"]
        if launcher == nil, canDownloadRuntime {
            await installRuntime()
            if case .failed(let message) = runtimeDownload { lines.append("FAIL download: \(message)") }
            else { lines.append("downloaded runtime") }
        }
        if let launcher {
            lines.append("runtime \(launcher.runtime.root.path)")
            do {
                let bottle = try await store.create(name: "Smoke Test \(Int(Date().timeIntervalSince1970))",
                                                    setUp: launcher.initialize)
                let capture = output.appendingPathExtension("wine")
                FileManager.default.createFile(atPath: capture.path, contents: nil)
                try await launcher.execute(bottle, arguments: ["cmd", "/c", "ver"],
                                           output: try FileHandle(forWritingTo: capture))
                let ver = (try? String(contentsOf: capture, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).first { $0.contains("Windows") } ?? "?"
                lines.append("PASS \(ver)")
                try? launcher.shutdown(bottle)
                try? FileManager.default.removeItem(at: bottle.root)
                try? FileManager.default.removeItem(at: capture)
            } catch {
                lines.append("FAIL \(error)")
            }
        } else {
            lines.append("FAIL no Wine runtime found")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        NSApplication.shared.terminate(nil)
    }

    /// After Windows support was updated: refresh every bottle's Windows files one at a time in the background,
    /// so most programs start right away instead of updating on their first start.
    private func updateBottlesInBackground() {
        guard let launcher else { return }
        // A running bottle is left for later: its Windows session belongs to the previous Wine build.
        let bottles = store.list().filter { $0.needsWindowsUpdate(for: launcher.runtime) && !$0.isRunning() }
        Task.detached(priority: .background) {
            for bottle in bottles { try? await launcher.updateWindows(bottle) }
        }
    }

    /// Builds the pre-made Windows environment in the background, so dropping a program opens its installer
    /// within seconds instead of after a ~25 s setup.
    private func prepareTemplate() {
        guard let launcher else { return }
        Task.detached(priority: .utility) {
            // Old derived runtimes and templates (from earlier Wine builds) go first; in-use ones stay.
            Maintenance.collectGarbage(launcher: launcher)
            try? await PrefixTemplate(launcher: launcher).prepare()
        }
    }

    private var reloading: Task<Void, Never>?

    /// Rescans the bottles off the main actor (store manifests and icons are many files). Reloads run one after
    /// another; the returned task finishes once `library` shows this one's result.
    @discardableResult
    func reload() -> Task<Void, Never> {
        let (store, previous) = (store, reloading)
        let task = Task {
            await previous?.value
            show(await Task.detached { Self.scan(store) }.value)
        }
        reloading = task
        return task
    }

    private nonisolated static func scan(_ store: BottleStore) -> ([Bottle], [(LibraryEntry, NSImage?)]) {
        let bottles = store.list()
        return (bottles, Library.scan(bottles, salt: LaunchSalt()).map { ($0, $0.iconFile.flatMap(NSImage.init(contentsOf:))) })
    }

    private func show(_ scan: ([Bottle], [(LibraryEntry, NSImage?)])) {
        bottles = scan.0
        library = scan.1.map { entry, icon in
            LibraryItem(program: entry.program, bottle: entry.bottle, icon: icon,
                        managedByStore: entry.managedByStore, iconFile: entry.iconFile)
        }
        syncShortcuts()
    }

    /// Mac app shortcuts in ~/Applications/Harbor, one per program (off the main actor: icons go through sips;
    /// one sync at a time, since reloads can follow each other faster than a sync takes).
    private func syncShortcuts() {
        let items = library.map { ($0.program, $0.iconFile ?? $0.bottle.iconFile(for: $0.program)) }
        let icons = Dictionary(items.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        AppShortcuts().scheduleSync(items.map(\.0)) { program in
            icons[program.id].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
    }

    /// `harbor://launch/<program id>`, sent by the Mac app shortcuts.
    func handle(_ url: URL) {
        guard url.scheme == "harbor", url.host() == "launch",
              let id = UUID(uuidString: url.lastPathComponent) else { return }
        Task {
            await reloading?.value   // a program added a moment ago is in the library once its reload is done
            if let item = library.first(where: { $0.id == id }) { open(item) }
        }
    }

    /// Adds a dropped program or installer: a new bottle, the installer's own window if it has one, then the
    /// programs it installed.
    func add(_ file: URL, allowDuplicate: Bool = false) async {
        guard let launcher, addState == nil else { return }
        // Reading the file happens off the main actor, so a slow or hostile file can't freeze the window.
        let suggested = await Task.detached { AddProgram.suggestedName(for: file) }.value
        if !allowDuplicate, let name = suggested,
           let existing = library.first(where: { $0.bottle.settings.name.caseInsensitiveCompare(name) == .orderedSame }) {
            pendingDuplicate = (file, existing, name)
            return
        }
        addState = AddState(fileName: file.lastPathComponent, phase: .working(.analyzing))
        let flow = AddProgram(store: store, launcher: launcher)
        do {
            let (_, programs) = try await flow.add(file) { step in
                Task { @MainActor in
                    self.addState?.phase = .working(step)
                    // The installer window should come to the front, not hide behind Harbor.
                    if case .runningInstaller = step { self.bringWineToFront(since: Date()) }
                }
            }
            await reload().value
            addState = nil
            status = programs.count == 1 ? "Added \(programs[0].name)" : "Added \(programs.count) programs"
        } catch {
            reload()
            addState?.phase = .failed(String(describing: error))
        }
    }

    /// Installs a Windows component (Visual C++ runtime) into the program's bottle, showing progress.
    func install(_ recipe: Recipe, for item: LibraryItem) async {
        guard let launcher, addState == nil else { return }
        addState = AddState(fileName: recipe.name, phase: .component(item.program.name))
        do {
            try await launcher.install(recipe, in: item.bottle)
            addState = nil
        } catch {
            addState?.phase = .failed(String(describing: error))
        }
    }

    /// One click: downloads the store's installer, installs it into its own bottle, adds it and starts it. If the
    /// store is already set up, just opens it.
    func addStore(_ which: GameStores.Store) async {
        guard let launcher, addState == nil else { return }
        let stores = GameStores(store: store, launcher: launcher)
        if let bottle = stores.existingBottle(for: which),
           let item = library.first(where: { $0.bottle == bottle && !$0.managedByStore }) {
            open(item)
            return
        }
        addState = AddState(fileName: which.name, phase: .store(which, .downloading))
        do {
            let (bottle, program) = try await stores.install(which) { step in
                Task { @MainActor in self.addState?.phase = .store(which, step) }
            }
            await reload().value
            addState = nil
            if let item = library.first(where: { $0.bottle == bottle && $0.program.id == program.id }) { open(item) }
        } catch {
            reload()
            addState?.phase = .failed(String(describing: error))
        }
    }

    func open(_ item: LibraryItem) {
        guard let launcher else { return }
        // After a runtime update, Wine first refreshes the bottle's Windows files (20–30 s). Say so instead of
        // leaving people looking at nothing. Not while the bottle is still running from before the update (the
        // program is usually already open there, and the update would wait for it to quit).
        if item.bottle.needsWindowsUpdate(for: launcher.runtime), !item.bottle.isRunning(), addState == nil {
            addState = AddState(fileName: item.program.name, phase: .updating)
            Task {
                try? await launcher.updateWindows(item.bottle)
                addState = nil
                launchNow(item, with: launcher)
            }
            return
        }
        launchNow(item, with: launcher)
    }

    private func launchNow(_ item: LibraryItem, with launcher: WineLauncher) {
        let started = Date()
        running.insert(item.id)
        let id = item.id
        // The first launch of a game clones the D3DMetal runtime; keep that off the main actor.
        Task.detached {
            do {
                try launcher.launch(item.program, in: item.bottle) { exitStatus in
                    Task { @MainActor in
                        self.running.remove(id)
                        if exitStatus != 0 { self.explainFailure(of: item, exitStatus: exitStatus) }
                    }
                }
                await MainActor.run { self.bringWineToFront(since: started) }
            } catch {
                await MainActor.run {
                    self.running.remove(id)
                    self.status = "Couldn’t open \(item.program.name): \(error)"
                }
            }
        }
    }

    /// macOS doesn't activate a process Harbor starts; without this a game's fullscreen window would stay
    /// behind Harbor. Watches for Wine's app processes (of Harbor's runtimes) started since `start`, for up to 60 s.
    func bringWineToFront(since start: Date) {
        let roots = [WineRuntime.installedDirectory, WineLauncher.defaultRuntimesDirectory] + [launcher?.runtime.root].compactMap { $0 }
        Task {
            for _ in 0..<120 {
                if let app = NSWorkspace.shared.runningApplications.first(where: { app in
                    guard let exe = app.executableURL, let launched = WineApps.startDate(of: app.processIdentifier) else { return false }
                    return launched >= start.addingTimeInterval(-1) && WineApps.isHarborWine(executable: exe, runtimes: roots)
                }) {
                    app.activate()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A program that failed with a recognised cause, explained in an alert.
    struct Failure: Identifiable {
        let id = UUID()
        let item: LibraryItem
        let diagnosis: Diagnosis
        let log: URL
    }
    var failure: Failure?

    /// Reads the run's log; a recognised cause gets an alert with what to do, anything else the exit code.
    func explainFailure(of item: LibraryItem, exitStatus: Int32) {
        // Reading the log (lossily: logs aren't always UTF-8) stays off the main actor.
        let (bottle, name) = (item.bottle, item.program.name)
        Task {
            if let found = await Task.detached(operation: { bottle.diagnosis(forLatestRunOf: name) }).value {
                failure = Failure(item: item, diagnosis: found.diagnosis, log: found.log)
            } else {
                status = "\(name) quit unexpectedly (\(exitStatus))"
            }
        }
    }

    func showInFinder(_ item: LibraryItem) {
        if let exe = item.bottle.unixPath(forWindowsPath: item.program.windowsPath) {
            NSWorkspace.shared.activateFileViewerSelecting([exe])
        }
    }

    func setGame(_ item: LibraryItem, _ isGame: Bool) { update(item) { $0.isGame = isGame } }

    func setGraphics(_ item: LibraryItem, _ graphics: GraphicsBackend) {
        update(item) { $0.graphics = graphics == .automatic ? nil : graphics }
    }

    private func update(_ item: LibraryItem, _ change: (inout Program) -> Void) {
        var programs = item.bottle.programs()
        guard let i = programs.firstIndex(where: { $0.id == item.id }) else { return }
        change(&programs[i])
        try? item.bottle.savePrograms(programs)
        reload()
    }

    func confirmRemoval(_ item: LibraryItem) { pendingRemoval = item }

    /// Whether removing `item` also deletes its bottle (it's the last program in it).
    func removesBottle(_ item: LibraryItem) -> Bool { item.bottle.programs().count <= 1 }

    func remove(_ item: LibraryItem) {
        AppShortcuts().remove(item.id)
        if removesBottle(item) {
            try? launcher?.shutdown(item.bottle)
            // To the Trash, not deleted: a removal must be undoable (Finder's Put Back).
            do { try store.moveToTrash(item.bottle) } catch { status = "Couldn’t move \(item.program.name) to the Trash: \(error.localizedDescription)" }
        } else {
            try? item.bottle.savePrograms(item.bottle.programs().filter { $0.id != item.id })
        }
        pendingRemoval = nil
        reload()
    }

    func installRosetta() {
        status = "Installing Rosetta…"
        Task.detached {
            // The system's administrator prompt; softwareupdate needs root to install Rosetta.
            let failure = Rosetta.install()
            await MainActor.run {
                self.rosettaAvailable = Rosetta.isAvailable
                self.status = self.rosettaAvailable ? nil : "Rosetta wasn’t installed\(failure.map { ": \($0)" } ?? ".")"
            }
        }
    }

}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.rosettaAvailable {
                ContentUnavailableView {
                    Label("Rosetta Is Needed", systemImage: "cpu")
                } description: {
                    Text("Windows programs run through Apple’s Rosetta translation. It’s a free, one-time install from Apple.")
                } actions: {
                    Button("Install Rosetta") { model.installRosetta() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.launcher == nil {
                RuntimeDownloadView()
            } else {
                LibraryView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary).padding(8)
            }
        }
        .onOpenURL { model.handle($0) }
        .confirmationDialog(model.pendingDuplicate.map { "\($0.name) Is Already Installed" } ?? "",
                            isPresented: Binding(get: { model.pendingDuplicate != nil },
                                                 set: { if !$0 { model.pendingDuplicate = nil } })) {
            if let d = model.pendingDuplicate {
                Button("Open \(d.existing.program.name)") { model.pendingDuplicate = nil; model.open(d.existing) }
                Button("Install Again") {
                    model.pendingDuplicate = nil
                    Task { await model.add(d.file, allowDuplicate: true) }
                }
            }
        } message: {
            Text("Installing again creates a second, separate copy.")
        }
        .alert(model.failure.map { "\($0.item.program.name) Couldn’t Run" } ?? "",
               isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
               presenting: model.failure) { failure in
            if let recipe = failure.diagnosis.recipe {
                Button("Install \(recipe.name)") { Task { await model.install(recipe, for: failure.item) } }
            }
            Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([failure.log]) }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.diagnosis.message(for: failure.item.program.name))
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { model.pendingRemoval != nil },
                                                               set: { if !$0 { model.pendingRemoval = nil } }),
                            presenting: model.pendingRemoval) { item in
            Button(model.removesBottle(item) ? "Move to Trash" : "Remove", role: .destructive) {
                model.remove(item)
            }
        } message: { item in
            if model.removesBottle(item) {
                Text("Everything installed for \(item.program.name), including its saved data, goes to the Trash. You can put it back from there until you empty it.")
            } else {
                Text("Other programs installed alongside it stay in your library.")
            }
        }
    }

    private var removalTitle: String {
        model.pendingRemoval.map { "Remove \($0.program.name)?" } ?? ""
    }
}

struct RuntimeDownloadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Windows Support Isn’t Installed", systemImage: "arrow.down.circle")
        } description: {
            switch model.runtimeDownload {
            case .running(let fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 240)
                    Text("Downloading Windows support… \(Int(fraction * 100))%")
                }
            case .failed(let message):
                Text("The download didn’t finish: \(message)")
            case nil where model.canDownloadRuntime:
                Text(sizeText)
            case nil:
                Text("This development build has no download location. Run scripts/fetch-runtime.sh, then relaunch Harbor.")
            }
        } actions: {
            if model.canDownloadRuntime, !isRunning {
                Button(model.runtimeDownload == nil ? "Download Windows Support" : "Try Again") {
                    Task { await model.installRuntime() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .task { await model.loadRuntimeOffer() }
    }

    private var isRunning: Bool {
        if case .running = model.runtimeDownload { true } else { false }
    }

    private var sizeText: String {
        let base = "Harbor needs a one-time download to run Windows programs."
        guard let size = model.runtimeDownloadSize, size > 0 else { return base }
        return base + " (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
    }
}
