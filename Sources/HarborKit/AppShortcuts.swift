import Foundation

/// Small Mac apps in `~/Applications/Harbor/`, one per library program, so Windows programs show up in
/// Spotlight, Launchpad, the Dock and Finder like Mac apps. Each one only opens `harbor://launch/<id>`;
/// Harbor does the launching (graphics layer, bringing the program to the front).
///
/// Shortcuts are created on this Mac and signed ad-hoc, so they carry no quarantine and Gatekeeper treats
/// them as the user's own. A marker file identifies Harbor's shortcuts; nothing else in the folder is touched.
public struct AppShortcuts: Sendable {
    public let directory: URL

    public init(directory: URL = AppShortcuts.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Harbor")
    }

    static let marker = "harbor-shortcut"
    public static func launchURL(for program: Program) -> URL { URL(string: "harbor://launch/\(program.id.uuidString)")! }

    /// Program ID → shortcut app, for the shortcuts Harbor made.
    public func existing() -> [UUID: URL] {
        var found: [UUID: URL] = [:]
        for app in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where app.pathExtension == "app" {
            if let text = try? String(contentsOf: app.appending(path: "Contents/Resources/\(Self.marker)"), encoding: .utf8),
               let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                found[id] = app
            }
        }
        return found
    }

    /// Makes every program have exactly one shortcut, and removes Harbor shortcuts whose program is gone.
    /// `icon` gives each program's PNG icon file, if it has one.
    public func sync(_ programs: [Program], icon: (Program) -> URL?) {
        var existing = existing()
        for program in programs {
            if let app = existing.removeValue(forKey: program.id) {
                // "Name.app" or a numbered twin "Name 2.app" (two programs with the same name) both match.
                let current = app.deletingPathExtension().lastPathComponent, base = Self.fileName(program.name)
                if current == base || (current.hasPrefix(base + " ") && Int(current.dropFirst(base.count + 1)) != nil) { continue }
                try? FileManager.default.removeItem(at: app)   // renamed: recreate under the new name
            }
            _ = try? create(for: program, iconPNG: icon(program))
        }
        for (_, app) in existing { try? FileManager.default.removeItem(at: app) }
    }

    @discardableResult
    public func create(for program: Program, iconPNG: URL?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var app = directory.appending(path: Self.fileName(program.name) + ".app")
        var n = 2
        while fm.fileExists(atPath: app.path) {
            app = directory.appending(path: "\(Self.fileName(program.name)) \(n).app"); n += 1
        }
        let staging = directory.appending(path: ".staging-\(UUID().uuidString).app")
        let contents = staging.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        do {
            let script = contents.appending(path: "MacOS/launch")
            // Static on purpose: names come from programs' own metadata, so nothing variable goes into a script.
            // The program ID is read from the marker file next to it.
            try """
            #!/bin/sh
            id=$(/bin/cat "$(/usr/bin/dirname "$0")/../Resources/\(Self.marker)")
            exec /usr/bin/open "harbor://launch/$id"
            """.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try Data(program.id.uuidString.utf8).write(to: contents.appending(path: "Resources/\(Self.marker)"))
            let hasIcon = iconPNG.map { Self.makeICNS(from: $0, to: contents.appending(path: "Resources/AppIcon.icns")) } ?? false
            let plist: [String: Any] = [
                "CFBundleIdentifier": "io.github.maxweilbuchner.harbor.shortcut.\(program.id.uuidString.lowercased())",
                "CFBundleName": program.name,
                "CFBundleDisplayName": program.name,
                "CFBundleExecutable": "launch",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "LSMinimumSystemVersion": "26.0",
                "LSApplicationCategoryType": program.isGame ? "public.app-category.games" : "public.app-category.utilities",
                // Just a trampoline into Harbor: no Dock icon of its own while it runs.
                "LSUIElement": true,
            ].merging(hasIcon ? ["CFBundleIconFile": "AppIcon"] : [:]) { a, _ in a }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            let sign = Process()
            sign.executableURL = URL(filePath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", staging.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            try fm.moveItem(at: staging, to: app)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return app
    }

    /// Removes the shortcut for `id`, if Harbor made one.
    public func remove(_ id: UUID) {
        if let app = existing()[id] { try? FileManager.default.removeItem(at: app) }
    }

    static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:".contains($0) ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Windows Program" : trimmed
    }

    /// Builds an .icns from a PNG with sips + iconutil (small Windows icons are scaled up).
    static func makeICNS(from png: URL, to icns: URL) -> Bool {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appending(path: "harbor-\(UUID().uuidString).iconset")
        defer { try? fm.removeItem(at: set) }
        guard (try? fm.createDirectory(at: set, withIntermediateDirectories: true)) != nil else { return false }
        func run(_ tool: String, _ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                let px = String(size * scale)
                guard run("/usr/bin/sips", ["-z", px, px, png.path, "--out", set.appending(path: name).path]) else { return false }
            }
        }
        return run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", icns.path])
    }
}
