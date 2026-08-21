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
    /// Feature 3: OpenAI charges a surcharge for requests whose input exceeds
    /// this many tokens (e.g. 272,000) — optional, so a model without a
    /// documented long-context tier (every Claude/opencode entry) is
    /// unaffected. All three fields are required together in practice, but
    /// kept independently optional so a partially-specified entry degrades to
    /// "no surcharge" rather than a crash.
    public let longContextThreshold: Int?
    /// Multiplies BOTH `inputPerMTok` and the cache rates above the
    /// threshold — the surcharge is billed against the whole input side of
    /// the request, cached or not, since it reflects the cost of processing
    /// a longer context, not which portion happened to hit the cache.
    public let longContextInputMultiplier: Double?
    public let longContextOutputMultiplier: Double?

    public init(inputPerMTok: Double? = nil, outputPerMTok: Double? = nil,
                cacheReadPerMTok: Double? = nil, cacheWritePerMTok: Double? = nil,
                contextWindow: Int? = nil, longContextThreshold: Int? = nil,
                longContextInputMultiplier: Double? = nil,
                longContextOutputMultiplier: Double? = nil) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.contextWindow = contextWindow
        self.longContextThreshold = longContextThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
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

    /// `requestInputTokens`, when supplied, is the FULL input size of the one
    /// request `tokens` describes (cache-inclusive) — used only to decide
    /// whether Feature 3's long-context surcharge applies to this call. Pass
    /// nil (the default) for a cumulative/session-level total, where no
    /// single request size exists and the flat rate is the only honest
    /// choice — applying a multiplier there would be guessing which portion
    /// of the total came from an over-threshold request.
    public func cost(for tokens: TokenStats, model: String, requestInputTokens: Int? = nil) -> Double? {
        guard let p = models[model] else { return nil }
        // A window-only entry (e.g. an opencode model, whose real cost comes from its
        // own DB) carries no rates — report nil rather than a misleading $0.00.
        guard p.inputPerMTok != nil || p.outputPerMTok != nil
           || p.cacheReadPerMTok != nil || p.cacheWritePerMTok != nil else { return nil }

        var inputRate = p.inputPerMTok ?? 0
        var cacheReadRate = p.cacheReadPerMTok ?? 0
        var cacheWriteRate = p.cacheWritePerMTok ?? 0
        var outputRate = p.outputPerMTok ?? 0
        if let threshold = p.longContextThreshold, let requestInputTokens,
           requestInputTokens > threshold {
            if let mult = p.longContextInputMultiplier {
                inputRate *= mult; cacheReadRate *= mult; cacheWriteRate *= mult
            }
            if let mult = p.longContextOutputMultiplier { outputRate *= mult }
        }

        let m = 1_000_000.0
        return Double(tokens.input)      / m * inputRate
             + Double(tokens.output)     / m * outputRate
             + Double(tokens.cacheRead)  / m * cacheReadRate
             + Double(tokens.cacheWrite) / m * cacheWriteRate
    }
}
