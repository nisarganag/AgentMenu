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
