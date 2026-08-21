import Testing
import Foundation
import Darwin
@testable import AgentMenuCore

private let pricingJSON = """
{"models":{"claude-opus-5":{"inputPerMTok":5.0,"outputPerMTok":25.0,
"cacheReadPerMTok":0.5,"cacheWritePerMTok":6.25,"contextWindow":200000}}}
""".data(using: .utf8)!

/// Lays out a fake ~/.claude/projects tree containing one session transcript.
private func fakeClaudeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let line = #"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"sess-1","cwd":"/Users/x/proj","gitBranch":"main","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":94000,"output_tokens":500}}}"#
    try (line + "\n").write(to: root.appendingPathComponent("sess-1.jsonl"),
                            atomically: true, encoding: .utf8)
    return root.deletingLastPathComponent()   // …/projects
}

@Test func claudeSourceDiscoversSessionsAndFillsCostAndContextWindow() throws {
    let projects = try fakeClaudeRoot()
    let source = ClaudeCodeSource(projectsRoot: projects,
                                  pricing: try PricingTable.decode(pricingJSON))
    let sessions = source.rescan(now: ISO8601.parse("2026-08-19T18:22:11.000Z")!)
    let s = try #require(sessions.first)
    #expect(s.nativeId == "sess-1")
    // Window comes from the price table — the transcript never states it.
    #expect(s.context?.window == 200_000)
    #expect(s.context?.used == 95_000)
    // 1000 in @5/M + 500 out @25/M + 94000 cacheRead @0.5/M = 0.005+0.0125+0.047
    #expect(abs(try #require(s.cost) - 0.0645) < 0.0001)
}

@Test func claudeSourceLeavesCostNilForAnUnpricedModel() throws {
    let projects = try fakeClaudeRoot()
    let empty = try PricingTable.decode(#"{"models":{}}"#.data(using: .utf8)!)
    let s = try #require(ClaudeCodeSource(projectsRoot: projects, pricing: empty)
        .rescan(now: ISO8601.parse("2026-08-19T18:22:11.000Z")!).first)
    #expect(s.cost == nil, "an unknown model must render — not guess")
    #expect(s.context == nil, "no window means no meter, rather than a fake one")
}

@Test func missingRootYieldsNoSessionsRatherThanThrowing() throws {
    let source = ClaudeCodeSource(projectsRoot: URL(fileURLWithPath: "/nope/projects"),
                                  pricing: try PricingTable.decode(pricingJSON))
    #expect(source.rescan(now: Date()).isEmpty)
}

// An absent root and an unreadable one must NOT look the same: silently
// treating a permissions/TCC/FileVault failure as "no sessions" is
// indistinguishable from "never used Claude Code" (spec §8 requires a source
// that cannot read to surface as a visible, explanatory failure instead).
// `chmod 000` has no effect on root (root bypasses POSIX permission bits
// entirely), so this is skipped rather than failed in that environment.
@Test(.enabled(if: getuid() != 0, "chmod 000 has no effect when running as root"))
func unreadableRootSurfacesAnErrorRatherThanReadingAsEmpty() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

    let source = ClaudeCodeSource(projectsRoot: root, pricing: try PricingTable.decode(pricingJSON))
    let sessions = source.rescan(now: Date())
    #expect(sessions.isEmpty)
    #expect(source.lastError != nil,
            "an existing-but-unreadable root must surface an error, not read as merely empty")
}

// Without an mtime bound, every rescan re-walks and re-parses the entire
// transcript history forever, and the per-path reader/parser caches grow
// without limit for the life of the process. This proves both halves: a
// transcript that ages past the lookback drops out of the results (even
// though it was already cached from an earlier rescan with the same `now`),
// and it stays gone rather than being resurrected by a lingering cache entry.
@Test func staleTranscriptsAreSkippedAndEvictedFromTheCache() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func line(_ id: String) -> String {
        #"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"\#(id)","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1,"output_tokens":1}}}"#
    }
    let freshURL = root.appendingPathComponent("fresh.jsonl")
    let agingURL = root.appendingPathComponent("aging.jsonl")
    try (line("fresh") + "\n").write(to: freshURL, atomically: true, encoding: .utf8)
    try (line("aging") + "\n").write(to: agingURL, atomically: true, encoding: .utf8)

    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))

    // Both files are fresh relative to `t0`: both are read, parsed, and cached.
    let t0 = Date()
    let first = source.rescan(now: t0)
    #expect(Set(first.map(\.nativeId)) == Set(["fresh", "aging"]))

    // Backdate only `aging` past the lookback — simulating time passing
    // without an actual 7-day sleep. `fresh` is left untouched.
    let old = t0.addingTimeInterval(-AgentSourceTuning.lookback - 3600)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: agingURL.path)

    let second = source.rescan(now: t0)
    #expect(second.map(\.nativeId) == ["fresh"],
            "a transcript that ages past the lookback must drop out, even though it was already cached")

    let third = source.rescan(now: t0)
    #expect(third.map(\.nativeId) == ["fresh"],
            "a stale transcript must not be resurrected by a lingering cache entry")
}

