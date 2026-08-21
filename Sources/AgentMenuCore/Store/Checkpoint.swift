import Foundation

/// Version tag + validity stamp + serialized accumulator for one transcript
/// file, keyed by absolute path in `Checkpoint.claudeTranscripts` /
/// `.codexTranscripts`.
///
/// Round 3 (Ruling F49): a byte offset alone is unsafe to resume from,
/// because `ClaudeTranscriptParser`/`CodexRolloutParser` are cumulative
/// folds — restoring just the offset and resuming with a FRESH accumulator
/// would report only the tail of a session's tokens (wrong total, wrong
/// cost, wrong context — worse than the slow-but-correct cold start it
/// would replace). The offset and the accumulator that produced it are
/// therefore checkpointed together as one inseparable unit: a restore is
/// both-or-neither, never offset-only.
public struct TranscriptCheckpoint<State: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    /// The OWNING parser's `checkpointVersion` at save time (NOT a version of
    /// this wrapper, which never changes shape). A mismatch at load time
    /// means "the parser's internals changed since this was written," and
    /// `Checkpoint`'s decoder drops the entry outright rather than trusting
    /// a decode that merely happens to succeed — see that type's doc
    /// comment. No migration is ever attempted; a version bump is a
    /// deliberate, total invalidation.
    public var v: Int
    /// Always `IncrementalFileReader.safeResumeOffset` — a complete-line
    /// boundary — never a raw post-read offset that could split a trailing
    /// partial line.
    public var offset: UInt64
    /// File size at save time — half of the validity stamp.
    public var size: UInt64
    /// File modification date at save time — the other half.
    public var modifiedAt: Date
    public var state: State

    public init(state: State, offset: UInt64, size: UInt64, modifiedAt: Date, version: Int) {
        self.v = version
        self.offset = offset
        self.size = size
        self.modifiedAt = modifiedAt
        self.state = state
    }

    /// Whether `offset`/`state` are safe to resume from, given the file's
    /// CURRENT size and modification date. Errs toward "no": a slow re-read
    /// from zero is always the safe fallback here; a wrong token total is
    /// not (Ruling F49). Only `size`/`modifiedAt` are used — deliberately no
    /// byte-content check (e.g. a hash of the prefix), which would cost
    /// exactly the read this feature exists to avoid.
    ///
    /// - current size SMALLER than the stamp: truncated or replaced by
    ///   something shorter. Not the same bytes. Invalid.
    /// - size and mtime BOTH identical: byte-for-byte unchanged since save.
    ///   Valid, with zero new bytes to read.
    /// - size LARGER and mtime advanced (or equal): ordinary append-only
    ///   growth. Valid — the caller reads only the new tail.
    /// - anything else (in particular: identical size but a DIFFERENT
    ///   mtime, meaning something rewrote the file in place without
    ///   changing its length) is unexplained by normal append-only use.
    ///   Invalid.
    public func isValid(currentSize: UInt64, currentModifiedAt: Date) -> Bool {
        guard currentSize >= size else { return false }
        if currentSize == size { return currentModifiedAt == modifiedAt }
        return currentModifiedAt >= modifiedAt
    }
}

/// Persistent state that must survive a restart.
///
/// `fileOffsets` stops a relaunch re-reading multi-megabyte transcripts from
/// zero; `notifiedKeys` stops it re-firing banners for events already shown.
///
/// `fileOffsets` itself is intentionally NEVER populated — see Ruling F49.
/// `claudeTranscripts`/`codexTranscripts` below are the real mechanism: each
/// entry carries its parser's accumulator alongside the offset, which is the
/// only safe way to do this.
public struct Checkpoint: Codable, Sendable, Equatable {
    public var fileOffsets: [String: UInt64]
    public var notifiedKeys: [String: Date]
    /// Feature 2: rolling 5h Claude token burn measured at the moment each
    /// real rate-limit error was observed — empty until at least one ever
    /// has been. A small, bounded history (see `RateLimitCeiling`); never
    /// approximated or seeded with a guess.
    public var observedCeilings: [Int]
    /// The freshest rate-limit timestamp already folded into
    /// `observedCeilings`, so a relaunch never re-records — or re-considers
    /// as "just happened" — an event from a past run.
    public var lastRateLimitObservedAt: Date?
    /// Round 3 (Ruling F49): one entry per Claude transcript this process has
    /// actually read, refreshed on every save by
    /// `ClaudeCodeSource.checkpointState(now:)`.
    public var claudeTranscripts: [String: TranscriptCheckpoint<ClaudeTranscriptParser>]
    /// Same as `claudeTranscripts`, for Codex rollouts. opencode needs
    /// neither — it reads a SQLite database, not an append-only log.
    public var codexTranscripts: [String: TranscriptCheckpoint<CodexRolloutParser>]

