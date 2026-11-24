import Foundation
import Testing
@testable import HarborKit

/// What the launched program's path looks like in Wine's log, which lines are about it, and how much of a log
/// is read (#65).
@Suite struct DiagnosisProgramPathTests {
    let fm = FileManager.default
    let missingVC = #"""
    0128:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Games\\Maze\\maze.exe") not found
    0128:err:module:loader_init Importing dlls for L"C:\\Games\\Maze\\maze.exe" failed, status c0000135
    """#

    /// Wine prints every character outside ASCII as a backslash and four hex digits.
    @Test func aProgramInAFolderWithAnAccentIsRecognised() {
        let log = #"""
        0128:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Program Files\\Pok\00e9mon \65e5\672c\\game.exe") not found
        0128:err:module:loader_init Importing dlls for L"C:\\Program Files\\Pok\00e9mon \65e5\672c\\game.exe" failed, status c0000135
        """#
        #expect(Diagnosis.analyze(log, program: #"C:\Program Files\Pokémon 日本\game.exe"#)?.cause
                == .missingLibrary("MSVCP140.dll", recipe: "vcrun2022"))
        #expect(Diagnosis.analyze(log, program: #"C:\Program Files\Pokemon\game.exe"#) == nil)
    }

    @Test func writesStringsTheWayWinesLogDoes() {
        #expect(Diagnosis.wineDebugString("C:\\a \"b\"\tc\u{1}é") == #"L"C:\\a \"b\"\tc\0001\00e9""#)
        // Characters beyond the 16-bit range are two units.
        #expect(Diagnosis.wineDebugString("😀") == #"L"\d83d\de00""#)
        // A long string is cut once about 290 characters are out; a single character left over is dropped
        // without the dots, as Wine's loop does.
        let a = String(repeating: "a", count: 289)
        #expect(Diagnosis.wineDebugString(a) == "L\"\(a)\"")
        #expect(Diagnosis.wineDebugString(a + "b") == "L\"\(a)\"")
        #expect(Diagnosis.wineDebugString(a + "bc") == "L\"\(a)\"...")
        #expect(Diagnosis.wineDebugString(String(repeating: "é", count: 80)) == "L\"" + String(repeating: #"\00e9"#, count: 58) + "\"...")
    }

    /// A path too long for Wine's buffer is cut in the log; the program is still recognised by what was printed.
    @Test func aVeryLongProgramPathIsRecognisedByItsPrintedPart() {
        let path = #"C:\Games\"# + String(repeating: "deep\\", count: 70) + "game.exe"
        let printed = Diagnosis.wineDebugString(path)
        #expect(printed.hasSuffix("\"..."))
        let log = """
        0128:err:module:import_dll Library HarborMissing.dll (which is needed by \(printed)) not found
        0128:err:module:loader_init Importing dlls for \(printed) failed, status c0000135
        """
        #expect(Diagnosis.analyze(log, program: path)?.cause == .missingLibrary("HarborMissing.dll", recipe: nil))
    }

    /// A helper's missing library earlier in the log isn't the one the program is missing.
    @Test func theLibraryNamedIsTheOneTheProgramItselfNeeds() {
        let log = DiagnosisScopeTests().helper + "\n" + missingVC
        #expect(Diagnosis.analyze(log, program: #"C:\Games\Maze\maze.exe"#)?.cause == .missingLibrary("MSVCP140.dll", recipe: "vcrun2022"))
        // When only one of the program's own libraries is named as needing something, the first line is used.
        let indirect = #"""
        0128:err:module:import_dll Library physx.dll (which is needed by L"C:\\Games\\Maze\\engine.dll") not found
        0128:err:module:loader_init Importing dlls for L"C:\\Games\\Maze\\maze.exe" failed, status c0000135
        """#
        #expect(Diagnosis.analyze(indirect, program: #"C:\Games\Maze\maze.exe"#)?.cause == .missingLibrary("physx.dll", recipe: nil))
    }

    /// A component that is already in the bottle isn't offered again.
    @Test func anInstalledComponentIsNotOfferedAgain() {
        #expect(Diagnosis.analyze(missingVC, installed: { $0.id == "vcrun2022" })?.cause == .missingLibrary("MSVCP140.dll", recipe: nil))
        #expect(Diagnosis.analyze(missingVC, installed: { $0.id == "vcrun2013" })?.cause == .missingLibrary("MSVCP140.dll", recipe: "vcrun2022"))
        // Nor is Microsoft's .NET suggested to a bottle that has it.
        let net = "0024:err:mscoree:CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed"
        #expect(Diagnosis.analyze(net)?.cause == .dotNet)
        #expect(Diagnosis.analyze(net, installed: { $0 == .dotnet48 }) == nil)
    }

    /// The same, read from a bottle: Microsoft's DLL in system32 is what counts as installed.
    @Test func aBottlesInstalledComponentsAreLeftOutOfItsDiagnosis() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-diag-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let b = try BottleStore(directory: base).create(name: "D")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        try missingVC.write(to: b.logsDirectory.appending(path: "20261119-100000-Maze.log"), atomically: true, encoding: .utf8)
        #expect(b.diagnosis(forLatestRunOf: "Maze")?.diagnosis.cause == .missingLibrary("MSVCP140.dll", recipe: "vcrun2022"))
        let system32 = b.driveC.appending(path: "windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try Data("MZ Microsoft".utf8).write(to: system32.appending(path: "msvcp140.dll"))
        #expect(b.diagnosis(forLatestRunOf: "Maze")?.diagnosis.cause == .missingLibrary("MSVCP140.dll", recipe: nil))
    }

    /// A program that prints an error per frame for hours: only the start (where loading fails) and the end
    /// (where a crash is reported) of its log are read.
    @Test func onlyTheStartAndEndOfALargeLogAreRead() throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-diag-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let noise = String(repeating: "0128:err:d3d:frame something went wrong\n", count: 500)
        let crash = "wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger...\n"
        let dll = "0128:err:module:import_dll Library HarborMissing.dll (which is needed by L\"C:\\\\a.exe\") not found\n"
        func text(_ parts: String...) throws -> String {
            let file = base.appending(path: "\(UUID().uuidString).log")
            try parts.joined().write(to: file, atomically: true, encoding: .utf8)
            return Diagnosis.text(ofLog: file, portion: 1000)
        }
        let read = try text(dll, noise, crash)
        #expect(read.utf8.count <= 2001)
        #expect(Diagnosis.analyze(read)?.cause == .missingLibrary("HarborMissing.dll", recipe: nil))
        #expect(Diagnosis.analyze(try text(noise, noise, crash))?.cause == .crashed)
        // What is only in the middle isn't seen; a small log is read whole; a log that isn't there reads as empty.
        #expect(Diagnosis.analyze(try text(noise, crash, noise)) == nil)
        #expect(try text(dll, crash) == dll + crash)
        #expect(Diagnosis.text(ofLog: base.appending(path: "none.log")) == "")
    }
}
