import Testing
import Foundation
@testable import AgentMenuCore

@Test func allThreeVisibleWithNoPreferencesWhenAllHaveSessions() {
    let visible = AgentVisibility.visible(
        preferences: [:],
        hasSessions: [.claudeCode, .codex, .opencode],
        hasDataDirectory: [])
    #expect(visible == [.claudeCode, .codex, .opencode])
}

@Test func aKindWithNoSessionsAndNoDataDirectoryAutoHides() {
    // opencode: never installed, never run — the exact "fresh user" case.
    let visible = AgentVisibility.visible(
        preferences: [:],
        hasSessions: [.claudeCode, .codex],
        hasDataDirectory: [.claudeCode, .codex])
    #expect(visible == [.claudeCode, .codex], "an agent never seen must not get a permanently empty page")
}

@Test func aKindWithADataDirectoryButNoCurrentSessionsStillShows() {
    // Used before; nothing currently inside the lookback window — idle, not "never used."
    let visible = AgentVisibility.visible(
        preferences: [:],
        hasSessions: [],
        hasDataDirectory: [.claudeCode])
    #expect(visible == [.claudeCode], "a data directory on disk is evidence enough, even with zero live sessions")
}

@Test func explicitFalseHidesAKindEvenWithLiveSessions() {
    let visible = AgentVisibility.visible(
        preferences: [.codex: false],
        hasSessions: [.claudeCode, .codex, .opencode],
        hasDataDirectory: [.claudeCode, .codex, .opencode])
    #expect(!visible.contains(.codex), "an explicit toggle must win over any auto-show evidence")
}

@Test func explicitTrueShowsAKindThatHasNeverBeenSeen() {
    let visible = AgentVisibility.visible(
        preferences: [.opencode: true],
        hasSessions: [.claudeCode],
        hasDataDirectory: [.claudeCode])
    #expect(visible.contains(.opencode), "an explicit toggle must win over the auto-hide rule too")
}

@Test func orderIsAlwaysTheFixedAgentKindOrder() {
    let visible = AgentVisibility.visible(
        preferences: [.opencode: true, .claudeCode: true],
        hasSessions: [.codex],
        hasDataDirectory: [.codex])
    #expect(visible == [.claudeCode, .codex, .opencode],
            "page order must never depend on preference dictionary iteration order")
}

@Test func allThreeHiddenYieldsAnEmptyList() {
    let visible = AgentVisibility.visible(
        preferences: [.claudeCode: false, .codex: false, .opencode: false],
        hasSessions: [.claudeCode, .codex, .opencode],
        hasDataDirectory: [.claudeCode, .codex, .opencode])
    #expect(visible.isEmpty)
}

@Test func allThreeNeverSeenYieldsAnEmptyListWithNoExplicitPreferences() {
    let visible = AgentVisibility.visible(preferences: [:], hasSessions: [], hasDataDirectory: [])
    #expect(visible.isEmpty, "a completely fresh install with none of the three ever used shows nothing")
}
