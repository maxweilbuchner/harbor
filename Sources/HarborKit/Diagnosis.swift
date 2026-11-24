import Foundation

/// Why a Windows program failed, in plain words, read from the log Wine wrote for that launch. Only causes that
/// can be told apart reliably are reported; anything else gets no diagnosis (the caller shows the exit code).
public struct Diagnosis: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// A DLL the program imports isn't there. `recipe` installs it when it's part of a Windows component.
        case missingLibrary(String, recipe: String?)
        case dotNet
        /// Wine's Direct3D shader compiler gave up on the program's shaders; Microsoft's builds them.
        case shaderCompiler
        case antiCheat(String)
        case crashed
    }

    public let cause: Cause

    /// One or two sentences for people who don't know what a DLL is.
    public func message(for program: String) -> String {
        switch cause {
        case .missingLibrary(let dll, let recipe?):
            let component = Recipe.named(recipe)?.name ?? recipe
            return String(localized: "\(program) needs Microsoft \(component), which isn’t installed for it yet (\(dll) is missing).", bundle: Strings.bundle)
        case .missingLibrary(let dll, nil):
            return String(localized: "\(program) is missing a file it needs (\(dll)). It usually comes with the program’s installer: try installing the program again with its full installer.", bundle: Strings.bundle)
        case .dotNet:
            return String(localized: "\(program) is a .NET program and stopped inside Harbor’s built-in .NET. Microsoft’s .NET Framework 4.8 may run it.", bundle: Strings.bundle)
        case .shaderCompiler:
            return String(localized: "\(program) couldn’t prepare its graphics with the shader compiler built into Harbor. Microsoft’s Direct3D shader compiler can.", bundle: Strings.bundle)
        case .antiCheat(let name):
            return String(localized: "\(program) uses \(name) anti-cheat, which only runs on Windows itself. Games that need it can’t run in Harbor.", bundle: Strings.bundle)
        case .crashed:
            return String(localized: "\(program) crashed. The log has the details for a bug report.", bundle: Strings.bundle)
        }
    }

    /// The component that fixes it, if any.
    public var recipe: Recipe? {
        if case .missingLibrary(_, let id?) = cause { return Recipe.named(id) }
        if cause == .dotNet { return .dotnet48 }
        if cause == .shaderCompiler { return .d3dcompiler47 }
        return nil
    }

    /// Whether the cause was read from lines that name the launched program (given to `analyze`), not from
    /// anything in the session's log: only a library the program itself couldn't load is.
    public var namesProgram: Bool {
        if case .missingLibrary = cause { true } else { false }
    }

    /// Reads a Wine log. The first recognised cause wins, most specific first.
    ///
    /// `program` is the Windows path of the program that was launched. A log covers everything that ran in the
    /// session, helper programs included (Steam's `gldriverquery.exe` fails to find SDL2.dll at every start, and
    /// nothing is wrong): a missing library is only reported when the launched program itself couldn't be loaded.
    /// Without `program`, any module's failure counts.
    /// `installed`: whether a component is already in the bottle. One that is isn't named as the fix again.
    public static func analyze(_ log: String, program: String? = nil, installed: (Recipe) -> Bool = { _ in false }) -> Diagnosis? {
        let lines = log.split(whereSeparator: \.isNewline)
        // err:module:import_dll Library HarborMissing.dll (which is needed by L"…") not found
        // err:module:loader_init Importing dlls for L"C:\\…\\program.exe" failed, status c0000135
        var failedToLoad = true
        var missing = lines.filter { $0.contains("err:module:import_dll Library ") && $0.hasSuffix(" not found") }
        if let program {
            let quoted = wineDebugString(program).lowercased()
            failedToLoad = lines.contains { $0.contains("err:module:loader_init Importing dlls for ") && $0.lowercased().contains(quoted + " failed") }
            // The library the program itself asks for, not one a helper missed earlier in the session. When no
            // line names the program (one of its own libraries needs something), the first one stays the guess.
            let own = missing.filter { $0.lowercased().contains(" (which is needed by " + quoted + ")") }
            if !own.isEmpty { missing = own }
        }
        if failedToLoad, let line = missing.first,
           let start = line.range(of: "import_dll Library ")?.upperBound,
           let end = line[start...].range(of: " (which is needed by ")?.lowerBound {
            let dll = String(line[start..<end])     // may contain spaces
            let base = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
            return Diagnosis(cause: .missingLibrary(dll, recipe: Recipe.all.first { $0.overrides.contains(base) && !installed($0) }?.id))
        }
        let lower = log.lowercased()
        // Only where Wine loads a module or driver, and never by the bare word "vanguard": any other line may just
        // quote the program's own path (…\Call of Duty Vanguard\game.exe).
        let loads = lines.filter { line in [":module:", ":loaddll:", ":ntoskrnl:", ":winedevice:"].contains { line.contains($0) } }
            .map { $0.lowercased() }
        for (needle, name) in [("easyanticheat", "Easy Anti-Cheat"), ("beservice", "BattlEye"), ("battleye", "BattlEye"),
                               ("vgk.sys", "Riot Vanguard"), ("riot vanguard", "Riot Vanguard")]
        where loads.contains(where: { $0.contains(needle) }) {
            return Diagnosis(cause: .antiCheat(name))
        }
        // What Wine's HLSL compiler (vkd3d-shader) says when a program hands it something it doesn't know yet, as
        // the program passes it on: "…D3DCompile error (Not implemented…): …: E5017: Aborting due to not yet
        // implemented feature: Shader model 5.1+ resource array." Not once Microsoft's compiler is in the bottle.
        if !installed(.d3dcompiler47), lower.contains("e5017: aborting due to not yet implemented feature") {
            return Diagnosis(cause: .shaderCompiler)
        }
        // Not in a bottle that has Microsoft's .NET already: the advice would be to install what is there.
        if !installed(.dotnet48),
           lower.contains("fatal unhandled exception: system.") || lines.contains(where: { $0.contains("err:mscoree:") }) {
            return Diagnosis(cause: .dotNet)
        }
        // wine: Unhandled page fault on read access to … / wine: Unhandled exception 0x… in thread …
        if lines.contains(where: { $0.hasPrefix("wine: Unhandled ") || $0.contains(":wine: Unhandled ") }) {
            return Diagnosis(cause: .crashed)
        }
        return nil
    }

    /// `text` as Wine's log prints a string (`wine_dbgstr_wn` in Wine's include/wine/debug.h): in `L"…"`, with
    /// backslash, quote, newline, return and tab escaped, every other character outside printable ASCII as a
    /// backslash and its four hex digits (per UTF-16 unit), and cut with `...` once about 290 characters are out.
    static func wineDebugString(_ text: String) -> String {
        var out = "L\""
        var left = text.utf16.count
        for unit in text.utf16 {
            // Wine counts the character it stops at as written: one left over is dropped without the dots.
            left -= 1
            guard out.utf8.count <= 290 else { break }
            switch unit {
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x20..<0x7f: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: out += "\\" + String(format: "%04x", unit)
            }
        }
        return out + "\"" + (left > 0 ? "..." : "")
    }

    /// A log's text for `analyze`, read lossily (Windows programs print in their own code pages). Of a log larger
    /// than two `portion`s only the first and the last one are read: a program that can't load says so at its
    /// start and a crash is the last thing in the log, while a game that prints an error per frame for hours
    /// writes gigabytes in between. A megabyte each is thousands of lines.
    static func text(ofLog log: URL, portion: Int = 1 << 20) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2 * portion)) ?? Data()
        guard head.count == 2 * portion, let size = try? handle.seekToEnd(), size > UInt64(2 * portion),
              (try? handle.seek(toOffset: size - UInt64(portion))) != nil else { return String(decoding: head, as: UTF8.self) }
        let tail = (try? handle.readToEnd()) ?? Data()
        return String(decoding: head.prefix(portion), as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }
}

