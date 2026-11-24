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
//   harbor-cli add <file.exe|file.msi|folder>         # the app's add-program flow
//   harbor-cli prepare-template                       # pre-build the prefix new bottles clone
//   harbor-cli analyze <file>                         # what Harbor reads from a program
//   harbor-cli run-with <bottle> <layer> <args…>      # like run, on one graphics layer (d3dmetal, dxmt, wined3d); for tests
//   harbor-cli add-steam [--store <dir>]              # the app's one-click Steam setup
//   harbor-cli add-epic [--store <dir>]               # the same for the Epic Games Store
//   harbor-cli components <bottle>                    # Windows components (Visual C++) and whether installed
//   harbor-cli install-component <bottle> <id>        # e.g. vcrun2022
//   harbor-cli gen-runtime-key                      # private key → ~/.config/harbor/runtime-signing.key
//   harbor-cli sign-manifest <runtime.json>         # writes runtime.json.sig with that key
//   harbor-cli install-runtime <manifest-url> [--into <dir>]
//   harbor-cli update-runtime <manifest-url> [--into <dir>]   # stage, switch, prove it starts (rolls back if not)

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
case "create" where args.count == 2 || (args.count == 3 && args[2] == "--mac-files"):
    // --mac-files: keep drive Z: (the whole Mac), which the Windows test programs use for their files.
    let wine = launcher()
    print("Creating \(args[1])…")
    var b = try await store.create(name: args[1], setUp: wine.initialize)
    if args.count == 3 {
        b.settings.macFilesAccess = true
        try b.save()
        b.applyMacFilesAccess()        // setup removed drive Z: before the setting existed; put it back now
    }
    print("Ready: \(b.root.path)")
case "mac-files" where args.count == 3 && ["on", "off"].contains(args[2]):
    // Whether the bottle's programs see the Mac's files as drive Z: (applies at the bottle's next start).
    var b = bottle(args[1])
    b.settings.macFilesAccess = args[2] == "on"
    try b.save()
    print("\(b.settings.name): Mac files \(args[2])")
case "open" where args.count == 3:
    let p = try launcher().open(URL(filePath: args[2]), in: bottle(args[1]))
    p.waitUntilExit()
    exit(p.terminationStatus)
case "run" where args.count >= 3:
    let b = bottle(args[1])
    let p = try launcher().run(b, arguments: Array(args.dropFirst(2)), output: .standardOutput)
    p.waitUntilExit()
    exit(p.terminationStatus)
case "run-with" where args.count >= 4:
    // For WindowsTests/graphics: runs on one graphics layer's runtime, whatever the bottle or program says (a
    // bottle-level D3DMetal setting is ignored otherwise, since D3DMetal is for games only). Fails if the layer
    // isn't installed, instead of quietly testing plain Wine.
    let b = bottle(args[1])
    guard let layer = GraphicsBackend(rawValue: args[2]) else { fail("unknown graphics layer \(args[2])") }
    let l = try launcher()
    let runtime = try l.runtime(for: layer)
    if layer != .wined3d, runtime.root == l.runtime.root { fail("\(args[2]) isn't installed") }
    if layer == .dxmt { try l.dxmt?.prepare(b) }
    let p = try l.run(b, arguments: Array(args.dropFirst(3)), output: .standardOutput, runtime: runtime)
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
case "steam-titles" where args.count == 2:
    // What Steam's own records say about the titles installed in a bottle: kind and Windows program.
    let b = bottle(args[1])
    guard let steam = SteamLibrary.steamFolder(in: b) else { fail("no Steam in \(b.settings.name)") }
    let games = SteamLibrary.games(in: b)
    let info = (try? Data(contentsOf: steam.appending(path: "appcache/appinfo.vdf"))).map { SteamAppInfo.apps(in: $0, ids: Set(games.map(\.appID))) } ?? [:]
    for g in games {
        let a = info[g.appID]
        print("\(g.appID)\t\(g.name)\t\(a?.type ?? "?")\t\(a?.executable ?? "?")\t\(a?.arguments ?? "")")
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
case "update-runtime" where args.count == 2 || (args.count == 4 && args[2] == "--into"):
    // The app's background update, in one go: stage what the signed list offers next to the installed runtime,
    // switch to it, prove the new Wine starts (else the previous one is put back). Only with no bottle running.
    guard let url = URL(string: args[1]), url.scheme != nil else { fail("not a URL: \(args[1])") }
    let publicKey = try RuntimeSigning.publicKey(
        ProcessInfo.processInfo.environment["HARBOR_RUNTIME_PUBLIC_KEY"]
            ?? (try String(contentsOf: WineRuntime.checkoutRoot.appending(path: "scripts/runtime-signing.pub"), encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines))
    let into = args.count == 4 ? URL(filePath: args[3]) : WineRuntime.installedDirectory
    if args.count == 2, store.list().contains(where: { $0.isRunning() }) { fail("a bottle is running; quit its programs first") }
    let installer = RuntimeInstaller(manifestURL: url, publicKey: publicKey, installedDirectory: into)
    let manifest = try await installer.fetchManifest()
    switch installer.decision(for: manifest, appBuild: nil) {
    case .upToDate where !installer.hasStagedUpdate: try installer.recordSequenceOfInstalled(manifest); print("up to date"); exit(0)
    case .refusedOlder: fail("the list is older than the installed runtime")
    case .needsNewerApp(let build): fail("needs Harbor build \(build)")
    case .failedBefore: fail("this list's runtime didn't start here before; waiting for a newer one")
    case .available(let components): print("staging \(components.map { "\($0.id) \($0.version)" }.joined(separator: ", "))")
    case .upToDate: break
    }
    try await installer.stage(manifest, appBuild: nil)
    try installer.activateStaged { installed in WineRuntime(root: installed.appending(path: "wine")).starts() }
    installer.removeOldVersions()
    print("updated: wine \(installer.installedVersion(of: "wine") ?? "-"), d3dmetal \(installer.installedVersion(of: "d3dmetal") ?? "-"), sequence \(installer.installedSequence.map(String.init) ?? "-")")
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
    fail("usage: list | create <name> [--mac-files] | mac-files <bottle> on|off | open <bottle> <file> | run <bottle> <args…> | run-with <bottle> <layer> <args…> | programs <bottle> | launch <bottle> <name> | add <file> | prepare-template | analyze <file> | add-steam [--store <dir>] | add-epic [--store <dir>] | components <bottle> | install-component <bottle> <id> | logs <bottle> | stop <bottle> | gen-runtime-key | sign-manifest <file> | install-runtime <url> [--into <dir>] | update-runtime <url> [--into <dir>]")
}
