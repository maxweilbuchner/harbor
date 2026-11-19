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

    /// The backend a bottle actually gets.
    ///
    /// D3DMetal is licensed only for games (GPTK license §2A(i)), so it is never chosen automatically until Harbor
    /// can tell games from apps; a bottle gets it only when set to `.d3dmetal` explicitly. DXMT and DXVK aren't
    /// shipped yet and honestly report plain Wine (wined3d) instead of pretending.
    public func effectiveGraphics(for bottle: Bottle) -> GraphicsBackend {
        switch bottle.settings.graphics {
        case .d3dmetal:
            return d3dmetal == nil ? .wined3d : .d3dmetal
        case .automatic, .wined3d, .dxmt, .dxvk:
            return .wined3d
        }
    }

    /// The backend a program gets when launched. Per launch, not per bottle: processes in one prefix can use
    /// different runtimes (verified), so Steam and its games can share a bottle.
    ///
    /// Automatic: every program Harbor considers a game runs on the D3DMetal runtime (the GPTK license covers
    /// games only), even when the launched file itself has no DirectX imports: launchers (Superposition's,
    /// Steam) start the real game as a child process, which inherits the launcher's runtime. That's safe because
    /// D3DMetal only replaces the 64-bit DirectX builtins; 32-bit and non-DirectX processes behave as on plain
    /// Wine. Everything that isn't a game runs on plain Wine.
    public func effectiveGraphics(for program: Program) -> GraphicsBackend {
        switch program.graphics {
        case .d3dmetal?:
            return d3dmetal == nil ? .wined3d : .d3dmetal
        case .wined3d?, .dxmt?, .dxvk?:
            return .wined3d
        case .automatic?, nil:
            return program.isGame && d3dmetal != nil ? .d3dmetal : .wined3d
        }
    }

    func runtime(for graphics: GraphicsBackend) throws -> WineRuntime {
        if graphics == .d3dmetal, let d3dmetal {
            return try d3dmetal.runtime(basedOn: runtime, in: runtimesDirectory)
        }
        return runtime
    }

    /// Launches a library program and returns the Wine process, which lives as long as the program.
    @discardableResult
    public func launch(_ program: Program, in bottle: Bottle,
                       onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        guard let exe = bottle.unixPath(forWindowsPath: program.windowsPath) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: program.windowsPath])
        }
        let graphics = effectiveGraphics(for: program)
        var arguments = ["start", "/wait"]
        if let dir = program.workingDirectory { arguments += ["/d", dir] }
        arguments += ["/unix", exe.path] + Self.splitArguments(program.arguments ?? "")
        return try run(bottle, arguments: arguments, label: program.name, runtime: try runtime(for: graphics), onExit: onExit)
    }

    /// Splits a Windows command-line argument string on spaces outside double quotes.
    static func splitArguments(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); hasToken = true }
            else if ch == " " && !quoted { if hasToken { out.append(current); current = ""; hasToken = false } }
            else { current.append(ch); hasToken = true }
        }
        if hasToken { out.append(current) }
        return out
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
    public func environment(for bottle: Bottle, runtime: WineRuntime? = nil,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = bottle.prefix.path
        // Wine dlopens libfreetype.6.dylib, libMoltenVK.dylib, … by bare name; dyld only finds them via the fallback
        // path. Without this, fonts and Vulkan silently fail and wineboot stalls on timeouts (5 min vs 30 s).
        let runtimeLib = (runtime ?? self.runtime).root.appending(path: "lib").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [runtimeLib, env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/local/lib:/usr/lib"]
            .joined(separator: ":")
        // Keep errors (for Diagnose), drop the noisy fixme channel.
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "fixme-all"
        // Keep Wine from writing Linux-style menu entries and file associations into the user's home.
        env["WINEDLLOVERRIDES"] = ["winemenubuilder.exe=d", env["WINEDLLOVERRIDES"]].compactMap { $0 }.joined(separator: ";")
        // User variables may add to, but not replace, what Harbor depends on.
        for (key, value) in bottle.settings.environment {
            switch key {
            case "WINEPREFIX":
                continue
            case "WINEDLLOVERRIDES":
                env[key] = [env[key], value].compactMap { $0 }.joined(separator: ";")
            default:
                env[key] = value
            }
        }
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
        // Harbor explains crashes itself (Diagnose); Wine's own "Program Error" dialog would only confuse.
        try await execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"], label: "setup")
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
                    runtime chosen: WineRuntime? = nil, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        let process = Process()
        let runtime = try chosen ?? runtime(for: bottle)
        process.executableURL = runtime.wine
        process.arguments = arguments
        process.environment = environment(for: bottle, runtime: runtime)
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
        let runtime = try runtime(for: bottle)
        process.executableURL = runtime.wineserver
        process.arguments = ["-k"]
        process.environment = environment(for: bottle, runtime: runtime)
        try process.run()
        process.waitUntilExit()
    }
}

public struct WineExitError: Error, CustomStringConvertible {
    public let status: Int32
    public var description: String { "Wine exited with status \(status)" }
}
