import SwiftUI

public struct HeaderView: View {
    let todayCost: Double
    let burn5h: Int
    /// nil unless the user set a budget — never a provider quota (spec §6).
    let burnFraction: Double?
    let onPreferences: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    public init(todayCost: Double, burn5h: Int, burnFraction: Double?,
                onPreferences: @escaping () -> Void) {
        self.todayCost = todayCost; self.burn5h = burn5h
        self.burnFraction = burnFraction; self.onPreferences = onPreferences
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Bug 3: this used to be labelled "Today", but the figure behind
            // it only ever counts burn actually OBSERVED while AgentMenu was
            // running (AppDelegate.tick()/BurnBaselines.delta seed a new
            // session's baseline without backdating its lifetime total into
            // "today") — spend from earlier in the calendar day, before
            // launch, is invisible to it and always will be (reconstructing
            // true calendar-day spend from message timestamps is out of
            // scope). Labelling that "Today" is exactly the kind of
            // plausible-looking lie this app refuses elsewhere; "Since
            // Launch" says only what is actually known.
            metric("Since Launch", String(format: "$%.2f", todayCost))
            metric("Last 5h", burnFraction.map {
                "\(SessionRowView.compact(burn5h)) tok  \(Int($0 * 100))%"
            } ?? "\(SessionRowView.compact(burn5h)) tok")
            Spacer()
            Button(action: onPreferences) {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary(dark: dark))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            // Aggregates are neutral grey — they belong to no single agent.
            Text(label.uppercased())
                .font(Theme.label).foregroundStyle(Theme.textTertiary(dark: dark))
            Text(value)
                .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary(dark: dark))
        }
    }
}
