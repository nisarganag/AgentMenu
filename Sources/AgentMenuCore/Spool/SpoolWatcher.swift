import Foundation

/// Drains the hook spool directory.
///
/// A directory of small JSON files rather than a socket: the hooks stay
/// plain POSIX `sh` with nothing to compile or code-sign (Fix 6 rewrote them
/// to drop a `/usr/bin/python3` dependency that is a stub without Xcode
/// Command Line Tools; they now wrap an agent's raw payload in a small
/// envelope rather than pre-flattening it themselves — see `SpoolEvent`),
/// events survive the app being closed, and the whole channel is debuggable
/// with `ls`.
public final class SpoolWatcher: @unchecked Sendable {
    /// Events older than this are cleaned up but never acted on — otherwise a
    /// relaunch would replay banners for prompts answered hours ago.
    public static let stalenessWindow: TimeInterval = 600

    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    /// Creates the spool directory 0700 if absent. Safe to call repeatedly.
    public func ensureDirectory() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    public func drain(now: Date) -> [SpoolEvent] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var events: [SpoolEvent] = []

        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }        // consume regardless of outcome
            // The hooks are pure POSIX sh (Fix 6) and write the agent's raw
            // payload wrapped in a small envelope rather than pre-flattened
            // fields — `SpoolEvent.init(envelopeData:)` does the per-agent
            // extraction with a real JSON parser.
            guard let data = try? Data(contentsOf: url),
                  let event = SpoolEvent(envelopeData: data) else { continue }
            guard now.timeIntervalSince(event.date) <= Self.stalenessWindow else { continue }
            events.append(event)
        }
        return events.sorted { $0.ts < $1.ts }
    }
}
