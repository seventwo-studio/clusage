import SwiftUI

struct AccountDetailView: View {
    let account: Account
    let snapshots: [UsageSnapshot]
    var gaps: [MonitoringGap] = []
    var momentum: MomentumCalculation?
    var burstSummary: BurstSummary?
    var streak: UsageStreak?
    var projection: WindowProjection?
    var dailyTarget: BudgetEngine.DailyTarget?
    var hasScheduleOverride: Bool = false
    var onScheduleOverride: ((DaySlot?) -> Void)?
    var pollState: UsagePoller.PollState?
    var rateLimitSecondsRemaining: TimeInterval?
    var tokenUsageStore: TokenUsageStore?
    var onRefresh: (() async -> Void)?

    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if pollState == .rateLimited {
                    rateLimitBanner
                }

                if let dailyTarget {
                    DailyTargetCard(
                        target: dailyTarget,
                        currentUtilization: account.sevenDay?.utilization ?? 0,
                        streak: streak,
                        currentVelocity: projection?.sevenDayVelocity ?? 0,
                        hasOverride: hasScheduleOverride,
                        onOverride: onScheduleOverride
                    )
                }

                windowCards

                if let tokenUsageStore {
                    TokenInsightsCard(store: tokenUsageStore)
                }

                if !snapshots.isEmpty {
                    GlassCard {
                        UnifiedChartView(
                            snapshots: snapshots,
                            gaps: gaps,
                            momentum: momentum,
                            projection: projection,
                            fiveHourWindow: account.fiveHour,
                            sevenDayWindow: account.sevenDay,
                            usagePlan: account.usagePlan,
                            dailyTarget: dailyTarget
                        )
                    }
                }

                if let streak {
                    ActivityGridCard(
                        streak: streak,
                        tokenUsageStore: tokenUsageStore
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle(account.displayName)
        .navigationSubtitle(account.lastUpdated.map { "Updated \(DateFormatting.relativeTime(from: $0))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await onRefresh?()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .disabled(isRefreshing)
                .accessibilityLabel(isRefreshing ? "Refreshing usage data" : "Refresh usage data")
                .help("Refresh usage data")
            }
        }
    }

    // MARK: - Rate Limit Banner

    private var rateLimitBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rate Limited")
                    .font(.callout.weight(.medium))
                if let remaining = rateLimitSecondsRemaining, remaining > 0 {
                    Text("Polling paused — retrying in \(formatCooldown(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Polling paused — waiting for cooldown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func formatCooldown(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    // MARK: - Window Cards

    @ViewBuilder
    private var windowCards: some View {
        if account.fiveHour != nil || account.sevenDay != nil {
            HStack(alignment: .top, spacing: 16) {
                if let fiveHour = account.fiveHour {
                    FiveHourCard(
                        window: fiveHour,
                        momentum: momentum,
                        burstSummary: burstSummary
                    )
                    .frame(maxWidth: .infinity)
                }

                if let sevenDay = account.sevenDay {
                    SevenDayCard(
                        window: sevenDay,
                        projection: projection
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        } else if let error = account.lastError {
            GlassCard {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        } else {
            GlassCard {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading usage data...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

}
