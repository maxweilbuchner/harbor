import Foundation

/// Builds and runs Wine processes for a bottle.
public struct WineLauncher: Sendable {
    public let runtime: WineRuntime
    public let d3dmetal: D3DMetalRedist?
    /// Where derived runtimes (base Wine + a graphics layer) are cached.
    public let runtimesDirectory: URL

    public init(runtime: WineRuntime, d3dmetal: D3DMetalRedist? = nil, runtimesDirectory: URL = WineLauncher.defaultRuntimesDirectory) {
        self.runtime = runtime
        self.d3dmetal = d3dmetal
        self.runtimesDirectory = runtimesDirectory
    }

    public static var defaultRuntimesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Harbor/Runtimes")
    }

    /// The backend a bottle actually gets. Automatic prefers D3DMetal when it is installed; per-program choice
    /// (from the executable's D3D imports) lands with DXMT/DXVK support.
    public func effectiveGraphics(for bottle: Bottle) -> GraphicsBackend {
        switch bottle.settings.graphics {
        case .automatic, .d3dmetal:
            return d3dmetal == nil ? .wined3d : .d3dmetal
        case let other:
            return other
        }
    }

    /// The Wine runtime to launch `bottle` with. Bottles can't switch runtimes while Wine is running in them,
    /// since every process in a prefix must share one wineserver.
    public func runtime(for bottle: Bottle) throws -> WineRuntime {
        if effectiveGraphics(for: bottle) == .d3dmetal, let d3dmetal {
            return try d3dmetal.runtime(basedOn: runtime, in: runtimesDirectory)
        }
        return runtime
    }

    /// The environment Wine runs with for `bottle`. Pure, so it can be unit-tested without running Wine.
    public func environment(for bottle: Bottle, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = bottle.prefix.path
        // Keep errors (for Diagnose), drop the noisy fixme channel.
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "fixme-all"
        // Keep Wine from writing Linux-style menu entries and file associations into the user's home.
        env["WINEDLLOVERRIDES"] = ["winemenubuilder.exe=d", env["WINEDLLOVERRIDES"]].compactMap { $0 }.joined(separator: ";")
        switch effectiveGraphics(for: bottle) {
        case .automatic, .wined3d, .dxvk, .d3dmetal:
            break
        case .dxmt:
            env["DXMT_LOG_LEVEL"] = env["DXMT_LOG_LEVEL"] ?? "none"
        }
        env.merge(bottle.settings.environment) { _, override in override }
        return env
    }

    /// Arguments to `bin/wine` for opening `file`: installers through msiexec, everything else via `start /wait /unix`
    /// so Wine resolves the working directory the way Explorer would, and the launched process lives exactly as
    /// long as the program (plain `start` returns immediately, so Harbor would lose track of it).
    public static func arguments(toOpen file: URL, extra: [String] = []) -> [String] {
        switch file.pathExtension.lowercased() {
        case "msi":
            return ["msiexec", "/i", file.path] + extra
        default:
            return ["start", "/wait", "/unix", file.path] + extra
        }
    }

    /// Creates the Wine prefix (`wineboot --init`) and waits for it.
    public func initialize(_ bottle: Bottle) async throws {
        try await execute(bottle, arguments: ["wineboot", "--init"], label: "setup")
        try await execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine"#, "/v", "Version", "/d", bottle.settings.windowsVersion.rawValue, "/f"], label: "setup")
    }

    /// Opens a Windows program or installer inside `bottle`. `onExit` runs when the program itself exits.
    @discardableResult
    public func open(_ file: URL, in bottle: Bottle, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        try run(bottle, arguments: Self.arguments(toOpen: file), label: file.deletingPathExtension().lastPathComponent, onExit: onExit)
    }

    /// Runs Wine and waits for it, throwing `WineExitError` on a non-zero status.
    public func execute(_ bottle: Bottle, arguments: [String], label: String = "run", output: FileHandle? = nil) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                // The handler is installed before the process starts, so it fires exactly once.
                try run(bottle, arguments: arguments, label: label, output: output) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if status != 0 { throw WineExitError(status: status) }
    }

    /// Starts Wine. Output goes to `output`, or to a new log file in the bottle's `logs/` folder.
    @discardableResult
    public func run(_ bottle: Bottle, arguments: [String], label: String = "run", output: FileHandle? = nil,
                    onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        let process = Process()
        process.executableURL = try runtime(for: bottle).wine
        process.arguments = arguments
        process.environment = environment(for: bottle)
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: bottle.driveC.path) ? bottle.driveC : bottle.root
        let handle = try output ?? bottle.newLog(label: label)
        process.standardOutput = handle
        process.standardError = handle
        if let onExit {
            process.terminationHandler = { onExit($0.terminationStatus) }
        }
        try process.run()
        return process
    }

    /// Stops every Wine process in the bottle.
    public func shutdown(_ bottle: Bottle) throws {
        let process = Process()
        process.executableURL = try runtime(for: bottle).wineserver
        process.arguments = ["-k"]
        process.environment = environment(for: bottle)
        try process.run()
        process.waitUntilExit()
    }
}

public struct WineExitError: Error, CustomStringConvertible {
    public let status: Int32
    public var description: String { "Wine exited with status \(status)" }
}
