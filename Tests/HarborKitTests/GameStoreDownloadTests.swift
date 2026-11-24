import Foundation
import Testing
@testable import HarborKit

@Suite struct GameStoreDownloadTests {
    /// A store's installer is run only if its download ended on the vendor's own host, over HTTPS (#87).
    @Test func anInstallerIsTrustedOnlyFromItsVendorsHost() {
        typealias Store = GameStores.Store
        // Where the links lead today: Valve's CDN directly, Epic's through a redirect to its Akamai host.
        for store in Store.allCases { #expect(store.trustsDownload(from: store.installerURL), "\(store)") }
        #expect(Store.epic.trustsDownload(from: URL(string: "https://epicgames-download1.akamaized.net/Builds/UnrealEngineLauncher/Installers/Windows/EpicInstaller-20.3.3.msi?launcherfilename=EpicInstaller-20.3.3.msi")))
        #expect(Store.epic.trustsDownload(from: URL(string: "https://download.EpicGames.com/x.msi")))
        #expect(Store.steam.trustsDownload(from: URL(string: "https://steamstatic.com/SteamSetup.exe")))

        let refused: [(Store, String)] = [
            (.steam, "http://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"),      // not HTTPS
            (.steam, "https://evilsteamstatic.com/SteamSetup.exe"),                                 // not a subdomain
            (.steam, "https://steamstatic.com.example.org/SteamSetup.exe"),
            (.steam, "https://example.org/steamstatic.com/SteamSetup.exe"),
            (.steam, "https://steamstatic.com@example.org/SteamSetup.exe"),
            (.steam, "https://download.epicgames.com/SteamSetup.exe"),                              // the other vendor
            (.epic, "https://someone-else.akamaized.net/EpicInstaller.msi"),                        // Akamai is shared
            (.epic, "https://epicgames-download1.akamaized.net.example.org/EpicInstaller.msi"),
            (.epic, "file:///tmp/EpicInstaller.msi"),
        ]
        for (store, url) in refused { #expect(!store.trustsDownload(from: URL(string: url)), "\(url)") }
        #expect(!Store.steam.trustsDownload(from: nil))
        #expect(String(describing: GameStores.Failure.untrustedDownload(.epic, host: "example.org"))
                == "The Epic Games Store installer came from example.org, not from Epic Games. Harbor didn’t run it.")
    }
}