// mtime alone is not a safe "unchanged" signal for the read-skip cache: two
// separate writes could in principle land in the same timestamp bucket (APFS
// nanosecond resolution makes this unlikely, not impossible), and if the
// missed write were the file's last one ever, nothing later would make the
// mtime differ again — the tail would be skipped forever. This forces
// exactly that collision and proves the size half of the (mtime, size) pair
// catches it anyway, since an append-only transcript's size only grows
// (round-2 fix report, Finding 2).
//
// The collision is forced by pinning the SAME literal `Date` value with
// `setAttributes` both before and after the second write, rather than
// capturing the first mtime via `attributesOfItem` and "restoring" it —
// verified directly that the latter does NOT reliably collide: the
// capture-then-restore round trip loses sub-microsecond precision (e.g.
// 1787254466.1243105 read back as 1787254466.12431), so the two mtimes
// still compare unequal and every implementation, buggy or not, correctly
// sees "changed". Pinning one whole-second literal twice avoids that: the
// same Double in gives the same stored mtime out, both times.
@Test func sameMTimeButLargerSizeStillTriggersAReread() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("sess-1.jsonl")
    let pinnedMTime = Date(timeIntervalSince1970: 1_800_000_000)   // whole seconds: no quantization risk

    let firstLine = #"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"sess-1","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1,"output_tokens":1}}}"#
    try (firstLine + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: pinnedMTime], ofItemAtPath: url.path)

    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))
    let t0 = Date()
    let first = try #require(source.rescan(now: t0).first)
    #expect(first.tokens.total == 2)   // 1 input + 1 output

    // Append more real content, then pin the mtime back to the EXACT SAME
    // literal value used above — a genuine, bit-exact timestamp collision,
    // not a lossy read-back-and-restore.
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    let secondLine = #"{"type":"assistant","timestamp":"2026-08-19T18:23:00.000Z","sessionId":"sess-1","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"More."}],"usage":{"input_tokens":5,"output_tokens":5}}}"#
    try h.write(contentsOf: Data((secondLine + "\n").utf8))
    try h.close()
    try FileManager.default.setAttributes([.modificationDate: pinnedMTime], ofItemAtPath: url.path)

    // mtime now reads identical to the first pass, but the file grew — the
    // second rescan must still pick up the new line rather than trusting a
    // stale, timestamp-collided "unchanged" verdict.
    let second = try #require(source.rescan(now: t0).first)
    #expect(second.tokens.total == 12, "a same-mtime append must still be read because size moved")
}

// A Claude Code subagent transcript reports its PARENT session's
// `sessionId`, so a real conversation with subagent calls produces multiple
// files that all resolve to the same `nativeId` — confirmed against real
// data on this machine: 27 session ids spanning more than one file, the
// worst spanning 61 (round-3 fix report). Left unmerged, these would
// surface as duplicate-`Identifiable`-id rows in `PopoverView`'s `ForEach`.
// This proves the fold: tokens sum across both files (real subagent spend,
// not to be silently dropped), but `lastEventAt`/`context` come from
// whichever file is newest rather than being summed — context fill
// describes the live conversation right now, not a running total.
@Test func sessionsSharingANativeIdAreMergedTokensSummedContextFromNewest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // The main transcript: older activity, its own token/context usage.
    let mainLine = #"{"type":"assistant","timestamp":"2026-08-19T18:22:10.000Z","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}"#
    try (mainLine + "\n").write(to: root.appendingPathComponent("shared-id.jsonl"),
                                atomically: true, encoding: .utf8)

    // A subagent transcript, nested the way Claude Code really writes them,
    // reporting the SAME parent sessionId — newer activity, and a
    // different (smaller) context usage.
    let subDir = root.appendingPathComponent("shared-id/subagents")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    let subLine = #"{"type":"assistant","timestamp":"2026-08-19T18:25:00.000Z","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Subagent done."}],"usage":{"input_tokens":20,"output_tokens":10,"cache_read_input_tokens":200,"cache_creation_input_tokens":5}}}"#
    try (subLine + "\n").write(to: subDir.appendingPathComponent("agent-x.jsonl"),
                               atomically: true, encoding: .utf8)

    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))
    let sessions = source.rescan(now: ISO8601.parse("2026-08-19T18:25:01.000Z")!)

    #expect(sessions.count == 1, "two files sharing a sessionId must merge into one row")
    let merged = try #require(sessions.first)
    // input 100+20, output 50+10, cacheRead 1000+200, cacheWrite 0+5
    #expect(merged.tokens.input == 120)
    #expect(merged.tokens.output == 60)
    #expect(merged.tokens.cacheRead == 1200)
    #expect(merged.tokens.cacheWrite == 5)
    #expect(merged.tokens.total == 1385, "tokens are summed across the group")
    #expect(merged.lastEventAt == ISO8601.parse("2026-08-19T18:25:00.000Z"),
            "lastEventAt comes from the newer file, not the older one")
    // Context is a property of the live conversation, not a summable
    // quantity: it must be the NEWER file's 225 (20+200+5), never 1100+225.
    #expect(merged.context?.used == 225,
            "context comes from the newest file rather than being summed")
}

