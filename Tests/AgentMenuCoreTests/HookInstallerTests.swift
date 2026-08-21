import Testing
import Foundation
@testable import AgentMenuCore

private func scratch() throws -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("inst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let existingSettings = """
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]}
    ]
  }
}
"""

private let existingConfig = """
model = "gpt-5"
notify = ["/Users/n/.codex/computer-use/SkyComputerUseClient", "turn-ended"]
approval_policy = "on-request"
"""

private func makeInstaller(_ dir: URL) throws -> (HookInstaller, URL, URL) {
    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
    try existingConfig.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    return (HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts),
            settings, config)
}

private func json(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

// Fix 1 / review Ruling F59 (the worst defect in the whole-branch review):
// PreToolUse fires before EVERY tool call, not only when the agent is
// genuinely blocked on approval, so an agentmenu entry there painted a solid
// red row and fired a false "needs permission" banner for routine tool use.
// The old version of this test actually asserted the BUG — that our own
// command ended up inside the PreToolUse group — which is exactly backwards.
@Test func installingClaudeHooksLeavesPreToolUseUntouchedAndAddsNotificationAndStop() throws {
    let (inst, settings, _) = try makeInstaller(try scratch())
    try inst.installClaude()

    let hooks = try #require(try json(settings)["hooks"] as? [String: Any])

    // PreToolUse must contain ONLY the user's pre-existing guard — no
    // agentmenu entry, ever.
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    let preCommands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    #expect(preCommands == ["/usr/local/bin/my-guard"],
            "PreToolUse must be left exactly as the user had it — no agentmenu entry, ever")
    #expect(!pre.contains { ($0["_agentmenu"] as? Bool) == true },
            "no group in PreToolUse may be tagged as ours")

    // The real permission signal (Notification) and turn-finished (Stop)
    // carry AgentMenu's hook instead.
    let notification = try #require(hooks["Notification"] as? [[String: Any]])
    let notificationCommands = notification.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    #expect(notificationCommands.contains { $0.contains("agentmenu-hook") })

    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    let stopCommands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    #expect(stopCommands.contains { $0.contains("agentmenu-hook") })

    // Unrelated settings untouched.
    #expect(try json(settings)["model"] as? String == "opus")
}

@Test func installingTwiceAddsNothingTheSecondTime() throws {
    let (inst, settings, _) = try makeInstaller(try scratch())
    try inst.installClaude()
    let after1 = try Data(contentsOf: settings)
    try inst.installClaude()
    #expect(try Data(contentsOf: settings) == after1, "install must be idempotent")
}

@Test func uninstallRestoresTheOriginalExactly() throws {
    let (inst, settings, _) = try makeInstaller(try scratch())
    let before = try json(settings)
    try inst.installClaude()
    try inst.uninstallClaude()
    let after = try json(settings)
    let preAfter = ((after["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]) ?? []
    let cmds = preAfter.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    #expect(cmds == ["/usr/local/bin/my-guard"])
    #expect(after["model"] as? String == before["model"] as? String)
    #expect((after["hooks"] as? [String: Any])?["Notification"] == nil)
}

@Test func codexShimCapturesAndForwardsToTheExistingNotifyProgram() throws {
    let dir = try scratch()
    let (inst, _, config) = try makeInstaller(dir)
    try inst.installCodex()

    let toml = try String(contentsOf: config, encoding: .utf8)
    #expect(toml.contains("codex-notify-shim"), "notify must now point at the shim")
    #expect(toml.contains("approval_policy = \"on-request\""), "other config must survive")

    let shim = try String(contentsOf: dir.appendingPathComponent("scripts/codex-notify-shim.sh"),
                          encoding: .utf8)
    #expect(shim.contains("/Users/n/.codex/computer-use/SkyComputerUseClient"),
            "the original notify program must be baked into the shim, not lost")
    #expect(shim.contains("turn-ended"))
}

@Test func uninstallingCodexRestoresTheOriginalNotifyLine() throws {
    let (inst, _, config) = try makeInstaller(try scratch())
    try inst.installCodex()
    try inst.uninstallCodex()
    let toml = try String(contentsOf: config, encoding: .utf8)
    #expect(toml.contains("SkyComputerUseClient"))
    #expect(!toml.contains("codex-notify-shim"))
}

@Test func aBackupIsWrittenBeforeAnyEdit() throws {
    let dir = try scratch()
    let (inst, settings, _) = try makeInstaller(dir)
    try inst.installClaude()
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("settings.json.agentmenu-backup") }
    #expect(backups.count == 1)
    #expect(try String(contentsOf: settings.deletingLastPathComponent()
        .appendingPathComponent(backups[0]), encoding: .utf8).contains("my-guard"))
}

@Test func statusReportsWhatIsActuallyInstalled() throws {
    let (inst, _, _) = try makeInstaller(try scratch())
    let initial = inst.status()
    #expect(initial == (claude: false, codex: false, codexOverridden: false))
    try inst.installClaude()
    #expect(inst.status().claude)
}

// MARK: - Additions beyond the brief's 7

// The brief's own `existingConfig` fixture uses a notify path with no spaces
// in it. Ground truth on the real machine this installer will run on is:
// notify = ["/Users/nisarganag/.codex/computer-use/Codex Computer Use.app/
//            Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/
//            SkyComputerUseClient", "turn-ended"]
// — a path containing spaces from the .app bundle name. This is the real
// case the task flagged as needing explicit verification, not a hypothetical.
private let spacedNotifyConfig = """
model = "gpt-5"
notify = ["/Users/n/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]
approval_policy = "on-request"
"""

@Test func codexShimHandlesANotifyProgramPathContainingSpaces() throws {
    let dir = try scratch()
    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
    try spacedNotifyConfig.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let inst = HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts)

    try inst.installCodex()
    let shim = try String(contentsOf: scripts.appendingPathComponent("codex-notify-shim.sh"),
                          encoding: .utf8)
    #expect(shim.contains(
        "/Users/n/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"),
        "the full path, spaces included, must be baked into the shim")

    try inst.uninstallCodex()
    let toml = try String(contentsOf: config, encoding: .utf8)
    #expect(toml.contains(
        "notify = [\"/Users/n/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient\", \"turn-ended\"]"),
        "uninstall must restore the exact original notify line, spaces included")
}

// Real ~/.claude/settings.json files accumulate keys (e.g. under "env") in
// whatever order features were enabled over time, not alphabetical order.
// Round-tripping the WHOLE document through JSONSerialization with
// .sortedKeys (as a naive parse-modify-reserialize would) silently resorts
// every section, including ones this installer has no business touching.
// Verified directly against the real ~/.claude/settings.json on the machine
// this ships on, whose "env" block is not alphabetically ordered.
private let settingsWithUnsortedEnv = """
{
  "model": "opus",
  "env": {
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOGS_EXPORTER": "otlp"
  },
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]}
    ]
  }
}
"""

@Test func installPreservesUnrelatedObjectsKeyOrderAndFormatting() throws {
    let dir = try scratch()
    let settings = dir.appendingPathComponent("settings.json")
    try settingsWithUnsortedEnv.write(to: settings, atomically: true, encoding: .utf8)
    let config = dir.appendingPathComponent("config.toml")
    try existingConfig.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let inst = HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts)

    try inst.installClaude()

    let text = try String(contentsOf: settings, encoding: .utf8)
    let intervalRange = try #require(text.range(of: "OTEL_LOGS_EXPORT_INTERVAL\""))
    let exporterRange = try #require(text.range(of: "OTEL_LOGS_EXPORTER\""))
    #expect(intervalRange.lowerBound < exporterRange.lowerBound,
            "env's own (non-alphabetical) key order must survive untouched")
}

@Test func installingCodexTwiceIsIdempotent() throws {
    let (inst, _, config) = try makeInstaller(try scratch())
    try inst.installCodex()
    let after1 = try Data(contentsOf: config)
    try inst.installCodex()
    #expect(try Data(contentsOf: config) == after1, "codex install must be idempotent")

    let backups = try FileManager.default.contentsOfDirectory(
        atPath: config.deletingLastPathComponent().path)
        .filter { $0.hasPrefix("config.toml.agentmenu-backup") }
    #expect(backups.count == 1, "a second install must not write a second backup")
}

private let settingsWithNoHooksKey = """
{
  "model": "opus",
  "theme": "dark"
}
"""

@Test func installingIntoSettingsWithNoExistingHooksKeyProducesValidJSON() throws {
    let dir = try scratch()
    let settings = dir.appendingPathComponent("settings.json")
    try settingsWithNoHooksKey.write(to: settings, atomically: true, encoding: .utf8)
    let config = dir.appendingPathComponent("config.toml")
    try existingConfig.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let inst = HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts)

    try inst.installClaude()

    let root = try json(settings)
    #expect(root["model"] as? String == "opus")
    #expect(root["theme"] as? String == "dark")
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(hooks["Notification"] != nil)
    #expect(hooks["Stop"] != nil)
    // Fix 1: a fresh settings file with no pre-existing PreToolUse group
    // must not gain one from scratch — AgentMenu never installs there.
    #expect(hooks["PreToolUse"] == nil)
}

// MARK: - Regressions for reviewer Findings 1 & 2 (parseNotify / notifyLineRange)
//
// The original parseNotify filtered array elements by content (dropping any
// element containing the substring "notify") and only ever returned the
// first two elements. notifyLineRange matched any line with prefix "notify",
// including unrelated keys like notify_on_error. Both are wrong: verified by
// actually running the old code against each case below before fixing it.

private func makeCodexInstaller(_ dir: URL, configText: String) throws -> (HookInstaller, URL) {
    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
    try configText.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    return (HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts), config)
}

@Test func notifyProgramPathContainingTheSubstringNotifyIsNotDropped() throws {
    let configText = """
    model = "gpt-5"
    notify = ["/usr/local/bin/notify-forwarder", "turn-ended"]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    let originalBytes = try Data(contentsOf: config)

    try inst.installCodex()
    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let shim = try String(contentsOf: scripts.appendingPathComponent("codex-notify-shim.sh"), encoding: .utf8)
    #expect(shim.contains("FORWARD_TO=\"/usr/local/bin/notify-forwarder\""),
            "a program path containing the substring 'notify' must survive intact")
    #expect(shim.contains("FORWARD_ARG_1=\"turn-ended\""))

    try inst.uninstallCodex()
    #expect(try Data(contentsOf: config) == originalBytes,
            "uninstall must restore the exact original bytes")
}