extension Bottle {
    /// The newest log written for a launch labelled exactly `label` (see `newLog(label:)`).
    public func latestLog(label: String) -> URL? {
        // <yyyyMMdd-HHmmss>[.n]-<label>.log, newest first
        let name = "-" + Self.logLabel(label)
        return logs().first { file in
            var rest = file.deletingPathExtension().lastPathComponent.dropFirst(15)
            if rest.hasPrefix(".") { rest = rest.dropFirst().drop(while: \.isNumber) }
            return rest == name
        }
    }

    /// What went wrong in the last run labelled `label`, and the log that says so. For a run whose own log is
    /// known (`WineExit.log`) use `diagnosis(ofLog:)`: the newest log by label can be another launch's.
    public func diagnosis(forLatestRunOf label: String, program: String? = nil) -> (diagnosis: Diagnosis, log: URL)? {
        guard let log = latestLog(label: label), let diagnosis = diagnosis(ofLog: log, program: program) else { return nil }
        return (diagnosis, log)
    }

    /// What went wrong in the run that wrote `log`. Reads the log (its start and end, if it is large) and which
    /// components the bottle has, so call it off the main actor.
    public func diagnosis(ofLog log: URL, program: String? = nil) -> Diagnosis? {
        Diagnosis.analyze(Diagnosis.text(ofLog: log), program: program, installed: { $0.isInstalled(in: self) })
    }
}
