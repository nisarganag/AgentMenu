import Foundation

/// Polls opencode's SQLite store rather than watching with FSEvents: the DB
/// is in WAL mode, so the main file's mtime does not move on every commit and
/// FSEvents misses writes. opencode reports cost natively (Task 6) — this
/// source never computes cost from the price table. It DOES need the table
/// for the context-fill meter (Fix 7 / review Ruling F65): `OpencodeDatabase`
/// leaves `context` nil and documents that the source fills it in, but until
/// this fix no `PricingTable` ever reached this type, so opencode rows never
/// got a meter even though `pricing.json` ships a `contextWindow` for both
/// of its models (`deepseek-v4-pro`, `kimi-k3`) for exactly this purpose.
public final class OpencodeSource: AgentSource, @unchecked Sendable {
    public static let pollInterval: TimeInterval = 2

    public let kind: AgentKind = .opencode
    /// Reads take the same lock `rescan` writes under — see `ClaudeCodeSource`.
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

    private let dbPath: String
    private let pricing: PricingTable
    private let lock = NSLock()
    private var _lastError: String?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "agentmenu.opencode")

    public init(dbPath: String, pricing: PricingTable) {
        self.dbPath = dbPath
        self.pricing = pricing
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        t.setEventHandler { onChange() }
        t.resume()
        lock.lock(); timer = t; lock.unlock()
    }

    /// Captures and clears `timer` under the lock, then cancels the local
    /// copy outside it — mirrors `DirectoryWatcher.stop()`'s own pattern.
    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }
    public func restart() { /* a timer needs no rebuild after wake */ }

    /// Round 2 Fix 3: existence only, no open of the DB — a fresh user who
    /// has never run opencode simply has no `opencode.db` at all.
    public var dataDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    public func rescan(now: Date) -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }

        // A missing DB is legitimately "no sessions" — most users who install
        // this app do not run opencode at all. Mirrors
        // ClaudeCodeSource/CodexSource's own root-absent guard (Fix 4 /
        // review Ruling F62): without this check, a fresh install with no
        // opencode DB produced a PERMANENT amber "source unavailable" row
        // whose reason was `cannotOpen("unable to open database file")` — a
        // raw Swift enum dump verbatim in the UI, AND a false implication
        // that something was actually wrong.
        guard FileManager.default.fileExists(atPath: dbPath) else {
            _lastError = nil
            return []
        }

        do {
            // Reopened each pass: cheap, and it picks up a DB replaced by an
            // upgrade. Also required for correctness — `OpencodeDatabase` is
            // opened with SQLITE_OPEN_NOMUTEX and provides no thread-safety of
            // its own, so a single instance must never be shared across the
            // poll timer and any other thread.
            let db = try OpencodeDatabase(path: dbPath)
            var sessions = try db.sessions(
                since: now.addingTimeInterval(-AgentSourceTuning.lookback), now: now)
            for i in sessions.indices { enrich(&sessions[i]) }
            _lastError = nil
            return sessions
        } catch {
            // `OpencodeDatabase.Error` conforms to `LocalizedError` (Fix 4),
            // so `error.localizedDescription` already reads its
            // human-readable `errorDescription` rather than falling through
            // to `String(describing:)`'s Swift-internal enum-case dump
            // (e.g. `cannotOpen("...")`), which is debug syntax, not
            // something to show a user in a permanent status row.
            _lastError = error.localizedDescription
            return []
        }
    }

    /// `OpencodeDatabase.sessions` deliberately leaves `context` nil — it has
    /// no price table of its own to look up a model's window with, and
    /// documents that the source is expected to fill it in. Mirrors
    /// `ClaudeCodeSource.enrich`: no known window means no meter, never a
    /// fake one.
    ///
    /// "Used" is the session's cumulative token total, not a per-message
    /// context-window snapshot — opencode's `session` row (unlike Claude's
    /// per-message JSONL) only ever gives a running total, not the size of
    /// the most recent turn alone. This can over-report fill on a long
    /// multi-turn session; both priced opencode models ship very large
    /// windows (1M / 1,048,576 tokens in `pricing.json`) specifically
    /// because of this, which keeps the approximation from reading as
    /// falsely alarming in the common case.
    private func enrich(_ s: inout AgentSession) {
        guard let model = s.model, let window = pricing.contextWindow(for: model) else {
            s.context = nil
            return
        }
        s.context = ContextFill(used: s.tokens.total, window: window)
    }
}
