import AppKit
import HarborKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct HarborApp: App {
    @State private var model = AppModel()

    init() {
        // Running from `swift run` has no bundle; make it a regular foreground app anyway.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Harbor") {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
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
              let keyText = env["HARBOR_RUNTIME_PUBLIC_KEY"] ?? info["HarborRuntimePublicKey"] as? String,
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
            try await installer.installPending(manifest) { fraction in
                Task { @MainActor in self.runtimeDownload = .running(fraction) }
            }
            installer.removeOldVersions()
            launcher = Self.makeLauncher()
            runtimeDownload = nil
        } catch {
            runtimeDownload = .failed(String(describing: error))
        }
    }
    var bottles: [Bottle] = []
    var selection: Bottle.ID?
    var status: String?
    var rosettaAvailable = Rosetta.isAvailable

    init() {
        reload()
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

    func reload() {
        bottles = store.list()
        if selection == nil { selection = bottles.first?.id }
    }

    func createBottle(named name: String) async {
        guard let launcher else { return }
        do {
            status = "Setting up \(name)…"
            let bottle = try await store.create(name: name, setUp: launcher.initialize)
            reload()
            selection = bottle.id
            status = nil
        } catch {
            reload()
            status = "Couldn’t set up \(name): \(error)"
        }
    }

    func installRosetta() {
        status = "Installing Rosetta…"
        Task.detached {
            // The system's administrator prompt; softwareupdate needs root to install Rosetta.
            let script = NSAppleScript(source: "do shell script \"\(Rosetta.installCommand)\" with administrator privileges")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            let failure = (error?[NSAppleScript.errorMessage] as? String)
            await MainActor.run {
                self.rosettaAvailable = Rosetta.isAvailable
                self.status = self.rosettaAvailable ? nil : "Rosetta wasn’t installed\(failure.map { ": \($0)" } ?? ".")"
            }
        }
    }

    func open(_ file: URL) {
        guard let launcher, let bottle = bottles.first(where: { $0.id == selection }) else { return }
        let name = file.lastPathComponent
        status = "Opening \(name)…"
        // The first launch with a graphics layer clones a runtime; keep that off the main actor.
        Task.detached {
            do {
                try launcher.open(file, in: bottle) { exitStatus in
                    Task { @MainActor in self.status = exitStatus == 0 ? nil : "\(name) quit unexpectedly (\(exitStatus))" }
                }
                await MainActor.run { self.status = "Running \(name)" }
            } catch {
                await MainActor.run { self.status = "Couldn’t open \(name): \(error)" }
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.bottles, selection: $model.selection) { bottle in
                Label(bottle.settings.name, systemImage: "shippingbox")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                Button("New Bottle", systemImage: "plus") { naming = true }
                    .disabled(model.launcher == nil)
            }
        } detail: {
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
            } else if model.bottles.isEmpty {
                ContentUnavailableView {
                    Label("No Bottles Yet", systemImage: "shippingbox")
                } description: {
                    Text("A bottle is a separate Windows environment for your programs.")
                } actions: {
                    Button("New Bottle") { naming = true }
                }
            } else {
                DropZone(onDrop: model.open)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary).padding(8)
            }
        }
        .alert("New Bottle", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                Task { await model.createBottle(named: name) }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

struct DropZone: View {
    let onDrop: (URL) -> Void
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Drop a Windows program or installer here").font(.title3)
            Button("Choose File…") { choosing = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
            .padding(24))
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(onDrop)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.exe, .item]) { result in
            if case .success(let url) = result { onDrop(url) }
        }
    }
}

/// Empty state while Windows support (the Wine runtime) isn't installed: offers the one-time download.
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
