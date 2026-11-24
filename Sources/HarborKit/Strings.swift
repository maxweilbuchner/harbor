import Foundation

/// Where Harbor's sentences are looked up: one table for the app and HarborKit (Resources/en.lproj; English is
/// the only language so far, and every key is its English sentence).
public enum Strings {
    /// SwiftPM's name for HarborKit's resource bundle.
    static let resourceBundle = "Harbor_HarborKit.bundle"

    /// The bundle that has the table. Harbor.app carries it in its own Resources (scripts/bundle-app.sh), where
    /// SwiftUI looks its texts up too; `swift run`, harbor-cli and the tests have SwiftPM's resource bundle
    /// beside the binary.
    public static let bundle: Bundle = {
        let own = Bundle(for: Anchor.self)
        var folders = [Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        // In a test bundle HarborKit isn't part of the main program: the resources are beside the .xctest.
        if own != Bundle.main { folders.append(own.bundleURL.deletingLastPathComponent()) }
        return locate(main: .main, beside: folders.compactMap { $0 })
    }()

    /// Not `Bundle.module`: that one stops the process when its bundle is gone, and looks for it in the root of
    /// Harbor.app, where nothing can be signed. Without a table every lookup gives its key, the English sentence
    /// (in the form for several where there is one for a single thing).
    static func locate(main: Bundle, beside folders: [URL]) -> Bundle {
        if main.url(forResource: "Localizable", withExtension: "strings") != nil { return main }
        return folders.lazy.compactMap { Bundle(url: $0.appending(path: resourceBundle)) }.first ?? main
    }

    private final class Anchor {}
}
