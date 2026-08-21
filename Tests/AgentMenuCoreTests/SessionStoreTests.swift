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

// MARK: - Bug 1: a permission dot must clear once the agent is demonstrably
// no longer live, even with no resolve event and no file evidence ever
// advancing again (the reported failure: closing the whole terminal).

@Test func stickyOverrideSurvivesWhileTheProcessIsAliveAndTheSessionIsFresh() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    let later = t.addingTimeInterval(10)   // past pushWinsWindow, nowhere near the 90s staleness ceiling
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .claudeCode, now: later)
    store.apply(runningKinds: [.claudeCode], now: later)
    guard case .awaitingPermission = store.all.first?.state else {
        Issue.record("a live process with a fresh transcript must keep the red dot, got \(String(describing: store.all.first?.state))")
        return
    }
}

// Reproduces the exact reported scenario: a Claude session asks for
// permission, then the user closes the whole terminal. The transcript can
// never advance again, so the pre-existing file-evidence release condition
// alone would leave this stuck forever — process liveness is what breaks
// the deadlock.
@Test func stickyOverrideReleasesWhenTheAgentProcessVanishesEntirely() {
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    let soonAfter = t.addingTimeInterval(6)   // just past pushWinsWindow, far short of 90s staleness
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .claudeCode, now: soonAfter)
    store.apply(runningKinds: [], now: soonAfter)   // no claude process anywhere any more
    guard case .working = store.all.first?.state else {
        Issue.record("a dead process must release a sticky override even though the transcript never advanced, got \(String(describing: store.all.first?.state))")
        return
    }
}

@Test func stickyOverrideReleasesOnStalenessEvenIfProcessLivenessSaysStillRunning() {
    // Backstop: even if a claude process is technically alive somewhere (a
    // second, unrelated session), THIS session's own transcript silence past
    // the ceiling proves nobody is actively staring at ITS prompt any more.
    let store = SessionStore()
    store.apply(events: [event("s1", .permissionRequired, at: t)], now: t)
    let wayLater = t.addingTimeInterval(SessionStore.stickyOverrideStaleness + 1)
    store.apply(sessions: [session("s1", .claudeCode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .claudeCode, now: wayLater)
    store.apply(runningKinds: [.claudeCode], now: wayLater)
    guard case .working = store.all.first?.state else {
        Issue.record("staleness past the ceiling must release the override even while the kind is still reported running, got \(String(describing: store.all.first?.state))")
        return
    }
}

// MARK: - Bug 2: a `.working` state needs a live process behind it.

@Test func workingStateIsDowngradedWhenNoProcessOfThatKindIsRunning() {
    let store = SessionStore()
    store.apply(sessions: [session("s1", .opencode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .opencode, now: t)
    store.apply(runningKinds: [], now: t)   // the opencode app has fully quit
    if case .working = store.all.first?.state {
        Issue.record("a dead opencode process must not leave the session reading WORKING")
    }
}

@Test func workingStateSurvivesWhileItsProcessIsStillRunning() {
    let store = SessionStore()
    store.apply(sessions: [session("s1", .opencode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .opencode, now: t)
    store.apply(runningKinds: [.opencode], now: t)
    guard case .working = store.all.first?.state else {
        Issue.record("a live process must not have its working state second-guessed, got \(String(describing: store.all.first?.state))")
        return
    }
}

@Test func processLivenessNeverActsBeforeItIsKnown() {
    // Regression guard against the opposite bug: before `apply(runningKinds:)`
    // is ever called (e.g. the very first tick, before ProcessScanner has run
    // even once), a `.working` state must not be second-guessed just because
    // liveness defaults to "nothing known" — that would misreport every
    // session as not-working for a tick on every single launch.
    let store = SessionStore()
    store.apply(sessions: [session("s1", .opencode, .working(Activity(body: .thinking, at: t)), at: t)],
                kind: .opencode, now: t)
    guard case .working = store.all.first?.state else {
        Issue.record("liveness must stay a no-op until the store has actually been told something, got \(String(describing: store.all.first?.state))")
        return
    }
}
