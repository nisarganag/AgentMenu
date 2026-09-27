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
    // See `ClaudeCodeSource.windowCache` — identical purpose and identical
    // reasoning for why it lives here rather than inside
    // `CodexRolloutParser`, applied to `foldedRequestCount` instead of
    // `foldedUsageCount`.
    private var windowCache: [String: (foldedCount: Int, nowBucket: Int64,
                                        tokensToday: TokenStats, tokensLast5h: TokenStats)] = [:]
    // The cost estimates re-walk `requestLog` too (each entry needs its own
    // `PricingTable` lookup: its own model, and a long-context surcharge
    // decided by its own input size), so they are exactly as avoidable to
    // repeat tick over tick as tokensToday/tokensLast5h above. `pricing`
    // never changes after construction (`let pricing`), and each request now
    // records the model it was made with, so nothing but the fold count and
    // the coarsened time bucket can change the answer. (The session's model
    // used to be part of this key because the whole rollout was priced at
    // it — the bug that priced a model switch entirely at the newer model.)
    private var costCache: [String: (foldedCount: Int, nowBucket: Int64,
                                      cost: CostEstimate, costToday: CostEstimate)] = [:]
    private var watcher: DirectoryWatcher?
    // Round 3 (Ruling F49) — see ClaudeCodeSource's identical field for the
    // full rationale: seeded once at init, consumed opportunistically the
    // first time each path is seen this process, then removed either way.
    private var pendingRestore: [String: TranscriptCheckpoint<CodexRolloutParser>]

    public init(sessionsRoot: URL, pricing: PricingTable,
                checkpoint: [String: TranscriptCheckpoint<CodexRolloutParser>] = [:]) {
        self.sessionsRoot = sessionsRoot
        self.pricing = pricing
        self.pendingRestore = checkpoint
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

    /// Round 2 Fix 3: existence only, no read of contents — a fresh user who
    /// has never run Codex simply has no `~/.codex/sessions` at all.
    public var dataDirectoryExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDir)
            && isDir.boolValue
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
                var reader: IncrementalFileReader
                var parser: CodexRolloutParser
                if let existingReader = readers[path], let existingParser = parsers[path] {
                    reader = existingReader
                    parser = existingParser
                } else if let restore = pendingRestore.removeValue(forKey: path),
                          let mtime, let size,
                          restore.isValid(currentSize: UInt64(size), currentModifiedAt: mtime) {
                    // Round 3 (Ruling F49): offset and accumulator restored
                    // together — see ClaudeCodeSource.rescan for the full
                    // rationale.
                    reader = IncrementalFileReader(url: url, offset: restore.offset)
                    parser = restore.state
                } else {
                    pendingRestore.removeValue(forKey: path)
                    reader = IncrementalFileReader(url: url)
                    parser = CodexRolloutParser()
                }
                for line in reader.readNewLines() { autoreleasepool { parser.consume(line) } }
                readers[path] = reader
                parsers[path] = parser
                if let mtime, let size { lastSeen[path] = (mtime, size) }
            }

            guard let parser = parsers[path] else { continue }
            // See `ClaudeCodeSource.rescan` — identical skip-if-nothing-
            // relevant-changed reasoning, applied to `foldedRequestCount`.
            let windowBucket = AgentSourceTuning.windowCacheBucket(for: now)
            let foldedCount = parser.foldedRequestCount
            var precomputedWindow: (tokensToday: TokenStats, tokensLast5h: TokenStats)?
            if let cached = windowCache[path],
               cached.foldedCount == foldedCount, cached.nowBucket == windowBucket {
                precomputedWindow = (cached.tokensToday, cached.tokensLast5h)
            }
            guard var session = parser.session(path: path, now: now, precomputedWindow: precomputedWindow)
            else { continue }
            if precomputedWindow == nil, let today = session.tokensToday, let last5h = session.tokensLast5h {
                windowCache[path] = (foldedCount, windowBucket, today, last5h)
            }
            // Codex supplies its own context window; only cost needs the
            // table. Priced per-request (Feature 3's long-context surcharge
            // needs each request's own input size), summed by the parser —
            // never `pricing.cost(for: session.tokens, model:)` against the
            // cumulative total, which has no way to know which portion of it
            // came from an over-threshold request. Cached the same way as
            // the windowed sums just above: re-walking `requestLog` twice a
            // tick (`cost`, `costToday` each loop it independently) for a
            // session whose requests haven't changed is exactly as
            // avoidable — see `costCache`'s doc comment for why `model`
            // joins the cache key here but `pricing` doesn't need to.
            let cost: CostEstimate, costToday: CostEstimate
            if let cached = costCache[path], cached.foldedCount == foldedCount,
               cached.nowBucket == windowBucket {
                (cost, costToday) = (cached.cost, cached.costToday)
            } else {
                cost = parser.costEstimate(pricing: pricing)
                costToday = parser.costEstimateToday(pricing: pricing, now: now)
                costCache[path] = (foldedCount, windowBucket, cost, costToday)
            }
            session.cost = cost.displayDollars
            session.costToday = costToday.displayDollars
            session.costIsPartial = cost.isPartial
            out.append(session)
        }
        readers = readers.filter { visited.contains($0.key) }
        parsers = parsers.filter { visited.contains($0.key) }
        lastSeen = lastSeen.filter { visited.contains($0.key) }
        windowCache = windowCache.filter { visited.contains($0.key) }
        costCache = costCache.filter { visited.contains($0.key) }
        _lastError = walkError
        return out
    }

    /// Snapshot of every rollout this process has actually read, ready to
    /// persist into `Checkpoint.codexTranscripts` — see
    /// `ClaudeCodeSource.checkpointState(now:)` for the full rationale
    /// (Round 3 / Ruling F49).
    public func checkpointState(now: Date) -> [String: TranscriptCheckpoint<CodexRolloutParser>] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: TranscriptCheckpoint<CodexRolloutParser>] = [:]
        for (path, parser) in parsers {
            guard let reader = readers[path], let seen = lastSeen[path] else { continue }
            out[path] = TranscriptCheckpoint(
                state: parser.checkpointSnapshot(now: now),
                offset: reader.safeResumeOffset,
                size: UInt64(seen.size),
                modifiedAt: seen.mtime,
                version: CodexRolloutParser.checkpointVersion)
        }
        return out
    }
}
