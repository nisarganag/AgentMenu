import Foundation

/// Round 2 Fix 3: which agent pages the popover should show. Pure decision
/// rule, independent of `UserDefaults`/SwiftUI — the UI layer owns reading
/// the actual preference and data-directory state and passes it in here, the
/// same separation `RateLimitCeiling`/`BurnBaselines`/`ContextWarnings` use.
public enum AgentVisibility {
    /// - Parameters:
    ///   - preferences: the user's explicit per-kind choice, if any. A kind
    ///     absent from this dictionary has never been touched in
    ///     Preferences — displayed there as ON (all three default to
    ///     visible) but still eligible for the auto-hide rule below, unlike
    ///     an explicit `true`, which always wins regardless of usage.
    ///   - hasSessions: kinds with at least one currently-known session.
    ///   - hasDataDirectory: kinds whose underlying storage location exists
    ///     on disk right now, regardless of whether any session is
    ///     currently inside the source's own lookback window — a session
    ///     that aged out is "idle," not "never used."
    /// - Returns: kinds to show, in `AgentKind.allCases`'s fixed order (the
    ///   order the popover has always paged through), so a user who sees
    ///   all three still sees them in exactly the order they always have.
    public static func visible(
        preferences: [AgentKind: Bool],
        hasSessions: Set<AgentKind>,
        hasDataDirectory: Set<AgentKind>
    ) -> [AgentKind] {
        AgentKind.allCases.filter { kind in
            if let explicit = preferences[kind] { return explicit }
            // Never been seen: no live session AND no trace it was ever
            // used. Either alone is real evidence the tool exists — only
            // their conjunction means "never touched."
            return hasSessions.contains(kind) || hasDataDirectory.contains(kind)
        }
    }
}