@Test func notifyArrayWithNoSpaceAfterCommaKeepsBothElements() throws {
    let configText = """
    model = "gpt-5"
    notify = ["prog","arg"]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    let originalBytes = try Data(contentsOf: config)

    try inst.installCodex()
    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let shim = try String(contentsOf: scripts.appendingPathComponent("codex-notify-shim.sh"), encoding: .utf8)
    #expect(shim.contains("FORWARD_TO=\"prog\""))
    #expect(shim.contains("FORWARD_ARG_1=\"arg\""), "the real argument must not be lost as a bare comma")

    try inst.uninstallCodex()
    #expect(try Data(contentsOf: config) == originalBytes,
            "uninstall must restore the exact original bytes, unusual spacing included")
}

@Test func notifyArrayWithThreeElementsKeepsAllOfThem() throws {
    let configText = """
    model = "gpt-5"
    notify = ["prog", "arg1", "arg2"]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    let originalBytes = try Data(contentsOf: config)

    try inst.installCodex()
    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let shim = try String(contentsOf: scripts.appendingPathComponent("codex-notify-shim.sh"), encoding: .utf8)
    #expect(shim.contains("FORWARD_TO=\"prog\""))
    #expect(shim.contains("FORWARD_ARG_1=\"arg1\""))
    #expect(shim.contains("FORWARD_ARG_2=\"arg2\""), "nothing past index 1 may be silently dropped")

    try inst.uninstallCodex()
    #expect(try Data(contentsOf: config) == originalBytes)
}

