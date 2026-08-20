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
}
