import Foundation
import SystemConfiguration

/// What names this Mac and its user, as it can turn up in a log. `Redaction` takes it out of a report.
public struct MacIdentity: Sendable, Equatable {
    /// The home folder's path, `/Users/anna`.
    public var home: String
    /// The account's short name, `anna`.
    public var userName: String
    /// The account's full name, `Anna Example`.
    public var fullName: String
    /// The Mac's names: on the network (`Annas-MacBook-Pro`, with or without a domain) and in Sharing settings.
    public var hostNames: [String]

    public init(home: String, userName: String, fullName: String, hostNames: [String]) {
        self.home = home
        self.userName = userName
        self.fullName = fullName
        self.hostNames = hostNames
    }

    /// This Mac's. Read from the system's settings store and the kernel, neither of which asks the network
    /// (`ProcessInfo.hostName` and `Host.current()` may look the name up and block for seconds).
    public static var current: MacIdentity {
        var hosts: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { hosts.append(name) }
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { hosts.append(name) }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, 255) == 0 { hosts.append(String(cString: buffer)) }
        return MacIdentity(home: FileManager.default.homeDirectoryForCurrentUser.path, userName: NSUserName(),
                           fullName: NSFullUserName(), hostNames: hosts)
    }
}

/// Takes the Mac's user and its name out of text that is about to be shown for sending (issue #50: "redacted
/// logs"). The Windows user is `harbor` in every bottle and stays.
public enum Redaction {
    // In square brackets, not angle brackets: GitHub drops `<user>` outside a code block as an unknown HTML tag.
    public static let user = "[user]"
    public static let name = "[name]"
    public static let host = "[host]"

    /// A name shorter than this is only replaced as the home folder, never as a word or a path component by
    /// itself: a user called "al" or "n" would take `\n` and every "al" out of a log and say nothing by it.
    public static let shortest = 3

    /// Names that are left alone as words: the Windows user's, which every report has, and the words of the
    /// placeholders themselves (replacing those would also change a text that is already redacted).
    private static let plain: Set<String> = ["harbor", "user", "name", "host"]

    /// `text` without `identity`. From the most specific to the least, so that what is left for the last step
    /// is only the bare name:
    /// 1. the home folder, in every form a log has it: with `/`, with `\` (Wine's `Z:\Users\anna` and
    ///    `\\?\unix\Users\anna`) and with `\\` (Wine prints strings with backslashes doubled, see
    ///    `Diagnosis.wineDebugString`). The folders above it stay, so the path still reads as one;
    /// 2. the Mac's names, the longest first (`Annas-MacBook-Pro.local` before `Annas-MacBook-Pro`);
    /// 3. the full name;
    /// 4. the user name as a folder anywhere else (`/Volumes/Backup/anna/`);
    /// 5. the user name as a word. Not inside one: a user called "max" leaves "maximum" as it is.
    /// Names match in any case, percent-encoded, and escaped the way Wine prints characters outside ASCII.
    /// Running it twice changes nothing more.
    public static func redact(_ text: String, identity: MacIdentity) -> String {
        var out = text
        let separator = #"(?:/|\\{1,2})"#
        let folders = identity.home.split(separator: "/").map(String.init)
        if let last = folders.last {
            let above = folders.dropLast().map { separator + spellings($0) }.joined() + separator
            // Not on drive C:, which is the bottle's: for a Mac user called "harbor", `C:\users\harbor` reads
            // the same as the home folder and is the Windows user's.
            out = replace(#"(?<!C:)(?<!C:\\)"# + "(\(above))\(spellings(last))\(after)", in: out, with: "$1" + user)
        }
        var hosts: [String] = []
        for host in identity.hostNames {
            // `Annas-MacBook-Pro.fritz.box`: whole, as `.local`, and by its first part alone.
            let first = String(host.prefix { $0 != "." })
            hosts += [host, first + ".local", first]
        }
        for host in unique(hosts).sorted(by: { $0.count > $1.count }) where isWord(host) {
            out = replace(before + spellings(host) + after, in: out, with: Self.host)
        }
        if isWord(identity.fullName) {
            out = replace(before + spellings(identity.fullName) + after, in: out, with: name)
        }
        for name in unique([folders.last ?? "", identity.userName]) where isWord(name) {
            out = replace("(\(separator))\(spellings(name))\(after)", in: out, with: "$1" + user)
            out = replace(before + spellings(name) + after, in: out, with: user)
        }
        return out
    }

    /// Not after or before a letter, a digit or `_`.
    private static let before = #"(?<![\p{L}\p{N}_])"#
    private static let after = #"(?![\p{L}\p{N}_])"#

    /// Whether `name` is replaced wherever it stands by itself.
    private static func isWord(_ name: String) -> Bool {
        name.count >= shortest && !plain.contains(name.lowercased())
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A pattern for every way `text` is written in a log: as it is (with an accent as one character or as
    /// two, as file names have it), percent-encoded as in a `file:` link, and as Wine prints it, in a wide
    /// string (`\00fc` per UTF-16 unit) and in a narrow one (`\xc3\xbc` per byte).
    private static func spellings(_ text: String) -> String {
        var all: [String] = []
        for form in [text, text.precomposedStringWithCanonicalMapping, text.decomposedStringWithCanonicalMapping] {
            all.append(form)
            if let encoded = form.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { all.append(encoded) }
            all.append(String(Diagnosis.wineDebugString(form).dropFirst(2).dropLast()))
            all.append(form.utf8.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined())
        }
        // The longest first: an alternation takes the first that matches, and a shorter spelling can start a longer.
        // (Not made unique: to Swift the one-character and the two-character accent are the same string.)
        let patterns = all.sorted { $0.utf16.count > $1.utf16.count }.map(NSRegularExpression.escapedPattern(for:))
        return "(?:" + patterns.joined(separator: "|") + ")"
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
