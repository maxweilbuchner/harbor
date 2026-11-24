import Foundation

/// What to tell the user about an error, in one readable sentence.
public enum ErrorMessage {
    /// Harbor's own errors describe themselves. The system's (no network, a file that can't be copied) have a
    /// localized sentence; their `String(describing:)` is a dump of domain, code and user info.
    public static func text(for error: any Error) -> String {
        if String(reflecting: type(of: error)).hasPrefix("HarborKit.") { return String(describing: error) }
        // A network error made without the system's sentence falls back to one that names its domain and code.
        if error is URLError, error.localizedDescription.contains("NSURLErrorDomain") { return String(localized: "The server couldn’t be reached.", bundle: Strings.bundle) }
        return error.localizedDescription
    }
}
