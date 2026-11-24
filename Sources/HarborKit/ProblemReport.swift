import Foundation

/// A problem report: plain text the user reads, changes and then submits themselves as an issue on GitHub
/// (issue #50). Harbor sends nothing; it opens the browser with the text filled in.
public struct ProblemReport: Sendable, Equatable {
    /// What is reported, which decides the issue template (`.github/ISSUE_TEMPLATE/`).
    public enum Kind: Sendable, Equatable, CaseIterable {
        case program
        case harbor

        /// The template's file name. With a Markdown template GitHub takes the labels from the template and
        /// the text from the link; an issue form (YAML) ignores `body` and wants one parameter per field.
        public var template: String {
            switch self {
            case .program: "program.md"
            case .harbor: "bug.md"
            }
        }
    }

    /// What a report says about the Mac and what is installed. No more than this: nothing here tells one Mac
    /// from another of its kind.
    public struct Versions: Sendable, Equatable {
        /// Harbor's version and build, `1.2 (34)`.
        public var harbor: String
        /// The installed Windows support and its graphics layers; nil when none is installed.
        public var windowsSupport: String?
        public var macOS: String
        /// The chip's name, `Apple M3 Pro`.
        public var chip: String

        public init(harbor: String, windowsSupport: String?, macOS: String, chip: String) {
            self.harbor = harbor
            self.windowsSupport = windowsSupport
            self.macOS = macOS
            self.chip = chip
        }

        /// With this Mac's macOS version and chip.
        public static func onThisMac(harbor: String, windowsSupport: String?) -> Versions {
            var size = 0
            sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
            var name = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
            let chip = String(cString: name)
            return Versions(harbor: harbor, windowsSupport: windowsSupport,
                            macOS: ProcessInfo.processInfo.operatingSystemVersionString, chip: chip.isEmpty ? "unknown" : chip)
        }
    }

    public var kind: Kind
    public var versions: Versions
    /// The program's name. Not part of a report unless the user puts it there (they can, in the text).
    public var program: String?
    public var diagnosis: Diagnosis?
    /// How the program ended.
    public var exit: WineExit?
    /// The end of the launch's log (`endOfLog`), as Wine wrote it. `text` redacts it.
    public var log: String?
    /// What macOS recorded when Harbor itself crashed (`CrashReport.summary`). `text` redacts it.
    public var crash: String?

    public init(kind: Kind, versions: Versions, program: String? = nil, diagnosis: Diagnosis? = nil, exit: WineExit? = nil,
                log: String? = nil) {
        self.kind = kind
        self.versions = versions
        self.program = program
        self.diagnosis = diagnosis
        self.exit = exit
        self.log = log
    }

    /// The issue's title. Names the cause, never the program.
    public var title: String {
        guard kind == .program else { return crash == nil ? "" : "Harbor quit unexpectedly" }
        switch diagnosis?.cause {
        case .missingLibrary(let dll, _): return "A program doesn’t run: \(dll) is missing"
        case .dotNet: return "A .NET program doesn’t run"
        case .shaderCompiler: return "A program doesn’t run: its shaders don’t compile"
        case .antiCheat(let name): return "A program doesn’t run: \(name) anti-cheat"
        case .crashed: return "A program crashes"
        case nil: return "A program doesn’t run"
        }
    }

