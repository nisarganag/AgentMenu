import Foundation

/// Watches `~/.claude/projects` and turns every `*.jsonl` transcript into an
/// `AgentSession`. The parser stays pure (Task 4); this is where the price
/// table fills in `cost` and the context window.
public final class ClaudeCodeSource: AgentSource, @unchecked Sendable {
    public let kind: AgentKind = .claudeCode
    /// Reads take the same lock `rescan` writes under — the stored value is
    /// mutated inside `rescan`'s locked region, so an external reader on a
    /// different thread must not observe a torn/unsynchronized write.
    public var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

    private let projectsRoot: URL
    private let pricing: PricingTable
    private let lock = NSLock()
    private var _lastError: String?
    private var parsers: [String: ClaudeTranscriptParser] = [:]   // path → parser
    private var readers: [String: IncrementalFileReader] = [:]
    // path → (mtime, size) at the last read. Lets a rescan skip the
    // open/seek/read entirely for a file that hasn't changed since the last
    // pass (Task 20 fix report, Finding 2) — a `stat` (already paid for
    // below, for the lookback cutoff) is far cheaper than opening and
    // reading a file that turns out to have nothing new. Both fields must
    // match: mtime alone could in principle miss a final append that lands
    // in the same timestamp bucket as a prior write (APFS's nanosecond
    // resolution makes this unlikely, not impossible), and if that missed
    // append were the file's last write ever, nothing later would make the
    // mtime differ again and the tail would be skipped permanently. File
    // size is monotonic for an append-only transcript and immune to
    // timestamp quantization, so pairing it with mtime closes that gap for
    // free (round-2 fix report, Finding 2).
    private var lastSeen: [String: (mtime: Date, size: Int)] = [:]
    // path -> the last (foldedUsageCount, coarsened-now bucket) a
    // tokensToday/tokensLast5h pair was actually DERIVED for, plus that
    // pair. `rescan` calls `session(path:now:)` every ~2s for every cached
    // parser regardless of whether its file changed this tick — without
    // this, a long-lived session re-folds its whole retained usage log
    // twice (`tokensToday`, `tokensLast5h` are separate scans) every single
    // tick, for numbers that are almost always identical to last tick's.
    // Lives here rather than inside `ClaudeTranscriptParser` itself so the
    // parser's checkpointed shape never changes (no `checkpointVersion`
    // bump, no risk of a stale cache value ever being persisted) — this is
    // purely a runtime memoisation of `session`'s own output, keyed on the
    // two things `AgentSourceTuning.windowCacheGranularity` and
    // `ClaudeTranscriptParser.foldedUsageCount` say can invalidate it.
    private var windowCache: [String: (foldedCount: Int, nowBucket: Int64,
                                        tokensToday: TokenStats, tokensLast5h: TokenStats)] = [:]
    private var watcher: DirectoryWatcher?
    // Round 3 (Ruling F49): seeded once at init from a loaded `Checkpoint`,
    // consumed opportunistically the first time each path is encountered by
    // THIS process (see `rescan`). Never consulted again after that — either
    // it seeded `parsers`/`readers` or it didn't, and either way `parsers[path]`
    // is non-nil from then on, which is what actually gates the restore path.
    // Removed from this dictionary as each entry is considered, so a process
    // that runs for a while never holds more of this than it still might use.
    private var pendingRestore: [String: TranscriptCheckpoint<ClaudeTranscriptParser>]

    public init(projectsRoot: URL, pricing: PricingTable,
                checkpoint: [String: TranscriptCheckpoint<ClaudeTranscriptParser>] = [:]) {
        self.projectsRoot = projectsRoot
        self.pricing = pricing
        self.pendingRestore = checkpoint
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        let w = DirectoryWatcher(paths: [projectsRoot.path], onChange: onChange)
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
    /// has never run Claude Code simply has no `~/.claude/projects` at all.
    public var dataDirectoryExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    public func rescan(now: Date) -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }

