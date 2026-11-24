import Foundation
import Testing
@testable import HarborKit

/// harbor-cli's exit status and error output, which scripts/package-runtime.sh and WindowsTests rely on (#67).
@Suite struct CLIErrorTests {
    let fm = FileManager.default

    /// Runs the harbor-cli built next to the tests and returns how it ended and what it wrote to stderr.
    func cli(_ arguments: [String], environment: [String: String] = [:]) async throws -> (status: Int32, crashed: Bool, errors: String) {
        // SwiftPM puts the test bundle and the executables into the same folder.
        var folder = Bundle(for: Marker.self).bundleURL
        while folder.pathExtension != "xctest", folder.path != "/" { folder.deleteLastPathComponent() }
        let tool = folder.deletingLastPathComponent().appending(path: "harbor-cli")
        try #require(fm.isExecutableFile(atPath: tool.path), "harbor-cli isn't built at \(tool.path)")
        let process = Process(), errors = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try await process.runUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, process.terminationReason == .uncaughtSignal, text)
    }
    private final class Marker {}

    /// An error thrown by a command (here: the list of runtimes can't be read) is one line and status 1, not a
    /// trap with "Fatal error: Error raised at top level".
    @Test(.timeLimit(.minutes(1))) func aCommandsErrorIsOneLineAndStatusOne() async throws {
        let base = fm.temporaryDirectory.appending(path: "harbor-cli-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let key = try RuntimeSigning.publicKey(forPrivate: RuntimeSigning.newPrivateKey())
        let result = try await cli(["install-runtime", base.appending(path: "missing.json").absoluteString, "--into", base.appending(path: "installed").path],
                                   environment: ["HARBOR_RUNTIME_PUBLIC_KEY": key])
        #expect(!result.crashed)
        #expect(result.status == 1)
        #expect(result.errors.hasPrefix("harbor-cli: ") && result.errors.hasSuffix("\n"))
        #expect(result.errors.split(separator: "\n").count == 1, "\(result.errors)")
        #expect(!result.errors.contains("Fatal error"))
    }

    @Test(.timeLimit(.minutes(1))) func anUnknownCommandIsStatusOne() async throws {
        let result = try await cli(["no-such-command"])
        #expect(result.status == 1 && !result.crashed)
        #expect(result.errors.hasPrefix("harbor-cli: usage: "))
    }
}
