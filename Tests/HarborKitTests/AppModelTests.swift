import Foundation
import Testing
@testable import HarborKit

@Suite struct WineAppsTests {
    let fm = FileManager.default
    let runtimes = [URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes"),
                    URL(filePath: "/Users/me/Library/Application Support/Harbor/Installed")]

    @Test func recognisesProgramsStartedThroughALoaderLink() {
        // What Wine's loader link folder holds: a symlink to the runtime's ntdll.so next to the program's link.
        let harbor: (URL) -> URL = { url in
            url.lastPathComponent == "ntdll.so" && url.path.contains("winetemp-")
                ? URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes/d3dmetal-4.0b3-ed28/lib/wine/x86_64-unix/ntdll.so") : url
        }
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                      runtimes: runtimes, resolve: harbor))
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/private/var/folders/x/T/winetemp-1-2-3-4/Wine Explorer"),
                                      runtimes: runtimes, resolve: harbor))
        // Another Wine's loader links (CrossOver uses the same folder names) aren't Harbor's.
        let other: (URL) -> URL = { url in
            url.lastPathComponent == "ntdll.so" ? URL(filePath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so") : url
        }
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                       runtimes: runtimes, resolve: other))
        // A link folder without the ntdll.so symlink.
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/var/folders/x/T//winetemp-1-2-3-4/Steam"),
                                       runtimes: runtimes, resolve: { $0 }))
    }

    @Test func recognisesProcessesRunFromTheRuntimeItself() {
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Installed/wine/bin/wine"),
                                      runtimes: runtimes, resolve: { $0 }))
        #expect(WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes/dxmt-1/bin/wineserver"),
                                      runtimes: runtimes, resolve: { $0 }))
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/Applications/Safari.app/Contents/MacOS/Safari"),
                                       runtimes: runtimes, resolve: { $0 }))
        // A sibling folder that merely starts with a runtime folder's name.
        #expect(!WineApps.isHarborWine(executable: URL(filePath: "/Users/me/Library/Application Support/Harbor/Runtimes-old/bin/wine"),
                                       runtimes: runtimes, resolve: { $0 }))
    }

    @Test func followsTheLoaderLinkFoldersSymlinkOnDisk() throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-wineapps-\(UUID().uuidString)")
        let unix = root.appending(path: "Runtimes/d3dmetal-1/lib/wine/x86_64-unix")
        let links = root.appending(path: "T/winetemp-1-2-3-4"), foreign = root.appending(path: "T/winetemp-5-6-7-8")
        for dir in [unix, links, foreign, root.appending(path: "Elsewhere")] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for file in [unix.appending(path: "ntdll.so"), root.appending(path: "Elsewhere/ntdll.so"),
                     links.appending(path: "Portal 2"), foreign.appending(path: "Portal 2")] { try Data().write(to: file) }
        try fm.createSymbolicLink(at: links.appending(path: "ntdll.so"), withDestinationURL: unix.appending(path: "ntdll.so"))
        try fm.createSymbolicLink(at: foreign.appending(path: "ntdll.so"), withDestinationURL: root.appending(path: "Elsewhere/ntdll.so"))
        let runtimes = [root.appending(path: "Runtimes")]
        #expect(WineApps.isHarborWine(executable: links.appending(path: "Portal 2"), runtimes: runtimes))
        #expect(!WineApps.isHarborWine(executable: foreign.appending(path: "Portal 2"), runtimes: runtimes))
    }

    @Test func readsAProcessStartTimeFromTheKernel() throws {
        let before = Date()
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let started = try #require(WineApps.startDate(of: child.processIdentifier))
        #expect(started >= before.addingTimeInterval(-1) && started <= Date().addingTimeInterval(1))
        // This test process started before its child.
        #expect(try #require(WineApps.startDate(of: ProcessInfo.processInfo.processIdentifier)) <= started)
        #expect(WineApps.startDate(of: 99_999_999) == nil)
    }
}
