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
