import Foundation
import AgentMenuCore

/// Round 2 Fix 3: reads/writes the per-agent "show this page" preference
/// `PreferencesView` edits and `AppViewModel.visibleAgentKinds` consumes.
/// Mirrors `Notifier`'s own directly-`UserDefaults`-backed settings
/// (`enabled`/`mutedKinds`) rather than introducing a new persistence
/// mechanism — this is a UI-layer concern, kept out of `AgentMenuCore` the
/// same way those are.
///
/// `nil` means "the user has never touched this toggle" — `PreferencesView`
/// still displays it as ON (all three default to visible), but
/// `AgentVisibility`'s auto-hide rule is free to override an untouched
/// preference for an agent that has never been used. The moment the user
/// actually flips a toggle (to either position), this reads back non-nil and
/// always wins over the auto rule from then on.
public enum AgentVisibilityPreference {
    private static func key(_ kind: AgentKind) -> String { "agentmenu.showAgent.\(kind.rawValue)" }

    public static func explicit(_ kind: AgentKind) -> Bool? {
        UserDefaults.standard.object(forKey: key(kind)) as? Bool
    }

    public static func setExplicit(_ kind: AgentKind, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key(kind))
    }

    /// All three kinds' current explicit preferences, shaped for
    /// `AgentVisibility.visible(preferences:...)`. A kind never touched is
    /// simply absent, not defaulted to `true` here — the auto-hide rule
    /// needs to tell "untouched" apart from "explicitly on."
    public static var all: [AgentKind: Bool] {
        Dictionary(uniqueKeysWithValues: AgentKind.allCases.compactMap { kind in
            explicit(kind).map { (kind, $0) }
        })
    }
}
