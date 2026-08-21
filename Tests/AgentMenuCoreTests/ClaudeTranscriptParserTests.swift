import Testing
import Foundation
@testable import AgentMenuCore

private func fixture(_ name: String) throws -> [Data] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    let bytes = try [UInt8](Data(contentsOf: url))
    return bytes.split(separator: 0x0A).map { Data($0) }
}

private func parsed(_ name: String, now: Date = Date(timeIntervalSince1970: 2_000_000_000))
    throws -> AgentSession
{
    var p = ClaudeTranscriptParser()
    for line in try fixture(name) { p.consume(line) }
    return try #require(p.session(path: "/tmp/\(name)", now: now))
}

@Test func sumsTokensAcrossAssistantMessages() throws {
    let s = try parsed("claude-session.jsonl")
    #expect(s.tokens.input == 7)            // 2 + 5
    #expect(s.tokens.output == 372)         // 322 + 50
    #expect(s.tokens.cacheRead == 115_495)  // 20868 + 94627
    #expect(s.tokens.cacheWrite == 22_453)  // 22353 + 100
    #expect(s.tokens.reasoning == 12)
}

@Test func contextFillUsesLastMessageNotTheSum() throws {
    let s = try parsed("claude-session.jsonl")
    // 5 + 94627 + 100 — the last message's live context, not cumulative burn.
    #expect(try #require(s.context).used == 94_732)
}

@Test func lastActivityIsFinalTextTruncatedToFirstLine() throws {
    let s = try parsed("claude-session.jsonl")
    #expect(try #require(s.lastActivity).line == "Done.")
}

@Test func toolCallsRenderWithTheirPrimaryArgument() {
    var p = ClaudeTranscriptParser()
    p.consume(Data("""
    {"type":"assistant","timestamp":"2026-08-19T18:21:33.704Z","sessionId":"s","cwd":"/p","message":{"model":"m","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"./mvnw test"}}],"usage":{"input_tokens":1,"output_tokens":1}}}
    """.utf8))
    let s = p.session(path: "/tmp/x", now: Date())
    #expect(s?.lastActivity?.line == "Bash  ./mvnw test")
}

@Test func endTurnMarksSessionDone() throws {
    let s = try parsed("claude-session.jsonl")
    guard case .done = s.state else { Issue.record("expected .done, got \(s.state)"); return }
}

@Test func staleWorkingSessionFallsBackToIdle() {
    var p = ClaudeTranscriptParser()
    p.consume(Data("""
    {"type":"assistant","timestamp":"2026-08-19T18:21:33.704Z","sessionId":"s","cwd":"/p","message":{"model":"m","stop_reason":"tool_use","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":1,"output_tokens":1}}}
    """.utf8))
    let long = Date(timeIntervalSince1970: 2_000_000_000)   // years later
    guard case .idle = p.session(path: "/tmp/x", now: long)?.state else {
        Issue.record("a turn that stopped years ago is not still working"); return
    }
}

@Test func malformedAndTruncatedLinesAreSkippedNotFatal() throws {
    var p = ClaudeTranscriptParser()
    p.consume(Data("not json at all".utf8))
    p.consume(Data("{\"type\":\"assistant\"".utf8))
    #expect(p.session(path: "/tmp/x", now: Date()) == nil)
    for line in try fixture("claude-session.jsonl") { p.consume(line) }
    #expect(p.session(path: "/tmp/x", now: Date()) != nil)
}

@Test func projectNameIsLastPathComponentOfCwd() throws {
    let s = try parsed("claude-session.jsonl")
    #expect(s.project == "proj")
    #expect(s.branch == "main")
    #expect(s.model == "claude-opus-5")
}

// MARK: - Feature 1: calendar-day / trailing-5h windowing

