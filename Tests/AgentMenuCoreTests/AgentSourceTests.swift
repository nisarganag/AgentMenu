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
        #"{"type":"event_msg","timestamp":"2026-08-19T14:02:13.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":500},"last_token_usage":{"total_tokens":2500},"model_context_window":272000}}}"#,
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
