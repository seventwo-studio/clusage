import SwiftUI

/// GitHub-style contribution grid showing daily Claude usage intensity.
struct ActivityGridCard: View {
    let streak: UsageStreak
    let tokenUsageStore: TokenUsageStore?

    private let columns = 13 // weeks to show
    private let rows = 7    // days per week (Mon–Sun)
    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3

    private var gridData: [DayCell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Build a lookup of daily message counts for intensity
        var messageCounts: [String: Int] = [:]
        if let store = tokenUsageStore {
            for summary in store.recentSummaries(days: columns * 7) {
                messageCounts[summary.date] = summary.messageCount
            }
        }

        // Find the max for normalization (exclude outliers by using p90)
        let counts = messageCounts.values.filter { $0 > 0 }.sorted()
        let maxCount = counts.isEmpty ? 1 : counts[min(counts.count - 1, Int(Double(counts.count) * 0.9))]

        // Build grid: columns * 7 days, ending on today
        // Grid fills top-to-bottom (Mon=0, Sun=6), left-to-right (oldest to newest)
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7 // Mon=0
        let totalCells = columns * rows
        let daysBack = totalCells - 1 - todayWeekday

        var cells: [DayCell] = []
        for i in 0..<totalCells {
            let offset = i - (totalCells - 1 - todayWeekday)
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else {
                cells.append(DayCell(date: today, dateKey: "", level: .empty, isToday: false, isFuture: true))
                continue
            }

            let key = UsageStreak.dayKey(for: date)
            let isFuture = date > today
            let isToday = calendar.isDate(date, inSameDayAs: today)
            let isActive = streak.activeDays.contains(key)

            let level: ActivityLevel
            if isFuture {
                level = .empty
            } else if !isActive {
                if let count = messageCounts[key], count > 0 {
                    level = intensityLevel(count: count, max: maxCount)
                } else {
                    level = .none
                }
            } else {
                let count = messageCounts[key] ?? 0
                level = count > 0 ? intensityLevel(count: count, max: maxCount) : .low
            }

            cells.append(DayCell(date: date, dateKey: key, level: level, isToday: isToday, isFuture: isFuture))
        }

        return cells
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    if streak.currentStreak > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text("\(streak.currentStreak) day streak")
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        Text("Activity")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    if streak.longestStreak > streak.currentStreak {
                        Text("Best: \(streak.longestStreak) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if streak.currentStreak > 1 {
                        Text("Personal best!")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Month labels
                monthLabels

                HStack(alignment: .top, spacing: 0) {
                    // Day labels
                    dayLabels

                    // Grid
                    let data = gridData
                    Grid(horizontalSpacing: cellSpacing, verticalSpacing: cellSpacing) {
                        ForEach(0..<rows, id: \.self) { row in
                            GridRow {
                                ForEach(0..<columns, id: \.self) { col in
                                    let index = col * rows + row
                                    if index < data.count {
                                        cellView(for: data[index])
                                    }
                                }
                            }
                        }
                    }
                }

                // Legend
                HStack(spacing: 4) {
                    Spacer()
                    Text("Less")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    ForEach(ActivityLevel.allCases, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level.color)
                            .frame(width: 10, height: 10)
                    }
                    Text("More")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                // Stats row
                statsRow
            }
        }
    }

    // MARK: - Month Labels

    private var monthLabels: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        let totalCells = columns * rows
        let firstDate = calendar.date(byAdding: .day, value: -(totalCells - 1 - todayWeekday), to: today)!

        // Compute which column each month starts in
        let dayLabelWidth: CGFloat = 22
        let columnWidth = cellSize + cellSpacing

        var monthMarkers: [(String, CGFloat)] = []
        var lastMonth = -1
        for col in 0..<columns {
            let dayOffset = col * rows
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: firstDate) else { continue }
            let month = calendar.component(.month, from: date)
            if month != lastMonth {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                let label = formatter.string(from: date)
                let x = dayLabelWidth + CGFloat(col) * columnWidth
                monthMarkers.append((label, x))
                lastMonth = month
            }
        }

        return ZStack(alignment: .leading) {
            ForEach(Array(monthMarkers.enumerated()), id: \.offset) { _, marker in
                Text(marker.0)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: marker.1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 12)
    }

    // MARK: - Day Labels

    private var dayLabels: some View {
        VStack(spacing: cellSpacing) {
            ForEach(0..<rows, id: \.self) { row in
                if row == 0 || row == 2 || row == 4 {
                    Text(dayAbbrev(row))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: cellSize, alignment: .trailing)
                } else {
                    Color.clear
                        .frame(width: 18, height: cellSize)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func dayAbbrev(_ row: Int) -> String {
        switch row {
        case 0: "Mon"
        case 2: "Wed"
        case 4: "Fri"
        default: ""
        }
    }

    // MARK: - Cell

    private func cellView(for cell: DayCell) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(cell.level.color)
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if cell.isToday {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.primary.opacity(0.4), lineWidth: 1)
                }
            }
            .help(cell.isFuture ? "" : cellTooltip(cell))
    }

    private func cellTooltip(_ cell: DayCell) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let dateStr = formatter.string(from: cell.date)
        if let store = tokenUsageStore,
           let summary = store.recentSummaries(days: columns * 7).first(where: { $0.date == cell.dateKey }),
           summary.messageCount > 0 {
            let cost = store.costForSummary(summary)
            return "\(summary.messageCount) messages ($\(String(format: "%.0f", cost))) on \(dateStr)"
        }
        return cell.level == .none ? "No activity on \(dateStr)" : dateStr
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let activeDaysCount = streak.activeDays.count
        let totalDays = columns * 7
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        let pastDays = (columns - 1) * rows + todayWeekday + 1

        return HStack {
            Text("\(activeDaysCount) active days in the last \(pastDays) days")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func intensityLevel(count: Int, max: Int) -> ActivityLevel {
        guard max > 0, count > 0 else { return .none }
        let ratio = Double(count) / Double(max)
        if ratio > 0.75 { return .high }
        if ratio > 0.4 { return .medium }
        if ratio > 0.15 { return .low }
        return .low
    }
}

// MARK: - Data Types

private struct DayCell {
    let date: Date
    let dateKey: String
    let level: ActivityLevel
    let isToday: Bool
    let isFuture: Bool
}

enum ActivityLevel: CaseIterable {
    case none, low, medium, high

    var color: Color {
        switch self {
        case .none: .primary.opacity(0.06)
        case .low: .green.opacity(0.3)
        case .medium: .green.opacity(0.6)
        case .high: .green
        }
    }

    // Used for future/padding cells
    static var empty: ActivityLevel { .none }
}
