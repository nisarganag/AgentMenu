import Testing
import Foundation
@testable import AgentMenuCore

private let json = """
{
  "models": {
    "claude-opus-5": {
      "inputPerMTok": 5.0, "outputPerMTok": 25.0,
      "cacheReadPerMTok": 0.5, "cacheWritePerMTok": 6.25,
      "contextWindow": 200000
    }
  }
}
""".data(using: .utf8)!

@Test func computesCostFromPerMillionRates() throws {
    let table = try PricingTable.decode(json)
    let t = TokenStats(input: 1_000_000, output: 1_000_000,
                       cacheRead: 1_000_000, cacheWrite: 1_000_000)
    let cost = try #require(table.cost(for: t, model: "claude-opus-5"))
    #expect(abs(cost - 36.75) < 0.0001)
}

@Test func returnsNilForUnknownModelRatherThanGuessing() throws {
    let table = try PricingTable.decode(json)
    #expect(table.cost(for: TokenStats(input: 100), model: "some-future-model") == nil)
    #expect(table.contextWindow(for: "some-future-model") == nil)
}

@Test func readsContextWindowForKnownModel() throws {
    let table = try PricingTable.decode(json)
    #expect(table.contextWindow(for: "claude-opus-5") == 200_000)
}

@Test func loadsFromFile() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent("pricing-\(UUID().uuidString).json")
    try json.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let table = try PricingTable.load(from: tempFile)
    #expect(table.contextWindow(for: "claude-opus-5") == 200_000)
}

@Test func windowOnlyEntryReportsNoCostRatherThanZero() throws {
    let table = try PricingTable.decode(#"""
    {"models":{"kimi-k3":{"contextWindow":1048576}}}
    """#.data(using: .utf8)!)
    // opencode reports real cost natively; a window-only entry must not claim $0.00.
    #expect(table.cost(for: TokenStats(input: 1_000_000), model: "kimi-k3") == nil)
    #expect(table.contextWindow(for: "kimi-k3") == 1_048_576)
}

@Test func rateOnlyEntryReportsCostButNoWindow() throws {
    let table = try PricingTable.decode(#"""
    {"models":{"gpt-5.6-sol":{"inputPerMTok":5.0,"outputPerMTok":30.0}}}
    """#.data(using: .utf8)!)
    // Codex supplies its own window; absence here must not fabricate one.
    #expect(table.contextWindow(for: "gpt-5.6-sol") == nil)
    let cost = try #require(table.cost(for: TokenStats(input: 1_000_000, output: 1_000_000),
                                       model: "gpt-5.6-sol"))
    #expect(abs(cost - 35.0) < 0.0001)
}

@Test func partialRatesTreatMissingBucketsAsZeroNotNil() throws {
    let table = try PricingTable.decode(#"""
    {"models":{"m":{"inputPerMTok":2.0}}}
    """#.data(using: .utf8)!)
    let cost = try #require(table.cost(for: TokenStats(input: 1_000_000, cacheRead: 5_000_000),
                                       model: "m"))
    #expect(abs(cost - 2.0) < 0.0001)
}

@Test func shippedPricingFileCoversEveryModelInActualUse() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AgentMenuCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    let table = try PricingTable.load(from:
        repoRoot.appendingPathComponent("Resources/pricing.json"))

    // Claude: needs BOTH rates and a window.
    for id in ["claude-fable-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
               "claude-sonnet-5", "claude-haiku-4-5", "opus", "sonnet", "haiku"] {
        #expect(table.contextWindow(for: id) != nil, "\(id) needs a context window")
        #expect(table.cost(for: TokenStats(input: 1000), model: id) != nil, "\(id) needs rates")
    }
    // Opus family is 1M context, not 200K — a wrong window makes every meter wrong.
    #expect(table.contextWindow(for: "claude-opus-5") == 1_000_000)
    #expect(table.contextWindow(for: "claude-haiku-4-5") == 200_000)

    // Codex: rates required, window deliberately absent.
    for id in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"] {
        #expect(table.cost(for: TokenStats(input: 1000), model: id) != nil, "\(id) needs rates")
        #expect(table.contextWindow(for: id) == nil, "\(id) window comes from the rollout")
    }

    // opencode: window required (cost is native to opencode's own DB).
    #expect(table.contextWindow(for: "deepseek-v4-pro") == 1_000_000)
    #expect(table.contextWindow(for: "kimi-k3") == 1_048_576)

    // Not billable models — must stay absent so they render "—".
    #expect(table.cost(for: TokenStats(input: 1000), model: "<synthetic>") == nil)
    #expect(table.cost(for: TokenStats(input: 1000), model: "codex-auto-review") == nil)
}
