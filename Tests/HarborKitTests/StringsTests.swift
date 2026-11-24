import Foundation
import Testing
@testable import HarborKit

/// The table of Harbor's sentences (Resources/en.lproj): it is in the build, has the forms for one and for
/// several, and its absence costs nothing but those forms (#72).
@Suite struct StringsTests {
    /// The table as SwiftPM built it for this test run.
    func table() throws -> Bundle {
        let bundle = Strings.bundle
        try #require(bundle.url(forResource: "Localizable", withExtension: "strings") != nil, "no strings table beside the tests")
        return bundle
    }

    @Test func theTableIsInTheBuildWithSentencesOfTheAppAndOfHarborKit() throws {
        let url = try #require(try table().url(forResource: "Localizable", withExtension: "strings"))
        let entries = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(entries.count > 150)
        // The app's (SwiftUI and its status lines) and HarborKit's own.
        for key in ["Add one program at a time.", "Report a Problem…", "Move to Trash",
                    "The runtime list isn't signed by Harbor.", "%@ crashed. The log has the details for a bug report."] {
            #expect(entries[key] == key, "\(key)")
        }
    }

    @Test func aSentenceWithANumberHasAFormForOneAndForSeveral() throws {
        _ = try table()
        #expect(Library.removalQuestion(name: "Steam", games: 1, running: false).title == "Remove Steam and 1 Game?")
        #expect(Library.removalQuestion(name: "Steam", games: 12, running: false).title == "Remove Steam and 12 Games?")
        #expect(Library.removalQuestion(name: "Steam", games: 1, running: false).message
                == "Steam, the game installed with it and their saved data go to the Trash. You can put them back from there until you empty it.")
        #expect(Library.removalQuestion(name: "Steam", games: 12, running: false).message
                == "Steam, the 12 games installed with it and their saved data go to the Trash. You can put them back from there until you empty it.")
        func said(_ count: Int, _ key: String.LocalizationValue) -> String { String(localized: key, bundle: Strings.bundle) }
        #expect(said(1, "\(1) programs’ data couldn’t be read.") == "1 program’s data couldn’t be read.")
        #expect(said(3, "\(3) programs’ data couldn’t be read.") == "3 programs’ data couldn’t be read.")
        #expect(said(2, "Found \(2) programs installed earlier.") == "Found 2 programs installed earlier.")
        #expect(said(4, "Added \(4) programs") == "Added 4 programs")
    }

    /// Without a table (a binary moved away from its resources) every sentence is still its English key.
    @Test func withoutATableASentenceIsItsKey() throws {
        let fm = FileManager.default
        let empty = fm.temporaryDirectory.appending(path: "harbor-strings-\(UUID().uuidString).bundle")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: empty) }
        let none = try #require(Bundle(url: empty))
        #expect(Strings.locate(main: none, beside: [empty.deletingLastPathComponent().appending(path: "nowhere")]) == none)
        #expect(String(localized: "The runtime list isn't signed by Harbor.", bundle: none) == "The runtime list isn't signed by Harbor.")
        #expect(String(localized: "Remove \("Steam") and \(12) Games?", bundle: none) == "Remove Steam and 12 Games?")
    }
}
