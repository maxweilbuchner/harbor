import Foundation

/// Why a Windows program failed, in plain words, read from the log Wine wrote for that launch. Only causes that
/// can be told apart reliably are reported; anything else gets no diagnosis (the caller shows the exit code).
public struct Diagnosis: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// A DLL the program imports isn't there. `recipe` installs it when it's part of a Windows component.
        case missingLibrary(String, recipe: String?)
        case dotNet
        case antiCheat(String)
        case crashed
    }

    public let cause: Cause

    /// One or two sentences for people who don't know what a DLL is.
    public func message(for program: String) -> String {
        switch cause {
        case .missingLibrary(let dll, let recipe?):
            let component = Recipe.named(recipe)?.name ?? recipe
            return "\(program) needs Microsoft \(component), which isn’t installed for it yet (\(dll) is missing)."
        case .missingLibrary(let dll, nil):
            return "\(program) is missing a file it needs (\(dll)). It usually comes with the program’s installer: try installing the program again with its full installer."
        case .dotNet:
            return "\(program) is a .NET program and stopped inside .NET. Harbor’s built-in .NET support doesn’t cover everything it needs yet."
        case .antiCheat(let name):
            return "\(program) uses \(name) anti-cheat, which only runs on Windows itself. Games that need it can’t run in Harbor."
        case .crashed:
            return "\(program) crashed. The log has the details for a bug report."
        }
    }

    /// The component that fixes it, if any.
    public var recipe: Recipe? {
        if case .missingLibrary(_, let id?) = cause { return Recipe.named(id) }
        return nil
    }

    /// Reads a Wine log. The first recognised cause wins, most specific first.
    public static func analyze(_ log: String) -> Diagnosis? {
        let lines = log.split(whereSeparator: \.isNewline)
        // err:module:import_dll Library HarborMissing.dll (which is needed by L"…") not found
        if let line = lines.first(where: { $0.contains("err:module:import_dll Library ") && $0.hasSuffix(" not found") }),
           let start = line.range(of: "import_dll Library ")?.upperBound,
           let end = line[start...].range(of: " (which is needed by ")?.lowerBound {
            let dll = String(line[start..<end])     // may contain spaces
            let base = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
            return Diagnosis(cause: .missingLibrary(dll, recipe: Recipe.all.first { $0.overrides.contains(base) }?.id))
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
        if lower.contains("fatal unhandled exception: system.") || lines.contains(where: { $0.contains("err:mscoree:") }) {
            return Diagnosis(cause: .dotNet)
        }
        // wine: Unhandled page fault on read access to … / wine: Unhandled exception 0x… in thread …
        if lines.contains(where: { $0.hasPrefix("wine: Unhandled ") || $0.contains(":wine: Unhandled ") }) {
            return Diagnosis(cause: .crashed)
        }
        return nil
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

    /// What went wrong in the last run labelled `label`, and the log that says so. Reads the log lossily (Windows
    /// programs print in their own code pages) and touches nothing else, so call it off the main actor.
    public func diagnosis(forLatestRunOf label: String) -> (diagnosis: Diagnosis, log: URL)? {
        guard let log = latestLog(label: label), let data = try? Data(contentsOf: log),
              let diagnosis = Diagnosis.analyze(String(decoding: data, as: UTF8.self)) else { return nil }
        return (diagnosis, log)
    }
}
