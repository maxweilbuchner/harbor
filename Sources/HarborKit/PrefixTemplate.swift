import Foundation

/// A pre-built Wine prefix that new bottles clone instead of running `wineboot --init` (about 25 s) when a
/// program is dropped. Cloning is APFS copy-on-write: under a second, no extra disk until files change.
///
/// One template per runtime build, under `~/Library/Application Support/Harbor/Templates/<fingerprint>/`,
/// built in the background once Windows support is installed. Built like the runtime cache: a lock file, a
/// unique staging folder carrying its completion marker, an atomic rename.
public struct PrefixTemplate: Sendable {
    public let launcher: WineLauncher
    public let directory: URL

    public init(launcher: WineLauncher, directory: URL = PrefixTemplate.defaultDirectory) {
        self.launcher = launcher
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Harbor/Templates")
    }

    /// Keyed on the Wine build, so a runtime update never pairs an old prefix with new Wine files.
    var root: URL {
        let runtime = launcher.runtime
        let key = D3DMetalRedist.fingerprint(of: [runtime.wine, runtime.root.appending(path: "lib/wine/x86_64-unix/ntdll.so")])
        return directory.appending(path: key)
    }

    var prefix: URL { root.appending(path: "prefix") }

    public var isReady: Bool { D3DMetalRedist.isComplete(root) }

    /// Locked (shared) by every build for as long as it runs. The staging prefix is in no `BottleStore`, so this
    /// is what tells a switch of the runtime that Wine is running from it (`isBeingBuilt`). A lock, not a note
    /// with a process number: it is gone with the process that held it, however that ended.
    static let buildLock = ".building"

