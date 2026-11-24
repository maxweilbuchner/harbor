import Foundation

/// One program in Harbor's library: one the user added, or a game a store installed in a bottle.
public struct LibraryEntry: Sendable, Equatable {
    public var program: Program
    public var bottle: Bottle
    /// Installed and managed by a game store (read from Steam's or Epic's records, not Harbor's library).
    public var managedByStore = false
    /// Image file its icon is read from, if it has one.
    public var iconFile: URL?
    /// For store titles: the key of the user's game/software choice (`Bottle.setStoreTitle`).
    public var storeTitleKey: String?
}

public enum Library {
    /// Every program in `bottles`, newest first: each bottle's own programs, plus the games Steam and the Epic
    /// Games Launcher installed there, read from the stores' own records each time. Reads many files; call it
    /// off the main actor. `salt` keeps the store games' IDs unguessable (the app passes `LaunchSalt()`).
    public static func scan(_ bottles: [Bottle], salt: LaunchSalt) -> [LibraryEntry] {
        let salt = salt.value()
        return bottles.flatMap { bottle -> [LibraryEntry] in
            let own = bottle.programs().map { LibraryEntry(program: $0, bottle: bottle, iconFile: bottle.iconFile(for: $0)) }
            let epic = EpicLibrary.games(in: bottle).compactMap { game -> LibraryEntry? in
                guard let program = EpicLibrary.program(for: game, in: bottle, salt: salt) else { return nil }
                return LibraryEntry(program: program, bottle: bottle, managedByStore: true,
                                    iconFile: EpicLibrary.icon(for: game, program: program, in: bottle), storeTitleKey: game.titleKey)
            }
            guard let steam = SteamLibrary.steamFolder(in: bottle) else { return own + epic }
            let games = SteamLibrary.games(in: bottle).compactMap { game -> LibraryEntry? in
                guard let program = SteamLibrary.program(for: game, steam: steam, in: bottle, salt: salt) else { return nil }
                return LibraryEntry(program: program, bottle: bottle, managedByStore: true,
                                    iconFile: SteamLibrary.iconSource(for: game, steam: steam), storeTitleKey: game.titleKey)
            }
            return own + epic + games
        }
        .sorted { $0.program.addedAt > $1.program.addedAt }
    }

    /// What to ask before `name` goes to the Trash with its whole bottle. `games`: how many store games go with
    /// it (it is Steam or the Epic Games Launcher). `running`: something in the bottle runs, and removing ends it.
    public static func removalQuestion(name: String, games: Int, running: Bool) -> (title: String, message: String) {
        let title = games == 0 ? "Remove \(name)?" : "Remove \(name) and \(games) \(games == 1 ? "Game" : "Games")?"
        var message = games == 0
            ? "Everything installed for \(name), including its saved data, goes to the Trash. You can put it back from there until you empty it."
            : "\(name), the \(games == 1 ? "game" : "\(games) games") installed with it and their saved data go to the Trash. You can put them back from there until you empty it."
        // First: it is what can't be put back (unsaved work).
        if running { message = "\(name) is running and will be quit. " + message }
        return (title, message)
    }
}