// Feature 1's windowed fields must be summed across a merged subagent group
// the same way `tokens`/`cost` already are — otherwise a merged row would
// silently drop one member's contribution (whichever isn't "newest").
@Test func mergedSessionsSumTokensTodayAndCostTodayAcrossTheGroup() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Timestamped relative to `Calendar.current.startOfDay`, not a hard-coded
    // UTC literal, so the test is not timezone-dependent.
    let now = Date()
    let earlierToday = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
    let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    let ts = isoFormatter.string(from: earlierToday)

    let mainLine = #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":100,"output_tokens":50}}}"#
    try (mainLine + "\n").write(to: root.appendingPathComponent("shared-id.jsonl"),
                                atomically: true, encoding: .utf8)

    let subDir = root.appendingPathComponent("shared-id/subagents")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    let subLine = #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"Subagent done."}],"usage":{"input_tokens":20,"output_tokens":10}}}"#
    try (subLine + "\n").write(to: subDir.appendingPathComponent("agent-x.jsonl"),
                               atomically: true, encoding: .utf8)

    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))
    let sessions = source.rescan(now: now)

    #expect(sessions.count == 1)
    let merged = try #require(sessions.first)
    let today = try #require(merged.tokensToday,
                              "a merged session must still report a windowed figure")
    #expect(today.input == 120, "tokensToday must sum across the group, not take the newest member alone")
    #expect(today.output == 60)
    let costToday = try #require(merged.costToday)
    // 120 in @5/M + 60 out @25/M = 0.0006 + 0.0015
    #expect(abs(costToday - 0.0021) < 0.0001)
}

// Only Claude's asymmetry was covered above; this pins Codex's at the source
// level too — the reason this task exists is these three asymmetries.
@Test func codexSourceAppliesCostButNeverOverwritesItsOwnContextWindow() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-\(UUID().uuidString)/sessions")
    let dayDir = sessionsRoot.appendingPathComponent("2026/08/19")
    try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

    let lines = [
        #"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"cx-src","cwd":"/p"}}"#,
        #"{"type":"turn_context","timestamp":"2026-08-19T14:02:12.000Z","payload":{"model":"gpt-5.6-sol","cwd":"/p"}}"#,
        // `last_token_usage` equals `total_token_usage` here because this is
        // the session's only `token_count` event (real rollouts carry a full
        // breakdown on both — verified summing `last_token_usage` across a
        // real session's events exactly reconstructs its final
        // `total_token_usage`, with no drift).
        #"{"type":"event_msg","timestamp":"2026-08-19T14:02:13.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":2500},"model_context_window":272000}}}"#,
        #"{"type":"event_msg","timestamp":"2026-08-19T14:02:50.000Z","payload":{"type":"task_complete"}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n")
        .write(to: dayDir.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)

    // `gpt-5.6-sol` carries no `contextWindow` in this table on purpose — the
    // window below must come from the rollout, never from here.
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    let source = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)
    let s = try #require(source.rescan(now: ISO8601.parse("2026-08-19T14:02:51.000Z")!).first)
    #expect(s.context?.window == 272_000, "the window must come from the rollout, not the price table")
    #expect(s.context?.used == 2_500)
    // 2000 in @5/M + 500 out @30/M = 0.01 + 0.015
    #expect(abs(try #require(s.cost) - 0.025) < 0.0001)
}

