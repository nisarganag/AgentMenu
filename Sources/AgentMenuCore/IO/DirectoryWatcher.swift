import Foundation
import CoreServices

/// FSEvents wrapper over one or more directory trees.
///
/// `restart()` is required, not a convenience: FSEvents does not reliably
/// deliver events that occurred while the system was asleep, so the app tears
/// down and re-creates its streams on wake (spec §12).
///
/// `stream` is guarded by `lock` rather than left to `@unchecked Sendable`
/// good faith. The FSEvents context below holds only an
/// `Unmanaged.passUnretained(self)` reference with no retain/release, so two
/// hazards are otherwise live: (1) `start()`/`stop()`/`restart()` racing from
/// different threads could both observe the same non-nil `stream` and
/// double-`FSEventStreamRelease` it, and (2) tearing down while a callback is
/// already executing on `queue` could deallocate `self` out from under that
/// callback — `FSEventStreamInvalidate` only guarantees no *new* callbacks,
/// it does not wait for one already in flight to finish. `stop()` closes
/// both: the lock makes the read-and-nil of `stream` atomic, and the
/// `queue.sync {}` barrier after invalidation blocks until any in-flight
/// callback has returned before `stop()` (and therefore `deinit`) can
/// proceed.
public final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "agentmenu.fsevents")

    public init(paths: [String], latency: TimeInterval = 0.2,
                onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagNoDefer)) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Not safe to call synchronously from `onChange`: `onChange` runs on
    /// `queue`, and the `queue.sync {}` barrier below would deadlock waiting
    /// for a queue it is already executing on. The real consumer only ever
    /// dispatches elsewhere from `onChange` and never calls back into `stop()`
    /// on the same turn — that invariant must hold.
    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }

        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)   // no NEW callbacks after this
        FSEventStreamRelease(s)

        // Invalidate does not block on a callback already running. Draining
        // the callback queue does: once this returns, no callback can still
        // be holding the unretained `self` pointer, so it is safe for ARC to
        // deallocate us.
        queue.sync { }
    }

    public func restart() {
        stop()
        start()
    }
}
