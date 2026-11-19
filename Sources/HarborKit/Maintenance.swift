import Foundation

/// Removes derived runtimes and prefix templates that no longer match the installed Wine, plus leftover
/// `.stale-*`/`.staging-*` folders. Never touches anything a running process is using.
public enum Maintenance {
    /// Returns the folders it removed. `inUse` lists executable paths of running processes (injectable for tests).
    @discardableResult
    public static func collectGarbage(launcher: WineLauncher, runtimesDirectory: URL = WineLauncher.defaultRuntimesDirectory,
                                      templatesDirectory: URL = PrefixTemplate.defaultDirectory,
                                      inUse: [String]? = nil) -> [URL] {
        let fm = FileManager.default
        let running = inUse ?? runningExecutables()
        var keep = Set<String>()
        if let d3dmetal = launcher.d3dmetal {
            keep.insert(d3dmetal.runtimeName(basedOn: launcher.runtime))
        }
        keep.insert(PrefixTemplate(launcher: launcher, directory: templatesDirectory).root.lastPathComponent)

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

    /// Executable paths of this user's running processes.
    static func runningExecutables() -> [String] {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-x", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return ["/"] }        // unknown: treat everything as in use
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