// Round-4 regression test. Round 3's merge made `id` collision-free per
// tick, so `main.swift` moved `recordedTotals`'s key from `transcriptPath`
// back to `id` — but `transcriptPath` was never safe as a CROSS-TICK key in
// the first place: a merged group's `transcriptPath` is whichever member is
// currently newest, and that flips every time activity moves parent ->
// subagent -> parent, the normal shape of every Task-tool call. A key that
// flips identity loses its prior baseline on every flip and the entire
// current cumulative total gets re-recorded as fresh burn. The single-tick
// merge test above cannot catch this — it calls `rescan()` once. This drives
// four simulated ticks, alternating which file is newest each time, mirroring
// the regression harness that caught it: merged totals go 100 -> 120 -> 125
// -> 127 as "newest" alternates parent/subagent/parent/subagent; true tokens
// ever written are 100+20+5+2 = 127. A delta tracker keyed by the
// merge-stabilized `id` (exactly what main.swift does) must record 127, not
// some multiple of it.
@Test func deltaTrackingKeyedByIdStaysCorrectAcrossNewestMemberFlips() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let mainURL = root.appendingPathComponent("shared-id.jsonl")
    let subDir = root.appendingPathComponent("shared-id/subagents")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    let subURL = subDir.appendingPathComponent("agent-x.jsonl")

    func line(tokens: Int, ts: String) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"shared-id","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
    }

    let source = ClaudeCodeSource(projectsRoot: root.deletingLastPathComponent(),
                                  pricing: try PricingTable.decode(pricingJSON))

    // Mirrors main.swift's delta tracker exactly (max(0, current - prior),
    // keyed by `id`) — this is what's actually under test.
    var recordedTotals: [String: Int] = [:]
    var totalRecorded = 0
    func tick() {
        for s in source.rescan(now: Date()) {
            let prior = recordedTotals[s.id] ?? 0
            totalRecorded += max(0, s.tokens.total - prior)
            recordedTotals[s.id] = s.tokens.total
        }
    }

    // Tick 1: only the parent file exists — trivially "newest". +100.
    try (line(tokens: 100, ts: "2026-08-19T18:00:00.000Z") + "\n")
        .write(to: mainURL, atomically: true, encoding: .utf8)
    tick()

    // Tick 2: the subagent file appears with a LATER timestamp — it becomes
    // newest, flipping the merged session's `transcriptPath`. +20.
    try (line(tokens: 20, ts: "2026-08-19T18:05:00.000Z") + "\n")
        .write(to: subURL, atomically: true, encoding: .utf8)
    tick()

    // Tick 3: back to the parent, with a still-later timestamp — flips
    // again. +5.
    let h1 = try FileHandle(forWritingTo: mainURL)
    try h1.seekToEnd()
    try h1.write(contentsOf: Data((line(tokens: 5, ts: "2026-08-19T18:10:00.000Z") + "\n").utf8))
    try h1.close()
    tick()

    // Tick 4: back to the subagent — flips one more time. +2.
    let h2 = try FileHandle(forWritingTo: subURL)
    try h2.seekToEnd()
    try h2.write(contentsOf: Data((line(tokens: 2, ts: "2026-08-19T18:15:00.000Z") + "\n").utf8))
    try h2.close()
    tick()

    #expect(totalRecorded == 127,
            "recorded burn must equal true tokens ever written (100+20+5+2), not a multiple inflated by every newest-member flip")
}

// MARK: - Round 3: checkpoint restore wiring (Ruling F49)
//
// Parser-level equivalence is covered directly in ClaudeTranscriptParserTests
// / CodexRolloutParserTests. These prove the SOURCE wiring around it: real
// files, real mtime/size stamps, a real `ClaudeCodeSource`/`CodexSource`
// constructed fresh (as a relaunch would) and seeded with a checkpoint
// exported from a PRIOR instance — the closest approximation of an actual
// app restart without spinning up the whole app.

@Test func sourceResumesFromACheckpointWhenTheFileGrewWhileClosed() throws {
    let projects = try fakeClaudeRoot()
    let fileURL = projects.appendingPathComponent("-Users-x-proj/sess-1.jsonl")
    let pricing = try PricingTable.decode(pricingJSON)

    let before = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let t0 = ISO8601.parse("2026-08-19T18:22:11.000Z")!
    _ = before.rescan(now: t0)
    let exported = before.checkpointState(now: t0)
    #expect(!exported.isEmpty, "the one real file read above must produce a checkpoint entry")

    // Simulate activity that happened while the app was closed.
    let moreLine = #"{"type":"assistant","timestamp":"2026-08-19T18:25:00.000Z","sessionId":"sess-1","cwd":"/Users/x/proj","gitBranch":"main","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"More."}],"usage":{"input_tokens":9,"output_tokens":4}}}"#
    let h = try FileHandle(forWritingTo: fileURL)
    try h.seekToEnd()
    try h.write(contentsOf: Data((moreLine + "\n").utf8))
    try h.close()

    // "Relaunch": a brand-new instance, seeded only with the exported checkpoint.
    let t1 = ISO8601.parse("2026-08-19T18:25:01.000Z")!
    let restored = ClaudeCodeSource(projectsRoot: projects, pricing: pricing, checkpoint: exported)
    let resumedSession = try #require(restored.rescan(now: t1).first)

    // Ground truth: a source with NO checkpoint, reading the whole grown
    // file from scratch.
    let fresh = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let freshSession = try #require(fresh.rescan(now: t1).first)

    #expect(resumedSession == freshSession,
            "resuming from a checkpoint after growth must match a full from-zero re-read exactly")
}