@Test func notifyOnErrorLineAboveTheRealNotifyLineIsNotMatchedInstead() throws {
    let configText = """
    model = "gpt-5"
    notify_on_error = true
    notify = ["real-program", "turn-ended"]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    let originalBytes = try Data(contentsOf: config)

    try inst.installCodex()
    let toml = try String(contentsOf: config, encoding: .utf8)
    #expect(toml.contains("notify_on_error = true"), "an unrelated key must survive untouched")
    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let shim = try String(contentsOf: scripts.appendingPathComponent("codex-notify-shim.sh"), encoding: .utf8)
    #expect(shim.contains("FORWARD_TO=\"real-program\""),
            "notify_on_error must not be mistaken for the real notify key")

    try inst.uninstallCodex()
    #expect(try Data(contentsOf: config) == originalBytes)
}

// MARK: - Round-3 review findings: mangled backup blob, multi-line arrays

@Test func uninstallRefusesAMangledOriginalLineBlobRatherThanWritingGarbage() throws {
    let configText = """
    model = "gpt-5"
    notify = ["prog", "arg"]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    try inst.installCodex()
    let afterInstall = try Data(contentsOf: config)

    // Simulate a user hand-editing the shim (a plain, human-readable shell
    // script by design): the stored blob still decodes fine as base64/UTF-8,
    // but the result isn't a notify assignment at all.
    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let shimURL = scripts.appendingPathComponent("codex-notify-shim.sh")
    let mangledB64 = Data("this is not a notify line at all".utf8).base64EncodedString()
    var lines = try String(contentsOf: shimURL, encoding: .utf8).components(separatedBy: "\n")
    for i in lines.indices where lines[i].hasPrefix("ORIGINAL_NOTIFY_LINE_B64=") {
        lines[i] = "ORIGINAL_NOTIFY_LINE_B64=\"\(mangledB64)\""
    }
    try lines.joined(separator: "\n").write(to: shimURL, atomically: true, encoding: .utf8)

    #expect(throws: HookInstaller.Error.self) { try inst.uninstallCodex() }
    #expect(try Data(contentsOf: config) == afterInstall,
            "a mangled backup must never be spliced into config.toml")
}

