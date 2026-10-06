import Testing
import Foundation
@testable import AgentMenuCore

// Notification types (owner report 2026-10-06: "context used and context limit
// reached notifications are way too much ... add a toggle so I can control
// which types of notifs I get").
//
// Investigating that turned up two bugs underneath the request:
//
//  1. Claude Code's `Notification` hook carries twelve different
//     `notification_type`s, and AgentMenu filed every one of them as
//     "needs permission" — including idle prompts, subagent completions,
//     auth and quota notices — and lit the red permission dot for each.
//     Field confirmed in the schema compiled into the installed Claude Code
//     2.1.284: `{hook_event_name:"Notification", message, title?, notification_type}`.
//
//  2. The 80% context warning re-fired every time a subagent ran: a merged
//     session took its context fill from whichever transcript wrote LAST, so
//     subagent activity dropped it below 80% (re-arming the warning) and the
//     parent's next message crossed it again. Simulated over the owner's last
//     14 days: one session would have sent 172 warnings, another 37 — while
//     sessions with no subagents sent exactly 1, as designed.

private let ts = 1_755_689_420

private func claudeNotification(_ type: String?, message: String = "msg", title: String? = nil) -> SpoolEvent? {
    var payload: [String: Any] = ["session_id": "s1", "cwd": "/p",
                                  "hook_event_name": "Notification", "message": message]
    if let type { payload["notification_type"] = type }
    if let title { payload["title"] = title }
    // The Notification hook always writes event "permission-required" — the
    // classification has to come from the payload, not the envelope.
    return SpoolEvent(envelopeData: try! JSONSerialization.data(withJSONObject: [
        "v": 2, "agent": "claude-code", "event": "permission-required", "ts": ts, "payload": payload,
    ] as [String: Any]))
}

// MARK: - Classification

@Test func everyBlockingNotificationTypeStillRaisesAPermissionRequest() throws {
    for type in ["permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"] {
        let e = try #require(claudeNotification(type), "\(type) must parse")
        #expect(e.event == .permissionRequired, "\(type) blocks the agent on the user")
        #expect(e.notificationContent?.category == .permission, "\(type)")
    }
}

@Test func nonBlockingNotificationTypesNoLongerMasqueradeAsPermissionRequests() throws {
    for type in ["idle_prompt", "agent_completed", "auth_success",
                 "quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled",
                 "elicitation_complete", "elicitation_response",
                 "some_type_claude_code_adds_next_year"] {
        let e = try #require(claudeNotification(type), "\(type) must parse")
        #expect(e.event == .notice, "\(type) must not be filed as a permission request")
        #expect(e.notificationContent?.category != .permission, "\(type)")
    }
}

@Test func anIdlePromptIsWaitingForInput() throws {
    let c = try #require(claudeNotification("idle_prompt", message: "Claude is waiting for your input")?.notificationContent)
    #expect(c.category == .waitingForInput)
    #expect(c.title == "Claude Code is waiting for your input")
    #expect(c.body == "Claude is waiting for your input")
}

@Test func aCompletedSubagentIsItsOwnCategory() throws {
    let c = try #require(claudeNotification("agent_completed", message: "Explore agent finished")?.notificationContent)
    #expect(c.category == .subagentFinished)
    #expect(c.body == "Explore agent finished")
}

@Test func otherNoticesUseClaudesOwnTitleWhenItSendsOne() throws {
    let c = try #require(claudeNotification("auth_success", message: "Signed in", title: "Authenticated")?.notificationContent)
    #expect(c.category == .other)
    #expect(c.title == "Authenticated")
    #expect(c.body == "Signed in")
}

@Test func otherNoticesFallBackToTheAgentNameWithoutATitle() throws {
    let c = try #require(claudeNotification("quota_auto_resume_fired", message: "Resumed")?.notificationContent)
    #expect(c.title == "Claude Code")
}

// An older Claude Code with no `notification_type` keeps the behaviour it had:
// the Notification hook was only ever wired up for permission prompts.
@Test func aPayloadWithNoNotificationTypeKeepsTheOldBehaviour() throws {
    let e = try #require(claudeNotification(nil, message: "Claude needs your permission to use Bash"))
    #expect(e.event == .permissionRequired)
    #expect(e.notificationContent?.category == .permission)
}