@Test func sourceResumesFromACheckpointWhenTheFileIsUnchanged() throws {
    let projects = try fakeClaudeRoot()
    let pricing = try PricingTable.decode(pricingJSON)

    let before = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let t0 = ISO8601.parse("2026-08-19T18:22:11.000Z")!
    let originalSession = try #require(before.rescan(now: t0).first)
    let exported = before.checkpointState(now: t0)

    // No changes to the file at all — nothing new to read.
    let restored = ClaudeCodeSource(projectsRoot: projects, pricing: pricing, checkpoint: exported)
    let resumedSession = try #require(restored.rescan(now: t0).first)

    #expect(resumedSession == originalSession)
}

@Test func sourceDiscardsACheckpointWhenTheFileWasTruncatedOrReplaced() throws {
    let projects = try fakeClaudeRoot()
    let fileURL = projects.appendingPathComponent("-Users-x-proj/sess-1.jsonl")
    let pricing = try PricingTable.decode(pricingJSON)

    let before = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let t0 = ISO8601.parse("2026-08-19T18:22:11.000Z")!
    _ = before.rescan(now: t0)
    let exported = before.checkpointState(now: t0)

    // Replace the file with unrelated, SHORTER content — as if the original
    // session file were deleted and a new one reused the path (or the
    // transcript was truncated by something outside AgentMenu entirely).
    let replacementLine = #"{"type":"assistant","timestamp":"2026-08-19T19:00:00.000Z","sessionId":"sess-2","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"New."}],"usage":{"input_tokens":3,"output_tokens":1}}}"#
    try (replacementLine + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

    let t1 = ISO8601.parse("2026-08-19T19:00:01.000Z")!
    let restored = ClaudeCodeSource(projectsRoot: projects, pricing: pricing, checkpoint: exported)
    let resumedSession = try #require(restored.rescan(now: t1).first)

    // Ground truth: a fresh source reading the REPLACED content from zero,
    // with no stale checkpoint at all.
    let fresh = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let freshSession = try #require(fresh.rescan(now: t1).first)

    #expect(resumedSession == freshSession,
            "a shrunk/replaced file must discard the stale checkpoint and re-read from zero")
    #expect(resumedSession.nativeId == "sess-2", "sanity: this really is the replaced content, not leftover state")
}

