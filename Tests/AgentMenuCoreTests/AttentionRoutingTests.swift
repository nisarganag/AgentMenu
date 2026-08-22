import Testing
import Foundation
@testable import AgentMenuCore

private let t = Date(timeIntervalSince1970: 1_755_689_400)

private func session(_ kind: AgentKind, _ state: SessionState, at: Date = t) -> AgentSession {
    AgentSession(kind: kind, nativeId: "\(kind.rawValue)-1", project: "p", directory: "/p",
                 state: state, startedAt: at, lastEventAt: at)
}

@Test func exactPermissionOutranksEverythingElse() {
    let sessions = [
        session(.codex, .working(Activity(body: .thinking, at: t))),
        session(.claudeCode, .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "rm -rf", since: t), confidence: .exact)),
        session(.opencode, .done(at: t)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .claudeCode)
}

@Test func exactPermissionBeatsInferredPermission() {
    let sessions = [
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "bash", summary: "", since: t), confidence: .inferred)),
        session(.claudeCode, .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: t), confidence: .exact)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .claudeCode)
}

@Test func inferredPermissionWinsWhenNoExactPromptExists() {
    let sessions = [
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "bash", summary: "", since: t), confidence: .inferred)),
        session(.claudeCode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .codex)
}

// Two agents both genuinely waiting is rare but not impossible; the more
// recently-raised prompt is the one that should win the jump.
@Test func mostRecentExactPromptWinsWhenTwoAgentsAreBothWaiting() {
    let earlier = t
    let later = t.addingTimeInterval(30)
    let sessions = [
        session(.claudeCode, .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: earlier), confidence: .exact)),
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "shell", summary: "", since: later), confidence: .exact)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .codex)
}

@Test func mostRecentTurnFinishedWinsWhenNothingIsAwaitingPermission() {
    let sessions = [
        session(.claudeCode, .done(at: t)),
        session(.codex, .done(at: t.addingTimeInterval(5))),
        session(.opencode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .claudeCode) == .codex)
}

// Was previously asserted the other way round: a `.working` session used to
// count as "nothing demanding attention" and lose to the fallback. That belief
// is precisely what the landing-page bug report contradicts — a running agent
// is now tier 3, so only genuinely quiet sessions reach the fallback.
@Test func aRunningAgentNowOutranksTheFallbackPage() {
    let sessions = [
        session(.claudeCode, .idle),
        session(.codex, .working(Activity(body: .thinking, at: t))),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .codex)
}

@Test func fallsBackToTheProvidedPageWhenEverySessionIsQuiet() {
    let sessions = [
        session(.claudeCode, .idle),
        session(.codex, .idle),
        session(.opencode, .unavailable("database is locked")),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .opencode)
}

@Test func emptySessionListFallsBackImmediately() {
    let sessions: [AgentSession] = []
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .codex) == .codex)
}

// MARK: - Bug: a long-finished agent hijacked the landing page

// The reported bug, verbatim: Claude Code was mid-turn, opencode had finished
// over an hour earlier and its app was closed, and the popover still opened on
// opencode. `.working` had no tier at all, so a live agent lost to any `.done`.
@Test func aWorkingAgentBeatsOneThatFinishedLongAgo() {
    let sessions = [
        session(.opencode, .done(at: t.addingTimeInterval(-3600))),
        session(.claudeCode, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-600)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .claudeCode)
}

// Running outranks finished even when the finish is seconds old: a live agent
// is the thing that can still change, a finished one is not going anywhere.
@Test func aWorkingAgentBeatsAJustFinishedOne() {
    let sessions = [
        session(.opencode, .done(at: t.addingTimeInterval(-3))),
        session(.claudeCode, .working(Activity(body: .thinking, at: t))),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .opencode) == .claudeCode)
}

// The owner's tie-break rule: "if claude and opencode are both running, the
// default should be whichever was running longer" — EARLIEST start wins, the
// opposite ordering to every other tier here, which is deliberate.
@Test func theLongestRunningAgentWinsWhenSeveralAreWorking() {
    let sessions = [
        session(.opencode, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-300)),
        session(.claudeCode, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-7200)),
        session(.codex, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-60)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .codex) == .claudeCode)
}

