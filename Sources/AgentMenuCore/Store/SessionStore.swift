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

    /// Longest a sticky (permission) override may hold once its session's
    /// transcript has stopped moving, even with no resolve event and no
    /// process signal at all. Matches spec §2's liveness grace.
    ///
    /// Bug 1: without this, killing the agent's terminal (or the whole
    /// machine's network/process going away mid-prompt) left the red dot
    /// pinned forever — the transcript never advances again, so the
    /// existing "file evidence moved past the override" release condition
    /// can never fire. This is the backstop for when `runningKinds` can't
    /// help either (process liveness unknown, or another process of the
    /// same kind is still around for an unrelated session): a real prompt
    /// the user is actively looking at keeps its transcript fresh well
    /// inside 90s, so this only ever fires once a prompt is certainly stale.
    public static let stickyOverrideStaleness: TimeInterval = 90

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
    /// Which agent kinds have at least one process running, as of the most
    /// recent `apply(runningKinds:now:)` call. `nil` until that method has
    /// been called at least once — the store must never treat "haven't been
    /// told yet" as "confirmed nothing is running," or every sticky override
    /// would look process-dead on the very first tick, before `ProcessScanner`
    /// has run even once. The store does no process scanning itself (Bug 1 /
    /// Bug 2): this is the only channel through which it learns liveness.
    private var runningKinds: Set<AgentKind>?

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

    // MARK: - Process liveness (Bug 1 / Bug 2)

    /// Tells the store which agent kinds currently have at least one running
    /// process, per `ProcessScanner`. The store performs no I/O of its own —
    /// callers (namely `AppDelegate.tick()`, where the scan already happens
    /// for other reasons, e.g. focus-on-click) call this once per tick with
    /// a fresh result.
    ///
    /// Two independent uses of the same signal:
    ///  - Bug 1: a sticky permission override for a kind with NO running
    ///    process anywhere is released immediately — no process of that
    ///    kind means no live prompt for the user to be looking at, however
    ///    stale or fresh the last-read transcript happens to be.
    ///  - Bug 2: an opencode session reported `.working` for a kind with no
    ///    running process is downgraded to `.idle` in `all` below — a dead
    ///    process cannot genuinely be mid-turn, regardless of what a
    ///    durable DB row still says. Scoped to opencode only (see `all`'s
    ///    doc comment): Claude/Codex already self-correct out of `.working`
    ///    within `stallThreshold` (25s) purely from transcript staleness —
    ///    that is WHY the bug report never named them — so generalizing this
    ///    to every kind would be an unrequested behaviour change with no
    ///    reported problem behind it, and it would fight Bug 1's own test
    ///    scenario: releasing a claudeCode override when its process vanishes
    ///    must reveal the pull channel's actual `.working` state, not a
    ///    second, unrelated demotion of it.
    public func apply(runningKinds: Set<AgentKind>, now: Date) {
        lock.lock(); defer { lock.unlock() }
        self.runningKinds = runningKinds
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
    /// are released by any ONE of three independent proofs the prompt can no
    /// longer be live:
    ///  1. File evidence proves the session moved on after the override was
    ///     set — the original self-heal, for a dropped "resolved" event.
    ///  2. Bug 1: no process of this override's agent kind is running at
    ///     all — the terminal (or the whole app) is gone.
    ///  3. Bug 1 backstop: the session's transcript has been silent past
    ///     `stickyOverrideStaleness`, regardless of process state — covers
    ///     the case where liveness can't be attributed (or another process
    ///     of the same kind is running an unrelated session).
    /// Without ALL THREE, a killed terminal pins a red dot forever: the
    /// transcript never advances again, so (1) alone never fires.
    private func expireOverrides(now: Date) {
        var expiredKeys: [String] = []
        for (key, o) in overrides {
            guard now.timeIntervalSince(o.at) > Self.pushWinsWindow else { continue }
            guard o.sticky else { expiredKeys.append(key); continue }

            let session = flattenLocked().first(where: { $0.id == key })
            if let session, session.lastEventAt > o.at {
                expiredKeys.append(key)
            } else if let runningKinds, let kind = Self.agentKind(ofOverrideKey: key),
                      !runningKinds.contains(kind) {
                expiredKeys.append(key)
            } else if let session, now.timeIntervalSince(session.lastEventAt) > Self.stickyOverrideStaleness {
                expiredKeys.append(key)
            }
        }
        for key in expiredKeys { overrides.removeValue(forKey: key) }
    }

    /// Recovers the `AgentKind` an override key was filed under (keys are
    /// always `"\(kind.rawValue)/\(nativeId)"`, same shape `apply(sessions:)`
    /// already parses via `hasPrefix` for its own release rule).
    private static func agentKind(ofOverrideKey key: String) -> AgentKind? {
        AgentKind.allCases.first { key.hasPrefix("\($0.rawValue)/") }
    }

    private func flattenLocked() -> [AgentSession] {
        byKind.values.flatMap { $0 }
    }

    // MARK: - Read

    /// Every known session across all kinds, with push overrides applied, in
    /// display order (spec §5).
    public var all: [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return flattenLocked().map { session -> AgentSession in
            var s = session
            // Bug 2: opencode's DB simply stops being written the moment its
            // app quits, so nothing but `idleThreshold` would otherwise ever
            // demote a session frozen mid-"working". A confirmed-dead
            // process is proof right now, not a guess. Scoped to `.opencode`
            // deliberately — Claude/Codex already self-correct out of
            // `.working` within `stallThreshold` (25s) from transcript
            // staleness alone, with no process signal needed, which is why
            // only opencode was reported stuck. Gated on `runningKinds`
            // being known (non-nil) so this never fires before the store has
            // actually been told anything, e.g. the first tick before
            // ProcessScanner has run even once.
            if case .working = s.state, s.kind == .opencode,
               let runningKinds, !runningKinds.contains(s.kind) {
                s.state = .idle
            }
            guard let o = overrides[s.id] else { return s }
            var overridden = s
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