@Test func sourceIgnoresACheckpointEntryWhoseStampDoesNotMatchTheRealFile() throws {
    // Directly exercises the `isValid` gate at the wiring boundary: an entry
    // whose recorded size could never correspond to reality (adversarial or
    // corrupt input, however it might have gotten here) must never be
    // trusted — the source must fall back to a full read exactly as if no
    // checkpoint had been supplied at all.
    let projects = try fakeClaudeRoot()
    let pricing = try PricingTable.decode(pricingJSON)
    let fileURL = projects.appendingPathComponent("-Users-x-proj/sess-1.jsonl")
    let realSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! Int

    var bogusParser = ClaudeTranscriptParser()
    bogusParser.consume(Data(#"{"type":"assistant","timestamp":"2020-01-01T00:00:00.000Z","sessionId":"wrong","cwd":"/nowhere","message":{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"bogus"}],"usage":{"input_tokens":999999,"output_tokens":999999}}}"#.utf8))
    let bogusEntry = TranscriptCheckpoint(
        state: bogusParser,
        offset: UInt64(realSize) + 10_000,       // impossible: past the real EOF
        size: UInt64(realSize) + 10_000,
        modifiedAt: Date(timeIntervalSince1970: 0),
        version: ClaudeTranscriptParser.checkpointVersion)

    let t0 = ISO8601.parse("2026-08-19T18:22:11.000Z")!
    let withBogusCheckpoint = ClaudeCodeSource(projectsRoot: projects, pricing: pricing,
                                               checkpoint: [fileURL.path: bogusEntry])
    let session = try #require(withBogusCheckpoint.rescan(now: t0).first)

    let fresh = ClaudeCodeSource(projectsRoot: projects, pricing: pricing)
    let freshSession = try #require(fresh.rescan(now: t0).first)

    #expect(session == freshSession, "an unverifiable stamp must never be trusted")
    #expect(session.nativeId == "sess-1", "must read the REAL file, not anything from the bogus entry")
}

// Same three scenarios, for Codex — proves the identical wiring in
// `CodexSource` independently (different concrete parser/checkpoint types).
@Test func codexSourceResumesFromACheckpointWhenTheFileGrewWhileClosed() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-\(UUID().uuidString)/sessions")
    let dayDir = sessionsRoot.appendingPathComponent("2026/08/19")
    try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let fileURL = dayDir.appendingPathComponent("rollout-test.jsonl")

    let lines = [
        #"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"cx-src","cwd":"/p"}}"#,
        #"{"type":"turn_context","timestamp":"2026-08-19T14:02:12.000Z","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"type":"event_msg","timestamp":"2026-08-19T14:02:13.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":2500}}}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    let pricing = try PricingTable.decode(#"{"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}"#.data(using: .utf8)!)

    let before = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)
    let t0 = ISO8601.parse("2026-08-19T14:02:14.000Z")!
    _ = before.rescan(now: t0)
    let exported = before.checkpointState(now: t0)
    #expect(!exported.isEmpty)

    let moreLine = #"{"type":"event_msg","timestamp":"2026-08-19T14:05:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2100,"cached_input_tokens":0,"output_tokens":520},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}"#
    let h = try FileHandle(forWritingTo: fileURL)
    try h.seekToEnd()
    try h.write(contentsOf: Data((moreLine + "\n").utf8))
    try h.close()

    let t1 = ISO8601.parse("2026-08-19T14:05:01.000Z")!
    let restored = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing, checkpoint: exported)
    let resumedSession = try #require(restored.rescan(now: t1).first)

    let fresh = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)
    let freshSession = try #require(fresh.rescan(now: t1).first)

    #expect(resumedSession == freshSession)
}

@Test func codexSourceDiscardsACheckpointWhenTheFileWasTruncatedOrReplaced() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-\(UUID().uuidString)/sessions")
    let dayDir = sessionsRoot.appendingPathComponent("2026/08/19")
    try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let fileURL = dayDir.appendingPathComponent("rollout-test.jsonl")

    let lines = [
        #"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"cx-src","cwd":"/p"}}"#,
        #"{"type":"turn_context","timestamp":"2026-08-19T14:02:12.000Z","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"type":"event_msg","timestamp":"2026-08-19T14:02:13.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":2500}}}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    let pricing = try PricingTable.decode(#"{"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}"#.data(using: .utf8)!)

    let before = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)
    let t0 = ISO8601.parse("2026-08-19T14:02:14.000Z")!
    _ = before.rescan(now: t0)
    let exported = before.checkpointState(now: t0)

    // Replace with a shorter, unrelated rollout.
    let replacement = #"{"type":"session_meta","timestamp":"2026-08-19T20:00:00.000Z","payload":{"id":"cx-new","cwd":"/p"}}"#
    try (replacement + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

    let t1 = ISO8601.parse("2026-08-19T20:00:01.000Z")!
    let restored = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing, checkpoint: exported)

    // A stale/invalid checkpoint plus session_meta-only content (no
    // terminal/lastAt-bearing usage line) can legitimately fail the parser's
    // own `guard let id, let lastAt` in `session(path:now:)` — the point
    // under test is that it behaves IDENTICALLY to a fresh source, not that
    // it necessarily produces a non-nil session.
    let restoredSessions = restored.rescan(now: t1)
    let fresh = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)
    let freshSessions = fresh.rescan(now: t1)

    #expect(restoredSessions == freshSessions,
            "a shrunk/replaced rollout must discard the stale checkpoint and re-read from zero")
}

// MARK: - Perf fix: windowed-sum memoisation correctness
//
// `ClaudeCodeSource`/`CodexSource` memoise tokensToday/tokensLast5h (and,
// for Codex, cost/costToday) keyed on (a fold count, a coarsened `now`)
// rather than recomputing on every rescan tick — see `ClaudeCodeSource
// .windowCache`'s doc comment. Unlike the parser-level Feature 1 tests
// (which call `session` exactly once), these call `rescan` MULTIPLE times
// against the SAME source, so they are the only tests that can actually
// observe the cache: whether it invalidates exactly when it must (a new
// calendar day, new content) and reuses exactly when it may (identical
// fold count, identical bucket).

