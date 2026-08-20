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

    // Everything below is guarded by `lock`. `notify()` can run on whatever
    // background queue `DirectoryWatcher` delivers spool events on, while
    // `PreferencesView` reads and writes `enabled`/`mutedKinds` from the main
    // actor — plain vars here would be a real data race, not a theoretical
    // one, so they get the same lock discipline `lastSent`/`useCenter` always had.
    private var _enabled: Bool
    private var _mutedKinds: Set<AgentKind>
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

    /// Loads persisted enable/mute state immediately, so it is in effect from
    /// the moment the app launches — not only after the user happens to open
    /// Preferences again. Absent keys default to enabled/unmuted, so a first
    /// run (or an upgrade from a build that predates this) behaves exactly as
    /// before.
    public init() {
        let d = UserDefaults.standard
        _enabled = (d.object(forKey: Self.enabledDefaultsKey) as? Bool) ?? true
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
        lock.unlock()

        if viaCenter {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Self.log.error("UNUserNotificationCenter delivery failed, falling back to osascript: \(error.localizedDescription, privacy: .public)")
                    Self.viaOsascript(title: title, body: body)
                }
            }
        } else {
            Self.viaOsascript(title: title, body: body)
        }
    }

    /// Always available, no entitlement required — the reason notifications are
    /// never on the critical path for this app.
    private static func viaOsascript(title: String, body: String) {
        let escape = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
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
