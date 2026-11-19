import Foundation

/// Wine's Windows code is x86_64 and runs under Rosetta on Apple silicon.
public enum Rosetta {
    static let runtime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")

    /// True on Intel Macs (nothing to translate) or when Rosetta is installed.
    public static var isAvailable: Bool {
        isAvailable(machine: currentMachine, runtimeExists: FileManager.default.fileExists(atPath: runtime.path))
    }

    static func isAvailable(machine: String, runtimeExists: Bool) -> Bool {
        machine == "x86_64" || runtimeExists
    }

    /// Hardware architecture, unaffected by whether Harbor itself runs translated.
    static var currentMachine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        let machine = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        // hw.machine reports "arm64" on Apple silicon; fall back to a compile-time guess if it's empty.
        if machine.isEmpty {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }
        return machine
    }

    /// The command that installs Rosetta; needs administrator rights, so callers run it with an auth prompt.
    public static let installCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
}
