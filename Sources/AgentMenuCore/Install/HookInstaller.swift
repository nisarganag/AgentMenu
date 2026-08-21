import Foundation

/// Installs and removes AgentMenu's hooks in the agents' own config files.
///
/// Every entry AgentMenu adds is tagged `_agentmenu: true` so uninstall can
/// identify exactly what was added and nothing else — but the marker alone
/// is not trusted, because it isn't ours to keep. Claude Code itself owns
/// and periodically rewrites `settings.json` (observed directly: it
/// normalises entries and has stripped the unknown `_agentmenu` key from
/// ones AgentMenu wrote). `isOurGroup` below therefore also recognises an
/// entry by the hook script's filename appearing in its command string —
/// a signal Claude Code has no reason to touch — so a marker-stripped
/// entry is still found by `installClaude` (preventing an unbounded
/// duplicate) and by `uninstallClaude` (which would otherwise be unable to
/// remove it at all). Either signal is sufficient on its own. Every edit is
/// backed up (once, timestamped) before the first byte changes. Every write
/// goes to a temp file and is renamed into place, so a crash mid-write
/// cannot corrupt a config the user's agents depend on to run at all.
///
/// The Claude side never reserializes the whole settings file through
/// `JSONSerialization`. `settings.json` can carry large, independently
/// maintained sections — env vars, permission lists, plugin toggles — whose
/// key order is *not* alphabetical in practice (verified directly against a
/// real `~/.claude/settings.json`, whose `env` block accumulated out of
/// alphabetical order). A parse → mutate → reserialize round trip with
/// `.sortedKeys` would silently resort every one of those sections. Instead,
/// only the text span of the top-level `"hooks"` value is replaced (see
/// `replacingTopLevelValue`): every byte *outside* that span — every other
/// key, in whatever order and formatting the user already had — is left
/// exactly as it was. Content *inside* the `"hooks"` span, including
/// pre-existing hook entries that survive an install or uninstall
/// unchanged in value, is re-serialized through `JSONSerialization` and so
/// is only guaranteed semantically equivalent, not byte-identical (its
/// keys come back alphabetised, for one). The Codex side avoids even that:
/// it never parses+reserializes at all, just a text replace of the single
/// `notify` line, so everything Codex-side — the replaced line included,
/// restored verbatim on uninstall — is byte-identical.
public struct HookInstaller: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unreadable(String)
        case malformed(String)
        /// The config's `notify` array is valid TOML this installer
        /// deliberately refuses to wrap (currently: an array that spans
        /// multiple lines) rather than risk corrupting it.
        case unsupportedNotifyFormat(String)
    }

    static let marker = "_agentmenu"

    /// Filename-only, not the full current `scriptsDir`-qualified path — an
    /// entry written by an earlier install (potentially from a different
    /// `scriptsDir`, e.g. the app relocated) must still be recognised as
    /// ours by `isOurGroup`, so matching is a *substring* against this
    /// stable filename rather than exact equality against `hookScript`.
    static let hookScriptFilename = "agentmenu-hook.sh"

    let claudeSettings: URL
    let codexConfig: URL
    let scriptsDir: URL

    public init(claudeSettings: URL, codexConfig: URL, scriptsDir: URL) {
        self.claudeSettings = claudeSettings
        self.codexConfig = codexConfig
        self.scriptsDir = scriptsDir
    }

    private var hookScript: String { scriptsDir.appendingPathComponent(Self.hookScriptFilename).path }
    private var shimScript: String { scriptsDir.appendingPathComponent("codex-notify-shim.sh").path }

    // MARK: - Claude

    public func installClaude() throws {
        let text = readText(claudeSettings)
        let root = try Self.parseObject(text, source: claudeSettings.path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Notification → permission required; Stop → turn finished.
        //
        // PreToolUse is deliberately NOT claimed here (Fix 1 / review Ruling
        // F59, the worst defect found in the whole-branch review). PreToolUse
        // fires before EVERY tool call, not only when the agent is actually
        // blocked waiting on approval — a routine `ls` would spool a
        // `permission-required` event exactly like a real prompt, painting
        // the row solid red and the menu bar badge red, and firing a "needs
        // permission" banner every `Notifier.coalesceWindow` seconds while
        // Claude works normally. `Notification` is the real, exact signal
        // Claude only sends when it is genuinely waiting on the user.
        // Nothing is lost by leaving PreToolUse alone: the row's activity
        // line already shows the current tool from the transcript (pull
        // channel), and any pre-existing PreToolUse guard the user already
        // has installed (e.g. a command-blocking hook) is left completely
        // untouched rather than merged alongside an entry of ours.
        let plan: [(String, String)] = [
            ("Notification", "permission-required"),
            ("Stop",         "turn-finished"),
        ]
        var changed = false
        for (event, arg) in plan {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let oursCount = groups.filter(Self.isOurGroup).count
            if oursCount == 1 { continue }         // exactly one of ours already: untouched, stays idempotent
            // 0 -> append a fresh entry. >1 -> Claude Code (or a prior
            // marker-stripped install) left duplicates behind; self-heal by
            // collapsing them to exactly one rather than appending a third.
            groups.removeAll(where: Self.isOurGroup)
            groups.append([
                Self.marker: true,
                "matcher": "",
                "hooks": [["type": "command", "command": "\(hookScript) \(arg)"]],
            ])
            hooks[event] = groups
            changed = true
        }
        guard changed else { return }              // idempotent: no write, no new backup

        try backup(claudeSettings)
        let newText = try Self.replacingTopLevelValue("hooks", with: hooks, in: text)
        try atomicWrite(newText, to: claudeSettings)
    }

    public func uninstallClaude() throws {
        let text = readText(claudeSettings)
        let root = try Self.parseObject(text, source: claudeSettings.path)
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        var changed = false
        for event in hooks.keys {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            let before = groups.count
            groups.removeAll(where: Self.isOurGroup)
            if groups.count != before { changed = true }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        guard changed else { return }               // nothing of ours found; leave the file untouched

        let newText = try Self.replacingTopLevelValue("hooks", with: hooks, in: text)
        try atomicWrite(newText, to: claudeSettings)
    }

    /// True if `group` is one AgentMenu itself created. Checks the
    /// `_agentmenu` marker first, but does not stop there: Claude Code owns
    /// `settings.json` and has been observed silently stripping unknown keys
    /// (including this one) while rewriting entries it manages, which would
    /// otherwise orphan AgentMenu's own hook group — invisible to both the
    /// idempotency check (so a re-install appends an unbounded duplicate)
    /// and to `uninstallClaude` (so it could never be removed again). The
    /// second, independent signal is the hook script's filename appearing in
    /// any of the group's command strings — something Claude Code has no
    /// reason to rewrite. Either signal alone is sufficient.
    private static func isOurGroup(_ group: [String: Any]) -> Bool {
        if (group[marker] as? Bool) == true { return true }
        let commands = (group["hooks"] as? [[String: Any]])?
            .compactMap { $0["command"] as? String } ?? []
        return commands.contains { $0.contains(hookScriptFilename) }
    }

    // MARK: - Codex

    public func installCodex() throws {
        guard let toml = try? String(contentsOf: codexConfig, encoding: .utf8) else {
            throw Error.unreadable(codexConfig.path)
        }
        // Genuinely active only, not merely "our shim path appears
        // somewhere in the file" — Codex's Computer Use component has been
        // observed to reclaim this slot for its own program and preserve
        // whatever it displaced (including our shim path) as a trailing
        // argument. A broader substring match would treat that reclaimed,
        // inert state as "already installed" and silently no-op forever,
        // so a user who notices via `status()` and tries to re-enable the
        // toggle could never actually recover. See `notifyIsGenuinelyOurShim`.
        if Self.notifyIsGenuinelyOurShim(toml) { return }        // idempotent

        // A `notify = [...]` array that spans multiple lines is valid TOML,
        // but replacing just its opening line (as the single-line splice
        // below does) would orphan the continuation lines and leave
        // config.toml syntactically broken — refuse rather than corrupt.
        if Self.notifyLineOpensAMultiLineArray(in: toml) {
            throw Error.unsupportedNotifyFormat(
                "notify = [...] spans multiple lines; refusing to wrap it rather than risk corrupting config.toml")
        }

        let originalLine = Self.notifyLineRange(in: toml).map { String(toml[$0]) }
        let elements = Self.parseNotify(toml)
        try writeShim(forwardTo: elements, originalLine: originalLine)
        try backup(codexConfig)

        let line = "notify = [\"\(shimScript)\"]"
        let updated: String
        if let range = Self.notifyLineRange(in: toml) {
            updated = toml.replacingCharacters(in: range, with: line)
        } else {
            updated = toml + "\n" + line + "\n"
        }
        try atomicWrite(updated, to: codexConfig)
    }

    /// Also correctly handles the "reclaimed" shape: if Codex has since
    /// rewritten `notify` to point at its own program (preserving whatever
    /// it displaced, including our shim path, as a trailing argument — see
    /// `notifyIsGenuinelyOurShim`), the top guard below still fires (the
    /// shim path substring is still present on the line), and `original` is
    /// still read from THIS installer's own shim file on disk — untouched
    /// by whatever Codex did to config.toml — so the restore below replaces
    /// whatever the *current* `notify` line is (reclaimed or not) with the
    /// user's true original, never something derived from the reclaimed
    /// text. If the shim is missing or its blob doesn't decode to a notify
    /// assignment, this leaves the line alone rather than guess.
    public func uninstallCodex() throws {
        guard let toml = try? String(contentsOf: codexConfig, encoding: .utf8),
              toml.contains("codex-notify-shim") else { return }   // idempotent: nothing to undo
        guard let shim = try? String(contentsOf: scriptsDir.appendingPathComponent("codex-notify-shim.sh"),
                                     encoding: .utf8) else { return }
        // The shim carries the user's exact original `notify = [...]` line,
        // base64-encoded, so it can be restored byte-for-byte regardless of
        // whatever spacing/quoting style the user originally had — rather
        // than reconstructed from parsed pieces, which would risk
        // normalising unusual formatting instead of truly restoring it.
        guard let b64 = Self.value(of: "ORIGINAL_NOTIFY_LINE_B64", in: shim),
              let data = Data(base64Encoded: b64),
              let original = String(data: data, encoding: .utf8),
              !original.isEmpty,
              let range = Self.notifyLineRange(in: toml) else { return }

        // The shim is a plain, commented, human-readable shell script by
        // design, so someone opening and hand-editing this value isn't
        // far-fetched. Refuse to splice back anything that doesn't actually
        // look like a notify assignment, rather than trusting a decodable
        // blob just because it decoded.
        guard Self.isNotifyKeyLine(original) else {
            throw Error.malformed(
                "codex-notify-shim.sh: ORIGINAL_NOTIFY_LINE_B64 does not decode to a notify assignment")
        }
        try atomicWrite(toml.replacingCharacters(in: range, with: original), to: codexConfig)
    }

    /// `codex` is true only when the shim is *genuinely* the program Codex
    /// invokes (see `notifyIsGenuinelyOurShim`) — not merely detectable
    /// somewhere in the file. `codexOverridden` distinguishes "Codex
    /// reclaimed the slot" from "never installed": both report `codex ==
    /// false`, but only the reclaimed case reports `codexOverridden ==
    /// true`, so the UI can tell the user the truth instead of a flat "off"
    /// that looks identical to having never turned it on.
    public func status() -> (claude: Bool, codex: Bool, codexOverridden: Bool) {
        let root = (try? Self.parseObject(readText(claudeSettings), source: claudeSettings.path)) ?? [:]
        let claude = (root["hooks"] as? [String: Any])?
            .values.contains { groups in
                (groups as? [[String: Any]])?.contains(where: Self.isOurGroup) ?? false
            } ?? false

        let toml = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        let codexActive = Self.notifyIsGenuinelyOurShim(toml)
        let notifyLine = Self.notifyLineRange(in: toml).map { String(toml[$0]) } ?? ""
        let codexOverridden = !codexActive && notifyLine.contains("codex-notify-shim")
        return (claude, codexActive, codexOverridden)
    }

    // MARK: - Codex TOML helpers

    /// True only if the notify array's *program* slot — element 0, the one
    /// Codex actually executes — is our shim. A prior version of `status()`
    /// (and `installCodex`'s idempotency guard) checked `toml.contains(
    /// "codex-notify-shim")` anywhere in the file, which stays true even
    /// after Codex's Computer Use component reclaims the slot for its own
    /// program and demotes our shim to a trailing argument it is never
    /// executed from — so the old check kept reporting "installed and
    /// working" for a shim that had gone silently dead. Scoped to `.first`
    /// so an appearance anywhere else (an argument, a comment) does not
    /// count.
    static func notifyIsGenuinelyOurShim(_ toml: String) -> Bool {
        parseNotify(toml).first?.contains("codex-notify-shim") ?? false
    }

    /// All elements of `notify = ["a", "b", ...]`, in the order they appear.
    ///
    /// A prior version split the line on `"` and then dropped any element
    /// whose *content* contained the substring "notify" — which silently
    /// discarded a real program path like `.../notify-forwarder`, and only
    /// ever kept the first two elements, losing anything past index 1. This
    /// instead locates the `[...]` span on the matched line and scans it
    /// properly as a string array, so every element survives regardless of
    /// its content, spacing around commas, or how many there are.
    static func parseNotify(_ toml: String) -> [String] {
        guard let range = notifyLineRange(in: toml) else { return [] }
        let line = String(toml[range])
        guard let open = line.firstIndex(of: "["),
              let close = matchingCloseBracket(afterOpenBracketAt: open, in: line) else { return [] }
        return parseQuotedArrayElements(line[line.index(after: open)..<close])
    }

    /// True if the matched `notify = [...]` line opens a bracket that does
    /// not close again before the line ends — i.e. a multi-line array.
    /// `installCodex` refuses to wrap this rather than risk corrupting the
    /// file (see its call site).
    static func notifyLineOpensAMultiLineArray(in toml: String) -> Bool {
        guard let range = notifyLineRange(in: toml) else { return false }
        let line = String(toml[range])
        guard let open = line.firstIndex(of: "[") else { return false }
        return matchingCloseBracket(afterOpenBracketAt: open, in: line) == nil
    }

    /// Index of the `]` that matches the `[` at `open`, scanning only
    /// within `line` (never past its end) and skipping over quoted string
    /// content (honouring `\"`/`\\` escapes). Returns nil if the array
    /// doesn't close within this line — a multi-line array, or a line with
    /// a bracket but no closing one at all.
    ///
    /// Scanning for the true *matching* bracket rather than the line's last
    /// `]` (a previous version's approach) also means a trailing same-line
    /// comment containing its own stray `]` — `notify = ["a","b"] # see [x]`
    /// — can no longer be mistaken for part of the array: this stops at the
    /// first bracket that actually closes the one just opened and never
    /// looks further right.
    private static func matchingCloseBracket(afterOpenBracketAt open: String.Index,
                                              in line: String) -> String.Index? {
        var i = line.index(after: open)
        var depth = 1
        while i < line.endIndex {
            switch line[i] {
            case "\"":
                i = line.index(after: i)
                while i < line.endIndex, line[i] != "\"" {
                    if line[i] == "\\", line.index(after: i) < line.endIndex {
                        i = line.index(i, offsetBy: 2)
                    } else {
                        i = line.index(after: i)
                    }
                }
                guard i < line.endIndex else { return nil }   // unterminated string on this line
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return i }
            default:
                break
            }
            i = line.index(after: i)
        }
        return nil
    }

    /// Scans the interior of a `[...]` bracket for `"`-delimited elements,
    /// honouring `\"` and `\\` escapes, and returns every element found in
    /// order — regardless of whitespace around the separating commas.
    private static func parseQuotedArrayElements(_ s: Substring) -> [String] {
        var elements: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "\"" else { i = s.index(after: i); continue }
            i = s.index(after: i)                  // past the opening quote
            var value = ""
            while i < s.endIndex, s[i] != "\"" {
                if s[i] == "\\", s.index(after: i) < s.endIndex {
                    let escaped = s[s.index(after: i)]
                    value.append(escaped == "n" ? "\n" : escaped == "t" ? "\t" : escaped)
                    i = s.index(i, offsetBy: 2)
                } else {
                    value.append(s[i])
                    i = s.index(after: i)
                }
            }
            elements.append(value)
            if i < s.endIndex { i = s.index(after: i) }   // past the closing quote
        }
        return elements
    }

    /// Range of the `notify = [...]` line. Requires the key itself — after
    /// trimming, `notify` followed only by optional whitespace and then
    /// `=` — so a similarly-prefixed but unrelated key (`notify_on_error`,
    /// a hypothetical `notifyX`) is never matched instead of the real one.
    static func notifyLineRange(in toml: String) -> Range<String.Index>? {
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false)
        where isNotifyKeyLine(String(line)) {
            if let r = toml.range(of: String(line)) { return r }
        }
        return nil
    }

    /// Whether `line`, once trimmed, is actually an assignment to the
    /// `notify` key — `notify` followed only by optional whitespace and
    /// then `=` — rather than a similarly-prefixed but unrelated key
    /// (`notify_on_error`, a hypothetical `notifyX`). Shared by
    /// `notifyLineRange` (to find the real line) and `uninstallCodex` (to
    /// refuse to restore a hand-edited backup that no longer looks like a
    /// notify assignment at all).
    private static func isNotifyKeyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("notify") else { return false }
        let afterKey = trimmed.dropFirst("notify".count).drop { $0 == " " || $0 == "\t" }
        return afterKey.hasPrefix("=")
    }

    static func value(of key: String, in shell: String) -> String? {
        for line in shell.split(separator: "\n") where line.hasPrefix("\(key)=") {
            return line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// Escapes a value for embedding inside a double-quoted POSIX shell
    /// string literal (`KEY="value"`), so a captured path containing `"`,
    /// `` ` ``, or `$` doesn't break the generated shim or get misinterpreted
    /// at runtime. Spaces need no escaping inside double quotes (already
    /// handled correctly without this). Nothing reads these values back on
    /// the Swift side — only the shell itself ever evaluates them — so no
    /// matching "unescape" is needed here.
    private static func shellEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "\"" || c == "`" || c == "$" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// `elements` is the full original `notify` array (program first, then
    /// any fixed arguments) — never just the first two, so nothing past
    /// index 1 is silently dropped. `originalLine` (nil if there was no
    /// pre-existing `notify` line at all) is stored base64-encoded purely so
    /// `uninstallCodex` can restore it byte-for-byte later; it plays no part
    /// in how the shim itself forwards calls.
    private func writeShim(forwardTo elements: [String], originalLine: String?) throws {
        let program = elements.first ?? ""
        let fixedArgs = Array(elements.dropFirst())
        let forwardAssignments = (["FORWARD_TO=\"\(Self.shellEscaped(program))\""]
            + fixedArgs.indices.map { "FORWARD_ARG_\($0 + 1)=\"\(Self.shellEscaped(fixedArgs[$0]))\"" })
            .joined(separator: "\n")
        let execWords = (["\"$FORWARD_TO\""]
            + fixedArgs.indices.map { "\"$FORWARD_ARG_\($0 + 1)\"" }
            + ["\"$@\""])
            .joined(separator: " ")
        let originalLineB64 = Data((originalLine ?? "").utf8).base64EncodedString()

        // Fix 6: no /usr/bin/python3 dependency. On a Mac without Xcode
        // Command Line Tools installed — exactly the machine a DMG gets
        // handed to — that path is a stub that never runs, so the shim would
        // register cleanly and then silently never forward an event. Field
        // extraction of Codex's notify JSON blob (thread-id/session_id, cwd,
        // last-assistant-message) used to happen right here with python's
        // json module; it now happens Swift-side in `SpoolEvent`, which has
        // a real JSON parser. This script's only remaining job is to wrap
        // the raw blob verbatim in a small envelope and write it atomically
        // — temp file + `mv` (rename) — so the watcher can never observe a
        // half-written file, then unconditionally exec the original notify
        // program so Codex's own behaviour is never affected by this shim.
        let template = """
        #!/bin/sh
        # AgentMenu shim for Codex's single `notify` slot.
        # Forwards to AgentMenu, then execs the ORIGINAL notify program so the
        # user's existing setup keeps working. Installed by HookInstaller.
        DIR="$HOME/.agentmenu/events"
        ORIGINAL_NOTIFY_LINE_B64="\(originalLineB64)"
        \(forwardAssignments)
        mkdir -p "$DIR" 2>/dev/null
        chmod 700 "$DIR" 2>/dev/null   # holds tool inputs/paths; spec S2 says 0700

        PAYLOAD="$1"
        [ -n "$PAYLOAD" ] || PAYLOAD='{}'
        TS=$(date +%s)
        RAND=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \\n')
        [ -n "$RAND" ] || RAND=$$
        OUT="$DIR/$TS-cx-$RAND.json"
        TMP="$OUT.tmp"
        printf '{"v":2,"agent":"codex","event":"turn-finished","ts":%s,"payload":%s}' \\
            "$TS" "$PAYLOAD" > "$TMP" 2>/dev/null && mv "$TMP" "$OUT" 2>/dev/null

        [ -x "$FORWARD_TO" ] && exec \(execWords)
        exit 0
        """
        let url = scriptsDir.appendingPathComponent("codex-notify-shim.sh")
        try atomicWrite(template, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - JSON reading

    /// A missing file reads as an empty object rather than failing: a user
    /// who has never touched hooks before has no `settings.json` yet, and
    /// installing into a fresh file should succeed rather than error out.
    private func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "{}"
    }

    private static func parseObject(_ text: String, source: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformed(source)
        }
        return obj
    }

    // MARK: - JSON text surgery
    //
    // `JSONSerialization` has no notion of key order, so round-tripping an
    // entire document through it (parse → mutate → reserialize) silently
    // resorts every object in the tree, including ones this installer has
    // no business touching. These helpers replace (or insert) only the
    // value belonging to one top-level key, splicing it directly into the
    // original text so everything else — order, spacing, unrelated content
    // — survives untouched.

    /// Replaces (or inserts) the value of top-level `key` in a JSON object's
    /// source text. Bytes *outside* the replaced span are untouched —
    /// that's the whole point (see the type-level doc comment) — but the
    /// replacement content itself is freshly serialized, so anything already
    /// inside `key`'s value (e.g. a pre-existing hook entry that survives an
    /// uninstall) comes back semantically equivalent, not byte-identical:
    /// keys are alphabetised and re-spaced by `JSONSerialization`.
    ///
    /// `JSONSerialization` always indents a value as if it started at column
    /// zero, so splicing its output in verbatim would under-indent every
    /// nested line relative to the surrounding document (still valid JSON,
    /// but visibly misaligned if a human ever opens the file). Reindenting
    /// every continuation line by the target line's own indent corrects
    /// this, since the serializer's indent step is a constant 2 spaces per
    /// level regardless of where it starts. `.withoutEscapingSlashes` keeps
    /// path-shaped strings (most hook commands) readable as `/usr/...`
    /// rather than Foundation's default `\/usr\/...`.
    static func replacingTopLevelValue(_ key: String, with value: [String: Any],
                                        in text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let rawFragment = String(decoding: data, as: UTF8.self)

        if let valueRange = topLevelValueRange(key, in: text) {
            let indent = leadingWhitespace(before: valueRange.lowerBound, in: text)
            let fragment = reindentingContinuationLines(rawFragment, by: indent)
            return text.replacingCharacters(in: valueRange, with: fragment)
        }
        // Key absent: insert a fresh entry right after the opening brace.
        guard let open = text.firstIndex(of: "{") else {
            throw Error.malformed("not a JSON object")
        }
        let insertAt = text.index(after: open)
        let hasSiblings = text[insertAt...].prefix { $0 != "}" }
            .contains { !" \n\t\r".contains($0) }
        let indent = "  "
        let fragment = reindentingContinuationLines(rawFragment, by: indent)
        let entry = "\n\(indent)\"\(key)\": \(fragment)" + (hasSiblings ? "," : "\n")
        return text.replacingCharacters(in: insertAt..<insertAt, with: entry)
    }

    /// The whitespace a line starts with, given any index on that line.
    private static func leadingWhitespace(before index: String.Index, in text: String) -> String {
        var lineStart = index
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            lineStart = prev
        }
        var indent = ""
        for c in text[lineStart..<index] {
            guard c == " " || c == "\t" else { break }
            indent.append(c)
        }
        return indent
    }

    /// Prepends `indent` to every line of `fragment` after the first — the
    /// first line continues directly after `"key": ` on the existing line,
    /// so it needs no extra indent of its own.
    private static func reindentingContinuationLines(_ fragment: String, by indent: String) -> String {
        guard !indent.isEmpty else { return fragment }
        let lines = fragment.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return fragment }
        return ([String(lines[0])] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n")
    }

    /// Range of the value belonging to top-level `key`, or nil if `key`
    /// isn't present at the top level.
    private static func topLevelValueRange(_ key: String, in s: String) -> Range<String.Index>? {
        guard let open = s.firstIndex(of: "{") else { return nil }
        var i = s.index(after: open)
        let quotedKey = "\"\(key)\""

        while i < s.endIndex {
            while i < s.endIndex, " \n\t\r,".contains(s[i]) { i = s.index(after: i) }
            guard i < s.endIndex, s[i] != "}" else { break }
            guard s[i] == "\"" else { break }             // malformed top level; bail out safely
            let keyStart = i
            guard let keyEnd = endOfValue(s, from: keyStart) else { break }
            var j = keyEnd
            while j < s.endIndex, " \n\t\r".contains(s[j]) { j = s.index(after: j) }
            guard j < s.endIndex, s[j] == ":" else { break }
            j = s.index(after: j)
            while j < s.endIndex, " \n\t\r".contains(s[j]) { j = s.index(after: j) }
            guard let valueEnd = endOfValue(s, from: j) else { break }

            if String(s[keyStart..<keyEnd]) == quotedKey {
                return j..<valueEnd
            }
            i = valueEnd
        }
        return nil
    }

    /// Index just past the JSON value beginning at `start` (its first
    /// non-whitespace character). Strings, numbers, literals, objects, and
    /// arrays are all handled; braces/brackets inside string content (e.g. a
    /// hook command that happens to contain `{`) are skipped rather than
    /// miscounted, by tracking string escaping explicitly.
    private static func endOfValue(_ s: String, from start: String.Index) -> String.Index? {
        guard start < s.endIndex else { return nil }

        func skipString(_ from: String.Index) -> String.Index? {
            var i = s.index(after: from)   // past the opening quote
            while i < s.endIndex {
                switch s[i] {
                case "\\":
                    i = s.index(after: i)
                    guard i < s.endIndex else { return nil }
                    i = s.index(after: i)
                case "\"":
                    return s.index(after: i)
                default:
                    i = s.index(after: i)
                }
            }
            return nil
        }

        if s[start] == "\"" { return skipString(start) }

        if s[start] == "{" || s[start] == "[" {
            var i = start
            var depth = 0
            while i < s.endIndex {
                if s[i] == "\"" {
                    guard let after = skipString(i) else { return nil }
                    i = after
                    continue
                }
                if s[i] == "{" || s[i] == "[" { depth += 1 }
                else if s[i] == "}" || s[i] == "]" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { return i }
            }
            return nil
        }

        // number / true / false / null: run until a structural delimiter.
        var i = start
        while i < s.endIndex, !",}] \n\t\r".contains(s[i]) { i = s.index(after: i) }
        return i
    }

    // MARK: - Shared file safety

    /// Write to a sibling temp file then rename — a crash mid-write must
    /// never leave the user with a truncated agent config.
    private func atomicWrite(_ contents: String, to url: URL) throws {
        let tmp = url.appendingPathExtension("agentmenu-tmp")
        try contents.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Timestamped copy of `url` taken before its first edit. Callers only
    /// invoke this on a path that is actually about to change (install's
    /// idempotent no-op path returns before reaching it), so re-running
    /// install never produces a second backup.
    private func backup(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).agentmenu-backup-\(stamp)")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
    }
}
