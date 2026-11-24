import Foundation
import Testing
@testable import HarborKit

@Suite struct AddProgramEdgeTests {
    let fm = FileManager.default

    /// A fresh temp folder and a function that creates empty files (and their folders) inside it.
    func tree() throws -> (URL, (String) throws -> Void) {
        let base = fm.temporaryDirectory.appending(path: "harbor-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, { path in
            let url = base.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        })
    }

    // MARK: #13

    /// A loose program in a folder of other games (`/Volumes/SSD/Games/tool.exe`): only the program is copied.
    @Test func aLooseProgramBesideOtherGamesDoesNotTakeTheirFolder() throws {
        let (base, touch) = try tree()
        defer { try? fm.removeItem(at: base) }
        for f in ["Games/tool.exe", "Games/Quest/Quest.exe", "Games/Quest/Data/quest.pak",
                  "Games/Racer/racer.exe", "Games/Racer/engine.dll"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Games/tool.exe")) == nil)
    }

    /// `~/Sync/bin/tool.exe` beside a letter and photos: walking up from `bin` stops below `Sync`.
    @Test func walkingUpFromBinNeverTakesAFolderOfPersonalFiles() throws {
        let (base, touch) = try tree()
        defer { try? fm.removeItem(at: base) }
        for f in ["Sync/bin/tool.exe", "Sync/letter.pdf", "Sync/Photos/2026/beach.jpg"] { try touch(f) }
        let bin = base.appending(path: "Sync/bin").standardizedFileURL
        #expect(AddProgram.programRoot(for: base.appending(path: "Sync/bin/tool.exe")) == bin)
        // The same without a document at the top level: the photos sit one folder down.
        try fm.removeItem(at: base.appending(path: "Sync/letter.pdf"))
        #expect(AddProgram.programRoot(for: base.appending(path: "Sync/bin/tool.exe")) == bin)
    }

    /// Without DLLs or an Unreal `Engine` folder, subfolders come along only if nothing in them looks like
    /// someone else's: another program, personal documents, or the dot-files of a synced or working folder.
    @Test func subfoldersComeAlongOnlyWhenTheyLookLikeTheProgramsOwn() throws {
        let (base, touch) = try tree()
        defer { try? fm.removeItem(at: base) }
        for f in ["Old/game.exe", "Old/data/levels/one.dat", "Old/.DS_Store"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Old/game.exe")) == base.appending(path: "Old").standardizedFileURL)
        for f in ["Work/tool.exe", "Work/project/.git/HEAD", "Work/project/notes.txt"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Work/tool.exe")) == nil)
        for f in ["Dropbox/bin/tool.exe", "Dropbox/.dropbox", "Dropbox/Notes/todo.txt"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Dropbox/bin/tool.exe"))
                == base.appending(path: "Dropbox/bin").standardizedFileURL)
        // Too many files to tell: only the program.
        try touch("Huge/tool.exe")
        for n in 0...AddProgram.unprovenFolderLimit { try touch("Huge/data/\(n).dat") }
        #expect(AddProgram.programRoot(for: base.appending(path: "Huge/tool.exe")) == nil)
    }

    @Test func cloudStorageRootsAreShared() {
        let cloud = fm.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        for shared in ["", "Dropbox", "GoogleDrive-someone@example.com", "GoogleDrive-someone@example.com/My Drive"] {
            #expect(AddProgram.isSharedFolder(cloud.appending(path: shared)), "\(shared)")
        }
        #expect(!AddProgram.isSharedFolder(cloud.appending(path: "Dropbox/Games/Thing")))
    }

    // MARK: #25

    /// A program folder around the `game64` fixture, and what's needed to place it in a new bottle.
    func placing() throws -> (AddProgram, Bottle, ProgramAnalysis, folder: URL) {
        let (base, touch) = try tree()
        let store = BottleStore(directory: base.appending(path: "bottles"))
        let flow = AddProgram(store: store, launcher: WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent"))))
        let fixture = try #require(Bundle.module.url(forResource: "game64", withExtension: "exe"))
        try touch("Game/engine.dll")
        try fm.copyItem(at: fixture, to: base.appending(path: "Game/game.exe"))
        return (flow, try store.create(name: "Edge"), try ProgramAnalysis.analyze(fixture), base.appending(path: "Game"))
    }

    /// Links that lead out of the program's folder would let Windows programs reach (and delete) Mac files.
    @Test func linksOutOfTheProgramFolderStayOutOfTheBottle() throws {
        let (flow, bottle, analysis, game) = try placing()
        defer { try? fm.removeItem(at: game.deletingLastPathComponent()) }
        let outside = game.deletingLastPathComponent().appending(path: "Mac Documents")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appending(path: "data"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: game.appending(path: "Saves"), withDestinationURL: outside)
        try fm.createSymbolicLink(atPath: game.appending(path: "data/up").path, withDestinationPath: "../../Mac Documents")
        try fm.createSymbolicLink(atPath: game.appending(path: "data/self").path, withDestinationPath: game.path)
        try fm.createSymbolicLink(atPath: game.appending(path: "data/engine.dll").path, withDestinationPath: "../engine.dll")
        _ = try flow.place(game.appending(path: "game.exe"), analysis: analysis, name: "Game", in: bottle)
        let placed = bottle.driveC.appending(path: "Program Files/Game")
        #expect(fm.fileExists(atPath: placed.appending(path: "game.exe").path))
        for link in ["Saves", "data/up", "data/self"] {
            #expect((try? fm.destinationOfSymbolicLink(atPath: placed.appending(path: link).path)) == nil, "\(link)")
        }
        // A link that stays inside the program's folder is the program's business.
        #expect((try? fm.destinationOfSymbolicLink(atPath: placed.appending(path: "data/engine.dll").path)) == "../engine.dll")
        #expect(fm.fileExists(atPath: outside.path))
    }

    /// A dropped alias of a program brings the program, not a link back to the Mac.
    @Test func aLinkedProgramIsCopiedAsAFile() throws {
        let (flow, bottle, analysis, game) = try placing()
        defer { try? fm.removeItem(at: game.deletingLastPathComponent()) }
        let shared = game.deletingLastPathComponent().appending(path: "Downloads")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: shared.appending(path: "tool.exe"), withDestinationURL: game.appending(path: "game.exe"))
        _ = try flow.place(shared.appending(path: "tool.exe"), analysis: analysis, name: "Tool", in: bottle)
        let placed = bottle.driveC.appending(path: "Program Files/Tool/tool.exe")
        #expect(fm.fileExists(atPath: placed.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: placed.path)) == nil)
    }

    /// A product called ".." has no usable folder name; the program's file name stands in.
    @Test func aNameWithoutUsableCharactersFallsBackToTheFileName() throws {
        let (flow, bottle, analysis, game) = try placing()
        defer { try? fm.removeItem(at: game.deletingLastPathComponent()) }
        let program = try flow.place(game.appending(path: "game.exe"), analysis: analysis, name: "..", in: bottle)
        #expect(program.windowsPath == #"C:\Program Files\game\game.exe"#)
        #expect(fm.fileExists(atPath: bottle.driveC.appending(path: "Program Files/game/game.exe").path))
        #expect(AddProgram.safeFolderName("..", fallback: "a?b") == "a-b")
        #expect(AddProgram.safeFolderName(" . ", fallback: "...") == "Program")
        #expect(AddProgram.safeFolderName("Thing", fallback: "other") == "Thing")
    }

    // MARK: #24

    /// A Shell Link as Windows writes it for a path outside the ANSI code page: LinkInfo with the 0x24-byte
    /// header, the path in Windows-1252 (as `ansi`; "?" in the suffix) and again in UTF-16.
    static func unicodeLink(base: String, suffix: String = "", ansi: [UInt8]) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        func wide(_ s: String) -> [UInt8] { s.utf16.flatMap { u16(Int($0)) } + [0, 0] }
        let header = 0x24
        let ansiBase = ansi + [0], ansiSuffix = suffix.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : 0x3F } + [0]
        let wideBase = wide(base), wideSuffix = wide(suffix)
        let suffixAt = header + ansiBase.count, wideBaseAt = suffixAt + ansiSuffix.count
        let wideSuffixAt = wideBaseAt + wideBase.count
        let info = u32(wideSuffixAt + wideSuffix.count) + u32(header) + u32(1) + u32(0) + u32(header) + u32(0)
            + u32(suffixAt) + u32(wideBaseAt) + u32(wideSuffixAt) + ansiBase + ansiSuffix + wideBase + wideSuffix
        return Data(u32(0x4C) + [UInt8](repeating: 0, count: 16) + u32(0x2 | 0x80)
                    + [UInt8](repeating: 0, count: 0x4C - 0x18) + info)
    }

    static let pokemon = #"C:\Games\Pok\#u{E9}mon\game.exe"#
    static let pokemonANSI = Array(#"C:\Games\Pok"#.utf8) + [0xE9] + Array(#"mon\game.exe"#.utf8)

    @Test func shellLinksPreferTheUnicodePath() {
        #expect(ShellLink(Self.unicodeLink(base: Self.pokemon, ansi: Self.pokemonANSI))?.target == Self.pokemon)
        // The suffix has a Unicode form too.
        let split = Self.unicodeLink(base: #"C:\Games\"#, suffix: "Pok\u{E9}mon.exe", ansi: Array(#"C:\Games\"#.utf8))
        #expect(ShellLink(split)?.target == "C:\\Games\\Pok\u{E9}mon.exe")
        let real = Self.unicodeLink(base: Self.pokemon, ansi: Self.pokemonANSI)
        for n in 0..<real.count { _ = ShellLink(real.prefix(n)) }   // truncations never crash
        // Offsets that point outside the block fall back to the ANSI path.
        var broken = Self.unicodeLink(base: #"C:\x.exe"#, ansi: Array(#"C:\x.exe"#.utf8))
        broken.replaceSubrange(0x4C + 28 ..< 0x4C + 32, with: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(ShellLink(broken)?.target == #"C:\x.exe"#)
    }

    @Test func findsStartMenuProgramsInstalledToNonASCIIFolders() throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-edge-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: store.directory) }
        let bottle = try store.create(name: "Unicode")
        let app = bottle.driveC.appending(path: "Games/Pok\u{E9}mon")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "game64", withExtension: "exe"))
        try fm.copyItem(at: fixture, to: app.appending(path: "game.exe"))
        let menu = bottle.driveC.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try Self.unicodeLink(base: Self.pokemon, ansi: Self.pokemonANSI).write(to: menu.appending(path: "Pok\u{E9}mon.lnk"))
        #expect(bottle.startMenuPrograms().map(\.windowsPath) == [Self.pokemon])
    }

    // MARK: #43

    /// An installer that makes no shortcut and installs outside Program Files: its program is still found, its
    /// uninstaller and what Windows itself holds are not.
    @Test func whatAnInstallerPutOutsideProgramFilesIsFound() throws {
        let (base, _) = try tree()
        defer { try? fm.removeItem(at: base) }
        let bottle = try BottleStore(directory: base.appending(path: "bottles")).create(name: "Outside")
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        func put(_ path: String) throws {
            let url = bottle.driveC.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: app, to: url)
        }
        for path in ["windows/notepad.exe", "users/me/AppData/Local/Temp/tool.exe", "ProgramData/Package Cache/helper.exe"] {
            try put(path)
        }
        let before = AddProgram.installedExecutables(in: bottle)
        #expect(before.isEmpty)
        for path in ["Games/Thing/thing.exe", "Games/Thing/unins000.exe", "Program Files/Vendor/Product/bin/product.exe",
                     "windows/system32/added.exe", "Games/a/b/c/d/e/deep.exe"] {
            try put(path)
        }
        let added = AddProgram.installedExecutables(in: bottle).subtracting(before)
        #expect(Set(added.map(\.lastPathComponent)) == ["thing.exe", "unins000.exe", "product.exe"])
        let programs = AddProgram.programs(among: added, in: bottle)
        #expect(Set(programs.map(\.windowsPath))
                == [#"C:\Games\Thing\thing.exe"#, #"C:\Program Files\Vendor\Product\bin\product.exe"#])
    }

    // MARK: #45

    /// A dropped folder stands for the installer or program at its top.
    @Test func aDroppedFolderIsResolvedToItsInstallerOrProgram() throws {
        let (base, touch) = try tree()
        defer { try? fm.removeItem(at: base) }
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        func put(_ path: String) throws {
            try touch(path)
            try fm.removeItem(at: base.appending(path: path))
            try fm.copyItem(at: app, to: base.appending(path: path))
        }
        func entry(_ folder: String) throws -> String {
            let found = try AddProgram.entry(in: base.appending(path: folder)).path
            return String(found.dropFirst(base.resolvingSymlinksInPath().path.count + folder.count + 2))
        }
        // A disc: the installer by its name, although a launcher sits beside it; subfolders don't count.
        for f in ["Disc/setup.exe", "Disc/launcher.exe", "Disc/Redist/vc_redist_setup.exe"] { try put(f) }
        try touch("Disc/data-01.bin")
        #expect(try entry("Disc") == "setup.exe")
        // What autorun.inf opens comes first, whatever its case and arguments.
        try "[autorun]\r\nicon=x.ico\r\nOPEN = Bin\\Start.EXE /auto\r\n".write(
            to: base.appending(path: "Disc/AUTORUN.INF"), atomically: true, encoding: .utf8)
        try put("Disc/bin/start.exe")
        #expect(try entry("Disc") == "bin/start.exe")
        // …unless it names nothing inside the folder.
        try "[autorun]\nopen=..\\Other\\x.exe\n".write(to: base.appending(path: "Disc/AUTORUN.INF"), atomically: true, encoding: .utf8)
        #expect(try entry("Disc") == "setup.exe")

        // A ready-to-run program: the one program, with a redistributable's installer and an uninstaller beside it.
        for f in ["Thing/thing.exe", "Thing/vc_redist_install.exe", "Thing/unins000.exe", "Thing/Uninstall.exe"] { try put(f) }
        #expect(try entry("Thing") == "thing.exe")
        // The only installer, whatever its name.
        try put("Download/thing_installer_2.exe")
        #expect(try entry("Download") == "thing_installer_2.exe")
        // Several programs: the one named like the folder.
        for f in ["Old Game/oldgame.exe", "Old Game/editor.exe"] { try put(f) }
        #expect(try entry("Old Game") == "oldgame.exe")
        // Nothing to go by.
        for f in ["Tools/a.exe", "Tools/b.exe"] { try put(f) }
        try touch("Empty/readme.txt")
        #expect(throws: AddProgram.Failure.unclearFolder) { try AddProgram.entry(in: base.appending(path: "Tools")) }
        #expect(throws: AddProgram.Failure.unclearFolder) { try AddProgram.entry(in: base.appending(path: "Empty")) }
        // Downloads is nobody's program folder, even with one program in it.
        try put("Downloads/thing.exe")
        #expect(throws: AddProgram.Failure.sharedFolder) { try AddProgram.entry(in: base.appending(path: "Downloads")) }

        // The bottle is named after the product, or after the folder when the program carries no name.
        #expect(AddProgram.suggestedName(for: base.appending(path: "Thing")) == "Fixture App")
        #expect(AddProgram.suggestedName(for: base.appending(path: "Tools")) == nil)
    }

    /// A dropped program folder comes into the bottle whole, also where Harbor wouldn't have dared on its own.
    @Test func aDroppedProgramFolderIsCopiedWhole() async throws {
        let (base, touch) = try tree()
        defer { try? fm.removeItem(at: base) }
        let store = BottleStore(directory: base.appending(path: "bottles"))
        let flow = AddProgram(store: store, launcher: WineLauncher(runtime: WineRuntime(root: URL(filePath: "/nonexistent"))))
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        let game = base.appending(path: "Old Game")
        for f in ["Old Game/Manual.pdf", "Old Game/data/levels.pak", "Old Game/tools/editor.exe"] { try touch(f) }
        try fm.copyItem(at: app, to: game.appending(path: "game.exe"))
        #expect(AddProgram.programRoot(for: game.appending(path: "game.exe")) == nil)      // the program alone, if dropped itself

        let bottle = try store.create(name: "Whole")
        let folder = game.standardizedFileURL.resolvingSymlinksInPath()
        let program = try flow.place(try AddProgram.entry(in: folder), analysis: try ProgramAnalysis.analyze(app),
                                     name: "Old Game", in: bottle, root: folder)
        #expect(program.windowsPath == #"C:\Program Files\Old Game\game.exe"#)
        let placed = bottle.driveC.appending(path: "Program Files/Old Game")
        for f in ["game.exe", "Manual.pdf", "data/levels.pak", "tools/editor.exe"] {
            #expect(fm.fileExists(atPath: placed.appending(path: f).path), "\(f)")
        }
    }
}
