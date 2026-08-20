import Foundation

/// Finds running agent processes, for liveness and focus-on-click.
///
/// Matching is on the EXECUTABLE path (argv[0]) only, never the whole command
/// line — otherwise `grep claude` and `vim claude.md` register as agents.
public struct ProcessScanner: Sendable {
    public struct RunningAgent: Sendable, Equatable {
        public let pid: pid_t
        public let kind: AgentKind
        public let commandLine: String
        /// The process's current working directory, when resolvable — used
        /// to attribute a pid to a SPECIFIC session (Fix 7 / review Ruling
        /// F65) rather than to "the first running process of this kind."
        /// Nil if the process no longer exists or lsof otherwise can't read
        /// it (permissions, timing); callers must treat that the same as
        /// "unattributable," never guess.
        public let directory: String?

        public init(pid: pid_t, kind: AgentKind, commandLine: String, directory: String? = nil) {
            self.pid = pid; self.kind = kind; self.commandLine = commandLine
            self.directory = directory
        }
    }

    public init() {}

    public static func parse(psOutput: String) -> [RunningAgent] {
        psOutput.split(separator: "\n").compactMap { line -> RunningAgent? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex..<space]) else { return nil }
            // `comm` gives the executable path with NO arguments, so argv[0] needs no
            // parsing. `args` cannot be used here: it is free text with no quoting, so any
            // executable path containing a space (e.g. ".../Software Update.app/...")
            // splits incorrectly and the process is silently missed.
            let executable = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            guard let kind = classify(executable: executable) else { return nil }
            return RunningAgent(pid: pid, kind: kind, commandLine: executable)
        }
    }

    /// Parses `lsof -a -p <pids> -d cwd -Fn` output into `pid -> cwd`.
    ///
    /// `-F` field-list output is line-oriented: a `p<pid>` header line
    /// starts each process's block, followed by one `f<fd-name>` and
    /// `n<path>` pair per matching descriptor. Restricting the query to
    /// `-d cwd` means at most one such pair per pid — the process's current
    /// working directory. A pid absent from the output (already exited,
    /// unreadable) simply has no entry in the result, which callers must
    /// treat as "unknown," never guessed.
    public static func parseWorkingDirectories(lsofOutput: String) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        var currentPid: pid_t?
        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                currentPid = pid_t(value)
            case "n":
                if let pid = currentPid { result[pid] = String(value) }
            default:
                break
            }
        }
        return result
    }

    private static func classify(executable: String) -> AgentKind? {
        let name = (executable as NSString).lastPathComponent
        switch name {
        case "claude": return .claudeCode
        case "codex":  return .codex
        case "opencode": return .opencode
        default:
            // VS Code extension hosts embed the agent name in the path.
            if executable.contains("anthropic.claude-code") { return .claudeCode }
            if executable.contains("openai.chatgpt") { return .codex }
            return nil
        }
    }

    public func scan() -> [RunningAgent] {
        let agents = Self.parse(psOutput: run("/bin/ps", ["-Ao", "pid=,comm="]))
        guard !agents.isEmpty else { return [] }

        // Only ever looked up for the (typically tiny) set of ALREADY
        // matched agent pids, never the full process table — this is a
        // handful of extra `lsof` reads riding along on the same throttled
        // cadence as `scan()` itself (Fix 2), not another O(process count) cost.
        let pids = agents.map(\.pid).map(String.init).joined(separator: ",")
        let dirs = Self.parseWorkingDirectories(
            lsofOutput: run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fn"]))

        return agents.map { a in
            RunningAgent(pid: a.pid, kind: a.kind, commandLine: a.commandLine, directory: dirs[a.pid])
        }
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
