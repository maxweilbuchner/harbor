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

    /// Installs Rosetta behind the system's administrator prompt and waits for it; call it off the main thread.
    /// Returns what went wrong if it failed and said why (e.g. "User canceled.").
    public static func install() -> String? {
        runAppleScript("do shell script \"\(installCommand)\" with administrator privileges")
    }

    /// Runs AppleScript in `/usr/bin/osascript` rather than with NSAppleScript, which may only be used on the
    /// main thread (where waiting for the prompt and the install would freeze the window). Returns the script's
    /// error message, nil if it succeeded.
    static func runAppleScript(_ source: String) -> String? {
        let script = Process(), errors = Pipe()
        script.executableURL = URL(filePath: "/usr/bin/osascript")
        script.arguments = ["-e", source]
        script.standardOutput = FileHandle.nullDevice
        script.standardError = errors
        let wait: () -> Void
        do { wait = try script.start() } catch { return error.localizedDescription }
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        wait()
        return script.terminationStatus == 0 ? nil : errorMessage(fromOsascript: output)
    }

    /// The message in osascript's "0:112: execution error: User canceled. (-128)".
    static func errorMessage(fromOsascript output: String) -> String? {
        var message = Substring(output.trimmingCharacters(in: .whitespacesAndNewlines))
        if let marker = message.range(of: "execution error: ") { message = message[marker.upperBound...] }
        if message.hasSuffix(")"), let code = message.range(of: " (", options: .backwards),
           Int(message[code.upperBound...].dropLast()) != nil { message = message[..<code.lowerBound] }
        return message.isEmpty ? nil : String(message)
    }
}
