import Foundation
import Testing
@testable import HarborKit

/// What a problem report carries of a crash of Harbor itself (#50). The fixture is a report macOS wrote (a
/// stand-in program named Harbor that ran off the end of an array), with its identifiers and paths replaced.
@Suite struct CrashReportTests {
    let fm = FileManager.default
    var fixture: URL { Bundle.module.url(forResource: "Harbor-crash", withExtension: "ips")! }

    @Test func theSummarySaysWhatStoppedItAndWhere() throws {
        let summary = try #require(CrashReport.summary(of: fixture))
        #expect(summary.contains("Version: 0.1.7 (210)") && summary.contains("macOS: macOS 27.3"))
        #expect(summary.contains("Exception: EXC_BREAKPOINT (SIGTRAP)") && summary.contains("Ended by: Trace/BPT trap: 5"))
        #expect(summary.contains("Crashed thread") && summary.contains("  0  Harbor  main + 0"))
    }

    @Test func nothingThatNamesTheMacOrTheIncidentIsInIt() throws {
        let summary = try #require(CrashReport.summary(of: fixture))
        // The report's own identifiers, the user's ID and every path stay behind.
        for secret in ["00000000-0000-0000-0000", "jane", "/Users/", "501", "crashReporterKey", "incident"] {
            #expect(!summary.contains(secret), "\(secret)")
        }
        // In a problem report it is redacted like a log, should a name turn up in a function's name.
        var report = ProblemReport(kind: .harbor, versions: .init(harbor: "0.1.7 (210)", windowsSupport: nil, macOS: "27.3", chip: "Apple M4"))
        report.crash = summary + "\n  9  Harbor  /Users/jane/thing + 4"
        let identity = MacIdentity(home: "/Users/jane", userName: "jane", fullName: "Jane Example", hostNames: ["janes-mac"])
        let text = report.text(identity: identity)
        #expect(report.title == "Harbor quit unexpectedly")
        #expect(text.contains("### What macOS recorded") && text.contains("EXC_BREAKPOINT") && !text.contains("jane"))
    }

    @Test func onlyAReportOfHarborWrittenSinceTheLastStartIsFound() throws {
        let folder = fm.temporaryDirectory.appending(path: "harbor-crash-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let now = Date()
        for (name, age) in [("Harbor-2026-11-20-101010.ips", 5000.0), ("Harbor-2026-11-24-090000.ips", 100), ("Harbor-2026-11-24-100000.ips", 50),
                            ("harbor-cli-2026-11-24-110000.ips", 10), ("HarborHelper-2026-11-24-110000.ips", 10), ("Harbor-2026-11-24-110000.diag", 10)] {
            let file = folder.appending(path: name)
            try Data().write(to: file)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        #expect(CrashReport.latest(in: folder, after: now.addingTimeInterval(-1000))?.lastPathComponent == "Harbor-2026-11-24-100000.ips")
        #expect(CrashReport.latest(in: folder, after: now.addingTimeInterval(-20)) == nil)
        #expect(CrashReport.latest(in: folder.appending(path: "missing"), after: .distantPast) == nil)
        // A file that isn't a report gives no summary.
        #expect(CrashReport.summary(of: folder.appending(path: "Harbor-2026-11-24-100000.ips")) == nil)
    }
}
