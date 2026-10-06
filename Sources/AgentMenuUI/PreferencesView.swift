import SwiftUI
import AgentMenuCore

public struct PreferencesView: View {
    let installer: HookInstaller
    let notifier: Notifier

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var loginNote = LoginItem.statusDescription
    @State private var hooks: (claude: Bool, codex: Bool, codexOverridden: Bool)
    @State private var notificationsOn: Bool
    @State private var soundOn: Bool
    @State private var disabledCategories: Set<NotificationCategory>
    @State private var mutedKinds: Set<AgentKind>
    @State private var budgetText: String
    // Round 2 Fix 3: only holds kinds the user has actually touched — a kind
    // absent here still displays ON (see the `?? true` in the Toggle below)
    // but remains eligible for auto-hide. See `AgentVisibilityPreference`.
    @State private var agentVisibility: [AgentKind: Bool]
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    public init(installer: HookInstaller, notifier: Notifier) {
        self.installer = installer
        self.notifier = notifier
        _hooks = State(initialValue: installer.status())
        _notificationsOn = State(initialValue: notifier.enabled)
        _soundOn = State(initialValue: notifier.soundEnabled)
        _disabledCategories = State(initialValue: notifier.disabledCategories)
        _mutedKinds = State(initialValue: notifier.mutedKinds)
        let saved = UserDefaults.standard.integer(forKey: PreferencesView.budgetKey)
        _budgetText = State(initialValue: saved > 0 ? String(saved) : "")
        _agentVisibility = State(initialValue: AgentVisibilityPreference.all)
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(Theme.label).foregroundStyle(Theme.textTertiary(dark: dark))
    }

    /// The explanatory grey line that follows most controls here.
    private func note(_ text: String) -> some View {
        Text(text).font(Theme.activity)
            .foregroundStyle(Theme.textTertiary(dark: dark))
            .fixedSize(horizontal: false, vertical: true)
    }

    public var body: some View {
        ScrollView {
            sections.padding(14)
                // Switches everywhere, per request. Applied once at the root
                // rather than per-Toggle, so a control added later cannot
                // quietly come back as a checkbox — which is AppKit's default
                // and what every one of these used to render as.
                .toggleStyle(TrailingSwitchToggleStyle())
        }
        // ScrollView, not a fixed VStack: the window is not resizable, and
        // sections in cards are taller than the old divider-separated list.
        // Anything that no longer fits now scrolls instead of being clipped
        // off the bottom with no way to reach it.
        // `.never`, not `.hidden`: `.hidden` is advisory and is overridden
        // when "Show scroll bars: Always" is set in System Settings — the same
        // trap already documented in `PagedPopoverView`.
        // `.never`, not `.hidden`: `.hidden` is advisory and is overridden
        // when "Show scroll bars: Always" is set in System Settings — the same
        // trap already documented in `PagedPopoverView`.
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No backdrop of its own: this is a page inside the popover now, and
        // NSPopover already supplies the pane. Blurring an already-blurred
        // surface reads as muddy rather than layered.
    }

    private var sections: some View {
        GlassStack(spacing: 12) {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Start at login", isOn: $startAtLogin)
                        .onChange(of: startAtLogin) { _, on in
                            do { try LoginItem.setEnabled(on) }
                            catch { startAtLogin = LoginItem.isEnabled }   // revert on failure
                            loginNote = LoginItem.statusDescription
                        }
                    note(loginNote)
                }
            }

