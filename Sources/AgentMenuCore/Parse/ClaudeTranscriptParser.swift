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
    /// Bumped 1 -> 2: `recentResponseIds` is new persisted state, and — far
    /// more importantly — the meaning of the persisted `tokens`/`usageLog`
    /// changed. Every checkpoint written before this carries the inflated,
    /// duplicate-counted totals described on `recentResponseIds`. They must
    /// be discarded and re-derived from the transcripts, not carried
    /// forward, or the fix would never reach anyone already running the app.
    ///
    /// Bumped 2 -> 3: `tokensByRate` and `TimedUsage.rate` are new persisted
    /// state, and every earlier checkpoint was accumulated without knowing
    /// which model each message belonged to — so its costs could only ever be
    /// re-priced as one model, the bug this version exists to fix. Discarded
    /// and re-derived, for the same reason as the 1 -> 2 bump.
    public static let checkpointVersion = 3

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
    private struct TimedUsage: Sendable, Codable, Equatable {
        let at: Date; let tokens: TokenStats; let rate: RateKey
    }
    private var usageLog: [TimedUsage] = []
    /// Lifetime usage split by what it is billed at — the source of the
    /// session's COST, where `tokens` stays the source of its displayed counts.
    ///
    /// Kept separately from `usageLog` rather than derived from it: that log
    /// is trimmed to roughly a day on every checkpoint, so pricing lifetime
    /// cost from it would silently lose everything older after a restart.
    /// Small in practice — one entry per model a session actually used.
    private var tokensByRate: [RateKey: TokenStats] = [:]
    /// Most recent real Claude rate-limit error seen (Feature 2) — see
    /// `AgentSession.lastRateLimitAt`.
    private var lastRateLimitAt: Date?

    /// Identifiers of the most recently folded API responses, oldest first —
    /// the guard against counting one response many times.
    ///
    /// Claude Code writes ONE record per content block of an assistant
    /// response: the text lands on its own line, each `tool_use` on another,
    /// and every one of them repeats a verbatim copy of the usage for the
    /// WHOLE response. The usage belongs to the request, not to the record,
    /// so summing per-record multiplies cost by however many blocks the reply
    /// happened to contain.
    ///
    /// Measured on the owner's machine across all 878 transcripts on disk:
    /// 29,026 duplicate groups, every copy byte-identical in all four token
    /// buckets, inflating cost 2.68x — $20,271 reported against $7,577 real.
    /// This was the "cost is grossly upwards of what the console shows" bug.
    ///
    /// Bounded rather than a full set, because this is persisted in every
    /// checkpoint and a session's identifiers would otherwise grow without
    /// limit. `dedupeWindow` is sized off the real distribution: copies of one
    /// response are separated by a median of 2 records and at most 29 (the
    /// interleaved records are the user-side `tool_result`s), so 128 is over
    /// four times the worst case ever observed. Erring on this bound is safe
    /// in one direction only — too small merely misses a duplicate and
    /// over-counts as before, and can never subtract usage that was real.
    private var recentResponseIds: [String] = []
    private static let dedupeWindow = 128

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
            // `cache_creation_input_tokens` is every write; this is the part of
            // it that went to the 1-hour cache, billed at 2x input rather than
            // 1.25x. Clamped so a malformed record cannot claim more 1-hour
            // writes than writes.
            let cacheWr1h = min(cacheWr, (usage["cache_creation"] as? [String: Any])?[
                "ephemeral_1h_input_tokens"] as? Int ?? 0)
            // The model THIS message was billed at. Priced per message because
            // a session is not one model: `/model` switches mid-conversation.
            let rate = RateKey(model: (message["model"] as? String) ?? model ?? "",
                               fast: usage["speed"] as? String == "fast",
                               usGeo: usage["inference_geo"] as? String == "us")

            // Live context is the LAST request's inputs, not the running
            // total — set before the duplicate check and outside it, since
            // every copy of a response reports the same figure and the newest
            // record is still the newest request either way.
            lastContextUsed = inTok + cacheRd + cacheWr

            // `message.id` is the API response id; `requestId` is Claude
            // Code's own per-request id and is a top-level sibling of
            // `message`. Every copy of a split response shares both, so
            // either identifies the response. With neither, fold: counting a
            // record twice is a smaller error than dropping real usage on the
            // guess that two anonymous records must be the same response.
            //
            // Skips only the token fold, never the whole record: the copies
            // of a response are its DIFFERENT content blocks, so the second
            // and later ones carry the tool calls. Returning early here would
            // leave every multi-block turn showing its opening text and never
            // the tool it actually ran.
            let responseId = (message["id"] as? String) ?? (obj["requestId"] as? String)
            var alreadyFolded = false
            if let responseId {
                alreadyFolded = recentResponseIds.contains(responseId)
                if !alreadyFolded {
                    recentResponseIds.append(responseId)
                    if recentResponseIds.count > Self.dedupeWindow {
                        recentResponseIds.removeFirst(recentResponseIds.count - Self.dedupeWindow)
                    }
                }
            }

            if !alreadyFolded {
                let entry = TokenStats(input: inTok, output: outTok, cacheRead: cacheRd,
                                       cacheWrite: cacheWr, reasoning: think, cacheWrite1h: cacheWr1h)
                tokens = tokens + entry
                tokensByRate[rate, default: TokenStats()] = tokensByRate[rate, default: TokenStats()] + entry
                if let messageDate {
                    usageLog.append(TimedUsage(at: messageDate, tokens: entry, rate: rate))
                }
            }
        }

        if let content = message["content"] as? [[String: Any]],
           let activity = Self.activity(from: content, at: lastAt ?? Date()) {
            lastActivity = activity
        }
    }

    /// Sum of every logged message's usage at or after `cutoff` — the shared
    /// implementation behind both `tokensToday` and `tokensLast5h`.
    /// Lifetime cost, each message priced at its own model and modifiers.
    public func costEstimate(pricing: PricingTable) -> CostEstimate {
        pricing.estimate(tokensByRate)
    }

    /// Cost since local midnight, priced per message the same way.
    public func costEstimateToday(pricing: PricingTable, now: Date) -> CostEstimate {
        let cutoff = Calendar.current.startOfDay(for: now)
        var buckets: [RateKey: TokenStats] = [:]
        for entry in usageLog where entry.at >= cutoff {
            buckets[entry.rate, default: TokenStats()] = buckets[entry.rate, default: TokenStats()] + entry.tokens
        }
        return pricing.estimate(buckets)
    }

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