    public init(fileOffsets: [String: UInt64] = [:], notifiedKeys: [String: Date] = [:],
                observedCeilings: [Int] = [], lastRateLimitObservedAt: Date? = nil,
                claudeTranscripts: [String: TranscriptCheckpoint<ClaudeTranscriptParser>] = [:],
                codexTranscripts: [String: TranscriptCheckpoint<CodexRolloutParser>] = [:]) {
        self.fileOffsets = fileOffsets
        self.notifiedKeys = notifiedKeys
        self.observedCeilings = observedCeilings
        self.lastRateLimitObservedAt = lastRateLimitObservedAt
        self.claudeTranscripts = claudeTranscripts
        self.codexTranscripts = codexTranscripts
    }

    private enum CodingKeys: String, CodingKey {
        case fileOffsets, notifiedKeys, observedCeilings, lastRateLimitObservedAt
        case claudeTranscripts, codexTranscripts
    }

    /// Hand-written rather than synthesized: a checkpoint written by a build
    /// before Feature 2 simply won't have `observedCeilings`/
    /// `lastRateLimitObservedAt` in its JSON, and synthesized `Decodable`
    /// would throw `keyNotFound` on that — which `CheckpointStore.load()`
    /// treats as "corrupt, start fresh," silently wiping the OTHER fields
    /// too (in particular `notifiedKeys`, which is real persisted data).
    /// Decoding the two new fields leniently means "nothing observed yet"
    /// for an old file, never data loss.
    ///
    /// `claudeTranscripts`/`codexTranscripts` need one MORE layer of lenience
    /// than `observedCeilings` did: those two are plain `[Int]`/`Date?` and
    /// only need to tolerate an ABSENT key (an old build's file). These carry
    /// a nested parser accumulator whose SHAPE can change between builds —
    /// present-but-now-incompatible, not merely absent — so
    /// `decodeIfPresent` alone is not enough: it still throws when the key
    /// exists but the value fails to decode, and that throw would otherwise
    /// propagate out of this initializer and wipe `notifiedKeys` too. The
    /// extra `try?` catches exactly that case. A per-entry `v` mismatch
    /// (same shape, deliberately bumped version) is handled separately
    /// below by filtering — decoding succeeds but the entry is still
    /// dropped, per Ruling F49's "discard and re-read, never migrate."
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileOffsets = try c.decodeIfPresent([String: UInt64].self, forKey: .fileOffsets) ?? [:]
        notifiedKeys = try c.decodeIfPresent([String: Date].self, forKey: .notifiedKeys) ?? [:]
        observedCeilings = try c.decodeIfPresent([Int].self, forKey: .observedCeilings) ?? []
        lastRateLimitObservedAt = try c.decodeIfPresent(Date.self, forKey: .lastRateLimitObservedAt)

        // `try?` on an expression that is already `Optional` (as
        // `decodeIfPresent` is) flattens rather than nesting, so this single
        // `?? [:]` covers BOTH "key absent" and "key present but decode
        // threw" in one step.
        let claudeRaw = (try? c.decodeIfPresent(
            [String: TranscriptCheckpoint<ClaudeTranscriptParser>].self,
            forKey: .claudeTranscripts)) ?? [:]
        claudeTranscripts = claudeRaw.filter { $0.value.v == ClaudeTranscriptParser.checkpointVersion }

        let codexRaw = (try? c.decodeIfPresent(
            [String: TranscriptCheckpoint<CodexRolloutParser>].self,
            forKey: .codexTranscripts)) ?? [:]
        codexTranscripts = codexRaw.filter { $0.value.v == CodexRolloutParser.checkpointVersion }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileOffsets, forKey: .fileOffsets)
        try c.encode(notifiedKeys, forKey: .notifiedKeys)
        try c.encode(observedCeilings, forKey: .observedCeilings)
        try c.encodeIfPresent(lastRateLimitObservedAt, forKey: .lastRateLimitObservedAt)
        try c.encode(claudeTranscripts, forKey: .claudeTranscripts)
        try c.encode(codexTranscripts, forKey: .codexTranscripts)
    }

    public func pruned(before cutoff: Date) -> Checkpoint {
        Checkpoint(fileOffsets: fileOffsets,
                   notifiedKeys: notifiedKeys.filter { $0.value >= cutoff },
                   observedCeilings: observedCeilings,
                   lastRateLimitObservedAt: lastRateLimitObservedAt,
                   claudeTranscripts: claudeTranscripts,
                   codexTranscripts: codexTranscripts)
    }
}

/// Reads and writes the checkpoint at `~/.agentmenu/state.json`.
///
/// `load` never throws: a corrupt or missing checkpoint means "start fresh",
/// which is degraded but correct. Refusing to launch over it would not be.
public struct CheckpointStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> Checkpoint {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Checkpoint.self, from: data) else {
            return Checkpoint()
        }
        return c
    }

    public func save(_ checkpoint: Checkpoint) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        let tmp = url.appendingPathExtension("agentmenu-tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
