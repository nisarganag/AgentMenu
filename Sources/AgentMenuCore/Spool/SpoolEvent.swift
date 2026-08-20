import Foundation

/// One push event from an agent hook.
///
/// Wire version 2 (Fix 6): the hooks are pure POSIX `sh` with no JSON parser
/// of their own — `/usr/bin/python3`, which used to do the field extraction,
/// is a stub that never runs on a Mac without Xcode Command Line Tools
/// installed, exactly the machine a DMG gets handed to. So the hooks no
/// longer flatten an agent's payload themselves; they wrap the agent's raw,
/// unparsed payload verbatim in a small envelope —
/// `{"v":2,"agent":"claude-code","event":"permission-required","ts":...,
/// "payload":{...whatever Claude Code/Codex itself sent...}}` — and
/// `init(envelopeData:)` below does the extraction, per agent, using
/// `JSONSerialization`, which is a real JSON parser.
///
/// `AgentKind`'s own `Codable` conformance (Task 1) round-trips its Swift case
/// name (e.g. "claudeCode"), but the hooks write the hyphenated wire spelling
/// (e.g. "claude-code"). Rather than override `AgentKind`'s conformance from
/// here — Task 1 owns that file — `agent` is read as a plain string and
/// mapped through `AgentKind(wire:)` below.
public struct SpoolEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case permissionRequired = "permission-required"
        case permissionResolved = "permission-resolved"
        case turnFinished       = "turn-finished"
        case turnStarted        = "turn-started"
    }

    /// The only wire version `init(envelopeData:)` understands. Bumped from 1
    /// (the old flat, python-flattened shape) to 2 when the hooks stopped
    /// doing their own field extraction (Fix 6).
    public static let wireVersion = 2

    public let v: Int
    public let agent: AgentKind
    public let event: Kind
    public let sessionId: String
    public let cwd: String
    public let tool: String?
    public let summary: String?
    public let ts: Int

    public var date: Date { Date(timeIntervalSince1970: Double(ts)) }

    /// `SessionStore`'s tests (Task 8) and others construct events directly
    /// with this signature rather than going through the wire format.
    public init(v: Int, agent: AgentKind, event: Kind, sessionId: String, cwd: String,
                tool: String? = nil, summary: String? = nil, ts: Int) {
        self.v = v
        self.agent = agent
        self.event = event
        self.sessionId = sessionId
        self.cwd = cwd
        self.tool = tool
        self.summary = summary
        self.ts = ts
    }

    /// Parses one spool file's raw bytes as a wire-version-2 envelope.
    /// Returns nil for anything that isn't a well-formed envelope of the
    /// expected version — an unrecognised `v`, agent, or event, or a body
    /// that isn't even a JSON object — so `SpoolWatcher.drain` can keep its
    /// existing fail-soft stance: a file that fails to parse is skipped, not
    /// fatal, the same as a truncated line in a transcript.
    public init?(envelopeData data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let v = obj["v"] as? Int, v == Self.wireVersion else { return nil }
        guard let rawAgent = obj["agent"] as? String, let agent = AgentKind(wire: rawAgent) else {
            return nil
        }
        guard let rawEvent = obj["event"] as? String, let event = Kind(rawValue: rawEvent) else {
            return nil
        }
        guard let ts = obj["ts"] as? Int else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]

        let fields = Self.extract(from: payload, agent: agent)
        self.init(v: v, agent: agent, event: event, sessionId: fields.sessionId, cwd: fields.cwd,
                  tool: fields.tool, summary: fields.summary, ts: ts)
    }

    /// Every agent shapes its hook/notify payload differently — this is
    /// exactly the flattening the old inline python one-liners used to do,
    /// now done with a real parser instead of shell string-slicing.
    private static func extract(from payload: [String: Any], agent: AgentKind)
        -> (sessionId: String, cwd: String, tool: String?, summary: String?) {
        switch agent {
        case .claudeCode:
            // Claude Code's own hook payload shape (verified live, Task 22):
            // `session_id`, `cwd`, `tool_name`, and either a `message` (the
            // Notification hook) or a `tool_input` object worth summarising
            // (a PreToolUse-shaped payload, kept here for completeness even
            // though AgentMenu no longer installs into PreToolUse itself —
            // see Fix 1).
            let sessionId = payload["session_id"] as? String ?? ""
            let cwd = payload["cwd"] as? String ?? ""
            let tool = payload["tool_name"] as? String
            let summary: String?
            if let message = payload["message"] as? String {
                summary = message
            } else if let input = payload["tool_input"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: input),
                      let str = String(data: data, encoding: .utf8) {
                summary = String(str.prefix(120))
            } else {
                summary = nil
            }
            return (sessionId, cwd, tool, summary)
        case .codex:
            // Codex's notify blob carries `thread-id` (preferred) or
            // `session_id`, `cwd`, and `last-assistant-message`. Codex never
            // reports a tool name here.
            let sessionId = (payload["thread-id"] as? String) ?? (payload["session_id"] as? String) ?? ""
            let cwd = payload["cwd"] as? String ?? ""
            let summary = payload["last-assistant-message"] as? String
            return (sessionId, cwd, nil, summary)
        case .opencode:
            // No hook or notify slot targets opencode today — Channel B
            // (DB polling) is its only source. Handled defensively, with the
            // same field names as the others, rather than assumed
            // unreachable.
            let sessionId = payload["session_id"] as? String ?? ""
            let cwd = payload["cwd"] as? String ?? ""
            return (sessionId, cwd, payload["tool"] as? String, payload["summary"] as? String)
        }
    }
}

extension AgentKind {
    /// Wire spelling used by the hook scripts.
    public init?(wire: String) {
        switch wire {
        case "claude-code": self = .claudeCode
        case "codex":       self = .codex
        case "opencode":    self = .opencode
        default:            return nil
        }
    }
    public var wire: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex:      return "codex"
        case .opencode:   return "opencode"
        }
    }
}
