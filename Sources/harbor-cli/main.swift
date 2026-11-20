import Foundation
import HarborKit

// Developer CLI for exercising HarborKit without the GUI.
//   harbor-cli list
//   harbor-cli create <name>
//   harbor-cli open <bottle> <file.exe|file.msi>
//   harbor-cli run <bottle> <wine args...>      e.g. run Test cmd /c ver
//   harbor-cli stop <bottle>
//   harbor-cli programs <bottle>                    # scan the Start Menu into the bottle's library
//   harbor-cli launch <bottle> <program name>
//   harbor-cli add <file.exe|file.msi>                # the app's add-program flow
//   harbor-cli prepare-template                       # pre-build the prefix new bottles clone
//   harbor-cli analyze <file>                         # what Harbor reads from a program
//   harbor-cli add-steam [--store <dir>]              # the app's one-click Steam setup
//   harbor-cli add-epic [--store <dir>]               # the same for the Epic Games Store
//   harbor-cli components <bottle>                    # Windows components (Visual C++) and whether installed
//   harbor-cli install-component <bottle> <id>        # e.g. vcrun2022
//   harbor-cli gen-runtime-key                      # private key → ~/.config/harbor/runtime-signing.key
//   harbor-cli sign-manifest <runtime.json>         # writes runtime.json.sig with that key
//   harbor-cli install-runtime <manifest-url> [--into <dir>]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("harbor-cli: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let store = BottleStore.default

func launcher() -> WineLauncher {
    guard let runtime = WineRuntime.locate() else {
        fail("no Wine runtime found; run scripts/fetch-runtime.sh or set HARBOR_WINE_ROOT")
    }
    return WineLauncher(runtime: runtime, d3dmetal: D3DMetalRedist.locate())
}

let signingKeyFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/harbor/runtime-signing.key")

func bottle(_ name: String) -> Bottle {
    guard let found = store.bottle(named: name) else { fail("no bottle named \(name)") }
    return found
}