// Same `nonisolated(unsafe)` acceptance as `ISO8601.swift`'s own cached
// formatter and `ClaudeTranscriptParserTests`'s identical constant:
// read-only after construction, never mutated concurrently.
nonisolated(unsafe) private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

@Test func claudeSourceTokensTodayRollsOverAtMidnightWithNoNewContent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("sess.jsonl")

    func line(at date: Date, input: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(isoWithFraction.string(from: date))","sessionId":"s","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
    }

    // A SINGLE message, safely before both queries below (no message is
    // ever dated after the `now` that queries it — `usage(since:)` has no
    // upper bound, so a "future" message would be included regardless of
    // caching and would prove nothing about THIS cache). The file is
    // written once and never touched again: `foldedUsageCount` is
    // identical across every rescan below. The ONLY thing that moves is
    // `now`, crossing local midnight — exactly the "2 live agents, zero
    // transcript writes" regression scenario the perf fix targets, and the
    // one dimension a cache keyed on fold-count ALONE (forgetting the
    // coarsened-`now` bucket) would get wrong.
    let boundaryMidnight = Calendar.current.startOfDay(for: Date())
    let messageTime = boundaryMidnight.addingTimeInterval(-300)   // 5 min before local midnight
    try (line(at: messageTime, input: 100) + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))

    let query1 = boundaryMidnight.addingTimeInterval(-120)   // 2 min before midnight, same day as the message
    let pass1 = try #require(source.rescan(now: query1).first)
    #expect(pass1.tokensToday?.input == 100, "before midnight, the message is still inside \"today\"")

    let query2 = boundaryMidnight.addingTimeInterval(120)    // 2 min after midnight
    let pass2 = try #require(source.rescan(now: query2).first)
    #expect(pass2.tokensToday?.input == 0,
            "after midnight, tokensToday must roll over to exclude yesterday's message — a cache that doesn't re-key on the new calendar day would keep reporting yesterday's 100 as \"today\"'s total")
    #expect(pass2.tokens.input == 100, "the lifetime total is untouched by the window rolling over")
}

@Test func claudeSourceWindowCacheAgreesWithAFromScratchRecomputeAcrossHitsAndMisses() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-\(UUID().uuidString)/projects/-Users-x-proj")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("sess.jsonl")

    func line(at date: Date, input: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(isoWithFraction.string(from: date))","sessionId":"s","cwd":"/Users/x/proj","message":{"model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }
    func freshSession(_ lines: [String], now: Date) throws -> AgentSession {
        var p = ClaudeTranscriptParser()
        for l in lines { p.consume(Data(l.utf8)) }
        return try #require(p.session(path: fileURL.path, now: now))
    }

    let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)   // 1am today
    let projects = root.deletingLastPathComponent()
    let source = ClaudeCodeSource(projectsRoot: projects, pricing: try PricingTable.decode(pricingJSON))

    // Tick 1: first content, first rescan — necessarily a cache MISS.
    var lines = [line(at: now.addingTimeInterval(-120), input: 10, output: 1)]
    try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    let pass1 = try #require(source.rescan(now: now).first)
    let fresh1 = try freshSession(lines, now: now)
    #expect(pass1.tokensToday == fresh1.tokensToday)
    #expect(pass1.tokensLast5h == fresh1.tokensLast5h)

    // Tick 2: identical `now`, file untouched — must be a cache HIT, and
    // still agree with a from-scratch recompute over the same data.
    let pass2 = try #require(source.rescan(now: now).first)
    #expect(pass2.tokensToday == fresh1.tokensToday)
    #expect(pass2.tokensLast5h == fresh1.tokensLast5h)

    // Tick 3: new content appended, `now` UNCHANGED — foldedUsageCount
    // moves even though the bucket doesn't, and must still invalidate.
    let newLine = line(at: now.addingTimeInterval(-60), input: 20, output: 2)
    lines.append(newLine)
    let h = try FileHandle(forWritingTo: fileURL)
    try h.seekToEnd()
    try h.write(contentsOf: Data((newLine + "\n").utf8))
    try h.close()
    let pass3 = try #require(source.rescan(now: now).first)
    let fresh3 = try freshSession(lines, now: now)
    #expect(pass3.tokensToday == fresh3.tokensToday)
    #expect(pass3.tokensLast5h == fresh3.tokensLast5h)
    #expect(fresh3.tokensToday?.input == 30, "sanity: both messages are really inside today's window")

    // Tick 4: no new content, but `now` advances into a new
    // `AgentSourceTuning.windowCacheGranularity` bucket — must invalidate
    // and still agree with a from-scratch recompute.
    let laterNow = now.addingTimeInterval(AgentSourceTuning.windowCacheGranularity + 5)
    let pass4 = try #require(source.rescan(now: laterNow).first)
    let fresh4 = try freshSession(lines, now: laterNow)
    #expect(pass4.tokensToday == fresh4.tokensToday)
    #expect(pass4.tokensLast5h == fresh4.tokensLast5h)
}

