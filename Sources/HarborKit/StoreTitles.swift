import Foundation

/// Whether a store's title is a game, which decides D3DMetal (Apple licenses it for games only).
///
/// Store titles count as games unless the store's own records say software (Steam: "Application" or "Tool";
/// Epic: categories without "games") or the user says so; the user's choice, kept in the bottle's
/// `store-titles.json` under the title's key ("steam:<appid>", "epic:<AppName>"), wins. A title that isn't a game
/// is started by its own program instead of through the store, because a title started by the store inherits the
/// store's runtime, which is the D3DMetal one.
extension Bottle {
    var storeTitlesFile: URL { root.appending(path: "store-titles.json") }

    /// The user's choices: title key → is a game.
    public func storeTitleChoices() -> [String: Bool] {
        (try? Data(contentsOf: storeTitlesFile)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
    }

    /// Records the user's choice for a title; nil goes back to what the store says.
    public func setStoreTitle(_ key: String, isGame: Bool?) throws {
        var choices = storeTitleChoices()
        choices[key] = isGame
        if choices.isEmpty {
            try? FileManager.default.removeItem(at: storeTitlesFile)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(choices).write(to: storeTitlesFile, options: .atomic)
        }
    }
}
