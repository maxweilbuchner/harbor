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
        // One library window: without tabs there is no tab bar whose "+" would open a second.
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = Updates.shared
    }

    var body: some Scene {
        // A window group, not `Window`: an app whose main scene is a `Window` quits when that window is closed,
        // and Harbor stays (a download goes on, running programs are watched, the Dock icon brings the window back).
        WindowGroup("Harbor") {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
                // A `harbor://` link from a Mac shortcut goes to the window that is open instead of opening
                // another one. With the window closed, the group opens it for the link as before.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .commands {
            // In place of File > New Window: a second window would show the same sheets and alerts as the first.
            CommandGroup(replacing: .newItem) { LibraryCommands(model: model) }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                    .disabled(!Updates.shared.isAvailable)
            }
            // In place of "Harbor Help", which only says that there is none.
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { model.reportProblem() }
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The File menu: what the toolbar's "+" and a tile's context menu do, for the keyboard. Both values come from
/// the library window (`LibraryView`), so the items are off while it is closed or shows something else.
struct LibraryCommands: View {
    let model: AppModel
    @FocusedValue(\.addProgram) private var addProgram
    @FocusedValue(\.selectedProgram) private var selected

    var body: some View {
        Button("Add Program…") { addProgram?() }
            .keyboardShortcut("o")
            .disabled(addProgram == nil)
        Divider()
        // Without a key here: Return as a menu key would be taken from the search field and from every dialog's
        // default button. The grid opens the selected program on Return itself.
        Button("Open") { if let selected { model.open(selected) } }
            .disabled(selected == nil)
        // Programs a store installed are removed in the store, as in the context menu.
        Button("Remove from Library…") { if let selected { model.confirmRemoval(selected) } }
            .keyboardShortcut(.delete)
            .disabled(selected.map(\.managedByStore) ?? true)
    }
}

/// Development builds may take update and download settings from the environment. Release builds never do: what
/// they use is in their Info.plist, written when the bundle is built (scripts/bundle-app.sh takes test URLs then),
/// so nothing in a user's environment can redirect a shipped app.
func debugOverride(_ value: String?) -> String? {
    #if DEBUG
    return value
    #else
    return nil
    #endif
}

/// Sparkle app updates. Only runs inside a real Harbor.app (not under `swift run`), whose Info.plist carries
/// SUFeedURL and SUPublicEDKey. For update tests, scripts/bundle-app.sh builds a bundle with a test feed and the
/// `HarborUpdateTest` flag (check at once, install without asking).
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
        if Self.isUpdateTest, let updater = controller?.updater {
            updater.automaticallyDownloadsUpdates = true
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle's own setting (kept in the app's defaults), shown in Settings.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Set only in bundles built for update tests; scripts/release-app.sh refuses to publish one.
    nonisolated static var isUpdateTest: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HarborUpdateTest") as? Bool == true
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        debugOverride(ProcessInfo.processInfo.environment["HARBOR_UPDATE_FEED_URL"])
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard Self.isUpdateTest else { return false }
        immediateInstallationBlock()
        return true
    }
}

@MainActor @Observable
final class AppModel {
    let store: BottleStore
    private(set) var launcher: WineLauncher? {
        didSet { runtimeVersions = Self.versions(of: launcher) }
    }
    /// The Mac shortcuts' folder, the secret in the store games' IDs and the pre-made Windows environments'
    /// folder: the user's own, except in tests.
    private let shortcuts: AppShortcuts
    private let salt: LaunchSalt
    private let templates: URL
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

    /// Where Windows support is downloaded from, and the key its list must be signed with (Info.plist; development
    /// builds may override both by environment).
    private let runtimeInstaller: RuntimeInstaller?

