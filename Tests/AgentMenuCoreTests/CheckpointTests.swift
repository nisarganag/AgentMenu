import Testing
import Foundation
@testable import AgentMenuCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ckpt-\(UUID().uuidString).json")
}

private let now = Date(timeIntervalSince1970: 1_755_689_400)

@Test func roundTripsOffsetsAndNotifiedKeys() throws {
    let store = CheckpointStore(url: tempURL())
    try store.save(Checkpoint(fileOffsets: ["/a.jsonl": 4096],
                              notifiedKeys: ["perm/s1": now]))
    let loaded = store.load()
    #expect(loaded.fileOffsets["/a.jsonl"] == 4096)
    #expect(loaded.notifiedKeys["perm/s1"]?.timeIntervalSince1970 == now.timeIntervalSince1970)
}

@Test func missingFileLoadsAnEmptyCheckpointRatherThanThrowing() {
    #expect(CheckpointStore(url: tempURL()).load() == Checkpoint())
}

@Test func corruptFileLoadsEmptyRatherThanCrashingTheApp() throws {
    let url = tempURL()
    try "{ not json".write(to: url, atomically: true, encoding: .utf8)
    #expect(CheckpointStore(url: url).load() == Checkpoint())
}

@Test func pruningDropsDedupeKeysOlderThanTheStalenessWindow() {
    let c = Checkpoint(fileOffsets: [:], notifiedKeys: [
        "old": now.addingTimeInterval(-3600),
        "new": now.addingTimeInterval(-10),
    ])
    let pruned = c.pruned(before: now.addingTimeInterval(-SpoolWatcher.stalenessWindow))
    #expect(Array(pruned.notifiedKeys.keys) == ["new"])
}

@Test func saveIsAtomicSoAPartialWriteCannotBeLoaded() throws {
    let url = tempURL()
    let store = CheckpointStore(url: url)
    try store.save(Checkpoint(fileOffsets: ["/a": 1], notifiedKeys: [:]))
    try store.save(Checkpoint(fileOffsets: ["/b": 2], notifiedKeys: [:]))
    #expect(store.load().fileOffsets == ["/b": 2])
    // No temp files left behind.
    let siblings = try FileManager.default.contentsOfDirectory(
        atPath: url.deletingLastPathComponent().path)
    #expect(!siblings.contains { $0.hasSuffix(".agentmenu-tmp") })
}