        // An absent root is legitimately "no sessions" (lastError stays nil).
        // An existing-but-unreadable root (permissions, TCC, FileVault) is a
        // real failure and must be surfaced — spec §8 requires a source that
        // cannot read to become a visible "source unavailable" row, not
        // silently render as indistinguishable from "never used Claude Code".
        // `FileManager.enumerator(at:)` cannot be trusted to make this
        // distinction itself: it returns a non-nil enumerator that simply
        // iterates zero items for both a missing path AND an unreadable one.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            _lastError = nil
            return []
        }
        guard FileManager.default.isReadableFile(atPath: projectsRoot.path) else {
            _lastError = "cannot read \(projectsRoot.path): permission denied"
            return []
        }

        var walkError: String?
        guard let e = FileManager.default.enumerator(
                at: projectsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    // One unreadable entry shouldn't abort the whole scan, but
                    // it must still be visible rather than silently dropped.
                    walkError = "\(url.path): \(error.localizedDescription)"
                    return true
                }) else {
            _lastError = "cannot enumerate \(projectsRoot.path)"
            return []
        }

        // A transcript untouched for longer than the lookback cannot belong
        // to a live session. Skipping it here — before opening or parsing it
        // — is what keeps a rescan cheap: without this bound, every 2s poll
        // re-reads the entire history (851 files / 512 MB of real ~/.claude
        // transcripts), and `readers`/`parsers` below retain one accumulator
        // per file forever. `.contentModificationDateKey` was already
        // requested from the enumerator above for exactly this check.
        let cutoff = now.addingTimeInterval(-AgentSourceTuning.lookback)
        var visited: Set<String> = []
        var out: [AgentSession] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            // One stat serves the lookback cutoff below AND the
            // unchanged-file skip further down — a second `resourceValues`
            // call would just be paying the stat cost twice.
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate
            let size = values?.fileSize
            if let mtime, mtime < cutoff { continue }
            let path = url.path
            visited.insert(path)

            // Nothing on disk changed since the last time this exact
            // (mtime, size) pair was recorded — skip the open/seek/read/parse
            // and reuse the cached parser state instead. A missing mtime or
            // size (resourceValues failed) reads as "assume changed", the
            // same failure-open stance as the cutoff check above, so an
            // unusual filesystem never hides real activity.
            let unchanged = mtime != nil && size != nil
                && lastSeen[path]?.mtime == mtime && lastSeen[path]?.size == size
            if !unchanged {
                var reader: IncrementalFileReader
                var parser: ClaudeTranscriptParser
                if let existingReader = readers[path], let existingParser = parsers[path] {
                    reader = existingReader
                    parser = existingParser
                } else if let restore = pendingRestore.removeValue(forKey: path),
                          let mtime, let size,
                          restore.isValid(currentSize: UInt64(size), currentModifiedAt: mtime) {
                    // Round 3 (Ruling F49): the offset and the accumulator
                    // that produced it, restored together — never the
                    // offset alone with a fresh parser, which would report
                    // only the tail of this session's tokens.
                    reader = IncrementalFileReader(url: url, offset: restore.offset)
                    parser = restore.state
                } else {
                    pendingRestore.removeValue(forKey: path)   // drop a stale/invalid entry, if any
                    reader = IncrementalFileReader(url: url)
                    parser = ClaudeTranscriptParser()
                }
                // `JSONSerialization` is Objective-C-bridged, so parsing one
                // line allocates a small mountain of short-lived objects.
                // Draining per line — not per file, not once for the whole
                // rescan — is what stops a cold-start catch-up over many
                // files from parking a peak worth several times the corpus
                // size in the process for the rest of its life. Measured
                // directly against 127 MB of real transcripts: unwrapped,
                // RSS after one pass plateaued ~3x the input size; wrapped
                // per line, well under the input size (Task 20 fix report).
                for line in reader.readNewLines() { autoreleasepool { parser.consume(line) } }
                readers[path] = reader
                parsers[path] = parser
                if let mtime, let size { lastSeen[path] = (mtime, size) }
            }

            guard let parser = parsers[path] else { continue }
            // See `windowCache`'s doc comment: skip re-deriving
            // tokensToday/tokensLast5h only when NEITHER of the two things
            // that could change them has — new usage folded in since the
            // cached pair was computed, or `now` having crossed into a new
            // coarsened bucket. A miss recomputes exactly, from the real
            // `now`, inside `session` itself — this only ever decides
            // whether that recompute is skippable, never what it would
            // have produced.
            let windowBucket = AgentSourceTuning.windowCacheBucket(for: now)
            let foldedCount = parser.foldedUsageCount
            var precomputedWindow: (tokensToday: TokenStats, tokensLast5h: TokenStats)?
            if let cached = windowCache[path],
               cached.foldedCount == foldedCount, cached.nowBucket == windowBucket {
                precomputedWindow = (cached.tokensToday, cached.tokensLast5h)
            }
            guard var session = parser.session(path: path, now: now, precomputedWindow: precomputedWindow)
            else { continue }
            // Only re-cache on an actual recompute — a hit already reflects
            // this exact (foldedCount, bucket) pair, so re-storing it would
            // just be redundant writes to a dictionary already at that key.
            if precomputedWindow == nil, let today = session.tokensToday, let last5h = session.tokensLast5h {
                windowCache[path] = (foldedCount, windowBucket, today, last5h)
            }
            enrich(&session)
            out.append(session)
        }
        // Drop every cached reader/parser/(mtime,size)/windowCache entry for
        // a path not seen this pass — aged-out or deleted — or the caches
        // grow for the life of the process. These stay keyed per FILE
        // regardless of the merge below: `IncrementalFileReader`/
        // `ClaudeTranscriptParser` are one real accumulator per file, and
        // the merge only changes what's handed to the caller, never how the
        // reading itself is cached.
        readers = readers.filter { visited.contains($0.key) }
        parsers = parsers.filter { visited.contains($0.key) }
        lastSeen = lastSeen.filter { visited.contains($0.key) }
        windowCache = windowCache.filter { visited.contains($0.key) }
        _lastError = walkError
        return Self.merging(out)
    }

    /// Snapshot of every transcript this process has actually read, ready to
    /// persist into `Checkpoint.claudeTranscripts` — Round 3 (Ruling F49).
    /// Only paths present in `parsers`, `readers`, AND `lastSeen` are
    /// exported: those three are always written together at the bottom of
    /// `rescan`'s per-file branch, so their intersection is exactly "files
    /// this process has read at least one line of," which is the same set
    /// `rescan` itself would otherwise re-read from zero on the next launch.
    public func checkpointState(now: Date) -> [String: TranscriptCheckpoint<ClaudeTranscriptParser>] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: TranscriptCheckpoint<ClaudeTranscriptParser>] = [:]
        for (path, parser) in parsers {
            guard let reader = readers[path], let seen = lastSeen[path] else { continue }
            out[path] = TranscriptCheckpoint(
                state: parser.checkpointSnapshot(now: now),
                offset: reader.safeResumeOffset,
                size: UInt64(seen.size),
                modifiedAt: seen.mtime,
                version: ClaudeTranscriptParser.checkpointVersion)
        }
        return out
    }

    /// A Claude Code subagent transcript reports its PARENT session's
    /// `sessionId`, so many distinct files can resolve to the same
    /// `nativeId`/`.id` — measured directly against real data on this
    /// machine: 27 session ids spanning more than one file, the worst
    /// spanning 61. Left unmerged, `SessionStore`/`PopoverView`'s `ForEach`
    /// would carry that many `AgentSession` values sharing one `id`:
    /// undefined `ForEach` behaviour over duplicate `Identifiable` ids, one
    /// conversation rendered as dozens of near-identical rows, and any
    /// push-channel override keyed by `id` (a permission dot, a done state)
    /// landing on all of them at once (round-3 fix report).
    ///
    /// Subagent spend is real spend, though: silently dropping those files
    /// would under-report cost, which is worse than the duplicate rows this
    /// fixes. So every session sharing a `nativeId` is folded into one:
    /// token fields and cost are summed (the group's total activity), while
    /// single-valued "what does this conversation look like right now"
    /// fields come from whichever member has the newest `lastEventAt` —
    /// context fill in particular is a property of the live conversation,
    /// not a quantity that means anything summed.
    private static func merging(_ sessions: [AgentSession]) -> [AgentSession] {
        let groups = Dictionary(grouping: sessions, by: \.nativeId)
        return groups.values.map { group in
            // The common case — no collision — needs no reconstruction.
            // Tie-break on transcriptPath when lastEventAt matches exactly:
            // `max(by:)` would otherwise silently resolve ties to whichever
            // order `FileManager.enumerator` happened to yield them in, an
            // undocumented, effectively random ordering (round-4 fix
            // report). Cosmetic only — tokens/cost are summed either way —
            // but worth being deterministic about.
            guard group.count > 1,
                  let newest = group.max(by: {
                      ($0.lastEventAt, $0.transcriptPath ?? "") < ($1.lastEventAt, $1.transcriptPath ?? "")
                  })
            else { return group[0] }

            var merged = newest   // state, lastActivity, context, transcriptPath,
                                   // project, directory, branch, model: all the
                                   // newest member's, as a starting point.
            merged.tokens = group.reduce(into: TokenStats()) { total, s in
                total.input      += s.tokens.input
                total.output     += s.tokens.output
                total.cacheRead  += s.tokens.cacheRead
                total.cacheWrite += s.tokens.cacheWrite
                total.reasoning  += s.tokens.reasoning
            }
            // Same "sum what's known, or nil" rule as `cost` just below —
            // Feature 1's windowed fields are as summable as `tokens` itself
            // (every member here came from the same parser, which always
            // sets them), but the group is handled generically rather than
            // assumed non-nil.
            merged.tokensToday = group.contains { $0.tokensToday != nil }
                ? group.compactMap(\.tokensToday).reduce(TokenStats(), +)
                : nil
            merged.tokensLast5h = group.contains { $0.tokensLast5h != nil }
                ? group.compactMap(\.tokensLast5h).reduce(TokenStats(), +)
                : nil
            // A partial sum is worse than an honest absent value: sum the
            // known costs only if at least one member actually has one.
            merged.cost = group.contains { $0.cost != nil }
                ? group.reduce(0) { $0 + ($1.cost ?? 0) }
                : nil
            merged.costToday = group.contains { $0.costToday != nil }
                ? group.reduce(0) { $0 + ($1.costToday ?? 0) }
                : nil
            // A timestamp, not a quantity: the most recent one wins, never summed.
            merged.lastRateLimitAt = group.compactMap(\.lastRateLimitAt).max()
            merged.startedAt = group.map(\.startedAt).min()!
            return merged
        }
    }

    /// The parser stays pure; pricing is applied here. An unpriced model must
    /// yield `cost == nil` AND `context == nil` — never a meter against a
    /// guessed window.
    private func enrich(_ s: inout AgentSession) {
        guard let model = s.model else { s.context = nil; return }
        s.cost = pricing.cost(for: s.tokens, model: model)
        s.costToday = s.tokensToday.flatMap { pricing.cost(for: $0, model: model) }
        if let window = pricing.contextWindow(for: model), let used = s.context?.used {
            s.context = ContextFill(used: used, window: window)
        } else {
            s.context = nil     // no window known → no meter, rather than a fake one
        }
    }
}
