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

extension FocusedValues {
    /// Shows the file chooser of the library window (File > Add Program…).
    @Entry var addProgram: (() -> Void)?
    /// The selected tile while the keyboard is in the grid (File > Open and Remove from Library…).
    @Entry var selectedProgram: LibraryItem?
}

/// The main window's content once Windows support is installed.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: Set<LibraryItem.ID> = []
    @State private var choosingFile = false
    @State private var dropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @FocusState private var gridFocused: Bool
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        // Sidebar + grid, like Music and Photos: one place to filter, room for more sections later.
        // (Chosen over a single grid with Games/Apps headers, which repeat the filter and cost vertical space.)
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                List(LibraryFilter.allCases, selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) { f in
                    // As a key: a `String` would be shown as it is, without being looked up.
                    Label(LocalizedStringKey(f.rawValue), systemImage: f.symbol).tag(f)
                }
                // Under the list rather than centred under the whole window, where it sat off-centre below the grid.
                StatusLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            content
                // With the sidebar hidden its status line would be gone too: it moves under the grid, at the edge
                // where the sidebar was.
                .safeAreaInset(edge: .bottom, alignment: .leading) {
                    if columns == .detailOnly {
                        StatusLine().padding(.horizontal, 24).padding(.bottom, 12)
                    }
                }
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
        .focusedSceneValue(\.addProgram) { choosingFile = true }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.exe, UTType(filenameExtension: "msi") ?? .data, .folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await model.add(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Local files only: a dropped web link ending in .exe would otherwise be downloaded synchronously.
            guard let url = urls.first, url.isFileURL else { return false }
            // Each program gets its own Windows environment and its installer's window: several at once would be
            // a guess at which one was meant.
            guard urls.count == 1 else {
                model.status = AppModel.oneAtATime
                return false
            }
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
            let items = visible
            let selected = items.first { selection.contains($0.id) }
            ScrollViewReader { proxy in
                ScrollView { grid(items).padding(24) }
                    // One stop for Tab, like Finder's icon view: the arrow keys move the selection inside it, and
                    // the selection's colour (not a ring around the whole grid) shows that the keyboard is here.
                    .focusable()
                    .focused($gridFocused)
                    .focusEffectDisabled()
                    .focusedValue(\.selectedProgram, selected)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                        let current = items.firstIndex { selection.contains($0.id) }
                        let next = Self.tileIndex(after: current, pressing: press.key, count: items.count, columns: columnCount)
                        selection = [items[next].id]
                        proxy.scrollTo(items[next].id)
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { _ in
                        guard let selected else { return .ignored }
                        model.open(selected)
                        return .handled
                    }
            }
        }
    }

    private static let tileMinimum: CGFloat = 120
    private static let tileSpacing: CGFloat = 16

    /// How many tiles the grid puts in a row: as many of the narrowest as fit, which is how an adaptive grid
    /// fills its width.
    private var columnCount: Int {
        max(1, Int((gridWidth + Self.tileSpacing) / (Self.tileMinimum + Self.tileSpacing)))
    }

    /// The tile an arrow key leads to from the one at `current`, in a grid of `count` tiles (at least one) in
    /// rows of `columns`: left and right go on into the neighbouring row, up and down stay in their column, and
    /// an arrow that leads nowhere stays where it is. Without a selection every arrow selects the first tile.
    static func tileIndex(after current: Int?, pressing key: KeyEquivalent, count: Int, columns: Int) -> Int {
        guard let current else { return 0 }
        let target = switch key {
        case .leftArrow: current - 1
        case .rightArrow: current + 1
        case .upArrow: current - columns
        default: current + columns
        }
        // Down above a shorter last row has no tile below it: the row's last one is the nearest.
        if key == .downArrow, target >= count, current / columns < (count - 1) / columns { return count - 1 }
        return (0..<count).contains(target) ? target : current
    }

    private func grid(_ items: [LibraryItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: 150), spacing: Self.tileSpacing, alignment: .top)],
                  alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                ProgramTile(item: item, selected: selection.contains(item.id), emphasized: gridFocused,
                            running: model.running.contains(item.id))
                    .onTapGesture(count: 2) { model.open(item) }
                    // Simultaneous, not a second onTapGesture: behind a double-click handler a plain tap is held back
                    // for the system's double-click interval, and selecting felt laggy.
                    .simultaneousGesture(TapGesture().onEnded { selection = [item.id]; gridFocused = true })
                    .contextMenu { ProgramMenu(item: item) }
                    .accessibilityAction { model.open(item) }
                    // The context menu's main actions, without a right-click (VoiceOver's Actions rotor).
                    .accessibilityActions {
                        Button("Show in Finder") { model.showInFinder(item) }
                        if !item.managedByStore { Button("Remove from Library") { model.confirmRemoval(item) } }
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }
}

