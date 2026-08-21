import Testing
import Foundation
@testable import AgentMenuCore

private func codexFixtureLines() throws -> [Data] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/codex-rollout.jsonl",
                                             withExtension: nil))
    let bytes = try [UInt8](Data(contentsOf: url))
    return bytes.split(separator: 0x0A).map { Data($0) }
}

private func parsedCodex(now: Date) throws -> AgentSession {
    var p = CodexRolloutParser()
    for line in try codexFixtureLines() { p.consume(line) }
    return try #require(p.session(path: "/tmp/rollout.jsonl", now: now))
}

private let lastEvent = ISO8601.parse("2026-08-19T14:02:40.000Z")!

@Test func readsIdentityFromSessionMeta() throws {
    let s = try parsedCodex(now: lastEvent)
    #expect(s.nativeId == "cx-1")
    #expect(s.project == "worldmonitor")
    #expect(s.branch == "main")
    #expect(s.kind == .codex)
}

@Test func turnContextSuppliesTheModelSessionMetaDoesNotHave() {
    var p = CodexRolloutParser()
    p.consume(Data(#"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"c","cwd":"/p"}}"#.utf8))
    p.consume(Data(#"{"type":"turn_context","timestamp":"2026-08-19T14:02:12.000Z","payload":{"model":"gpt-5.6-sol","effort":"ultra","cwd":"/p"}}"#.utf8))
    let at = ISO8601.parse("2026-08-19T14:02:12.000Z")!
    // session_meta carries no `model` key on real rollouts — only turn_context does.
    #expect(p.session(path: "/tmp/r", now: at)?.model == "gpt-5.6-sol")
}

@Test func doesNotDoubleCountCachedInsideInputTokens() throws {
    let s = try parsedCodex(now: lastEvent)
    // Codex's input_tokens already contains cached_input_tokens.
    #expect(s.tokens.input == 24_046_405 - 23_615_457)
    #expect(s.tokens.cacheRead == 23_615_457)
    #expect(s.tokens.cacheWrite == 400_931)
    #expect(s.tokens.output == 89_901)
    #expect(s.tokens.reasoning == 32_136)
}

@Test func contextWindowComesFromTheRolloutNotAPriceTable() throws {
    let ctx = try #require(try parsedCodex(now: lastEvent).context)
    #expect(ctx.window == 258_400)
    #expect(ctx.used == 188_395)      // last_token_usage.total_tokens
}

@Test func lastActivityIsTheFinalAgentMessageFirstLine() throws {
    #expect(try parsedCodex(now: lastEvent).lastActivity?.line == "Typecheck passed.")
}

@Test func toolCallActivityUsesNameAndInputString() {
    var p = CodexRolloutParser()
    p.consume(Data(#"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"c","cwd":"/p"}}"#.utf8))
    p.consume(Data(#"{"type":"event_msg","timestamp":"2026-08-19T14:02:25.000Z","payload":{"type":"custom_tool_call","name":"exec","input":"npm run typecheck"}}"#.utf8))
    let at = ISO8601.parse("2026-08-19T14:02:25.000Z")!
    #expect(p.session(path: "/tmp/r", now: at)?.lastActivity?.line == "exec  npm run typecheck")
}

@Test func functionCallFallsBackToArgumentsWhenInputIsAbsent() throws {
    var p = CodexRolloutParser()
    p.consume(Data(#"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"c","cwd":"/p"}}"#.utf8))
    p.consume(Data(#"{"type":"event_msg","timestamp":"2026-08-19T14:02:25.000Z","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"task_name\":\"audit_until\"}","call_id":"call-1"}}"#.utf8))
    let at = ISO8601.parse("2026-08-19T14:02:25.000Z")!
    let line = try #require(p.session(path: "/tmp/r", now: at)?.lastActivity?.line)
    // Real "function_call" payloads have no `input` key at all — the summary
    // must come from `arguments` instead of collapsing to an empty string.
    #expect(line.hasPrefix("spawn_agent  "), "summary must be non-empty, not just the bare tool name")
    #expect(line.contains("audit_until"), "summary must reflect the arguments string")
}

@Test func taskCompleteMarksDone() {
    var p = CodexRolloutParser()
    p.consume(Data(#"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"c","cwd":"/p"}}"#.utf8))
    p.consume(Data(#"{"type":"event_msg","timestamp":"2026-08-19T14:02:50.000Z","payload":{"type":"task_complete"}}"#.utf8))
    let at = ISO8601.parse("2026-08-19T14:02:50.000Z")!
    guard case .done = p.session(path: "/tmp/r", now: at)!.state else {
        Issue.record("task_complete must end the turn"); return
    }
}

@Test func stalledLiveTurnBecomesInferredPermissionNeverExact() throws {
    // 60s after the last event, with no completion signal.
    let s = try parsedCodex(now: lastEvent.addingTimeInterval(60))
    guard case .awaitingPermission(_, let confidence) = s.state else {
        Issue.record("expected inferred permission, got \(s.state)"); return
    }
    #expect(confidence == .inferred, "Codex logs no approval events; this can never be .exact")
}

@Test func fastToolSequenceDoesNotTripTheStallHeuristic() throws {
    // 5s after the last event is well inside the 25s threshold.
    let s = try parsedCodex(now: lastEvent.addingTimeInterval(5))
    guard case .working = s.state else {
        Issue.record("a 5s gap is normal work, not a stall"); return
    }
}

@Test func abortedTurnIsDoneNotStalled() {
    var p = CodexRolloutParser()
    p.consume(Data(#"{"type":"session_meta","timestamp":"2026-08-19T14:02:11.560Z","payload":{"id":"c","cwd":"/p"}}"#.utf8))
    p.consume(Data(#"{"type":"event_msg","timestamp":"2026-08-19T14:02:50.000Z","payload":{"type":"turn_aborted"}}"#.utf8))
    let long = ISO8601.parse("2026-08-19T14:05:00.000Z")!
    guard case .done = p.session(path: "/tmp/r", now: long)!.state else {
        Issue.record("an aborted turn is finished, not waiting on the user"); return
    }
}

// MARK: - Feature 1 & 3: per-request usage (`last_token_usage`), windowing, long-context cost

// Same `nonisolated(unsafe)` acceptance as `ISO8601.swift`'s own cached
// formatter: read-only after construction, never mutated concurrently.
nonisolated(unsafe) private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func codexSessionMeta(id: String = "c", at date: Date) -> Data {
    Data(#"{"type":"session_meta","timestamp":"\#(isoWithFraction.string(from: date))","payload":{"id":"\#(id)","cwd":"/p"}}"#.utf8)
}

private func codexTurnContext(model: String, at date: Date) -> Data {
    Data(#"{"type":"turn_context","timestamp":"\#(isoWithFraction.string(from: date))","payload":{"model":"\#(model)","cwd":"/p"}}"#.utf8)
}

/// `cumulative` is the running total-so-far (`total_token_usage`); `delta`
/// is THIS request's own contribution (`last_token_usage`) — verified
/// against real rollouts to be an exact, non-overlapping per-request slice
/// that reconstructs `cumulative` when summed across a session.
private func codexTokenCount(
    at date: Date, cumulative: (input: Int, cached: Int, output: Int),
    delta: (input: Int, cached: Int, output: Int)
) -> Data {
    let deltaTotal = max(0, delta.input - delta.cached) + delta.cached + delta.output
    return Data(#"""
    {"type":"event_msg","timestamp":"\#(isoWithFraction.string(from: date))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(cumulative.input),"cached_input_tokens":\#(cumulative.cached),"output_tokens":\#(cumulative.output)},"last_token_usage":{"input_tokens":\#(delta.input),"cached_input_tokens":\#(delta.cached),"output_tokens":\#(delta.output),"total_tokens":\#(deltaTotal)}}}}
    """#.utf8)
}

@Test func codexTokensTodaySumsOnlyRequestsSinceLocalMidnight() throws {
    let now = Date()
    let todayStart = Calendar.current.startOfDay(for: now)
    let yesterday = todayStart.addingTimeInterval(-3600)
    let earlierToday = todayStart.addingTimeInterval(3600)

    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: yesterday))
    p.consume(codexTokenCount(at: yesterday, cumulative: (1000, 0, 100), delta: (1000, 0, 100)))
    p.consume(codexTokenCount(at: earlierToday, cumulative: (1050, 0, 110), delta: (50, 0, 10)))
    let s = p.session(path: "/tmp/r", now: now)

    #expect(s?.tokens.output == 110, "the cumulative total reflects the latest snapshot")
    let today = try #require(s?.tokensToday)
    #expect(today.input == 50, "tokensToday must exclude yesterday's request")
    #expect(today.output == 10)
}

@Test func codexTokensLast5hSumsOnlyRequestsWithinTheTrailingWindow() throws {
    let now = Date()
    let sixHoursAgo = now.addingTimeInterval(-6 * 3600)
    let twoHoursAgo = now.addingTimeInterval(-2 * 3600)

    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: sixHoursAgo))
    p.consume(codexTokenCount(at: sixHoursAgo, cumulative: (500, 0, 0), delta: (500, 0, 0)))
    p.consume(codexTokenCount(at: twoHoursAgo, cumulative: (520, 0, 7), delta: (20, 0, 7)))
    let s = p.session(path: "/tmp/r", now: now)

    let last5h = try #require(s?.tokensLast5h)
    #expect(last5h.input == 20, "the 6h-old request must fall outside the trailing 5h window")
    #expect(last5h.output == 7)
}

/// Worked example, verified against this machine's real Codex rollouts
/// (model `gpt-5.6-terra`, file `rollout-2026-07-11T23-08-16-...jsonl`): one
/// real request measured 302,892 raw input tokens (287,567 of them cached)
/// against a 272,000 threshold, and another measured 228,333 (all
/// non-cached) — genuinely below it. This test reproduces both exactly.
@Test func costAppliesTheLongContextMultiplierOnlyToTheRequestThatCrossesTheThreshold() throws {
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-terra":{"inputPerMTok":2.0,"outputPerMTok":12.0,
    "cacheReadPerMTok":0.2,"cacheWritePerMTok":2.5,"longContextThreshold":272000,
    "longContextInputMultiplier":2.0,"longContextOutputMultiplier":1.5}}}
    """#.data(using: .utf8)!)

    let t0 = ISO8601.parse("2026-08-19T14:00:00.000Z")!
    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: t0))
    p.consume(codexTurnContext(model: "gpt-5.6-terra", at: t0))
    // Below threshold (228,333 raw input): flat rate, no surcharge.
    p.consume(codexTokenCount(at: t0.addingTimeInterval(10),
        cumulative: (228_333, 0, 609), delta: (228_333, 0, 609)))
    // Above threshold (302,892 raw input, 287,567 of it cached): 2x the
    // input side (plain + cache), 1.5x output — for THIS request only.
    p.consume(codexTokenCount(at: t0.addingTimeInterval(20),
        cumulative: (531_225, 287_567, 740), delta: (302_892, 287_567, 131)))

    let cost = try #require(p.cost(pricing: pricing, model: "gpt-5.6-terra"))
    let below = 228_333.0 / 1_000_000 * 2.0 + 609.0 / 1_000_000 * 12.0
    let aboveFlat = 15_325.0 / 1_000_000 * 2.0          // exclusive input 302892-287567, flat rate
                  + 287_567.0 / 1_000_000 * 0.2          // cached input, flat rate
                  + 131.0 / 1_000_000 * 12.0             // output, flat rate
    let above = 15_325.0 / 1_000_000 * 2.0 * 2.0        // exclusive input, doubled
              + 287_567.0 / 1_000_000 * 0.2 * 2.0        // cached input, also doubled
              + 131.0 / 1_000_000 * 12.0 * 1.5           // output, 1.5x
    #expect(abs(cost - (below + above)) < 0.0001)
    // The meaningful comparison is against the SAME request's own flat
    // price, not against the unrelated below-threshold request — whose much
    // larger non-cached volume happens to make it the pricier of the two
    // either way, surcharge or not.
    #expect(above > aboveFlat, "the surcharge must make the over-threshold request cost more than its own flat price")
}

@Test func costIgnoresTheMultiplierWhenNoLongContextFieldsAreConfigured() throws {
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    let t0 = ISO8601.parse("2026-08-19T14:00:00.000Z")!
    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: t0))
    p.consume(codexTurnContext(model: "gpt-5.6-sol", at: t0))
    p.consume(codexTokenCount(at: t0.addingTimeInterval(5),
        cumulative: (400_000, 0, 100), delta: (400_000, 0, 100)))

    let cost = try #require(p.cost(pricing: pricing, model: "gpt-5.6-sol"))
    let flat = 400_000.0 / 1_000_000 * 5.0 + 100.0 / 1_000_000 * 30.0
    #expect(abs(cost - flat) < 0.0001, "a model without long-context fields must never be surcharged")
}

@Test func costReturnsNilForAnUnpricedModelEvenWithARequestLog() throws {
    let pricing = try PricingTable.decode(#"{"models":{}}"#.data(using: .utf8)!)
    let t0 = ISO8601.parse("2026-08-19T14:00:00.000Z")!
    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: t0))
    p.consume(codexTokenCount(at: t0, cumulative: (100, 0, 10), delta: (100, 0, 10)))
    #expect(p.cost(pricing: pricing, model: "unknown-model") == nil,
            "an unknown model must render absent, never a guessed $0.00")
}

@Test func costTodayFiltersRequestsToTheCalendarDay() throws {
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    let now = Date()
    let todayStart = Calendar.current.startOfDay(for: now)
    let yesterday = todayStart.addingTimeInterval(-3600)
    let earlierToday = todayStart.addingTimeInterval(3600)

    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: yesterday))
    p.consume(codexTurnContext(model: "gpt-5.6-sol", at: yesterday))
    p.consume(codexTokenCount(at: yesterday, cumulative: (1_000_000, 0, 0), delta: (1_000_000, 0, 0)))
    p.consume(codexTokenCount(at: earlierToday, cumulative: (1_000_100, 0, 0), delta: (100, 0, 0)))

    let costToday = try #require(p.costToday(pricing: pricing, model: "gpt-5.6-sol", now: now))
    #expect(abs(costToday - (100.0 / 1_000_000 * 5.0)) < 0.0001,
            "costToday must only include today's request, not yesterday's much larger one")
}

// MARK: - Round 3: checkpoint accumulator persistence (Ruling F49)
//
// See `ClaudeTranscriptParserTests`'s identical section for the full
// rationale — the same offset-plus-accumulator equivalence bar applies here.

private func twoPassCodexSession(splitAt: Int, now: Date) throws -> AgentSession {
    let lines = try codexFixtureLines()
    var first = CodexRolloutParser()
    for line in lines[..<splitAt] { first.consume(line) }
    let snapshot = first.checkpointSnapshot(now: now)
    let data = try JSONEncoder().encode(snapshot)
    var restored = try JSONDecoder().decode(CodexRolloutParser.self, from: data)
    for line in lines[splitAt...] { restored.consume(line) }
    return try #require(restored.session(path: "/tmp/rollout.jsonl", now: now))
}

@Test func codexTwoPassWithCheckpointRestoreMidFileMatchesOnePassExactly() throws {
    let lines = try codexFixtureLines()
    var full = CodexRolloutParser()
    for line in lines { full.consume(line) }
    let fullSession = try #require(full.session(path: "/tmp/rollout.jsonl", now: lastEvent))

    let twoPass = try twoPassCodexSession(splitAt: lines.count / 2, now: lastEvent)
    #expect(twoPass == fullSession, "resuming mid-rollout must reproduce the full parse in every field")
}

@Test func codexCheckpointRestoreOfAnUnchangedRolloutMatchesOnePassExactly() throws {
    let lines = try codexFixtureLines()
    var full = CodexRolloutParser()
    for line in lines { full.consume(line) }
    let fullSession = try #require(full.session(path: "/tmp/rollout.jsonl", now: lastEvent))

    let twoPass = try twoPassCodexSession(splitAt: lines.count, now: lastEvent)
    #expect(twoPass == fullSession)
}

@Test func codexCheckpointSnapshotRoundTripsThroughCodableWithoutLosingAnyState() throws {
    var p = CodexRolloutParser()
    for line in try codexFixtureLines() { p.consume(line) }
    let snapshot = p.checkpointSnapshot(now: lastEvent)
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(CodexRolloutParser.self, from: data)
    #expect(restored == snapshot)
}

// Same "min(todayStart, now-5h)" pruning-boundary proof as
// ClaudeTranscriptParserTests, applied to `requestLog`/costToday instead.
@Test func checkpointSnapshotPruningKeepsRequestsInsideTodayEvenIfOutsideTheTrailing5hWindow() throws {
    let pricing = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    let todayStart = Calendar.current.startOfDay(for: Date())
    let now1 = todayStart.addingTimeInterval(12 * 3600)
    let sixAM = todayStart.addingTimeInterval(6 * 3600)

    var p = CodexRolloutParser()
    p.consume(codexSessionMeta(at: sixAM))
    p.consume(codexTurnContext(model: "gpt-5.6-sol", at: sixAM))
    p.consume(codexTokenCount(at: sixAM, cumulative: (100, 0, 10), delta: (100, 0, 10)))

    #expect(p.session(path: "/tmp/r", now: now1)?.tokensLast5h?.input == 0)

    let snapshot = p.checkpointSnapshot(now: now1)
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(CodexRolloutParser.self, from: data)

    let now2 = now1.addingTimeInterval(3600)
    #expect(restored.session(path: "/tmp/r", now: now2)?.tokensToday?.input == 100,
            "a request inside today but outside the 5h window must survive the checkpoint prune")
    let costToday = try #require(restored.costToday(pricing: pricing, model: "gpt-5.6-sol", now: now2))
    #expect(costToday > 0, "costToday is derived from requestLog too and must not silently go to zero")
}
