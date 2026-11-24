import Foundation
import Testing
@testable import HarborKit

/// The text of a problem report and the link that opens it as a new issue on GitHub (#50).
@Suite struct ProblemReportTests {
    let identity = MacIdentity(home: "/Users/max", userName: "max", fullName: "Max Müller", hostNames: ["Maxs-MacBook-Pro"])
    let versions = ProblemReport.Versions(harbor: "1.2 (34)", windowsSupport: "11.0 (D3DMetal 3.0, DXMT 0.60)",
                                          macOS: "Version 26.1 (Build 25B78)", chip: "Apple M3 Max")
    let missing = Diagnosis(cause: .missingLibrary("MSVCP140.dll", recipe: nil))
    let log = #"0118:err:module:import_dll Library MSVCP140.dll (which is needed by L"Z:\\Users\\max\\Games\\Quest\\quest.exe") not found"#

    // MARK: The text

    @Test func aProgramsReportHasVersionsCauseStatusAndLog() {
        let report = ProblemReport(kind: .program, versions: versions, diagnosis: missing, exit: WineExit(status: 53), log: log + "\n")
        let text = report.text(identity: identity)
        #expect(text.contains("- Harbor: 1.2 (34)\n"))
        #expect(text.contains("- Windows support: 11.0 (D3DMetal 3.0, DXMT 0.60)\n"))
        #expect(text.contains("- macOS: Version 26.1 (Build 25B78)\n"))
        // The user is called "max"; the chip keeps its name.
        #expect(text.contains("- Chip: Apple M3 Max\n"))
        #expect(text.contains("- Cause: The program is missing a file it needs (MSVCP140.dll)."))
        #expect(text.contains("- Exit status: 53\n"))
        #expect(text.contains(#"(which is needed by L"Z:\\Users\\[user]\\Games\\Quest\\quest.exe") not found"# + "\n```\n"))
        #expect(!text.contains(#"\\max"#))
        #expect(report.title == "A program doesn’t run: MSVCP140.dll is missing")
    }

    @Test func theProgramIsNotNamedUnlessGiven() {
        var report = ProblemReport(kind: .program, versions: versions, diagnosis: Diagnosis(cause: .crashed), exit: WineExit(status: 11, signalled: true))
        var text = report.text(identity: identity)
        #expect(text.contains("- Program: (not named."))
        #expect(text.contains("- Cause: The program crashed."))
        #expect(text.contains("- Exit status: ended by signal 11\n"))
        #expect(!text.contains("End of the log"))
        report.program = "Quest 2"
        text = report.text(identity: identity)
        #expect(text.contains("- Program: Quest 2\n"))
        #expect(text.contains("- Cause: Quest 2 crashed."))
        // The title never names it.
        #expect(report.title == "A program crashes")
    }

    @Test func aReportAboutHarborHasVersionsOnly() {
        let text = ProblemReport(kind: .harbor, versions: ProblemReport.Versions(harbor: "1.2 (34)", windowsSupport: nil, macOS: "26.1", chip: "Apple M3"))
            .text(identity: identity)
        #expect(text.contains("### What happened"))
        #expect(text.contains("- Windows support: not installed\n"))
        #expect(!text.contains("Program") && !text.contains("Cause") && !text.contains("Exit status") && !text.contains("log"))
    }

    @Test func thisMacsVersionsAreFilledIn() {
        let versions = ProblemReport.Versions.onThisMac(harbor: "1.2", windowsSupport: nil)
        #expect(!versions.macOS.isEmpty && !versions.chip.isEmpty)
    }

    // MARK: The end of the log