/// Icon and name, like a Finder or Launchpad item.
struct ProgramTile: View {
    let item: LibraryItem
    let selected: Bool
    /// The keyboard is in the grid: the selection has the accent colour, and is grey while it is elsewhere.
    let emphasized: Bool
    let running: Bool

    var body: some View {
        VStack(spacing: 8) {
            ProgramIcon(icon: item.icon, size: 72)
                .padding(10)
                .background(selected ? (emphasized ? Color.accentColor : .secondary).opacity(0.18) : .clear, in: .rect(cornerRadius: 14))
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
        // Also for what runs without Harbor having started it this time (left from before Harbor was reopened).
        if model.isRunning(item) { Button("Quit") { model.quit(item) } }
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
                Button(installed ? String(localized: "\(recipe.name) (Installed)") : recipe.name) { Task { await model.install(recipe, for: item) } }
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
            Text("Drag a program, its installer (.exe or .msi) or its folder into this window. Harbor sets everything up.")
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
                // Every state that waits for something that may never come has a way out. Finding the programs
                // is Harbor's own, short work.
                switch step {
                case .analyzing, .preparingWindows:
                    cancelButton.help("Don’t add this program")
                case .runningInstaller:
                    HStack {
                        cancelButton.help("End the installer and add nothing")
                        Button("Stop") { model.stopAdd() }.help("End the installer and add what it has installed")
                    }
                case .findingPrograms:
                    EmptyView()
                }
            case .store(let which, let step):
                ProgressView().controlSize(.large)
                Text(storeTitle(which, step)).font(.headline)
                Text(storeDetail(which, step)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                cancelButton.help("Don’t add \(which.name)")
            case .component(let program):
                ProgressView().controlSize(.large)
                Text("Installing \(state.fileName)…").font(.headline)
                Text("For \(program). Microsoft’s installer runs in the background; this can take a few minutes.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Stop") { model.stopAdd() }.help("End the installer. This also quits \(program) if it is running.")
            case .updating:
                ProgressView().controlSize(.large)
                Text("Updating Windows for \(state.fileName)…").font(.headline)
                Text("This happens once after Harbor updates its Windows support. It takes about half a minute.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                cancelButton.help("Don’t open \(state.fileName) now")
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

    private var cancelButton: some View {
        Button("Cancel") { model.cancelAdd() }.keyboardShortcut(.cancelAction)
    }

    private func storeTitle(_ which: GameStores.Store, _ step: GameStores.Step) -> String {
        switch step {
        case .downloading: String(localized: "Downloading \(which.name)…")
        case .preparingWindows: String(localized: "Preparing Windows for \(which.name)…")
        case .installing: String(localized: "Installing \(which.name)…")
        }
    }

    private func storeDetail(_ which: GameStores.Store, _ step: GameStores.Step) -> String {
        switch step {
        case .downloading: String(localized: "Getting the installer from \(which.vendor).")
        case .preparingWindows: String(localized: "Setting up a separate Windows environment for your games.")
        case .installing: which == .steam ? String(localized: "Steam updates itself on its first start, which can take a few minutes.")
                                          : String(localized: "This takes a minute or two.")
        }
    }

    private func title(_ step: AddProgram.Step) -> String {
        switch step {
        case .analyzing: String(localized: "Reading \(state.fileName)…")
        case .preparingWindows(let name): String(localized: "Preparing Windows for \(name)…")
        case .runningInstaller(let name): String(localized: "Installing \(name)")
        case .findingPrograms: String(localized: "Finding Programs…")
        }
    }

    private func detail(_ step: AddProgram.Step) -> String {
        switch step {
        case .analyzing: String(localized: "Checking what kind of program this is.")
        case .preparingWindows: String(localized: "This takes about half a minute the first time.")
        case .runningInstaller: String(localized: "Finish the installer’s window to continue. If it starts the program at the end, quit the program too. If nothing happens after that, click Stop.")
        case .findingPrograms: String(localized: "Looking for what the installer added.")
        }
    }
}
