import Foundation

/// Feature 2: learn Claude's real rate-limit ceiling by measuring it,
/// instead of assuming one. `rateLimits` is null on disk for every real
/// transcript on this machine (see `RollingBurn`'s doc comment) — spec §6
/// correctly refuses to turn that into a fabricated percentage. But when
/// Claude actually rate-limits the user (`apiErrorStatus == 429`, see
/// `ClaudeTranscriptParser`), the rolling 5-hour burn AT THAT MOMENT is a
/// real, measured data point about where the ceiling sits, and AgentMenu can
/// remember it.
///
/// Pure decision logic, deliberately separated from `AppDelegate`'s timing
/// and I/O — mirrors `BurnBaselines`.
public enum RateLimitCeiling {
    /// A handful of observations is enough to be useful; unbounded growth
    /// serves no purpose (the ceiling can drift over time, so only recent
    /// observations should count anyway).
    public static let historyLimit = 10

    /// A rate-limit timestamp discovered more than this long after the fact
    /// is treated as historical, not live — e.g. the very first scan of a
    /// transcript that happens to fall inside the lookback window, which
    /// reads the file's entire history in one pass. Recording "whatever
    /// Claude's trailing-5h burn happens to be right now" against a
    /// days-old event would itself be a plausible-looking lie, since the
    /// burn at discovery time has no relationship to the burn when the
    /// limit actually fired.
    public static let freshnessWindow: TimeInterval = 300

    /// Given the freshest rate-limit timestamp seen this tick (if any) and
    /// the checkpoint's prior watermark, decide whether to fold in a new
    /// observed ceiling. Returns `previous` unchanged when there is nothing
    /// new to record.
    ///
    /// A timestamp is folded in as a ceiling only once — every later tick
    /// reports the exact same timestamp again (the parser never clears
    /// `lastRateLimitAt` once set), so `newest <= priorAt` after the first
    /// pass is what stops it from being recorded a second time. A stale
    /// (non-fresh) timestamp still ADVANCES the watermark, so it is never
    /// reconsidered on a later tick — it is simply never recorded as a
    /// ceiling.
    public static func recording(
        rateLimitTimestamps: [Date], now: Date, burn5h: Int,
        previous: (ceilings: [Int], lastAt: Date?)
    ) -> (ceilings: [Int], lastAt: Date?) {
        guard let newest = rateLimitTimestamps.max() else { return previous }
        if let priorAt = previous.lastAt, newest <= priorAt { return previous }
        guard now.timeIntervalSince(newest) <= freshnessWindow else {
            return (previous.ceilings, newest)   // seen, but too stale to trust as live
        }
        var ceilings = previous.ceilings
        ceilings.append(burn5h)
        if ceilings.count > historyLimit { ceilings.removeFirst(ceilings.count - historyLimit) }
        return (ceilings, newest)
    }

    /// A conservative estimate of the ceiling: the LOWEST ever observed, so
    /// a warning fires early rather than late. Nil until at least one has
    /// ever been observed — never a guess.
    public static func conservativeCeiling(_ ceilings: [Int]) -> Int? {
        ceilings.min()
    }
}
