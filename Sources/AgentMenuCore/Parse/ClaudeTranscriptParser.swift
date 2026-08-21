import Foundation

/// Folds Claude Code transcript lines into one `AgentSession`.
///
/// Incremental by design: `consume` is called per new line as the file grows,
/// so a 4.8 MB transcript is parsed once and then only appended to. Any line
/// that fails to decode is skipped — truncated trailing records are the normal
/// case when reading a file an agent is actively writing.
///
/// `Codable`, `Equatable` (Round 3 / Ruling F49): this struct doubles as its
/// own checkpoint payload. The parsers are cumulative folds — a byte offset
/// alone says nothing about the tokens/model/branch/etc. already folded in
/// before that offset, so restoring an offset without this exact accumulator
/// would silently report only the tail of a session. `Checkpoint` persists
/// this whole struct, not a derived summary of it, so a restore is bit-for-
/// bit equivalent to having never stopped reading. See
/// `TranscriptCheckpoint.checkpointVersion` doc comment for the version-bump
/// discipline this depends on.
public struct ClaudeTranscriptParser: Sendable, Codable, Equatable {
    /// A turn that produced no output for longer than this is no longer "working".
    public static let stallThreshold: TimeInterval = 25

    /// Bump whenever ANY stored property below changes name, type, or
    /// meaning. `Checkpoint` stamps this alongside every persisted
    /// accumulator and discards on mismatch rather than trusting a decode
    /// that merely happens to succeed — a future version could rename/repurpose
    /// a field in a way `Codable` alone would not catch (e.g. same name and
    /// type, different unit). Never bump this for a change that doesn't touch
    /// the shape of this struct's persisted state.
    public static let checkpointVersion = 1

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
    /// One entry per assistant message that carried usage, timestamped —
    /// folded into `tokensToday`/`tokensLast5h` at `session(path:now:)` time
    /// rather than accumulated eagerly, since which messages fall inside a
    /// calendar-day or trailing-5h window depends on `now`, not on when the
    /// line was consumed (Feature 1).
    private struct TimedUsage: Sendable, Codable, Equatable { let at: Date; let tokens: TokenStats }
    private var usageLog: [TimedUsage] = []
    /// Most recent real Claude rate-limit error seen (Feature 2) — see
    /// `AgentSession.lastRateLimitAt`.
    private var lastRateLimitAt: Date?

    public init() {}

    /// How many usage-bearing messages have been folded so far — bumped by
    /// every `consume` that sees a new one, O(1) to read. Exposed so a
    /// caller across many `session(path:now:)` calls (`ClaudeCodeSource`,
    /// one per rescan tick) can tell WITHOUT re-deriving `tokensToday`/
    /// `tokensLast5h` whether anything that could change them has arrived
    /// since the last tick — see `session`'s `precomputedWindow` parameter.
    public var foldedUsageCount: Int { usageLog.count }

    /// A copy suitable for persisting in a checkpoint. `usageLog` is trimmed
    /// to entries that could still matter for a FUTURE `tokensToday`/
    /// `tokensLast5h` computed at any `now' >= now` — everything older only
    /// ever fed `tokens` (the lifetime running total), which is a plain
    /// scalar already carried separately and needs no history at all.
    ///
    /// Safe by construction, not by luck: `Calendar.startOfDay(for:)` and
    /// `now - 5h` are both monotonically non-decreasing in `now`, so
    /// `cutoff(now') >= cutoff(now)` for any later restore-and-evaluate time
    /// — nothing dropped here could ever be needed again. See
    /// `ClaudeTranscriptParserCheckpointTests` for the direct proof.
    ///
    /// Bounds checkpoint size independent of how long a transcript has been
    /// accumulating: measured against this machine's real 7-day working set,
    /// the unpruned log was already ~20,600 entries (order of a few MB) and
    /// grows with retention; the pruned log is roughly one day's worth,
    /// however long the file has existed.
    public func checkpointSnapshot(now: Date) -> ClaudeTranscriptParser {
        let todayStart = Calendar.current.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let cutoff = min(todayStart, fiveHoursAgo)
        var copy = self
        copy.usageLog = usageLog.filter { $0.at >= cutoff }
        return copy
    }