    /// Whether a template is being built in `directory`: some process holds the build lock, or a build whose
    /// process is gone (Harbor was quit) still has Wine running in its staging prefix. Part of "nothing is
    /// running" before the runtime is switched. A build that hangs counts for as long as its process lives; it
    /// delays the switch, never a program's start. (So does, for a moment after a build, a child process that
    /// was being started as it ended: until it has become its program it holds a copy of the lock.)
    public static func isBeingBuilt(in directory: URL = defaultDirectory, serverDirectory: String? = nil) -> Bool {
        let fd = open(directory.appending(path: buildLock).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains { name in
            guard name.hasPrefix(".staging-") else { return false }
            let bottle = Bottle(root: directory.appending(path: name), settings: BottleSettings(name: "Template"))
            return serverDirectory.map { bottle.isRunning(serverDirectory: $0) } ?? bottle.isRunning()
        }
    }

    /// Builds the template if it doesn't exist yet. Safe to call repeatedly and from several processes.
    /// `mayStart` is asked once the build lock is held and can call the build off (a switch of the runtime has
    /// begun): whichever of the two comes second sees the other.
    public func prepare(mayStart: () async -> Bool = { true }) async throws {
        if isReady { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not inherited: a program started meanwhile would hold the lock for as long as it runs.
        let lock = open(directory.appending(path: Self.buildLock).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory.path]) }
        defer { close(lock) }      // closing gives the lock up
        guard flock(lock, LOCK_SH) == 0 else { throw CocoaError(.fileLocking) }
        guard await mayStart() else { return }
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)")
        // A throwaway bottle around the staging prefix, so the normal setup path does the work.
        let bottle = Bottle(root: staging, settings: BottleSettings(name: "Template"))
        do {
            try bottle.save()
            try await launcher.initialize(bottle)
            // Let wineserver write the registry and exit before the files are cloned.
            try await launcher.waitForShutdown(bottle)
            try Data().write(to: staging.appending(path: D3DMetalRedist.markerName))
            try withLock(directory.appending(path: ".lock")) {
                if isReady { try? fm.removeItem(at: staging); return }
                if fm.fileExists(atPath: root.path) {
                    try fm.moveItem(at: root, to: directory.appending(path: ".stale-\(UUID().uuidString)"))
                }
                try fm.moveItem(at: staging, to: root)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Gives `bottle` a prefix cloned from the template, with its own machine ID and Windows version.
    /// Returns false (and does nothing) if the template isn't ready.
    public func clone(into bottle: Bottle) throws -> Bool {
        guard isReady else { return false }
        try FileManager.default.copyItem(at: prefix, to: bottle.prefix)      // clonefile(2) on APFS
        let system = bottle.prefix.appending(path: "system.reg")
        if var text = try? String(contentsOf: system, encoding: .utf8),
           let range = text.range(of: #""MachineGuid"="[0-9a-fA-F-]+""#, options: .regularExpression) {
            text.replaceSubrange(range, with: "\"MachineGuid\"=\"\(UUID().uuidString.lowercased())\"")
            try text.write(to: system, atomically: true, encoding: .utf8)
        }
        if bottle.settings.windowsVersion != BottleSettings(name: "").windowsVersion {
            Self.setWindowsVersion(bottle.settings.windowsVersion.rawValue, in: bottle.prefix)
        }
        bottle.applyMacFilesAccess()         // templates from before this setting still carry drive Z:
        return true
    }

    /// Edits `[Software\\Wine]` "Version" in user.reg directly (no wineserver is running for a fresh clone).
    static func setWindowsVersion(_ version: String, in prefix: URL) {
        let user = prefix.appending(path: "user.reg")
        guard var text = try? String(contentsOf: user, encoding: .utf8) else { return }
        if let range = text.range(of: #"(?m)^"Version"="[^"]*"$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "\"Version\"=\"\(version)\"")
            try? text.write(to: user, atomically: true, encoding: .utf8)
        }
    }
}

extension WineLauncher {
    /// Sets up a new bottle's prefix: from the template when it's ready (under a second), otherwise the full
    /// `wineboot --init` (about 25 s).
    public func initialize(_ bottle: Bottle, template: PrefixTemplate?) async throws {
        if let template, try template.clone(into: bottle) { return }
        try await initialize(bottle)
    }

    /// Waits until the bottle's wineserver has exited (it saves the registry on the way out).
    public func waitForShutdown(_ bottle: Bottle) async throws {
        let process = Process()
        process.executableURL = runtime.wineserver
        process.arguments = ["-w"]
        process.environment = environment(for: bottle, runtime: runtime)
        try await process.runUntilExit()
    }
}

extension Bottle {
    /// Whether Wine will update this bottle's Windows files on its next start (20–30 s, silently): wineboot does
    /// so when `prefix/.update-timestamp` differs from the runtime's `share/wine/wine.inf` modification time
    /// (programs/wineboot/wineboot.c, update_wineprefix). "disable" turns that off.
    public func needsWindowsUpdate(for runtime: WineRuntime) -> Bool {
        guard let stamp = try? String(contentsOf: prefix.appending(path: ".update-timestamp"), encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: prefix.path)   // a prefix without a stamp gets updated
        }
        if stamp.hasPrefix("disable") { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: runtime.root.appending(path: "share/wine/wine.inf").path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        let recorded = UInt64(stamp.prefix { $0.isNumber }) ?? 0
        return recorded != UInt64(modified.timeIntervalSince1970)
    }
}

extension Bottle {
    /// Whether a Wine session is running for this bottle: its wineserver holds a write lock on
    /// `<tmp>/.wine-<uid>/server-<dev>-<inode>/lock` (server/request.c, dlls/ntdll/unix/server.c). Only asks
    /// about the lock, so it never starts or disturbs a server.
    public func isRunning(serverDirectory base: String = "/tmp/.wine-\(getuid())") -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let lock = "\(base)/server-\(String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))/lock"
        let fd = open(lock, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var query = flock()
        query.l_type = Int16(F_WRLCK)
        query.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &query) != -1 else { return false }
        return query.l_type != Int16(F_UNLCK)
    }
}

extension Bottle {
    /// Replaces links from the Windows user folders (`drive_c/users/*/Documents` etc.) to anywhere outside the
    /// bottle with empty folders, so programs can't reach the Mac's own Documents, Downloads, Pictures… Wine used to
    /// create those links for every new prefix (Harbor's Wine patch 0007 stops that); this migrates older bottles.
    /// Only the links are removed, never what they point to. Returns the folders it replaced.
    @discardableResult
    public func unshareUserFolders() -> [URL] {
        let fm = FileManager.default
        let users = driveC.appending(path: "users")
        let inside = prefix.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var replaced: [URL] = []
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            // The user's folders, and what's on the Windows Desktop: Wine put a "My Mac Desktop" link there.
            for folder in [user, user.appending(path: "Desktop")] {
                for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
                    let resolved = URL(filePath: target, relativeTo: folder).standardizedFileURL.resolvingSymlinksInPath().path
                    guard !resolved.hasPrefix(inside) else { continue }
                    // removeItem on a link deletes the link itself, not its target.
                    guard (try? fm.removeItem(at: entry)) != nil,
                          (try? fm.createDirectory(at: entry, withIntermediateDirectories: false)) != nil else { continue }
                    replaced.append(entry)
                }
            }
        }
        return replaced
    }
}

extension WineLauncher {
    /// Brings a bottle's Windows files up to date with the runtime (what Wine would otherwise do silently on the
    /// next program start) and waits for it. `-r` skips the bottle's autostart entries (wineboot otherwise runs the
    /// Run keys too: Steam's would start Steam on the wrong runtime and keep wineserver, and this wait, alive).
    public func updateWindows(_ bottle: Bottle) async throws {
        try await execute(bottle, arguments: ["wineboot", "-u", "-r"], label: "update")
        try await waitForShutdown(bottle)
    }
}
