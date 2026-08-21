import Testing
import Foundation
@testable import AgentMenuCore

@Test func tokenTotalSumsAllBuckets() {
    let t = TokenStats(input: 2, output: 322, cacheRead: 20868, cacheWrite: 22353, reasoning: 100)
    // reasoning is a subset of output and must NOT be double-counted
    #expect(t.total == 43545)
}

// Round 2 Fix 1: `workTokens` is the DISPLAYED figure — input+output only,
// excluding cache — while `.total` (used for pricing/context-fill) keeps
// counting every bucket. On the owner's real data cache reads alone were 92%
// of `.total`, so the two must diverge sharply on a cache-heavy session, not
// merely differ by a rounding error.
@Test func workTokensExcludesCacheReadAndCacheWriteUnlikeTotal() {
    let t = TokenStats(input: 1000, output: 500, cacheRead: 740_000, cacheWrite: 62_000, reasoning: 50)
    #expect(t.workTokens == 1500)
    #expect(t.total == 803_500)
}

@Test func workTokensIsZeroWhenOnlyCacheBucketsAreNonZero() {
    let t = TokenStats(input: 0, output: 0, cacheRead: 900_000, cacheWrite: 100_000)
    #expect(t.workTokens == 0, "a session that only re-read cache did no new work to display")
    #expect(t.total == 1_000_000, "but .total must still count it for pricing/context-fill")
}

@Test func tokenStatsAdditionSumsEachBucketIndependently() {
    let a = TokenStats(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 5)
    let b = TokenStats(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, reasoning: 50)
    let sum = a + b
    #expect(sum.input == 11)
    #expect(sum.output == 22)
    #expect(sum.cacheRead == 33)
    #expect(sum.cacheWrite == 44)
    #expect(sum.reasoning == 55)
}

@Test func tokenStatsSubtractionClampsEachBucketAtZero() {
    let a = TokenStats(input: 5, output: 5, cacheRead: 5, cacheWrite: 5, reasoning: 5)
    let b = TokenStats(input: 10, output: 1, cacheRead: 10, cacheWrite: 1, reasoning: 10)
    let diff = a - b
    #expect(diff.input == 0, "5 - 10 must clamp at 0, never go negative")
    #expect(diff.output == 4)
    #expect(diff.cacheRead == 0)
    #expect(diff.cacheWrite == 4)
    #expect(diff.reasoning == 0)
}

@Test func contextFillClampsAtOne() {
    #expect(ContextFill(used: 300_000, window: 200_000).fraction == 1.0)
    #expect(ContextFill(used: 94_000, window: 200_000).fraction == 0.47)
    #expect(ContextFill(used: 10, window: 0).fraction == 0)
}

@Test func displayOrderPutsPermissionFirstThenWorkingThenIdleThenDone() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func s(_ id: String, _ state: SessionState) -> AgentSession {
        AgentSession(kind: .codex, nativeId: id, project: "p", directory: "/p",
                     state: state, startedAt: now, lastEventAt: now)
    }
    let ordered = [
        s("done",  .done(at: now)),
        s("idle",  .idle),
        s("work",  .working(Activity(body: .thinking, at: now))),
        s("perm",  .awaitingPermission(PermissionRequest(tool: "Bash", summary: "x", since: now),
                                       confidence: .exact)),
    ].sortedForDisplay()
    #expect(ordered.map(\.nativeId) == ["perm", "work", "idle", "done"])
}
