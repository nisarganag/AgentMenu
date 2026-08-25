import Foundation
import UserNotifications
import AppKit
import os
import AgentMenuCore

public final class Notifier: @unchecked Sendable {
    /// Two banners for the same key inside this window collapse into one — a
    /// burst of tool calls must not produce a burst of banners.
    public static let coalesceWindow: TimeInterval = 8

    private static let log = Logger(subsystem: "com.nisarganag.agentmenu", category: "notifier")

    private static let enabledDefaultsKey = "agentmenu.notificationsEnabled"
    private static let mutedKindsDefaultsKey = "agentmenu.mutedAgentKinds"
    private static let soundDefaultsKey = "agentmenu.notificationSound"

    // Everything below is guarded by `lock`. `notify()` can run on whatever
    // background queue `DirectoryWatcher` delivers spool events on, while
    // `PreferencesView` reads and writes `enabled`/`mutedKinds` from the main
    // actor — plain vars here would be a real data race, not a theoretical
    // one, so they get the same lock discipline `lastSent`/`useCenter` always had.
    private var _enabled: Bool
    private var _mutedKinds: Set<AgentKind>
    private var _soundEnabled: Bool
    private var lastSent: [String: Date] = [:]
    private var useCenter = false
    private let lock = NSLock()

    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set {
            lock.lock(); _enabled = newValue; lock.unlock()
            // Write-through so a mute/unmute survives relaunch (spec §9) —
            // mirrors how PreferencesView already persists the burn budget.
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
        }
    }

    public var mutedKinds: Set<AgentKind> {
        get { lock.lock(); defer { lock.unlock() }; return _mutedKinds }
        set {
            lock.lock(); _mutedKinds = newValue; lock.unlock()
            // Stored as wire strings (not `rawValue`) so the persisted form
            // matches the spool wire format already used elsewhere.
            UserDefaults.standard.set(newValue.map(\.wire), forKey: Self.mutedKindsDefaultsKey)
        }
    }

    /// Whether a delivered banner also plays a sound.
    ///
    /// Separate from `enabled` rather than folded into it: the two answer
    /// different questions. `enabled` is "do I want to be told at all";
    /// this is "do I want to be told audibly", which is the setting people
    /// actually change as they move between a quiet room and a loud one.
    /// Defaults ON — a monitor whose entire job is catching a blocked agent
    /// while you are looking elsewhere is not doing it silently.
    ///
    /// Note this cannot force sound past the system: macOS still honours
    /// Focus, Do Not Disturb, and the per-app notification settings in
    /// System Settings. Turning this on is a request, not an override — and
    /// deliberately so; `.defaultCritical` would pierce Do Not Disturb and
    /// that is not a decision a menu bar app should make for someone.
    public var soundEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _soundEnabled }
        set {
            lock.lock(); _soundEnabled = newValue; lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.soundDefaultsKey)
        }
    }

    /// Loads persisted enable/mute state immediately, so it is in effect from
    /// the moment the app launches — not only after the user happens to open
    /// Preferences again. Absent keys default to enabled/unmuted, so a first
    /// run (or an upgrade from a build that predates this) behaves exactly as
    /// before.
    public init() {
        let d = UserDefaults.standard
        _enabled = (d.object(forKey: Self.enabledDefaultsKey) as? Bool) ?? true
        _soundEnabled = (d.object(forKey: Self.soundDefaultsKey) as? Bool) ?? true
        if let wires = d.array(forKey: Self.mutedKindsDefaultsKey) as? [String] {
            _mutedKinds = Set(wires.compactMap(AgentKind.init(wire:)))
        } else {
            _mutedKinds = []
        }
    }

    /// Restore dedupe state from a previous run so a restart does not re-fire
    /// banners for events already shown (spec §12).
    public func seed(notified: [String: Date]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in notified { lastSent[k] = v }
    }

    /// Current dedupe state, for checkpointing.
    public var notifiedKeys: [String: Date] {
        lock.lock(); defer { lock.unlock() }
        return lastSent
    }

    /// Drops dedupe entries older than `cutoff` so `lastSent` does not grow
    /// unbounded for the life of the process. Called from Task 20's existing
    /// periodic checkpoint save — no timer lives inside `Notifier` itself.
    public func prune(before cutoff: Date) {
        lock.lock(); defer { lock.unlock() }
        lastSent = lastSent.filter { $0.value >= cutoff }
    }

    public func requestAuthorization() {
        // Only meaningful inside a signed bundle; harmless otherwise.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                self?.lock.lock()
                self?.useCenter = granted
                self?.lock.unlock()
                if let error {
                    Self.log.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
                }
                // Logged unconditionally (not just on failure): a silent
                // "denied" is exactly why banners would appear to stop
                // working with nothing in between to explain it.
                Self.log.info("notification authorization outcome: \(granted ? "granted" : "denied", privacy: .public)")
            }
    }

    public func notify(kind: AgentKind, title: String, body: String,
                       key: String, now: Date = Date()) {
        lock.lock()
        guard _enabled, !_mutedKinds.contains(kind) else { lock.unlock(); return }
        if let last = lastSent[key], now.timeIntervalSince(last) < Self.coalesceWindow {
            lock.unlock(); return
        }
        lastSent[key] = now
        let viaCenter = useCenter
        let withSound = _soundEnabled
        lock.unlock()

        if viaCenter {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // `.default` rather than a named system sound: a named sound that
            // is missing at runtime delivers SILENTLY, which would look
            // exactly like the toggle not working. `.default` cannot fail.
            if withSound { content.sound = .default }
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Self.log.error("UNUserNotificationCenter delivery failed, falling back to osascript: \(error.localizedDescription, privacy: .public)")
                    Self.viaOsascript(title: title, body: body, sound: withSound)
                }
            }
        } else {
            Self.viaOsascript(title: title, body: body, sound: withSound)
        }
    }

    /// Always available, no entitlement required — the reason notifications are
    /// never on the critical path for this app.
    private static func viaOsascript(title: String, body: String, sound: Bool = false) {
        let escape = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // The fallback path has to carry the setting too, or sound silently
        // becomes a coin-flip on whichever delivery route happened to be
        // taken. "Ping" is a stock macOS sound present on every install.
        let soundClause = sound ? " sound name \"Ping\"" : ""
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\"\(soundClause)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            Self.log.error("osascript fallback failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps a spool event to a banner. Inferred states are phrased as questions.
    public func handle(_ e: SpoolEvent, now: Date = Date()) {
        switch e.event {
        case .permissionRequired:
            notify(kind: e.agent,
                   title: "\(e.agent.displayName) needs permission",
                   body: [e.tool, e.summary].compactMap { $0 }.joined(separator: "  "),
                   // Prefixed with the agent kind, matching AgentSession.id's
                   // "kind/nativeId" convention, so two agents can never
                   // collide on the same coalescing key.
                   key: "\(e.agent.rawValue)/perm/\(e.sessionId)", now: now)
        case .turnFinished:
            notify(kind: e.agent,
                   title: "\(e.agent.displayName) finished",
                   body: e.summary ?? "Turn complete",
                   key: "\(e.agent.rawValue)/done/\(e.sessionId)", now: now)
        case .permissionResolved, .turnStarted:
            break
        }
    }
}
