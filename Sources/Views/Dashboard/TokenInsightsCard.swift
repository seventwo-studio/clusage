import SwiftUI

struct TokenInsightsCard: View {
    let store: TokenUsageStore

    private var today: TokenUsageSummary? { store.today }
    private var todayCost: Double { today.map { store.costForSummary($0) } ?? 0 }
    private var sevenDayCost: Double { store.cost(lastDays: 7) }

    var body: some View {
        GlassCard {
            VStack(spacing: 16) {
                Text("API Cost Equivalent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Cost headline
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("$")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(formatCost(todayCost))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                    Text(" today")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Divider()

                // Period breakdown
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("7-Day Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$\(formatCost(sevenDayCost))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .center, spacing: 4) {
                        Text("Daily Avg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$\(formatCost(store.averageDailyCost(lastDays: 7)))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("30-Day Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$\(formatCost(store.cost(lastDays: 30)))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }

                // Token breakdown by model
                if let summary = today, !summary.models.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Today by Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(summary.models.sorted(by: { TokenPricing.cost(model: $0.key, tokens: $0.value) > TokenPricing.cost(model: $1.key, tokens: $1.value) }), id: \.key) { model, tokens in
                            modelRow(model: model, tokens: tokens)
                        }
                    }
                }

                // Messages today
                if let summary = today, summary.messageCount > 0 {
                    HStack {
                        Label("\(summary.messageCount) messages", systemImage: "message")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatTokenCount(summary.totalTokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Model Row

    private func modelRow(model: String, tokens: ModelTokens) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(shortModelName(model))
                    .font(.caption.weight(.medium))
                Spacer()
                Text("$\(formatCost(TokenPricing.cost(model: model, tokens: tokens)))")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }

            HStack(spacing: 12) {
                tokenPill("In", count: tokens.inputTokens, color: .blue)
                tokenPill("Out", count: tokens.outputTokens, color: .green)
                tokenPill("Cache R", count: tokens.cacheReadInputTokens, color: .teal)
                tokenPill("Cache W", count: tokens.cacheCreationInputTokens, color: .orange)
                Spacer()
            }
        }
    }

    private func tokenPill(_ label: String, count: Int, color: Color) -> some View {
        Group {
            if count > 0 {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(count))
                        .font(.system(size: 9, design: .monospaced))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.1), in: Capsule())
                .foregroundStyle(color)
            }
        }
    }

    // MARK: - Formatting

    private func formatCost(_ cost: Double) -> String {
        if cost >= 100 {
            return String(format: "%.0f", cost)
        } else if cost >= 10 {
            return String(format: "%.1f", cost)
        }
        return String(format: "%.2f", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