// Same `nonisolated(unsafe)` acceptance as `ISO8601.swift`'s own cached
// formatter: read-only after construction, never mutated concurrently.
nonisolated(unsafe) private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Deliberately timestamped relative to `Calendar.current.startOfDay`,
/// never a hard-coded UTC literal — otherwise "is this before or after local
/// midnight" would depend on whichever timezone happens to run the test.
private func claudeUsageLine(at date: Date, sessionId: String = "s", input: Int, output: Int) -> Data {
    let ts = isoWithFraction.string(from: date)
    return Data(#"""
    {"type":"assistant","timestamp":"\#(ts)","sessionId":"\#(sessionId)","cwd":"/p","message":{"model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}
    """#.utf8)
}

@Test func tokensTodaySumsOnlyMessagesSinceLocalMidnight() {
    let now = Date()
    let todayStart = Calendar.current.startOfDay(for: now)
    let yesterday = todayStart.addingTimeInterval(-3600)     // 1h before local midnight
    let earlierToday = todayStart.addingTimeInterval(3600)   // 1h after local midnight

    var p = ClaudeTranscriptParser()
    p.consume(claudeUsageLine(at: yesterday, input: 100, output: 50))
    p.consume(claudeUsageLine(at: earlierToday, input: 10, output: 5))
    let s = p.session(path: "/tmp/x", now: now)

    #expect(s?.tokens.total == 165, "the cumulative total still includes yesterday's usage")
    let today = s?.tokensToday
    #expect(today?.input == 10, "tokensToday must exclude yesterday's message")
    #expect(today?.output == 5)
}

@Test func tokensTodayIsPresentButZeroWhenNoMessageFallsInToday() throws {
    let now = Date()
    let todayStart = Calendar.current.startOfDay(for: now)
    let yesterday = todayStart.addingTimeInterval(-3600)

    var p = ClaudeTranscriptParser()
    p.consume(claudeUsageLine(at: yesterday, input: 100, output: 50))
    let s = p.session(path: "/tmp/x", now: now)

    let today = try #require(s?.tokensToday, "tokensToday must be present even with no activity today")
    #expect(today.total == 0, "no activity today is a real, known zero — never nil")
}

@Test func tokensLast5hSumsOnlyMessagesWithinTheTrailingWindow() throws {
    let now = Date()
    let sixHoursAgo = now.addingTimeInterval(-6 * 3600)
    let twoHoursAgo = now.addingTimeInterval(-2 * 3600)

    var p = ClaudeTranscriptParser()
    p.consume(claudeUsageLine(at: sixHoursAgo, input: 100, output: 0))
    p.consume(claudeUsageLine(at: twoHoursAgo, input: 20, output: 3))
    let s = p.session(path: "/tmp/x", now: now)

    let last5h = try #require(s?.tokensLast5h)
    #expect(last5h.input == 20, "the 6h-old message must fall outside the trailing 5h window")
    #expect(last5h.output == 3)
}

// MARK: - Feature 2: real Claude rate-limit detection

@Test func apiErrorStatus429SetsLastRateLimitAt() {
    var p = ClaudeTranscriptParser()
    p.consume(Data(#"""
    {"type":"assistant","timestamp":"2026-08-19T18:21:00.000Z","sessionId":"s","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}}
    """#.utf8))
    // Verified real shape: a failed call is a top-level sibling of `message`,
    // not nested inside it, with `message.model == "<synthetic>"`.
    p.consume(Data(#"""
    {"type":"assistant","timestamp":"2026-08-19T18:22:00.000Z","sessionId":"s","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error"}],"usage":{"input_tokens":0,"output_tokens":0}},"error":"rate_limit_error","isApiErrorMessage":true,"apiErrorStatus":429}
    """#.utf8))
    let s = p.session(path: "/tmp/x", now: ISO8601.parse("2026-08-19T18:22:01.000Z")!)
    #expect(s?.lastRateLimitAt == ISO8601.parse("2026-08-19T18:22:00.000Z"))
}

@Test func nonRateLimitApiErrorsDoNotSetLastRateLimitAt() {
    var p = ClaudeTranscriptParser()
    p.consume(Data(#"""
    {"type":"assistant","timestamp":"2026-08-19T18:21:00.000Z","sessionId":"s","message":{"model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}}
    """#.utf8))
    // Real, observed on this machine: a 529 overload, never a 429 rate limit.
    p.consume(Data(#"""
    {"type":"assistant","timestamp":"2026-08-19T18:22:00.000Z","sessionId":"s","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"Overloaded"}],"usage":{"input_tokens":0,"output_tokens":0}},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":529}
    """#.utf8))
    let s = p.session(path: "/tmp/x", now: ISO8601.parse("2026-08-19T18:22:01.000Z")!)
    #expect(s?.lastRateLimitAt == nil, "a 529 overload is not a rate limit")
}

// MARK: - Round 3: checkpoint accumulator persistence (Ruling F49)
//
// The correctness bar: parsing a file in one pass must be indistinguishable
// from parsing it in two passes with a checkpoint save/restore in between —
// every field of the resulting `AgentSession`, not just the lifetime token
// total. A byte offset restored against a FRESH accumulator would satisfy a
// weaker test (it would still produce SOME session) while silently
// under-reporting everything the fresh accumulator never saw — this is
// exactly the anti-pattern Ruling F49 rejects, so the test must compare full
// equality, not just "did it parse."

/// Splits the fixture, runs the first half through one parser, snapshots and
/// round-trips it through REAL `Codable` (encode/decode), then feeds the
/// second half into the restored parser. Mirrors what
/// `ClaudeCodeSource`/`Checkpoint` do at a save/relaunch boundary, minus the
/// file I/O — that half is covered separately in `AgentSourceTests`.
private func twoPassSession(splitAt: Int, now: Date) throws -> AgentSession {
    let lines = try fixture("claude-session.jsonl")
    var first = ClaudeTranscriptParser()
    for line in lines[..<splitAt] { first.consume(line) }
    let snapshot = first.checkpointSnapshot(now: now)
    let data = try JSONEncoder().encode(snapshot)
    var restored = try JSONDecoder().decode(ClaudeTranscriptParser.self, from: data)
    for line in lines[splitAt...] { restored.consume(line) }
    return try #require(restored.session(path: "/tmp/x", now: now))
}

@Test func twoPassWithCheckpointRestoreMidFileMatchesOnePassExactly() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let lines = try fixture("claude-session.jsonl")
    var full = ClaudeTranscriptParser()
    for line in lines { full.consume(line) }
    let fullSession = try #require(full.session(path: "/tmp/x", now: now))

    let twoPass = try twoPassSession(splitAt: lines.count / 2, now: now)
    #expect(twoPass == fullSession, "resuming mid-file must reproduce the full parse in every field")
}

@Test func checkpointRestoreOfAnUnchangedFileMatchesOnePassExactly() throws {
    // "The file hasn't changed since the checkpoint" — the whole file was
    // already in the first pass; the second pass consumes zero new lines.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let lines = try fixture("claude-session.jsonl")
    var full = ClaudeTranscriptParser()
    for line in lines { full.consume(line) }
    let fullSession = try #require(full.session(path: "/tmp/x", now: now))

    let twoPass = try twoPassSession(splitAt: lines.count, now: now)
    #expect(twoPass == fullSession)
}

@Test func checkpointRestoreOfAFreshlyStartedFileMatchesOnePassExactly() throws {
    // Degenerate opposite split: nothing consumed before the checkpoint —
    // every line arrives in the "second pass" against a snapshot of a brand
    // new parser.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let lines = try fixture("claude-session.jsonl")
    var full = ClaudeTranscriptParser()
    for line in lines { full.consume(line) }
    let fullSession = try #require(full.session(path: "/tmp/x", now: now))

    let twoPass = try twoPassSession(splitAt: 0, now: now)
    #expect(twoPass == fullSession)
}

@Test func checkpointSnapshotRoundTripsThroughCodableWithoutLosingAnyState() throws {
    // Same idea, but checked directly against the DECODED parser rather than
    // through `session(path:now:)` — pins that Codable itself is lossless
    // for every stored field, not just the ones `session` happens to surface.
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var p = ClaudeTranscriptParser()
    for line in try fixture("claude-session.jsonl") { p.consume(line) }
    let snapshot = p.checkpointSnapshot(now: now)   // no pruning expected: all messages are "recent" relative to `now`
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(ClaudeTranscriptParser.self, from: data)
    #expect(restored == snapshot)
}

// Proves `checkpointSnapshot`'s pruning cutoff — `min(todayStart, now-5h)` —
// keeps anything inside EITHER window, not just the narrower of the two.
// Anchored to noon today rather than `Date()` directly so the "6am is inside
// today but outside the trailing 5h" relationship never depends on what
// wall-clock time the test happens to run at.
@Test func checkpointSnapshotPruningKeepsEntriesInsideTodayEvenIfOutsideTheTrailing5hWindow() throws {
    let todayStart = Calendar.current.startOfDay(for: Date())
    let now1 = todayStart.addingTimeInterval(12 * 3600)     // noon: the checkpoint save moment
    let sixAM = todayStart.addingTimeInterval(6 * 3600)     // inside today, outside the 5h-before-noon window

    var p = ClaudeTranscriptParser()
    p.consume(claudeUsageLine(at: sixAM, input: 10, output: 5))

    // Confirm the premise: at save time this message is already outside the
    // trailing 5h window.
    #expect(p.session(path: "/tmp/x", now: now1)?.tokensLast5h?.input == 0)

    let snapshot = p.checkpointSnapshot(now: now1)
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(ClaudeTranscriptParser.self, from: data)

    // Evaluated LATER (after "relaunch"), still today: tokensToday must
    // still see it — proving the prune kept it for being inside TODAY, not
    // merely inside the narrower 5h window.
    let now2 = now1.addingTimeInterval(3600)
    #expect(restored.session(path: "/tmp/x", now: now2)?.tokensToday?.input == 10,
            "an entry inside today but outside the 5h window must survive the checkpoint prune")
    // The lifetime total needs no log at all — it is never pruned.
    #expect(restored.session(path: "/tmp/x", now: now2)?.tokens.input == 10)
}
