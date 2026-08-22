import Foundation

/// Tuning for the landing-page decision below.
public enum AttentionRouting {
    /// How recently a turn must have finished for "an agent just finished"
    /// to still be the reason the popover is being opened.
    ///
    /// Bug (owner report): with no bound at all, a `.done` session was
    /// treated as a live notification forever. Every session ends in `.done`
    /// and sources retain a week of them, so the tier was almost always
    /// matched by something — an opencode turn that had finished an hour
    /// earlier, with its app since closed, still captured the landing page.
    /// Past this age the user has demonstrably walked away, and the page
    /// they last chose themselves is the better answer.
    ///
    /// 600s deliberately matches `OpencodeDatabase.permissionFreshness`, and
    /// for the same reason: these windows are measured in the time a person
    /// takes to notice something and come back to it, not in machine time.
    public static let doneFreshness: TimeInterval = 600
}

/// Which agent's popover page most deserves the user's attention right now.
///
/// Deliberately independent of `Notifier`: every signal this needs — an
/// exact permission prompt, an inferred one, a running turn, or a just-
/// finished one — already lives on `AgentSession.state` by the time
/// `SessionStore.all` produces it (push overrides are folded in there).
/// Keeping the decision here, as a pure function over the session list,
/// means "jump to whichever agent actually wants me" is testable without
/// constructing a Notifier, an AppViewModel, or any AppKit type.
extension Array where Element == AgentSession {
    /// Preference order, highest first:
    ///
    ///  1. an exact permission prompt — most recently raised
    ///  2. an inferred permission prompt — most recently raised
    ///  3. a **running** session — the one running *longest*
    ///  4. a turn finished within `AttentionRouting.doneFreshness` — most recent
    ///  5. `fallback`
    ///
    /// Tiers 1–2 outrank 3 because being blocked on the user outranks merely
    /// being busy: a working agent needs nothing, and the entire point of the
    /// app is surfacing the one that does.
    ///
    /// Tier 3 is the owner's rule, verbatim: "take me to the page of
    /// whichever agent session is running, and if multiple are running the
    /// default should be whichever was running longer." Note it orders by
    /// EARLIEST start — the opposite of every other tier, all of which take
    /// the most recent event. That asymmetry is intentional, not a slip:
    /// elsewhere the timestamp marks a moment that just demanded attention,
    /// whereas here it marks the beginning of a stretch, and the longer the
    /// stretch the more likely it is the session the user came to check on.
    ///
    /// - Parameter now: evaluation time — tier 4 is the only age-sensitive
    ///   tier. A permission prompt is deliberately never aged out here: it
    ///   stays unanswered until it is answered, however long that takes, and
    ///   `SessionStore` already owns releasing prompts that stopped being
    ///   real.
    /// - Parameter fallback: what to return when nothing qualifies — callers
    ///   pass "the page the user was already on."
    public func mostUrgentAgentKind(now: Date, fallback: AgentKind) -> AgentKind {
        if let kind = latestKind(ofState: { s in
            if case .awaitingPermission(let r, .exact) = s.state { return r.since }
            return nil
        }) { return kind }

        if let kind = latestKind(ofState: { s in
            if case .awaitingPermission(let r, .inferred) = s.state { return r.since }
            return nil
        }) { return kind }

        // Running: longest-running wins, so `startedAt` (when the stretch
        // began), never the activity's own timestamp (when it last moved).
        if let kind = earliestKind(ofState: { s in
            if case .working = s.state { return s.startedAt }
            return nil
        }) { return kind }

        if let kind = latestKind(ofState: { s in
            if case .done(let at) = s.state,
               now.timeIntervalSince(at) <= AttentionRouting.doneFreshness { return at }
            return nil
        }) { return kind }

        return fallback
    }

    /// Among sessions where `timestamp` returns non-nil, the kind of
    /// whichever has the latest timestamp. `timestamp` doubles as the
    /// state-matching predicate (nil = "doesn't qualify for this tier"), so
    /// each tier above is a single pass over the array.
    private func latestKind(ofState timestamp: (AgentSession) -> Date?) -> AgentKind? {
        bestKind(ofState: timestamp, preferring: >)
    }

    /// `latestKind`'s mirror, for the one tier that wants the oldest rather
    /// than the newest timestamp.
    private func earliestKind(ofState timestamp: (AgentSession) -> Date?) -> AgentKind? {
        bestKind(ofState: timestamp, preferring: <)
    }

    private func bestKind(ofState timestamp: (AgentSession) -> Date?,
                          preferring beats: (Date, Date) -> Bool) -> AgentKind? {
        var best: (kind: AgentKind, at: Date)?
        for s in self {
            guard let at = timestamp(s) else { continue }
            if best == nil || beats(at, best!.at) { best = (s.kind, at) }
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
