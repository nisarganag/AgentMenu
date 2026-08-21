import Foundation

/// Round 2 Fix 2: detects a session's context fill crossing ~80%, so
/// `AppDelegate` can fire exactly one notification per crossing instead of
/// one per tick. Pure decision logic, mirrors `RateLimitCeiling`/
/// `BurnBaselines`: the RULE is unit-tested here, independent of `Notifier`,
/// `DispatchQueue` timing, or real `AgentSource` I/O.
///
/// 80% is not an arbitrary round number here — it is where `SegmentedMeter`
/// already shifts its own tail from accent to caution colour, i.e. the point
/// this app already treats as "worth a second look." Crossing it is also the
/// point where compacting is still comfortably ahead of the limit rather
/// than a last-second scramble, which is what makes it actionable rather
/// than merely descriptive.
public enum ContextWarnings {
    public static let threshold: Double = 0.80

    /// Given this tick's full session list and the set of session ids
    /// already warned since their last dip below `threshold`, returns the
    /// sessions that just crossed upward, and updates `armed` in place:
    ///
    ///  - A session at or above `threshold` whose id is not yet in `armed`
    ///    has just crossed — it is returned AND added to `armed`, so it will
    ///    not fire again on the next tick while it stays up there.
    ///  - A session that has dropped back below `threshold` (e.g. the user
    ///    ran `/compact`) is removed from `armed`, so a later re-climb past
    ///    `threshold` is treated as a fresh crossing and fires again.
    ///  - A session with no known context window (`context == nil`) never
    ///    participates at all — there is no percentage to cross, and it
    ///    must never be treated as "0%, therefore below threshold" (which
    ///    would at least be harmless) or, worse, made to look like a real
    ///    reading.
    ///  - Ids for sessions no longer present this tick (ended, aged out of
    ///    the source's retention window, or transiently lost their context
    ///    window) are dropped from `armed`, so it cannot grow for the life
    ///    of the process. Worst case this causes one extra notification if
    ///    such a session reappears still above threshold — never a stuck
    ///    "can never warn again."
    @discardableResult
    public static func crossed(
        _ sessions: [AgentSession], armed: inout Set<String>
    ) -> [AgentSession] {
        var firing: [AgentSession] = []
        var stillEligible: Set<String> = []
        for session in sessions {
            guard let fraction = session.context?.fraction else { continue }
            stillEligible.insert(session.id)
            if fraction >= threshold {
                if !armed.contains(session.id) {
                    firing.append(session)
                    armed.insert(session.id)
                }
            } else {
                armed.remove(session.id)
            }
        }
        armed.formIntersection(stillEligible)
        return firing
    }
}
