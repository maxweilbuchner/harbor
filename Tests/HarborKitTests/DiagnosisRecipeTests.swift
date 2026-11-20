import Foundation
import Testing
@testable import HarborKit

@Suite struct DiagnosisMisfireTests {
    let fm = FileManager.default
    let missing = #"01cc:err:module:import_dll Library HarborMissing.dll (which is needed by L"Z:\\tmp\\diag\\needsdll.exe") not found"#
    let crash = "wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger..."

    func bottle() throws -> Bottle {
        let b = try BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-diag-\(UUID().uuidString)")).create(name: "D")
        try fm.createDirectory(at: b.logsDirectory, withIntermediateDirectories: true)
        return b
    }

    @Test func aGameFolderCalledVanguardIsNotAntiCheat() {
        let log = #"""
        0128:err:module:loader_init Importing dlls for L"C:\\Games\\Call of Duty Vanguard\\Vanguard.exe" failed, status c0000135
        wine: Unhandled page fault on read access to 0000000000000000 at address 000000014000149C (thread 00e0), starting debugger...
        00e8:fixme:dbghelp_dwarf:dwarf2_load_one_entry Unhandled Tag type 0xa in ctx(0000000004812080,L"C:\\Games\\Call of Duty Vanguard\\Vanguard.exe")
        00e8:err:seh:dispatch_exception easyanticheat and battleye mentioned outside a module load
        """#
        #expect(Diagnosis.analyze(log)?.cause == .crashed)
    }

    @Test func antiCheatIsStillRecognisedWhereItsModulesLoad() {
        #expect(Diagnosis.analyze(#"0120:err:module:load_dll failed to load L"C:\\Program Files\\Riot Vanguard\\vgk.sys""# + "\n" + crash)?.cause
                == .antiCheat("Riot Vanguard"))
        #expect(Diagnosis.analyze(#"0044:err:winedevice:async_create_driver failed to create driver L"BEService": c0000135"#)?.cause
                == .antiCheat("BattlEye"))
        #expect(Diagnosis.analyze(#"0044:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\EasyAntiCheat": c0000135"#)?.cause
                == .antiCheat("Easy Anti-Cheat"))
    }

    @Test func missingLibraryNamesKeepTheirSpaces() {
        let log = missing.replacingOccurrences(of: "HarborMissing.dll", with: "My Lib.dll")
        #expect(Diagnosis.analyze(log) == Diagnosis(cause: .missingLibrary("My Lib.dll", recipe: nil)))
    }

    @Test func aLogThatIsNotUTF8IsStillDiagnosed() throws {
        let b = try bottle()
        let log = b.logsDirectory.appending(path: "20261119-100000-Quest.log")
        try (Data("Gr".utf8) + Data([0xFC, 0xDF, 0x65, 0x0A]) + Data(missing.utf8) + Data([0x0A, 0xFF])).write(to: log)
        #expect(throws: (any Error).self) { try String(contentsOf: log, encoding: .utf8) }
        let found = try #require(b.diagnosis(forLatestRunOf: "Quest"))
        #expect(found.diagnosis.cause == .missingLibrary("HarborMissing.dll", recipe: nil))
        #expect(found.log.lastPathComponent == log.lastPathComponent)
        #expect(b.diagnosis(forLatestRunOf: "Other") == nil)
    }

    @Test func aProgramsLogIsNotMistakenForItsNumberedSiblings() throws {
        let b = try bottle()
        for name in ["20261119-100000-Foo.log", "20261119-110000-Foo-2.log", "20261119-120000-Foo-2-3.log"] {
            try Data().write(to: b.logsDirectory.appending(path: name))
        }
        #expect(b.latestLog(label: "Foo")?.lastPathComponent == "20261119-100000-Foo.log")
        #expect(b.latestLog(label: "Foo 2")?.lastPathComponent == "20261119-110000-Foo-2.log")
        #expect(b.latestLog(label: "Foo-2 3")?.lastPathComponent == "20261119-120000-Foo-2-3.log")
        // A second run within the same second is counted before the label and is the newer one.
        try Data().write(to: b.logsDirectory.appending(path: "20261119-100000.2-Foo.log"))
        #expect(b.latestLog(label: "Foo")?.lastPathComponent == "20261119-100000.2-Foo.log")
        #expect(b.logs().first?.lastPathComponent == "20261119-120000-Foo-2-3.log")
    }

    @Test func runsInTheSameSecondGetLogsThatStayWithTheirProgram() throws {
        let b = try bottle()
        for (label, text) in [("Foo", "first"), ("Foo 2", "sibling"), ("Foo", "second"), ("Foo 2", "sibling again")] {
            let handle = try b.newLog(label: label)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        #expect(b.logs().count == 4)
        #expect(try String(contentsOf: #require(b.latestLog(label: "Foo")), encoding: .utf8) == "second")
        #expect(try String(contentsOf: #require(b.latestLog(label: "Foo 2")), encoding: .utf8) == "sibling again")
    }
}
