import SwiftUI
import AppKit
import AgentMenuCore

@Observable
public final class AppViewModel {
    public var sessions: [AgentSession] = []
    /// Feature 1: a real calendar-day (local midnight) figure, summed from
    /// each session's `costToday` — computed by the parsers from real
    /// per-message timestamps, never accumulated from deltas observed after
    /// AgentMenu happened to launch.
    public var todayCost: Double = 0
    public var burn5h: Int = 0
    /// True when at least one currently-displayed session could not
    /// contribute a windowed figure (opencode, or an unreadable source) —
    /// `todayCost`/`burn5h` above are a sum over the sessions that COULD
    /// answer, not the whole fleet, so this must stay visible in the UI
    /// rather than let the total silently read as complete.
    public var figuresPartial: Bool = false
    public var attentionCount: Int = 0
    /// Sessions only SUSPECTED of being blocked (Codex's stall heuristic —
    /// see `SessionStore.inferredAttentionCount`). Kept apart from
    /// `attentionCount` so `StatusItemController` can badge it in caution
    /// colour instead of claiming false parity with an exact permission fact.
    public var inferredAttentionCount: Int = 0
    /// Round 2 Fix 4: project names behind `attentionCount`, so the menu bar
    /// title can name a single blocked session outright, or fall back to a
    /// count once there's more than one — thin passthrough over the pure,
    /// tested `Array<AgentSession>.exactAttentionProjects` in AgentMenuCore,
    /// the same shape `pageToShowOnOpen()` already uses for `mostUrgentAgentKind`.
    public var exactAttentionProjects: [String] { sessions.exactAttentionProjects }
    /// nil unless the user set their own budget — spec §6 forbids showing a
    /// percentage of a provider quota, which is not readable locally.
    public var burnFraction: Double?
    /// Feature 2: the lowest rolling-5h Claude burn AgentMenu has ever
    /// observed at the moment of a REAL rate-limit error — nil until at
    /// least one has actually happened. Set externally by `AppDelegate`,
    /// which owns the checkpoint this is measured from; never guessed here.
    public var observedCeiling: Int?
    /// Claude's own trailing-5h burn against `observedCeiling` — Claude
    /// only, never the cross-provider total, since the ceiling measures a
    /// Claude-specific quota. Nil until `observedCeiling` exists.
    public var rateLimitFraction: Double?
    public var installerStatus: (claude: Bool, codex: Bool) = (false, false)

    /// Round 2 Fix 3: which kinds' underlying data location exists on disk —
    /// independent of whether they currently have any live sessions. Set
    /// externally by `AppDelegate` once per tick from each `AgentSource`'s
    /// own `dataDirectoryExists`; `AppViewModel` has no I/O of its own (same
    /// shape as `observedCeiling` above).
    public var dataDirectoryPresent: Set<AgentKind> = []

    /// Round 2 Fix 3: which agent pages should currently be shown. An
    /// explicit `PreferencesView` toggle always wins; absent one, a kind
    /// auto-hides only when it has truly never been used — no live sessions
    /// AND no data directory — so a fresh user isn't shown a permanently
    /// empty page for a tool they don't have. Recomputed on every access
    /// (cheap: three dictionary/set lookups plus a `UserDefaults` read) so
    /// it always reflects the latest preference, sessions, and disk state
    /// without needing its own cache-invalidation.
    public var visibleAgentKinds: [AgentKind] {
        AgentVisibility.visible(
            preferences: AgentVisibilityPreference.all,
            hasSessions: Set(sessions.map(\.kind)),
            hasDataDirectory: dataDirectoryPresent)
    }

    /// Which agent's page `PagedPopoverView` is currently showing. Doubles
    /// as (a) the two-way `.scrollPosition(id:)` binding target the paged
    /// view swipes/taps update, and (b) "the last page the user was on" —
    /// the final fallback `pageToShowOnOpen()` uses when no agent currently
    /// demands attention. Defaults to the first page in the fixed order.
    public var currentPage: AgentKind = .claudeCode

