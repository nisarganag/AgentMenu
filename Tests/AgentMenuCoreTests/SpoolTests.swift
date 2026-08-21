import Testing
import Foundation
@testable import AgentMenuCore

private func tempSpool() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("spool-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ json: String, to dir: URL, name: String = UUID().uuidString) throws {
    try json.write(to: dir.appendingPathComponent("\(name).json"),
                   atomically: true, encoding: .utf8)
}

private let now = Date(timeIntervalSince1970: 1_755_689_500)

// Fix 6: the hooks are pure POSIX sh with no JSON parser of their own, so
// they wrap the agent's raw, unparsed payload verbatim in a small envelope
// rather than pre-flattening session_id/cwd/tool/summary themselves. These
// fixtures are what the rewritten Scripts/agentmenu-hook.sh and the
// generated codex-notify-shim.sh actually produce on disk.

@Test func decodesAndDeletesEvents() throws {
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"claude-code","event":"permission-required","ts":1755689420,"payload":{"session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"rm -rf x"}}}"#, to: dir)
    let w = SpoolWatcher(directory: dir)
    let events = w.drain(now: now)
    #expect(events.count == 1)
    #expect(events[0].agent == .claudeCode)
    #expect(events[0].event == .permissionRequired)
    #expect(events[0].sessionId == "s1")
    #expect(events[0].cwd == "/p")
    #expect(events[0].tool == "Bash")
    #expect(events[0].summary?.contains("rm -rf x") ?? false)
    // Draining consumes: a second call must be empty, or events replay forever.
    #expect(w.drain(now: now).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func claudeMessageFieldWinsOverToolInputWhenBothArePresent() throws {
    // The Notification hook payload carries `message`, not `tool_input` — a
    // turn-finished-shaped payload should never fall back to summarising a
    // tool call that isn't there.
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"claude-code","event":"turn-finished","ts":1755689420,"payload":{"session_id":"s1","cwd":"/p","message":"All tests pass."}}"#, to: dir)
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.first?.summary == "All tests pass.")
    #expect(events.first?.tool == nil)
}

@Test func codexPrefersThreadIdOverSessionIdAndReadsLastAssistantMessage() throws {
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"codex","event":"turn-finished","ts":1755689420,"payload":{"thread-id":"th-1","session_id":"should-be-ignored","cwd":"/p","last-assistant-message":"Done."}}"#, to: dir)
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.first?.sessionId == "th-1")
    #expect(events.first?.summary == "Done.")
    #expect(events.first?.tool == nil, "Codex never reports a tool name")
}

@Test func codexFallsBackToSessionIdWhenThreadIdIsAbsent() throws {
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"codex","event":"turn-finished","ts":1755689420,"payload":{"session_id":"s9","cwd":"/p"}}"#, to: dir)
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.first?.sessionId == "s9")
}

@Test func anEmptyPayloadObjectDecodesToBlankFieldsRatherThanFailing() throws {
    // The hook falls back to a literal `{}` payload when stdin is empty —
    // this must still produce a valid (if blank) event, not a dropped file.
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"claude-code","event":"permission-required","ts":1755689420,"payload":{}}"#, to: dir)
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.count == 1)
    #expect(events.first?.sessionId == "")
    #expect(events.first?.cwd == "")
    #expect(events.first?.tool == nil)
}

@Test func wireVersionOneIsNoLongerUnderstoodAndIsSkippedNotCrashed() throws {
    // Regression guard for the version bump itself (Fix 6 asks the wire
    // format to stay versioned): an old flat-shaped v1 file — the format the
    // now-removed python one-liners used to write — must be treated as
    // unparseable, the same fail-soft way a corrupt file already is, rather
    // than partially decoded or crashing the watcher.
    let dir = try tempSpool()
    try write(#"{"v":1,"agent":"claude-code","event":"permission-required","session_id":"s1","cwd":"/p","tool":"Bash","summary":"rm -rf x","ts":1755689420}"#, to: dir, name: "aaa-old")
    try write(#"{"v":2,"agent":"opencode","event":"turn-finished","ts":1755689490,"payload":{"session_id":"s3","cwd":"/p"}}"#, to: dir, name: "bbb-good")
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.map(\.sessionId) == ["s3"])
}

@Test func discardsEventsOlderThanTheStalenessWindow() throws {
    let dir = try tempSpool()
    let ancient = Int(now.timeIntervalSince1970) - 3600     // 1h old, window is 600s
    try write(#"{"v":2,"agent":"codex","event":"turn-finished","ts":\#(ancient),"payload":{"session_id":"s2","cwd":"/p"}}"#, to: dir)
    let w = SpoolWatcher(directory: dir)
    #expect(w.drain(now: now).isEmpty, "a stale event must not fire a banner on launch")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty,
            "stale events must still be cleaned up")
}

@Test func skipsCorruptFilesWithoutLosingGoodOnes() throws {
    let dir = try tempSpool()
    try write("this is not json", to: dir, name: "aaa-bad")
    try write(#"{"v":2,"agent":"opencode","event":"turn-finished","ts":1755689490,"payload":{"session_id":"s3","cwd":"/p"}}"#, to: dir, name: "bbb-good")
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.map(\.sessionId) == ["s3"])
}

@Test func returnsEventsInTimestampOrder() throws {
    let dir = try tempSpool()
    try write(#"{"v":2,"agent":"codex","event":"turn-finished","ts":1755689490,"payload":{"session_id":"late","cwd":"/p"}}"#, to: dir, name: "zzz")
    try write(#"{"v":2,"agent":"codex","event":"turn-finished","ts":1755689450,"payload":{"session_id":"early","cwd":"/p"}}"#, to: dir, name: "aaa")
    let events = SpoolWatcher(directory: dir).drain(now: now)
    #expect(events.map(\.sessionId) == ["early", "late"])
}

@Test func missingDirectoryIsNotAnError() {
    let w = SpoolWatcher(directory: URL(fileURLWithPath: "/nope/spool"))
    #expect(w.drain(now: now).isEmpty)
}
