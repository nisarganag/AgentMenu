import SwiftUI
import AppKit
import AgentMenuCore

@Observable
public final class AppViewModel {
    public var sessions: [AgentSession] = []
    public var todayCost: Double = 0
    public var burn5h: Int = 0
    public var attentionCount: Int = 0
    /// Sessions only SUSPECTED of being blocked (Codex's stall heuristic —
    /// see `SessionStore.inferredAttentionCount`). Kept apart from
    /// `attentionCount` so `StatusItemController` can badge it in caution
    /// colour instead of claiming false parity with an exact permission fact.
    public var inferredAttentionCount: Int = 0
    /// nil unless the user set their own budget — spec §6 forbids showing a
    /// percentage of a provider quota, which is not readable locally.
    public var burnFraction: Double?
    public var installerStatus: (claude: Bool, codex: Bool) = (false, false)

    /// Which agent's page `PagedPopoverView` is currently showing. Doubles
    /// as (a) the two-way `.scrollPosition(id:)` binding target the paged
    /// view swipes/taps update, and (b) "the last page the user was on" —
    /// the final fallback `pageToShowOnOpen()` uses when no agent currently
    /// demands attention. Defaults to the first page in the fixed order.
    public var currentPage: AgentKind = .claudeCode

    private let store: SessionStore
    private var burn = RollingBurn()

    public init(store: SessionStore) { self.store = store }

    public func refresh(now: Date = Date()) {
        sessions = store.all
        attentionCount = store.attentionCount
        inferredAttentionCount = store.inferredAttentionCount
        burn5h = burn.tokens(window: RollingBurn.fiveHours, now: now)
        todayCost = burn.cost(window: 24 * 3600, now: now)
        let budget = UserDefaults.standard.integer(forKey: "agentmenu.burnBudget5h")
        burnFraction = budget > 0 ? min(1.0, Double(burn5h) / Double(budget)) : nil
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
    public func pageToShowOnOpen() -> AgentKind {
        sessions.mostUrgentAgentKind(fallback: currentPage)
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
