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
    let launcher = WineRuntime.locate().map { WineLauncher(runtime: $0, d3dmetal: D3DMetalRedist.locate()) }
    var bottles: [Bottle] = []
    var selection: Bottle.ID?
    var status: String?
    var rosettaAvailable = Rosetta.isAvailable

    init() { reload() }

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
                ContentUnavailableView("Wine Isn’t Installed", systemImage: "exclamationmark.triangle",
                                       description: Text("Run scripts/fetch-runtime.sh, then relaunch Harbor."))
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