// Liveness ranks below attention: an agent that is merely busy does not
// outrank one that is actually blocked on the user, at either confidence.
@Test func anExactPermissionPromptStillOutranksALongRunningWorkingAgent() {
    let sessions = [
        session(.claudeCode, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-7200)),
        session(.opencode, .awaitingPermission(
            PermissionRequest(tool: "bash", summary: "", since: t), confidence: .exact)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .claudeCode) == .opencode)
}

@Test func anInferredPermissionPromptStillOutranksAWorkingAgent() {
    let sessions = [
        session(.claudeCode, .working(Activity(body: .thinking, at: t)), at: t.addingTimeInterval(-7200)),
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "shell", summary: "", since: t), confidence: .inferred)),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .claudeCode) == .codex)
}

// The other half of the same bug: with nothing running, a turn that finished
// hours ago is not a notification worth jumping to. The page the user last
// chose is a better answer than an agent they have long since walked away from.
@Test func aStaleFinishedTurnLosesToTheLastViewedPage() {
    let stale = t.addingTimeInterval(-(AttentionRouting.doneFreshness + 60))
    let sessions = [
        session(.opencode, .done(at: stale)),
        session(.claudeCode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .claudeCode) == .claudeCode)
}

@Test func aRecentlyFinishedTurnStillWinsWhenNothingIsRunning() {
    let sessions = [
        session(.opencode, .done(at: t.addingTimeInterval(-30))),
        session(.claudeCode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .claudeCode) == .opencode)
}

// A permission prompt is never aged out the way a finished turn is: it stays
// unanswered until someone answers it, however long that takes.
@Test func aStalePermissionPromptIsNotAgedOutTheWayAFinishedTurnIs() {
    let old = t.addingTimeInterval(-(AttentionRouting.doneFreshness * 10))
    let sessions = [
        session(.claudeCode, .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: old), confidence: .exact)),
        session(.codex, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(now: t, fallback: .codex) == .claudeCode)
}

// MARK: - Round 2 Fix 4: `exactAttentionProjects`

private func session(_ kind: AgentKind, project: String, _ state: SessionState) -> AgentSession {
    AgentSession(kind: kind, nativeId: "\(kind.rawValue)-\(project)", project: project,
                 directory: "/\(project)", state: state, startedAt: t, lastEventAt: t)
}

@Test func exactAttentionProjectsNamesOnlyExactPermissionSessions() {
    let sessions = [
        session(.claudeCode, project: "ezeeabanotes", .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: t), confidence: .exact)),
        session(.codex, project: "worldmonitor", .working(Activity(body: .thinking, at: t))),
        session(.opencode, project: "geo-reminder", .done(at: t)),
    ]
    #expect(sessions.exactAttentionProjects == ["ezeeabanotes"])
}

@Test func exactAttentionProjectsExcludesInferredEvenWhenExactIsAbsent() {
    let sessions = [
        session(.codex, project: "worldmonitor", .awaitingPermission(
            PermissionRequest(tool: "shell", summary: "", since: t), confidence: .inferred)),
    ]
    #expect(sessions.exactAttentionProjects.isEmpty,
            "a guess must never be captioned with a fact-backed session's certainty")
}

@Test func exactAttentionProjectsListsMultipleInOrder() {
    let sessions = [
        session(.claudeCode, project: "alpha", .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: t), confidence: .exact)),
        session(.codex, project: "beta", .awaitingPermission(
            PermissionRequest(tool: "shell", summary: "", since: t), confidence: .exact)),
    ]
    #expect(sessions.exactAttentionProjects == ["alpha", "beta"])
}

@Test func exactAttentionProjectsIsEmptyWhenNothingIsBlocked() {
    let sessions = [session(.claudeCode, project: "alpha", .idle)]
    #expect(sessions.exactAttentionProjects.isEmpty)
}
