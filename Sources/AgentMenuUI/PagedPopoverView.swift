import SwiftUI
import AgentMenuCore

/// Replaces the old single scrollable list (bugs: reshuffling under the
/// cursor, scroll position snapping to the top) with one horizontally-paged
/// container holding exactly three pages — Claude Code, Codex, opencode, in
/// that fixed order, always, even when an agent has no sessions at all. Each
/// page keeps `sortedForDisplay()` ordering and scrolls vertically on its
/// own, so a state-driven reshuffle is now confined to one agent's handful
/// of rows instead of all sessions across every agent at once.
///
/// Uses `ScrollView(.horizontal)` + `.scrollTargetLayout()` +
/// `.scrollTargetBehavior(.paging)` + `.scrollPosition(id:)` — all part of
/// the macOS 14/iOS 17 scroll API family, not `TabView(.page)`
/// (`PageTabViewStyle` is iOS-only and does not exist on macOS).
public struct PagedPopoverView: View {
    // Plain `let`, matching PopoverView's Ruling F3: a `@Bindable` stored
    // property cannot be assigned via `self.model = model` in a custom
    // init. The one place this view needs a two-way binding
    // (`.scrollPosition(id:)`) is built by hand below instead.
    let model: AppViewModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { scheme == .dark }

    /// Fixed order per the owner's ask. Always these three, always in this
    /// order — a missing page would make the indicator dots lie about where
    /// you are.
    static let pages: [AgentKind] = [.claudeCode, .codex, .opencode]

    public init(model: AppViewModel) { self.model = model }

    /// `model.sessions` is already `sortedForDisplay()` (permission first,
    /// then working, idle, done, most-recent-first within a rank — spec
    /// §5). Filtering a sorted array by a subset predicate preserves that
    /// relative order, so no re-sort is needed per page.
    private func sessions(for kind: AgentKind) -> [AgentSession] {
        model.sessions.filter { $0.kind == kind }
    }

    private func attention(for kind: AgentKind) -> PageDotView.Attention {
        let mine = sessions(for: kind)
        if mine.contains(where: {
            if case .awaitingPermission(_, .exact) = $0.state { return true }
            return false
        }) { return .exact }
        if mine.contains(where: {
            if case .awaitingPermission(_, .inferred) = $0.state { return true }
            return false
        }) { return .inferred }
        return .none
    }

    private var pageBinding: Binding<AgentKind?> {
        Binding(
            get: { model.currentPage },
            set: { newValue in if let newValue { model.currentPage = newValue } })
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.pages, id: \.self) { kind in
                        AgentPageView(kind: kind, sessions: sessions(for: kind),
                                      model: model, dark: dark, reduceMotion: reduceMotion)
                            .frame(width: Theme.popoverWidth)
                            .id(kind)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pageBinding)
            // .never, not .hidden: `.hidden` is advisory and is overridden when
            // the user sets "Show scroll bars: Always" in System Settings, which
            // leaves a bar sitting across the bottom of the popover. The three
            // page dots are the paging affordance; a scrollbar is noise.
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)

            pageDots
        }
    }

    private var pageDots: some View {
        HStack(spacing: 2) {
            ForEach(Self.pages, id: \.self) { kind in
                PageDotView(kind: kind, isCurrent: model.currentPage == kind,
                            attention: attention(for: kind), dark: dark) {
                    jump(to: kind)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private func jump(to kind: AgentKind) {
        guard model.currentPage != kind else { return }
        if reduceMotion {
            model.currentPage = kind
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { model.currentPage = kind }
        }
    }
}

/// One agent's page: a pinned identity label, then either that agent's
/// sessions (own vertical `ScrollView`, own state) or a quiet placeholder.
private struct AgentPageView: View {
    let kind: AgentKind
    let sessions: [AgentSession]
    let model: AppViewModel
    let dark: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.displayName.uppercased())
                .font(Theme.label)
                .tracking(0.8)
                .foregroundStyle(Theme.accent(for: kind, dark: dark))
                .padding(.horizontal, 12)
                .padding(.top, 9).padding(.bottom, 3)

            if sessions.isEmpty {
                Text("No \(kind.displayName) sessions")
                    .font(Theme.activity)
                    .foregroundStyle(Theme.textTertiary(dark: dark))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            SessionRowView(session: session) { model.focus(session) }
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(duration: 0.18), value: sessions)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
        }
        // Content shorter than the page stays top-aligned rather than
        // stretching to fill the fixed popover height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One page-indicator dot. Reuses `StatusDot`'s existing visual grammar
/// (solid alert fill = a fact; hollow caution ring = a guess) so a dot on
/// another page reads the same way a row's own status dot would.
private struct PageDotView: View {
    enum Attention: Equatable { case none, inferred, exact }

    let kind: AgentKind
    let isCurrent: Bool
    let attention: Attention
    let dark: Bool
    let action: () -> Void

    private var fill: Color {
        if isCurrent { return Theme.accent(for: kind, dark: dark) }
        switch attention {
        case .exact:    return Theme.alert(dark: dark)
        case .inferred: return .clear
        case .none:     return Theme.textTertiary(dark: dark)
        }
    }

    private var stroke: Color {
        (!isCurrent && attention == .inferred) ? Theme.caution(dark: dark) : .clear
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(stroke, lineWidth: 1.3))
                .frame(width: 6, height: 6)
                .padding(6)   // larger tap target than the visible dot
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        switch attention {
        case .exact:    return "\(kind.displayName), needs permission"
        case .inferred: return "\(kind.displayName), maybe waiting"
        case .none:     return kind.displayName
        }
    }
}
