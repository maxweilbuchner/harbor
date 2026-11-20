import Foundation

/// One program in Harbor's library: one the user added, or a game a store installed in a bottle.
public struct LibraryEntry: Sendable, Equatable {
    public var program: Program
    public var bottle: Bottle
    /// Installed and managed by a game store (read from Steam's or Epic's records, not Harbor's library).
    public var managedByStore = false
    /// Image file its icon is read from, if it has one.
    public var iconFile: URL?
}

public enum Library {
    /// Every program in `bottles`, newest first: each bottle's own programs, plus the games Steam and the Epic
    /// Games Launcher installed there, read from the stores' own records each time. Reads many files; call it
    /// off the main actor.
    public static func scan(_ bottles: [Bottle]) -> [LibraryEntry] {
        bottles.flatMap { bottle -> [LibraryEntry] in
            let own = bottle.programs().map { LibraryEntry(program: $0, bottle: bottle, iconFile: bottle.iconFile(for: $0)) }
            let epic = EpicLibrary.games(in: bottle).compactMap { game -> LibraryEntry? in
                guard let program = EpicLibrary.program(for: game, in: bottle) else { return nil }
                return LibraryEntry(program: program, bottle: bottle, managedByStore: true,
                                    iconFile: EpicLibrary.icon(for: game, program: program, in: bottle))
            }
            guard let steam = SteamLibrary.steamFolder(in: bottle) else { return own + epic }
            let games = SteamLibrary.games(in: bottle).compactMap { game -> LibraryEntry? in
                guard let program = SteamLibrary.program(for: game, steam: steam, in: bottle) else { return nil }
                return LibraryEntry(program: program, bottle: bottle, managedByStore: true,
                                    iconFile: SteamLibrary.iconSource(for: game, steam: steam))
            }
            return own + epic + games
        }
        .sorted { $0.program.addedAt > $1.program.addedAt }
    }
}
