import Foundation

extension AgentSession {
    /// How long this session actually spanned: first recorded activity to
    /// last. Takes no `now`, deliberately.
    ///
    /// The row used to render `now - startedAt`, which is the session's AGE,
    /// not its length — so a finished session's displayed duration kept
    /// climbing for as long as its transcript stayed on disk (transcripts are
    /// retained for 7 days). Measured on the owner's machine: sessions that
    /// genuinely ran 6 and 12 minutes displayed as 167.9h and 187.0h, the
    /// difference being entirely the days since they ended.
    ///
    /// Having no `now` parameter is the fix, not an omission. A finished
    /// session's length is a fact about the past with no clock left to drift
    /// against, and a live session needs no special case either: its own
    /// `lastEventAt` advances as it works, so the figure tracks the work
    /// rather than the wall clock.
    ///
    /// This still includes idle gaps WITHIN the session — a session left open
    /// over lunch counts the lunch. That is the honest reading of "how long
    /// was this session", and separating true working time from waiting-on-me
    /// time would require inferring which gaps were which. What it no longer
    /// does is count time after the session was over.
    ///
    /// Clamped at zero on the same grounds as `TokenStats.-`: a rescan racing
    /// a write must not produce a negative duration to format.
    public var span: TimeInterval {
        max(0, lastEventAt.timeIntervalSince(startedAt))
    }
}

/// Compact duration rendering, shared so the row and its tests agree.
public enum DurationFormat {
    /// `"45s"`, `"1m30s"`, `"6m"`, `"167h54m"`. Exact seconds are dropped from
    /// a whole-minute figure so common values read as `6m`, not `6m0s`.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60 == 0 ? "" : "\(s % 60)s")" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
