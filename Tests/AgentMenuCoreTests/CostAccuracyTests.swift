import Testing
import Foundation
@testable import AgentMenuCore

// Cost accuracy, round 2 (owner report 2026-09-27: "the cost calculations are
// grossly wrong ... claude was updated and new models came out ... gpt was
// also updated").
//
// Measured on the owner's machine before any change: the app showed $36.92
// for the day against $242.58 real, and $0.37 for a week of Codex against
// $13.53. Wrong in both directions at once — whole sessions vanished while
// the sessions that did get priced were priced too high — which is why it read
// as random rather than merely off. Every test below pins one cause.
//
// Rates are the official ones, fetched 2026-09-27:
//   platform.claude.com/docs/en/about-claude/pricing
//   developers.openai.com/api/docs/pricing

private let pricing = try! PricingTable.decode(#"""
{"models":{
 "claude-opus-5":   {"inputPerMTok":5,"outputPerMTok":25,"cacheReadPerMTok":0.5,"cacheWritePerMTok":6.25,
                     "cacheWrite1hPerMTok":10,"fastMultiplier":2,"usGeoMultiplier":1.1,"contextWindow":1000000},
 "claude-opus-5-5": {"inputPerMTok":4,"outputPerMTok":20,"cacheReadPerMTok":0.2,"cacheWritePerMTok":5,
                     "cacheWrite1hPerMTok":8,"fastMultiplier":2,"usGeoMultiplier":1.1,"contextWindow":1000000},
 "claude-haiku-4-5":{"inputPerMTok":1,"outputPerMTok":5,"cacheReadPerMTok":0.1,"cacheWritePerMTok":1.25,
                     "contextWindow":200000},
 "gpt-6-astra":     {"inputPerMTok":10,"outputPerMTok":50,"cacheReadPerMTok":1,"cacheWritePerMTok":12.5,
                     "longContextThreshold":272000,"longContextInputMultiplier":2,"longContextOutputMultiplier":1.5},
 "gpt-5.6-sol":     {"inputPerMTok":4,"outputPerMTok":20,"cacheReadPerMTok":0.4,"cacheWritePerMTok":5,
                     "longContextThreshold":272000,"longContextInputMultiplier":2,"longContextOutputMultiplier":1.5}
}}
"""#.data(using: .utf8)!)

private let M = 1_000_000
private func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tol
}

// MARK: - PricingTable: the dimensions the old table could not express

// Opus 5.5 cache reads are 0.05x input, not the 0.1x every older model uses.
// Cache reads are the dominant bucket on this machine by far, so assuming the
// usual ratio would have doubled the largest line of the bill.
@Test func opus55CacheReadsAreBilledAtFivePercentOfInputNotTen() {
    #expect(near(pricing.cost(for: TokenStats(cacheRead: M), rate: RateKey(model: "claude-opus-5-5")), 0.20))
}

// 1-hour cache writes cost 2x input; 5-minute writes cost 1.25x. The transcript
// reports the split in `cache_creation`, so there is no reason to guess.
@Test func oneHourCacheWritesAreBilledAtTheirOwnRate() {
    let t = TokenStats(cacheWrite: 2 * M, cacheWrite1h: M)   // 1M of 5-minute + 1M of 1-hour
    #expect(near(pricing.cost(for: t, rate: RateKey(model: "claude-opus-5")), 6.25 + 10))
}

@Test func oneHourWritesOnAModelWithNoOneHourRateAreUnpricedNotGuessed() {
    let t = TokenStats(cacheWrite: M, cacheWrite1h: M)
    #expect(pricing.cost(for: t, rate: RateKey(model: "claude-haiku-4-5")) == nil)
}

@Test func fastModeMultipliesEveryBucket() {
    let t = TokenStats(input: M, output: M)
    #expect(near(pricing.cost(for: t, rate: RateKey(model: "claude-opus-5-5", fast: true)), (4 + 20) * 2))
}

// Billing a fast-mode request at standard rates would understate it by half
// and look perfectly plausible doing it.
@Test func fastModeOnAModelWithNoFastRateIsUnpricedNotBilledAsStandard() {
    #expect(pricing.cost(for: TokenStats(input: M), rate: RateKey(model: "claude-haiku-4-5", fast: true)) == nil)
}

@Test func usInferenceGeographyAddsTenPercentAndStacksWithFastMode() {
    let t = TokenStats(input: M)
    #expect(near(pricing.cost(for: t, rate: RateKey(model: "claude-opus-5-5", usGeo: true)), 4.4))
    #expect(near(pricing.cost(for: t, rate: RateKey(model: "claude-opus-5-5", fast: true, usGeo: true)), 8.8))
}

// MARK: - Estimates over several models

@Test func anEstimateSumsEachBucketAtItsOwnRate() {
    let e = pricing.estimate([
        RateKey(model: "claude-opus-5"): TokenStats(input: M),
        RateKey(model: "claude-opus-5-5"): TokenStats(input: M),
    ])
    #expect(near(e.displayDollars, 9))
    #expect(!e.isPartial)
}

// The failure the owner hit, generalised: a model newer than the price table
// used to erase a session's entire known cost. It must now cost what it can
// and say it is incomplete.
@Test func anUnpricedModelMakesAnEstimatePartialInsteadOfErasingIt() {
    let e = pricing.estimate([
        RateKey(model: "claude-opus-5"): TokenStats(input: M),
        RateKey(model: "claude-future-9"): TokenStats(output: M),
    ])
    #expect(near(e.displayDollars, 5))
    #expect(e.isPartial)
}

@Test func anEstimateWithNothingPricedHasNoDollarsAtAll() {
    let e = pricing.estimate([RateKey(model: "claude-future-9"): TokenStats(output: M)])
    #expect(e.displayDollars == nil)
}

// `<synthetic>` placeholder messages carry no tokens. An unknown model with
// nothing to price cannot make a total wrong, so it must not flag one either.
@Test func anUnpricedBucketWithNoTokensDoesNotMakeAnEstimatePartial() {
    let e = pricing.estimate([
        RateKey(model: "claude-opus-5"): TokenStats(input: M),
        RateKey(model: "<synthetic>"): TokenStats(),
    ])
    #expect(!e.isPartial)
}

// MARK: - Claude: each message at its own model

private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
nonisolated(unsafe) private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func claudeLine(id: String, model: String, at: Date = t0,
                        input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                        write5m: Int = 0, write1h: Int = 0,
                        speed: String? = nil, geo: String? = nil) -> Data {
    var usage: [String: Any] = [
        "input_tokens": input, "output_tokens": output,
        "cache_read_input_tokens": cacheRead,
        "cache_creation_input_tokens": write5m + write1h,
        "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
    ]
    if let speed { usage["speed"] = speed }
    if let geo { usage["inference_geo"] = geo }
    return try! JSONSerialization.data(withJSONObject: [
        "type": "assistant", "timestamp": iso.string(from: at), "sessionId": "s", "cwd": "/p",
        "message": ["id": id, "model": model, "stop_reason": "tool_use",
                    "content": [["type": "text", "text": "x"]], "usage": usage],
    ] as [String: Any])
}

// THE bug. The session's whole lifetime was priced at whichever model sent
// its LAST message. The owner's AgentMenu session — 1,477 Opus 5 messages
// then a switch to Opus 5.5 — was therefore priced entirely as Opus 5.5,
// which had no entry, so ~$590 of spend rendered "—" and left every total.
@Test func aSessionThatSwitchesModelsPricesEachMessageAtItsOwnModel() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", input: M))        // $5
    p.consume(claudeLine(id: "b", model: "claude-opus-5", output: M))       // $25
    p.consume(claudeLine(id: "c", model: "claude-opus-5-5", cacheRead: M))  // $0.20
    // Priced as last-model-wins this would read 4 + 20 + 0.2 = $24.20.
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 30.20))
}

@Test func aSessionEndingOnAnUnpricedModelKeepsItsPricedHistory() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", input: M))
    p.consume(claudeLine(id: "b", model: "claude-future-9", output: M))
    let e = p.costEstimate(pricing: pricing)
    #expect(near(e.displayDollars, 5))
    #expect(e.isPartial)
}

@Test func syntheticPlaceholderMessagesDoNotMakeASessionPartial() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", input: M))
    p.consume(claudeLine(id: "b", model: "<synthetic>"))
    #expect(!p.costEstimate(pricing: pricing).isPartial)
}

@Test func oneHourCacheWritesAreReadFromTheTranscriptSplit() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", write5m: M, write1h: M))
    // All writes at the 5-minute rate would read 2 x 6.25 = $12.50.
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 16.25))
    // The display total is unchanged: every write is still a cache write.
    #expect(p.session(path: "/t", now: t0)?.tokens.cacheWrite == 2 * M)
}

@Test func fastModeAndUSGeographyAreCarriedFromTheUsageRecord() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5-5", input: M, speed: "fast", geo: "us"))
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 8.8))
}

@Test func standardSpeedAndGlobalGeographyAreBilledAtBaseRates() {
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5-5", input: M, speed: "standard", geo: "global"))
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 4))
}

@Test func todaysCostIsPricedPerMessageToo() {
    let now = Calendar.current.startOfDay(for: t0).addingTimeInterval(12 * 3600)
    let yesterday = now.addingTimeInterval(-86_400)
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", at: yesterday, input: M))   // $5, not today
    p.consume(claudeLine(id: "b", model: "claude-opus-5-5", at: now, input: M))       // $4, today
    #expect(near(p.costEstimateToday(pricing: pricing, now: now).displayDollars, 4))
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 9))
}

// Lifetime cost comes from a per-rate accumulator, not from the per-message
// log — that log is trimmed to about a day on every checkpoint, so pricing
// from it would lose everything older after a restart.
@Test func perModelTotalsSurviveACheckpointRoundTrip() throws {
    let now = Calendar.current.startOfDay(for: t0).addingTimeInterval(12 * 3600)
    var p = ClaudeTranscriptParser()
    p.consume(claudeLine(id: "a", model: "claude-opus-5", at: now.addingTimeInterval(-3 * 86_400), input: M))
    p.consume(claudeLine(id: "b", model: "claude-opus-5-5", at: now, input: M))
    let restored = try JSONDecoder().decode(ClaudeTranscriptParser.self,
                                            from: JSONEncoder().encode(p.checkpointSnapshot(now: now)))
    #expect(near(restored.costEstimate(pricing: pricing).displayDollars, 9))
}

// MARK: - Codex

private func codexMeta() -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "type": "session_meta", "timestamp": iso.string(from: t0),
        "payload": ["id": "r", "cwd": "/p"]] as [String: Any])
}
private func codexTurn(_ model: String, at: Date = t0) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "type": "turn_context", "timestamp": iso.string(from: at),
        "payload": ["model": model]] as [String: Any])
}

/// Emits one `token_count`, keeping `total_token_usage` cumulative the way
/// real rollouts do — so a test exercises the lifetime path and the
/// per-request path from the same data, just like production.
private struct CodexRollout {
    var raw = 0, cached = 0, write = 0, output = 0
    mutating func request(at: Date = t0, raw r: Int, cached c: Int = 0, write w: Int = 0,
                          output o: Int = 0) -> Data {
        raw += r; cached += c; write += w; output += o
        func usage(_ i: Int, _ c: Int, _ w: Int, _ o: Int) -> [String: Any] {
            ["input_tokens": i, "cached_input_tokens": c, "cache_write_input_tokens": w,
             "output_tokens": o, "reasoning_output_tokens": 0, "total_tokens": i + o]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "timestamp": iso.string(from: at),
            "payload": ["type": "token_count", "info": [
                "total_token_usage": usage(raw, cached, write, output),
                "last_token_usage": usage(r, c, w, o),
                "model_context_window": 258_400]]] as [String: Any])
    }
}

// Proven across all 1,675 token_count records on the owner's machine:
// `input_tokens - cached_input_tokens - cache_write_input_tokens` is never
// negative, so writes are a SUBSET of input, exactly as cached reads already
// were. Only reads were being subtracted, so every written token was billed
// twice — once as input, once as a write — on 96.5% of requests.
@Test func codexCacheWritesAreNotAlsoBilledAsInput() {
    var r = CodexRollout(); var p = CodexRolloutParser()
    p.consume(codexMeta()); p.consume(codexTurn("gpt-6-astra"))
    p.consume(r.request(raw: 200_000, write: 199_997))
    // 3 uncached x $10 + 199,997 written x $12.50. Double-billed: $4.50.
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 2.49999, 1e-4))
    #expect(p.session(path: "/r", now: t0)?.tokens.input == 3)
}

@Test func aCodexRolloutThatSwitchesModelsPricesEachRequestAtItsOwnModel() {
    var r = CodexRollout(); var p = CodexRolloutParser()
    p.consume(codexMeta())
    p.consume(codexTurn("gpt-5.6-sol"));  p.consume(r.request(raw: 100_000))   // $0.40
    p.consume(codexTurn("gpt-6-astra"));  p.consume(r.request(raw: 100_000))   // $1.00
    // Priced as last-model-wins: $2.00.
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 1.40))
}

@Test func codexLongContextSurchargeStillAppliesPerRequest() {
    var r = CodexRollout(); var p = CodexRolloutParser()
    p.consume(codexMeta()); p.consume(codexTurn("gpt-5.6-sol"))
    p.consume(r.request(raw: 300_000))   // over 272k: $4 doubled
    #expect(near(p.costEstimate(pricing: pricing).displayDollars, 0.3 * 8))
}

// The lifetime figure was summed from `requestLog`, which the checkpoint trims
// to about a day — so after any restart a rollout's cost silently shrank to
// just its recent requests.
@Test func codexLifetimeCostSurvivesACheckpointRestore() throws {
    let now = Calendar.current.startOfDay(for: t0).addingTimeInterval(12 * 3600)
    var r = CodexRollout(); var p = CodexRolloutParser()
    p.consume(codexMeta()); p.consume(codexTurn("gpt-5.6-sol"))
    p.consume(r.request(at: now.addingTimeInterval(-3 * 86_400), raw: 100_000))   // $0.40, days ago
    p.consume(r.request(at: now, raw: 100_000))                                    // $0.40, today
    let restored = try JSONDecoder().decode(CodexRolloutParser.self,
                                            from: JSONEncoder().encode(p.checkpointSnapshot(now: now)))
    #expect(near(restored.costEstimate(pricing: pricing).displayDollars, 0.80))
    #expect(near(restored.costEstimateToday(pricing: pricing, now: now).displayDollars, 0.40))
}

@Test func aCodexRequestOnAnUnpricedModelMakesTheRolloutPartial() {
    var r = CodexRollout(); var p = CodexRolloutParser()
    p.consume(codexMeta())
    p.consume(codexTurn("gpt-5.6-sol")); p.consume(r.request(raw: 100_000))
    p.consume(codexTurn("gpt-7-nova"));  p.consume(r.request(raw: 100_000))
    let e = p.costEstimate(pricing: pricing)
    #expect(near(e.displayDollars, 0.40))
    #expect(e.isPartial)
}

// MARK: - The shipped table, value by value

private func shipped() throws -> PricingTable {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try PricingTable.load(from: root.appendingPathComponent("Resources/pricing.json"))
}

/// in, out, cache read, 5-minute write, 1-hour write — per MTok.
private func expectClaude(_ t: PricingTable, _ id: String,
                          _ i: Double, _ o: Double, _ cr: Double, _ w5: Double, _ w1: Double,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let r = RateKey(model: id)
    #expect(near(t.cost(for: TokenStats(input: M), rate: r), i), "\(id) input", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(output: M), rate: r), o), "\(id) output", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(cacheRead: M), rate: r), cr), "\(id) cache read", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(cacheWrite: M), rate: r), w5), "\(id) 5m write", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(cacheWrite: M, cacheWrite1h: M), rate: r), w1), "\(id) 1h write", sourceLocation: sourceLocation)
}

// The earlier shipped-file test only asserted that models were PRESENT, never
// what they cost — which is precisely how a Sonnet 5 price 50% too high passed
// it for a month. These are the official figures, one assertion per rate.
@Test func shippedClaudeRatesMatchTheOfficialPriceList() throws {
    let t = try shipped()
    expectClaude(t, "claude-fable-5-1",  10, 50, 0.25, 12.5, 20)
    expectClaude(t, "claude-mythos-5-1", 10, 50, 0.25, 12.5, 20)
    expectClaude(t, "claude-fable-5",    10, 50, 1.0,  12.5, 20)
    expectClaude(t, "claude-opus-5-5",    4, 20, 0.20,  5,    8)
    expectClaude(t, "claude-opus-5",      5, 25, 0.5,   6.25, 10)
    expectClaude(t, "claude-opus-4-8",    5, 25, 0.5,   6.25, 10)
    expectClaude(t, "claude-opus-4-7",    5, 25, 0.5,   6.25, 10)
    // Announced as introductory through 2026-08-31, then made permanent — the
    // scheduled rise to $3/$15 was cancelled. The old table charged $3/$15.
    expectClaude(t, "claude-sonnet-5",    2, 10, 0.2,   2.5,  4)
    expectClaude(t, "claude-sonnet-4-6",  3, 15, 0.3,   3.75, 6)
    expectClaude(t, "claude-haiku-4-5",   1,  5, 0.1,   1.25, 2)
    expectClaude(t, "claude-haiku-4-5-20251001", 1, 5, 0.1, 1.25, 2)
    // Bare aliases resolve to the current default of their tier.
    expectClaude(t, "opus",   5, 25, 0.5, 6.25, 10)
    expectClaude(t, "sonnet", 2, 10, 0.2, 2.5,  4)
    expectClaude(t, "haiku",  1,  5, 0.1, 1.25, 2)

    // Fast mode exists only on these three.
    for id in ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"] {
        #expect(near(t.cost(for: TokenStats(input: M), rate: RateKey(model: id, fast: true)),
                     2 * (t.models[id]?.inputPerMTok ?? .nan)), "\(id) fast mode")
    }
    #expect(t.cost(for: TokenStats(input: M), rate: RateKey(model: "claude-opus-4-7", fast: true)) == nil,
            "Opus 4.7 has no fast mode")
    // US-only inference is 4.6-and-later; Haiku 4.5 rejects the parameter outright.
    #expect(near(t.cost(for: TokenStats(input: M), rate: RateKey(model: "claude-sonnet-5", usGeo: true)), 2.2))
    #expect(t.cost(for: TokenStats(input: M), rate: RateKey(model: "claude-haiku-4-5", usGeo: true)) == nil)

    #expect(t.contextWindow(for: "claude-opus-5-5") == 1_000_000)
    #expect(t.contextWindow(for: "claude-fable-5-1") == 1_000_000)
}

/// in, out, cached read, cache write — per MTok, standard tier, short context.
private func expectCodex(_ t: PricingTable, _ id: String,
                         _ i: Double, _ o: Double, _ cr: Double, _ w: Double,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    let r = RateKey(model: id)
    #expect(near(t.cost(for: TokenStats(input: M), rate: r), i), "\(id) input", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(output: M), rate: r), o), "\(id) output", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(cacheRead: M), rate: r), cr), "\(id) cached", sourceLocation: sourceLocation)
    #expect(near(t.cost(for: TokenStats(cacheWrite: M), rate: r), w), "\(id) cache write", sourceLocation: sourceLocation)
}

@Test func shippedCodexRatesMatchTheOfficialPriceList() throws {
    let t = try shipped()
    expectCodex(t, "gpt-6-astra",   10,   50,   1.0,  12.5)
    expectCodex(t, "gpt-6-sol",      2,   10,   0.2,   2.5)
    expectCodex(t, "gpt-6-luna",     0.1,  0.5, 0.01,  0.125)
    // Promotional, "available at least through November 21, 2026". The old
    // table still charged $5/$30.
    expectCodex(t, "gpt-5.6-sol",    4,   20,   0.4,   5)
    expectCodex(t, "gpt-5.6-terra",  2,   12,   0.2,   2.5)
    expectCodex(t, "gpt-5.6-luna",   0.2,  1.2, 0.02,  0.25)
    // OpenAI lists no cache-write charge for GPT-5.5; the old table invented one.
    expectCodex(t, "gpt-5.5",        5,   30,   0.5,   0)

    // Long context: 2x the input side, 1.5x output, above the threshold.
    let astra = try #require(t.cost(for: TokenStats(input: M, output: M), rate: RateKey(model: "gpt-6-astra"),
                                    requestInputTokens: 300_000))
    #expect(near(astra, 20 + 75))
}
