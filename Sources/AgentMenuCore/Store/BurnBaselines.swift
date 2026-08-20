import Foundation

/// Pure helper behind `AgentMenuApp`'s per-tick burn-baseline pruning
/// (Fix 5 / review Ruling F63). Extracted to a standalone type so the
/// pruning RULE itself has direct test coverage, independent of
/// `DispatchQueue` timing or real `AgentSource` I/O.
public enum BurnBaselines {
    /// Keeps a baseline if its session id was reported live this pass, OR if
    /// its `AgentKind` is in `erroredKinds`.
    ///
    /// Before this rule existed, `main.swift`'s tick loop `continue`d past a
    /// source the moment `source.lastError` was set — BEFORE that source's
    /// session ids were added to the live set — so a single unreadable
    /// directory entry anywhere in, say, `~/.claude/projects` wiped the
    /// burn baseline for every OTHER Claude session too, not just the
    /// unreadable one. The very next clean tick then found `prior == nil`
    /// for all of them, and recorded each session's entire cumulative
    /// token/cost total as if it were brand-new activity — the same class of bug
    /// as the round-2 Finding-1 CRITICAL (already fixed for the
    /// merged-group identity-flip case), just reached through a transient
    /// per-kind read error instead. A kind that failed to report this tick
    /// has no fresh evidence either way, so its baselines are carried
    /// forward untouched rather than being treated as "gone."
    public static func pruned<Value>(
        _ baselines: [String: Value], liveIds: Set<String>, erroredKinds: Set<AgentKind>
    ) -> [String: Value] {
        baselines.filter { key, _ in
            liveIds.contains(key) || erroredKinds.contains { key.hasPrefix("\($0.rawValue)/") }
        }
    }
}
