import Foundation
import os
import Testing
@testable import HarborKit

/// The template build runs Wine in a prefix that is in no bottle store. "Nothing is running", asked before the
/// runtime is switched, has to see it all the same (#53).
@Suite struct TemplateBuildTests {
    let fm = FileManager.default

    /// A template whose "wine" sets up a prefix for `wineboot`, after waiting for `bin/go` if `waits`. The wait
    /// ends by itself (its folder is gone, or a minute has passed). Remove `base` at the end.
    func fixture(waits: Bool) throws -> (template: PrefixTemplate, base: URL, bin: URL) {
        let base = fm.temporaryDirectory.appending(path: "harbor-tplbuild-\(UUID().uuidString)").resolvingSymlinksInPath()
        let bin = base.appending(path: "wine/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let wait = waits ? #"n=0; while [ ! -f "$BIN/go" ] && [ -d "$BIN" ] && [ $n -lt 1200 ]; do sleep 0.05; n=$((n+1)); done"# : ""
        let wine = """
        #!/bin/sh
        BIN="$(dirname "$0")"
        case "$1" in
        wineboot) touch "$BIN/started"
        \(wait)
        mkdir -p "$WINEPREFIX/drive_c/windows" "$WINEPREFIX/dosdevices";;
        esac
        """
        for (name, script) in [("wine", wine), ("wineserver", "#!/bin/sh\nexit 0\n")] {
            try script.write(to: bin.appending(path: name), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: name).path)
        }
        let launcher = WineLauncher(runtime: WineRuntime(root: base.appending(path: "wine")),
                                    runtimesDirectory: base.appending(path: "runtimes"))
        return (PrefixTemplate(launcher: launcher, directory: base.appending(path: "templates")), base, bin)
    }

    func building(_ template: PrefixTemplate, _ base: URL) -> Bool {
        PrefixTemplate.isBeingBuilt(in: template.directory, serverDirectory: base.appending(path: "servers").path)
    }

    /// Whether the build lock is free again after a build. Asked until it is (for ten seconds at most): a
    /// process that another test starts at that moment holds a copy of every open file until it has become its
    /// program, the lock's among them.
    func ended(_ template: PrefixTemplate, _ base: URL) async throws -> Bool {
        for _ in 0..<1000 where building(template, base) { try await Task.sleep(for: .milliseconds(10)) }
        return !building(template, base)
    }

    @Test(.timeLimit(.minutes(1))) func aBuildCountsAsRunningUntilItHasEnded() async throws {
        let f = try fixture(waits: true)
        defer { try? fm.removeItem(at: f.base) }
        #expect(!building(f.template, f.base))                             // no templates folder yet
        let template = f.template
        let build = Task { try await template.prepare() }
        for _ in 0..<1000 where !fm.fileExists(atPath: f.bin.appending(path: "started").path) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(fm.fileExists(atPath: f.bin.appending(path: "started").path), "the build never started Wine")
        #expect(building(f.template, f.base))
        // Tidying up meanwhile leaves the lock where the next look finds it.
        Maintenance.collectGarbage(launcher: f.template.launcher, runtimesDirectory: f.base.appending(path: "runtimes"),
                                   templatesDirectory: f.template.directory, bottleRunning: false, inUse: { [] })
        #expect(building(f.template, f.base))
        try Data().write(to: f.bin.appending(path: "go"))
        try await build.value
        #expect(f.template.isReady)
        #expect(try await ended(f.template, f.base))
    }

    /// A switch that began first: the build asks once it holds the lock, and doesn't start Wine.
    @Test func aBuildThatMayNotStartRunsNothing() async throws {
        let f = try fixture(waits: false)
        defer { try? fm.removeItem(at: f.base) }
        let (template, base) = (f.template, f.base)
        let seenWhileAsked = OSAllocatedUnfairLock(initialState: false)
        try await template.prepare {
            let seen = building(template, base)
            seenWhileAsked.withLock { $0 = seen }
            return false
        }
        // The switch's own look, had it come at that moment, would have found the build.
        #expect(seenWhileAsked.withLock { $0 })
        #expect(!fm.fileExists(atPath: f.bin.appending(path: "started").path))
        #expect(!f.template.isReady)
        #expect(try await ended(f.template, f.base))
        #expect(!(try fm.contentsOfDirectory(atPath: f.template.directory.path)).contains { $0.hasPrefix(".staging-") })
        // Allowed, it builds.
        try await f.template.prepare { true }
        #expect(f.template.isReady)
        #expect(try await ended(f.template, f.base))
    }

    /// Harbor was quit during a build: nobody holds the lock, but Wine still runs in the staging prefix.
    @Test func aBuildLeftRunningByAProcessThatIsGoneStillCounts() throws {
        let f = try fixture(waits: false)
        defer { try? fm.removeItem(at: f.base) }
        let staging = f.template.directory.appending(path: ".staging-\(UUID().uuidString)")
        let prefix = Bottle(root: staging, settings: BottleSettings(name: "Template")).prefix
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: f.template.directory.appending(path: PrefixTemplate.buildLock))
        let servers = f.base.appending(path: "servers").path
        let attrs = try fm.attributesOfItem(atPath: prefix.path)
        let dir = "\(servers)/server-\(String(attrs[.systemNumber] as! Int, radix: 16))-\(String(attrs[.systemFileNumber] as! UInt64, radix: 16))"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data().write(to: URL(filePath: "\(dir)/lock"))
        #expect(!building(f.template, f.base))                             // a leftover folder, nothing running in it

        // Another process takes the lock the way wineserver does (fcntl F_SETLK, write lock).
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)", "\(dir)/lock"]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { holder.terminate() }
        _ = pipe.fileHandleForReading.availableData                      // waits for "locked"
        #expect(building(f.template, f.base))
    }
}
