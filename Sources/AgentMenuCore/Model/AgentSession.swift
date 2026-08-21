import Foundation

public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claudeCode, codex, opencode

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .opencode:   return "opencode"
        }
    }
}

/// Whether a state was read from an authoritative signal or inferred.
/// Load-bearing: Codex cannot report permission state, so its dot must render
/// differently rather than claim false parity. See spec §3.2.
public enum Confidence: Sendable, Equatable { case exact, inferred }

public struct Activity: Sendable, Equatable, Codable {
    // Codable: Round 3 (Ruling F49) — `ClaudeTranscriptParser`/
    // `CodexRolloutParser` store `lastActivity: Activity?` and must be
    // checkpointable as a whole, accumulator-and-offset-together unit.
    public enum Body: Sendable, Equatable, Codable {
        case message(String)
        case tool(name: String, summary: String)
        case thinking
    }
    public let body: Body
    public let at: Date
    public init(body: Body, at: Date) { self.body = body; self.at = at }

    /// Single-line render for the row's activity line.
    public var line: String {
        switch body {
        case .message(let s): return s.split(separator: "\n").first.map(String.init) ?? s
        case .tool(let n, let s): return s.isEmpty ? n : "\(n)  \(s)"
        case .thinking: return "thinking…"
        }
    }
}

public struct PermissionRequest: Sendable, Equatable {
    public let tool: String
    public let summary: String
    public let since: Date
    public init(tool: String, summary: String, since: Date) {
        self.tool = tool; self.summary = summary; self.since = since
    }
}

public enum SessionState: Sendable, Equatable {
    case working(Activity)
    case awaitingPermission(PermissionRequest, confidence: Confidence)
    case idle
    case done(at: Date)
    case unavailable(String)
}

public struct TokenStats: Sendable, Equatable, Codable {
    // Codable: Round 3 (Ruling F49) — persisted as part of a parser
    // accumulator's checkpoint (both the running lifetime total and each
    // logged message/request's usage).
    public var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.reasoning = reasoning
    }
    /// Reasoning tokens are already counted inside `output` by every provider
    /// here, so they are excluded from the total.
    ///
    /// This is the correct figure wherever every priced bucket must count —
    /// pricing (`PricingTable.cost`, which weights cache at its own real,
    /// discounted rate) and context-fill math both need the true sum. It is
    /// deliberately NOT what `workTokens` below is for: displaying a token
    /// count to the user.
    public var total: Int { input + output + cacheRead + cacheWrite }

    /// Round 2 Fix 1: the token count to DISPLAY (header, session rows) —
    /// `input + output`, deliberately excluding `cacheRead`/`cacheWrite`.
    ///
    /// Every Claude Code turn re-sends the accumulated conversation as
    /// cached context, so `cacheRead` re-counts the same prior context on
    /// every single turn of a long session and dominates `.total` — on the
    /// owner's real data, cache reads were 92% of `.total` for one day's
    /// activity. That number is priced correctly (cache read is billed at
    /// ~10-20% of fresh-input rate, see `PricingTable`), but as a TOKEN
    /// COUNT it tells the user nothing about the work actually done and
    /// reads as a wildly inflated, plausible-looking lie (804.7M vs. the
    /// 2.1M actually written/read once). `workTokens` is what a person
    /// means by "how many tokens did this session use" — `.total` remains
    /// exactly as it was for the call sites that need every bucket (cost
    /// input, context fill) and MUST NOT be redefined; do not replace
    /// `.total` with this at those call sites.
    public var workTokens: Int { input + output }
}

extension TokenStats {
    /// Bucket-wise sum — used to fold per-message/per-request usage into a
    /// windowed total (Feature 1) without hand-writing the same five-field
    /// addition at every call site.
    public static func + (lhs: TokenStats, rhs: TokenStats) -> TokenStats {
        TokenStats(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                   reasoning: lhs.reasoning + rhs.reasoning)
    }

    /// Bucket-wise difference, clamped at zero per bucket — the same
    /// defensive stance as `BurnBaselines.delta`: a rescan racing a write, or
    /// totals that otherwise appear to shrink, must never produce negative
    /// tokens.
    public static func - (lhs: TokenStats, rhs: TokenStats) -> TokenStats {
        TokenStats(input: max(0, lhs.input - rhs.input), output: max(0, lhs.output - rhs.output),
                   cacheRead: max(0, lhs.cacheRead - rhs.cacheRead),
                   cacheWrite: max(0, lhs.cacheWrite - rhs.cacheWrite),
                   reasoning: max(0, lhs.reasoning - rhs.reasoning))
    }
}

public struct ContextFill: Sendable, Equatable {
    public let used: Int, window: Int
    public init(used: Int, window: Int) { self.used = used; self.window = window }
    public var fraction: Double {
        guard window > 0 else { return 0 }
        return min(1.0, Double(used) / Double(window))
    }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    public let kind: AgentKind
    public let nativeId: String
    public var id: String { "\(kind.rawValue)/\(nativeId)" }

    public var project: String
    public var directory: String
    public var branch: String?
    public var model: String?
    public var state: SessionState
    public var lastActivity: Activity?
    public var tokens: TokenStats
    /// Real calendar-day (local midnight) and trailing-5h token windows,
    /// computed by the parser from per-message timestamps — never
    /// accumulated from deltas observed after AgentMenu happened to launch.
    /// `nil` means "this source cannot compute it," never "zero": opencode's
    /// SQLite schema has only per-session totals and a `time_updated`, with
    /// no per-message breakdown to window, so its sessions leave both nil
    /// rather than approximate (spec §7 — an unknown number renders absent).
    public var tokensToday: TokenStats?
    public var tokensLast5h: TokenStats?
    /// Cost of just `tokensToday`, priced the same way `cost` is — nil
    /// whenever `tokensToday` is nil OR the model is unpriced.
    public var costToday: Double?
    public var context: ContextFill?
    public var cost: Double?
    public var startedAt: Date
    public var lastEventAt: Date
    public var pid: pid_t?
    public var transcriptPath: String?
    /// Timestamp of the most recent real Claude rate-limit error observed in
    /// this transcript (`apiErrorStatus == 429` on a message carrying
    /// `isApiErrorMessage: true`) — nil if none ever has been. Always nil for
    /// Codex/opencode; Feature 2 is scoped to Claude, whose quota this is.
    public var lastRateLimitAt: Date?

    public init(kind: AgentKind, nativeId: String, project: String, directory: String,
                branch: String? = nil, model: String? = nil, state: SessionState = .idle,
                lastActivity: Activity? = nil, tokens: TokenStats = .init(),
                tokensToday: TokenStats? = nil, tokensLast5h: TokenStats? = nil,
                costToday: Double? = nil,
                context: ContextFill? = nil, cost: Double? = nil,
                startedAt: Date, lastEventAt: Date,
                pid: pid_t? = nil, transcriptPath: String? = nil,
                lastRateLimitAt: Date? = nil) {
        self.kind = kind; self.nativeId = nativeId; self.project = project
        self.directory = directory; self.branch = branch; self.model = model
        self.state = state; self.lastActivity = lastActivity; self.tokens = tokens
        self.tokensToday = tokensToday; self.tokensLast5h = tokensLast5h; self.costToday = costToday
        self.context = context; self.cost = cost; self.startedAt = startedAt
        self.lastEventAt = lastEventAt; self.pid = pid; self.transcriptPath = transcriptPath
        self.lastRateLimitAt = lastRateLimitAt
    }
}
