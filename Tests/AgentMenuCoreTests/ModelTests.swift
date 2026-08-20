import Testing
import Foundation
@testable import AgentMenuCore

@Test func tokenTotalSumsAllBuckets() {
    let t = TokenStats(input: 2, output: 322, cacheRead: 20868, cacheWrite: 22353, reasoning: 100)
    // reasoning is a subset of output and must NOT be double-counted
    #expect(t.total == 43545)
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
