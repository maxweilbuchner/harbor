import Foundation
import os
import Testing
@testable import HarborKit

/// The published list and its signature are replaced one after the other. A check in between sees a pair that
/// doesn't match; it looks once more before it says the list isn't Harbor's (#74).
@Suite struct ManifestRetryTests {
    let fm = FileManager.default
    let updates = RuntimeUpdateTests()

    /// A served folder as it is in the middle of a publish: the new list (sequence 200) under the signature of
    /// the previous one. Returns the list's URL and the signature that belongs to it.
    func halfPublished(in root: URL) throws -> (list: URL, signature: Data) {
        let old = try updates.serve([("wine", "1", "wine v1")], sequence: 100, in: root)
        let new = try updates.serve([("wine", "2", "wine v2")], sequence: 200, in: root)
        let signature = try Data(contentsOf: new.appendingPathExtension("sig"))
        try Data(contentsOf: old.appendingPathExtension("sig")).write(to: new.appendingPathExtension("sig"))
        return (new, signature)
    }

    @Test func aListSeenBetweenItsTwoUploadsIsFetchedOnceMore() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-retry-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let (list, signature) = try halfPublished(in: root)
        let inst = try updates.installer(list, installed: root.appending(path: "installed"))
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        // The publish finishes during the pause: the signature arrives.
        let manifest = try await inst.fetchManifest {
            pauses.withLock { $0 += 1 }
            try signature.write(to: list.appendingPathExtension("sig"))
        }
        #expect(manifest.sequence == 200 && pauses.withLock { $0 } == 1)
    }

    @Test func aListThatStillDoesntMatchItsSignatureIsRefused() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-retry-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let (list, _) = try halfPublished(in: root)
        let inst = try updates.installer(list, installed: root.appending(path: "installed"))
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: RuntimeInstallError.badSignature) {
            try await inst.fetchManifest { pauses.withLock { $0 += 1 } }
        }
        #expect(pauses.withLock { $0 } == 1)                              // one more look, not a loop
    }

    /// A list that can't be fetched at all is not a mismatch: nothing is tried again.
    @Test func aMissingListIsNotFetchedAgain() async throws {
        let root = fm.temporaryDirectory.appending(path: "harbor-retry-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let inst = try updates.installer(root.appending(path: "runtime.json"), installed: root.appending(path: "installed"))
        await #expect(throws: (any Error).self) {
            try await inst.fetchManifest { Issue.record("paused for a list that isn't there") }
        }
    }
}