@Test func permissionPromptsAndInputRequestsAreWordedDifferently() throws {
    #expect(claudeNotification("permission_prompt")?.notificationContent?.title == "Claude Code needs permission")
    #expect(claudeNotification("agent_needs_input")?.notificationContent?.title == "Claude Code needs your input")
    #expect(claudeNotification("elicitation_dialog")?.notificationContent?.title == "Claude Code needs your input")
}

@Test func finishedTurnsMapToTheTurnFinishedCategory() throws {
    let claude = SpoolEvent(v: 2, agent: .claudeCode, event: .turnFinished, sessionId: "s", cwd: "/p",
                            summary: "Done.", ts: ts)
    let codex = SpoolEvent(v: 2, agent: .codex, event: .turnFinished, sessionId: "s", cwd: "/p", ts: ts)
    #expect(claude.notificationContent?.category == .turnFinished)
    #expect(claude.notificationContent?.title == "Claude Code finished")
    #expect(codex.notificationContent?.body == "Turn complete")
}

@Test func resolvedAndStartedEventsNeverNotify() {
    for kind: SpoolEvent.Kind in [.permissionResolved, .turnStarted] {
        let e = SpoolEvent(v: 2, agent: .claudeCode, event: kind, sessionId: "s", cwd: "/p", ts: ts)
        #expect(e.notificationContent == nil)
    }
}

// Every category coalesces on its own key. They all used to share
// "<agent>/perm/<session>", so an idle prompt arriving within the 8-second
// coalescing window could swallow a real permission prompt behind it.
@Test func eachCategoryCoalescesOnItsOwnKey() throws {
    let keys = ["permission_prompt", "idle_prompt", "agent_completed", "auth_success"]
        .compactMap { claudeNotification($0)?.notificationContent?.key }
    #expect(keys.count == 4)
    #expect(Set(keys).count == 4, "distinct keys: \(keys)")
}

// MARK: - A notice never claims the agent is blocked

