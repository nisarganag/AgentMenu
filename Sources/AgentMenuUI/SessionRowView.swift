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
            Text(Self.compact(session.tokens.total))
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary(dark: dark))
            Text(session.cost.map { String(format: "$%.2f", $0) } ?? "—")
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary(dark: dark))
            Spacer(minLength: 4)
            // Total session elapsed — a different question from activity age.
            Text(Self.elapsed(since: session.startedAt))
                .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary(dark: dark))
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    static func elapsed(since: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60 == 0 ? "" : "\(s % 60)s")" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
