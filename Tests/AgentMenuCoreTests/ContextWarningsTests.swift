import Testing
import Foundation
@testable import AgentMenuCore

private let t = Date(timeIntervalSince1970: 1_755_689_400)

private func session(_ id: String, fraction: Double?, kind: AgentKind = .claudeCode) -> AgentSession {
    let context: ContextFill? = fraction.map { ContextFill(used: Int($0 * 100_000), window: 100_000) }
    return AgentSession(kind: kind, nativeId: id, project: "proj-\(id)", directory: "/proj",
                        context: context, startedAt: t, lastEventAt: t)
}

@Test func sessionCrossingThresholdForTheFirstTimeFires() {
    var armed: Set<String> = []
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    #expect(fired.map(\.nativeId) == ["s1"])
    #expect(armed.contains("claudeCode/s1"))
}

@Test func stayingAboveThresholdOnASubsequentTickDoesNotRefire() {
    var armed: Set<String> = []
    _ = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.90)], armed: &armed)
    #expect(fired.isEmpty, "must not re-fire every tick while a session stays above threshold")
}

@Test func droppingBelowThresholdThenClimbingAgainReArmsAndRefires() {
    var armed: Set<String> = []
    _ = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    _ = ContextWarnings.crossed([session("s1", fraction: 0.10)], armed: &armed)   // e.g. /compact
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.82)], armed: &armed)
    #expect(fired.map(\.nativeId) == ["s1"],
            "compacting back down and climbing again must be treated as a fresh crossing")
}

@Test func exactlyAtThresholdFires() {
    var armed: Set<String> = []
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.80)], armed: &armed)
    #expect(fired.map(\.nativeId) == ["s1"], "80% itself must count as crossed, not just past it")
}

@Test func justBelowThresholdDoesNotFire() {
    var armed: Set<String> = []
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.7999)], armed: &armed)
    #expect(fired.isEmpty)
}

@Test func sessionWithNoKnownContextWindowNeverFiresRegardlessOfHowMuchIsWritten() {
    var armed: Set<String> = []
    let fired = ContextWarnings.crossed([session("s1", fraction: nil)], armed: &armed)
    #expect(fired.isEmpty, "no known window means no percentage to cross, ever")
    #expect(armed.isEmpty)
}

@Test func multipleSessionsCrossingInTheSameTickAllFireIndependently() {
    var armed: Set<String> = []
    let fired = ContextWarnings.crossed([
        session("s1", fraction: 0.85),
        session("s2", fraction: 0.50),
        session("s3", fraction: 0.99),
    ], armed: &armed)
    #expect(Set(fired.map(\.nativeId)) == Set(["s1", "s3"]))
}

@Test func armedSetDoesNotGrowUnboundedWhenASessionDisappears() {
    var armed: Set<String> = []
    _ = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    #expect(armed.count == 1)
    _ = ContextWarnings.crossed([], armed: &armed)   // session ended / rotated out of the window
    #expect(armed.isEmpty, "an id for a session no longer reported must not leak forever")
}

@Test func reappearingStillAboveThresholdAfterDisappearingFiresAgain() {
    var armed: Set<String> = []
    _ = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    _ = ContextWarnings.crossed([], armed: &armed)
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.85)], armed: &armed)
    #expect(fired.map(\.nativeId) == ["s1"])
}

@Test func independentSessionsArmAndReArmIndependently() {
    var armed: Set<String> = []
    _ = ContextWarnings.crossed([session("s1", fraction: 0.85), session("s2", fraction: 0.85)], armed: &armed)
    // s1 compacts, s2 stays high.
    let fired = ContextWarnings.crossed([session("s1", fraction: 0.20), session("s2", fraction: 0.86)],
                                        armed: &armed)
    #expect(fired.isEmpty, "s2 must not refire merely because a DIFFERENT session dropped")
    let firedAfterS1Reclimbs = ContextWarnings.crossed(
        [session("s1", fraction: 0.81), session("s2", fraction: 0.86)], armed: &armed)
    #expect(firedAfterS1Reclimbs.map(\.nativeId) == ["s1"])
}
