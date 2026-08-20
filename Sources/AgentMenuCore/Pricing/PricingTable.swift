import Foundation

public struct ModelPricing: Codable, Sendable, Equatable {
    /// All fields optional by design. Each agent needs a different subset:
    /// opencode reports cost natively and needs only a window; Codex supplies its
    /// own per-session window and needs only rates. Requiring all five would force
    /// one of them to be fabricated — which spec §7 forbids.
    public let inputPerMTok: Double?
    public let outputPerMTok: Double?
    public let cacheReadPerMTok: Double?
    public let cacheWritePerMTok: Double?
    public let contextWindow: Int?

    public init(inputPerMTok: Double? = nil, outputPerMTok: Double? = nil,
                cacheReadPerMTok: Double? = nil, cacheWritePerMTok: Double? = nil,
                contextWindow: Int? = nil) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.contextWindow = contextWindow
    }
}

/// Model rates live in a user-editable JSON resource rather than compiled in,
/// so a newly released model is a one-line edit instead of a rebuild, and an
/// unknown model renders "—" instead of a silently wrong number (spec §7).
public struct PricingTable: Sendable, Equatable {
    public let models: [String: ModelPricing]

    public init(models: [String: ModelPricing]) {
        self.models = models
    }

    private struct Wire: Codable { let models: [String: ModelPricing] }

    public static func decode(_ data: Data) throws -> PricingTable {
        PricingTable(models: try JSONDecoder().decode(Wire.self, from: data).models)
    }

    public static func load(from url: URL) throws -> PricingTable {
        try decode(try Data(contentsOf: url))
    }

    public func contextWindow(for model: String) -> Int? {
        models[model]?.contextWindow
    }

    public func cost(for tokens: TokenStats, model: String) -> Double? {
        guard let p = models[model] else { return nil }
        // A window-only entry (e.g. an opencode model, whose real cost comes from its
        // own DB) carries no rates — report nil rather than a misleading $0.00.
        guard p.inputPerMTok != nil || p.outputPerMTok != nil
           || p.cacheReadPerMTok != nil || p.cacheWritePerMTok != nil else { return nil }
        let m = 1_000_000.0
        return Double(tokens.input)      / m * (p.inputPerMTok      ?? 0)
             + Double(tokens.output)     / m * (p.outputPerMTok     ?? 0)
             + Double(tokens.cacheRead)  / m * (p.cacheReadPerMTok  ?? 0)
             + Double(tokens.cacheWrite) / m * (p.cacheWritePerMTok ?? 0)
    }
}
