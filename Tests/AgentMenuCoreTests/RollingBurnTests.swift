import Testing
import Foundation
@testable import AgentMenuCore

private let now = Date(timeIntervalSince1970: 1_755_689_400)

@Test func sumsOnlyWithinTheWindow() {
    var b = RollingBurn()
    b.record(tokens: 100, cost: 1.0, at: now.addingTimeInterval(-60))          // 1m ago
    b.record(tokens: 200, cost: 2.0, at: now.addingTimeInterval(-4 * 3600))    // 4h ago
    b.record(tokens: 400, cost: 4.0, at: now.addingTimeInterval(-6 * 3600))    // 6h ago
    #expect(b.tokens(window: RollingBurn.fiveHours, now: now) == 300)
    #expect(abs(b.cost(window: RollingBurn.fiveHours, now: now) - 3.0) < 0.0001)
    #expect(b.tokens(window: RollingBurn.sevenDays, now: now) == 700)
}

@Test func missingCostContributesZeroRatherThanBreakingTheSum() {
    var b = RollingBurn()
    b.record(tokens: 50, cost: nil, at: now)      // unknown model — no price
    b.record(tokens: 50, cost: 1.5, at: now)
    #expect(b.tokens(window: RollingBurn.fiveHours, now: now) == 100)
    #expect(abs(b.cost(window: RollingBurn.fiveHours, now: now) - 1.5) < 0.0001)
}

@Test func prunesEntriesOlderThanTheLongestWindow() {
    var b = RollingBurn()
    b.record(tokens: 1, cost: nil, at: now.addingTimeInterval(-30 * 86_400))
    b.record(tokens: 1, cost: nil, at: now)
    _ = b.tokens(window: RollingBurn.fiveHours, now: now)
    #expect(b.count == 1, "month-old samples must not accumulate forever")
}
