import Foundation

/// Which agent's popover page most deserves the user's attention right now
/// (round-2 fix: "open the popover on whichever agent sent the last
/// notification").
///
/// Deliberately independent of `Notifier`: every signal this needs — an
/// exact permission prompt, an inferred one, or a just-finished turn —
/// already lives on `AgentSession.state` by the time `SessionStore.all`
/// produces it (push overrides are folded in there). Keeping the decision
/// here, as a pure function over the session list, means "jump to whichever
/// agent just demanded attention" is testable without constructing a
/// Notifier, an AppViewModel, or any AppKit type.
extension Array where Element == AgentSession {
    /// - Parameter fallback: what to return when nothing currently demands
    ///   attention — callers pass "the page the user was already on", so the
    ///   full preference order is: exact permission prompt, then inferred
    ///   permission prompt, then most-recently-finished turn, then last page
    ///   viewed.
    public func mostUrgentAgentKind(fallback: AgentKind) -> AgentKind {
        if let kind = latestKind(ofState: { s in
            if case .awaitingPermission(let r, .exact) = s.state { return r.since }
            return nil
        }) { return kind }

        if let kind = latestKind(ofState: { s in
            if case .awaitingPermission(let r, .inferred) = s.state { return r.since }
            return nil
        }) { return kind }

        if let kind = latestKind(ofState: { s in
            if case .done(let at) = s.state { return at }
            return nil
        }) { return kind }

        return fallback
    }

    /// Among sessions where `timestamp` returns non-nil, the kind of
    /// whichever has the latest timestamp. `timestamp` doubles as the
    /// state-matching predicate (nil = "doesn't qualify for this tier"), so
    /// each tier above is a single pass over the array.
    private func latestKind(ofState timestamp: (AgentSession) -> Date?) -> AgentKind? {
        var best: (kind: AgentKind, at: Date)?
        for s in self {
            guard let at = timestamp(s) else { continue }
            if best == nil || at > best!.at { best = (s.kind, at) }
        }
        return best?.kind
    }

    /// Round 2 Fix 4: project names of sessions awaiting permission at
    /// EXACT confidence, in display order — the menu bar title needs the
    /// actual identity (not just `SessionStore.attentionCount`'s raw
    /// number) to name a single blocked session outright. Deliberately
    /// excludes `.inferred` sessions, for the same reason
    /// `SessionStore.attentionCount` does: a guess must never be captioned
    /// with the same certainty as a fact-backed permission prompt.
    public var exactAttentionProjects: [String] {
        compactMap { s in
            if case .awaitingPermission(_, .exact) = s.state { return s.project }
            return nil
        }
    }
}
