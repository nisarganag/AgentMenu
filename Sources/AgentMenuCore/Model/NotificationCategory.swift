import Foundation

/// The kinds of notification AgentMenu can send, each switchable on its own in
/// Preferences.
///
/// Persisted by `rawValue` (as the set of categories the user switched OFF), so
/// renaming a case would silently re-enable whatever someone had turned off —
/// the raw values are pinned by a test for that reason. Storing the OFF set
/// rather than the ON set also means a category added in a later release
/// arrives enabled instead of silently missing.
public enum NotificationCategory: String, CaseIterable, Sendable, Codable {
    /// An agent is blocked until you approve or answer something.
    case permission
    /// Claude finished and has been sitting at the prompt (`idle_prompt`).
    case waitingForInput
    /// An agent finished its turn.
    case turnFinished
    /// A Claude Code subagent finished (`agent_completed`).
    case subagentFinished
    /// A session crossed 80% of its context window.
    case contextWarning
    /// Everything else Claude Code reports: sign-in, quota auto-resume, MCP
    /// elicitation results, and any notification type it adds in future.
    case other

    public var label: String {
        switch self {
        case .permission:       return "Permission & input requests"
        case .waitingForInput:  return "Waiting for your input"
        case .turnFinished:     return "Turn finished"
        case .subagentFinished: return "Subagent finished"
        case .contextWarning:   return "Context nearly full"
        case .other:            return "Other Claude Code notices"
        }
    }

    /// One line for the settings screen, saying when it fires.
    public var detail: String {
        switch self {
        case .permission:       return "An agent is blocked until you approve a tool or answer a question."
        case .waitingForInput:  return "Claude has finished and is idle at the prompt."
        case .turnFinished:     return "An agent finished replying."
        case .subagentFinished: return "A Claude Code subagent completed its task."
        case .contextWarning:   return "A session crossed 80% of its context window."
        case .other:            return "Sign-in, quota auto-resume, and anything else Claude Code reports."
        }
    }
}

/// One banner, fully decided: what it says, which switch governs it, and the
/// key it coalesces on. Built here in Core, rather than inside `Notifier`, so
/// the mapping from event to banner is covered by tests.
public struct NotificationContent: Sendable, Equatable {
    public let category: NotificationCategory
    public let title: String
    public let body: String
    /// Two banners with the same key inside `Notifier.coalesceWindow` collapse
    /// into one. Every category has its own key: they used to share
    /// "<agent>/perm/<session>", so an idle prompt could swallow a real
    /// permission prompt that arrived seconds behind it.
    public let key: String

    public init(category: NotificationCategory, title: String, body: String, key: String) {
        self.category = category; self.title = title; self.body = body; self.key = key
    }

    public static func contextWarning(for s: AgentSession) -> NotificationContent {
        let percent = Int((s.context?.fraction ?? 0) * 100)
        return NotificationContent(
            category: .contextWarning,
            title: "\(s.project) is near its context limit",
            body: "\(percent)% of context used — consider compacting soon.",
            key: "\(s.kind.rawValue)/\(s.nativeId)/context80")
    }
}

extension SpoolEvent {
    /// Claude Code `notification_type`s that genuinely block the agent on the
    /// user. Only these may raise the red "needs permission" state.
    static let blockingNotificationTypes: Set<String> = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
    ]

    /// The banner this event should produce, or nil when it never notifies.
    public var notificationContent: NotificationContent? {
        let who = agent.displayName
        let session = "\(agent.rawValue)/\(sessionId)"
        switch event {
        case .permissionRequired:
            // A permission prompt names a tool; an input request (a subagent
            // or an MCP server asking a question) does not, and reads wrong
            // phrased as "permission".
            let asksForInput = notificationType.map { $0 != "permission_prompt" } ?? false
            return NotificationContent(
                category: .permission,
                title: asksForInput ? "\(who) needs your input" : "\(who) needs permission",
                body: [tool, summary].compactMap { $0 }.joined(separator: "  "),
                key: "\(session)/perm")
        case .turnFinished:
            return NotificationContent(category: .turnFinished, title: "\(who) finished",
                                       body: summary ?? "Turn complete", key: "\(session)/done")
        case .notice:
            switch notificationType {
            case "idle_prompt":
                return NotificationContent(category: .waitingForInput,
                                           title: "\(who) is waiting for your input",
                                           body: summary ?? "", key: "\(session)/idle")
            case "agent_completed":
                return NotificationContent(category: .subagentFinished,
                                           title: "\(who): subagent finished",
                                           body: summary ?? "", key: "\(session)/agent")
            default:
                return NotificationContent(category: .other, title: title ?? who,
                                           body: summary ?? notificationType ?? "",
                                           key: "\(session)/notice/\(notificationType ?? "")")
            }
        case .permissionResolved, .turnStarted:
            return nil
        }
    }
}