    /// The whole report, without anything that names the Mac or its user: what comes out of the log (its end,
    /// and the cause, which quotes a file name from it) goes through `Redaction`. The versions don't: they are
    /// Harbor's own words and Apple's, and a user called "max" would lose the chip's name, "Apple M3 Max".
    /// Markdown, as GitHub shows an issue; the log is in a code block, where nothing in it is read as formatting.
    public func text(identity: MacIdentity) -> String {
        var lines = ["### What happened", "", "(Write here what you did and what went wrong.)", "", "### Details", ""]
        if kind == .program {
            lines.append("- Program: \(program ?? "(not named. Write its name here if you’d like it looked at.)")")
        }
        lines += ["- Harbor: \(versions.harbor)",
                  "- Windows support: \(versions.windowsSupport ?? "not installed")",
                  "- macOS: \(versions.macOS)",
                  "- Chip: \(versions.chip)"]
        if let diagnosis {
            lines.append("- Cause: " + Redaction.redact(diagnosis.message(for: program ?? "The program"), identity: identity))
        }
        if let exit { lines.append("- Exit status: \(exit.signalled ? "ended by signal \(exit.status)" : String(exit.status))") }
        if let log {
            let end = log.trimmingCharacters(in: .newlines)
            lines += ["", "### End of the log", "", "```", end.isEmpty ? "(the log is empty)" : Redaction.redact(end, identity: identity), "```"]
        }
        if let crash {
            lines += ["", "### What macOS recorded", "", "```", Redaction.redact(crash, identity: identity), "```"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last lines of a log, read lossily like `Diagnosis.text(ofLog:)`. 40 lines or 4,000 bytes, whichever is
    /// less: with the rest of a report that usually still fits into a link to GitHub (`linkLimit`), so the report
    /// arrives in the browser whole and nothing has to be pasted. What stopped a program is at the end of its log
    /// (a library that isn't found, Wine's "Unhandled exception" line), and the whole log stays in the bottle
    /// for whoever asks for it.
    public static func endOfLog(_ log: URL, lines: Int = 40, bytes: Int = 4_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let cut = size > UInt64(bytes)
        guard (try? handle.seek(toOffset: cut ? size - UInt64(bytes) : 0)) != nil else { return "" }
        var all = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // The first line of a cut is the rest of one.
        if cut, all.count > 1 { all.removeFirst() }
        while all.last?.isEmpty == true { all.removeLast() }
        return all.suffix(lines).joined(separator: "\n")
    }

    // MARK: The link

    public static let newIssue = "https://github.com/maxweilbuchner/harbor/issues/new"

    /// The longest link Harbor hands to the browser, in characters after percent-encoding. GitHub answers a
    /// longer one with "414 URI Too Long" and documents no number ("a URL that exceeds the server limit",
    /// docs.github.com, "Creating an issue from a URL query"); in practice the limit is near 8 KB. 7,500 is
    /// what Visual Studio Code's issue reporter allows itself for the same kind of link before it falls back
    /// to the clipboard. Safari, Chrome and Firefox all take far longer ones.
    public static let linkLimit = 7_500

    /// What stands in a shortened text where lines were left out.
    public static let shortenedNote = "[… shortened to fit a link. The whole text is on the clipboard: paste it over this …]"

    /// The link that opens a new issue with `title` and `body` filled in, and whether `body` had to be shortened
    /// for it (`shortened`). The caller then puts the whole text on the clipboard.
    public static func issueLink(kind: Kind, title: String, body: String, limit: Int = linkLimit) -> (url: URL, shortened: Bool) {
        let start = newIssue + "?template=" + encoded(kind.template) + "&title=" + encoded(title) + "&body="
        var text = encoded(body)
        let fits = start.count + text.count <= limit
        if !fits { text = encoded(shortened(body, toEncodedLength: limit - start.count)) }
        // Only unreserved characters and percent escapes are left, so this is a URL.
        return (URL(string: start + text)!, !fits)
    }

    /// `body` with lines left out of its middle until it is at most `length` characters long when
    /// percent-encoded: the start (what the user wrote, the versions, the cause) gets half, the end (the last
    /// lines of the log) the other half, and whichever needs less leaves its rest to the other.
    static func shortened(_ body: String, toEncodedLength length: Int) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cost = lines.map { encoded($0 + "\n").count }
        let room = length - encoded("\n" + shortenedNote + "\n").count
        var head = 0, tail = 0, used = 0
        while head < lines.count, used + cost[head] <= room / 2 { used += cost[head]; head += 1 }
        while head + tail < lines.count, used + cost[lines.count - 1 - tail] <= room { used += cost[lines.count - 1 - tail]; tail += 1 }
        while head + tail < lines.count, used + cost[head] <= room { used += cost[head]; head += 1 }
        return (lines.prefix(head) + [shortenedNote] + lines.suffix(tail)).joined(separator: "\n")
    }

    /// Percent-encoded for a query value. Everything but letters, digits and `-._~`: `+` would arrive as a
    /// space and `&` would end the value.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
