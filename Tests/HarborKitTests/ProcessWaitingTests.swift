import Foundation
import Testing
@testable import HarborKit

@Suite struct ProcessWaitingTests {
    func tool(_ path: String, _ args: [String] = []) -> Process {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        return p
    }

    /// Children that exit at once, waited for from many dispatch worker threads at the same time: the situation in
    /// which `waitUntilExit()` was seen to hang. Every wait must return, with the right status.
    @Test(.timeLimit(.minutes(1))) func neverMissesAChildThatExitsAtOnce() async throws {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for n in 0..<200 {
                group.addTask {
                    let p = self.tool(n % 2 == 0 ? "/usr/bin/true" : "/usr/bin/false")
                    if n % 4 < 2 { try p.runAndWait() } else { try await p.runUntilExit() }
                    return p.terminationStatus
                }
            }
            var statuses: [Int32: Int] = [:]
            for try await status in group { statuses[status, default: 0] += 1 }
            #expect(statuses == [0: 100, 1: 100])
        }
    }

    @Test func aToolThatCantStartThrowsInsteadOfWaiting() async {
        #expect(throws: (any Error).self) { try self.tool("/nonexistent/tool").runAndWait() }
        await #expect(throws: (any Error).self) { try await self.tool("/nonexistent/tool").runUntilExit() }
    }
}