            // Round 2 Fix 3: all three default to ON (`?? true`) whether or
            // not the user has ever touched them — a kind an agent has
            // genuinely never used still auto-hides on its own, but the
            // toggle itself never displays as "off" just because nothing has
            // happened yet.
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("SHOW AGENTS")
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { agentVisibility[kind] ?? true },
                            set: { on in
                                agentVisibility[kind] = on
                                AgentVisibilityPreference.setExplicit(kind, on)
                            }))
                    }
                    note("An agent you've never used is hidden automatically until it has a session to show.")
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("PERMISSION DETECTION")
                    Toggle("Claude Code hooks", isOn: Binding(
                        get: { hooks.claude },
                        set: { on in
                            try? on ? installer.installClaude() : installer.uninstallClaude()
                            hooks = installer.status()
                        }))
                    Toggle("Codex notify shim", isOn: Binding(
                        get: { hooks.codex },
                        set: { on in
                            try? on ? installer.installCodex() : installer.uninstallCodex()
                            hooks = installer.status()
                        }))
                    // Codex's Computer Use component can reclaim the `notify`
                    // slot for its own program later, silently leaving
                    // AgentMenu's shim un-invoked. The toggle above already
                    // renders correctly OFF in that case (`hooks.codex` — see
                    // HookInstaller.status() — reports genuine activity, not
                    // just presence), but "off" alone reads identically to
                    // "never turned on"; this line tells the user which one
                    // actually happened, matching loginNote's plain
                    // inline-explanation style just above rather than a
                    // colored warning.
                    if hooks.codexOverridden {
                        note("Codex reclaimed its notify setting — AgentMenu's Codex alerts are inactive. Re-enable to try again.")
                    }
                    note("Codex logs no approval events, so its permission state is always an estimate.")
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("NOTIFICATIONS")
                    Toggle("Enabled", isOn: $notificationsOn)
                        .onChange(of: notificationsOn) { _, on in notifier.enabled = on }
                    Toggle("Play sound", isOn: $soundOn)
                        .onChange(of: soundOn) { _, on in notifier.soundEnabled = on }
                        .disabled(!notificationsOn)
                    // Worth stating outright: this toggle is a request, not an
                    // override. Someone who turns sound ON, hears nothing
                    // because Focus is active, and is told nothing would
                    // reasonably conclude the setting is broken.
                    note("Focus and Do Not Disturb still apply — sound is requested, not forced.")
                    // Per-agent mute, per spec §9 — a noisy agent can be
                    // silenced without losing banners from the other two.
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { !mutedKinds.contains(kind) },
                            set: { on in
                                if on { mutedKinds.remove(kind) } else { mutedKinds.insert(kind) }
                                notifier.mutedKinds = mutedKinds
                            }))
                        .disabled(!notificationsOn)
                        .padding(.leading, 14)
                    }
                }
            }

            // One switch per kind of notification AgentMenu can send, driven
            // straight from `NotificationCategory.allCases` — so a type added
            // later gets its switch here automatically rather than shipping
            // with no way to turn it off.
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("NOTIFICATION TYPES")
                    ForEach(NotificationCategory.allCases, id: \.self) { category in
                        Toggle(isOn: Binding(
                            get: { !disabledCategories.contains(category) },
                            set: { on in
                                if on { disabledCategories.remove(category) }
                                else { disabledCategories.insert(category) }
                                notifier.disabledCategories = disabledCategories
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label)
                                note(category.detail)
                            }
                        }
                    }
                    if !notificationsOn {
                        note("Notifications are off above, so none of these are sent.")
                    }
                }
                .disabled(!notificationsOn)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("BURN BUDGET")
                    HStack {
                        TextField("none", text: $budgetText)
                            .frame(width: 90)
                            .onSubmit {
                                let v = Int(budgetText.filter(\.isNumber)) ?? 0
                                UserDefaults.standard.set(v, forKey: PreferencesView.budgetKey)
                            }
                        Text("tokens per 5h").font(Theme.activity)
                            .foregroundStyle(Theme.textTertiary(dark: dark))
                    }
                    // Spec §6: providers do not persist quota state locally,
                    // so this is YOUR budget, not a provider limit. Left blank,
                    // no percentage is shown at all rather than a fabricated one.
                    note("Optional. Your own target — not a provider limit, which is not readable locally.")
                }
            }
        }
    }

    public static let budgetKey = "agentmenu.burnBudget5h"
}

/// A switch pinned to the trailing edge, with the label taking the rest of the
/// row — the layout macOS System Settings uses.
///
/// The stock `.switch` style places the switch immediately after its label, so
/// rows whose labels differ in width put their switches at different x
/// positions. Single short labels hid that; the notification-types card, where
/// each label carries a one-line description, made the switches zig-zag down
/// the card (caught by screenshotting the built panel). Pinning every switch
/// to one edge gives a straight column on every card.
private struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
