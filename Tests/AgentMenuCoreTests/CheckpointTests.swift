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

// MARK: - Feature 2: observed rate-limit ceilings

@Test func decodesAnOldCheckpointMissingRateLimitFieldsWithoutLosingExistingData() throws {
    // Simulates a checkpoint written by a build before Feature 2 existed —
    // it simply has no `observedCeilings`/`lastRateLimitObservedAt` keys.
    // Decoding must not throw and, critically, must not silently lose the
    // OTHER real persisted data (`notifiedKeys` in particular).
    let json = #"{"fileOffsets":{"/a.jsonl":10},"notifiedKeys":{"perm/s1":800000000.0}}"#
        .data(using: .utf8)!
    let c = try JSONDecoder().decode(Checkpoint.self, from: json)
    #expect(c.fileOffsets["/a.jsonl"] == 10)
    #expect(c.notifiedKeys.keys.contains("perm/s1"),
            "an old checkpoint's real data must survive decoding the new fields")
    #expect(c.observedCeilings.isEmpty)
    #expect(c.lastRateLimitObservedAt == nil)
}

@Test func roundTripsObservedCeilingsAndWatermark() throws {
    let store = CheckpointStore(url: tempURL())
    try store.save(Checkpoint(observedCeilings: [500, 300, 700], lastRateLimitObservedAt: now))
    let loaded = store.load()
    #expect(loaded.observedCeilings == [500, 300, 700])
    #expect(loaded.lastRateLimitObservedAt?.timeIntervalSince1970 == now.timeIntervalSince1970)
}

@Test func prunedPreservesObservedCeilingsAndWatermarkUntouched() {
    // `pruned(before:)` only ever filters `notifiedKeys` by staleness — a
    // regression here would silently wipe the ceiling history on every
    // checkpoint save (it runs roughly every 30s).
    let c = Checkpoint(notifiedKeys: ["old": now.addingTimeInterval(-3600)],
                       observedCeilings: [123, 456], lastRateLimitObservedAt: now)
    let pruned = c.pruned(before: now)
    #expect(pruned.observedCeilings == [123, 456])
    #expect(pruned.lastRateLimitObservedAt == now)
}

// MARK: - Round 3: transcript accumulator checkpoints (Ruling F49)

// `Int` stands in for a real parser here — `TranscriptCheckpoint.isValid`
// only ever looks at size/modifiedAt, never at `state`, so this decouples
// the validity-stamp logic from any particular parser's shape.
private func stamp(offset: UInt64 = 10, size: UInt64 = 100, modifiedAt: Date = now)
    -> TranscriptCheckpoint<Int>
{
    TranscriptCheckpoint(state: 0, offset: offset, size: size, modifiedAt: modifiedAt, version: 1)
}

@Test func transcriptCheckpointIsValidWhenSizeAndModifiedDateAreBothUnchanged() {
    #expect(stamp().isValid(currentSize: 100, currentModifiedAt: now))
}

@Test func transcriptCheckpointIsInvalidWhenTheFileShrank() {
    #expect(!stamp().isValid(currentSize: 50, currentModifiedAt: now),
            "smaller than the stamp means truncated or replaced by something shorter")
}

@Test func transcriptCheckpointIsValidWhenTheFileGrewAndMtimeAdvanced() {
    #expect(stamp().isValid(currentSize: 200, currentModifiedAt: now.addingTimeInterval(5)),
            "ordinary append-only growth must be resumable")
}

@Test func transcriptCheckpointIsInvalidWhenSameSizeButADifferentMtime() {
    #expect(!stamp().isValid(currentSize: 100, currentModifiedAt: now.addingTimeInterval(5)),
            "identical length but a moved mtime is unexplained by append-only use")
}

@Test func transcriptCheckpointIsValidWhenGrewEvenIfMtimeSomehowDidNotAdvance() {
    // Defensive corner: every real filesystem bumps mtime on a write, but if
    // one somehow didn't, pure growth (never a decrease) is still safe to
    // resume — `state` was captured at an offset strictly smaller than the
    // file's new size either way.
    #expect(stamp().isValid(currentSize: 200, currentModifiedAt: now))
}

