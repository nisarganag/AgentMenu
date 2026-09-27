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
    ///
    /// Bumped 1 -> 2: `RequestUsage.model` is new persisted state, `requestLog`
    /// is no longer trimmed, and — most importantly — every earlier checkpoint
    /// holds token counts with cache writes double-counted as input. Carrying
    /// those forward would keep the inflated figures alive indefinitely.
    public static let checkpointVersion = 2

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
    ///
    /// `model` is the model in force for THIS request (the most recent
    /// `turn_context`), so a rollout that switches model mid-session prices
    /// each request at its own rate instead of all of them at the last one.
    private struct RequestUsage: Sendable, Codable, Equatable {
        let at: Date; let tokens: TokenStats; let rawInput: Int; let model: String?
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
        _ = cutoff
        // `requestLog` is deliberately NOT trimmed here, unlike Claude's
        // `usageLog`. It is the only source of Codex's LIFETIME cost — the
        // long-context surcharge is decided per request, so the requests
        // themselves have to survive, not a pre-summed total — and trimming it
        // made every rollout's cost silently shrink to its last day of
        // requests after any restart. Bounded in practice by the rollout's own
        // length (a few hundred small entries at most on this machine), and
        // evicted with the rollout once it ages out of the source's lookback.
        return self
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
                let write  = total["cache_write_input_tokens"] as? Int ?? 0
                // Codex's input_tokens INCLUDES both cached_input_tokens AND
                // cache_write_input_tokens — subtract both. Only reads used to
                // be subtracted, so every written token was billed twice: as
                // input and again as a write. Proven, not assumed: across all
                // 1,675 token_count records on the owner's machine,
                // input - cached - write is never negative (minimum exactly 0),
                // i.e. writes are a subset of input exactly as reads are.
                tokens.input      = max(0, raw - cached - write)
                tokens.cacheRead  = cached
                tokens.cacheWrite = write
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
                let write    = last["cache_write_input_tokens"] as? Int ?? 0
                let entry = TokenStats(
                    input: max(0, rawInput - cached - write),   // see total_token_usage above
                    output: last["output_tokens"] as? Int ?? 0,
                    cacheRead: cached,
                    cacheWrite: write,
                    reasoning: last["reasoning_output_tokens"] as? Int ?? 0)
                if let at {
                    requestLog.append(RequestUsage(at: at, tokens: entry, rawInput: rawInput,
                                                   model: model))
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

    /// Session cost as the SUM of each request's own cost — each at the model
    /// in force when it was made, and with the long-context surcharge decided
    /// by that request's own input size, never smeared across a cumulative
    /// total that cannot say which portion crossed the threshold.
    private func costEstimate(pricing: PricingTable, since cutoff: Date) -> CostEstimate {
        var e = CostEstimate()
        for entry in requestLog where entry.at >= cutoff {
            e.add(pricing.cost(for: entry.tokens, rate: RateKey(model: entry.model ?? ""),
                               requestInputTokens: entry.rawInput),
                  tokens: entry.tokens)
        }
        return e
    }

    public func costEstimate(pricing: PricingTable) -> CostEstimate {
        costEstimate(pricing: pricing, since: .distantPast)
    }

    public func costEstimateToday(pricing: PricingTable, now: Date) -> CostEstimate {
        costEstimate(pricing: pricing, since: Calendar.current.startOfDay(for: now))
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
