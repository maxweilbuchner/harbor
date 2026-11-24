import Foundation
import Testing
@testable import HarborKit

/// What names the Mac and its user is out of a text before it is shown for sending (#50). Every identity here is
/// made up and handed in: the tests never read this Mac's.
@Suite struct RedactionTests {
    let max = MacIdentity(home: "/Users/max", userName: "max", fullName: "Max Müller",
                          hostNames: ["Maxs-MacBook-Pro", "Max’s MacBook Pro", "Maxs-MacBook-Pro.fritz.box"])
    let anna = MacIdentity(home: "/Users/anna", userName: "anna", fullName: "Anna Example", hostNames: ["Annas-iMac"])

    func redact(_ text: String) -> String { Redaction.redact(text, identity: max) }

    // MARK: The home folder

    @Test func theHomeFolderInAMacPath() {
        #expect(redact("/Users/max/Games/setup.exe") == "/Users/[user]/Games/setup.exe")
        #expect(redact("open /Users/max") == "open /Users/[user]")
        #expect(redact("/System/Volumes/Data/Users/max/Library") == "/System/Volumes/Data/Users/[user]/Library")
        #expect(redact("/USERS/MAX/games") == "/USERS/[user]/games")
        #expect(redact("file:///Users/max/My%20Games/") == "file:///Users/[user]/My%20Games/")
    }

    @Test func theHomeFolderAsWineWritesIt() {
        #expect(redact(#"Z:\Users\max\Games\setup.exe"#) == #"Z:\Users\[user]\Games\setup.exe"#)
        #expect(redact(#"\\?\unix\Users\max\Games"#) == #"\\?\unix\Users\[user]\Games"#)
        // In a log, a string's backslashes are doubled.
        #expect(redact(#"L"Z:\\Users\\max\\Games\\setup.exe""#) == #"L"Z:\\Users\\[user]\\Games\\setup.exe""#)
        #expect(redact(#"L"\\\\?\\unix\\Users\\max\\Games""#) == #"L"\\\\?\\unix\\Users\\[user]\\Games""#)
        #expect(redact(Diagnosis.wineDebugString(#"Z:\Users\max\a.exe"#)) == #"L"Z:\\Users\\[user]\\a.exe""#)
    }

    @Test func aHomeFolderElsewhereAndWithAnAccent() {
        let identity = MacIdentity(home: "/Volumes/Daten/Benutzer/jörg", userName: "joerg", fullName: "", hostNames: [])
        func redact(_ text: String) -> String { Redaction.redact(text, identity: identity) }
        #expect(redact("/Volumes/Daten/Benutzer/jörg/x") == "/Volumes/Daten/Benutzer/[user]/x")
        // As two characters (o and the dots), the way file names are stored.
        #expect(redact("/Volumes/Daten/Benutzer/jo\u{308}rg/x") == "/Volumes/Daten/Benutzer/[user]/x")
        #expect(redact("file:///Volumes/Daten/Benutzer/j%C3%B6rg/x") == "file:///Volumes/Daten/Benutzer/[user]/x")
        // Wine, in a wide string and in a narrow one.
        #expect(redact(#"L"Z:\\Volumes\\Daten\\Benutzer\\j\00f6rg\\x""#) == #"L"Z:\\Volumes\\Daten\\Benutzer\\[user]\\x""#)
        #expect(redact(#""/Volumes/Daten/Benutzer/j\xc3\xb6rg/x""#) == #""/Volumes/Daten/Benutzer/[user]/x""#)
        #expect(redact("started by joerg, in /tmp/joerg/x") == "started by [user], in /tmp/[user]/x")
    }

    @Test func anotherUsersFolderIsNotCutInTwo() {
        #expect(redact("/Users/maxine/Games") == "/Users/maxine/Games")
        #expect(redact("/Users/max2/Games") == "/Users/max2/Games")
    }

    // MARK: The name

    /// A name that is part of a common word: only where it stands by itself.
    @Test func theUserNameOnlyAsAWord() {
        #expect(redact("maximum texture size 16384, MAX_PATH, climax, max2") == "maximum texture size 16384, MAX_PATH, climax, max2")
        #expect(redact("owner=max uid=501") == "owner=[user] uid=501")
        #expect(redact("Max logged in; MAX; (max)") == "[user] logged in; [user]; ([user])")
        #expect(redact("/Volumes/Backup/max/Games") == "/Volumes/Backup/[user]/Games")
    }

    @Test func theFullName() {
        #expect(redact("registered to Max Müller.") == "registered to [name].")
        #expect(redact("registered to max müller") == "registered to [name]")
        #expect(redact(#"L"Max M\00fcller""#) == #"L"[name]""#)
        #expect(redact("Max%20M%C3%BCller") == "[name]")
    }

