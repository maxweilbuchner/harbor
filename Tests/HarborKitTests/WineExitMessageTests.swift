import Foundation
import Testing
@testable import HarborKit

/// What the add sheet and the status line say when a setup step or an installer ends with an error (#68).
@Suite struct WineExitMessageTests {
    /// A sentence in the app's words, with the status for a bug report; nothing of "Wine" or "bottle".
    @Test func aFailedStepIsASentenceWithItsStatus() {
        let text = ErrorMessage.text(for: WineExitError(status: 3))
        #expect(text == "A Windows setup step ended with an error (status 3).")
        #expect(WineExitError(status: 1603).description.contains("1603"))
        for word in ["Wine", "wine", "bottle"] { #expect(!text.contains(word), "\(text)") }
    }
}
