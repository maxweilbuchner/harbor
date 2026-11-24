import Foundation
import Testing
@testable import HarborKit

/// The question before a program goes to the Trash with everything installed for it (#71).
@Suite struct RemovalQuestionTests {
    @Test func aProgramOnItsOwn() {
        let q = Library.removalQuestion(name: "Thing", games: 0, running: false)
        #expect(q.title == "Remove Thing?")
        #expect(q.message == "Everything installed for Thing, including its saved data, goes to the Trash. You can put it back from there until you empty it.")
    }

    /// Removing ends a running program, and its unsaved work with it: said first.
    @Test func aRunningProgramIsNamed() {
        let q = Library.removalQuestion(name: "Thing", games: 0, running: true)
        #expect(q.title == "Remove Thing?")
        #expect(q.message.hasPrefix("Thing is running and will be quit. Everything installed for Thing"))
    }

    /// A store's tile takes the store's games along: title and message say how many.
    @Test func aStoreSaysHowManyGamesGoWithIt() {
        let many = Library.removalQuestion(name: "Steam", games: 12, running: false)
        #expect(many.title == "Remove Steam and 12 Games?")
        #expect(many.message == "Steam, the 12 games installed with it and their saved data go to the Trash. You can put them back from there until you empty it.")
        let one = Library.removalQuestion(name: "Epic Games Launcher", games: 1, running: true)
        #expect(one.title == "Remove Epic Games Launcher and 1 Game?")
        #expect(one.message == "Epic Games Launcher is running and will be quit. Epic Games Launcher, the game installed with it and their saved data go to the Trash. You can put them back from there until you empty it.")
    }
}
