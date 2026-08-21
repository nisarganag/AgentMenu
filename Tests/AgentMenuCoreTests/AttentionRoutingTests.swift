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
    #expect(sessions.mostUrgentAgentKind(fallback: .opencode) == .claudeCode)
}

@Test func exactPermissionBeatsInferredPermission() {
    let sessions = [
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "bash", summary: "", since: t), confidence: .inferred)),
        session(.claudeCode, .awaitingPermission(
            PermissionRequest(tool: "Bash", summary: "", since: t), confidence: .exact)),
    ]
    #expect(sessions.mostUrgentAgentKind(fallback: .opencode) == .claudeCode)
}

@Test func inferredPermissionWinsWhenNoExactPromptExists() {
    let sessions = [
        session(.codex, .awaitingPermission(
            PermissionRequest(tool: "bash", summary: "", since: t), confidence: .inferred)),
        session(.claudeCode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(fallback: .opencode) == .codex)
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
    #expect(sessions.mostUrgentAgentKind(fallback: .opencode) == .codex)
}

@Test func mostRecentTurnFinishedWinsWhenNothingIsAwaitingPermission() {
    let sessions = [
        session(.claudeCode, .done(at: t)),
        session(.codex, .done(at: t.addingTimeInterval(5))),
        session(.opencode, .idle),
    ]
    #expect(sessions.mostUrgentAgentKind(fallback: .claudeCode) == .codex)
}

@Test func fallsBackToTheProvidedPageWhenNothingDemandsAttention() {
    let sessions = [
        session(.claudeCode, .idle),
        session(.codex, .working(Activity(body: .thinking, at: t))),
    ]
    #expect(sessions.mostUrgentAgentKind(fallback: .opencode) == .opencode)
}

@Test func emptySessionListFallsBackImmediately() {
    let sessions: [AgentSession] = []
    #expect(sessions.mostUrgentAgentKind(fallback: .codex) == .codex)
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
