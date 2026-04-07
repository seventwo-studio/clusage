import Foundation

/// Token counts from a single Claude API response.
struct TokenUsage: Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }
}

/// Aggregated token usage for a time period, broken down by model.
struct TokenUsageSummary: Codable, Sendable, Identifiable {
    let id: UUID
    let date: String // "yyyy-MM-dd"
    var models: [String: ModelTokens]
    var messageCount: Int
    var sessionCount: Int

    /// Total tokens across all models.
    var totalTokens: Int {
        models.values.reduce(0) { $0 + $1.totalTokens }
    }

    init(date: String) {
        self.id = UUID()
        self.date = date
        self.models = [:]
        self.messageCount = 0
        self.sessionCount = 0
    }
}

/// Per-model token accumulator with cost calculation.
struct ModelTokens: Codable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    mutating func add(_ usage: TokenUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadInputTokens += usage.cacheReadInputTokens
        cacheCreationInputTokens += usage.cacheCreationInputTokens
    }

}

/// Pricing per million tokens for each model tier.
enum TokenPricing {
    struct ModelPrice {
        let input: Double        // $ per 1M tokens
        let output: Double       // $ per 1M tokens
        let cacheRead: Double    // $ per 1M tokens
        let cacheWrite: Double   // $ per 1M tokens

        func cost(for tokens: ModelTokens) -> Double {
            let inputCost = Double(tokens.inputTokens) / 1_000_000 * input
            let outputCost = Double(tokens.outputTokens) / 1_000_000 * output
            let cacheReadCost = Double(tokens.cacheReadInputTokens) / 1_000_000 * cacheRead
            let cacheWriteCost = Double(tokens.cacheCreationInputTokens) / 1_000_000 * cacheWrite
            return inputCost + outputCost + cacheReadCost + cacheWriteCost
        }
    }

    static let prices: [String: ModelPrice] = [
        "claude-opus-4-6": ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-sonnet-4-5-20250929": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-4-5-20251001": ModelPrice(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
    ]

    /// Look up pricing for a model ID. Falls back to Sonnet pricing for unknown models.
    static func price(for model: String) -> ModelPrice {
        if let exact = prices[model] { return exact }
        // Fuzzy match: "claude-opus-4-6" prefix matches
        if model.contains("opus") { return prices["claude-opus-4-6"]! }
        if model.contains("haiku") { return prices["claude-haiku-4-5-20251001"]! }
        // Default to Sonnet pricing
        return ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
    }

    static func cost(model: String, tokens: ModelTokens) -> Double {
        price(for: model).cost(for: tokens)
    }
}