    public mutating func consume(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let messageDate = (obj["timestamp"] as? String).flatMap(ISO8601.parse)
        if let messageDate {
            if firstAt == nil { firstAt = messageDate }
            lastAt = messageDate
        }
        if sessionId == nil { sessionId = obj["sessionId"] as? String }
        if let c = obj["cwd"] as? String { cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

        // Feature 2: verified against real transcripts on disk — a failed API
        // call (rate limit, overload, billing) is logged as a top-level
        // sibling of `message`, not nested inside it: `isApiErrorMessage:
        // true`, `apiErrorStatus: <HTTP status>`, `error: "<cli label>"`, with
        // `message.model == "<synthetic>"`. Real occurrences on this machine
        // only ever showed 529 ("server_error") and 400 ("billing_error"/
        // "unknown") — never 429 — so this exact firing is unverified, but
        // the field and its HTTP-status semantics are real, not guessed.
        if obj["isApiErrorMessage"] as? Bool == true, obj["apiErrorStatus"] as? Int == 429 {
            lastRateLimitAt = messageDate ?? lastAt
        }

        guard type == "assistant", let message = obj["message"] as? [String: Any] else { return }
        if let m = message["model"] as? String { model = m }
        lastStopReason = message["stop_reason"] as? String

        if let usage = message["usage"] as? [String: Any] {
            let inTok    = usage["input_tokens"] as? Int ?? 0
            let outTok   = usage["output_tokens"] as? Int ?? 0
            let cacheRd  = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWr  = usage["cache_creation_input_tokens"] as? Int ?? 0
            let think    = (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0
            tokens.input      += inTok
            tokens.output     += outTok
            tokens.cacheRead  += cacheRd
            tokens.cacheWrite += cacheWr
            tokens.reasoning  += think
            // Live context is the LAST request's inputs, not the running total.
            lastContextUsed = inTok + cacheRd + cacheWr

            if let messageDate {
                usageLog.append(TimedUsage(at: messageDate, tokens: TokenStats(
                    input: inTok, output: outTok, cacheRead: cacheRd, cacheWrite: cacheWr,
                    reasoning: think)))
            }
        }

        if let content = message["content"] as? [[String: Any]],
           let activity = Self.activity(from: content, at: lastAt ?? Date()) {
            lastActivity = activity
        }
    }

    /// Sum of every logged message's usage at or after `cutoff` — the shared
    /// implementation behind both `tokensToday` and `tokensLast5h`.
    private func usage(since cutoff: Date) -> TokenStats {
        usageLog.filter { $0.at >= cutoff }.map(\.tokens).reduce(TokenStats(), +)
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

    /// - Parameter precomputedWindow: lets a caller that already knows
    ///   `tokensToday`/`tokensLast5h` haven't changed (`ClaudeCodeSource`,
    ///   keyed on `foldedUsageCount` and a coarsened `now` —
    ///   `AgentSourceTuning.windowCacheGranularity`) skip re-deriving them
    ///   here. `session` runs every ~2s for every cached parser regardless
    ///   of whether the transcript changed that tick, so without this a
    ///   session with a long-retained `usageLog` would re-fold the whole
    ///   thing — twice, once per window — every single tick for numbers
    ///   that are almost always unchanged since the last one. `nil` (the
    ///   default, and what every existing call site including every test
    ///   passes) always computes fresh from `usageLog` and is exact by
    ///   construction; the parameter only ever lets a caller skip work it
    ///   has already separately proven is safe to skip, never changes what
    ///   a fresh computation would have produced.
    public func session(path: String, now: Date,
                         precomputedWindow: (tokensToday: TokenStats, tokensLast5h: TokenStats)? = nil)
        -> AgentSession?
    {
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
            kind: .claudeCode,
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
            context: lastContextUsed.map { ContextFill(used: $0, window: 0) },
            cost: nil,                        // filled by the source using PricingTable
            startedAt: firstAt ?? lastAt,
            lastEventAt: lastAt,
            transcriptPath: path,
            lastRateLimitAt: lastRateLimitAt
        )
    }
}
