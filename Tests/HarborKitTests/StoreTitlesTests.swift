import Foundation
import Testing
@testable import HarborKit

@Suite struct StoreTitlesTests {
    let fm = FileManager.default

    // MARK: A Steam appinfo cache, written the way Steam writes it

    indirect enum Node { case map([(String, Node)]), string(String), int(UInt32) }

    func u32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) }) }

    func encode(_ entries: [(String, Node)], table: inout [String]?) -> Data {
        var out = Data()
        for (key, node) in entries {
            let type: UInt8 = { switch node { case .map: 0x00; case .string: 0x01; case .int: 0x02 } }()
            out.append(type)
            if table != nil {
                let index = table!.firstIndex(of: key) ?? { table!.append(key); return table!.count - 1 }()
                out += u32(UInt32(index))
            } else {
                out += Data(key.utf8) + [0]
            }
            switch node {
            case .map(let m): out += encode(m, table: &table)
            case .string(let s): out += Data(s.utf8) + [0]
            case .int(let v): out += u32(v)
            }
        }
        out.append(0x08)
        return out
    }

    func cache(_ apps: [(Int, [(String, Node)])], version: UInt32) -> Data {
        var table: [String]? = version == 0x0756_4429 ? [] : nil
        var body = Data()
        for (id, root) in apps {
            let vdf = encode(root, table: &table)
            body += u32(UInt32(id)) + u32(UInt32(60 + vdf.count)) + Data(repeating: 0xAB, count: 60) + vdf
        }
        body += u32(0)
        var out = u32(version) + u32(1)
        if let table {
            out += u32(UInt32(16 + body.count)) + u32(0)                 // 64-bit offset of the string table
            out += body + u32(UInt32(table.count))
            for s in table { out += Data(s.utf8) + [0] }
        } else {
            out += body
        }
        return out
    }

    func title(type: String, exe: String?, macFirst: Bool = false) -> [(String, Node)] {
        var launch: [(String, Node)] = []
        if macFirst { launch.append(("0", .map([("executable", .string("Thing.app")), ("config", .map([("oslist", .string("macos"))]))]))) }
        if let exe {
            launch.append(("1", .map([("executable", .string(exe)), ("arguments", .string("-fast")),
                                      ("config", .map([("oslist", .string("windows"))]))])))
        }
        return [("appinfo", .map([("appid", .int(1)), ("common", .map([("name", .string("X")), ("type", .string(type))])),
                                  ("config", .map([("installdir", .string("X")), ("launch", .map(launch))]))]))]
    }

    @Test func readsKindAndWindowsProgramFromSteamsCache() {
        for version in [0x0756_4428, 0x0756_4429] as [UInt32] {
            let data = cache([(10, title(type: "Game", exe: "game.exe")),
                              (20, title(type: "Application", exe: #"bin\editor.exe"#, macFirst: true)),
                              (30, title(type: "Tool", exe: nil))], version: version)
            let apps = SteamAppInfo.apps(in: data, ids: [10, 20, 30, 99])
            #expect(apps[10] == .init(type: "Game", executable: "game.exe", arguments: "-fast"), "version \(String(version, radix: 16))")
            #expect(apps[10]?.isSoftware == false)
            #expect(apps[20]?.executable == #"bin\editor.exe"#)              // the Windows entry, not the Mac one
            #expect(apps[20]?.isSoftware == true)
            #expect(apps[30] == .init(type: "Tool", executable: nil, arguments: nil))
            #expect(apps[99] == nil)
            #expect(SteamAppInfo.apps(in: data, ids: [20]).count == 1)       // others are skipped, not parsed
        }
    }

    /// A damaged or cut-off cache gives no information and never crashes.
    @Test func survivesDamagedCaches() {
        let good = cache([(10, title(type: "Game", exe: "game.exe")), (20, title(type: "Application", exe: "a.exe"))], version: 0x0756_4429)
        for cut in stride(from: 0, to: good.count, by: 1) { _ = SteamAppInfo.apps(in: good.prefix(cut), ids: [10, 20]) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var bad = good
            for _ in 0..<4 { bad[Int.random(in: 0..<bad.count, using: &generator)] = UInt8.random(in: .min ... .max, using: &generator) }
            _ = SteamAppInfo.apps(in: bad, ids: [10, 20])
        }
        #expect(SteamAppInfo.apps(in: Data("not a cache".utf8), ids: [10]).isEmpty)
        #expect(SteamAppInfo.apps(in: Data(), ids: [10]).isEmpty)
    }

    // MARK: Games and software in a bottle

    /// A Steam bottle with one game and one application installed, as Steam records them.
    func steamBottle() throws -> (Bottle, URL) {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-titles-\(UUID().uuidString)")).create(name: "Steam")
        let steam = b.driveC.appending(path: "Program Files (x86)/Steam")
        try fm.createDirectory(at: steam.appending(path: "steamapps/common/Maze"), withIntermediateDirectories: true)
        try fm.createDirectory(at: steam.appending(path: "steamapps/common/Editor/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: steam.appending(path: "appcache"), withIntermediateDirectories: true)
        for file in ["steam.exe", "steamapps/common/Maze/maze.exe", "steamapps/common/Editor/bin/editor.exe"] {
            try Data().write(to: steam.appending(path: file))
        }
        for (id, name, dir) in [(10, "Maze", "Maze"), (20, "Editor", "Editor")] {
            try "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"\(dir)\"\n}\n"
                .write(to: steam.appending(path: "steamapps/appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        try cache([(10, title(type: "Game", exe: "maze.exe")), (20, title(type: "Application", exe: #"bin\editor.exe"#))], version: 0x0756_4429)
            .write(to: steam.appending(path: "appcache/appinfo.vdf"))
        return (b, steam)
    }

    @Test func steamGamesStartThroughSteamAndSoftwareByItsOwnProgram() throws {
        let (b, steam) = try steamBottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let games = SteamLibrary.games(in: b)
        #expect(games.map(\.name) == ["Editor", "Maze"])
        let editor = try #require(SteamLibrary.program(for: games[0], steam: steam, in: b, salt: "s"))
        let maze = try #require(SteamLibrary.program(for: games[1], steam: steam, in: b, salt: "s"))

        #expect(maze.isGame && maze.arguments == "-applaunch 10" && maze.windowsPath.hasSuffix(#"\steam.exe"#))
        #expect(!editor.isGame)
        #expect(editor.windowsPath == #"C:\Program Files (x86)\Steam\steamapps\common\Editor\bin\editor.exe"#)
        #expect(editor.arguments == "-fast")
        #expect(editor.workingDirectory == #"C:\Program Files (x86)\Steam\steamapps\common\Editor\bin"#)
        // D3DMetal is refused for it even if asked for.
        var asked = editor; asked.graphics = .d3dmetal
        let launcher = WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent")),
                                    d3dmetal: D3DMetalRedist(lib: URL(filePath: "/nonexistent")))
        #expect(launcher.effectiveGraphics(for: asked) != .d3dmetal)
    }

    @Test func theUsersChoiceWinsOverTheStoresRecordAndSurvivesRescans() throws {
        let (b, steam) = try steamBottle()
        defer { try? fm.removeItem(at: b.root.deletingLastPathComponent()) }
        let games = SteamLibrary.games(in: b)
        try b.setStoreTitle("steam:10", isGame: false)        // "Maze" is software after all
        try b.setStoreTitle("steam:20", isGame: true)         // and "Editor" a game
        let rescanned = SteamLibrary.games(in: b)
        let editor = try #require(SteamLibrary.program(for: rescanned[0], steam: steam, in: b, salt: "s"))
        let maze = try #require(SteamLibrary.program(for: rescanned[1], steam: steam, in: b, salt: "s"))
        #expect(editor.isGame && editor.arguments == "-applaunch 20")
        #expect(!maze.isGame && maze.windowsPath.hasSuffix(#"\Maze\maze.exe"#))
        // The ID doesn't depend on the choice (the Mac shortcut stays the same).
        #expect(maze.id == SteamLibrary.program(for: games[1], steam: steam, in: b, salt: "s")?.id)
        // Back to the store's word.
        try b.setStoreTitle("steam:10", isGame: nil)
        try b.setStoreTitle("steam:20", isGame: nil)
        #expect(b.storeTitleChoices().isEmpty && !fm.fileExists(atPath: b.root.appending(path: "store-titles.json").path))
        #expect(SteamLibrary.program(for: rescanned[1], steam: steam, in: b, salt: "s")?.isGame == true)
    }

    @Test func epicTitlesListedAsSoftwareAreNotGames() throws {
        func manifest(_ categories: String) -> Data {
            Data(#"{"AppName":"A","DisplayName":"A","InstallLocation":"C:\\A","LaunchExecutable":"a.exe","bIsApplication":true,"AppCategories":[\#(categories)]}"#.utf8)
        }
        #expect(EpicLibrary.parseManifest(manifest(#""public","games","applications""#))?.isSoftware == false)
        #expect(EpicLibrary.parseManifest(manifest(#""public","applications""#))?.isSoftware == true)
        #expect(EpicLibrary.parseManifest(manifest(#""public","software","editors""#))?.isSoftware == true)
        #expect(EpicLibrary.parseManifest(manifest(""))?.isSoftware == false)          // no categories: a game, as before
    }
}
