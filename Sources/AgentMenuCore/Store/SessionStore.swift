import Foundation

/// Merges the push channel (hook events) and the pull channel (file/DB
/// polling) into a single, display-ordered list of sessions. This is the
/// meeting point of the two-channel design (spec §2).
///
/// Push is authoritative for state transitions; pull is authoritative for the
/// numbers (tokens, cost, activity text). A push-derived state override holds
/// for `pushWinsWindow` before file evidence is allowed to speak for that
/// session again — so a dropped "permission-resolved" event self-heals into a
/// correct state instead of pinning a red dot on screen forever.
public final class SessionStore: @unchecked Sendable {
    /// How long a push event's state override outranks file evidence for the
    /// same session. Named because later tasks reference it directly.
    public static let pushWinsWindow: TimeInterval = 5

    /// A push-derived state that temporarily outranks whatever the file
    /// watchers report for the same session.
    private struct Override {
        let state: SessionState
        let at: Date
        /// Permission overrides are sticky: they survive past `pushWinsWindow`
        /// until an explicit resolve/start event arrives, or the file channel
        /// shows the session active more recently than the override — proof
        /// the prompt was answered even though the event was lost. A
        /// turn-finished override is not sticky: it simply expires once the
        /// window passes.
        let sticky: Bool
    }

    private let lock = NSLock()
    private var byKind: [AgentKind: [AgentSession]] = [:]
    private var overrides: [String: Override] = [:]      // keyed by AgentSession.id

    public init() {}

    // MARK: - Pull channel (file/DB polling)

    /// Replaces the full session list reported for one `kind`. Other kinds'
    /// sessions are untouched.
    public func apply(sessions: [AgentSession], kind: AgentKind, now: Date) {
        lock.lock(); defer { lock.unlock() }
        byKind[kind] = sessions
        // Release overrides whose session this source no longer reports. Every
        // source has bounded retention (opencode is `LIMIT 50` plus a `since`
        // cutoff; the transcript sources age out too), and this app is meant to
        // sit in the menu bar for weeks — without this, a sticky override for a
        // session that rotated out of the source's window would leak in
        // `overrides` for the rest of the process's life. This is safe: the row
        // is already invisible (`all` only ever emits sessions present in
        // `byKind`), so releasing a hold on one can never create a false stuck
        // dot.
        let live = Set(sessions.map(\.id))
        let prefix = "\(kind.rawValue)/"
        overrides = overrides.filter { !$0.key.hasPrefix(prefix) || live.contains($0.key) }
        expireOverrides(now: now)
    }

    /// Renders a source that failed to read as a single visible, explanatory
    /// row rather than silently dropping it or crashing the app.
    public func markUnavailable(_ kind: AgentKind, reason: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        byKind[kind] = [AgentSession(
            kind: kind, nativeId: "unavailable", project: kind.displayName, directory: "",
            state: .unavailable(reason), startedAt: now, lastEventAt: now)]
        expireOverrides(now: now)
    }

    // MARK: - Push channel (hook spool)

    public func apply(events: [SpoolEvent], now: Date) {
        lock.lock(); defer { lock.unlock() }
        for e in events {
            let key = "\(e.agent.rawValue)/\(e.sessionId)"
            switch e.event {
            case .permissionRequired:
                overrides[key] = Override(
                    state: .awaitingPermission(
                        PermissionRequest(tool: e.tool ?? "—", summary: e.summary ?? "", since: e.date),
                        confidence: .exact),
                    at: e.date, sticky: true)
            case .permissionResolved, .turnStarted:
                overrides.removeValue(forKey: key)
            case .turnFinished:
                overrides[key] = Override(state: .done(at: e.date), at: e.date, sticky: false)
            }
        }
        expireOverrides(now: now)
    }

    /// Drops overrides whose authority has run out.
    ///
    /// Non-sticky overrides simply time out. Sticky (permission) overrides
    /// are only released once file evidence proves the session moved on
    /// after the override was set — that self-heal is what stops a dropped
    /// "resolved" event from pinning a red dot forever.
    private func expireOverrides(now: Date) {
        var expiredKeys: [String] = []
        for (key, o) in overrides {
            guard now.timeIntervalSince(o.at) > Self.pushWinsWindow else { continue }
            if !o.sticky {
                expiredKeys.append(key)
            } else if let s = flattenLocked().first(where: { $0.id == key }), s.lastEventAt > o.at {
                expiredKeys.append(key)
            }
        }
        for key in expiredKeys { overrides.removeValue(forKey: key) }
    }

    private func flattenLocked() -> [AgentSession] {
        byKind.values.flatMap { $0 }
    }

    // MARK: - Read

    /// Every known session across all kinds, with push overrides applied, in
    /// display order (spec §5).
    public var all: [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return flattenLocked().map { session in
            guard let o = overrides[session.id] else { return session }
            var overridden = session
            overridden.state = o.state
            return overridden
        }.sortedForDisplay()
    }

    /// Count of sessions blocked on the user with an EXACT signal (Claude's
    /// Notification hook; opencode's own pending-tool-part record) — drives
    /// the menu bar's alert badge.
    ///
    /// This must NEVER include `.inferred` sessions. The badge is the only
    /// thing visible with the popover closed and the entire point of the
    /// app; flattening a Codex stall guess into the same red dot as a real
    /// Claude permission prompt presents a guess as a fact at the app's most
    /// prominent surface (Fix 3 / review Ruling F61). The row UI is already
    /// scrupulous about this distinction (hollow ring, "MAYBE WAITING",
    /// worded as a question) — the badge must be too.
    public var attentionCount: Int {
        // `all` takes and releases `lock` itself before returning; do not lock
        // again here; `NSLock` is not reentrant and a second `lock()` on this
        // thread would deadlock rather than fail a test.
        all.filter {
            if case .awaitingPermission(_, .exact) = $0.state { return true }
            return false
        }.count
    }

    /// Count of sessions only SUSPECTED of being blocked — Codex's stall
    /// heuristic, which can never be `.exact` because Codex logs no approval
    /// events at all. Kept separate from `attentionCount` so the menu bar can
    /// render it at a lower-certainty caution colour rather than alert.
    public var inferredAttentionCount: Int {
        all.filter {
            if case .awaitingPermission(_, .inferred) = $0.state { return true }
            return false
        }.count
    }
}
