import Foundation

/// Watches `~/.codex/sessions` and turns every `rollout-*.jsonl` file into an
/// `AgentSession`. Codex supplies its own context window from the rollout
/// itself (Task 5), so only `cost` needs the price table here — the window
/// must never be overwritten.
public final class CodexSource: AgentSource, @unchecked Sendable {
    public let kind: AgentKind = .codex
    /// Reads take the same lock `rescan` writes under — see `ClaudeCodeSource`.
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

    private let sessionsRoot: URL
    private let pricing: PricingTable
    private let lock = NSLock()
    private var _lastError: String?
    private var parsers: [String: CodexRolloutParser] = [:]
    private var readers: [String: IncrementalFileReader] = [:]
    // path → (mtime, size) at the last read — see ClaudeCodeSource for why
    // both fields (not mtime alone) are needed to safely skip an unchanged
    // file's open/seek/read/parse on a rescan.
    private var lastSeen: [String: (mtime: Date, size: Int)] = [:]
    private var watcher: DirectoryWatcher?

    public init(sessionsRoot: URL, pricing: PricingTable) {
        self.sessionsRoot = sessionsRoot
        self.pricing = pricing
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        let w = DirectoryWatcher(paths: [sessionsRoot.path], onChange: onChange)
        w.start()
        lock.lock(); watcher = w; lock.unlock()
    }

    /// Captures and clears `watcher` under the lock, then acts on the local
    /// copy outside it — mirrors `DirectoryWatcher.stop()`'s own pattern, so a
    /// potentially-slow teardown never blocks a concurrent `rescan()`.
    public func stop() {
        lock.lock()
        let w = watcher
        watcher = nil
        lock.unlock()
        w?.stop()
    }

    public func restart() {
        lock.lock()
        let w = watcher
        lock.unlock()
        w?.restart()
    }

    public func rescan(now: Date) -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }

        // See ClaudeCodeSource.rescan: an absent root is "no sessions", but an
        // existing-but-unreadable one is a real failure that must surface via
        // `lastError` rather than silently reading as empty (spec §8).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            _lastError = nil
            return []
        }
        guard FileManager.default.isReadableFile(atPath: sessionsRoot.path) else {
            _lastError = "cannot read \(sessionsRoot.path): permission denied"
            return []
        }

        var walkError: String?
        guard let e = FileManager.default.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    walkError = "\(url.path): \(error.localizedDescription)"
                    return true
                }) else {
            _lastError = "cannot enumerate \(sessionsRoot.path)"
            return []
        }

        // See ClaudeCodeSource.rescan: skip anything too old to be live before
        // ever opening it, and evict cached readers/parsers for paths that
        // aged out or vanished — otherwise every rescan re-walks the whole
        // rollout history and the caches grow without bound.
        let cutoff = now.addingTimeInterval(-AgentSourceTuning.lookback)
        var visited: Set<String> = []
        var out: [AgentSession] = []
        for case let url as URL in e
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            // One stat serves the lookback cutoff below AND the
            // unchanged-file skip further down.
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate
            let size = values?.fileSize
            if let mtime, mtime < cutoff { continue }
            let path = url.path
            visited.insert(path)

            // See ClaudeCodeSource.rescan: skip the open/seek/read/parse only
            // when BOTH mtime and size are unchanged (mtime alone could miss
            // a same-timestamp-bucket final append), and drain the
            // autoreleasepool per line rather than per file/rescan so a
            // cold-start catch-up over many rollouts can't park a
            // multi-times-corpus-size peak for the rest of the process's
            // life (Task 20 fix report; round-2 fix report, Finding 2).
            let unchanged = mtime != nil && size != nil
                && lastSeen[path]?.mtime == mtime && lastSeen[path]?.size == size
            if !unchanged {
                var reader = readers[path] ?? IncrementalFileReader(url: url)
                var parser = parsers[path] ?? CodexRolloutParser()
                for line in reader.readNewLines() { autoreleasepool { parser.consume(line) } }
                readers[path] = reader
                parsers[path] = parser
                if let mtime, let size { lastSeen[path] = (mtime, size) }
            }

            guard var session = parsers[path]?.session(path: path, now: now) else { continue }
            // Codex supplies its own context window; only cost needs the table.
            if let model = session.model { session.cost = pricing.cost(for: session.tokens, model: model) }
            out.append(session)
        }
        readers = readers.filter { visited.contains($0.key) }
        parsers = parsers.filter { visited.contains($0.key) }
        lastSeen = lastSeen.filter { visited.contains($0.key) }
        _lastError = walkError
        return out
    }
}
