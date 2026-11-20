import AppKit
import HarborKit
import SwiftUI
import UniformTypeIdentifiers

/// One program in the library, with the bottle it lives in.
struct LibraryItem: Identifiable, Equatable {
    var program: Program
    var bottle: Bottle
    var icon: NSImage?
    /// Installed and managed by a game store (read from Steam's or Epic's records, not Harbor's library).
    var managedByStore = false
    /// Image file the Mac shortcut's icon is made from.
    var iconFile: URL?
    /// For store titles: the key of the user's game/software choice.
    var storeTitleKey: String?
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
                    Button("Add Steam") { Task { await model.addStore(.steam) } }
                    Button("Add Epic Games Store") { Task { await model.addStore(.epic) } }
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
            EmptyLibraryView(choose: { choosingFile = true }, addSteam: { Task { await model.addStore(.steam) } })
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
                    // Simultaneous, not a second onTapGesture: behind a double-click handler a plain tap is held back
                    // for the system's double-click interval, and selecting felt laggy.
                    .simultaneousGesture(TapGesture().onEnded { selection = [item.id] })
                    .contextMenu { ProgramMenu(item: item) }
                    .accessibilityAction { model.open(item) }
                    // The context menu's main actions, without a right-click (VoiceOver's Actions rotor).
                    .accessibilityActions {
                        Button("Show in Finder") { model.showInFinder(item) }
                        if !item.managedByStore { Button("Remove from Library") { model.confirmRemoval(item) } }
                    }
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
        // One named element per tile (combining the children left it unnamed): VoiceOver reads the program's name
        // and whether it's running; activating it opens the program.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.program.name)
        .accessibilityValue(running ? "Running" : "")
        .accessibilityHint("Opens the program")
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
        if !item.managedByStore { ownMenu } else if item.storeTitleKey != nil {
            // Stores sell software too, and Apple's D3DMetal is for games only. Harbor follows the store's own
            // records; this corrects them.
            Divider()
            Toggle("Treat as Game", isOn: Binding(get: { item.program.isGame }, set: { model.setStoreTitle(item, isGame: $0) }))
        }
    }

    /// Settings for programs Harbor manages itself (Steam games are always games; uninstall them in Steam).
    @ViewBuilder private var ownMenu: some View {
        Divider()
        Toggle("Treat as Game", isOn: Binding(get: { item.program.isGame }, set: { model.setGame(item, $0) }))
        Picker("Graphics", selection: Binding(get: { item.program.graphics ?? .automatic }, set: { model.setGraphics(item, $0) })) {
            Text("Automatic").tag(GraphicsBackend.automatic)
            // Apple licenses D3DMetal for games only.
            Text("D3DMetal (Games)").tag(GraphicsBackend.d3dmetal)
                .selectionDisabled(model.launcher?.offers(.d3dmetal, for: item.program) != true)
            Text("DXMT").tag(GraphicsBackend.dxmt)
                .selectionDisabled(model.launcher?.offers(.dxmt, for: item.program) != true)
            Text("Compatibility").tag(GraphicsBackend.wined3d)
        }
        // Off by default: Windows programs then only see their own drive C:. For programs that open or save files
        // anywhere on the Mac (an archiver, an editor). Applies to everything installed together with this program.
        Toggle("Allow Access to My Mac’s Files", isOn: Binding(get: { item.bottle.settings.macFilesAccess },
                                                                set: { model.setMacFilesAccess(item, $0) }))
        // Microsoft's own runtimes, for programs that need more than Wine's built-in versions.
        Menu("Install Windows Component") {
            ForEach(Recipe.all) { recipe in
                let installed = recipe.isInstalled(in: item.bottle)
                Button(installed ? "\(recipe.name) (Installed)" : recipe.name) { Task { await model.install(recipe, for: item) } }
                    .disabled(installed)
            }
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
            case .store(let which, let step):
                ProgressView().controlSize(.large)
                Text(storeTitle(which, step)).font(.headline)
                Text(storeDetail(which, step)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .component(let program):
                ProgressView().controlSize(.large)
                Text("Installing \(state.fileName)…").font(.headline)
                Text("For \(program). Microsoft’s installer runs in the background; this can take a few minutes.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .updating:
                ProgressView().controlSize(.large)
                Text("Updating Windows for \(state.fileName)…").font(.headline)
                Text("This happens once after Harbor updates its Windows support. It takes about half a minute.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
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

    private func storeTitle(_ which: GameStores.Store, _ step: GameStores.Step) -> String {
        switch step {
        case .downloading: "Downloading \(which.name)…"
        case .preparingWindows: "Preparing Windows for \(which.name)…"
        case .installing: "Installing \(which.name)…"
        }
    }

    private func storeDetail(_ which: GameStores.Store, _ step: GameStores.Step) -> String {
        switch step {
        case .downloading: "Getting the installer from \(which.vendor)."
        case .preparingWindows: "Setting up a separate Windows environment for your games."
        case .installing: which == .steam ? "Steam updates itself on its first start, which can take a few minutes."
                                          : "This takes a minute or two."
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
        case .runningInstaller: "Finish the installer’s window to continue. If it starts the program at the end, quit the program too."
        case .findingPrograms: "Looking for what the installer added."
        }
    }
}