@Test func installRefusesAMultiLineNotifyArrayRatherThanCorruptingTheConfig() throws {
    let configText = """
    model = "gpt-5"
    notify = [
        "prog",
        "arg"
    ]
    approval_policy = "on-request"
    """
    let (inst, config) = try makeCodexInstaller(try scratch(), configText: configText)
    let originalBytes = try Data(contentsOf: config)

    #expect(throws: HookInstaller.Error.self) { try inst.installCodex() }
    #expect(try Data(contentsOf: config) == originalBytes,
            "a multi-line notify array must be left completely untouched, not partially rewritten")

    let scripts = config.deletingLastPathComponent().appendingPathComponent("scripts")
    let backups = try FileManager.default.contentsOfDirectory(
        atPath: config.deletingLastPathComponent().path)
        .filter { $0.hasPrefix("config.toml.agentmenu-backup") }
    #expect(backups.isEmpty, "a refused install must not write a backup either")
    #expect(FileManager.default.fileExists(
        atPath: scripts.appendingPathComponent("codex-notify-shim.sh").path) == false,
        "a refused install must not generate a shim either")
}

// MARK: - Fix 6: no python3 dependency in the generated shim

// /usr/bin/python3 is a stub that never runs on a Mac without Xcode Command
// Line Tools installed — exactly the machine a DMG gets handed to. The shim
// must not depend on it at all, and must set the spool directory to 0700
// itself (Fix 7) rather than trust whoever created it first.
@Test func generatedCodexShimHasNoPython3DependencyAndSecuresTheSpoolDirectory() throws {
    let (inst, _, config) = try makeInstaller(try scratch())
    try inst.installCodex()

    let shim = try String(contentsOf: config.deletingLastPathComponent()
        .appendingPathComponent("scripts/codex-notify-shim.sh"), encoding: .utf8)
    #expect(shim.contains("python3") == false, "the shim must not shell out to python3 at all")
    #expect(shim.contains("chmod 700"), "the shim must secure the spool directory itself")
    #expect(shim.contains("\"v\":2"), "the shim must write the current (v2) envelope wire format")
}

// MARK: - Verification requirement #4: exercised against literal /tmp copies
//
// Every other test in this file uses FileManager's per-process temporary
// directory, which is already disposable and never touches a real agent
// config. This test additionally pins its scratch files under literal
// `/tmp`, matching the task's own verification wording, and is the direct
// regression test for Fix 1: the installed plan must never contain a
// PreToolUse entry of ours, and a pre-existing user guard must survive
// untouched.

@Test func installAgainstLiteralTmpCopiesNeverAddsPreToolUseAndPreservesTheUsersGuard() throws {
    let dir = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("agentmenu-fix-verify-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
    try existingConfig.write(to: config, atomically: true, encoding: .utf8)
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let inst = HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts)

    try inst.installClaude()

    let hooks = try #require(try json(settings)["hooks"] as? [String: Any])
    let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(pre.contains { ($0["_agentmenu"] as? Bool) == true } == false,
            "the plan must not contain a PreToolUse entry of ours")
    let preCommands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    #expect(preCommands == ["/usr/local/bin/my-guard"],
            "the user's own pre-existing PreToolUse guard must survive untouched")
    #expect(hooks["Notification"] != nil)
    #expect(hooks["Stop"] != nil)
}

