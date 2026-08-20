import Foundation

/// Absolute token and cost burn over rolling windows.
///
/// Deliberately NOT a percentage of a provider quota: `rateLimits` is null on
/// disk for both Claude and Codex, so any percentage would be invented. See
/// spec §6.
public struct RollingBurn: Sendable {
    public static let fiveHours: TimeInterval = 5 * 3600
    public static let sevenDays: TimeInterval = 7 * 86_400

    private struct Sample { let tokens: Int; let cost: Double?; let at: Date }
    private var samples: [Sample] = []

    public init() {}

    public var count: Int { samples.count }

    public mutating func record(tokens: Int, cost: Double?, at: Date) {
        samples.append(Sample(tokens: tokens, cost: cost, at: at))
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.sevenDays)
        samples.removeAll { $0.at < cutoff }
    }

    public mutating func tokens(window: TimeInterval, now: Date) -> Int {
        prune(now: now)
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.at >= cutoff }.reduce(0) { $0 + $1.tokens }
    }

    public mutating func cost(window: TimeInterval, now: Date) -> Double {
        prune(now: now)
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.at >= cutoff }.reduce(0) { $0 + ($1.cost ?? 0) }
    }
}
