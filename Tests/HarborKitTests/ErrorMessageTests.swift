import Foundation
import Testing
@testable import HarborKit

/// The sentence shown for an error in the add sheet, the first download and the status line (#68).
@Suite struct ErrorMessageTests {
    @Test func harborsOwnErrorsDescribeThemselves() {
        #expect(ErrorMessage.text(for: AddProgram.Failure.notAWindowsProgram) == AddProgram.Failure.notAWindowsProgram.description)
        #expect(ErrorMessage.text(for: RecipeError.bottleInUse) == RecipeError.bottleInUse.description)
        #expect(ErrorMessage.text(for: WineExitError(status: 3)) == "Wine exited with status 3")
    }

    @Test func aNetworkErrorIsASentenceNotADump() {
        // As URLSession throws it, with the system's sentence, and as Harbor's own code makes it, without one.
        let offline = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        #expect(ErrorMessage.text(for: offline) == "The Internet connection appears to be offline.")
        for error in [offline, URLError(.badServerResponse), URLError(.notConnectedToInternet)] {
            let text = ErrorMessage.text(for: error)
            #expect(!text.contains("NSURLErrorDomain") && !text.contains("Code=") && !text.contains("UserInfo"), "\(text)")
            #expect(!text.isEmpty)
        }
    }

    @Test func aFileErrorIsASentenceNotADump() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "harbor-missing-\(UUID().uuidString)/setup.exe")
        let thrown = #expect(throws: CocoaError.self) {
            try FileManager.default.copyItem(at: missing, to: missing.appendingPathExtension("copy"))
        }
        let error = try #require(thrown)
        let text = ErrorMessage.text(for: error)
        #expect(text == error.localizedDescription)
        #expect(text.contains("setup.exe"))
        #expect(!text.contains("Error Domain") && !text.contains("Code=") && !text.contains("UserInfo"), "\(text)")
    }
}