// MARK: - Bugfix round 3, Bug A: Claude Code strips the `_agentmenu` marker
//
// Observed on the real machine: Claude Code owns and periodically rewrites
// settings.json, and normalises entries as it goes — including silently
// dropping the unknown `_agentmenu` key AgentMenu relies on. Before this
// fix, that made installClaude's idempotency check
// (`groups.contains { marker == true }`) blind to its own prior entries,
// so the next install appended an unbounded duplicate; and it made
// uninstallClaude, which matched the same way, unable to remove them at
// all. Fixed by recognising an entry as ours if EITHER the marker survives
// OR the hook script's filename appears in one of its command strings
// (`HookInstaller.isOurGroup`), and by self-healing: install now collapses
// any number of "ours" entries down to exactly one per event instead of
// only ever appending. Every test below runs against a literal `/tmp`
// fixture, matching the task's own verification wording.

private func tmpScratch(_ label: String) throws -> URL {
    let d = URL(fileURLWithPath: "/tmp").appendingPathComponent("agentmenu-bugfix3-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func preToolUseCommands(_ root: [String: Any]) -> [String] {
    let pre = (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
    return pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
}

private func groupCommands(_ root: [String: Any], event: String) -> [String] {
    let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
}

/// A settings.json shaped exactly like the real post-Claude-Code-rewrite
/// state: `notificationCopies` Notification groups and `stopCopies` Stop
/// groups, ALL missing the `_agentmenu` marker (simulating Claude Code
/// having stripped it) but still carrying the real hook script command —
/// plus the user's own untagged PreToolUse guard, which every test below
/// must find completely untouched afterward.
private func markerStrippedSettingsJSON(hookScript: String, notificationCopies: Int, stopCopies: Int) -> String {
    func group(_ arg: String) -> String {
        #"{"matcher": "", "hooks": [{"type": "command", "command": "\#(hookScript) \#(arg)"}]}"#
    }
    let notifications = Array(repeating: group("permission-required"), count: notificationCopies).joined(separator: ",\n      ")
    let stops = Array(repeating: group("turn-finished"), count: stopCopies).joined(separator: ",\n      ")
    return """
    {
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]}
        ],
        "Notification": [
          \(notifications)
        ],
        "Stop": [
          \(stops)
        ]
      }
    }
    """
}

/// Builds `(installer, settingsURL, dir)` under a literal `/tmp` scratch
/// directory (not `FileManager`'s per-process temporary directory, which on
/// macOS resolves under `/var/folders/...`, not `/tmp`) — matching the
/// task's explicit "each against a /tmp fixture" wording — with a
/// marker-stripped settings.json already containing `notificationCopies`/
/// `stopCopies` duplicate AgentMenu entries plus the user's own untagged
/// PreToolUse guard. `scriptsDir`/the hook script path are created FIRST so
/// the fixture's embedded command actually points at this instance's real
/// hook script, exactly as a genuine prior install would have left it.
private func makeMarkerStrippedTmpInstaller(_ label: String, notificationCopies: Int, stopCopies: Int)
    throws -> (HookInstaller, URL, URL)
{
    let dir = try tmpScratch(label)
    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let hookScript = scripts.appendingPathComponent("agentmenu-hook.sh").path

    try markerStrippedSettingsJSON(hookScript: hookScript, notificationCopies: notificationCopies, stopCopies: stopCopies)
        .write(to: settings, atomically: true, encoding: .utf8)
    try existingConfig.write(to: config, atomically: true, encoding: .utf8)

    return (HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts), settings, dir)
}

// Required test 1: a config whose AgentMenu entries have had `_agentmenu`
// stripped -> install does not add a duplicate.
@Test func installDoesNotDuplicateWhenClaudeCodeHasStrippedTheMarker() throws {
    let (inst, settings, dir) = try makeMarkerStrippedTmpInstaller(
        "strip-install", notificationCopies: 1, stopCopies: 1)
    defer { try? FileManager.default.removeItem(at: dir) }

    try inst.installClaude()

    let root = try json(settings)
    #expect(groupCommands(root, event: "Notification").count == 1,
            "a marker-stripped entry must be recognised as ours, not duplicated")
    #expect(groupCommands(root, event: "Stop").count == 1,
            "a marker-stripped entry must be recognised as ours, not duplicated")
    #expect(preToolUseCommands(root) == ["/usr/local/bin/my-guard"],
            "the user's own untagged PreToolUse guard must survive untouched")
}

