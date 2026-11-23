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

    /// DXMT, when the runtime ships it (Harbor's own builds do, under lib/dxmt).
    public var dxmt: DXMT? { DXMT.locate(in: runtime) }

    public static var defaultRuntimesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Harbor/Runtimes")
    }

    /// The backend a bottle's own commands get: everything that isn't a library launch (installers, `reg`,
    /// recipes, wineboot).
    ///
    /// D3DMetal is licensed only for games (GPTK license §2A(i)) and none of those commands is one, so a bottle
    /// set to `.d3dmetal` runs them on plain Wine; games get D3DMetal per launch, below. DXMT is used when set
    /// and shipped. DXVK isn't shipped and honestly reports plain Wine (wined3d) instead of pretending.
    public func effectiveGraphics(for bottle: Bottle) -> GraphicsBackend {
        switch bottle.settings.graphics {
        case .dxmt:
            return dxmt == nil ? .wined3d : .dxmt
        case .automatic, .wined3d, .dxvk, .d3dmetal:
            return .wined3d
        }
    }

    /// Whether `graphics` can be chosen for `program`: its layer has to be installed, and D3DMetal is for games
    /// only (GPTK license §2A(i)).
    public func offers(_ graphics: GraphicsBackend, for program: Program) -> Bool {
        switch graphics {
        case .d3dmetal:
            return program.isGame && d3dmetal != nil
        case .dxmt:
            return dxmt != nil
        case .automatic, .wined3d, .dxvk:
            return true
        }
    }

    /// The backend a program gets when launched. Per launch, not per bottle: processes in one prefix can use
    /// different runtimes (verified), so Steam and its games can share a bottle.
    ///
    /// Automatic: every program Harbor considers a game runs on the D3DMetal runtime (the GPTK license covers
    /// games only), even when the launched file itself has no DirectX imports: launchers (Superposition's,
    /// Steam) start the real game as a child process, which inherits the launcher's runtime. That's safe because
    /// D3DMetal only replaces the 64-bit DirectX builtins; 32-bit and non-DirectX processes behave as on plain
    /// Wine. Everything that isn't a game runs on plain Wine, also when D3DMetal was chosen for it.
    ///
    /// Known gap: everything added from Steam or Epic counts as a game, though stores sell other software too.
    public func effectiveGraphics(for program: Program) -> GraphicsBackend {
        switch program.graphics {
        case .d3dmetal?:
            return offers(.d3dmetal, for: program) ? .d3dmetal : .wined3d
        case .dxmt?:
            return dxmt == nil ? .wined3d : .dxmt
        case .wined3d?, .dxvk?:
            return .wined3d
        case .automatic?, nil:
            return program.isGame && d3dmetal != nil ? .d3dmetal : .wined3d
        }
    }

    /// The backend for launching `program` from `executable`: as above, plus DXMT for programs that link Direct3D
    /// 10/11 (Wine's own D3D11 can't run shader model 5 on MoltenVK) and are either not games or 32-bit games,
    /// for which D3DMetal has no DLLs. Other games stay off it, with or without D3DMetal: their launchers start
    /// Direct3D 12 children, and DXMT's dxgi replaces Wine's, which Wine's D3D12 needs, for the whole process tree.
    /// For the same reason nothing gets DXMT whose folder holds a Direct3D 12 program.
    public func effectiveGraphics(for program: Program, executable: URL) -> GraphicsBackend {
        let chosen = effectiveGraphics(for: program)
        guard program.graphics ?? .automatic == .automatic, dxmt != nil,
              let analysis = try? ProgramAnalysis.analyze(executable), let d3d = analysis.direct3D, (10...11).contains(d3d),
              !program.isGame || analysis.architecture == .x86,
              !ProgramAnalysis.usesDirect3D12(in: executable.deletingLastPathComponent()) else { return chosen }
        return .dxmt
    }

    public func runtime(for graphics: GraphicsBackend) throws -> WineRuntime {
        if graphics == .d3dmetal, let d3dmetal {
            return try d3dmetal.runtime(basedOn: runtime, in: runtimesDirectory)
        }
        if graphics == .dxmt, let dxmt {
            return try dxmt.runtime(basedOn: runtime, in: runtimesDirectory)
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
        let graphics = effectiveGraphics(for: program, executable: exe)
        if graphics == .dxmt { try dxmt?.prepare(bottle) }
        var arguments = ["start", "/wait"]
        if let dir = program.workingDirectory { arguments += ["/d", dir] }
        let own = Self.splitArguments(program.arguments ?? "")
        let known = (Self.knownArguments[exe.lastPathComponent.lowercased()] ?? []).filter { !own.contains($0) }
        arguments += ["/unix", exe.path] + own + known
        return try run(bottle, arguments: arguments, label: program.name, runtime: try runtime(for: graphics), onExit: onExit)
    }

    /// Options some programs need under Wine, added at launch (not stored, so changing them here reaches
    /// existing libraries).
    /// - steam.exe: its Chromium UI must composite in software (`-cef-disable-gpu`): the GPU path crashes the
    ///   GPU process and leaves no window; with this option and scripts/patches/wine/0001 it renders.
    static let knownArguments: [String: [String]] = ["steam.exe": ["-cef-disable-gpu"]]

    /// Splits a Windows command-line argument string on spaces outside double quotes. Backslashes are special only
    /// before a quote, as in CommandLineToArgvW: each pair is one backslash, and an odd one makes the quote literal.
    static func splitArguments(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        var backslashes = 0
        for ch in line {
            if ch == "\\" { backslashes += 1; hasToken = true; continue }
            current += String(repeating: "\\", count: ch == "\"" ? backslashes / 2 : backslashes)
            if ch == "\"" { if backslashes % 2 == 1 { current.append(ch) } else { quoted.toggle() }; hasToken = true }
            else if ch == " " && !quoted { if hasToken { out.append(current); current = ""; hasToken = false } }
            else { current.append(ch); hasToken = true }
            backslashes = 0
        }
        current += String(repeating: "\\", count: backslashes)
        if hasToken { out.append(current) }
        return out
    }

    /// The Wine runtime to launch `bottle` with. Bottles can't switch runtimes while Wine is running in them,
    /// since every process in a prefix must share one wineserver.
    public func runtime(for bottle: Bottle) throws -> WineRuntime {
        let graphics = effectiveGraphics(for: bottle)
        if graphics == .dxmt { try dxmt?.prepare(bottle) }
        return try runtime(for: graphics)
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
        // Programs that aren't games keep a display mode change inside Wine (scripts/patches/wine/0013): a real one
        // captures the displays, which shuts out Mission Control. Games, on the D3DMetal runtime, keep the
        // display's real modes; emulation offers nothing above the desktop's current size.
        env["HARBOR_EMULATE_MODESET"] = D3DMetalRedist.isRuntime(runtime ?? self.runtime) ? nil : "1"
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
    /// `windowsPath`: the file's path inside the bottle, which msiexec needs (it is a Windows program and can't read
    /// a Mac path once drive Z: is gone).
    public static func arguments(toOpen file: URL, windowsPath: String? = nil, extra: [String] = []) -> [String] {
        switch file.pathExtension.lowercased() {
        case "msi":
            return ["msiexec", "/i", windowsPath ?? file.path] + extra
        default:
            let known = (knownArguments[file.lastPathComponent.lowercased()] ?? []).filter { !extra.contains($0) }
            return ["start", "/wait", "/unix", file.path] + extra + known
        }
    }

    /// Creates the Wine prefix (`wineboot --init`) and waits for it.
    public func initialize(_ bottle: Bottle) async throws {
        try await execute(bottle, arguments: ["wineboot", "--init"], label: "setup")
        try await execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine"#, "/v", "Version", "/d", bottle.settings.windowsVersion.rawValue, "/f"], label: "setup")
        // Harbor explains crashes itself (Diagnose); Wine's own "Program Error" dialog would only confuse.
        try await execute(bottle, arguments: ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"], label: "setup")
        // A new prefix: nothing uses drive Z: yet, so it can go now even though wineserver lingers for a moment
        // (later starts only touch it while the bottle is stopped).
        bottle.applyMacFilesAccess()
    }

    /// Opens a Windows program or installer inside `bottle`. `onExit` runs when the program itself exits.
    @discardableResult
    public func open(_ file: URL, in bottle: Bottle, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        // Wine can't start a file by its Mac path once drive Z: is gone: run a copy inside the bottle.
        let local = try bottle.importForRunning(file)
        return try run(bottle, arguments: Self.arguments(toOpen: local, windowsPath: bottle.windowsPath(for: local)),
                       label: file.deletingPathExtension().lastPathComponent, onExit: onExit)
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
        // Older bottles still link their Documents etc. to the Mac's; replace those links before Windows starts.
        // Also the place where drive Z: (the whole Mac) is removed or kept, per the bottle's setting.
        if !bottle.isRunning() {
            bottle.unshareUserFolders()
            bottle.applyMacFilesAccess()
        }
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

    /// Stops every Wine process in the bottle. Uses the base runtime's wineserver (derived runtimes carry the same
    /// one), so a graphics layer that can't be set up never keeps a bottle from stopping.
    public func shutdown(_ bottle: Bottle) throws {
        let process = Process()
        process.executableURL = runtime.wineserver
        process.arguments = ["-k"]
        process.environment = environment(for: bottle, runtime: runtime)
        try process.runAndWait()
    }
}

public struct WineExitError: Error, CustomStringConvertible {
    public let status: Int32
    public var description: String { "Wine exited with status \(status)" }
}
