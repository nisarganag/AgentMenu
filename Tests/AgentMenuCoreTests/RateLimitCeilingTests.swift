import Testing
import Foundation
@testable import AgentMenuCore

private let now = Date(timeIntervalSince1970: 1_755_689_400)

@Test func recordsANewCeilingWhenARateLimitTimestampAdvances() {
    let hit = now.addingTimeInterval(-1)   // 1s ago: fresh
    let result = RateLimitCeiling.recording(
        rateLimitTimestamps: [hit], now: now, burn5h: 42_000,
        previous: (ceilings: [], lastAt: nil))
    #expect(result.ceilings == [42_000])
    #expect(result.lastAt == hit)
}

@Test func doesNotReRecordTheSameRateLimitTimestampTwice() {
    // The parser never clears `lastRateLimitAt` once set, so every later
    // tick reports the exact same timestamp again — it must only ever be
    // folded in once.
    let hit = now.addingTimeInterval(-1)
    let first = RateLimitCeiling.recording(
        rateLimitTimestamps: [hit], now: now, burn5h: 42_000,
        previous: (ceilings: [], lastAt: nil))
    let second = RateLimitCeiling.recording(
        rateLimitTimestamps: [hit], now: now.addingTimeInterval(2), burn5h: 99_000,
        previous: first)
    #expect(second.ceilings == [42_000], "the same timestamp must never be recorded twice")
}

@Test func ignoresAStaleRateLimitTimestampButStillAdvancesTheWatermark() {
    // Discovered an hour after it actually happened — e.g. the first scan
    // of a transcript already containing it. Recording "now's" burn against
    // an hour-old event would itself be a plausible-looking lie.
    let staleHit = now.addingTimeInterval(-3600)
    let result = RateLimitCeiling.recording(
        rateLimitTimestamps: [staleHit], now: now, burn5h: 999_000,
        previous: (ceilings: [], lastAt: nil))
    #expect(result.ceilings.isEmpty, "a stale discovery must not fabricate a ceiling")
    #expect(result.lastAt == staleHit, "but it must still be marked seen so it is never reconsidered")
}

@Test func aLiveRateLimitJustInsideTheFreshnessWindowIsStillRecorded() {
    let hit = now.addingTimeInterval(-RateLimitCeiling.freshnessWindow + 1)
    let result = RateLimitCeiling.recording(
        rateLimitTimestamps: [hit], now: now, burn5h: 10_000,
        previous: (ceilings: [], lastAt: nil))
    #expect(result.ceilings == [10_000])
}

@Test func conservativeCeilingIsTheMinimumObserved() {
    #expect(RateLimitCeiling.conservativeCeiling([500, 300, 700]) == 300,
            "the minimum observed ceiling warns early rather than late")
}

@Test func noObservationsYieldsNilRatherThanZeroOrAGuess() {
    #expect(RateLimitCeiling.conservativeCeiling([]) == nil)
}

@Test func noRateLimitTimestampsLeavesThePreviousStateUnchanged() {
    let previous = (ceilings: [111], lastAt: now.addingTimeInterval(-100))
    let result = RateLimitCeiling.recording(
        rateLimitTimestamps: [], now: now, burn5h: 999_999, previous: previous)
    #expect(result.ceilings == [111])
    #expect(result.lastAt == previous.lastAt)
}

@Test func historyIsBoundedToTheMostRecentObservations() {
    var state: (ceilings: [Int], lastAt: Date?) = ([], nil)
    for i in 0..<(RateLimitCeiling.historyLimit + 3) {
        let hit = now.addingTimeInterval(Double(i))
        state = RateLimitCeiling.recording(
            rateLimitTimestamps: [hit], now: hit, burn5h: i * 1000, previous: state)
    }
    #expect(state.ceilings.count == RateLimitCeiling.historyLimit)
    #expect(!state.ceilings.contains(0), "the oldest observations must be evicted first")
    #expect(state.ceilings.contains((RateLimitCeiling.historyLimit + 2) * 1000),
            "the newest observation must always be kept")
}