    @Test func theMacsNames() {
        #expect(redact("host Maxs-MacBook-Pro.local up") == "host [host] up")
        #expect(redact("host maxs-macbook-pro up") == "host [host] up")
        #expect(redact("host Maxs-MacBook-Pro.fritz.box up") == "host [host] up")
        #expect(redact("computer \"Max’s MacBook Pro\"") == "computer \"[host]\"")
    }

    /// Two letters turn up everywhere: such a name goes with the home folder and is otherwise left.
    @Test func aNameTooShortToReplaceAsAWord() {
        let identity = MacIdentity(home: "/Users/al", userName: "al", fullName: "Al", hostNames: ["al"])
        let text = #"Z:\Users\al\x.exe: al dente, C:\al\x, /Users/al"#
        #expect(Redaction.redact(text, identity: identity) == #"Z:\Users\[user]\x.exe: al dente, C:\al\x, /Users/[user]"#)
    }

    @Test func theWindowsUserStays() {
        let line = #"L"C:\\users\\harbor\\AppData\\Roaming\\x.ini""#
        #expect(redact(line) == line)
        // Also on a Mac whose user is called the same; the home folder still goes.
        let identity = MacIdentity(home: "/Users/harbor", userName: "harbor", fullName: "Harbor", hostNames: [])
        #expect(Redaction.redact(line + " /Users/harbor/x Harbor 1.0", identity: identity) == line + " /Users/[user]/x Harbor 1.0")
    }

    // MARK: A whole log

    /// What a launch from the Mac's Downloads folder writes, with the name in every form above.
    static let log = #"""
        wineserver: using server-side synchronization.
        0024:err:environ:run_wineboot boot event wait timed out
        0118:trace:file:NtCreateFile handle=0x7ffe1234 L"\\??\\Z:\\Users\\anna\\Downloads\\Setup.exe"
        0118:trace:file:nt_to_unix_file_name L"\\??\\unix\\Users\\anna\\Library\\Application Support\\Harbor\\Bottles\\1\\drive_c" -> "/Users/anna/Library/Application Support/Harbor/Bottles/1/drive_c"
        0118:fixme:shell:SHGetKnownFolderPath L"C:\\users\\harbor\\Documents"
        0118:trace:winsock:gethostname returning "Annas-iMac.local"
        0118:trace:advapi:GetUserNameW returning L"harbor" (unix user anna, ANNA EXAMPLE)
        0118:err:module:import_dll Library MSVCP140.dll (which is needed by L"Z:\\Users\\anna\\Downloads\\Setup.exe") not found
        0118:err:module:loader_init Importing dlls for L"Z:\\Users\\anna\\Downloads\\Setup.exe" failed, status c0000135
        0118:trace:file:open file:///Users/anna/Downloads/read%20me.txt for Anna Example on annas-imac
        0118:fixme:d3d:wined3d_guess_card No card selector available, max texture size 16384, savannah mode
        """#

    @Test func nothingOfTheNameIsLeftInALog() {
        let out = Redaction.redact(Self.log, identity: anna)
        // "savannah" has the name inside a word and stays; nothing else has it.
        #expect(!out.lowercased().replacingOccurrences(of: "savannah", with: "").contains("anna"))
        #expect(!out.lowercased().contains("imac"))
        #expect(!out.lowercased().contains("example"))
        #expect(out.contains(#"L"\\??\\Z:\\Users\\[user]\\Downloads\\Setup.exe""#))
        #expect(out.contains(#""/Users/[user]/Library/Application Support/Harbor/Bottles/1/drive_c""#))
        #expect(out.contains(#"returning "[host]""#))
        #expect(out.contains(#"L"C:\\users\\harbor\\Documents""#))
        #expect(out.contains("(unix user [user], [name])"))
        #expect(out.contains("for [name] on [host]"))
        // The lines a diagnosis is read from still say what they said.
        #expect(Diagnosis.analyze(out)?.cause == Diagnosis.analyze(Self.log)?.cause)
        #expect(out.split(separator: "\n").count == Self.log.split(separator: "\n").count)
    }

    @Test func redactingTwiceChangesNothingMore() {
        let once = Redaction.redact(Self.log, identity: anna)
        #expect(Redaction.redact(once, identity: anna) == once)
        // Not even for a user whose name is the placeholder's word.
        let user = MacIdentity(home: "/Users/user", userName: "user", fullName: "Name", hostNames: ["host"])
        let text = "/Users/user/x by user Name on host"
        let out = Redaction.redact(text, identity: user)
        #expect(out == "/Users/[user]/x by user Name on host")
        #expect(Redaction.redact(out, identity: user) == out)
    }
}
