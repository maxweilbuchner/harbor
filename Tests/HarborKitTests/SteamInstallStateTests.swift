import Foundation
import Testing
@testable import HarborKit

@Suite struct SteamInstallStateTests {
    func manifest(flags: String?) -> String {
        "\"AppState\"\n{\n\t\"appid\"\t\t\"2570630\"\n\t\"name\"\t\t\"20 Small Mazes\"\n"
            + (flags.map { "\t\"StateFlags\"\t\t\"\($0)\"\n" } ?? "") + "\t\"installdir\"\t\t\"20 Small Mazes\"\n}\n"
    }

    /// A game appears once Steam marks it fully installed (StateFlags bit 4), not while it downloads.
    @Test func listsAGameOnlyOnceSteamHasInstalledIt() {
        #expect(SteamLibrary.parseManifest(manifest(flags: "4"))?.name == "20 Small Mazes")
        #expect(SteamLibrary.parseManifest(manifest(flags: "6"))?.appID == 2570630)     // installed, update queued
        #expect(SteamLibrary.parseManifest(manifest(flags: "1026")) == nil)             // downloading
        #expect(SteamLibrary.parseManifest(manifest(flags: "2")) == nil)                // update required, never installed
        #expect(SteamLibrary.parseManifest(manifest(flags: nil)) != nil)                // older Steam: no field
    }
}
