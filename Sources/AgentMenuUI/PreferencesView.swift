import SwiftUI
import AgentMenuCore

public struct PreferencesView: View {
    let installer: HookInstaller
    let notifier: Notifier

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var loginNote = LoginItem.statusDescription
    @State private var hooks: (claude: Bool, codex: Bool, codexOverridden: Bool)
    @State private var notificationsOn: Bool
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
        _mutedKinds = State(initialValue: notifier.mutedKinds)
        let saved = UserDefaults.standard.integer(forKey: PreferencesView.budgetKey)
        _budgetText = State(initialValue: saved > 0 ? String(saved) : "")
        _agentVisibility = State(initialValue: AgentVisibilityPreference.all)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AgentMenu").font(.system(size: 15, weight: .semibold))

            Toggle("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, on in
                    do { try LoginItem.setEnabled(on) }
                    catch { startAtLogin = LoginItem.isEnabled }   // revert on failure
                    loginNote = LoginItem.statusDescription
                }
            Text(loginNote).font(Theme.activity)
                .foregroundStyle(Theme.textTertiary(dark: dark))

            Divider()

            // Round 2 Fix 3: all three default to ON (`?? true`) whether or
            // not the user has ever touched them — a kind an agent has
            // genuinely never used still auto-hides on its own, but the
            // toggle itself never displays as "off" just because nothing has
            // happened yet.
            Text("SHOW AGENTS").font(Theme.label)
                .foregroundStyle(Theme.textTertiary(dark: dark))
            ForEach(AgentKind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: Binding(
                    get: { agentVisibility[kind] ?? true },
                    set: { on in
                        agentVisibility[kind] = on
                        AgentVisibilityPreference.setExplicit(kind, on)
                    }))
            }
            Text("An agent you've never used is hidden automatically until it has a session to show.")
                .font(Theme.activity)
                .foregroundStyle(Theme.textTertiary(dark: dark))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("PERMISSION DETECTION").font(Theme.label)
                .foregroundStyle(Theme.textTertiary(dark: dark))
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
            // Codex's Computer Use component can reclaim the `notify` slot
            // for its own program later, silently leaving AgentMenu's shim
            // un-invoked. The toggle above already renders correctly OFF in
            // that case (`hooks.codex` — see HookInstaller.status() —
            // reports genuine activity, not just presence), but "off" alone
            // reads identically to "never turned on"; this line tells the
            // user which one actually happened, matching loginNote's plain
            // inline-explanation style just above rather than a colored
            // warning.
            if hooks.codexOverridden {
                Text("Codex reclaimed its notify setting — AgentMenu's Codex alerts are inactive. Re-enable to try again.")
                    .font(Theme.activity)
                    .foregroundStyle(Theme.textTertiary(dark: dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Codex logs no approval events, so its permission state is always an estimate.")
                .font(Theme.activity)
                .foregroundStyle(Theme.textTertiary(dark: dark))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("NOTIFICATIONS").font(Theme.label)
                .foregroundStyle(Theme.textTertiary(dark: dark))
            Toggle("Enabled", isOn: $notificationsOn)
                .onChange(of: notificationsOn) { _, on in notifier.enabled = on }
            // Per-agent mute, per spec §9 — a noisy agent can be silenced
            // without losing banners from the other two.
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

            Divider()

            Text("BURN BUDGET").font(Theme.label)
                .foregroundStyle(Theme.textTertiary(dark: dark))
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
            // Spec §6: providers do not persist quota state locally, so this is
            // YOUR budget, not a provider limit. Left blank, no percentage is
            // shown at all rather than a fabricated one.
            Text("Optional. Your own target — not a provider limit, which is not readable locally.")
                .font(Theme.activity)
                .foregroundStyle(Theme.textTertiary(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
    }

    public static let budgetKey = "agentmenu.burnBudget5h"
}
