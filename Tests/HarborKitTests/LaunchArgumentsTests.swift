import Foundation
import Testing
@testable import HarborKit

/// What `WineLauncher.launch` hands to Wine for a library program (#85).
@Suite struct LaunchArgumentsTests {
    let fm = FileManager.default

    /// Launches `program`, whose file is put at `file` on drive C:, with a "wine" that writes down its arguments,
    /// and returns them.
    func arguments(launching program: Program, at file: String) async throws -> [String] {
        let f = try LaunchExitTests().fixture(wine: #"for a in "$@"; do printf '%s\n' "$a"; done > "$0.args""#)
        defer { try? fm.removeItem(at: f.base) }
        let exe = f.bottle.driveC.appending(path: file)
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        let _: WineExit = try await withCheckedThrowingContinuation { done in
            do { try f.launcher.launch(program, in: f.bottle) { done.resume(returning: $0) } } catch { done.resume(throwing: error) }
        }
        let written = try String(contentsOf: f.launcher.runtime.wine.appendingPathExtension("args"), encoding: .utf8)
        // The program's place on the Mac is the fixture's; what matters is that it is the file, after `/unix`
        // (spelt as the library entry spells it, where the disk doesn't tell upper from lower case).
        return written.split(separator: "\n").map { $0.lowercased() == exe.path.lowercased() ? "<file>" : String($0) }
    }

    @Test func aProgramIsStartedByItsFileAndWaitedFor() async throws {
        let program = Program(name: "Game", windowsPath: #"C:\Games\Thing\Game.exe"#)
        #expect(try await arguments(launching: program, at: "Games/Thing/Game.exe") == ["start", "/wait", "/unix", "<file>"])
    }

    /// The folder to start in comes before the file (it is `start`'s option), the user's arguments after it:
    /// split like a Windows command line, quotes gone, backslashes kept.
    @Test func theStartFolderComesBeforeTheFileAndTheUsersArgumentsAfterIt() async throws {
        let program = Program(name: "Game", windowsPath: #"C:\Games\Thing\Game.exe"#,
                              arguments: #"-windowed  -name "Max Power" -saves C:\Saves\"#, workingDirectory: #"C:\Games\Thing\Data"#)
        #expect(try await arguments(launching: program, at: "Games/Thing/Game.exe")
                == ["start", "/wait", "/d", #"C:\Games\Thing\Data"#, "/unix", "<file>", "-windowed", "-name", "Max Power", "-saves", #"C:\Saves\"#])
        // Arguments that are only spaces are none.
        let blank = Program(name: "Game", windowsPath: #"C:\Games\Thing\Game.exe"#, arguments: "  ")
        #expect(try await arguments(launching: blank, at: "Games/Thing/Game.exe") == ["start", "/wait", "/unix", "<file>"])
    }

    /// What a program needs under Wine is added after the user's own arguments, by the file's name whatever
    /// its case, and not a second time when the user gave it already.
    @Test func knownArgumentsAreAddedOnce() async throws {
        let steam = "Program Files (x86)/Steam/Steam.exe"
        var program = Program(name: "Steam", windowsPath: #"c:\program files (x86)\steam\STEAM.EXE"#)
        #expect(try await arguments(launching: program, at: steam) == ["start", "/wait", "/unix", "<file>", "-cef-disable-gpu"])
        program.arguments = "-silent"
        #expect(try await arguments(launching: program, at: steam) == ["start", "/wait", "/unix", "<file>", "-silent", "-cef-disable-gpu"])
        program.arguments = "-cef-disable-gpu -silent"
        #expect(try await arguments(launching: program, at: steam) == ["start", "/wait", "/unix", "<file>", "-cef-disable-gpu", "-silent"])
        // Another program of that name's beginning gets nothing added.
        let other = Program(name: "Steam Helper", windowsPath: #"C:\Games\steamhelper.exe"#, arguments: "-silent")
        #expect(try await arguments(launching: other, at: "Games/steamhelper.exe") == ["start", "/wait", "/unix", "<file>", "-silent"])
    }

    /// A program whose file is gone, or lies outside drive C:, isn't handed to Wine at all.
    @Test func aProgramWithoutItsFileIsNotStarted() throws {
        let f = try LaunchExitTests().fixture(wine: #"touch "$0.started""#)
        defer { try? fm.removeItem(at: f.base) }
        try fm.createDirectory(at: f.bottle.driveC.appending(path: "Games"), withIntermediateDirectories: true)
        for path in [#"C:\Games\Gone.exe"#, #"C:\Games\..\..\..\wine\bin\wine"#, #"Z:\bin\ls"#] {
            #expect(throws: CocoaError.self, "\(path)") { try f.launcher.launch(Program(name: "Gone", windowsPath: path), in: f.bottle) }
        }
        #expect(!fm.fileExists(atPath: f.launcher.runtime.wine.appendingPathExtension("started").path))
        #expect(f.bottle.logs().isEmpty)
    }
}