    private let store: SessionStore
    // Kept, but no longer read by `refresh()` for the headline numbers below
    // (Feature 1 replaced that usage with the parsers' exact windowed
    // fields) — `recordBurn`/`burn` are still fed every tick by
    // `AppDelegate.tick()` and remain available should a future feature want
    // a generic rolling-window accumulator again.
    private var burn = RollingBurn()

    public init(store: SessionStore) { self.store = store }

    public func refresh(now: Date = Date()) {
        sessions = store.all

        // Feature 1: sum the parsers' exact windowed fields rather than
        // RollingBurn's launch-observed deltas — a session with a nil
        // windowed value (opencode; or a source that errored) simply
        // contributes nothing to the sum, which is mathematically the same
        // as excluding it, but the UI must say so rather than imply the
        // total covers every agent.
        figuresPartial = sessions.contains { $0.tokensToday == nil }
        todayCost = sessions.compactMap(\.costToday).reduce(0, +)
        // Round 2 Fix 1: `workTokens` (input+output), not `.total` — this
        // feeds HeaderView's displayed "LAST 5H" count and the budget
        // fraction below it directly. Cache-read re-counts the same prior
        // context on every turn and would otherwise dominate both figures
        // (measured 92% of `.total` on a cache-heavy real session) without
        // reflecting any budget the user actually cares about spending.
        burn5h = sessions.compactMap(\.tokensLast5h).reduce(0) { $0 + $1.workTokens }

        attentionCount = store.attentionCount
        inferredAttentionCount = store.inferredAttentionCount
        let budget = UserDefaults.standard.integer(forKey: "agentmenu.burnBudget5h")
        burnFraction = budget > 0 ? min(1.0, Double(burn5h) / Double(budget)) : nil

        // Feature 2: percentage against a MEASURED ceiling, Claude-only
        // since the ceiling itself only ever comes from a Claude rate-limit
        // event. `observedCeiling` is set externally before `refresh()` runs.
        let claudeBurn5h = sessions.filter { $0.kind == .claudeCode }
            .compactMap(\.tokensLast5h).reduce(0) { $0 + $1.total }
        rateLimitFraction = observedCeiling.flatMap { $0 > 0 ? Double(claudeBurn5h) / Double($0) : nil }
    }

    /// Called by the app when a source reports new totals.
    public func recordBurn(tokens: Int, cost: Double?, at: Date) {
        burn.record(tokens: tokens, cost: cost, at: at)
    }

    /// Which page the popover should open to (round-2 fix: "whichever agent
    /// sent the last notification"). The actual tie-breaking rule
    /// (exact permission > inferred permission > most-recent turn-finished)
    /// is `Array<AgentSession>.mostUrgentAgentKind`, a pure function in
    /// AgentMenuCore with its own test coverage — this is a thin, otherwise
    /// untestable-UI-glue accessor over it, using `currentPage` (the last
    /// page the user was on) as the final fallback.
    ///
    /// Round 2 Fix 3: both the candidates AND the fallback are restricted to
    /// `visibleAgentKinds`, so this can never return a page `PagedPopoverView`
    /// doesn't have — a dot/page mismatch is explicitly called out as a bug.
    /// The only way a hidden agent's session can be "most urgent" at all is
    /// an explicit Preferences toggle hiding a kind that still has live
    /// sessions (never-seen agents cannot have any); in that deliberate case
    /// the popover opens on the next-most-urgent VISIBLE page rather than a
    /// page that does not exist.
    public func pageToShowOnOpen() -> AgentKind {
        let visible = visibleAgentKinds
        guard !visible.isEmpty else { return currentPage }
        let visibleSet = Set(visible)
        let candidates = sessions.filter { visibleSet.contains($0.kind) }
        let fallback = visibleSet.contains(currentPage) ? currentPage : visible[0]
        return candidates.mostUrgentAgentKind(fallback: fallback)
    }

    /// Focus the window this session lives in. Best-effort by design: if the
    /// target is gone we do nothing rather than raise an error (spec §8).
    public func focus(_ session: AgentSession) {
        if let pid = session.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        // Fall back to revealing the transcript so the click is never a no-op.
        if let path = session.transcriptPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}
