import SwiftUI

// MARK: - 5-Hour Window Card (Gauge + Momentum)

struct FiveHourCard: View {
    let window: UsageWindow
    var momentum: MomentumCalculation?
    var burstSummary: BurstSummary?

    private var gaugeColor: Color {
        if window.percentUsed > 80 { return .red }
        if window.percentUsed > 60 { return .orange }
        if window.percentUsed > 40 { return .blue }
        return .teal
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 16) {
                // MARK: Gauge

                Text("5-Hour Window")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Gauge(value: window.percentUsed / 100) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(window.percentUsed))%")
                        .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeColor.gradient)
                .scaleEffect(1.6)
                .frame(width: 88, height: 88)

                Text("Resets \(DateFormatting.resetCountdown(from: window.resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // MARK: Momentum Details

                Divider()
                    .padding(.horizontal, 4)

                velocitySection

                etaSection

                burstBadgeSection
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Velocity

    private var velocitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Burn Rate")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let momentum {
                    Text(momentum.intensity.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ThemeColors.intensityColor(momentum.intensity))
                } else {
                    Text("—")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary.opacity(0.3))

                    if let momentum {
                        Capsule()
                            .fill(ThemeColors.intensityGradient(momentum.intensity))
                            .frame(width: max(0, geo.size.width * min(momentum.velocity / 50, 1)))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            HStack {
                if let momentum {
                    Text(Formatting.pace(momentum.velocity))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("— pp/hr")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let momentum, momentum.acceleration != 0 {
                    HStack(spacing: 3) {
                        Image(systemName: momentum.acceleration > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text(momentum.acceleration > 0 ? "Accelerating" : "Decelerating")
                            .font(.caption)
                    }
                    .foregroundStyle(momentum.acceleration > 0 ? .orange : .green)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burn rate")
        .accessibilityValue(momentum.map {
            "\($0.intensity.label), \($0.acceleration > 0 ? "accelerating" : $0.acceleration < 0 ? "decelerating" : "steady")"
        } ?? "No data")
    }

    // MARK: - ETA

    private var etaSection: some View {
        HStack(spacing: 8) {
            if let momentum, momentum.etaToCeiling != nil {
                Image(systemName: momentum.resetsFirst ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(momentum.resetsFirst ? .green : .orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    if momentum.resetsFirst {
                        Text("Window resets before cap")
                            .font(.subheadline.weight(.medium))
                    } else if let eta = momentum.etaToCeiling {
                        Text(formatETA(eta))
                            .font(.subheadline.weight(.medium))
                        Text("May hit rate limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text("No cap estimate")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 24 {
            return "\(hours / 24)d \(hours % 24)h to cap"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m to cap"
        }
        return "\(minutes)m to cap"
    }

    // MARK: - Burst

    private var burstBadgeSection: some View {
        Group {
            if let burst = burstSummary {
                HStack(spacing: 4) {
                    Image(systemName: burstIcon(burst.pattern))
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(burst.pattern.label)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ThemeColors.burstColor(burst.pattern).opacity(0.15), in: Capsule())
                .foregroundStyle(ThemeColors.burstColor(burst.pattern))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Usage pattern: \(burst.pattern.label)")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path")
                        .font(.caption)
                    Text("—")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func burstIcon(_ pattern: BurstSummary.Pattern) -> String {
        switch pattern {
        case .steady: "waveform.path"
        case .bursty: "waveform.badge.magnifyingglass"
        case .spiky: "bolt.fill"
        }
    }
}

// MARK: - 7-Day Window Card (Gauge + Projection)

struct SevenDayCard: View {
    let window: UsageWindow
    var projection: WindowProjection?

    private var displayPercent: Double {
        window.percentUsed
    }

    private var gaugeColor: Color {
        if displayPercent > 80 { return .red }
        if displayPercent > 60 { return .orange }
        if displayPercent > 40 { return .blue }
        return .teal
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 16) {
                // MARK: Gauge

                Text("7-Day Window")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Gauge(value: displayPercent / 100) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(displayPercent))%")
                        .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeColor.gradient)
                .scaleEffect(1.6)
                .frame(width: 88, height: 88)

                Text("Resets \(DateFormatting.resetCountdown(from: window.resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // MARK: Projection Details

                Divider()
                    .padding(.horizontal, 4)

                projectionBarSection
                budgetSectionView
                statusSectionView
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Projection Bar

    private var projectionBarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projected at Reset")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let projection {
                    Text(Formatting.percent(projection.projectedAtReset, decimals: 0))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ThemeColors.projectionColor(projection.status))
                } else {
                    Text("—")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary.opacity(0.3))

                    if let projection {
                        Capsule()
                            .fill(ThemeColors.projectionGradient(projection.status))
                            .frame(width: max(0, geo.size.width * min(projection.projectedAtReset / 100, 1)))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Projected usage at reset")
            .accessibilityValue(projection.map { "\(Int($0.projectedAtReset)) percent, \($0.status.label)" } ?? "No data")
        }
    }

    // MARK: - Budget vs Pace

    private var budgetSectionView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let projection {
                    Text("\(String(format: "%.1f", projection.dailyBudget)) pp/day")
                        .font(.callout.weight(.semibold).monospacedDigit())
                } else {
                    Text("— pp/day")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Current Pace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let projection {
                    Text("\(String(format: "%.1f", projection.dailyProjected)) pp/day")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(paceColor(projection))
                } else {
                    Text("— pp/day")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func paceColor(_ projection: WindowProjection) -> Color {
        guard projection.dailyBudget > 0 else { return .secondary }
        let ratio = projection.dailyProjected / projection.dailyBudget
        if ratio > 1.3 { return .orange }
        if ratio < 0.7 { return .green }
        return .blue
    }

    // MARK: - Status

    private var statusSectionView: some View {
        HStack {
            if let projection {
                Text(projection.status.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ThemeColors.projectionColor(projection.status).opacity(0.15), in: Capsule())
                    .foregroundStyle(ThemeColors.projectionColor(projection.status))

                if let pattern = projection.patternProjection, pattern.isPatternAware {
                    Text(Formatting.percentRange(pattern.optimisticAtReset, pattern.pessimisticAtReset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let projection {
                Text("\(String(format: "%.1f", projection.remainingDays)) days left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("— days left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