@Test func aTranscriptEntryWithAMismatchedVersionIsDroppedNotTrusted() throws {
    // Simulates a checkpoint written by a build whose `ClaudeTranscriptParser`
    // had a different shape but would still decode structurally — the
    // explicit `v` tag must gate it out regardless, per Ruling F49 ("discard
    // and re-read, never migrate").
    var p = ClaudeTranscriptParser()
    p.consume(Data(#"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"s","cwd":"/p","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}}"#.utf8))
    let entry = TranscriptCheckpoint(state: p, offset: 10, size: 100, modifiedAt: now,
                                     version: ClaudeTranscriptParser.checkpointVersion)
    let realJSON = try JSONEncoder().encode(Checkpoint(claudeTranscripts: ["/a.jsonl": entry]))
    // Corrupt ONLY the version tag — the `state` payload is a real, validly
    // shaped encoding, so this isolates the version gate specifically.
    var text = String(data: realJSON, encoding: .utf8)!
    let currentTag = "\"v\":\(ClaudeTranscriptParser.checkpointVersion)"
    #expect(text.contains(currentTag), "test setup assumption: the version tag must appear verbatim")
    text = text.replacingOccurrences(of: currentTag, with: "\"v\":999")

    let decoded = try JSONDecoder().decode(Checkpoint.self, from: text.data(using: .utf8)!)
    #expect(decoded.claudeTranscripts.isEmpty, "a version mismatch must discard the entry outright")
}

@Test func aStructurallyMalformedTranscriptsEntryNeverWipesNotifiedKeys() throws {
    // The key EXISTS (unlike the old-build "absent key" case `observedCeilings`
    // already covers) but its value cannot decode as a `TranscriptCheckpoint`
    // at all. This must degrade to "no restorable transcripts", never
    // propagate and wipe unrelated real persisted data.
    let json = #"""
    {"notifiedKeys":{"perm/s1":800000000.0},
     "claudeTranscripts":{"/a.jsonl":{"v":"not-an-int","offset":"nope"}}}
    """#.data(using: .utf8)!
    let c = try JSONDecoder().decode(Checkpoint.self, from: json)
    #expect(c.notifiedKeys.keys.contains("perm/s1"),
            "a malformed claudeTranscripts entry must not wipe unrelated real data")
    #expect(c.claudeTranscripts.isEmpty)
}

@Test func prunedPreservesTranscriptCheckpointsUntouched() throws {
    // `pruned(before:)` only ever filters `notifiedKeys` by staleness (same
    // contract as `observedCeilings`/`lastRateLimitObservedAt` above) —
    // transcript checkpoints have their OWN validity mechanism
    // (`isValid(currentSize:currentModifiedAt:)`), checked at restore time by
    // the sources, not by staleness here.
    var p = ClaudeTranscriptParser()
    p.consume(Data(#"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"s","cwd":"/p","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}}"#.utf8))
    let entry = TranscriptCheckpoint(state: p, offset: 10, size: 100, modifiedAt: now,
                                     version: ClaudeTranscriptParser.checkpointVersion)
    let c = Checkpoint(notifiedKeys: ["old": now.addingTimeInterval(-3600)],
                       claudeTranscripts: ["/a.jsonl": entry])
    let pruned = c.pruned(before: now)
    #expect(pruned.claudeTranscripts["/a.jsonl"] == entry)
}

@Test func checkpointStoreRoundTripsATranscriptCheckpointExactly() throws {
    var p = ClaudeTranscriptParser()
    p.consume(Data(#"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"sess-1","cwd":"/Users/x/proj","gitBranch":"main","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":9}}}"#.utf8))
    let entry = TranscriptCheckpoint(state: p, offset: 42, size: 100, modifiedAt: now,
                                     version: ClaudeTranscriptParser.checkpointVersion)
    let store = CheckpointStore(url: tempURL())
    try store.save(Checkpoint(claudeTranscripts: ["/a.jsonl": entry]))

    let loaded = store.load()
    let loadedEntry = try #require(loaded.claudeTranscripts["/a.jsonl"])
    #expect(loadedEntry.offset == 42)
    #expect(loadedEntry.size == 100)
    #expect(loadedEntry.modifiedAt.timeIntervalSince1970 == now.timeIntervalSince1970)
    #expect(loadedEntry.state == p,
            "the whole accumulator — not a summary of it — must round-trip exactly")
}

@Test func saveIsAtomicSoAPartialWriteCannotBeLoaded() throws {
    let url = tempURL()
    let store = CheckpointStore(url: url)
    try store.save(Checkpoint(fileOffsets: ["/a": 1], notifiedKeys: [:]))
    try store.save(Checkpoint(fileOffsets: ["/b": 2], notifiedKeys: [:]))
    #expect(store.load().fileOffsets == ["/b": 2])
    // No temp file left behind for THIS checkpoint specifically. Checking
    // every file in the shared system temp directory (as this used to)
    // races every OTHER concurrently-running test that also saves a
    // checkpoint there under swift-testing's parallel execution — this
    // scopes the check to exactly the one sibling path `save()` itself uses.
    let ownTmp = url.appendingPathExtension("agentmenu-tmp")
    #expect(!FileManager.default.fileExists(atPath: ownTmp.path))
}