@Test func aNoticeNeverLightsTheRedPermissionDot() throws {
    let store = SessionStore()
    let now = Date(timeIntervalSince1970: Double(ts) + 1)
    store.apply(sessions: [AgentSession(kind: .claudeCode, nativeId: "s1", project: "p", directory: "/p",
                                        state: .idle, startedAt: now, lastEventAt: now)],
                kind: .claudeCode, now: now)
    store.apply(events: [try #require(claudeNotification("idle_prompt"))], now: now)
    #expect(store.attentionCount == 0, "an idle prompt is not a permission request")
    store.apply(events: [try #require(claudeNotification("permission_prompt"))], now: now)
    #expect(store.attentionCount == 1, "a real one still is")
}

// MARK: - Context warning content

@Test func theContextWarningIsItsOwnCategory() {
    var s = AgentSession(kind: .claudeCode, nativeId: "s1", project: "ezeeabanotes", directory: "/p",
                         startedAt: Date(), lastEventAt: Date())
    s.context = ContextFill(used: 850, window: 1000)
    let c = NotificationContent.contextWarning(for: s)
    #expect(c.category == .contextWarning)
    #expect(c.title == "ezeeabanotes is near its context limit")
    #expect(c.body == "85% of context used — consider compacting soon.")
    #expect(c.key == "claudeCode/s1/context80")
}

@Test func everyCategoryExplainsItselfForTheSettingsScreen() {
    #expect(NotificationCategory.allCases.count == 6)
    for c in NotificationCategory.allCases {
        #expect(!c.label.isEmpty, "\(c)")
        #expect(!c.detail.isEmpty, "\(c)")
    }
    // Persisted by raw value: renaming a case would silently re-enable
    // whatever the user had switched off.
    #expect(NotificationCategory.allCases.map(\.rawValue) ==
            ["permission", "waitingForInput", "turnFinished", "subagentFinished", "contextWarning", "other"])
}

// MARK: - The context-warning flood

private let pricing = try! PricingTable.decode(#"""
{"models":{"claude-opus-5":{"inputPerMTok":5,"outputPerMTok":25,"contextWindow":1000}}}
"""#.data(using: .utf8)!)

private func assistantLine(at: String, context used: Int, sidechain: Bool = false) -> String {
    let flag = sidechain ? #""isSidechain":true,"# : ""
    return #"{"type":"assistant",\#(flag)"timestamp":"\#(at)","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"id":"m-\#(at)","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(used),"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
}

private func projectDir() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("shared-id/subagents"),
                                            withIntermediateDirectories: true)
    return root
}

// The root cause. A subagent is a separate conversation with its own window;
// its fill says nothing about how full the user's own conversation is.
@Test func aMergedSessionsContextComesFromTheParentNotANewerSubagent() throws {
    let root = try projectDir()
    try (assistantLine(at: "2026-08-19T18:22:10.000Z", context: 900) + "\n")
        .write(to: root.appendingPathComponent("shared-id.jsonl"), atomically: true, encoding: .utf8)
    try (assistantLine(at: "2026-08-19T18:25:00.000Z", context: 50, sidechain: true) + "\n")
        .write(to: root.appendingPathComponent("shared-id/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)

    let source = ClaudeCodeSource(projectsRoot: root.deletingLastPathComponent(), pricing: pricing)
    let merged = try #require(source.rescan(now: ISO8601.parse("2026-08-19T18:25:01.000Z")!).first)
    #expect(merged.context?.used == 900, "the parent's 90%, not the subagent's 5%")
    // Activity still reflects what is happening now, including the subagent.
    #expect(merged.lastEventAt == ISO8601.parse("2026-08-19T18:25:00.000Z"))
}

// End to end: the warning fires once at the crossing, then stays quiet while
// a subagent runs and the parent carries on.
@Test func theContextWarningFiresOnceAcrossSubagentActivity() throws {
    let root = try projectDir()
    let parent = root.appendingPathComponent("shared-id.jsonl")
    let sub = root.appendingPathComponent("shared-id/subagents/agent-a.jsonl")
    let source = ClaudeCodeSource(projectsRoot: root.deletingLastPathComponent(), pricing: pricing)
    var armed: Set<String> = []

    try (assistantLine(at: "2026-08-19T18:00:00.000Z", context: 850) + "\n")
        .write(to: parent, atomically: true, encoding: .utf8)
    #expect(ContextWarnings.crossed(source.rescan(now: ISO8601.parse("2026-08-19T18:00:01.000Z")!),
                                    armed: &armed).count == 1, "crossing 80% warns once")

    try (assistantLine(at: "2026-08-19T18:01:00.000Z", context: 40, sidechain: true) + "\n")
        .write(to: sub, atomically: true, encoding: .utf8)
    #expect(ContextWarnings.crossed(source.rescan(now: ISO8601.parse("2026-08-19T18:01:01.000Z")!),
                                    armed: &armed).isEmpty, "a subagent running must not re-arm it")

    try ([assistantLine(at: "2026-08-19T18:00:00.000Z", context: 850),
          assistantLine(at: "2026-08-19T18:02:00.000Z", context: 870)].joined(separator: "\n") + "\n")
        .write(to: parent, atomically: true, encoding: .utf8)
    #expect(ContextWarnings.crossed(source.rescan(now: ISO8601.parse("2026-08-19T18:02:01.000Z")!),
                                    armed: &armed).isEmpty, "the parent continuing must not re-fire it")
}

@Test func isSidechainIsReadFromTheTranscriptAndFromTheSubagentsDirectory() throws {
    var flagged = ClaudeTranscriptParser()
    flagged.consume(Data(assistantLine(at: "2026-08-19T18:00:00.000Z", context: 10, sidechain: true).utf8))
    #expect(flagged.session(path: "/p/s.jsonl", now: Date())?.isSidechain == true)

    // Older transcripts may not carry the flag; the directory layout still says it.
    var unflagged = ClaudeTranscriptParser()
    unflagged.consume(Data(assistantLine(at: "2026-08-19T18:00:00.000Z", context: 10).utf8))
    #expect(unflagged.session(path: "/p/shared-id/subagents/agent-a.jsonl", now: Date())?.isSidechain == true)
    #expect(unflagged.session(path: "/p/shared-id.jsonl", now: Date())?.isSidechain == false)
}

// A request with no input at all — Claude Code's `<synthetic>` API-error
// placeholders — is not a real reading of the conversation. Letting it reset
// the fill to 0% would re-arm the warning just as a subagent did.
@Test func aZeroInputRecordDoesNotResetTheContextReading() throws {
    var p = ClaudeTranscriptParser()
    p.consume(Data(assistantLine(at: "2026-08-19T18:00:00.000Z", context: 850).utf8))
    p.consume(Data(#"{"type":"assistant","timestamp":"2026-08-19T18:00:05.000Z","sessionId":"shared-id","cwd":"/p","message":{"id":"syn","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error"}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#.utf8))
    #expect(p.session(path: "/p/s.jsonl", now: Date())?.context?.used == 850)
}
