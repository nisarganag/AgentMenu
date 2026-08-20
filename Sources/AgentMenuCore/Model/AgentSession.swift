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

public struct Activity: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
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

public struct TokenStats: Sendable, Equatable {
    public var input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.reasoning = reasoning
    }
    /// Reasoning tokens are already counted inside `output` by every provider
    /// here, so they are excluded from the total.
    public var total: Int { input + output + cacheRead + cacheWrite }
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
    public var context: ContextFill?
    public var cost: Double?
    public var startedAt: Date
    public var lastEventAt: Date
    public var pid: pid_t?
    public var transcriptPath: String?

    public init(kind: AgentKind, nativeId: String, project: String, directory: String,
                branch: String? = nil, model: String? = nil, state: SessionState = .idle,
                lastActivity: Activity? = nil, tokens: TokenStats = .init(),
                context: ContextFill? = nil, cost: Double? = nil,
                startedAt: Date, lastEventAt: Date,
                pid: pid_t? = nil, transcriptPath: String? = nil) {
        self.kind = kind; self.nativeId = nativeId; self.project = project
        self.directory = directory; self.branch = branch; self.model = model
        self.state = state; self.lastActivity = lastActivity; self.tokens = tokens
        self.context = context; self.cost = cost; self.startedAt = startedAt
        self.lastEventAt = lastEventAt; self.pid = pid; self.transcriptPath = transcriptPath
    }
}
