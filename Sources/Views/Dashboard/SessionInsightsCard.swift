import SwiftUI

/// Shows session-level usage insights: context compounding, cost distribution,
/// and per-session metrics that help users understand how conversation length
/// impacts their rate limit consumption.
struct SessionInsightsCard: View {
    let store: TokenUsageStore

    private var sessions: [SessionSummary] { store.recentSessions(days: 7) }
    private var todaySessions: [SessionSummary] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let todayStr = formatter.string(from: Date())
        return sessions.filter { $0.date == todayStr }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session Insights")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if sessions.isEmpty {
                    Text("No session data yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    // Averages row
                    averagesRow

                    Divider()

                    // Context compounding section
                    compoundingSection

                    // Today's sessions
                    if !todaySessions.isEmpty {
                        Divider()
                        todaySessionsList
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Averages

    private var averagesRow: some View {
        HStack(spacing: 0) {
            statColumn(
                label: "Avg Session",
                value: formatCost(store.averageSessionCost),
                prefix: "$"
            )
            Spacer()
            statColumn(
                label: "Avg Messages",
                value: String(format: "%.0f", store.averageMessagesPerSession),
                alignment: .center
            )
            Spacer()
            statColumn(
                label: "Context Growth",
                value: String(format: "%.1fx", store.averageCompoundingRatio),
                alignment: .trailing
            )
        }
    }

    private func statColumn(label: String, value: String, prefix: String = "", alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
        }
    }

    // MARK: - Context Compounding

    private var compoundingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Context Compounding")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("Last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Distribution of sessions by compounding severity
            let bins = compoundingBins
            HStack(spacing: 3) {
                ForEach(bins, id: \.label) { bin in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bin.color.gradient)
                            .frame(height: max(4, CGFloat(bin.count) / CGFloat(max(sessions.count, 1)) * 40))
                        Text("\(bin.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(bin.count) session(s) with \(bin.label) context growth")
                }
            }
            .frame(height: 56, alignment: .bottom)

            HStack(spacing: 3) {
                ForEach(bins, id: \.label) { bin in
                    Text(bin.label)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Tip
            if store.averageCompoundingRatio > 4 {
                compoundingTip("Sessions grow \(String(format: "%.0fx", store.averageCompoundingRatio)) on average. Use /clear between tasks to save quota.")
            } else if store.averageCompoundingRatio > 2 {
                compoundingTip("Moderate context growth. Long sessions compound fast — consider /compact for big tasks.")
            }
        }
    }

    private struct CompoundingBin: Hashable {
        let label: String
        let color: Color
        let count: Int
    }

    private var compoundingBins: [CompoundingBin] {
        var small = 0, medium = 0, large = 0, huge = 0
        for s in sessions {
            switch s.compoundingRatio {
            case ..<2: small += 1
            case 2..<5: medium += 1
            case 5..<10: large += 1
            default: huge += 1
            }
        }
        return [
            CompoundingBin(label: "<2x", color: .green, count: small),
            CompoundingBin(label: "2-5x", color: .blue, count: medium),
            CompoundingBin(label: "5-10x", color: .orange, count: large),
            CompoundingBin(label: "10x+", color: .red, count: huge),
        ]
    }

    private func compoundingTip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Today's Sessions

    private var todaySessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Sessions")
                .font(.caption.weight(.medium))

            ForEach(todaySessions.sorted(by: { $0.costUSD > $1.costUSD }).prefix(5)) { session in
                sessionRow(session)
            }

            if todaySessions.count > 5 {
                Text("+\(todaySessions.count - 5) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 8) {
            // Context growth bar
            contextBar(session)
                .frame(width: 40, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(session.messageCount) msgs")
                        .font(.caption2.weight(.medium))
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(shortModelName(session.primaryModel))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let dur = session.durationSeconds, dur > 0 {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(formatDuration(dur))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text(formatTokenCount(session.startContextTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                    Text(formatTokenCount(session.endContextTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(compoundingColor(session.compoundingRatio))
                    Text("(\(String(format: "%.1fx", session.compoundingRatio)))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(compoundingColor(session.compoundingRatio))
                }
            }

            Spacer()

            Text("$\(formatCost(session.costUSD))")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    private func contextBar(_ session: SessionSummary) -> some View {
        GeometryReader { geo in
            let ratio = session.peakContextTokens > 0
                ? CGFloat(session.startContextTokens) / CGFloat(session.peakContextTokens)
                : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(compoundingColor(session.compoundingRatio).opacity(0.3))
                RoundedRectangle(cornerRadius: 3)
                    .fill(compoundingColor(session.compoundingRatio).gradient)
                    .frame(width: geo.size.width * (1 - ratio) + geo.size.width * ratio * 0.2)
            }
        }
    }

    private func compoundingColor(_ ratio: Double) -> Color {
        if ratio >= 10 { return .red }
        if ratio >= 5 { return .orange }
        if ratio >= 2 { return .blue }
        return .green
    }

    // MARK: - Formatting

    private func formatCost(_ cost: Double) -> String {
        if cost >= 100 { return String(format: "%.0f", cost) }
        if cost >= 10 { return String(format: "%.1f", cost) }
        return String(format: "%.2f", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
