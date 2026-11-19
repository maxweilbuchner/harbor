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
    let scan = store.scan()
    for b in scan.bottles {
        print("\(b.settings.name)\t\(b.settings.windowsVersion.rawValue)\t\(b.settings.graphics.rawValue)\t\(b.root.path)")
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
case "logs" where args.count == 2:
    for log in bottle(args[1]).logs() { print(log.path) }
case "stop" where args.count == 2:
    try launcher().shutdown(bottle(args[1]))
default:
    fail("usage: list | create <name> | open <bottle> <file> | run <bottle> <args…> | logs <bottle> | stop <bottle>")
}
