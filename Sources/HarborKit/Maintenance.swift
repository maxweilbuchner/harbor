import Foundation

/// Removes derived runtimes and prefix templates that no longer match the installed Wine, plus leftover
/// `.stale-*`/`.staging-*` folders. Never touches anything a running process is using.
public enum Maintenance {
    /// Returns the folders it removed: none while Windows runs in any bottle, or when the running processes can't
    /// be listed. Wine rewrites its processes' titles (`C:\…\steam.exe`), so nothing tells which derived runtime a
    /// running program was started from. `bottleRunning` and `inUse` (executable paths of running processes, nil
    /// when unknown) are injectable for tests.
    @discardableResult
    public static func collectGarbage(launcher: WineLauncher, runtimesDirectory: URL = WineLauncher.defaultRuntimesDirectory,
                                      templatesDirectory: URL = PrefixTemplate.defaultDirectory,
                                      bottleRunning: Bool? = nil,
                                      inUse: (() -> [String]?)? = nil) -> [URL] {
        let fm = FileManager.default
        guard !(bottleRunning ?? BottleStore.default.list().contains { $0.isRunning() }),
              let running = (inUse ?? { runningExecutables() })() else { return [] }
        var keep = Set<String>()
        if let d3dmetal = launcher.d3dmetal {
            keep.insert(d3dmetal.runtimeName(basedOn: launcher.runtime))
        }
        if let dxmt = launcher.dxmt {
            keep.insert(dxmt.runtimeName(basedOn: launcher.runtime))
        }
        keep.insert(PrefixTemplate(launcher: launcher, directory: templatesDirectory).root.lastPathComponent)
        // A build holds its lock on this file; removed, the next look would find no file and no build.
        keep.insert(PrefixTemplate.buildLock)

        var removed: [URL] = []
        for directory in [runtimesDirectory, templatesDirectory] {
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name != ".lock" && !keep.contains(name) {
                let url = directory.appending(path: name)
                let path = url.standardizedFileURL.path + "/"
                // Leftovers younger than an hour may belong to a build in progress.
                if name.hasPrefix(".staging-"),
                   let age = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date).map({ Date().timeIntervalSince($0) }),
                   age < 3600 { continue }
                guard !running.contains(where: { $0.hasPrefix(path) }) else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
            }
        }
        return removed
    }

    /// Executable paths of this user's running processes (Wine's own show up only as its wineservers and
    /// whatever kept its title), or nil when they can't be listed.
    static func runningExecutables(ps tool: String = "/bin/ps") -> [String]? {
        let ps = Process()
        ps.executableURL = URL(filePath: tool)
        ps.arguments = ["-x", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard let wait = try? ps.start() else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        wait()
        guard ps.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
