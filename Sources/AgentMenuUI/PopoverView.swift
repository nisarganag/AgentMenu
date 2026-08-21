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
    private var dark: Bool { scheme == .dark }

    public init(model: AppViewModel, onPreferences: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.model = model; self.onPreferences = onPreferences; self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderView(todayCost: model.todayCost, burn5h: model.burn5h,
                       burnFraction: model.burnFraction, onPreferences: onPreferences)
            Divider().overlay(Theme.hairline(dark: dark))

            // Always three pages (Claude Code, Codex, opencode), horizontally
            // paged, each scrolling vertically on its own — round-2 fix for
            // the single list's scrollbar jitter / scroll-to-top / clipping.
            PagedPopoverView(model: model)
                .frame(maxHeight: .infinity)

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
        // Fixed width AND height so NSPopover never resizes/repositions/clips
        // as content changes (round-2 fix). Shorter content stays top-aligned
        // (PagedPopoverView/AgentPageView's own `.top`-aligned frames) rather
        // than stretching to fill the extra space.
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight, alignment: .top)
    }
}
