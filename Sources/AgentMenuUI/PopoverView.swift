import SwiftUI
import AgentMenuCore

public struct PopoverView: View {
    // CONTROLLER RULING F3: plain `let`, not `@Bindable var`. The view only
    // reads from the model; a `@Bindable` stored property cannot be assigned
    // via `self.model = model` in a custom init, and `@Observable` already
    // drives view updates through a plain `let`. Reintroduce `@Bindable` at a
    // child call site only if a two-way binding is ever needed there.
    let model: AppViewModel
    let onPreferences: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { scheme == .dark }

    public init(model: AppViewModel, onPreferences: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.model = model; self.onPreferences = onPreferences; self.onQuit = onQuit
    }

    /// Grouped by agent, but ordering across the whole list already puts
    /// anything blocked first (Task 1's sortedForDisplay).
    private var groups: [(AgentKind, [AgentSession])] {
        let order = model.sessions
        var seen: [AgentKind] = []
        for s in order where !seen.contains(s.kind) { seen.append(s.kind) }
        return seen.map { kind in (kind, order.filter { $0.kind == kind }) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderView(todayCost: model.todayCost, burn5h: model.burn5h,
                       burnFraction: model.burnFraction, onPreferences: onPreferences)
            Divider().overlay(Theme.hairline(dark: dark))

            if model.sessions.isEmpty {
                Text("No agent sessions")
                    .font(Theme.activity)
                    .foregroundStyle(Theme.textTertiary(dark: dark))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.0) { kind, sessions in
                            Text(kind.displayName.uppercased())
                                .font(Theme.label)
                                .tracking(0.8)
                                .foregroundStyle(Theme.accent(for: kind, dark: dark))
                                .padding(.horizontal, 12)
                                .padding(.top, 9).padding(.bottom, 3)
                            ForEach(sessions) { session in
                                SessionRowView(session: session) { model.focus(session) }
                                    .transition(reduceMotion ? .identity : .opacity)
                            }
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(duration: 0.18), value: model.sessions)
                }
                .frame(maxHeight: Theme.popoverMaxHeight)
            }

            Divider().overlay(Theme.hairline(dark: dark))
            HStack {
                Spacer()
                Button("Quit AgentMenu", action: onQuit)
                    .buttonStyle(.plain)
                    .font(Theme.activity)
                    .foregroundStyle(Theme.textSecondary(dark: dark))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: Theme.popoverWidth)
    }
}
