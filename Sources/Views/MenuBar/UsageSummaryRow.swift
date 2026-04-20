import SwiftUI

struct UsageSummaryRow: View {
    let account: Account
    var momentum: MomentumCalculation?
    var projection: WindowProjection?
    var dailyTarget: BudgetEngine.DailyTarget?

    var body: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 2)
            if let error = account.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Error: \(error)")
            }

            if let dailyTarget, dailyTarget.isActiveDay {
                GlassCard {
                    targetRow(target: dailyTarget)
                }
            }

            if let fiveHour = account.fiveHour {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("5-hour window")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        usageBar(window: fiveHour)
                        Text(paceSubtitle(window: fiveHour, showReset: true))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let momentum {
                            Divider()
                            momentumRow(momentum: momentum)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let sevenDay = account.sevenDay {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("7-day window")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        usageBar(window: sevenDay)
                        Text(paceSubtitle(window: sevenDay, showReset: false))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let projection {
                            Divider()
                            projectionRow(projection: projection)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if account.fiveHour == nil && account.sevenDay == nil && account.lastError == nil {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading usage data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func paceSubtitle(window: UsageWindow, showReset: Bool) -> String {
        let pace = PaceCalculation(window: window)
        let paceText: String
        if abs(pace.delta) < 1 {
            paceText = "On pace"
        } else if pace.isOverpacing {
            paceText = "Over pace"
        } else {
            paceText = "Under pace"
        }
        if showReset {
            let reset = DateFormatting.resetCountdown(from: window.resetsAt)
            return "\(paceText) · Resets in \(reset)"
        }
        return paceText
    }

    private func usageBar(window: UsageWindow) -> some View {
        let displayPercent = window.percentUsed
        let displayNormalized = displayPercent / 100
        let windowLabel = window.duration <= 18001 ? "5-hour" : "7-day"
        return HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary.opacity(0.3))
                    Capsule()
                        .fill(barGradient(for: displayNormalized))
                        .frame(width: max(0, geo.size.width * displayNormalized))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text("\(Int(displayPercent))%")
                .font(.caption2.monospacedDigit().weight(.medium))
                .frame(width: 30, alignment: .trailing)
            PaceIndicator(window: window)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(windowLabel) usage")
        .accessibilityValue("\(Int(displayPercent)) percent")
    }

    private func barGradient(for utilization: Double) -> some ShapeStyle {
        if utilization > 0.8 { return AnyShapeStyle(.red.gradient) }
        if utilization > 0.5 { return AnyShapeStyle(.orange.gradient) }
        return AnyShapeStyle(.green.gradient)
    }

    private func momentumRow(momentum: MomentumCalculation) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: velocityIcon(for: momentum))
                    .font(.caption2)
                    .foregroundStyle(ThemeColors.intensityColor(momentum.intensity))
                    .accessibilityHidden(true)
                Text(velocityText(for: momentum))
                    .font(.caption2.monospacedDigit().weight(.medium))
            }
            Spacer()
            if let etaText = etaLabel(for: momentum) {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(etaText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if momentum.resetsFirst, momentum.etaToCeiling != nil {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Resets before cap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func projectionRow(projection: WindowProjection) -> some View {
        HStack {
            Text("Projected at reset")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if let pattern = projection.patternProjection, pattern.isPatternAware {
                Text("\(Int(projection.projectedAtReset))% (\(Int(pattern.optimisticAtReset))–\(Int(pattern.pessimisticAtReset)))")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(ThemeColors.projectionColor(projection.status))
            } else {
                Text("\(Int(projection.projectedAtReset))%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(ThemeColors.projectionColor(projection.status))
            }
        }
    }

    private func velocityIcon(for momentum: MomentumCalculation) -> String {
        switch momentum.intensity {
        case .idle: "minus"
        case .steady: "arrow.right"
        case .moderate: "arrow.up.right"
        case .high: "arrow.up"
        case .burning: "flame"
        }
    }

    private func velocityText(for momentum: MomentumCalculation) -> String {
        if momentum.velocity < 0.1 { return "Idle" }
        return Formatting.pace(momentum.velocity, decimals: 0)
    }

    private func etaLabel(for momentum: MomentumCalculation) -> String? {
        guard let eta = momentum.etaToCeiling else { return nil }
        // When the window resets before cap, don't show a misleading ETA
        if momentum.resetsFirst { return nil }
        if eta < 60 { return "<1m to cap" }
        let hours = Int(eta) / 3600
        let minutes = (Int(eta) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m to cap" }
        return "\(minutes)m to cap"
    }

    private func targetRow(target: BudgetEngine.DailyTarget) -> some View {
        HStack {
            Image(systemName: "target")
                .font(.caption2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("Target \(Formatting.percent(target.currentTarget))")
                .font(.caption2.weight(.medium))
            if target.currentTarget != target.targetUtilization {
                Text("→ \(Formatting.percent(target.targetUtilization))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(target.status.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(ThemeColors.targetStatusColor(target.status))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily target \(Int(target.currentTarget)) percent, \(target.status.label)")
    }

}
