import SwiftUI

/// GitHub-style contribution grid showing daily Claude usage intensity.
struct ActivityGridCard: View {
    let streak: UsageStreak
    let tokenUsageStore: TokenUsageStore?

    private let rows = 7    // days per week (Mon–Sun)
    private let dayLabelWidth: CGFloat = 24
    private let minCellSpacing: CGFloat = 3

    private func columns(for availableWidth: CGFloat) -> Int {
        // Calculate how many columns fit at a reasonable cell size
        let gridWidth = availableWidth - dayLabelWidth - minCellSpacing
        // Aim for cells between 10-16px, pick column count that fills nicely
        let idealCellSize: CGFloat = 13
        let cols = Int(gridWidth / (idealCellSize + minCellSpacing))
        return max(cols, 8)
    }

    private func gridMetrics(for availableWidth: CGFloat) -> (columns: Int, cellSize: CGFloat, spacing: CGFloat) {
        let cols = columns(for: availableWidth)
        let gridWidth = availableWidth - dayLabelWidth - minCellSpacing
        // Distribute space evenly: total = cols * cellSize + (cols - 1) * spacing
        // With spacing = minCellSpacing, cellSize = (gridWidth - (cols-1)*spacing) / cols
        let spacing = minCellSpacing
        let cellSize = (gridWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        return (cols, max(cellSize, 4), spacing)
    }

    private func gridData(columns: Int) -> [DayCell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var messageCounts: [String: Int] = [:]
        if let store = tokenUsageStore {
            for summary in store.recentSummaries(days: columns * 7) {
                messageCounts[summary.date] = summary.messageCount
            }
        }

        let counts = messageCounts.values.filter { $0 > 0 }.sorted()
        let maxCount = counts.isEmpty ? 1 : counts[min(counts.count - 1, Int(Double(counts.count) * 0.9))]

        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7 // Mon=0
        let totalCells = columns * rows

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

                GeometryReader { geo in
                    let metrics = gridMetrics(for: geo.size.width)
                    let data = gridData(columns: metrics.columns)

                    VStack(alignment: .leading, spacing: 4) {
                        // Month labels
                        monthLabels(columns: metrics.columns, cellSize: metrics.cellSize, spacing: metrics.spacing)

                        HStack(alignment: .top, spacing: 0) {
                            // Day labels
                            dayLabels(cellSize: metrics.cellSize, spacing: metrics.spacing)

                            // Grid
                            VStack(spacing: metrics.spacing) {
                                ForEach(0..<rows, id: \.self) { row in
                                    HStack(spacing: metrics.spacing) {
                                        ForEach(0..<metrics.columns, id: \.self) { col in
                                            let index = col * rows + row
                                            if index < data.count {
                                                cellView(for: data[index], size: metrics.cellSize)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: gridHeight)

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

    /// Estimated grid height (month labels + 7 rows of cells + spacing).
    private var gridHeight: CGFloat {
        let estimatedCellSize: CGFloat = 13
        return 12 + 4 + CGFloat(rows) * estimatedCellSize + CGFloat(rows - 1) * minCellSpacing
    }

    // MARK: - Month Labels

    private func monthLabels(columns: Int, cellSize: CGFloat, spacing: CGFloat) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        let totalCells = columns * rows
        let firstDate = calendar.date(byAdding: .day, value: -(totalCells - 1 - todayWeekday), to: today)!

        let columnWidth = cellSize + spacing

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
                let x = dayLabelWidth + minCellSpacing + CGFloat(col) * columnWidth
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

    private func dayLabels(cellSize: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                if row == 0 || row == 2 || row == 4 {
                    Text(dayAbbrev(row))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: dayLabelWidth - minCellSpacing, height: cellSize, alignment: .trailing)
                } else {
                    Color.clear
                        .frame(width: dayLabelWidth - minCellSpacing, height: cellSize)
                }
            }
        }
        .padding(.trailing, minCellSpacing)
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

    private func cellView(for cell: DayCell, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(cell.level.color)
            .frame(width: size, height: size)
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
           let summary = store.dailySummaries.first(where: { $0.date == cell.dateKey }),
           summary.messageCount > 0 {
            let cost = store.costForSummary(summary)
            return "\(summary.messageCount) messages ($\(String(format: "%.0f", cost))) on \(dateStr)"
        }
        return cell.level == .none ? "No activity on \(dateStr)" : dateStr
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let activeDaysCount = streak.activeDays.count
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        // Use a fixed estimate for display since actual columns depend on width
        let pastDays = 12 * rows + todayWeekday + 1

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

    static var empty: ActivityLevel { .none }
}
