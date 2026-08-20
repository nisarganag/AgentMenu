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
            metric("Today", String(format: "$%.2f", todayCost))
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