// Required test 2: that same config -> uninstall DOES remove them
// (previously impossible once the marker was gone).
@Test func uninstallRemovesEntriesEvenAfterClaudeCodeHasStrippedTheMarker() throws {
    let (inst, settings, dir) = try makeMarkerStrippedTmpInstaller(
        "strip-uninstall", notificationCopies: 1, stopCopies: 1)
    defer { try? FileManager.default.removeItem(at: dir) }

    try inst.uninstallClaude()

    let root = try json(settings)
    #expect(groupCommands(root, event: "Notification").isEmpty,
            "uninstall must remove marker-stripped entries — this was previously impossible")
    #expect(groupCommands(root, event: "Stop").isEmpty,
            "uninstall must remove marker-stripped entries — this was previously impossible")
    #expect(preToolUseCommands(root) == ["/usr/local/bin/my-guard"],
            "the user's own untagged PreToolUse guard must survive untouched")
}

// Required test 3: a config with three duplicate copies -> install
// collapses to exactly one.
@Test func installCollapsesThreeDuplicateCopiesToExactlyOne() throws {
    let (inst, settings, dir) = try makeMarkerStrippedTmpInstaller(
        "collapse", notificationCopies: 3, stopCopies: 3)
    defer { try? FileManager.default.removeItem(at: dir) }

    try inst.installClaude()

    let root = try json(settings)
    let notificationCommands = groupCommands(root, event: "Notification")
    let stopCommands = groupCommands(root, event: "Stop")
    #expect(notificationCommands.count == 1, "three duplicate copies must collapse to exactly one")
    #expect(stopCommands.count == 1, "three duplicate copies must collapse to exactly one")
    #expect(preToolUseCommands(root) == ["/usr/local/bin/my-guard"],
            "the user's own untagged PreToolUse guard must survive untouched")

    // Having collapsed to one, a second install must now be a true no-op.
    let after1 = try Data(contentsOf: settings)
    try inst.installClaude()
    #expect(try Data(contentsOf: settings) == after1, "once collapsed to one, install is idempotent again")
}

// Required test 4 (non-negotiable): the user's own untagged PreToolUse
// guard survives ALL of the above, untouched, at every step of the worst
// observed sequence: a three-duplicate marker-stripped mess -> install
// (collapse) -> install again (no-op) -> uninstall.
@Test func theUsersOwnPreToolUseGuardSurvivesStripDuplicateAndUninstallUntouched() throws {
    let (inst, settings, dir) = try makeMarkerStrippedTmpInstaller(
        "guard-survives", notificationCopies: 3, stopCopies: 3)
    defer { try? FileManager.default.removeItem(at: dir) }

    func assertGuardIntact(_ when: String) throws {
        #expect(preToolUseCommands(try json(settings)) == ["/usr/local/bin/my-guard"],
                "the user's own PreToolUse guard must never be touched (\(when))")
    }

    try assertGuardIntact("initial fixture")
    try inst.installClaude()
    try assertGuardIntact("after install (collapse)")
    try inst.installClaude()
    try assertGuardIntact("after a second, idempotent install")
    try inst.uninstallClaude()
    try assertGuardIntact("after uninstall")
}

// MARK: - Bugfix round 3, Bug B: Codex reclaims `notify`, status() lied about it
//
// Observed on the real machine: after AgentMenu pointed `notify` at its
// shim, Codex's own Computer Use component rewrote the line — reclaiming
// the program slot for itself and demoting AgentMenu's shim path to a
// trailing `--previous-notify` argument it never executes. The shim was
// therefore completely dead (Codex push notifications silently stopped),
// but the old `status()` checked `toml.contains("codex-notify-shim")`,
// which stays true because the path substring survives inside that
// argument — so Preferences kept showing the Codex toggle ON and
// "working" when it was neither. Fixed by requiring the shim be genuinely
// element 0 of the `notify` array (`HookInstaller.notifyIsGenuinelyOurShim`),
// and by adding `codexOverridden` so the UI can tell "reclaimed" apart from
// "never installed" instead of collapsing both to a flat "off".

