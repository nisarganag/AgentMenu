import Testing
import Foundation
@testable import AgentMenuCore

private let t = Date(timeIntervalSince1970: 1_755_689_400)

private func session(_ id: String, _ kind: AgentKind = .claudeCode,
                     _ state: SessionState = .idle, at: Date = t) -> AgentSession {
    AgentSession(kind: kind, nativeId: id, project: "proj", directory: "/proj",
                 state: state, startedAt: at, lastEventAt: at)
}

private func event(_ id: String, _ kind: SpoolEvent.Kind, at: Date) -> SpoolEvent {
    SpoolEvent(v: 1, agent: .claudeCode, event: kind, sessionId: id, cwd: "/proj",
               tool: "Bash", summary: "rm -rf target/", ts: Int(at.timeIntervalSince1970))
}

@Test func pushEventOverridesFileStateImmediately() {
    let store = SessionStore()
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)))],
                kind: .claudeCode, now: t)
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)

    guard case .awaitingPermission(_, let c) = store.all.first?.state else {
        Issue.record("push must win, got \(String(describing: store.all.first?.state))"); return
    }
    #expect(c == .exact)
}

@Test func fileStateCannotUndoAFreshPushEvent() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    // A poll 2s later still reporting "working" must not clear the red dot.
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)))],
                kind: .claudeCode, now: t.addingTimeInterval(2))
    guard case .awaitingPermission = store.all.first?.state else {
        Issue.record("inside the push-wins window, file evidence must not override"); return
    }
}

@Test func fileStateTakesOverAfterThePushWindowSoAMissedResolveSelfHeals() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    // No "resolved" event ever arrives — but the transcript kept moving.
    let later = t.addingTimeInterval(10)
    store.apply(sessions: [session("s1", .claudeCode,
                                   .working(Activity(body: .thinking, at: later)), at: later)],
                kind: .claudeCode, now: later)
    guard case .working = store.all.first?.state else {
        Issue.record("a dropped resolve event must not pin a red dot forever"); return
    }
}

@Test func permissionResolvedClearsTheDotImmediately() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    store.apply(events: [event("s1", .permissionResolved, at: t.addingTimeInterval(1))],
                now: t.addingTimeInterval(1))
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)))],
                kind: .claudeCode, now: t.addingTimeInterval(1))
    guard case .working = store.all.first?.state else {
        Issue.record("resolve must release the override"); return
    }
}

@Test func turnFinishedEventMarksDone() {
    let store = SessionStore()
    store.apply(sessions: [session("s1")], kind: .claudeCode, now: t)
    store.apply(events: [event("s1", .turnFinished, at: t)], now: t)
    guard case .done = store.all.first?.state else { Issue.record("got \(store.all.first!.state)"); return }
}

@Test func applyingOneSourceDoesNotDropAnother() {
    let store = SessionStore()
    store.apply(sessions: [session("c1", .claudeCode)], kind: .claudeCode, now: t)
    store.apply(sessions: [session("o1", .opencode)], kind: .opencode, now: t)
    store.apply(sessions: [session("c2", .claudeCode)], kind: .claudeCode, now: t)
    // Replacing Claude's set must not disturb opencode's.
    #expect(Set(store.all.map(\.id)) == ["claudeCode/c2", "opencode/o1"])
}

@Test func failingSourceBecomesAVisibleRowNotACrash() {
    let store = SessionStore()
    store.apply(sessions: [session("c1", .claudeCode)], kind: .claudeCode, now: t)
    store.markUnavailable(.claudeCode, reason: "permission denied reading ~/.claude")
    guard case .unavailable(let why) = store.all.first?.state else {
        Issue.record("expected an unavailable row"); return
    }
    #expect(why.contains("permission denied"))
}