    @Test func theEndOfALogIsItsLastLines() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "harbor-report-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1...100).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let end = ProblemReport.endOfLog(file).split(separator: "\n")
        #expect(end.count == 40)
        #expect(end.first == "line 61" && end.last == "line 100")
        // Long lines: no more than the bytes allowed, and no line that starts in its middle.
        try (1...100).map { "\($0) " + String(repeating: "x", count: 300) }.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        let long = ProblemReport.endOfLog(file)
        #expect(long.utf8.count <= 4_000)
        #expect(long.hasPrefix("88 x") && long.hasSuffix("x"))
        #expect(long.split(separator: "\n").allSatisfy { $0.count > 300 })
        #expect(ProblemReport.endOfLog(file.appendingPathExtension("none")) == "")
    }

    // MARK: The link

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func theLinkOpensANewIssueWithTheTextFilledIn() {
        let body = "### What happened\n\n1 + 1 = 3 & \"Müller\" #50 100%\n"
        let link = ProblemReport.issueLink(kind: .program, title: "A program doesn’t run", body: body)
        #expect(!link.shortened)
        #expect(link.url.absoluteString.hasPrefix("https://github.com/maxweilbuchner/harbor/issues/new?template=program.md&title="))
        #expect(link.url.absoluteString.count <= ProblemReport.linkLimit)
        // Nothing a server reads as something else: `+` as a space, `&` as the end of the value.
        let encoded = link.url.absoluteString.split(separator: "?", maxSplits: 1)[1]
        #expect(encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%&=".contains($0)) })
        #expect(encoded.filter { $0 == "&" }.count == 2)
        #expect(query(link.url) == ["template": "program.md", "title": "A program doesn’t run", "body": body])
        #expect(query(ProblemReport.issueLink(kind: .harbor, title: "", body: "x").url) == ["template": "bug.md", "title": "", "body": "x"])
    }

    /// The link names the templates by their files: each is there, and is a Markdown template (an issue form
    /// would ignore `body`).
    @Test func everyKindHasItsTemplate() throws {
        for kind in ProblemReport.Kind.allCases {
            let file = WineRuntime.checkoutRoot.appending(path: ".github/ISSUE_TEMPLATE/\(kind.template)")
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(kind.template.hasSuffix(".md"))
            #expect(text.hasPrefix("---\nname: "))
        }
    }

    @Test func aRealReportFitsTheLinkWhole() {
        // 40 lines as Wine writes them, the most `endOfLog` hands on.
        let report = ProblemReport(kind: .program, versions: versions, diagnosis: missing, exit: WineExit(status: 53),
                                   log: Array(repeating: log, count: 40).joined(separator: "\n"))
        let link = ProblemReport.issueLink(kind: .program, title: report.title, body: report.text(identity: identity))
        #expect(link.url.absoluteString.count <= ProblemReport.linkLimit)
    }

    @Test func aTextTooLongForALinkKeepsItsStartAndItsEnd() {
        let lines = ["### What happened", "It stopped."] + (1...400).map { "0118:fixme:d3d: line \($0) \\\\ \"quoted\"" } + ["```"]
        let body = lines.joined(separator: "\n")
        let link = ProblemReport.issueLink(kind: .program, title: "A program crashes", body: body)
        #expect(link.shortened)
        #expect(link.url.absoluteString.count <= ProblemReport.linkLimit)
        // Not much is given away either: most of the room is used.
        #expect(link.url.absoluteString.count > ProblemReport.linkLimit - 200)
        let sent = (query(link.url)["body"] ?? "").split(separator: "\n").map(String.init)
        #expect(sent.prefix(3) == ["### What happened", "It stopped.", lines[2]])
        #expect(sent.suffix(2) == [lines[401], "```"])
        #expect(sent.filter { $0 == ProblemReport.shortenedNote }.count == 1)
        // What is left is whole lines of the text, in order, around the note.
        let note = sent.firstIndex(of: ProblemReport.shortenedNote)!
        #expect(Array(sent[..<note]) == Array(lines.prefix(note)))
        #expect(Array(sent[(note + 1)...]) == Array(lines.suffix(sent.count - note - 1)))
        #expect(note > 10 && sent.count - note > 10)
    }

    @Test func aTextWithoutLineBreaksIsStillUnderTheLimit() {
        let link = ProblemReport.issueLink(kind: .harbor, title: "", body: String(repeating: "word ", count: 5_000))
        #expect(link.shortened)
        #expect(link.url.absoluteString.count <= ProblemReport.linkLimit)
        #expect(query(link.url)["body"] == ProblemReport.shortenedNote)
    }
}
