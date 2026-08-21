import AppKit
import SwiftUI
import AgentMenuCore
import AgentMenuUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private lazy var model = AppViewModel(store: store)
    private let notifier = Notifier()
    private var statusController: StatusItemController?
    private var preferencesWindow: NSWindow?

    private var sources: [any AgentSource] = []
    // Round 3 (Ruling F49): kept as concrete-typed references, alongside the
    // generic `sources` array above, purely so `saveCheckpoint` can call
    // their kind-specific `checkpointState(now:)` — that method isn't (and
    // shouldn't be) part of the shared `AgentSource` protocol, since
    // OpencodeSource needs no equivalent at all (it reads a database, not an
    // append-only log) and must stay untouched.
    private var claudeSource: ClaudeCodeSource!
    private var codexSource: CodexSource!
    private var spool: SpoolWatcher!
    private var scanner = ProcessScanner()
    // OpencodeSource already declares its own poll cadence
    // (OpencodeSource.pollInterval), but every tick() — not just its own
    // timer's — reaches the rescan loop below and would otherwise reopen a
    // fresh SQLite connection every time, regardless of what triggered the
    // tick. FSEvents firing from unrelated Claude/Codex activity pushes its
    // real rescan rate well above its declared cadence. Measured directly:
    // removing OpencodeSource's rescan entirely roughly halved steady-state
    // CPU (Task 20 fix report) — capping calls into it to its own declared
    // interval recovers most of that without touching OpencodeSource or
    // OpencodeDatabase (whose SQLITE_OPEN_NOMUTEX connections are not
    // thread-safe, and are deliberately left alone here).
    //
    // Fix 2 / review Ruling F60 REVERSES the note that used to sit here: an
    // earlier pass claimed "a controlled A/B measured zero CPU-time change"
    // from throttling `ProcessScanner.scan()` and reverted it on that basis
    // (round-2 fix report, Finding 4). That measurement was simply wrong —
    // the whole-branch review measured `scan()` directly at 93.9ms/call
    // against a real 541-process table, and with FSEvents ticks previously
    // undebounced (NoDefer + 0.2s latency, admitting ~10 ticks/s), that is
    // up to ~940ms of `ps` per second on the MAIN thread. Do not reintroduce
    // the "no measurable benefit" reasoning; it does not hold. `scan()` is
    // now throttled to `processScanInterval` (spec §2's stated 5s cadence)
    // via `lastProcessScan`/`cachedRunningAgents` below, the same
    // cache-and-reuse shape as opencode's own throttle right below it.
    private var lastProcessScan = Date.distantPast
    private var cachedRunningAgents: [ProcessScanner.RunningAgent] = []
    private static let processScanInterval: TimeInterval = 5
    private var lastOpencodeRescan = Date.distantPast
    private var lastOpencodeSessions: [AgentSession] = []
    // Fix 2 / review Ruling F60: every FSEvents callback from
    // ClaudeCodeSource/CodexSource's DirectoryWatcher used to reach tick()
    // completely undebounced (`DispatchQueue.main.async { tick() }`, no
    // coalescing at all), and the watchers themselves use
    // kFSEventStreamCreateFlagNoDefer with a 0.2s latency specifically so
    // they don't sit on an event — which admits up to ~10 ticks/s during a
    // burst of tool calls, each one forking `scan()` (and, before this
    // fix, reopening opencode's SQLite connection too). `tickScheduled`
    // caps that to at most one tick per `tickDebounceWindow`. The 2s
    // heartbeat and the post-wake tick() in `didWake()` call `tick()`
    // directly and must NEVER be routed through this — see their own call
    // sites — or the app could go quiet for arbitrarily long stretches with
    // nothing else triggering a refresh.
    private var tickScheduled = false
    private static let tickDebounceWindow: TimeInterval = 0.25
    // s.tokens.total/s.cost from a rescanned session are cumulative running
    // totals, not new activity — RollingBurn.record expects "new totals" per
    // its own doc comment (ViewModel.swift). Tracks the last-recorded
    // cumulative figure per session id so only the delta since the previous
    // tick is ever recorded; without this, a session sitting idle re-adds
    // its ENTIRE total again on every 2s heartbeat forever, inflating the
    // header's burn/cost figures without bound within minutes (round-2 fix
    // report, Finding 1 — CRITICAL).
    private var recordedTotals: [String: (tokens: Int, cost: Double)] = [:]
    // Round 2 Fix 2: session ids currently armed-and-not-yet-warned for a
    // context-fill crossing (ContextWarnings' doc comment). In-memory only,
    // like `recordedTotals` above — a relaunch starts fresh rather than
    // persisting across restarts, so this deliberately does not live in
    // `Checkpoint`. That is a real, considered choice, not an oversight: a
    // session already sitting above 80% at the moment of a relaunch (which
    // happens often during active development of this very app) is still
    // useful, actionable information, not a stale repeat — unlike a spool
    // event banner, there is no earlier "this exact banner already fired"
    // fact being re-asserted, just the session's CURRENT fill, which is
    // just as true after a relaunch as before it.
    private var contextWarningsArmed: Set<String> = []
    private var installer: HookInstaller!
    private var timer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private lazy var checkpoints = CheckpointStore(
        url: home.appendingPathComponent(".agentmenu/state.json"))
    private var checkpoint = Checkpoint()
    private var lastCheckpointSave = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Nap would stretch our 2s poll to tens of seconds for a windowless
        // background app — which describes this app exactly (spec §12).
        // Deliberately NOT .idleSystemSleepDisabled: a monitor must not keep the
        // machine awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Monitoring agent sessions")

        // Resume rather than replay: without this, a relaunch re-reads every
        // transcript from byte zero and re-fires banners already shown (§12).
        checkpoint = checkpoints.load()
            .pruned(before: Date().addingTimeInterval(-SpoolWatcher.stalenessWindow))
        notifier.seed(notified: checkpoint.notifiedKeys)

        let pricing = loadPricing()
        spool = SpoolWatcher(directory: home.appendingPathComponent(".agentmenu/events"))
        try? spool.ensureDirectory()

        // Stage the bundled hook scripts before constructing HookInstaller,
        // which writes hook entries pointing at exactly this directory — if
        // the scripts aren't there yet, flipping "Claude Code hooks" on in
        // Preferences registers successfully and then silently does nothing:
        // Claude calls a command that isn't there, gets nothing back, and
        // the permission dot never fires, with no error anywhere (Task 22
        // finding, ship blocker).
        let scriptsDir = home.appendingPathComponent(".agentmenu/bin")
        stageHookScripts(into: scriptsDir)

        installer = HookInstaller(
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            codexConfig: home.appendingPathComponent(".codex/config.toml"),
            scriptsDir: scriptsDir)

        // Round 3 (Ruling F49): each file-based source is seeded with
        // whatever this checkpoint already has for it — the offset AND the
        // accumulator that produced it, never the offset alone. A source
        // whose checkpoint is empty (first-ever launch, or a version bump
        // that discarded everything) just falls back to its existing
        // from-zero behaviour per path, unchanged.
        claudeSource = ClaudeCodeSource(projectsRoot: home.appendingPathComponent(".claude/projects"),
                                        pricing: pricing, checkpoint: checkpoint.claudeTranscripts)
        codexSource = CodexSource(sessionsRoot: home.appendingPathComponent(".codex/sessions"),
                                  pricing: pricing, checkpoint: checkpoint.codexTranscripts)
        sources = [
            claudeSource,
            codexSource,
            OpencodeSource(dbPath: home.appendingPathComponent(
                ".local/share/opencode/opencode.db").path, pricing: pricing),
        ]
        for source in sources {
            // Fix 2: routed through the debounced scheduler, not tick()
            // directly — see tickScheduled's doc comment above.
            source.start { [weak self] in DispatchQueue.main.async { self?.scheduleDebouncedTick() } }
        }

        statusController = StatusItemController(
            model: model,
            onPreferences: { [weak self] in self?.showPreferences() },
            onQuit: { NSApp.terminate(nil) })
        statusController?.install()
        notifier.requestAuthorization()

        // Heartbeat: catches anything FSEvents missed and ages the "stalled"
        // heuristics forward even when nothing is being written. Calls
        // tick() directly — Fix 2's debounce must never apply here, or the
        // app could go quiet for arbitrarily long stretches with nothing
        // else around to trigger a refresh.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        tick()
    }

    /// Closing the popover must never quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Coalesces FSEvents-driven change notifications into at most one
    /// tick() per `tickDebounceWindow` (Fix 2). Deliberately NOT a
    /// cancel-and-reschedule debounce: once a tick is pending it always
    /// fires after the fixed delay regardless of further calls in the
    /// meantime, so a sustained burst of tool calls can never starve it
    /// into firing arbitrarily late — it always lands within
    /// `tickDebounceWindow` of the FIRST change in that window, comfortably
    /// inside the "within a second" permission-latency goal (spec §2).
    /// Callers that must never be delayed (the 2s heartbeat, the post-wake
    /// tick) call `tick()` directly instead of this method.
    private func scheduleDebouncedTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickDebounceWindow) { [weak self] in
            self?.tickScheduled = false
            self?.tick()
        }
    }

    private func tick(now: Date = Date()) {
        // Pull channel. Fix 2 / review Ruling F60: scan() measured at
        // 93.9ms against a real 541-process table; throttled here to
        // processScanInterval (spec §2's 5s cadence) and cached between
        // scans, the same shape as opencode's own rescan throttle just
        // below — a tick that lands inside the window reuses
        // cachedRunningAgents instead of forking `ps`(+`lsof`) again.
        if now.timeIntervalSince(lastProcessScan) >= Self.processScanInterval {
            cachedRunningAgents = scanner.scan()
            lastProcessScan = now
        }
        let running = cachedRunningAgents
        // Bug 1 / Bug 2: tell the store what's actually running so it can
        // release a permission override whose agent process is gone
        // (SessionStore.apply(runningKinds:now:) doc comment) and downgrade
        // a `.working` opencode session left behind when the app quit
        // outright, without waiting on that source's own idle timeout. The
        // store does no scanning itself — this IS the scan, already needed
        // below for pid attribution.
        store.apply(runningKinds: Set(running.map(\.kind)), now: now)
        var liveSessionIds: Set<String> = []
        // Fix 5 / review Ruling F63: which kinds failed to report at all
        // this pass. Baselines belonging to one of these are carried
        // forward untouched below rather than pruned — see BurnBaselines.
        var erroredKinds: Set<AgentKind> = []
        for source in sources {
            var sessions: [AgentSession]
            if source.kind == .opencode,
               now.timeIntervalSince(lastOpencodeRescan) < OpencodeSource.pollInterval {
                sessions = lastOpencodeSessions
            } else {
                sessions = source.rescan(now: now)
                if source.kind == .opencode {
                    lastOpencodeRescan = now
                    lastOpencodeSessions = sessions
                }
            }
            if let error = source.lastError {
                store.markUnavailable(source.kind, reason: error)
                erroredKinds.insert(source.kind)
                continue
            }
            // Attach pids for focus-on-click and liveness. Fix 7 / review
            // Ruling F65: a pid is only ever assigned when it can be
            // attributed to THIS session — its process's working directory
            // (from `ProcessScanner`'s lsof pass) matching `session.directory`
            // — never "the first running process of this kind," which made
            // every row of a kind share one pid and could focus an
            // arbitrary project's window on click. Spec §8: an unmappable
            // row simply isn't clickable; `AppViewModel.focus` already falls
            // back to revealing the transcript when `pid` is nil.
            for i in sessions.indices {
                let dir = sessions[i].directory
                sessions[i].pid = running.first {
                    $0.kind == sessions[i].kind && !dir.isEmpty && $0.directory == dir
                }?.pid
            }
            store.apply(sessions: sessions, kind: source.kind, now: now)
            for s in sessions {
                // KEY MUST BE `id`, NOT `transcriptPath` — do not "helpfully"
                // change this back. `ClaudeCodeSource.rescan` merges every
                // session sharing a `nativeId` (a Claude Code subagent
                // transcript reports its PARENT session's `sessionId`) into
                // exactly one `AgentSession` per tick, so `id` is guaranteed
                // stable and collision-free here (round-3 fix report).
                // `transcriptPath` looks tempting — it used to be the fix,
                // before the merge existed — but a merged group's
                // `transcriptPath` is whichever member is currently NEWEST,
                // recomputed every `rescan()`. Activity moving parent ->
                // subagent -> parent (the normal shape of every Task-tool
                // call) flips that identity, so keying by it drops the prior
                // baseline on every flip and re-records the ENTIRE current
                // merged total as fresh burn — reproduced directly: merged
                // totals 100 -> 120 -> 125 -> 127 across four ticks recorded
                // as 472 (3.7x) instead of the true 127 (round-4 fix report,
                // CRITICAL regression). `id` has no such instability.
                let key = s.id
                liveSessionIds.insert(key)
                // s.tokens.total is cumulative, so record only what's new since
                // the last tick — otherwise an idle session re-adds its whole
                // total on every heartbeat (round-2 fix report, Finding 1).
                // Bug 3: `prior == nil` means first sight of this session, not
                // "zero burn so far" — BurnBaselines.delta seeds the baseline
                // with a zero delta in that case instead of recording the
                // session's entire cumulative lifetime total as if it all
                // happened just now (see its doc comment for the $2424 story).
                let prior = recordedTotals[key]
                let burn = BurnBaselines.delta(current: (s.tokens.total, s.cost ?? 0), prior: prior)
                if burn.tokens > 0 || burn.cost > 0 {
                    model.recordBurn(tokens: burn.tokens, cost: s.cost == nil ? nil : burn.cost,
                                     at: s.lastEventAt)
                }
                recordedTotals[key] = (s.tokens.total, s.cost ?? 0)
            }
        }
        // Bounded the same way the sources evict their own path caches: drop
        // a baseline for any session id not seen this pass, or it grows for
        // the life of the process. Fix 5: EXCEPT for a kind that errored
        // this pass entirely — see BurnBaselines' doc comment for why a
        // transient read error must not wipe baselines it has no fresh
        // evidence against.
        recordedTotals = BurnBaselines.pruned(recordedTotals, liveIds: liveSessionIds,
                                              erroredKinds: erroredKinds)

        // Push channel.
        let events = spool.drain(now: now)
        if !events.isEmpty {
            store.apply(events: events, now: now)
            for e in events { notifier.handle(e, now: now) }
        }

        // Feature 2: fold in any NEW real Claude rate-limit event as an
        // observed ceiling. Scoped to Claude only — the signal
        // (`apiErrorStatus == 429`) and the quota it measures are both
        // Claude-specific. Reads `store.all` fresh rather than
        // `model.sessions` because `model.refresh()` (which sets the
        // latter) has not run yet this tick — `observedCeiling` must be in
        // place BEFORE it does, so `rateLimitFraction` reflects this tick's
        // value rather than lagging one tick behind.
        let claudeSessions = store.all.filter { $0.kind == .claudeCode }
        let claudeBurn5h = claudeSessions.compactMap(\.tokensLast5h).reduce(0) { $0 + $1.total }
        let (ceilings, lastAt) = RateLimitCeiling.recording(
            rateLimitTimestamps: claudeSessions.compactMap(\.lastRateLimitAt), now: now,
            burn5h: claudeBurn5h,
            previous: (checkpoint.observedCeilings, checkpoint.lastRateLimitObservedAt))
        if lastAt != checkpoint.lastRateLimitObservedAt {
            checkpoint.observedCeilings = ceilings
            checkpoint.lastRateLimitObservedAt = lastAt
            saveCheckpoint(now: now)   // rare and important — do not wait for the 30s throttle
        }
        model.observedCeiling = RateLimitCeiling.conservativeCeiling(checkpoint.observedCeilings)

        // Round 2 Fix 3: cheap (three `FileManager.fileExists` calls) and
        // set fresh every tick so a user who starts using a new tool mid-run
        // sees its page auto-appear within one tick, with no relaunch
        // needed — set before `refresh()` so `visibleAgentKinds` (read from
        // `PagedPopoverView` immediately after) is never one tick stale.
        // PERF: the SwiftUI hosting controller stays instantiated even while the
        // popover is closed, so ANY mutation of this @Observable model re-evaluates
        // the whole hidden view tree. Profiling the shipped build with the popover
        // shut put SwiftUICore at the top of the sample and total CPU at ~15.6%,
        // with zero transcript writes in the window. So while hidden we touch the
        // model not at all and drive the status item straight from the store; the
        // full refresh happens on the next tick after it opens, and `togglePopover`
        // already refreshes immediately before showing.
        let popoverVisible = statusController?.isPopoverShown ?? false
        if popoverVisible {
            // Cheap (three `FileManager.fileExists` calls) and set fresh so a user
            // who starts using a new tool sees its page appear without a relaunch.
            // Must precede `refresh()`, which `PagedPopoverView` reads right after.
            model.dataDirectoryPresent = Set(sources.filter { $0.dataDirectoryExists }.map(\.kind))
            model.refresh(now: now)
        }

        // Round 2 Fix 2: warn once per session per crossing of ~80% context
        // fill — crossing detection itself (the "once, and re-arm on a
        // drop" rule) is pure and tested in `ContextWarnings`; this is only
        // the I/O glue that turns a crossing into an actual notification.
        // Reuses `Notifier.notify` directly (its coalescing window and
        // per-agent mute both still apply) rather than `.handle(SpoolEvent)`
        // — this isn't a hook event, it's a computed threshold crossing.
        // Read the store, not the model: these must keep firing while the popover
        // is closed, which is exactly when the model is deliberately not refreshed.
        let storeSessions = store.all
        for s in ContextWarnings.crossed(storeSessions, armed: &contextWarningsArmed) {
            let percent = Int((s.context?.fraction ?? 0) * 100)
            notifier.notify(kind: s.kind,
                            title: "\(s.project) is near its context limit",
                            body: "\(percent)% of context used — consider compacting soon.",
                            key: "\(s.id)/context80", now: now)
        }

        let liveKinds = Array(Set(storeSessions.compactMap { s -> AgentKind? in
            if case .working = s.state { return s.kind } else { return nil }
        })).sorted { $0.rawValue < $1.rawValue }
        statusController?.updateIcon(inferredAttention: store.inferredAttentionCount,
                                     activeKinds: liveKinds,
                                     exactAttentionProjects: storeSessions.exactAttentionProjects)

        // Throttled: this runs every 2s, but the checkpoint only needs to be
        // durable enough that a crash loses seconds, not history.
        if now.timeIntervalSince(lastCheckpointSave) > 30 {
            saveCheckpoint(now: now)
            lastCheckpointSave = now
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveCheckpoint(now: Date())
    }

    private func saveCheckpoint(now: Date) {
        checkpoint.notifiedKeys = notifier.notifiedKeys
        let cutoff = now.addingTimeInterval(-SpoolWatcher.stalenessWindow)
        checkpoint = checkpoint.pruned(before: cutoff)
        // Amendment: Notifier.lastSent otherwise grows one entry per unique key
        // for the process lifetime; prune uses the same staleness cutoff as the
        // checkpoint itself so both agree on what "too old to matter" means.
        notifier.prune(before: cutoff)
        // Round 3 (Ruling F49): refresh every transcript's accumulator +
        // offset + validity stamp on every save (throttled to 30s / on
        // terminate, same as everything else here) so the NEXT launch can
        // resume instead of replaying. `checkpointSnapshot` inside each
        // source already trims what doesn't need to survive the round trip,
        // so this stays cheap even for a chatty session.
        checkpoint.claudeTranscripts = claudeSource.checkpointState(now: now)
        checkpoint.codexTranscripts = codexSource.checkpointState(now: now)
        try? checkpoints.save(checkpoint)
    }

    /// FSEvents does not reliably deliver events from during sleep, so streams
    /// are rebuilt and everything is re-read (spec §12).
    @objc private func didWake() {
        // A fast user-switch (sessionDidBecomeActiveNotification) can land
        // inside the opencode throttle window even though this is exactly
        // the path required to force a full rescan — reset it so the very
        // next tick() is never suppressed (round-2 fix report, Finding 3).
        // Fix 2's process-scan throttle gets the same treatment for the same
        // reason: waking is exactly when the process table is most likely to
        // have genuinely changed, so a stale cached scan must never win here.
        lastOpencodeRescan = .distantPast
        lastProcessScan = .distantPast
        for source in sources { source.restart() }
        tick()
    }

    private func showPreferences() {
        if preferencesWindow == nil {
            // Height bumped for Round 2 Fix 3's new "SHOW AGENTS" section
            // (a label, three toggles, and an explanatory line). Not
            // `.resizable`, so this has to fit the content up front rather
            // than relying on the user dragging it taller.
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 470),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AgentMenu Preferences"
            w.contentViewController = NSHostingController(
                rootView: PreferencesView(installer: installer, notifier: notifier))
            w.isReleasedWhenClosed = false
            w.center()
            preferencesWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    private func loadPricing() -> PricingTable {
        if let url = Bundle.main.url(forResource: "pricing", withExtension: "json"),
           let table = try? PricingTable.load(from: url) { return table }
        // Running from .build/ during development — fall back to the repo copy.
        let dev = URL(fileURLWithPath: "Resources/pricing.json")
        return (try? PricingTable.load(from: dev)) ?? PricingTable(models: [:])
    }

    /// Copies every bundled `.sh` hook script into `~/.agentmenu/bin`, the
    /// directory `HookInstaller` writes hook commands pointing at. Without
    /// this, the scripts exist only inside the bundle
    /// (`Contents/Resources/Scripts/`) and never reach the path the
    /// installed hooks actually invoke — Task 22's live verification hit
    /// exactly this: hooks register cleanly, then do nothing, forever,
    /// with no error surfaced anywhere.
    ///
    /// Overwritten unconditionally on every launch so an app update
    /// refreshes a stale script instead of leaving an old one in place.
    /// Every step is `try?` — staging failure must degrade to "hooks don't
    /// work," never to "the app doesn't launch."
    private func stageHookScripts(into dir: URL) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Scripts")
        let items = bundled.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        // Running from .build/ during development has no bundle Scripts
        // directory at all — fall back to the repo copy, the same way
        // loadPricing() already does for pricing.json, so this is testable
        // outside a real .app bundle.
        ?? (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "Scripts"), includingPropertiesForKeys: nil))
        guard let items else { return }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in items where item.pathExtension == "sh" {
            let dest = dir.appendingPathComponent(item.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: item, to: dest)) != nil else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu-bar only, no Dock icon
app.run()