@Test func attentionCountCountsOnlyBlockedSessions() {
    let store = SessionStore()
    store.apply(sessions: [
        session("a", .claudeCode, .working(Activity(body: .thinking, at: t))),
        session("b", .claudeCode, .idle),
    ], kind: .claudeCode, now: t)
    #expect(store.attentionCount == 0)
    store.apply(events: [event("a", .permissionRequired, at: t)], now: t)
    #expect(store.attentionCount == 1)
}

// Fix 3 / review Ruling F61: the menu bar badge (attentionCount) must never
// count an `.inferred` guess — that flattens Codex's stall heuristic into
// the same red-alert signal as a fact-backed Claude permission prompt, at
// the app's most prominent, popover-closed surface. `inferredAttentionCount`
// exists precisely so the UI layer can render the two at different
// certainty (StatusItemController: alert red vs. caution amber).
@Test func attentionCountExcludesInferredGuessesInferredAttentionCountTracksThemSeparately() {
    let store = SessionStore()
    let inferredReq = PermissionRequest(tool: "bash", summary: "", since: t)
    // Codex's stall heuristic is pull-channel only — it is never delivered
    // via a push event, since Codex logs no approval events at all.
    store.apply(sessions: [session("codexGuess", .codex,
                                   .awaitingPermission(inferredReq, confidence: .inferred))],
                kind: .codex, now: t)
    store.apply(sessions: [session("exactPending", .claudeCode,
                                   .working(Activity(body: .thinking, at: t)))],
                kind: .claudeCode, now: t)
    store.apply(events: [event("exactPending", .permissionRequired, at: t)], now: t)

    #expect(store.attentionCount == 1,
            "only the exact (Claude) permission may count toward the alert badge")
    #expect(store.inferredAttentionCount == 1,
            "the inferred (Codex) guess must be tracked, just not in attentionCount")
}

@Test func attentionCountIsZeroWhenOnlyInferredGuessesArePresent() {
    let store = SessionStore()
    let inferredReq = PermissionRequest(tool: "bash", summary: "", since: t)
    store.apply(sessions: [session("codexGuess", .codex,
                                   .awaitingPermission(inferredReq, confidence: .inferred))],
                kind: .codex, now: t)
    #expect(store.attentionCount == 0, "a guess alone must never light up the alert badge")
    #expect(store.inferredAttentionCount == 1)
}

@Test func resultsComeBackInDisplayOrder() {
    let store = SessionStore()
    store.apply(sessions: [
        session("done", .claudeCode, .done(at: t)),
        session("work", .claudeCode, .working(Activity(body: .thinking, at: t))),
    ], kind: .claudeCode, now: t)
    store.apply(events: [event("done", .permissionRequired, at: t)], now: t)
    #expect(store.all.first?.nativeId == "done", "whatever needs the user sorts first")
}

@Test func droppingASessionFromASourceReleasesItsOverride() {
    let store = SessionStore()
    store.apply(sessions: [session("s1")], kind: .claudeCode, now: t)
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    // The source rotates s1 out of its window (every source has bounded
    // retention) without ever sending a resolve event.
    store.apply(sessions: [], kind: .claudeCode, now: t)
    // If the override had leaked, s1 reappearing would wrongly still show
    // awaitingPermission even though nothing ever resolved it explicitly.
    store.apply(sessions: [session("s1")], kind: .claudeCode, now: t)
    guard case .idle = store.all.first?.state else {
        Issue.record("orphaned override must be released once its session drops out of the source's list, got \(String(describing: store.all.first?.state))")
        return
    }
}

@Test func stickyOverrideSurvivesPastTheWindowWhenFileEvidenceHasNotMoved() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    let later = t.addingTimeInterval(10)
    // Same lastEventAt as when the override was set — the file channel has not
    // actually proven the session moved on, so the override must hold even
    // though we're well past pushWinsWindow.
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .claudeCode, now: later)
    guard case .awaitingPermission = store.all.first?.state else {
        Issue.record("a sticky override must survive past the window until file evidence actually advances, got \(String(describing: store.all.first?.state))")
        return
    }
}
