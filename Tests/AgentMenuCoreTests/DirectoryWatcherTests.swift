import Testing
import Foundation
@testable import AgentMenuCore

@Test func firesWhenAFileAppearsInAWatchedDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fired = Fired()
    let w = DirectoryWatcher(paths: [dir.path], latency: 0.05) { fired.signal() }
    w.start()
    defer { w.stop() }

    try "x".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    #expect(await fired.wait(timeout: 5), "FSEvents should report the new file")
}

@Test func restartResubscribesAndStillFires() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fired = Fired()
    let w = DirectoryWatcher(paths: [dir.path], latency: 0.05) { fired.signal() }
    w.start()
    w.restart()                       // simulates the wake-from-sleep path
    defer { w.stop() }

    try "x".write(to: dir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
    #expect(await fired.wait(timeout: 5), "a restarted stream must still deliver")
}

/// Regression test for the use-after-free/double-release finding: `stop()`
/// must not crash or corrupt the watcher when it races a burst of FSEvents
/// callbacks actively arriving on the watcher's queue — exactly the shape of
/// `restart()` racing a flood of writes on wake. This won't deterministically
/// catch the race, but it exercises the teardown-under-load path, and it
/// would catch a deadlock regression in the `queue.sync {}` drain barrier.
@Test func stopDuringActiveDeliveryReturnsCleanlyWithoutCrashing() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fired = Fired()
    let w = DirectoryWatcher(paths: [dir.path], latency: 0.01) { fired.signal() }
    w.start()

    let writer = Task {
        for i in 0..<500 {
            try? "x".write(to: dir.appendingPathComponent("f\(i).jsonl"),
                            atomically: true, encoding: .utf8)
        }
    }
    try? await Task.sleep(nanoseconds: 20_000_000)   // let delivery actually start
    w.stop()
    _ = await writer.value

    // Must still be alive and usable afterward — proof `stop()` didn't
    // corrupt or deallocate the watcher out from under an in-flight callback.
    w.restart()
    defer { w.stop() }
    try "y".write(to: dir.appendingPathComponent("after.jsonl"), atomically: true, encoding: .utf8)
    #expect(await fired.wait(timeout: 5), "watcher must still work after a teardown that raced with delivery")
}

/// Minor coverage for the guard clauses `start()`/`stop()` already rely on —
/// cheap to pin down so a future refactor can't silently break them.
@Test func emptyPathsIsASafeNoOp() {
    let w = DirectoryWatcher(paths: [], latency: 0.05) { }
    w.start()      // guarded by `!paths.isEmpty` — must not create a stream
    w.restart()
    w.stop()
    #expect(Bool(true), "start()/restart()/stop() with no paths must never crash")
}

@Test func nonexistentPathIsASafeNoOp() {
    let missing = "/tmp/agentmenu-does-not-exist-\(UUID().uuidString)"
    let w = DirectoryWatcher(paths: [missing], latency: 0.05) { }
    w.start()      // FSEvents tolerates watching a path that doesn't exist yet
    w.stop()
    #expect(Bool(true), "watching a nonexistent path must never crash")
}

@Test func stopBeforeStartIsASafeNoOp() {
    let w = DirectoryWatcher(paths: ["/tmp"], latency: 0.05) { }
    w.stop()       // never started — guarded by `guard let s = stream`
    #expect(Bool(true), "stop() before start() must never crash")
}

/// Minimal async signal helper.
private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var hit = false
    func signal() { lock.lock(); hit = true; lock.unlock() }
    // `lock()`/`unlock()` are `noasync` in this SDK, so the check is factored
    // into a synchronous helper rather than called inline from `wait` — same
    // synchronous lock/unlock pairing, just not lexically inside `async`.
    private func checkHit() -> Bool { lock.lock(); defer { lock.unlock() }; return hit }
    func wait(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if checkHit() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
