import SwiftUI
import AgentMenuCore

public struct SessionRowView: View {
    let session: AgentSession
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var accent: Color { Theme.accent(for: session.kind, dark: dark) }

    public init(session: AgentSession, onTap: @escaping () -> Void) {
        self.session = session; self.onTap = onTap
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Identity spine — always the agent accent, never state-coloured.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                topLine
                activityLine
                telemetryLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            StatusDot(state: session.state, accent: accent,
                      alert: Theme.alert(dark: dark), caution: Theme.caution(dark: dark),
                      idle: Theme.textTertiary(dark: dark))
            Text(session.project)
                .font(Theme.project)
                .foregroundStyle(Theme.textPrimary(dark: dark))
            if let branch = session.branch {
                Text("⌥ \(branch)")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary(dark: dark))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            stateBadge
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch session.state {
        case .awaitingPermission(_, .exact):
            Text("NEEDS PERMISSION")
                .font(Theme.label).foregroundStyle(Theme.alert(dark: dark))
        case .awaitingPermission(let r, .inferred):
            // Worded as a question: Codex logs no approval events (spec §3.2).
            Text("MAYBE WAITING \(Self.elapsed(since: r.since))")
                .font(Theme.label.monospacedDigit()).foregroundStyle(Theme.caution(dark: dark))
        case .working:
            Text("WORKING").font(Theme.label).foregroundStyle(Theme.textSecondary(dark: dark))
        case .done:
            Text("DONE").font(Theme.label).foregroundStyle(Theme.textTertiary(dark: dark))
        case .idle:
            Text("IDLE").font(Theme.label).foregroundStyle(Theme.textTertiary(dark: dark))
        case .unavailable:
            Text("UNAVAILABLE").font(Theme.label).foregroundStyle(Theme.caution(dark: dark))
        }
    }

    private var activityLine: some View {
        HStack(spacing: 4) {
            Text(activityText)
                .font(Theme.activity)
                .foregroundStyle(Theme.textSecondary(dark: dark))
                .lineLimit(1)
                .truncationMode(.middle)   // keeps tool name AND path tail visible
            Spacer(minLength: 6)
            if let a = session.lastActivity {
                // Age of THIS step — what tells you it is stuck.
                Text(Self.elapsed(since: a.at))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary(dark: dark))
            }
        }
    }

    private var activityText: String {
        if case .unavailable(let why) = session.state { return why }
        return session.lastActivity?.line ?? "—"
    }

    private var telemetryLine: some View {
        HStack(spacing: 8) {
            if let ctx = session.context {
                SegmentedMeter(fraction: ctx.fraction, accent: accent,
                               caution: Theme.caution(dark: dark),
                               alert: Theme.alert(dark: dark),
                               empty: Theme.hairline(dark: dark))
                Text("\(Int(ctx.fraction * 100))%")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary(dark: dark))
            }
            // Round 2 Fix 1: `workTokens` (input+output), not `.total` — a
            // long session's cache-read alone can outweigh the tokens it
            // actually read/wrote by two orders of magnitude (measured
            // 1.2B vs 5.3M `.total`-vs-`workTokens` on one real session
            // here), which reads as a plausible-looking lie, not a bigger
            // number. `.total` is still exactly what `cost` above and the
            // context meter below are priced/filled from — unchanged.
            Text(Self.compact(session.tokens.workTokens))
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary(dark: dark))
                .help("Input + output tokens for this session (\(Self.compact(session.tokens.total)) total including cache read/write, priced separately in the cost figure).")
            // A trailing "+" marks a floor: some of this session's usage came
            // from a model the price table does not know, so the figure covers
            // only the priced part. Better than the old behaviour, where one
            // message from a too-new model blanked the whole session to "—".
            Text(session.cost.map { String(format: "$%.2f", $0) + (session.costIsPartial ? "+" : "") } ?? "—")
                .help(session.costIsPartial
                      ? "At least this much. Some usage in this session is from a model with no known price — add it to pricing.json to include it."
                      : "")
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary(dark: dark))
            Spacer(minLength: 4)
            // How long the session RAN (first activity to last), not how long
            // ago it started. This used to be `elapsed(since: startedAt)` —
            // i.e. now-relative — so a finished session's length climbed for
            // as long as its transcript survived: 6-minute sessions were
            // displaying as 167.9h. `AgentSession.span` takes no `now` at all,
            // which is what makes that impossible rather than merely fixed.
            Text(DurationFormat.short(session.span))
                .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary(dark: dark))
                .help("Time from this session's first activity to its last. Includes any idle stretches within the session, but not time after it ended.")
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    /// Age of something against the wall clock — "how long has this prompt
    /// been waiting", "how long since the last activity". Deliberately still
    /// now-relative: unlike a session's length, these ARE questions about the
    /// present, and both remaining call sites want exactly that.
    static func elapsed(since: Date, now: Date = Date()) -> String {
        DurationFormat.short(now.timeIntervalSince(since))
    }
}
