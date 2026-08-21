import Foundation

/// Folds Codex rollout lines into one `AgentSession`.
///
/// Codex never logs approval requests (verified across every rollout on disk),
/// so "blocked on permission" is a stall heuristic reported at `.inferred`
/// confidence. See spec §3.2 — do not upgrade this to `.exact`.
///
/// `Codable`, `Equatable` (Round 3 / Ruling F49): see
/// `ClaudeTranscriptParser`'s equivalent doc comment — the same
/// offset-plus-accumulator reasoning applies here, keyed off
/// `checkpointVersion` rather than shared with Claude's.
public struct CodexRolloutParser: Sendable, Codable, Equatable {
    public static let stallThreshold: TimeInterval = 25

    /// See `ClaudeTranscriptParser.checkpointVersion` — same discipline,
    /// independent counter (Claude and Codex accumulators evolve separately).
    public static let checkpointVersion = 1

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
    /// One entry per `token_count` event's `last_token_usage` — verified
    /// against real rollouts to be an EXACT non-overlapping per-request
    /// delta (summed across a session it reconstructs `total_token_usage`
    /// exactly, no drift), unlike `total_token_usage` which is cumulative.
    /// This is both the precise per-message contribution for calendar-day
    /// windowing (Feature 1) and the precise per-request input size OpenAI's
    /// long-context surcharge keys off (Feature 3) — `rawInput` keeps the
    /// cache-inclusive figure for the threshold check, since the surcharge is
    /// about total prompt size, not the cache/non-cache split.
    private struct RequestUsage: Sendable, Codable, Equatable {
        let at: Date; let tokens: TokenStats; let rawInput: Int
    }
    private var requestLog: [RequestUsage] = []

    public init() {}

    /// See `ClaudeTranscriptParser.foldedUsageCount` — same purpose, applied
    /// to `requestLog` instead of `usageLog`.
    public var foldedRequestCount: Int { requestLog.count }

    /// See `ClaudeTranscriptParser.checkpointSnapshot(now:)` — identical
    /// reasoning and identical monotonic-cutoff safety proof, applied to
    /// `requestLog` instead of `usageLog`.
    public func checkpointSnapshot(now: Date) -> CodexRolloutParser {
        let todayStart = Calendar.current.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let cutoff = min(todayStart, fiveHoursAgo)
        var copy = self
        copy.requestLog = requestLog.filter { $0.at >= cutoff }
        return copy
    }

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
                // Same raw-includes-cached convention as `total_token_usage`
                // above (verified: subtracting cached_input_tokens from
                // input_tokens and adding output_tokens reproduces total_tokens
                // exactly on real per-request snapshots).
                let rawInput = last["input_tokens"] as? Int ?? 0
                let cached   = last["cached_input_tokens"] as? Int ?? 0
                let entry = TokenStats(
                    input: max(0, rawInput - cached),
                    output: last["output_tokens"] as? Int ?? 0,
                    cacheRead: cached,
                    cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0,
                    reasoning: last["reasoning_output_tokens"] as? Int ?? 0)
                if let at {
                    requestLog.append(RequestUsage(at: at, tokens: entry, rawInput: rawInput))
                }
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

    /// Sum of every logged request's usage at or after `cutoff`.
    private func usage(since cutoff: Date) -> TokenStats {
        requestLog.filter { $0.at >= cutoff }.map(\.tokens).reduce(TokenStats(), +)
    }

    /// Session cost as the SUM of each individual request's cost, so Feature
    /// 3's long-context surcharge — which applies above a per-request input
    /// threshold — is priced against the request that actually crossed it,
    /// never smeared across the session's cumulative total (which has no way
    /// to know which portion came from an over-threshold request). When no
    /// request ever crosses a threshold this is mathematically identical to
    /// pricing the cumulative total in one shot, since `requestLog` entries
    /// are exact non-overlapping deltas that sum to it (verified against real
    /// rollouts) — so this is a drop-in replacement, not just an addition.
    /// `since` restricts the sum to a window (`costToday`); omit it for the
    /// whole-session figure. Returns nil only when the model itself is
    /// unpriced — a window with no requests in it is a real zero, not unknown.
    private func cost(pricing: PricingTable, model: String, since cutoff: Date) -> Double? {
        guard pricing.cost(for: TokenStats(), model: model) != nil else { return nil }
        var total = 0.0
        for entry in requestLog where entry.at >= cutoff {
            total += pricing.cost(for: entry.tokens, model: model, requestInputTokens: entry.rawInput) ?? 0
        }
        return total
    }

    public func cost(pricing: PricingTable, model: String) -> Double? {
        cost(pricing: pricing, model: model, since: .distantPast)
    }

    public func costToday(pricing: PricingTable, model: String, now: Date) -> Double? {
        cost(pricing: pricing, model: model, since: Calendar.current.startOfDay(for: now))
    }

    /// - Parameter precomputedWindow: see
    ///   `ClaudeTranscriptParser.session(path:now:precomputedWindow:)` —
    ///   identical contract, applied to `requestLog` instead of `usageLog`.
    ///   `nil` (the default; every existing call site including every test)
    ///   always computes fresh and is exact by construction.
    public func session(path: String, now: Date,
                         precomputedWindow: (tokensToday: TokenStats, tokensLast5h: TokenStats)? = nil)
        -> AgentSession?
    {
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

        let tokensToday: TokenStats
        let tokensLast5h: TokenStats
        if let precomputedWindow {
            tokensToday = precomputedWindow.tokensToday
            tokensLast5h = precomputedWindow.tokensLast5h
        } else {
            // "Today" is local midnight on the user's current calendar —
            // never UTC, never a rolling 24h window (Feature 1).
            let todayStart = Calendar.current.startOfDay(for: now)
            let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
            tokensToday = usage(since: todayStart)
            tokensLast5h = usage(since: fiveHoursAgo)
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
            tokensToday: tokensToday,
            tokensLast5h: tokensLast5h,
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