switch args.first {
case "list":
    let scan = store.scan()
    let runtime = WineRuntime.locate()
    for b in scan.bottles {
        let update = runtime.map { b.needsWindowsUpdate(for: $0) ? "needs-update" : "up-to-date" } ?? "-"
        let state = b.isRunning() ? "running" : "stopped"
        print("\(b.settings.name)\t\(b.settings.windowsVersion.rawValue)\t\(b.settings.graphics.rawValue)\t\(update)\t\(state)\t\(b.root.path)")
    }
    for (folder, error) in scan.damaged {
        print("DAMAGED\t\(folder.path)\t\(error.localizedDescription)")
    }
case "create" where args.count == 2:
    let wine = launcher()
    print("Creating \(args[1])…")
    let b = try await store.create(name: args[1], setUp: wine.initialize)
    print("Ready: \(b.root.path)")
case "open" where args.count == 3:
    let p = try launcher().open(URL(filePath: args[2]), in: bottle(args[1]))
    p.waitUntilExit()
    exit(p.terminationStatus)
case "run" where args.count >= 3:
    let b = bottle(args[1])
    let p = try launcher().run(b, arguments: Array(args.dropFirst(2)), output: .standardOutput)
    p.waitUntilExit()
    exit(p.terminationStatus)
case "programs" where args.count == 2:
    // Scans the bottle's Start Menu, merges new programs into its library and lists them.
    let b = bottle(args[1])
    if b.programsFileIsDamaged { fail("\(b.root.path)/programs.json can't be read; not overwriting it") }
    var library = b.programs()
    for found in b.startMenuPrograms() where !library.contains(where: { $0.windowsPath.lowercased() == found.windowsPath.lowercased() }) {
        library.append(found)
    }
    try b.savePrograms(library)
    let wine = launcher()
    for p in library {
        print("\(p.name)\t\(p.isGame ? "game" : "app")\t\(wine.effectiveGraphics(for: p).rawValue)\t\(p.windowsPath)")
    }
case "add" where args.count == 2:
    // The app's add-program flow: a new bottle named after the product, installer run or program placed.
    let flow = AddProgram(store: store, launcher: launcher())
    let (b, programs) = try await flow.add(URL(filePath: args[1])) { step in print("…", step) }
    for p in programs {
        let icon = FileManager.default.fileExists(atPath: b.iconFile(for: p).path) ? "icon" : "no icon"
        print("added \(p.name)\t\(p.isGame ? "game" : "app")\t\(icon)\t\(p.windowsPath)\tbottle \(b.settings.name)")
    }
case "components" where args.count == 2:
    // Windows components Harbor can install into a bottle (Microsoft's Visual C++ runtimes).
    let b = bottle(args[1])
    for r in Recipe.all { print("\(r.id)\t\(r.isInstalled(in: b) ? "installed" : "-")\t\(r.name)") }
case "install-component" where args.count == 3:
    let b = bottle(args[1])
    guard let recipe = Recipe.named(args[2]) else { fail("unknown component \(args[2]); see `components <bottle>`") }
    try await launcher().install(recipe, in: b)
    print("\(recipe.name) installed in \(b.settings.name): \(recipe.isInstalled(in: b) ? "verified" : "NOT FOUND")")
// The condition is repeated: a `where` after several patterns applies to the last one only.
case "add-steam" where args.count == 1 || (args.count == 3 && args[1] == "--store"),
     "add-epic" where args.count == 1 || (args.count == 3 && args[1] == "--store"):
    // The app's "Add Steam" / "Add Epic Games Store": download the official installer, silent install into its
    // own bottle.
    let which: GameStores.Store = args[0] == "add-epic" ? .epic : .steam
    let target = args.count == 3 ? BottleStore(directory: URL(filePath: args[2])) : store
    let (b, p) = try await GameStores(store: target, launcher: launcher()).install(which) { print("…", $0) }
    print("\(which.name) ready in \(b.root.path): \(p.name) \(p.windowsPath)")
case "analyze" where args.count == 2:
    // What Harbor reads from a program: architecture, DirectX, game classification (incl. its folder).
    let url = URL(filePath: args[1])
    if let a = try? ProgramAnalysis.analyze(url) {
        print("\(a.displayName(fallback: url)) arch=\(a.architecture.rawValue) gui=\(a.isGUI) d3d=\(a.direct3D.map(String.init) ?? "-") installer=\(a.installer?.rawValue ?? "-") gameImports=\(a.looksLikeGame)")
    }
    print("game (with folder): \(Bottle.looksLikeGame(url))")
case "suggest-name" where args.count == 2:
    print(AddProgram.suggestedName(for: URL(filePath: args[1])) ?? "(not a Windows program)")
case "prepare-template" where args.count == 1:
    let template = PrefixTemplate(launcher: launcher())
    let start = Date()
    try await template.prepare()
    print("template ready (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
case "launch" where args.count == 3:
    let b = bottle(args[1])
    guard let program = b.programs().first(where: { $0.name == args[2] }) else { fail("no program \(args[2]) in \(args[1]); run `programs` first") }
    let p = try launcher().launch(program, in: b)
    p.waitUntilExit()
    exit(p.terminationStatus)
case "logs" where args.count == 2:
    for log in bottle(args[1]).logs() { print(log.path) }
case "stop" where args.count == 2:
    try launcher().shutdown(bottle(args[1]))
case "gen-runtime-key" where args.count == 1:
    if FileManager.default.fileExists(atPath: signingKeyFile.path) { fail("\(signingKeyFile.path) already exists") }
    try FileManager.default.createDirectory(at: signingKeyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let key = RuntimeSigning.newPrivateKey()
    FileManager.default.createFile(atPath: signingKeyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
    print(try RuntimeSigning.publicKey(forPrivate: key))
case "sign-manifest" where args.count == 2:
    let manifest = URL(filePath: args[1])
    let key = try String(contentsOf: signingKeyFile, encoding: .utf8)
    let data = try Data(contentsOf: manifest)
    _ = try JSONDecoder().decode(RuntimeManifest.self, from: data) // refuse to sign something malformed
    try Data(try RuntimeSigning.sign(data, privateKey: key).utf8).write(to: manifest.appendingPathExtension("sig"))
    print("signed \(manifest.path)")
case "install-runtime" where args.count == 2 || (args.count == 4 && args[2] == "--into"):
    guard let url = URL(string: args[1]), url.scheme != nil else { fail("not a URL: \(args[1])") }
    let publicKey = try RuntimeSigning.publicKey(
        ProcessInfo.processInfo.environment["HARBOR_RUNTIME_PUBLIC_KEY"]
            ?? (try String(contentsOf: WineRuntime.checkoutRoot.appending(path: "scripts/runtime-signing.pub"), encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines))
    let into = args.count == 4 ? URL(filePath: args[3]) : WineRuntime.installedDirectory
    let installer = RuntimeInstaller(manifestURL: url, publicKey: publicKey, installedDirectory: into)
    let manifest = try await installer.fetchManifest()
    let pending = installer.pending(in: manifest)
    if pending.isEmpty { print("up to date"); exit(0) }
    print("installing \(pending.map { "\($0.id) \($0.version)" }.joined(separator: ", ")) into \(into.path)")
    try await installer.installPending(manifest) { fraction in
        FileHandle.standardError.write(Data(String(format: "\r%5.1f%%", fraction * 100).utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    print("installed")
default:
    fail("usage: list | create <name> | open <bottle> <file> | run <bottle> <args…> | programs <bottle> | launch <bottle> <name> | add <file> | prepare-template | analyze <file> | add-steam [--store <dir>] | add-epic [--store <dir>] | components <bottle> | install-component <bottle> <id> | logs <bottle> | stop <bottle> | gen-runtime-key | sign-manifest <file> | install-runtime <url> [--into <dir>]")
}
