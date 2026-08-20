import Testing
import Foundation
@testable import AgentMenuCore

// Fix 5 / review Ruling F63: a source error must not wipe burn baselines for
// sessions that were perfectly fine moments ago. Before this rule, ANY
// source reporting `lastError` made main.swift's tick loop `continue` before
// that kind's session ids were added to the live set, so the blanket
// end-of-tick prune (`filter { liveIds.contains($0.key) }`) deleted every
// baseline for that ENTIRE kind — not just whatever one entry was actually
// unreadable. These tests exercise the extracted pruning rule directly,
// independent of main.swift's DispatchQueue/AgentSource plumbing.

@Test func prunedKeepsOnlyLiveIdsWhenNoKindErrored() {
    let baselines = ["claudeCode/a": 1, "claudeCode/b": 2, "codex/c": 3]
    let result = BurnBaselines.pruned(baselines, liveIds: ["claudeCode/a"], erroredKinds: [])
    #expect(Set(result.keys) == ["claudeCode/a"])
}

@Test func prunedKeepsEveryBaselineForAKindThatErroredThisPassEvenIfAbsentFromLiveIds() {
    // Claude errored this tick and reported no sessions at all (so its ids
    // are entirely absent from liveIds) — its baselines must survive
    // untouched. Losing them here means the NEXT clean tick sees
    // `prior == nil` for every one of them and re-records each session's
    // entire cumulative total as fresh burn (the round-2 Finding-1 class of
    // bug, reached via a different path).
    let baselines = ["claudeCode/a": 1, "claudeCode/b": 2, "codex/c": 3]
    let result = BurnBaselines.pruned(baselines, liveIds: ["codex/c"], erroredKinds: [.claudeCode])
    #expect(Set(result.keys) == ["claudeCode/a", "claudeCode/b", "codex/c"])
}

@Test func prunedStillDropsABaselineForAKindThatReportedCleanlyButNoLongerListsIt() {
    // Claude reported successfully this tick (not in erroredKinds) but "b"
    // legitimately rotated out of its retention window — that baseline must
    // still be dropped, same as before this fix.
    let baselines = ["claudeCode/a": 1, "claudeCode/b": 2]
    let result = BurnBaselines.pruned(baselines, liveIds: ["claudeCode/a"], erroredKinds: [])
    #expect(Set(result.keys) == ["claudeCode/a"])
}

@Test func prunedHandlesMultipleErroredKindsIndependently() {
    let baselines = ["claudeCode/a": 1, "codex/b": 2, "opencode/c": 3]
    // Codex is live, Claude and opencode both errored this pass.
    let result = BurnBaselines.pruned(baselines, liveIds: ["codex/b"],
                                      erroredKinds: [.claudeCode, .opencode])
    #expect(Set(result.keys) == ["claudeCode/a", "codex/b", "opencode/c"])
}

@Test func prunedOnAnEmptyBaselineSetStaysEmpty() {
    #expect(BurnBaselines.pruned([String: Int](), liveIds: ["claudeCode/a"],
                                 erroredKinds: [.claudeCode]).isEmpty)
}
