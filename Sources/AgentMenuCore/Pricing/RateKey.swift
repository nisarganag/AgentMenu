import Foundation

/// Everything that decides which rates a unit of usage is billed at: the
/// model that produced it, plus the request-level modifiers that reprice it.
///
/// Usage is accumulated per `RateKey` and priced at read time, never folded
/// into a single session total first. A session is not one model — people
/// switch with `/model` mid-conversation, and the old approach of pricing a
/// session's entire lifetime at whichever model sent its LAST message priced
/// 1,477 Opus 5 messages as Opus 5.5 on the owner's machine (and, with Opus 5.5
/// then unlisted, as nothing at all).
///
/// Holds tokens, not dollars, on purpose: accumulators are checkpointed, and
/// dollars frozen into a checkpoint would never pick up a corrected price.
public struct RateKey: Hashable, Codable, Sendable {
    public var model: String
    /// Claude `usage.speed == "fast"` — fast mode's premium applies to every
    /// bucket, cache included.
    public var fast: Bool
    /// Claude `usage.inference_geo == "us"` — US-only inference carries a
    /// 1.1x uplift on every bucket.
    public var usGeo: Bool

    public init(model: String, fast: Bool = false, usGeo: Bool = false) {
        self.model = model; self.fast = fast; self.usGeo = usGeo
    }
}

/// A cost that may cover only part of the usage it describes.
public struct CostEstimate: Sendable, Equatable {
    /// Sum over every bucket that could be priced.
    public var dollars: Double
    /// Some bucket with real tokens had no known price, so `dollars` is a floor.
    public var isPartial: Bool
    /// At least one bucket was priced — even at $0.00.
    public var anyPriced: Bool

    public init(dollars: Double = 0, isPartial: Bool = false, anyPriced: Bool = false) {
        self.dollars = dollars; self.isPartial = isPartial; self.anyPriced = anyPriced
    }

    /// What a session should show: nil when nothing at all could be priced,
    /// so a session made purely of unknown models still renders "—" rather
    /// than a confident-looking $0.00 (spec §7).
    public var displayDollars: Double? { anyPriced ? dollars : nil }

    public static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate {
        CostEstimate(dollars: a.dollars + b.dollars, isPartial: a.isPartial || b.isPartial,
                     anyPriced: a.anyPriced || b.anyPriced)
    }

    /// Folds one bucket's price in. `price` nil means "no known rate" — which
    /// only makes the estimate partial when there were tokens to price. An
    /// unknown model with nothing to bill (Claude Code's `<synthetic>` API
    /// error placeholders) cannot make a total wrong, so it must not flag one.
    public mutating func add(_ price: Double?, tokens: TokenStats) {
        if let price {
            dollars += price
            anyPriced = true
        } else if tokens.total > 0 {
            isPartial = true
        }
    }
}
