import Foundation

/// Both Claude and Codex stamp records as ISO8601 with fractional seconds
/// ("2026-08-19T18:21:33.704Z"). `ISO8601DateFormatter` needs the fractional
/// option explicitly, and is expensive to construct, so it is cached.
public enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}
