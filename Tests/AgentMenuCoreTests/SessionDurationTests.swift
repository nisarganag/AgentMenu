import Testing
import Foundation
@testable import AgentMenuCore

private let t = Date(timeIntervalSince1970: 1_800_000_000)

private func session(startedAt: Date, lastEventAt: Date) -> AgentSession {
    AgentSession(kind: .claudeCode, nativeId: "s", project: "p", directory: "/p",
                 state: .idle, startedAt: startedAt, lastEventAt: lastEventAt)
}

// The bug, verbatim: the row rendered `now - startedAt`, so a session's
// displayed length kept growing for as long as the transcript stayed on disk.
// Measured on the owner's machine: a session that genuinely ran 0.1h displayed
// as 167.9h, having ended 167.9h earlier.
@Test func spanIsFirstToLastActivityNotTimeSinceItStarted() {
    let s = session(startedAt: t, lastEventAt: t.addingTimeInterval(6 * 60))
    #expect(s.span == 6 * 60)
}

@Test func spanDoesNotGrowAfterTheSessionStopsBeingWrittenTo() {
    let s = session(startedAt: t, lastEventAt: t.addingTimeInterval(360))
    // `span` takes no `now` at all — that is the fix. There is no clock left
    // for a finished session's length to drift against.
    #expect(s.span == 360)
}

// A live session needs no special case: its own last event is what advances
// the figure, so the number tracks the work rather than the wall clock.
@Test func aLiveSessionSpanAdvancesWithItsOwnEvents() {
    var s = session(startedAt: t, lastEventAt: t.addingTimeInterval(10))
    #expect(s.span == 10)
    s.lastEventAt = t.addingTimeInterval(75)
    #expect(s.span == 75)
}

// Defensive, matching `TokenStats.-`'s stance: a rescan racing a write must
// never produce a negative duration to format.
@Test func aLastEventBeforeTheStartClampsToZeroRatherThanGoingNegative() {
    let s = session(startedAt: t, lastEventAt: t.addingTimeInterval(-500))
    #expect(s.span == 0)
}

@Test func aSingleMessageSessionSpansZero() {
    let s = session(startedAt: t, lastEventAt: t)
    #expect(s.span == 0)
}

// MARK: - Formatting

@Test func durationsUnderAMinuteRenderInSeconds() {
    #expect(DurationFormat.short(0) == "0s")
    #expect(DurationFormat.short(59) == "59s")
}

@Test func durationsUnderAnHourRenderInMinutesDroppingExactSeconds() {
    #expect(DurationFormat.short(60) == "1m")
    #expect(DurationFormat.short(90) == "1m30s")
    #expect(DurationFormat.short(3599) == "59m59s")
}

@Test func durationsOverAnHourRenderInHoursAndMinutes() {
    #expect(DurationFormat.short(3600) == "1h0m")
    #expect(DurationFormat.short(6 * 60) == "6m")
    #expect(DurationFormat.short(167.9 * 3600) == "167h54m")
}

@Test func negativeDurationsClampRatherThanRenderingASign() {
    #expect(DurationFormat.short(-42) == "0s")
}