@Test func codexSourceTokensTodayRollsOverAtMidnightWithNoNewContent() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-\(UUID().uuidString)/sessions")
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    let fileURL = sessionsRoot.appendingPathComponent("rollout-test.jsonl")

    // Same construction as the Claude version above: one request, safely
    // before both queries, file written once and never touched again.
    let boundaryMidnight = Calendar.current.startOfDay(for: Date())
    let messageTime = boundaryMidnight.addingTimeInterval(-300)
    let metaTime = messageTime.addingTimeInterval(-60)
    let lines = [
        #"{"type":"session_meta","timestamp":"\#(isoWithFraction.string(from: metaTime))","payload":{"id":"cx-1","cwd":"/p"}}"#,
        #"{"type":"event_msg","timestamp":"\#(isoWithFraction.string(from: messageTime))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"#,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

    let source = CodexSource(sessionsRoot: sessionsRoot, pricing: PricingTable(models: [:]))

    let query1 = boundaryMidnight.addingTimeInterval(-120)
    let pass1 = try #require(source.rescan(now: query1).first)
    #expect(pass1.tokensToday?.input == 100)

    let query2 = boundaryMidnight.addingTimeInterval(120)
    let pass2 = try #require(source.rescan(now: query2).first)
    #expect(pass2.tokensToday?.input == 0,
            "after midnight, tokensToday must roll over to exclude yesterday's request")
    #expect(pass2.tokens.input == 100, "the lifetime total is untouched by the window rolling over")
}

@Test func codexSourceCostCacheAgreesWithAFromScratchRecomputeAcrossHitsAndMisses() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-\(UUID().uuidString)/sessions")
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    let fileURL = sessionsRoot.appendingPathComponent("rollout-test.jsonl")

    func tokenCountLine(at date: Date, input: Int, output: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(isoWithFraction.string(from: date))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
    }
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    func freshSession(_ lines: [String], now: Date) throws -> AgentSession {
        var p = CodexRolloutParser()
        for l in lines { p.consume(Data(l.utf8)) }
        var s = try #require(p.session(path: fileURL.path, now: now))
        if let model = s.model {
            s.cost = p.cost(pricing: pricing, model: model)
            s.costToday = p.costToday(pricing: pricing, model: model, now: now)
        }
        return s
    }

    let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
    let metaTime = now.addingTimeInterval(-600)
    var lines = [
        #"{"type":"session_meta","timestamp":"\#(isoWithFraction.string(from: metaTime))","payload":{"id":"cx-2","cwd":"/p"}}"#,
        #"{"type":"turn_context","timestamp":"\#(isoWithFraction.string(from: metaTime))","payload":{"model":"gpt-5.6-sol"}}"#,
        tokenCountLine(at: now.addingTimeInterval(-300), input: 1000, output: 100),
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

    let source = CodexSource(sessionsRoot: sessionsRoot, pricing: pricing)

    // Tick 1: necessarily a cache MISS.
    let pass1 = try #require(source.rescan(now: now).first)
    let fresh1 = try freshSession(lines, now: now)
    #expect(pass1.cost == fresh1.cost)
    #expect(pass1.costToday == fresh1.costToday)

    // Tick 2: identical `now`, file untouched — must be a cache HIT, and
    // still agree with a from-scratch recompute.
    let pass2 = try #require(source.rescan(now: now).first)
    #expect(pass2.cost == fresh1.cost)
    #expect(pass2.costToday == fresh1.costToday)

    // Tick 3: a new request appended — foldedRequestCount moves, must
    // invalidate even though `now`'s bucket doesn't.
    let newLine = tokenCountLine(at: now.addingTimeInterval(-60), input: 2000, output: 200)
    lines.append(newLine)
    let h = try FileHandle(forWritingTo: fileURL)
    try h.seekToEnd()
    try h.write(contentsOf: Data((newLine + "\n").utf8))
    try h.close()
    let pass3 = try #require(source.rescan(now: now).first)
    let fresh3 = try freshSession(lines, now: now)
    #expect(pass3.cost == fresh3.cost)
    #expect(pass3.costToday == fresh3.costToday)
    let cost1 = try #require(fresh1.cost)
    let cost3 = try #require(fresh3.cost)
    #expect(cost3 > cost1, "sanity: cost grew with the new request")
}
