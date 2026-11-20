import Foundation

/// Recognising the Mac processes of the Windows programs Harbor runs, so Harbor can bring a program it just
/// started to the front.
public enum WineApps {
    /// Whether `executable` is a process of one of Harbor's Wine runtimes (under one of `runtimes`).
    ///
    /// Wine starts each process through a link to its loader named after the program, in
    /// `$TMPDIR/winetemp-…/<Program name>` (Wine patch 0006), so the executable itself is rarely inside the
    /// runtime. That folder holds a symlink to the runtime's `ntdll.so`, which tells Harbor's Wine apart from
    /// another Wine on this Mac (CrossOver uses the same folders).
    public static func isHarborWine(executable: URL, runtimes: [URL],
                                    resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() }) -> Bool {
        let folder = executable.deletingLastPathComponent()
        let file = folder.lastPathComponent.hasPrefix("winetemp-") ? resolve(folder.appending(path: "ntdll.so")) : resolve(executable)
        let path = file.standardizedFileURL.pathComponents
        return runtimes.contains { path.starts(with: resolve($0).standardizedFileURL.pathComponents) }
    }

    /// When the process started. `NSRunningApplication.launchDate` is nil for Wine's processes (LaunchServices
    /// didn't launch them), so this asks the kernel.
    public static func startDate(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}
