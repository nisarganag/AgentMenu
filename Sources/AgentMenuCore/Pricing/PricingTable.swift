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
    /// 1-hour prompt-cache write rate (Claude: 2x input). `cacheWritePerMTok`
    /// is the 5-minute rate. Absent means "no known 1-hour price": usage that
    /// actually has 1-hour writes is then unpriced rather than billed at the
    /// cheaper 5-minute rate.
    public let cacheWrite1hPerMTok: Double?
    /// Fast mode's premium over standard rates, applied to every bucket (2x on
    /// Opus 5.5 / Opus 5 / Opus 4.8). Absent means the model has no fast mode.
    public let fastMultiplier: Double?
    /// US-only inference uplift, applied to every bucket (1.1x on Claude 4.6
    /// and later). Absent means the model does not support it.
    public let usGeoMultiplier: Double?

    public init(inputPerMTok: Double? = nil, outputPerMTok: Double? = nil,
                cacheReadPerMTok: Double? = nil, cacheWritePerMTok: Double? = nil,
                contextWindow: Int? = nil, longContextThreshold: Int? = nil,
                longContextInputMultiplier: Double? = nil,
                longContextOutputMultiplier: Double? = nil,
                cacheWrite1hPerMTok: Double? = nil, fastMultiplier: Double? = nil,
                usGeoMultiplier: Double? = nil) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.contextWindow = contextWindow
        self.longContextThreshold = longContextThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.fastMultiplier = fastMultiplier
        self.usGeoMultiplier = usGeoMultiplier
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

    /// Convenience for a model at standard speed and global routing.
    public func cost(for tokens: TokenStats, model: String, requestInputTokens: Int? = nil) -> Double? {
        cost(for: tokens, rate: RateKey(model: model), requestInputTokens: requestInputTokens)
    }

    /// Price of `tokens` billed at `rate`, or nil when that price is not known.
    ///
    /// "Not known" is deliberately broad: an unlisted model, a listed model
    /// with no rates (opencode window-only entries), a fast-mode or US-only
    /// request on a model with no multiplier for it, or 1-hour cache writes on
    /// a model with no 1-hour rate. Every one of those used to be — or would
    /// easily have been — silently billed at some other rate, which produces a
    /// number that looks right and is not. nil is honest; `CostEstimate` then
    /// decides whether that makes a whole session unknown or merely partial.
    ///
    /// `requestInputTokens`, when supplied, is the FULL input size of the one
    /// request `tokens` describes (cache-inclusive) — used only to decide
    /// whether the long-context surcharge applies to this call. Pass nil for a
    /// cumulative total, where no single request size exists and the flat rate
    /// is the only honest choice.
    public func cost(for tokens: TokenStats, rate: RateKey, requestInputTokens: Int? = nil) -> Double? {
        guard let p = models[rate.model] else { return nil }
        guard p.inputPerMTok != nil || p.outputPerMTok != nil
           || p.cacheReadPerMTok != nil || p.cacheWritePerMTok != nil else { return nil }

        var modifier = 1.0
        if rate.fast {
            guard let m = p.fastMultiplier else { return nil }
            modifier *= m
        }
        if rate.usGeo {
            guard let m = p.usGeoMultiplier else { return nil }
            modifier *= m
        }
        let oneHour = min(tokens.cacheWrite1h, tokens.cacheWrite)
        if oneHour > 0, p.cacheWrite1hPerMTok == nil { return nil }

        var inputRate = p.inputPerMTok ?? 0
        var cacheReadRate = p.cacheReadPerMTok ?? 0
        var cacheWriteRate = p.cacheWritePerMTok ?? 0
        var cacheWrite1hRate = p.cacheWrite1hPerMTok ?? 0
        var outputRate = p.outputPerMTok ?? 0
        if let threshold = p.longContextThreshold, let requestInputTokens,
           requestInputTokens > threshold {
            if let mult = p.longContextInputMultiplier {
                inputRate *= mult; cacheReadRate *= mult
                cacheWriteRate *= mult; cacheWrite1hRate *= mult
            }
            if let mult = p.longContextOutputMultiplier { outputRate *= mult }
        }

        let m = 1_000_000.0
        let dollars = Double(tokens.input)                / m * inputRate
                    + Double(tokens.output)               / m * outputRate
                    + Double(tokens.cacheRead)            / m * cacheReadRate
                    + Double(tokens.cacheWrite - oneHour) / m * cacheWriteRate
                    + Double(oneHour)                     / m * cacheWrite1hRate
        return dollars * modifier
    }

    /// Prices each bucket at its own rate and sums them. See `CostEstimate`
    /// for how unknown buckets are folded in.
    public func estimate(_ buckets: [RateKey: TokenStats]) -> CostEstimate {
        var e = CostEstimate()
        for (rate, tokens) in buckets { e.add(cost(for: tokens, rate: rate), tokens: tokens) }
        return e
    }
}
