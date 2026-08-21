import Testing
import Foundation
@testable import AgentMenuCore

// Real shapes captured from `ps -Ao pid=,comm=` on the target machine. `comm`
// reports the executable path with no arguments at all — see
// ProcessScanner.parse for why `args` (unquoted free text) can't be used
// instead.
private let psSample = """
64895 /Users/n/.vscode/extensions/openai.chatgpt-26.818.21641-darwin-arm64/bin/macos-aarch64/codex
65060 /Users/n/.vscode/extensions/anthropic.claude-code-2.1.237-darwin-arm64/resources/native-binary/claude
70001 /opt/homebrew/bin/opencode
70002 /usr/local/bin/node
70003 /usr/bin/grep
70004 /Users/n/My Tools/opencode
80001 /Users/n/.vscode/extensions/anthropic.claude-code-2.1.237-darwin-arm64/resources/native-binary/claude-cli-renamed
80002 /Users/n/.vscode/extensions/openai.chatgpt-26.818.21641-darwin-arm64/bin/macos-aarch64/codex-cli-renamed
"""

@Test func recognisesVSCodeExtensionBinariesNotJustBareCLINames() {
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(found.first { $0.pid == 64895 }?.kind == .codex)
    #expect(found.first { $0.pid == 65060 }?.kind == .claudeCode)
    #expect(found.first { $0.pid == 70001 }?.kind == .opencode)
}

@Test func ignoresUnrelatedProcesses() {
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(!found.contains { $0.pid == 70002 })
}

@Test func ignoresOurOwnGrepAndSimilarFalsePositives() {
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(found.contains { $0.pid == 70003 } == false,
            "grep is not a tracked agent executable, regardless of its arguments")
}

@Test func toleratesMalformedLines() {
    #expect(ProcessScanner.parse(psOutput: "\n\nnot-a-pid something\n").isEmpty)
}

@Test func emptyOutputYieldsNoAgents() {
    #expect(ProcessScanner.parse(psOutput: "").isEmpty)
}

@Test func executablePathContainingASpaceIsNotTruncated() {
    // Regression guard: `comm` can legitimately contain spaces (e.g. an app
    // bundle path like ".../Software Update.app/..."). argv[0] extraction
    // must use the whole remainder of the line, never split it on space.
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(found.first { $0.pid == 70004 }?.kind == .opencode)
}

@Test func classifiesByExtensionIdWhenTheBinaryLeafNameDiffers() {
    // Closes a coverage gap: every other fixture's last path component
    // already equals the bare CLI name, so the substring fallback below
    // never actually ran until this fixture existed.
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(found.first { $0.pid == 80001 }?.kind == .claudeCode)
    #expect(found.first { $0.pid == 80002 }?.kind == .codex)
}

@Test func parsedAgentsHaveNoDirectoryUntilLsofFillsItIn() {
    // `parse(psOutput:)` alone (no lsof pass) must not guess — Fix 7 requires
    // "unattributable" to read as nil, never a fabricated value.
    let found = ProcessScanner.parse(psOutput: psSample)
    #expect(found.allSatisfy { $0.directory == nil })
}

// MARK: - Fix 7: working-directory attribution, so a pid is only ever
// assigned to the ONE session whose directory it actually matches, rather
// than "the first running process of this kind" (which made every row of a
// kind share the same pid and could focus an arbitrary project's window).

// Real shape of `lsof -a -p <pids> -d cwd -Fn`: a `p<pid>` header line, then
// one `f<fd-name>`/`n<path>` pair per matching descriptor — verified
// directly against a real invocation on this machine.
private let lsofSample = """
p64895
fcwd
n/Users/n/work/codex-project
p65060
fcwd
n/Users/n/work/claude-project
"""

@Test func parsesPidToWorkingDirectoryFromLsofFieldOutput() {
    let dirs = ProcessScanner.parseWorkingDirectories(lsofOutput: lsofSample)
    #expect(dirs[64895] == "/Users/n/work/codex-project")
    #expect(dirs[65060] == "/Users/n/work/claude-project")
}

@Test func aPidAbsentFromLsofOutputHasNoEntryRatherThanAGuess() {
    let dirs = ProcessScanner.parseWorkingDirectories(lsofOutput: lsofSample)
    #expect(dirs[99999] == nil, "a pid lsof couldn't report on must stay unattributed, never guessed")
}

@Test func emptyLsofOutputYieldsNoDirectories() {
    #expect(ProcessScanner.parseWorkingDirectories(lsofOutput: "").isEmpty)
}

@Test func workingDirectoryContainingSpacesIsCapturedInFull() {
    // `n` takes the rest of the line verbatim, no splitting on whitespace —
    // mirrors why ProcessScanner.parse itself never uses `ps`'s `args` field.
    let sample = "p123\nfcwd\nn/Users/n/My Tools/some project\n"
    let dirs = ProcessScanner.parseWorkingDirectories(lsofOutput: sample)
    #expect(dirs[123] == "/Users/n/My Tools/some project")
}
