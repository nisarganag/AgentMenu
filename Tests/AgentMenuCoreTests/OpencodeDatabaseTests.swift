import Testing
import Foundation
import SQLite3
@testable import AgentMenuCore

private let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a throwaway DB with the real opencode schema shape.
private func makeDB(_ rows: [(id: String, title: String, dir: String, cost: Double,
                              updated: Int, permission: String?)],
                    parts: [(session: String, data: String, created: Int)]) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("oc-\(UUID().uuidString).db").path
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let schema = """
    CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT,
      title TEXT, permission TEXT, time_created INTEGER, time_updated INTEGER,
      agent TEXT, model TEXT, cost REAL DEFAULT 0, tokens_input INTEGER DEFAULT 0,
      tokens_output INTEGER DEFAULT 0, tokens_reasoning INTEGER DEFAULT 0,
      tokens_cache_read INTEGER DEFAULT 0, tokens_cache_write INTEGER DEFAULT 0);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
      time_created INTEGER, time_updated INTEGER, data TEXT);
    """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    for r in rows {
        let sql = """
        INSERT INTO session (id,title,directory,cost,time_created,time_updated,agent,model,
          tokens_input,tokens_output,tokens_cache_read,tokens_cache_write,permission)
        VALUES ('\(r.id)','\(r.title)','\(r.dir)',\(r.cost),\(r.updated - 1000),\(r.updated),
          'build','{"id":"kimi-k3","providerID":"moonshotai"}',38115,13431,900,100,
          \(r.permission.map { "'\($0)'" } ?? "NULL"));
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    for (i, p) in parts.enumerated() {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO part (id,message_id,session_id,time_created,time_updated,data) VALUES (?,?,?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, "p\(i)", -1, SQLITE_TRANSIENT_TEST)
        sqlite3_bind_text(stmt, 2, "m\(i)", -1, SQLITE_TRANSIENT_TEST)
        sqlite3_bind_text(stmt, 3, p.session, -1, SQLITE_TRANSIENT_TEST)
        sqlite3_bind_int64(stmt, 4, Int64(p.created))
        sqlite3_bind_int64(stmt, 5, Int64(p.created))
        sqlite3_bind_text(stmt, 6, p.data, -1, SQLITE_TRANSIENT_TEST)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
    }
    return path
}

private let t0 = 1_755_600_000_000   // ms

@Test func readsSessionTelemetryIncludingNativeCost() throws {
    let path = try makeDB(
        [(id: "s1", title: "Greeting", dir: "/Users/x/lucid-ui", cost: 0.452,
          updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"text","text":"Both files are in your Java folder"}"#,
                 created: t0)])
    let db = try OpencodeDatabase(path: path)
    let s = try #require(db.sessions(since: .distantPast,
                                     now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    #expect(s.kind == .opencode)
    #expect(s.nativeId == "s1")
    #expect(s.project == "lucid-ui")
    #expect(s.model == "kimi-k3")           // extracted from the JSON blob
    #expect(s.cost == 0.452)                // native, not computed
    #expect(s.tokens.input == 38_115)
    #expect(s.tokens.cacheRead == 900)
    #expect(s.lastActivity?.line == "Both files are in your Java folder")
}

@Test func pendingToolPartMeansExactPermission() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"tool","tool":"bash","state":{"status":"pending"}}"#,
                 created: t0)])
    let db = try OpencodeDatabase(path: path)
    let s = try #require(db.sessions(since: .distantPast,
                                     now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    guard case .awaitingPermission(let req, let confidence) = s.state else {
        Issue.record("expected permission, got \(s.state)"); return
    }
    // opencode DOES record this, unlike Codex.
    #expect(confidence == .exact)
    #expect(req.tool == "bash")
}

@Test func completedToolPartIsWorkingNotBlocked() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"tool","tool":"bash","state":{"status":"completed"}}"#,
                 created: t0)])
    let db = try OpencodeDatabase(path: path)
    let s = try #require(db.sessions(since: .distantPast,
                                     now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    guard case .working = s.state else { Issue.record("got \(s.state)"); return }
}

@Test func staleSessionIsDoneNotWorking() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"text","text":"finished"}"#, created: t0)])
    let db = try OpencodeDatabase(path: path)
    let hourLater = Date(timeIntervalSince1970: Double(t0) / 1000 + 3600)
    let s = try #require(db.sessions(since: .distantPast, now: hourLater).first)
    guard case .done = s.state else { Issue.record("got \(s.state)"); return }
}

@Test func missingDatabaseThrowsRatherThanCrashing() {
    #expect(throws: (any Error).self) { try OpencodeDatabase(path: "/nope/missing.db") }
}

// Real opencode data on this machine shows `session.permission` holding a
// *stored auto-deny policy* (e.g. subagents spawned with todowrite/task
// denied), not a live "awaiting a decision right now" flag — confirmed via
// `sqlite3 -readonly ~/.local/share/opencode/opencode.db` against sessions
// that finished long ago yet still carry a non-null `permission` value.
// A session carrying that column must not be forced into
// `.awaitingPermission` on that basis alone; only a pending tool `part` may
// do that (see `pendingToolPartMeansExactPermission` above).
@Test func storedPermissionPolicyDoesNotForceAwaitingPermission() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0,
          permission: #"[{"permission":"todowrite","action":"deny","pattern":"*"}]"#)],
        parts: [(session: "s1", data: #"{"type":"text","text":"done exploring"}"#, created: t0)])
    let db = try OpencodeDatabase(path: path)
    let s = try #require(db.sessions(since: .distantPast,
                                     now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    guard case .working = s.state else { Issue.record("got \(s.state)"); return }
}

// A pending tool `part` is a durable database row — opencode never rewrites
// it once a turn is abandoned — so it is NOT by itself a live "awaiting a
// decision right now" signal. Real data on this machine has seven sessions,
// the oldest 99.2 days stale, that still carry a pending tool part; without
// a freshness gate every one of them would show a permanently-unclearable
// "needs permission" indicator, which is worse than showing nothing.
@Test func stalePendingToolResolvesToDoneNotAwaitingPermission() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"tool","tool":"bash","state":{"status":"pending"}}"#,
                 created: t0)])
    let db = try OpencodeDatabase(path: path)
    let hourLater = Date(timeIntervalSince1970: Double(t0) / 1000 + 3600)
    let s = try #require(db.sessions(since: .distantPast, now: hourLater).first)
    guard case .done = s.state else { Issue.record("got \(s.state)"); return }
}

// A pending tool part inside the freshness window still means a real,
// currently-blocked permission request — even at an age (5 min) that already
// exceeds `idleThreshold` (2 min), proving permission correctly takes
// priority over plain idleness as long as the session was touched recently.
@Test func freshPendingToolWithinWindowStillMeansExactPermission() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"tool","tool":"bash","state":{"status":"pending"}}"#,
                 created: t0)])
    let db = try OpencodeDatabase(path: path)
    let fiveMinutesLater = Date(timeIntervalSince1970: Double(t0) / 1000 + 300)
    let s = try #require(db.sessions(since: .distantPast, now: fiveMinutesLater).first)
    guard case .awaitingPermission(let req, let confidence) = s.state else {
        Issue.record("expected permission, got \(s.state)"); return
    }
    #expect(confidence == .exact)
    #expect(req.tool == "bash")
}

// Only the NEWEST part may signal a live permission. An abandoned tool call
// from an earlier turn (pending, never rewritten) must not resurface as
// `.awaitingPermission` just because the user later resumed the same session
// with unrelated work — even though the session's own `time_updated` is
// recent enough to pass `permissionFreshness`. All 8 prior tests use a
// single part per session, so this scan-order interaction was never caught.
@Test func onlyNewestPartCanSignalPendingPermission() throws {
    let recentUpdate = t0 + 200_000   // 200s after the abandoned tool call
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0, updated: recentUpdate, permission: nil)],
        parts: [
            (session: "s1", data: #"{"type":"tool","tool":"bash","state":{"status":"pending"}}"#,
             created: t0),
            (session: "s1", data: #"{"type":"text","text":"unrelated follow-up message"}"#,
             created: recentUpdate),
        ])
    let db = try OpencodeDatabase(path: path)
    let now = Date(timeIntervalSince1970: Double(recentUpdate) / 1000 + 10)
    let s = try #require(db.sessions(since: .distantPast, now: now).first)
    guard case .working = s.state else { Issue.record("got \(s.state)"); return }
}

// MARK: - OpencodeSource: Fix 4 (missing-DB guard) and Fix 7 (context meter)

// Review Ruling F62: most users installing this app do not run opencode at
// all, so a missing DB is the COMMON case, not a failure — it must render
// exactly like "never used this agent," mirroring
// ClaudeCodeSource/CodexSource's own root-absent guard, rather than a
// permanent amber "source unavailable" row.
@Test func opencodeSourceTreatsAMissingDatabaseAsNoSessionsRatherThanAnError() {
    let source = OpencodeSource(dbPath: "/nope/opencode.db",
                                pricing: PricingTable(models: [:]))
    let sessions = source.rescan(now: Date())
    #expect(sessions.isEmpty)
    #expect(source.lastError == nil,
            "an absent DB must read as 'no sessions', not a surfaced error")
}

// A DB that EXISTS but cannot actually be opened (corrupt, wrong format) is
// a real failure and must still surface — just not as
// `String(describing:)`'s raw Swift enum-case dump, which is debug syntax,
// not a message meant to be read by a person.
@Test func opencodeSourceSurfacesAHumanReadableErrorForAnUnopenableButPresentDatabase() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("oc-garbage-\(UUID().uuidString).db").path
    try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))

    let source = OpencodeSource(dbPath: path, pricing: PricingTable(models: [:]))
    let sessions = source.rescan(now: Date())
    #expect(sessions.isEmpty)
    let message = try #require(source.lastError, "an existing-but-unopenable DB must surface an error")
    #expect(message.contains("cannotOpen(") == false,
            "must never leak the raw Swift enum-case dump into the UI")
    #expect(message.contains("opencode"), "the message should say which source failed")
}

// Fix 7 / review Ruling F65: `OpencodeDatabase` leaves `context` nil and
// documents that the SOURCE fills it in from a price table — but no
// `PricingTable` ever reached `OpencodeSource` until this fix, so opencode
// rows never got a context meter even though pricing.json ships a
// `contextWindow` for both of opencode's models. `makeDB` hardcodes the
// model blob to kimi-k3 with tokens_input=38115, tokens_output=13431,
// tokens_cache_read=900, tokens_cache_write=100 — total 52,546.
@Test func opencodeSourceFillsContextFromThePriceTablesWindowAndTheSessionsTokenTotal() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0.1, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"text","text":"hi"}"#, created: t0)])
    let pricing = try PricingTable.decode(#"{"models":{"kimi-k3":{"contextWindow":500000}}}"#
        .data(using: .utf8)!)
    let source = OpencodeSource(dbPath: path, pricing: pricing)
    let s = try #require(source.rescan(now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    #expect(s.tokens.total == 52_546)
    #expect(s.context?.window == 500_000, "the window must come from the price table")
    #expect(s.context?.used == 52_546, "used is the session's cumulative token total")
}

@Test func opencodeSourceLeavesContextNilForAModelAbsentFromThePriceTable() throws {
    let path = try makeDB(
        [(id: "s1", title: "t", dir: "/p", cost: 0.1, updated: t0, permission: nil)],
        parts: [(session: "s1", data: #"{"type":"text","text":"hi"}"#, created: t0)])
    let source = OpencodeSource(dbPath: path, pricing: PricingTable(models: [:]))
    let s = try #require(source.rescan(now: Date(timeIntervalSince1970: Double(t0) / 1000)).first)
    #expect(s.context == nil, "no known window means no meter, never a fake one")
}
