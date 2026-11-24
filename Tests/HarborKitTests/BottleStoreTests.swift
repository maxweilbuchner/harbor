import Foundation
import Testing
@testable import HarborKit

@Suite struct BottleStoreTests {
    let fm = FileManager.default

    /// Two adds of one program at the same moment get a bottle each, never one folder between them (#58).
    @Test func concurrentCreatesOfOneNameGetDifferentFolders() async throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-store-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: store.directory) }
        let roots = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<64 { group.addTask { try store.create(name: "Same Name").root.lastPathComponent } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(roots).count == 64)
        #expect(Set(roots) == Set(["same-name"] + (2...64).map { "same-name-\($0)" }))
        #expect(store.scan().bottles.count == 64 && store.scan().damaged.isEmpty)
    }

    /// A create whose setup fails takes its own folder away again, and nobody else's.
    @Test func aFailedSetupRemovesOnlyItsOwnFolder() async throws {
        let store = BottleStore(directory: fm.temporaryDirectory.appending(path: "harbor-store-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: store.directory) }
        struct SetupFailed: Error {}
        let first = try store.create(name: "Thing")
        await #expect(throws: SetupFailed.self) {
            _ = try await store.create(name: "Thing") { second in
                #expect(second.root.lastPathComponent == "thing-2")
                throw SetupFailed()
            }
        }
        #expect(store.list().map(\.root.lastPathComponent) == ["thing"])
        #expect(fm.fileExists(atPath: first.settingsFile.path))
        // Something that isn't a bottle sits where the next one would go: it is left alone.
        try Data("mine".utf8).write(to: store.directory.appending(path: "thing-2"))
        #expect(try store.create(name: "Thing").root.lastPathComponent == "thing-3")
        #expect(try Data(contentsOf: store.directory.appending(path: "thing-2")) == Data("mine".utf8))
    }
}
