import Foundation
import Testing
@testable import WillDeep

@Suite("Model reference prices and gateway accounting")
struct AgentModelPricingTests {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test("DeepSeek UTC boundaries, weekends and Chinese holidays", arguments: [
        ("2026-10-26T00:59:59Z", true), ("2026-10-26T01:00:00Z", false),
        ("2026-10-26T03:59:59Z", false), ("2026-10-26T04:00:00Z", true),
        ("2026-10-26T06:00:00Z", false), ("2026-10-26T10:00:00Z", true),
        ("2026-10-25T02:00:00Z", true), ("2026-10-01T02:00:00Z", true),
        ("2026-10-10T02:00:00Z", true)
    ])
    func deepSeekTimeBands(value: (String, Bool)) {
        #expect(DeepSeekModelPricing.isOffPeak(date(value.0)) == value.1)
    }

    @Test("Pre-change DeepSeek calls retain their historical reference price")
    func historicalPrice() throws {
        let before = try #require(AgentModelPricing.price(providerID: "deepseek", modelID: "deepseek-v4-pro", at: date("2026-08-16T15:59:59Z")))
        let after = try #require(AgentModelPricing.price(providerID: "deepseek", modelID: "deepseek-v4-pro", at: date("2026-08-16T16:00:00Z")))
        #expect(before.inputPerMillion == 0.435)
        #expect(after.inputPerMillion == 0.66)
    }

    @Test("Gateway aliases resolve without guessing future models")
    func aliases() throws {
        let sol = try #require(AgentModelPricing.price(providerID: "custom", modelID: "group/auto-gpt-6-1-sol"))
        #expect(sol.inputPerMillion == 2)
        #expect(sol.cachedInputPerMillion == 0.1)
        let claude = try #require(AgentModelPricing.price(providerID: "magpie", modelID: "claude/claude-opus-4-6"))
        #expect(claude.outputPerMillion == 25)
        let codex = try #require(AgentModelPricing.price(providerID: "custom", modelID: "codex/gpt-5.3-codex"))
        #expect(codex.outputPerMillion == 14)
        #expect(AgentModelPricing.price(providerID: "custom", modelID: "gpt-5.99") == nil)
        #expect(AgentModelPricing.price(providerID: "custom", modelID: "claude-opus-4.99") == nil)
    }

    @Test("Model totals sum per-call DeepSeek charges across time bands")
    func perRequestAggregation() throws {
        let messages = ["2026-10-26T02:00:00Z", "2026-10-26T05:00:00Z"].map { instant in
            AgentMessage(role: .assistant, content: "ok", usageTokens: 2_000_000,
                         promptTokens: 1_000_000, completionTokens: 1_000_000, createdAt: date(instant))
        }
        let session = AgentSession(title: "Price fixture", modelID: "deepseek-v4-flash", messages: messages)
        let row = try #require(AgentUsageStats.modelUsage(for: [session]).first)
        #expect(abs(try #require(row.estimatedCostUSD) - 2.25) < 0.000001)
    }

    @Test("Magpie is remote inference on default and discovered custom ports", arguments: [
        ("http://127.0.0.1:3425/v1", ""), ("http://localhost:4567/v1", "magpie-willdeep"),
        ("http://localhost:4567/v1", "magpie")
    ])
    func magpieClassification(value: (String, String)) {
        let config = AgentConfiguration(providerID: "custom", baseURL: value.0, model: "codex/gpt-6.1-sol",
                                        flashModel: "codex/gpt-6.1-sol", proModel: "codex/gpt-6.1-sol",
                                        routingMode: .flash, imageDescription: .default, apiKey: value.1)
        #expect(!AgentLocalModelPrompting.isLocalProvider(config))
    }

    @Test("Long context threshold applies to the whole request", arguments: [272_000, 272_001])
    func longContext(tokens: Int) throws {
        let price = try #require(AgentModelPricing.price(providerID: "magpie", modelID: "codex/gpt-6-sol", promptTokens: tokens))
        #expect(price.inputPerMillion == (tokens > 272_000 ? 4 : 2))
        #expect(price.cachedInputPerMillion == (tokens > 272_000 ? 0.4 : 0.2))
        #expect(price.outputPerMillion == (tokens > 272_000 ? 15 : 10))
    }

    @Test("Haiku long context includes latest and dated aliases", arguments: [
        "claude-haiku-5.5", "claude-haiku-5-5-latest", "claude/claude-haiku-5.5-20261001"
    ])
    func haikuLongContext(model: String) throws {
        let price = try #require(AgentModelPricing.price(providerID: "magpie", modelID: model, promptTokens: 100_001))
        #expect(price.inputPerMillion == 0.5)
        #expect(price.outputPerMillion == 2.5)
    }
}
