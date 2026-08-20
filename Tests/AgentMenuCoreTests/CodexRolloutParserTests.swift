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