/// Verbatim (program path filled in) reproduction of the line found on the
/// real machine after Codex's Computer Use component reclaimed `notify`.
private let reclaimedNotifyLine =
    #"notify = ["/Users/nisarganag/.codex/computer-use/SkyComputerUseClient", "turn-ended", "--previous-notify", "[\"\\/Users\\/nisarganag\\/.agentmenu\\/bin\\/codex-notify-shim.sh\"]"]"#

private let reclaimedConfig = """
model = "gpt-5"
\(reclaimedNotifyLine)
approval_policy = "on-request"
"""

// NOTE ON ASSERTION STYLE: this project's bundled swift-testing version
// (0.99.0, per `swift test`'s own banner) does not correctly evaluate
// `#expect(boolExpr == true)` / `#expect(boolExpr == false)` — verified with
// a standalone throwaway diagnostic that it silently records NO failure
// regardless of the operand's actual value (e.g. `let v = true; #expect(v ==
// false)` "passes"). Bare boolean conditions (`#expect(x)` / `#expect(!x)`)
// and tuple/Int/Array/Data equality all DO correctly fail on a mismatch
// (also verified directly). Every assertion below therefore either compares
// the whole `status()` 3-tuple at once (which also gives a precise
// actual-vs-expected message on failure) or uses a bare/negated condition —
// never a direct `== true`/`== false` against a plain Bool.

// Required test 1: the exact reclaimed line from the bug report -> status()
// reports not installed / overridden, not installed.
@Test func statusReportsNotInstalledAndOverriddenForTheExactReclaimedLine() throws {
    let dir = try tmpScratch("reclaimed-status")
    defer { try? FileManager.default.removeItem(at: dir) }
    let settings = dir.appendingPathComponent("settings.json")
    let config = dir.appendingPathComponent("config.toml")
    let scripts = dir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
    try reclaimedConfig.write(to: config, atomically: true, encoding: .utf8)
    let inst = HookInstaller(claudeSettings: settings, codexConfig: config, scriptsDir: scripts)

    #expect(inst.status() == (claude: false, codex: false, codexOverridden: true),
            "the shim is not genuinely active (Codex's own program runs from slot 0, not ours), and that must be distinguishable from never-installed")
}

// Required test 2: a genuine install -> status() reports installed.
@Test func statusReportsInstalledForAGenuineInstall() throws {
    let dir = try tmpScratch("genuine-status")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (inst, _, _) = try makeInstaller(dir)
    try inst.installCodex()

    #expect(inst.status() == (claude: false, codex: true, codexOverridden: false))
}

// Required test 3: uninstall against the reclaimed shape -> does not
// corrupt the line. Stronger than the minimum ask: also proves the restore
// is the TRUE pre-AgentMenu original captured at the genuine install, not
// anything derived from the reclaimed text itself.
@Test func uninstallAgainstTheReclaimedShapeDoesNotCorruptTheLine() throws {
    let dir = try tmpScratch("reclaimed-uninstall")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (inst, _, config) = try makeInstaller(dir)

    // A genuine install first, so a real shim file exists on disk holding
    // the TRUE original notify line (existingConfig's), base64-encoded.
    try inst.installCodex()

    // Simulate Codex reclaiming the slot: overwrite ONLY the notify line in
    // config.toml with the exact reclaimed shape, exactly as Codex's own
    // rewrite would — the shim file AgentMenu already wrote is left as-is.
    let beforeReclaim = try String(contentsOf: config, encoding: .utf8)
    let range = try #require(HookInstaller.notifyLineRange(in: beforeReclaim))
    let reclaimed = beforeReclaim.replacingCharacters(in: range, with: reclaimedNotifyLine)
    try reclaimed.write(to: config, atomically: true, encoding: .utf8)

    // status() must now show overridden, not active — the fix under test.
    #expect(inst.status() == (claude: false, codex: false, codexOverridden: true))

    try inst.uninstallCodex()

    let restored = try String(contentsOf: config, encoding: .utf8)
    #expect(restored.contains(
        "notify = [\"/Users/n/.codex/computer-use/SkyComputerUseClient\", \"turn-ended\"]"),
        "must restore the TRUE original notify line captured at the genuine install")
    #expect(!restored.contains("codex-notify-shim"),
            "the reclaimed line's embedded reference to our shim must not survive into the restored line")
    #expect(restored.contains("approval_policy = \"on-request\""), "unrelated config must survive untouched")
}
