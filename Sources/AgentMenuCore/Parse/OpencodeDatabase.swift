import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only reader for opencode's SQLite store.
///
/// Opened READONLY with a busy timeout: the DB is in WAL mode and opencode
/// writes to it constantly, so a lock is a retry, not an error. The app must
/// never write here (spec: never mutate an agent's session state).
public final class OpencodeDatabase: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable {
        case cannotOpen(String)
        case queryFailed(String)
    }

    /// No activity for this long and the session is treated as finished.
    public static let idleThreshold: TimeInterval = 120

    /// A pending tool `part` is a durable database row — opencode never
    /// rewrites it once a turn is abandoned, so it persists forever whether
    /// or not anyone is actually waiting on it. Real sessions on this machine
    /// carry a pending part up to 99+ days after they went stale. Only trust
    /// it as a LIVE signal if the session itself was touched within this
    /// window; 600s (not `idleThreshold`'s 120s) is deliberate — a human
    /// genuinely sitting on a prompt for a few minutes must still show red,
    /// and the closest real false positive found was 6.6 *days* old, so
    /// there is enormous margin either way. (A later task can tighten this
    /// with process liveness; this layer can't see processes.)
    public static let permissionFreshness: TimeInterval = 600

    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Error.cannotOpen(msg)
        }
        sqlite3_busy_timeout(handle, 2000)
        self.db = handle
    }

    deinit { sqlite3_close(db) }

    public func sessions(since: Date, now: Date) throws -> [AgentSession] {
        let cutoffMs = Int64(max(0, since.timeIntervalSince1970) * 1000)
        let sql = """
        SELECT id, title, directory, model, cost, tokens_input, tokens_output,
               tokens_reasoning, tokens_cache_read, tokens_cache_write,
               time_created, time_updated
        FROM session
        WHERE time_updated >= ? AND time_archived IS NULL
        ORDER BY time_updated DESC LIMIT 50;
        """
        // `time_archived` may not exist on older schemas; fall back if so.
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            stmt = nil
            let fallback = sql.replacingOccurrences(of: " AND time_archived IS NULL", with: "")
            guard sqlite3_prepare_v2(db, fallback, -1, &stmt, nil) == SQLITE_OK else {
                throw Error.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)

        var out: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0) else { continue }
            let dir = text(stmt, 2) ?? ""
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11)) / 1000)
            let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10)) / 1000)

            let tokens = TokenStats(
                input: Int(sqlite3_column_int64(stmt, 5)),
                output: Int(sqlite3_column_int64(stmt, 6)),
                cacheRead: Int(sqlite3_column_int64(stmt, 8)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 9)),
                reasoning: Int(sqlite3_column_int64(stmt, 7)))

            let (activity, pendingTool) = latestPart(sessionId: id, at: updated)

            // NOTE: `session.permission` is deliberately NOT treated as a live
            // "awaiting a decision right now" signal. On the real DB on this
            // machine it holds a *stored auto-deny policy* attached to
            // subagent sessions (e.g. `[{"permission":"todowrite","action":
            // "deny","pattern":"*"}]`), present even on sessions that finished
            // over 100 days ago — using it as a trigger produced false
            // positives. The only authoritative live signal is a pending tool
            // `part`, which opencode does genuinely record (hence `.exact`) —
            // but that row is ALSO durable (see `permissionFreshness` above),
            // so it only counts while the session is still fresh; a stale
            // pending part falls through to the done/working/idle checks
            // below like any other session.
            let age = now.timeIntervalSince(updated)
            let state: SessionState
            if let tool = pendingTool, age <= Self.permissionFreshness {
                state = .awaitingPermission(
                    PermissionRequest(tool: tool, summary: activity?.line ?? "", since: updated),
                    confidence: .exact)          // opencode records this; Codex cannot
            } else if age > Self.idleThreshold {
                state = .done(at: updated)
            } else if let activity {
                state = .working(activity)
            } else {
                state = .idle
            }

            out.append(AgentSession(
                kind: .opencode,
                nativeId: id,
                project: dir.isEmpty ? (text(stmt, 1) ?? "—") : (dir as NSString).lastPathComponent,
                directory: dir,
                branch: nil,
                model: modelId(from: text(stmt, 3)),
                state: state,
                lastActivity: activity,
                tokens: tokens,
                // Fix 7: this used to be aspirational — nothing actually
                // filled it in, so opencode never got a context meter even
                // though pricing.json ships a contextWindow for its models.
                // OpencodeSource.enrich now does this fill (window from
                // PricingTable, used = tokens.total) right after this call.
                context: nil,
                cost: sqlite3_column_double(stmt, 4),
                startedAt: created,
                lastEventAt: updated))
        }
        return out
    }

    /// Newest meaningful part for a session, plus the tool name if one is pending.
    private func latestPart(sessionId: String, at: Date) -> (Activity?, String?) {
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM part WHERE session_id = ? ORDER BY time_created DESC LIMIT 20;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        var activity: Activity?
        var pending: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = text(stmt, 0),
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                            as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "text":
                if activity == nil,
                   let t = (obj["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    activity = Activity(body: .message(t), at: at)
                }
            case "tool":
                let name = obj["tool"] as? String ?? "tool"
                if activity == nil {
                    // Only the NEWEST part may signal a live permission. An
                    // older pending row is an abandoned turn opencode never
                    // rewrote, not a live prompt — a genuine permission
                    // request is always the newest part. (Previously this
                    // check ran unconditionally and could resurrect a stale
                    // pending tool from under an unrelated newer message.)
                    let status = (obj["state"] as? [String: Any])?["status"] as? String
                    if status == "pending" || status == "running-permission" { pending = name }
                    activity = Activity(body: .tool(name: name, summary: ""), at: at)
                }
            default: continue
            }
            if activity != nil { break }
        }
        return (activity, pending)
    }

    /// `model` is stored as a JSON blob; the UI wants just the id.
    private func modelId(from blob: String?) -> String? {
        guard let blob else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(blob.utf8))
                        as? [String: Any] else { return blob }
        return obj["id"] as? String ?? blob
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}

/// Without this, an unreadable-but-present DB (permissions, a lock the
/// busy timeout still couldn't ride out, a corrupt file) reached the UI as
/// `String(describing:)`'s raw enum-case dump — literally
/// `cannotOpen("unable to open database file")` in a status row — rather
/// than a message meant to be read by a person (Fix 4 / review Ruling F62).
/// `OpencodeSource.rescan` relies on this via `error.localizedDescription`,
/// which Foundation routes to `errorDescription` automatically for any
/// `LocalizedError`, so no call site needs to know about this type specifically.
extension OpencodeDatabase.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let reason):
            return "opencode: couldn't open the database (\(reason))"
        case .queryFailed(let reason):
            return "opencode: query failed (\(reason))"
        }
    }
}