    private static var bundledRuntimeInstaller: RuntimeInstaller? {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        guard let url = (debugOverride(env["HARBOR_RUNTIME_MANIFEST_URL"]) ?? info["HarborRuntimeManifestURL"] as? String)
                .flatMap(URL.init(string:)),
              let keyText = debugOverride(env["HARBOR_RUNTIME_PUBLIC_KEY"]) ?? info["HarborRuntimePublicKey"] as? String,
              let key = try? RuntimeSigning.publicKey(keyText) else { return nil }
        return RuntimeInstaller(manifestURL: url, publicKey: key)
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
            try await installer.installPending(manifest, appBuild: appBuild) { fraction in
                Task { @MainActor in
                    // A late report must not undo "failed" (and hide Try Again) or "done".
                    if case .running = self.runtimeDownload { self.runtimeDownload = .running(fraction) }
                }
            }
            installer.removeOldVersions()
            launcher = Self.makeLauncher()
            runtimeDownload = nil
            prepareTemplate()
            updateBottlesInBackground()
        } catch {
            runtimeDownload = .failed(ErrorMessage.text(for: error))
        }
    }
    // MARK: Updating installed Windows support

    /// The oldest runtime list this build works with (Info.plist, written by scripts/bundle-app.sh), if it has one.
    private let minimumRuntimeSequence: Int?

    private static var bundledMinimumRuntimeSequence: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "HarborMinimumRuntimeSequence") as? NSNumber)?.intValue
    }

    /// This Harbor's build number, which a runtime list can ask a minimum of.
    private var appBuild: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// Whether the installed Windows support is older than this Harbor needs.
    var runtimeIsTooOld: Bool {
        guard launcher != nil, let installer = runtimeInstaller else { return false }
        return !installer.meetsMinimum(minimumRuntimeSequence)
    }

    private var runtimeUpdateTask: Task<Void, Never>?
    private var lastRuntimeCheck = Date.distantPast
    /// Where an update to Windows support stands (Settings shows it; a waiting one also shows in the main window).
    private(set) var runtimeUpdate = RuntimeUpdateState.idle
    /// When the published list was last read successfully.
    private(set) var runtimeLastChecked: Date?

    /// The installed Windows support, for Settings. `wine` is nil for a runtime that wasn't downloaded by Harbor
    /// (a development build's own).
    struct RuntimeVersions: Equatable {
        var wine: String?
        var installed: Date?
        var d3dmetal: String?
        var dxmt: String?
    }

    /// Read from disk when the runtime changes, not per view update (Settings redraws on every download tick).
    private(set) var runtimeVersions: RuntimeVersions?

    private static func versions(of launcher: WineLauncher?) -> RuntimeVersions? {
        guard let launcher else { return nil }
        let downloaded = launcher.runtime.root.standardizedFileURL.path
            .hasPrefix(WineRuntime.installedDirectory.standardizedFileURL.path + "/")
        return RuntimeVersions(
            wine: downloaded ? RuntimeInstaller.installedVersion(of: "wine").map(RuntimeInstaller.displayVersion) : nil,
            installed: downloaded ? RuntimeInstaller.installedDate() : nil,
            d3dmetal: (downloaded ? RuntimeInstaller.installedVersion(of: "d3dmetal").map(RuntimeInstaller.displayVersion) : nil)
                ?? launcher.d3dmetal?.version,
            dxmt: launcher.dxmt?.version)
    }

    /// Someone asked for the check that is running (in Settings), so its failure is told, not kept quiet.
    private var runtimeCheckWasAsked = false

    /// Looks for newer Windows support (at most every six hours, or at once when the user asks in Settings),
    /// downloads it in the background next to the installed one, and switches to it once nothing is running.
    /// Quiet: one status line, no dialogs.
    func checkForRuntimeUpdate(userAsked: Bool = false) {
        guard launcher != nil, let installer = runtimeInstaller else { return }
        // A check already under way becomes the one that was asked for.
        if userAsked { runtimeCheckWasAsked = true }
        guard runtimeUpdateTask == nil else { return }
        // An app that needs newer Windows support than is installed doesn't wait for the usual interval.
        guard userAsked || installer.hasStagedUpdate || runtimeIsTooOld
                || Date().timeIntervalSince(lastRuntimeCheck) > 6 * 3600 else { return }
        lastRuntimeCheck = Date()
        let build = appBuild
        let previous = runtimeUpdate
        // At once, not after the clean-up below: Settings' button is off from the first moment.
        if !installer.hasStagedUpdate { runtimeUpdate = .checking }
        runtimeUpdateTask = Task {
            defer { runtimeUpdateTask = nil; runtimeCheckWasAsked = false; tellHowTheUpdateForAStartEnded() }
            // Runtimes moved aside by an earlier switch (e.g. one that was interrupted) go once nothing can use them.
            let store = store
            await Task.detached { if !store.list().contains(where: { $0.isRunning() }) { installer.removeOldVersions() } }.value
            if !installer.hasStagedUpdate {
                runtimeUpdate = .checking
                let manifest: RuntimeManifest
                do { manifest = try await installer.fetchManifest() } catch {
                    runtimeUpdate = .afterFailedCheck(error, previous: previous, userAsked: runtimeCheckWasAsked)
                    return
                }
                runtimeLastChecked = Date()
                switch installer.decision(for: manifest, appBuild: build) {
                case .upToDate:
                    // The same components under a newer list: only the record changes (it is what
                    // `runtimeIsTooOld` goes by).
                    do { try installer.recordSequenceOfInstalled(manifest) } catch {
                        runtimeUpdate = .afterFailedCheck(error, previous: previous, userAsked: runtimeCheckWasAsked)
                        return
                    }
                    runtimeUpdate = .idle
                    return
                case .refusedOlder:
                    runtimeUpdate = .idle
                    return
                case .failedBefore:
                    runtimeUpdate = .failedBefore
                    return
                case .needsNewerApp:
                    runtimeUpdate = .needsNewerApp
                    status = "Newer Windows support is available for a newer Harbor. Choose Harbor > Check for Updates…"
                    return
                case .available:
                    runtimeUpdate = .downloading(0)
                    status = "Downloading an update to Windows support…"
                    do {
                        try await installer.stage(manifest, appBuild: build) { fraction in
                            Task { @MainActor in
                                // A late report must not undo "ready".
                                if case .downloading = self.runtimeUpdate { self.runtimeUpdate = .downloading(fraction) }
                            }
                        }
                    } catch {
                        let message = RuntimeInstallError.message(for: error)
                        runtimeUpdate = .failed(message)
                        status = "Windows support couldn’t be updated: \(message)"
                        return
                    }
                    // The main window says so with a link to Settings instead of a sentence.
                    status = nil
                }
            }
            // "Ready" only for an update that is really there (it may have been switched to from the command
            // line meanwhile, or the list turned out to need nothing).
            runtimeUpdate = installer.hasStagedUpdate ? .ready : .idle
            await activateRuntimeUpdateIfIdle(installer)
        }
    }

    /// A program someone tried to start while Windows support was too old for this Harbor (`open`).
    private var startWaitingForRuntime: String?

    /// When the check that `open` started for such a program is over: says where things really stand, so that
    /// "Updating Windows support first" doesn't stay when the check failed or the update can't be installed yet.
    private func tellHowTheUpdateForAStartEnded() {
        guard let name = startWaitingForRuntime else { return }
        startWaitingForRuntime = nil
        guard runtimeIsTooOld else {
            status = "Windows support is up to date. Start \(name) again."
            return
        }
        let blocking = library.first { running.contains($0.id) }?.program.name
        status = runtimeUpdate.statusWhileTooOld(starting: name, running: blocking)
    }

    /// Windows support is being switched to a downloaded update: the Wine folder is being replaced, and the new
    /// one isn't proven yet (if it doesn't start, it is removed again and the previous one put back).
    private var runtimeIsSwitching = false

    /// Whether a program, an add or a component install has to wait for that switch; says so if it does. Starting
    /// meanwhile could find no Wine at all, or one that is taken away under it.
    private func waitsForRuntimeSwitch() -> Bool {
        guard runtimeIsSwitching else { return false }
        status = "Windows support is being updated; try again in a moment."
        return true
    }

    /// Switches to a downloaded runtime, but only while nothing uses the current one. The new Wine must start, or
    /// the previous one is put back.
    private func activateRuntimeUpdateIfIdle(_ installer: RuntimeInstaller) async {
        guard installer.hasStagedUpdate, addState == nil, running.isEmpty else { return }
        // Before the first suspension: from here on nothing of Harbor's starts (`waitsForRuntimeSwitch`), so what
        // the check below finds running is all there is.
        runtimeIsSwitching = true
        defer { runtimeIsSwitching = false }
        let (store, templates) = (store, templates)
        do {
            let switched = try await Task.detached {
                // The template build runs Wine too, in a prefix that is in no store.
                try installer.activateStagedIfIdle({ !store.list().contains { $0.isRunning() } && !PrefixTemplate.isBeingBuilt(in: templates) }) { installed in
                    WineRuntime(root: installed.appending(path: "wine")).starts()
                }
            }.value
            guard switched else { return }
            launcher = Self.makeLauncher()
            prepareTemplate()
            updateBottlesInBackground()
            runtimeUpdate = .idle
            status = "Windows support was updated."
        } catch {
            let message = RuntimeInstallError.message(for: error)
            runtimeUpdate = .failed(message)
            status = "Windows support couldn’t be updated: \(message)"
            // Kept although it didn't start (there was nothing to go back to): it is what is installed now, and
            // the sentence says so by itself.
            if case RuntimeInstallError.unprovenUpdateKept = error { launcher = Self.makeLauncher(); status = message }
        }
    }

    var bottles: [Bottle] = []
    /// Bottle folders the library can't show (all of, or some of) the programs of: their settings or their list
    /// of programs can't be read. Said in the status line for as long as it is so, never dropped silently.
    var damaged: [URL] = []
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

    /// The bottle the sheet's work runs in, once there is one, and what ends the task doing that work: what the
    /// sheet's Stop and Cancel act on.
    private var addBottle: Bottle?
    private var endAddTask: () -> Void = {}

    private func showSheet(_ state: AddState, bottle: Bottle? = nil) {
        addState = state
        addBottle = bottle
        endAddTask = {}
    }

    /// The sheet's Stop: ends what runs in the bottle. An add then goes on to look for what was installed.
    func stopAdd() {
        // A component's installers run one after the other: the next one must not start.
        if case .component = addState?.phase { endAddTask() }
        endAddBottle()
    }

    /// The sheet's Cancel: ends the work and keeps nothing of it. Can be asked again: an installer that was
    /// only just being started when the first click came is ended by the next.
    func cancelAdd() {
        endAddTask()
        // Nothing runs yet while the file is being read, so the sheet goes at once; the add ends itself when
        // the read returns.
        if case .working(.analyzing) = addState?.phase { addState = nil }
        endAddBottle()
    }

    private func endAddBottle() {
        guard let launcher, let bottle = addBottle else { return }
        // Waits for wineserver to end the bottle's programs: off the main actor.
        Task.detached { try? launcher.shutdown(bottle) }
    }

    convenience init() {
        self.init(store: .default, launcher: Self.makeLauncher(), runtimeInstaller: Self.bundledRuntimeInstaller,
                  minimumRuntimeSequence: Self.bundledMinimumRuntimeSequence)
    }

    /// What `init()` takes from this Mac and from the app's bundle, given instead: tests bring a library, a Wine
    /// and folders of their own. `background: false` starts nothing by itself: no pre-made Windows environment,
    /// no check for newer Windows support, none of the development modes below.
    init(store: BottleStore, launcher: WineLauncher?, runtimeInstaller: RuntimeInstaller? = nil,
         minimumRuntimeSequence: Int? = nil, shortcuts: URL = AppShortcuts.defaultDirectory, salt: LaunchSalt = LaunchSalt(),
         templates: URL = PrefixTemplate.defaultDirectory, background: Bool = true) {
        self.store = store
        self.launcher = launcher
        self.runtimeInstaller = runtimeInstaller
        self.minimumRuntimeSequence = minimumRuntimeSequence
        self.shortcuts = AppShortcuts(directory: shortcuts)
        self.salt = salt
        self.templates = templates
        // The first scan happens before the window exists, so the library never flashes its empty state.
        show(Self.scan(store, salt: salt))
        runtimeVersions = Self.versions(of: launcher)
        if background { prepareTemplate() }
        // An install that never reached the library is looked for off the main actor; it shows a moment later.
        reload()
        guard background else { return }
        // Distribution checks: `open --env HARBOR_SMOKE_TEST=/path/result.txt Harbor.app` makes the real, signed
        // app (launched through LaunchServices, as Gatekeeper sees it) set up a bottle, run a Windows command,
        // write the outcome and quit.
        if let output = ProcessInfo.processInfo.environment["HARBOR_SMOKE_TEST"] {
            Task { await runSmokeTest(writingTo: URL(filePath: output)) }
        } else if let preview = debugOverride(ProcessInfo.processInfo.environment["HARBOR_PREVIEW_RUNTIME_UPDATE"]) {
            // Development builds only: shows the given update state (checking|downloading|ready|newer-app|
            // failed-before|failed) without checking for one, so every state of Settings and the main window can
            // be looked at.
            lastRuntimeCheck = Date()
            switch preview {
            case "checking": runtimeUpdate = .checking
            case "downloading": runtimeUpdate = .downloading(0.4)
            case "ready": runtimeUpdate = .ready
            case "newer-app": runtimeUpdate = .needsNewerApp
            case "failed-before": runtimeUpdate = .failedBefore
            case "failed": runtimeUpdate = .failed(RuntimeInstallError.message(for: URLError(.networkConnectionLost)))
            default: runtimeLastChecked = Date()
            }
            // With it, HARBOR_PREVIEW_STATUS=<text> shows a status line.
            status = ProcessInfo.processInfo.environment["HARBOR_PREVIEW_STATUS"]
        } else {
            checkForRuntimeUpdate()
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
        let templates = templates
        Task.detached(priority: .utility) {
            // Old derived runtimes and templates (from earlier Wine builds) go first; in-use ones stay.
            Maintenance.collectGarbage(launcher: launcher)
            // Not while Windows support is being switched: the build would start Wine from a folder that is
            // being replaced. (The build asked for at the end of a switch gets here after the switch is over.)
            try? await PrefixTemplate(launcher: launcher, directory: templates).prepare { await !self.runtimeIsSwitching }
        }
    }

    private var reloading: Task<Void, Never>?

    /// Rescans the bottles off the main actor (store manifests and icons are many files). Reloads run one after
    /// another; the returned task finishes once `library` shows this one's result.
    @discardableResult
    func reload() -> Task<Void, Never> {
        let (store, salt, previous) = (store, salt, reloading)
        let task = Task {
            await previous?.value
            let (found, scan) = await Task.detached {
                // Installs that never reached the library (Harbor quit while the installer ran) come in first.
                (AddProgram.recoverUnrecorded(in: store).adopted, Self.scan(store, salt: salt))
            }.value
            show(scan)
            if let first = found.first {
                status = found.count == 1 ? "Found \(first.settings.name), installed earlier."
                                          : "Found \(found.count) programs installed earlier."
            }
        }
        reloading = task
        return task
    }

    private nonisolated static func scan(_ store: BottleStore, salt: LaunchSalt) -> ([Bottle], [(LibraryEntry, NSImage?)], [URL]) {
        let (bottles, unreadable) = store.scan()
        let damaged = unreadable.map(\.folder) + bottles.filter(\.hasUnreadablePrograms).map(\.root)
        return (bottles, Library.scan(bottles, salt: salt).map { ($0, $0.iconFile.flatMap(NSImage.init(contentsOf:))) },
                damaged.sorted { $0.path < $1.path })
    }

    private func show(_ scan: ([Bottle], [(LibraryEntry, NSImage?)], [URL])) {
        bottles = scan.0
        damaged = scan.2
        library = scan.1.map { entry, icon in
            LibraryItem(program: entry.program, bottle: entry.bottle, icon: icon,
                        managedByStore: entry.managedByStore, iconFile: entry.iconFile, storeTitleKey: entry.storeTitleKey)
        }
        syncShortcuts()
    }

    /// Mac app shortcuts in ~/Applications/Harbor, one per program (off the main actor: icons go through sips;
    /// one sync at a time, since reloads can follow each other faster than a sync takes).
    private func syncShortcuts() {
        let items = library.map { ($0.program, $0.iconFile ?? $0.bottle.iconFile(for: $0.program)) }
        let icons = Dictionary(items.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        // With a bottle that can't be read, a shortcut without a program in the library isn't a leftover.
        shortcuts.scheduleSync(items.map(\.0), keepingOthers: !damaged.isEmpty) { program in
            icons[program.id].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
    }

    /// `harbor://launch/<program id>`, sent by the Mac app shortcuts.
    func handle(_ url: URL) {
        guard url.scheme == "harbor" else { return }
        let id = url.host() == "launch" ? UUID(uuidString: url.lastPathComponent) : nil
        Task {
            await reloading?.value   // a program added a moment ago is in the library once its reload is done
            guard let item = library.first(where: { $0.id == id }) else {
                // A shortcut that outlived its program (kept in the Dock, copied elsewhere), or a link Harbor
                // doesn't know.
                status = "That shortcut’s program isn’t in Harbor any more."
                return
            }
            // The window shows the download then; say why nothing opened.
            if launcher == nil { status = "Download Windows support to open \(item.program.name)." }
            open(item)
        }
    }

    /// Said when a second program is dropped while one is being added, or several at once.
    static let oneAtATime = "Add one program at a time."

    /// Adds a dropped program or installer: a new bottle, the installer's own window if it has one, then the
    /// programs it installed.
    func add(_ file: URL, allowDuplicate: Bool = false) async {
        guard let launcher else { return }
        guard addState == nil else {
            status = Self.oneAtATime
            return
        }
        if waitsForRuntimeSwitch() { return }
        // Before the first suspension: reading the file can take a while (a network share, a file iCloud has to
        // fetch), and a second add that got past the check above meanwhile would run beside this one. From here
        // on no switch of Windows support begins either (`activateRuntimeUpdateIfIdle`).
        let state = AddState(fileName: file.lastPathComponent, phase: .working(.analyzing))
        let id = state.id
        showSheet(state)
        // Reading the file happens off the main actor, so a slow or hostile file can't freeze the window.
        let suggested = await Task.detached { AddProgram.suggestedName(for: file) }.value
        // Cancelled meanwhile: the sheet is gone, and another add's may be up by now.
        guard addState?.id == id else { return }
        if !allowDuplicate, let name = suggested,
           let existing = library.first(where: { $0.bottle.settings.name.caseInsensitiveCompare(name) == .orderedSame }) {
            addState = nil
            pendingDuplicate = (file, existing, name)
            return
        }
        let flow = AddProgram(store: store, launcher: launcher, template: PrefixTemplate(launcher: launcher, directory: templates))
        // In a task of its own, so that Cancel can end it.
        let task = Task {
            try await flow.add(file, progress: { step in
                Task { @MainActor in
                    // Not a late report that would undo "failed", nor one of an add whose sheet is gone.
                    guard self.addState?.id == id, case .working = self.addState?.phase else { return }
                    self.addState?.phase = .working(step)
                    // The installer window should come to the front, not hide behind Harbor.
                    if case .runningInstaller = step { self.bringWineToFront(since: Date()) }
                }
            }, created: { bottle in
                Task { @MainActor in if self.addState?.id == id { self.addBottle = bottle } }
            })
        }
        endAddTask = { task.cancel() }
        let result = await task.result
        guard addState?.id == id else {
            reload()
            return
        }
        switch result {
        case .success((_, let programs)):
            await reload().value
            addState = nil
            status = programs.count == 1 ? "Added \(programs[0].name)" : "Added \(programs.count) programs"
        case .failure(let error):
            reload()
            // Cancelled: nothing of it was kept, and how the installer ended is no news.
            if task.isCancelled { addState = nil } else { addState?.phase = .failed(ErrorMessage.text(for: error)) }
        }
    }

    /// Whether the program's bottle shows the Mac's files as drive Z:. Takes effect when the bottle next starts.
    func setMacFilesAccess(_ item: LibraryItem, _ allowed: Bool) {
        var bottle = item.bottle
        bottle.settings.macFilesAccess = allowed
        do { try bottle.save() } catch { status = "Couldn’t save the setting: \(error.localizedDescription)" }
        if running.contains(item.id) || bottle.isRunning() {
            status = "\(item.program.name) \(allowed ? "can open" : "can no longer open") your Mac’s files the next time it starts."
        }
        reload()
    }

    /// Installs a Windows component (Visual C++ runtime) into the program's bottle, showing progress.
    func install(_ recipe: Recipe, for item: LibraryItem) async {
        guard let launcher else { return }
        // Offered by the alert about a program that couldn't run, which can come up over a sheet.
        guard addState == nil else {
            status = "\(recipe.name) wasn’t installed because Harbor is busy. Try again when it’s done."
            return
        }
        if waitsForRuntimeSwitch() { return }
        showSheet(AddState(fileName: recipe.name, phase: .component(item.program.name)), bottle: item.bottle)
        let task = Task { try await launcher.install(recipe, in: item.bottle) }
        endAddTask = { task.cancel() }
        do {
            try await task.value
            addState = nil
            status = "Installed \(recipe.name) for \(item.program.name)."
        } catch {
            // Stopped by the user: how the installer ended is no news then. What the stop left the program's
            // Windows environment without (`RecipeError`) is.
            if task.isCancelled, !(error is RecipeError) {
                addState = nil
                status = "Stopped installing \(recipe.name)."
            } else {
                addState?.phase = .failed(ErrorMessage.text(for: error))
            }
        }
    }

    /// One click: downloads the store's installer, installs it into its own bottle, adds it and starts it. If the
    /// store is already set up, just opens it.
    func addStore(_ which: GameStores.Store) async {
        guard let launcher else { return }
        guard addState == nil else {
            status = Self.oneAtATime
            return
        }
        if waitsForRuntimeSwitch() { return }
        let stores = GameStores(store: store, launcher: launcher)
        if let bottle = stores.existingBottle(for: which),
           let item = library.first(where: { $0.bottle == bottle && !$0.managedByStore }) {
            open(item)
            return
        }
        showSheet(AddState(fileName: which.name, phase: .store(which, .downloading)))
        let task = Task {
            try await stores.install(which, progress: { step in
                Task { @MainActor in self.addState?.phase = .store(which, step) }
            }, created: { bottle in
                Task { @MainActor in self.addBottle = bottle }
            })
        }
        endAddTask = { task.cancel() }
        do {
            let (bottle, program) = try await task.value
            await reload().value
            addState = nil
            if let item = library.first(where: { $0.bottle == bottle && $0.program.id == program.id }) { open(item) }
        } catch {
            reload()
            // Cancelled: the store's Windows environment is gone again, and how its installer ended is no news.
            if task.isCancelled { addState = nil } else { addState?.phase = .failed(ErrorMessage.text(for: error)) }
        }
    }

    func open(_ item: LibraryItem) {
        guard let launcher else { return }
        if waitsForRuntimeSwitch() { return }
        if runtimeIsTooOld {
            status = RuntimeUpdateState.checking.statusWhileTooOld(starting: item.program.name, running: nil)
            // Asked for: a check that fails says why, and its end replaces the line above (see
            // `tellHowTheUpdateForAStartEnded`).
            startWaitingForRuntime = item.program.name
            checkForRuntimeUpdate(userAsked: true)
            return
        }
        // After a runtime update, Wine first refreshes the bottle's Windows files (20–30 s). Say so instead of
        // leaving people looking at nothing. Not while the bottle is still running from before the update (the
        // program is usually already open there, and the update would wait for it to quit).
        if item.bottle.needsWindowsUpdate(for: launcher.runtime), !item.bottle.isRunning(), addState == nil {
            showSheet(AddState(fileName: item.program.name, phase: .updating), bottle: item.bottle)
            let task = Task {
                var problem: String?
                do { try await launcher.updateWindows(item.bottle) } catch { problem = ErrorMessage.text(for: error) }
                addState = nil
                // Cancelled: the program isn't wanted any more. (Windows is updated when it is next started.)
                if Task.isCancelled { return }
                // The program is started all the same: Windows tries the update again by itself then, and the
                // program may well run. But what went wrong here is said.
                if let problem { status = "Opening \(item.program.name) although Windows couldn’t be updated for it: \(problem)" }
                launchNow(item, with: launcher)
            }
            endAddTask = { task.cancel() }
            return
        }
        launchNow(item, with: launcher)
    }

    /// How many launches of each program are still going: a program can be opened twice, and is running until
    /// the last of them has ended.
    private var launches: [LibraryItem.ID: Int] = [:]
    /// Bottles Harbor stopped itself (their program was removed, or quit from its tile); how their programs end
    /// is no failure.
    private var stoppedBottles: Set<Bottle.ID> = []

    private func launchEnded(_ id: LibraryItem.ID) {
        launches[id] = (launches[id] ?? 1) - 1
        if launches[id] == 0 {
            launches[id] = nil
            running.remove(id)
        }
    }

    private func launchNow(_ item: LibraryItem, with launcher: WineLauncher) {
        let started = Date()
        running.insert(item.id)
        launches[item.id, default: 0] += 1
        stoppedBottles.remove(item.bottle.id)
        let id = item.id
        // The first launch of a game clones the D3DMetal runtime; keep that off the main actor.
        Task.detached {
            do {
                try launcher.launch(item.program, in: item.bottle) { exit in
                    Task { @MainActor in
                        self.launchEnded(id)
                        if exit.status != 0 { self.explainFailure(of: item, exit: exit) }
                        self.checkForRuntimeUpdate()
                    }
                }
                await MainActor.run { self.bringWineToFront(since: started) }
            } catch {
                await MainActor.run {
                    self.launchEnded(id)
                    self.status = "Couldn’t open \(item.program.name): \(ErrorMessage.text(for: error))"
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
        let exit: WineExit
    }
    var failure: Failure?

    /// A problem report that is being read before it goes to GitHub (`ReportSheet`).
    struct ReportDraft: Identifiable {
        let id = UUID()
        let kind: ProblemReport.Kind
        var title: String
        var text: String
    }
    var reportDraft: ReportDraft?

    /// Writes a report and shows it: about the program that failed, with the end of that launch's log, or
    /// (from the Help menu) with the versions only. The program's name stays out; the user can add it.
    func reportProblem(_ failure: Failure? = nil) {
        let support = runtimeVersions.map { versions in
            let layers = [versions.d3dmetal.map { "D3DMetal \($0)" }, versions.dxmt.map { "DXMT \($0)" }].compactMap { $0 }
            return (versions.wine ?? "this checkout’s own build") + (layers.isEmpty ? "" : " (\(layers.joined(separator: ", ")))")
        }
        let report = ProblemReport(kind: failure == nil ? .harbor : .program,
                                   versions: .onThisMac(harbor: Bundle.main.harborVersion, windowsSupport: support),
                                   diagnosis: failure?.diagnosis, exit: failure?.exit)
        let log = failure?.log
        Task {
            // Reading the log and the Mac's names stays off the main actor.
            let text = await Task.detached(operation: {
                var report = report
                report.log = log.map { ProblemReport.endOfLog($0) }
                return report.text(identity: .current)
            }).value
            reportDraft = ReportDraft(kind: report.kind, title: report.title, text: text)
        }
    }

    /// Reads the run's own log; a recognised cause gets an alert with what to do, a program that ended right
    /// after starting its exit code, and anything else nothing (`WineExit.report`).
    func explainFailure(of item: LibraryItem, exit: WineExit) {
        // Reading the log (lossily: logs aren't always UTF-8) stays off the main actor.
        // A title started through its store: the exit status is the launcher's handover, not the game's, and the
        // log is the whole store session's. Nothing reliable can be said, so nothing is.
        if item.managedByStore && item.program.arguments != nil { return }
        let (bottle, name, path) = (item.bottle, item.program.name, item.program.windowsPath)
        let stopped = stoppedBottles.contains(bottle.id)
        Task {
            let diagnosis = await Task.detached(operation: { exit.log.flatMap { bottle.diagnosis(ofLog: $0, program: path) } }).value
            switch exit.report(diagnosis: diagnosis, stoppedByHarbor: stopped) {
            case .nothing:
                break
            case .cause(let diagnosis):
                if let log = exit.log { failure = Failure(item: item, diagnosis: diagnosis, log: log, exit: exit) }
            case .unexplained:
                status = exit.signalled ? "\(name) was stopped unexpectedly" : "\(name) quit unexpectedly (\(exit.status))"
            }
        }
    }

    /// Ends the program, and with it everything else that runs in its bottle (programs installed together share
    /// one Windows session). Also ends what is left of it in the background, without a window to close.
    func quit(_ item: LibraryItem) {
        guard let launcher else { return }
        stoppedBottles.insert(item.bottle.id)
        let (bottle, name) = (item.bottle, item.program.name)
        Task {
            // Waits for wineserver to end the bottle's programs: off the main actor.
            let problem = await Task.detached { () -> String? in
                do { try launcher.shutdown(bottle) } catch { return ErrorMessage.text(for: error) }
                return nil
            }.value
            if let problem { status = "Couldn’t quit \(name): \(problem)" }
        }
    }

    func showInFinder(_ item: LibraryItem) {
        if let exe = item.bottle.unixPath(forWindowsPath: item.program.windowsPath) {
            NSWorkspace.shared.activateFileViewerSelecting([exe])
        }
    }

    func setGame(_ item: LibraryItem, _ isGame: Bool) { update(item) { $0.isGame = isGame } }

    /// The user's choice whether a store's title is a game (kept in the bottle; the library is rescanned).
    func setStoreTitle(_ item: LibraryItem, isGame: Bool) {
        guard let key = item.storeTitleKey else { return }
        do { try item.bottle.setStoreTitle(key, isGame: isGame) } catch { status = "Couldn’t save the setting: \(error.localizedDescription)" }
        reload()
    }

    func setGraphics(_ item: LibraryItem, _ graphics: GraphicsBackend) {
        update(item) { $0.graphics = graphics == .automatic ? nil : graphics }
    }

    private func update(_ item: LibraryItem, _ change: (inout Program) -> Void) {
        do {
            try item.bottle.changePrograms { programs in
                if let i = programs.firstIndex(where: { $0.id == item.id }) { change(&programs[i]) }
            }
        } catch {
            status = "Couldn’t save the setting: \(ErrorMessage.text(for: error))"
        }
        reload()
    }

    func confirmRemoval(_ item: LibraryItem) { pendingRemoval = item }

    /// Whether the program runs, or anything else in its bottle (also what Harbor didn't start itself this time:
    /// left from before Harbor was reopened).
    func isRunning(_ item: LibraryItem) -> Bool { running.contains(item.id) || item.bottle.isRunning() }

    /// What the dialog asks before `item` goes to the Trash with its bottle: it names the store games that go
    /// with Steam or Epic, and says when something is running that the removal ends.
    func removalQuestion(_ item: LibraryItem) -> (title: String, message: String) {
        Library.removalQuestion(name: item.program.name,
                                games: library.count { $0.bottle == item.bottle && $0.managedByStore },
                                running: isRunning(item))
    }

    /// Whether removing `item` also deletes its bottle (it's the last program in it).
    /// A bottle whose record is partly unreadable may hold programs that aren't shown: it is never taken for a
    /// bottle with one program (removing that one would move the others to the Trash with it).
    func removesBottle(_ item: LibraryItem) -> Bool {
        item.bottle.programs().count <= 1 && !item.bottle.hasUnreadablePrograms
    }

    func remove(_ item: LibraryItem) {
        if removesBottle(item) {
            shortcuts.remove(item.id)
            stoppedBottles.insert(item.bottle.id)
            // Stopping the bottle waits for wineserver to end its programs: off the main actor, with the
            // bottle's programs out of the library meanwhile (the reload brings them back if it stays).
            library.removeAll { $0.bottle == item.bottle }
            let (launcher, store) = (launcher, store)
            Task {
                let problem = await Task.detached { () -> String? in
                    try? launcher?.shutdown(item.bottle)
                    // To the Trash, not deleted: a removal must be undoable (Finder's Put Back).
                    do { try store.moveToTrash(item.bottle) } catch { return error.localizedDescription }
                    return nil
                }.value
                if let problem { status = "Couldn’t move \(item.program.name) to the Trash: \(problem)" }
                reload()
            }
            pendingRemoval = nil
            return
        } else {
            do {
                try item.bottle.changePrograms { $0.removeAll { $0.id == item.id } }
                shortcuts.remove(item.id)
            } catch {
                status = "Couldn’t remove \(item.program.name): \(ErrorMessage.text(for: error))"
            }
        }
        pendingRemoval = nil
        reload()
    }

    /// Rosetta's installer is running (its administrator prompt may be up); the button is off meanwhile, or a
    /// second click would bring a second prompt.
    private(set) var rosettaInstalling = false

    func installRosetta() {
        guard !rosettaInstalling else { return }
        rosettaInstalling = true
        status = "Installing Rosetta…"
        Task.detached {
            // The system's administrator prompt; softwareupdate needs root to install Rosetta.
            let failure = Rosetta.install()
            await MainActor.run {
                self.rosettaInstalling = false
                self.rosettaAvailable = Rosetta.isAvailable
                self.status = self.rosettaAvailable ? nil : "Rosetta wasn’t installed\(failure.map { ": \($0)" } ?? ".")"
            }
        }
    }

}

/// What Harbor last did or is doing, and a downloaded update that waits for Windows programs to quit (a link to
/// Settings for as long as it waits). Nothing at all when there's nothing to say.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var alignment: HorizontalAlignment = .leading
    @State private var showingAll = false

    var body: some View {
        if model.status != nil || model.runtimeUpdate == .ready || !model.damaged.isEmpty {
            VStack(alignment: alignment, spacing: 4) {
                if let status = model.status {
                    // Statuses name programs and quote errors, and the sidebar is narrow: a long one is cut after
                    // a few lines instead of squeezing the list. A click shows all of it (so does hovering).
                    Button { showingAll = true } label: {
                        Text(status).foregroundStyle(.secondary)
                            .multilineTextAlignment(alignment == .center ? .center : .leading)
                            .lineLimit(4)
                    }
                    .buttonStyle(.plain)
                    .help(status)
                    .popover(isPresented: $showingAll, arrowEdge: .trailing) {
                        Text(status).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading).padding()
                    }
                }
                if !model.damaged.isEmpty {
                    // Not through `status`, which the next message replaces: this is said for as long as it is so.
                    Text(model.damaged.count == 1 ? "1 program’s data couldn’t be read."
                                                  : "\(model.damaged.count) programs’ data couldn’t be read.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.damaged) }
                        .buttonStyle(.link)
                }
                if model.runtimeUpdate == .ready {
                    // Short enough for one line in the narrowest sidebar.
                    Button("Update ready") { openSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
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
                        .disabled(model.rosettaInstalling)
                }
            } else if model.launcher == nil {
                RuntimeDownloadView()
            } else {
                LibraryView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The library shows the status in its sidebar: centred under the whole window it sat off-centre
            // under the grid. The screens without a sidebar keep it here.
            if !model.rosettaAvailable || model.launcher == nil {
                StatusLine(alignment: .center).padding(8)
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
            Button("Report a Problem…") { model.reportProblem(failure) }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.diagnosis.message(for: failure.item.program.name))
        }
        .sheet(item: Binding(get: { model.reportDraft }, set: { model.reportDraft = $0 })) { ReportSheet(draft: $0) }
        // Stores install games on their own: look again whenever Harbor comes to the front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
            model.checkForRuntimeUpdate()
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { model.pendingRemoval != nil },
                                                               set: { if !$0 { model.pendingRemoval = nil } }),
                            presenting: model.pendingRemoval) { item in
            Button(model.removesBottle(item) ? "Move to Trash" : "Remove", role: .destructive) {
                model.remove(item)
            }
        } message: { item in
            if model.removesBottle(item) {
                Text(model.removalQuestion(item).message)
            } else {
                Text("Other programs installed alongside it stay in your library.")
            }
        }
    }

    private var removalTitle: String {
        guard let item = model.pendingRemoval else { return "" }
        return model.removesBottle(item) ? model.removalQuestion(item).title : "Remove \(item.program.name)?"
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
