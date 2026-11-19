import AppKit
import HarborKit
import SwiftUI
import UniformTypeIdentifiers

/// One program in the library, with the bottle it lives in.
struct LibraryItem: Identifiable, Equatable {
    var program: Program
    var bottle: Bottle
    var icon: NSImage?
    /// Installed and managed by Steam (read from Steam's records, not stored in Harbor's library).
    var managedBySteam = false
    /// Image file the Mac shortcut's icon is made from.
    var iconFile: URL?
    var id: UUID { program.id }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.program == b.program && a.bottle == b.bottle }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Programs", games = "Games", apps = "Apps"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .games: "gamecontroller"
        case .apps: "app.badge"
        }
    }
}

/// The main window's content once Windows support is installed.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: Set<LibraryItem.ID> = []
    @State private var choosingFile = false
    @State private var dropTargeted = false

    var body: some View {
        // Sidebar + grid, like Music and Photos: one place to filter, room for more sections later.
        // (Chosen over a single grid with Games/Apps headers, which repeat the filter and cost vertical space.)
        NavigationSplitView {
            List(LibraryFilter.allCases, selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) { f in
                Label(f.rawValue, systemImage: f.symbol).tag(f)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            content
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Programs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Click: choose a program or installer. Menu: one-click game stores.
                Menu("Add Program", systemImage: "plus") {
                    Button("Add Program…") { choosingFile = true }
                    Button("Add Steam") { Task { await model.addSteam() } }
                } primaryAction: {
                    choosingFile = true
                }
                .help("Add a Windows program or installer")
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.exe, UTType(filenameExtension: "msi") ?? .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await model.add(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Local files only: a dropped web link ending in .exe would otherwise be downloaded synchronously.
            guard let url = urls.first, url.isFileURL else { return false }
            Task { await model.add(url) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: Binding(get: { model.addState }, set: { model.addState = $0 })) { state in
            AddProgressSheet(state: state)
        }
    }

    private var visible: [LibraryItem] {
        model.library.filter { item in
            (filter == .all || (filter == .games) == item.program.isGame)
                && (search.isEmpty || item.program.name.localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.library.isEmpty {
            EmptyLibraryView(choose: { choosingFile = true }, addSteam: { Task { await model.addSteam() } })
        } else if visible.isEmpty {
            if search.isEmpty {
                ContentUnavailableView(filter == .games ? "No Games Yet" : "No Apps Yet", systemImage: filter.symbol,
                                       description: Text("Programs you add appear here. Use “Treat as Game” to move one."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            ScrollView { grid(visible).padding(24) }
        }
    }

    private func grid(_ items: [LibraryItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                ProgramTile(item: item, selected: selection.contains(item.id), running: model.running.contains(item.id))
                    .onTapGesture(count: 2) { model.open(item) }
                    .onTapGesture { selection = [item.id] }
                    .contextMenu { ProgramMenu(item: item) }
            }
        }
    }
}

/// Icon and name, like a Finder or Launchpad item.
struct ProgramTile: View {
    let item: LibraryItem
    let selected: Bool
    let running: Bool

    var body: some View {
        VStack(spacing: 8) {
            ProgramIcon(icon: item.icon, size: 72)
                .padding(10)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 14))
            Text(item.program.name)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            // Footprint always reserved so names don't shift when a program starts.
            Text("Running").font(.caption2).foregroundStyle(.secondary).opacity(running ? 1 : 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct ProgramIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary).frame(width: size * 0.8, height: size * 0.8).frame(width: size, height: size)
        }
    }
}

struct ProgramMenu: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItem

    var body: some View {
        Button("Open") { model.open(item) }
        Button("Show in Finder") { model.showInFinder(item) }
        if !item.managedBySteam { ownMenu }
    }

    /// Settings for programs Harbor manages itself (Steam games are always games; uninstall them in Steam).
    @ViewBuilder private var ownMenu: some View {
        Divider()
        Toggle("Treat as Game", isOn: Binding(get: { item.program.isGame }, set: { model.setGame(item, $0) }))
        Picker("Graphics", selection: Binding(get: { item.program.graphics ?? .automatic }, set: { model.setGraphics(item, $0) })) {
            Text("Automatic").tag(GraphicsBackend.automatic)
            Text("D3DMetal (Games)").tag(GraphicsBackend.d3dmetal)
            Text("Compatibility").tag(GraphicsBackend.wined3d)
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { model.confirmRemoval(item) }
    }
}

/// First run: one obvious thing to do.
struct EmptyLibraryView: View {
    let choose: () -> Void
    let addSteam: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Add Your First Windows Program", systemImage: "square.and.arrow.down")
        } description: {
            Text("Drag a program or its installer (.exe or .msi) into this window. Harbor sets everything up.")
        } actions: {
            HStack {
                Button("Choose File…", action: choose).buttonStyle(.borderedProminent)
                Button("Add Steam", action: addSteam)
            }
        }
    }
}

/// Progress while a dropped file is being added.
struct AddProgressSheet: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.AddState

    var body: some View {
        VStack(spacing: 16) {
            switch state.phase {
            case .working(let step):
                ProgressView().controlSize(.large)
                Text(title(step)).font(.headline)
                Text(detail(step)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .store(let step):
                ProgressView().controlSize(.large)
                Text(storeTitle(step)).font(.headline)
                Text(storeDetail(step)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn’t Add \(state.fileName)").font(.headline)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("OK") { model.addState = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private func storeTitle(_ step: GameStores.Step) -> String {
        switch step {
        case .downloading: "Downloading Steam…"
        case .preparingWindows: "Preparing Windows for Steam…"
        case .installing: "Installing Steam…"
        }
    }

    private func storeDetail(_ step: GameStores.Step) -> String {
        switch step {
        case .downloading: "Getting the installer from Valve."
        case .preparingWindows: "Setting up a separate Windows environment for your games."
        case .installing: "Steam updates itself on its first start, which can take a few minutes."
        }
    }

    private func title(_ step: AddProgram.Step) -> String {
        switch step {
        case .analyzing: "Reading \(state.fileName)…"
        case .preparingWindows(let name): "Preparing Windows for \(name)…"
        case .runningInstaller(let name): "Installing \(name)"
        case .findingPrograms: "Finding Programs…"
        }
    }

    private func detail(_ step: AddProgram.Step) -> String {
        switch step {
        case .analyzing: "Checking what kind of program this is."
        case .preparingWindows: "This takes about half a minute the first time."
        case .runningInstaller: "Finish the installer’s window to continue."
        case .findingPrograms: "Looking for what the installer added."
        }
    }
}
