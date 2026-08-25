import SwiftUI
import AgentMenuCore

public struct PopoverView: View {
    // CONTROLLER RULING F3: plain `let`, not `@Bindable var`. The view only
    // reads from the model; a `@Bindable` stored property cannot be assigned
    // via `self.model = model` in a custom init, and `@Observable` already
    // drives view updates through a plain `let`. Reintroduce `@Bindable` at a
    // child call site only if a two-way binding is ever needed there.
    let model: AppViewModel
    let installer: HookInstaller
    let notifier: Notifier
    let onQuit: () -> Void

    /// Preferences is a page of this popover, not a window.
    ///
    /// Deliberately `@State` and therefore reset every time the popover is
    /// mounted (see `StatusItemController.mountContent`): opening the menu
    /// bar icon should always land on the agents, which is the entire reason
    /// the app exists — and landing on Preferences would silently defeat the
    /// attention routing that picks WHICH agent page to open on.
    @State private var showingSettings = false

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    public init(model: AppViewModel, installer: HookInstaller, notifier: Notifier,
                onQuit: @escaping () -> Void) {
        self.model = model; self.installer = installer
        self.notifier = notifier; self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderView(todayCost: model.todayCost, burn5h: model.burn5h,
                       burnFraction: model.burnFraction, figuresPartial: model.figuresPartial,
                       rateLimitFraction: model.rateLimitFraction,
                       showingSettings: showingSettings,
                       onPreferences: {
                           withAnimation(.easeInOut(duration: 0.18)) { showingSettings.toggle() }
                       })
            Divider().overlay(Theme.hairline(dark: dark))

            Group {
                if showingSettings {
                    PreferencesView(installer: installer, notifier: notifier)
                } else {
                    // One page per VISIBLE agent (Round 2 Fix 3 — see
                    // `AppViewModel.visibleAgentKinds`; can be 0-3 pages),
                    // each horizontally paged and scrolling vertically on its
                    // own — round-2 fix for the single list's scrollbar
                    // jitter / scroll-to-top / clipping.
                    PagedPopoverView(model: model)
                }
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(Theme.hairline(dark: dark))
            HStack {
                // Balances "Quit" across the footer and answers "which build
                // am I actually running" without opening Finder — the first
                // thing worth knowing when reporting anything about this app.
                // Tertiary + mono so it reads as a stamp rather than a
                // control: it sits next to the only button down here, and
                // anything styled like a label would invite a click.
                // Absent entirely when the bundle has no version (see
                // `AppVersion.display`), which is the case under `swift run`.
                if let version = AppVersion.display(
                    short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
                    Text(version)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary(dark: dark))
                        .accessibilityLabel("AgentMenu version \(version.dropFirst())")
                }
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
