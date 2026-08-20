import Foundation

/// Folds Codex rollout lines into one `AgentSession`.
///
/// Codex never logs approval requests (verified across every rollout on disk),
/// so "blocked on permission" is a stall heuristic reported at `.inferred`
/// confidence. See spec §3.2 — do not upgrade this to `.exact`.
public struct CodexRolloutParser: Sendable {
    public static let stallThreshold: TimeInterval = 25

    private var id: String?
    private var cwd: String?
    private var branch: String?
    private var model: String?
    private var tokens = TokenStats()
    private var contextUsed: Int?
    private var contextWindow: Int?
    private var lastActivity: Activity?
    private var terminal: Date?          // task_complete / turn_aborted
    private var firstAt: Date?
    private var lastAt: Date?

    public init() {}

    public mutating func consume(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let at = (obj["timestamp"] as? String).flatMap(ISO8601.parse)
        if let at {
            if firstAt == nil { firstAt = at }
            lastAt = at
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]

        // session_meta is a RECORD-level type, not a payload type — handle it
        // before the payload-type switch below.
        if type == "session_meta" {
            id = payload["id"] as? String ?? payload["session_id"] as? String
            cwd = payload["cwd"] as? String
            branch = (payload["git"] as? [String: Any])?["branch"] as? String
            if let w = payload["context_window"] as? Int { contextWindow = w }
            if let m = payload["model"] as? String { model = m }
            return
        }

        // turn_context is also RECORD-level, not a payload type. session_meta
        // carries no `model` key on real rollouts (only `model_provider`,
        // e.g. "openai") — the actual model id ("gpt-5.6-sol", etc.) lives
        // here instead. Recurs per turn, so a later record naturally wins,
        // which is correct if the model changes mid-session.
        if type == "turn_context" {
            if let m = payload["model"] as? String, !m.isEmpty { model = m }
            return
        }

        switch payload["type"] as? String {
        case "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            if let total = info["total_token_usage"] as? [String: Any] {
                let raw    = total["input_tokens"] as? Int ?? 0
                let cached = total["cached_input_tokens"] as? Int ?? 0
                // Codex's input_tokens INCLUDES cached_input_tokens. Subtract,
                // or the cost model over-charges by the entire cache.
                tokens.input      = max(0, raw - cached)
                tokens.cacheRead  = cached
                tokens.cacheWrite = total["cache_write_input_tokens"] as? Int ?? 0
                tokens.output     = total["output_tokens"] as? Int ?? 0
                tokens.reasoning  = total["reasoning_output_tokens"] as? Int ?? 0
            }
            if let last = info["last_token_usage"] as? [String: Any] {
                contextUsed = last["total_tokens"] as? Int
            }
            if let w = info["model_context_window"] as? Int { contextWindow = w }

        case "agent_message":
            if let m = (payload["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                lastActivity = Activity(body: .message(m), at: at ?? Date())
            }

        case "custom_tool_call", "function_call":
            // The tool field is `name`, not `tool_name`. `custom_tool_call`
            // carries its summary in `input`; `function_call` carries the
            // same shape under `arguments` instead (confirmed against a real
            // rollout — `function_call` payloads have no `input` key at all).
            // Both are STRINGS here, unlike Claude's object — do not reuse
            // Claude's dictionary-based summarize().
            let name = payload["name"] as? String ?? "tool"
            let summary = ((payload["input"] as? String) ?? (payload["arguments"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lastActivity = Activity(body: .tool(name: name, summary: summary), at: at ?? Date())

        case "reasoning":
            lastActivity = Activity(body: .thinking, at: at ?? Date())

        case "task_complete", "turn_aborted":
            terminal = at ?? Date()

        case "task_started":
            terminal = nil

        default: break
        }
    }

    public func session(path: String, now: Date) -> AgentSession? {
        guard let id, let lastAt else { return nil }
        let dir = cwd ?? ""

        let state: SessionState
        if let terminal {
            state = .done(at: terminal)
        } else if now.timeIntervalSince(lastAt) > Self.stallThreshold {
            // Codex logs no approval/permission/elicitation events (verified
            // across every rollout on disk) — this can only ever be inferred
            // from silence, never reported as an exact fact.
            state = .awaitingPermission(
                PermissionRequest(tool: lastActivity.map(Self.toolName) ?? "—",
                                  summary: lastActivity?.line ?? "",
                                  since: lastAt),
                confidence: .inferred)
        } else if let lastActivity {
            state = .working(lastActivity)
        } else {
            state = .idle
        }

        return AgentSession(
            kind: .codex,
            nativeId: id,
            project: dir.isEmpty ? "—" : (dir as NSString).lastPathComponent,
            directory: dir,
            branch: branch,
            model: model,
            state: state,
            lastActivity: lastActivity,
            tokens: tokens,
            context: zip2(contextUsed, contextWindow).map(ContextFill.init),
            cost: nil,                        // filled by the source using PricingTable
            startedAt: firstAt ?? lastAt,
            lastEventAt: lastAt,
            transcriptPath: path
        )
    }

    private static func toolName(_ a: Activity) -> String {
        if case .tool(let n, _) = a.body { return n }
        return "—"
    }
}

/// Combine two optionals into an optional pair — nil unless both are present.
func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
