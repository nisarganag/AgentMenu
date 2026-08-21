import Foundation

/// One monitored agent. Implementations own their file watching and parsing and
/// expose nothing about their storage format — the UI only ever sees
/// `[AgentSession]`.
public protocol AgentSource: AnyObject, Sendable {
    var kind: AgentKind { get }
    /// Re-read everything this source knows about. Must never throw: a source
    /// that cannot read returns [] and reports through `lastError`.
    func rescan(now: Date) -> [AgentSession]
    var lastError: String? { get }
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
    /// Rebuild any OS-level watchers. Called on wake from sleep.
    func restart()
    /// Round 2 Fix 3: whether this source's underlying storage location
    /// exists on disk AT ALL — independent of whether `rescan` currently
    /// returns any sessions (a session can age out of the lookback window
    /// while the tool itself has clearly been used before). Lets the UI
    /// distinguish "installed but idle right now" from "this agent has
    /// never been used," so a fresh user isn't shown a permanently empty
    /// page for a tool they don't have.
    var dataDirectoryExists: Bool { get }
}

/// Tuning shared by all three sources so their retention windows agree.
public enum AgentSourceTuning {
    /// A session untouched for longer than this cannot still be live. Bounds
    /// two different costs: opencode's SQL `since` cutoff, and the mtime
    /// filter the file-based sources use to skip stale transcripts entirely
    /// rather than re-reading the whole history on every rescan — 851 files /
    /// 512 MB of real transcripts on the machine this was written against,
    /// which would otherwise mean every 2s poll re-opens and re-parses all of
    /// them forever, with `readers`/`parsers` growing without bound.
    public static let lookback: TimeInterval = 7 * 86_400

    /// Granularity `ClaudeTranscriptParser`/`CodexRolloutParser` coarsen `now`
    /// to when memoising `tokensToday`/`tokensLast5h` (and `CodexSource`'s
    /// analogous per-tick cost cache) — see
    /// `ClaudeTranscriptParser.session(path:now:)`. `session` runs every ~2s
    /// for every cached parser regardless of whether its file changed, so
    /// without memoisation a long-lived session re-folds its entire retained
    /// per-message usage log twice a tick for numbers that are, almost
    /// always, identical to last tick's. Neither window needs second-level
    /// precision — "today" and "trailing 5h" are both spec'd in whole
    /// minutes/hours — so treating every `now` within one bucket of this
    /// width as equivalent is exact enough. Local midnight always falls
    /// exactly on a boundary of this width (every real-world UTC offset is a
    /// multiple of 15 minutes, itself a multiple of this), so a bucket can
    /// never straddle the one crossing that must stay exact; the trailing-5h
    /// boundary is allowed to move by up to this much between recomputes,
    /// which is the one imprecision this deliberately trades for.
    public static let windowCacheGranularity: TimeInterval = 30

    /// Two `now` values map to the same bucket iff no multiple of
    /// `windowCacheGranularity` falls strictly between them — i.e. a cache
    /// keyed on this is valid for any `now` recorded up to
    /// `windowCacheGranularity` (minus an instant) after the one it was
    /// computed for.
    public static func windowCacheBucket(for now: Date) -> Int64 {
        Int64((now.timeIntervalSinceReferenceDate / windowCacheGranularity).rounded(.down))
    }
}
