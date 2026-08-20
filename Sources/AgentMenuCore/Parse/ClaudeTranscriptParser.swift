import Foundation

/// Folds Claude Code transcript lines into one `AgentSession`.
///
/// Incremental by design: `consume` is called per new line as the file grows,
/// so a 4.8 MB transcript is parsed once and then only appended to. Any line
/// that fails to decode is skipped — truncated trailing records are the normal
/// case when reading a file an agent is actively writing.
public struct ClaudeTranscriptParser: Sendable {
    /// A turn that produced no output for longer than this is no longer "working".
    public static let stallThreshold: TimeInterval = 25

    private var sessionId: String?
    private var cwd: String?
    private var branch: String?
    private var model: String?
    private var tokens = TokenStats()
    private var lastContextUsed: Int?
    private var lastActivity: Activity?
    private var lastStopReason: String?
    private var firstAt: Date?
    private var lastAt: Date?

    public init() {}

    public mutating func consume(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if let ts = obj["timestamp"] as? String, let date = ISO8601.parse(ts) {
            if firstAt == nil { firstAt = date }
            lastAt = date
        }
        if sessionId == nil { sessionId = obj["sessionId"] as? String }
        if let c = obj["cwd"] as? String { cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

        guard type == "assistant", let message = obj["message"] as? [String: Any] else { return }
        if let m = message["model"] as? String { model = m }
        lastStopReason = message["stop_reason"] as? String

        if let usage = message["usage"] as? [String: Any] {
            let inTok    = usage["input_tokens"] as? Int ?? 0
            let outTok   = usage["output_tokens"] as? Int ?? 0
            let cacheRd  = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWr  = usage["cache_creation_input_tokens"] as? Int ?? 0
            tokens.input      += inTok
            tokens.output     += outTok
            tokens.cacheRead  += cacheRd
            tokens.cacheWrite += cacheWr
            if let d = usage["output_tokens_details"] as? [String: Any],
               let think = d["thinking_tokens"] as? Int {
                tokens.reasoning += think
            }
            // Live context is the LAST request's inputs, not the running total.
            lastContextUsed = inTok + cacheRd + cacheWr
        }

        if let content = message["content"] as? [[String: Any]],
           let activity = Self.activity(from: content, at: lastAt ?? Date()) {
            lastActivity = activity
        }
    }

    private static func activity(from content: [[String: Any]], at date: Date) -> Activity? {
        // Walk backwards: the last meaningful block is what the agent is doing.
        for block in content.reversed() {
            switch block["type"] as? String {
            case "text":
                if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty { return Activity(body: .message(t), at: date) }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                return Activity(body: .tool(name: name, summary: summarize(input)), at: date)
            case "thinking":
                return Activity(body: .thinking, at: date)
            default: continue
            }
        }
        return nil
    }

    /// Pick the argument a human would recognise the call by.
    private static func summarize(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "query", "prompt", "url"] {
            if let v = input[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    public func session(path: String, now: Date) -> AgentSession? {
        guard let id = sessionId, let lastAt else { return nil }
        let dir = cwd ?? ""
        let state: SessionState
        if lastStopReason == "end_turn" {
            state = .done(at: lastAt)
        } else if now.timeIntervalSince(lastAt) > Self.stallThreshold {
            // Not "working" — nothing has happened for a long time. The spool
            // channel is what promotes this to .awaitingPermission (Task 8).
            state = .idle
        } else if let activity = lastActivity {
            state = .working(activity)
        } else {
            state = .idle
        }

        return AgentSession(
            kind: .claudeCode,
            nativeId: id,
            project: dir.isEmpty ? "—" : (dir as NSString).lastPathComponent,
            directory: dir,
            branch: branch,
            model: model,
            state: state,
            lastActivity: lastActivity,
            tokens: tokens,
            context: lastContextUsed.map { ContextFill(used: $0, window: 0) },
            cost: nil,                        // filled by the source using PricingTable
            startedAt: firstAt ?? lastAt,
            lastEventAt: lastAt,
            transcriptPath: path
        )
    }
}
