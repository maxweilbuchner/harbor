import Foundation
import HarborKit

// Developer CLI for exercising HarborKit without the GUI.
//   harbor-cli list
//   harbor-cli create <name>
//   harbor-cli open <bottle> <file.exe|file.msi>
//   harbor-cli run <bottle> <wine args...>      e.g. run Test cmd /c ver
//   harbor-cli stop <bottle>

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

func bottle(_ name: String) -> Bottle {
    guard let found = store.bottle(named: name) else { fail("no bottle named \(name)") }
    return found
}

switch args.first {
case "list":
    for b in store.list() {
        print("\(b.settings.name)\t\(b.settings.windowsVersion.rawValue)\t\(b.settings.graphics.rawValue)\t\(b.root.path)")
    }
case "create" where args.count == 2:
    let wine = launcher()
    let b = try store.create(name: args[1])
    print("Creating \(b.settings.name) at \(b.root.path)…")
    try await wine.initialize(b)
    print("Ready.")
case "open" where args.count == 3:
    let p = try launcher().open(URL(filePath: args[2]), in: bottle(args[1]))
    p.waitUntilExit()
case "run" where args.count >= 3:
    let b = bottle(args[1])
    let p = try launcher().run(b, arguments: Array(args.dropFirst(2)), log: URL(filePath: "/dev/stdout"))
    p.waitUntilExit()
    exit(p.terminationStatus)
case "stop" where args.count == 2:
    try launcher().shutdown(bottle(args[1]))
default:
    fail("usage: list | create <name> | open <bottle> <file> | run <bottle> <args…> | stop <bottle>")
}
