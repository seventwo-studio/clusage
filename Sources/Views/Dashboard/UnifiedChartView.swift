import Charts
import SwiftUI

struct UnifiedChartView: View {
    let snapshots: [UsageSnapshot]
    var gaps: [MonitoringGap] = []
    var momentum: MomentumCalculation?
    var projection: WindowProjection?
    var fiveHourWindow: UsageWindow?
    var sevenDayWindow: UsageWindow?
    var usagePlan: UsagePlan?
    var dailyTarget: BudgetEngine.DailyTarget?

    @State private var hoverDate: Date?
    @State private var now: Date = .now

    // Timeline state
    @State private var visibleCenter: Date = .now
    @State private var visibleSpan: TimeInterval = 24 * 3600
    @State private var gestureSpanAtStart: TimeInterval = 0
    @State private var gestureCenterAtStart: Date = .distantPast
    @State private var isLive = true

    private static let maxChartPoints = 500
    private static let minSpan: TimeInterval = 5 * 60
    private static let maxSpan: TimeInterval = 30 * 86400

    // MARK: - Window Helpers

    private var windowDuration: TimeInterval {
        sevenDayWindow?.duration ?? 7 * 86400
    }

    private var fiveHourDuration: TimeInterval {
        fiveHourWindow?.duration ?? 5 * 3600
    }

    // MARK: - Timeline Bounds

    private var timelineStart: Date {
        snapshots.first?.timestamp ?? now.addingTimeInterval(-7 * 86400)
    }

    private var timelineEnd: Date {
        let windowEnd = sevenDayWindow?.resetsAt ?? now
        return max(now, windowEnd)
    }

    private var totalSpan: TimeInterval {
        max(timelineEnd.timeIntervalSince(timelineStart), Self.minSpan)
    }

    private var dateRange: ClosedRange<Date> {
        let halfSpan = visibleSpan / 2
        var from = visibleCenter.addingTimeInterval(-halfSpan)
        var to = visibleCenter.addingTimeInterval(halfSpan)

        if from < timelineStart {
            from = timelineStart
            to = from.addingTimeInterval(visibleSpan)
        }
        if to > timelineEnd {
            to = timelineEnd
            from = to.addingTimeInterval(-visibleSpan)
            if from < timelineStart { from = timelineStart }
        }

        return from...max(to, from.addingTimeInterval(1))
    }

    private var filteredSnapshots: [UsageSnapshot] {
        let range = dateRange
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }

        // Find the nearest point before and after the visible range so lines
        // extend to the screen edges instead of starting/ending mid-chart.
        let leadIn = sorted.last { $0.timestamp < range.lowerBound }
        let leadOut = sorted.first { $0.timestamp > range.upperBound }

        var base = sorted
            .filter { $0.timestamp >= range.lowerBound && $0.timestamp <= range.upperBound }

        if let leadIn { base.insert(leadIn, at: 0) }
        if let leadOut { base.append(leadOut) }

        guard base.count > Self.maxChartPoints else { return base }

        let bucketCount = Self.maxChartPoints
        let rangeSpan = range.upperBound.timeIntervalSince(range.lowerBound)
        let bucketDuration = rangeSpan / Double(bucketCount)

        var result: [UsageSnapshot] = []
        result.reserveCapacity(bucketCount)
        var bucketStart = range.lowerBound
        var baseIdx = 0

        for _ in 0..<bucketCount {
            let bucketEnd = bucketStart.addingTimeInterval(bucketDuration)
            var sumFive = 0.0, sumSeven = 0.0, count = 0

            while baseIdx < base.count && base[baseIdx].timestamp < bucketEnd {
                sumFive += base[baseIdx].fiveHourUtilization
                sumSeven += base[baseIdx].sevenDayUtilization
                count += 1
                baseIdx += 1
            }

            if count > 0 {
                let midTime = bucketStart.addingTimeInterval(bucketDuration / 2)
                result.append(UsageSnapshot(
                    id: UUID(),
                    accountID: base[0].accountID,
                    timestamp: midTime,
                    fiveHourUtilization: sumFive / Double(count),
                    sevenDayUtilization: sumSeven / Double(count)
                ))
            }
            bucketStart = bucketEnd
        }

        if let last = base.last, result.last?.timestamp != last.timestamp {
            result.append(last)
        }
        return result
    }

    // MARK: - Reset Dates in Range

    /// All 7-day reset dates that fall within the visible range.
    private var sevenDayResetsInRange: [Date] {
        guard let sevenDay = sevenDayWindow else { return [] }
        let range = dateRange
        var resets: [Date] = []

        // Walk backward from the known reset date
        var cursor = sevenDay.resetsAt
        while cursor > range.lowerBound {
            if cursor >= range.lowerBound && cursor <= range.upperBound {
                resets.append(cursor)
            }
            cursor = cursor.addingTimeInterval(-sevenDay.duration)
        }

        // Walk forward (in case window extends past now)
        cursor = sevenDay.resetsAt.addingTimeInterval(sevenDay.duration)
        while cursor <= range.upperBound {
            if cursor >= range.lowerBound {
                resets.append(cursor)
            }
            cursor = cursor.addingTimeInterval(sevenDay.duration)
        }

        return resets.sorted()
    }

    /// All 5-hour reset dates that fall within the visible range (only when zoomed in).
    private var fiveHourResetsInRange: [Date] {
        guard visibleSpan < 2 * 86400,
              let fiveHour = fiveHourWindow
        else { return [] }

        let range = dateRange
        var resets: [Date] = []

        var cursor = fiveHour.resetsAt
        while cursor > range.lowerBound {
            if cursor >= range.lowerBound && cursor <= range.upperBound {
                resets.append(cursor)
            }
            cursor = cursor.addingTimeInterval(-fiveHour.duration)
        }

        cursor = fiveHour.resetsAt.addingTimeInterval(fiveHour.duration)
        while cursor <= range.upperBound {
            if cursor >= range.lowerBound {
                resets.append(cursor)
            }
            cursor = cursor.addingTimeInterval(fiveHour.duration)
        }

        return resets.sorted()
    }

    /// The next upcoming 7-day reset (the one we show projection info on).
    private var nextSevenDayReset: Date? {
        guard let resetDate = sevenDayWindow?.resetsAt,
              resetDate >= dateRange.lowerBound && resetDate <= dateRange.upperBound
        else { return nil }
        return resetDate
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toolbar
            HStack(spacing: 6) {
                // Zoom controls
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { zoom(factor: 0.5) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Zoom in")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { zoom(factor: 2.0) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Zoom out")

                Divider()
                    .frame(height: 12)

                // Live button
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { snapToLive() }
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(isLive ? .green : .secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text("Live")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        isLive
                            ? AnyShapeStyle(Color.green.opacity(0.1))
                            : AnyShapeStyle(Color.secondary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(isLive ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Snap to current time")

                Spacer()

                // Range description
                Text(rangeDescription(span: visibleSpan))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Chart
            usageChart
                .frame(height: 180)
                .clipped()
                .contentShape(Rectangle())
                .gesture(panGesture)
                .gesture(pinchGesture)
                .onScrollWheel { delta in
                    handleScrollWheel(delta)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chartAccessibilityLabel)

            // Legend + stats
            HStack(spacing: 12) {
                rangeLabel
                Spacer()
                usageStats
            }
        }
        .onAppear { snapToLive() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            now = date
            if isLive {
                visibleCenter = now
                clampTimeline()
            }
        }
    }

    private var chartAccessibilityLabel: String {
        let count = filteredSnapshots.count
        let spanDesc = rangeDescription(span: visibleSpan)
        let fivePeak = filteredSnapshots.map(\.fiveHourUtilization).max() ?? 0
        let sevenPeak = filteredSnapshots.map(\.sevenDayUtilization).max() ?? 0
        return "Usage history chart, \(spanDesc), \(count) data points. Peak 5-hour \(Int(fivePeak)) percent, peak 7-day \(Int(sevenPeak)) percent"
    }

    // MARK: - Zoom & Navigation

    private func zoom(factor: Double) {
        visibleSpan = min(max(visibleSpan * factor, Self.minSpan), min(totalSpan, Self.maxSpan))
        clampTimeline()
    }

    private func snapToLive() {
        isLive = true
        visibleCenter = now
        clampTimeline()
    }

    private func markNotLive() {
        isLive = false
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if gestureCenterAtStart == .distantPast {
                    gestureCenterAtStart = visibleCenter
                }
                let pixelsPerSecond = 400.0 / visibleSpan
                let timeOffset = -Double(value.translation.width) / pixelsPerSecond
                visibleCenter = gestureCenterAtStart.addingTimeInterval(timeOffset)
                markNotLive()
                clampTimeline()
            }
            .onEnded { _ in
                gestureCenterAtStart = .distantPast
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if gestureSpanAtStart == 0 {
                    gestureSpanAtStart = visibleSpan
                }
                let newSpan = gestureSpanAtStart / value.magnification
                visibleSpan = min(max(newSpan, Self.minSpan), min(totalSpan, Self.maxSpan))
                clampTimeline()
            }
            .onEnded { _ in
                gestureSpanAtStart = 0
            }
    }

    private func handleScrollWheel(_ delta: CGPoint) {
        if abs(delta.x) > abs(delta.y) || abs(delta.y) < 0.5 {
            let panFraction = delta.x / 400.0
            let timeOffset = -Double(panFraction) * visibleSpan
            visibleCenter = visibleCenter.addingTimeInterval(timeOffset)
            markNotLive()
        } else {
            let zoomFactor = 1.0 + Double(delta.y) * 0.03
            visibleSpan = min(max(visibleSpan * zoomFactor, Self.minSpan), min(totalSpan, Self.maxSpan))
        }
        clampTimeline()
    }

    // MARK: - Timeline Helpers

    private func clampTimeline() {
        visibleSpan = min(max(visibleSpan, Self.minSpan), min(totalSpan, Self.maxSpan))

        let halfSpan = visibleSpan / 2
        let minCenter = timelineStart.addingTimeInterval(halfSpan)
        let maxCenter = timelineEnd.addingTimeInterval(-halfSpan)

        if minCenter >= maxCenter {
            visibleCenter = timelineStart.addingTimeInterval(totalSpan / 2)
        } else if visibleCenter < minCenter {
            visibleCenter = minCenter
        } else if visibleCenter > maxCenter {
            visibleCenter = maxCenter
        }
    }

    // MARK: - Range Label

    private var rangeLabel: some View {
        let range = dateRange
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(dateRangeDescription(range))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func dateRangeDescription(_ range: ClosedRange<Date>) -> String {
        let formatter = DateFormatter()
        if visibleSpan < 86400 {
            formatter.dateFormat = "MMM d, HH:mm"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return "\(formatter.string(from: range.lowerBound)) – \(formatter.string(from: range.upperBound))"
    }

    private func rangeDescription(span: TimeInterval) -> String {
        if span < 3600 {
            return "\(Int(span / 60))m"
        } else if span < 86400 {
            let hours = span / 3600
            return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        } else {
            let days = span / 86400
            return days == days.rounded() ? "\(Int(days))d" : String(format: "%.1fd", days)
        }
    }

    // MARK: - Chart Overlay

    private func chartOverlay<V: View>(content: V) -> some View {
        content
            .chartXScale(domain: dateRange)
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisLabel(for: date))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geo[plotFrame].origin
                                let x = location.x - origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    hoverDate = date
                                }
                            case .ended:
                                hoverDate = nil
                            }
                        }
                }
            }
    }

    private func axisLabel(for date: Date) -> String {
        if visibleSpan < 86400 {
            return date.formatted(.dateTime.hour().minute())
        } else if visibleSpan < 86400 * 3 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    // MARK: - Projection

    private var projectionEnd: Date? {
        if let sevenDayReset = sevenDayWindow?.resetsAt {
            return sevenDayReset
        }
        guard momentum?.velocity ?? 0 > 0 else { return nil }
        if let fiveHourReset = fiveHourWindow?.resetsAt {
            return min(fiveHourReset, now.addingTimeInterval(3600))
        }
        return now.addingTimeInterval(3600)
    }

    private struct UsageProjectionData {
        var fiveHour: [(date: Date, value: Double)] = []
        var sevenDay: [(date: Date, value: Double)] = []
        var sevenDayBand: [(date: Date, low: Double, high: Double)] = []
        var isPatternAware: Bool = false
    }

    private var usageProjectionPoints: UsageProjectionData? {
        guard let lastSnap = filteredSnapshots.last,
              let velocity = momentum?.velocity, velocity > 0
        else { return nil }

        let sevenDayVelocity = projection?.sevenDayVelocity ?? 0
        guard let end = projectionEnd, end > lastSnap.timestamp else { return nil }

        var data = UsageProjectionData()

        // 5-hour projection (only when zoomed in)
        if visibleSpan < 86400 {
            let fiveHourEnd = fiveHourWindow?.resetsAt ?? now.addingTimeInterval(3600)
            let cappedEnd = min(fiveHourEnd, now.addingTimeInterval(3600))
            if cappedEnd > lastSnap.timestamp {
                let startDate = lastSnap.timestamp
                let steps = 30
                let interval = cappedEnd.timeIntervalSince(startDate) / Double(steps)
                data.fiveHour.append((startDate, lastSnap.fiveHourUtilization))
                for i in 1...steps {
                    let date = startDate.addingTimeInterval(Double(i) * interval)
                    let hours = date.timeIntervalSince(startDate) / 3600
                    let value = min(lastSnap.fiveHourUtilization + velocity * hours, 100)
                    data.fiveHour.append((date, value))
                }
            }
        }

        // 7-day projection
        if let pattern = projection?.patternProjection, pattern.curve.count >= 2 {
            data.isPatternAware = pattern.isPatternAware
            for point in pattern.curve {
                data.sevenDay.append((point.date, point.projected))
                data.sevenDayBand.append((point.date, point.optimistic, point.pessimistic))
            }
        } else if sevenDayVelocity > 0 {
            let startDate = lastSnap.timestamp
            let sevenDayBase = projection?.currentGranularUtilization() ?? lastSnap.sevenDayUtilization
            let steps = 60
            let interval = end.timeIntervalSince(startDate) / Double(steps)
            data.sevenDay.append((startDate, sevenDayBase))
            for i in 1...steps {
                let date = startDate.addingTimeInterval(Double(i) * interval)
                let hours = date.timeIntervalSince(startDate) / 3600
                let value = min(sevenDayBase + sevenDayVelocity * hours, 100)
                data.sevenDay.append((date, value))
            }
        }

        return data
    }

    private var projectedAtReset: Double? {
        projection?.projectedAtReset
    }

    // MARK: - Target Curve

    private var targetCurvePoints: [(date: Date, value: Double)] {
        guard let plan = usagePlan, plan.isEnabled,
              let sevenDay = sevenDayWindow
        else { return [] }

        let resetDate = sevenDay.resetsAt
        let current7Day = sevenDay.utilization
        let totalBudget = max(100 - current7Day, 0)
        guard totalBudget > 0 else { return [] }

        let totalActiveHours = plan.activeHoursRemaining(until: resetDate, from: now)
        guard totalActiveHours > 0 else { return [] }

        let budgetPerHour = totalBudget / totalActiveHours
        var points: [(date: Date, value: Double)] = []
        var cursor = now
        var accumulatedBudget = 0.0

        points.append((now, current7Day))

        while cursor < resetDate {
            let nextCursor = cursor.addingTimeInterval(3600)
            let stepEnd = min(nextCursor, resetDate)

            if plan.isActiveTime(cursor) {
                let dt = stepEnd.timeIntervalSince(cursor) / 3600
                accumulatedBudget += budgetPerHour * dt
            }

            points.append((stepEnd, min(current7Day + accumulatedBudget, 100)))
            cursor = nextCursor
        }

        return points
    }

    // MARK: - Usage Chart

    private var peakUtilization: Double {
        let fivePeak = filteredSnapshots.map(\.fiveHourUtilization).max() ?? 0
        let sevenPeak = filteredSnapshots.map(\.sevenDayUtilization).max() ?? 0
        let projFivePeak = usageProjectionPoints?.fiveHour.map(\.value).max() ?? 0
        let projSevenPeak = usageProjectionPoints?.sevenDay.map(\.value).max() ?? 0
        let bandPeak = usageProjectionPoints?.sevenDayBand.map(\.high).max() ?? 0
        let targetPeak = targetCurvePoints.map(\.value).max() ?? 0
        return max(fivePeak, sevenPeak, projFivePeak, projSevenPeak, bandPeak, targetPeak)
    }

    private func nearestSnapshot(to date: Date) -> UsageSnapshot? {
        guard !filteredSnapshots.isEmpty else { return nil }
        return filteredSnapshots.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        })
    }

    private var usageChart: some View {
        let proj = usageProjectionPoints
        return chartOverlay(content:
            Chart {
                ForEach(filteredSnapshots) { snapshot in
                    LineMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value("5h Usage", snapshot.fiveHourUtilization)
                    )
                    .foregroundStyle(by: .value("Window", "5-Hour"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value("7d Usage", snapshot.sevenDayUtilization)
                    )
                    .foregroundStyle(by: .value("Window", "7-Day"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                // 5-hour projection
                if let fiveHourProj = proj?.fiveHour, fiveHourProj.count >= 2 {
                    ForEach(Array(fiveHourProj.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("5h Projected", point.value)
                        )
                        .foregroundStyle(Color.blue.opacity(0.4))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                }

                // 7-day confidence band
                if let band = proj?.sevenDayBand, band.count >= 2 {
                    ForEach(Array(band.enumerated()), id: \.offset) { _, point in
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Low", point.low),
                            yEnd: .value("High", point.high)
                        )
                        .foregroundStyle(Color.purple.opacity(0.08))
                        .interpolationMethod(.monotone)
                    }
                }

                // 7-day projection line
                if let sevenDayProj = proj?.sevenDay, sevenDayProj.count >= 2 {
                    ForEach(Array(sevenDayProj.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("7d Projected", point.value)
                        )
                        .foregroundStyle(Color.purple.opacity(0.4))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                }

                // Target curve
                if !targetCurvePoints.isEmpty {
                    ForEach(Array(targetCurvePoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Target", point.value)
                        )
                        .foregroundStyle(Color.green.opacity(0.5))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }

                // 7-day reset markers
                ForEach(Array(sevenDayResetsInRange.enumerated()), id: \.offset) { idx, resetDate in
                    RuleMark(x: .value("7d Reset", resetDate))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.purple.opacity(0.4))
                        .annotation(position: .topLeading, spacing: 4) {
                            resetAnnotation(for: resetDate, isNext: resetDate == nextSevenDayReset)
                        }
                }

                // 5-hour reset markers (when zoomed in)
                ForEach(Array(fiveHourResetsInRange.enumerated()), id: \.offset) { _, resetDate in
                    RuleMark(x: .value("5h Reset", resetDate))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(.blue.opacity(0.25))
                        .annotation(position: .bottomLeading, spacing: 2) {
                            Text("5h")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.blue.opacity(0.4))
                        }
                }

                // Projected point at next reset
                if let resetDate = nextSevenDayReset, let projected = projectedAtReset {
                    PointMark(
                        x: .value("Reset", resetDate),
                        y: .value("Projected", projected)
                    )
                    .foregroundStyle(.purple.opacity(0.6))
                    .symbolSize(40)
                    .symbol(.diamond)
                }

                // Now marker
                if now >= dateRange.lowerBound && now <= dateRange.upperBound {
                    RuleMark(x: .value("Now", now))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary.opacity(0.3))
                }

                // Hover
                if let date = hoverDate {
                    RuleMark(x: .value("Hover", date))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary.opacity(0.6))

                    if let snap = nearestSnapshot(to: date) {
                        PointMark(
                            x: .value("Time", snap.timestamp),
                            y: .value("5h", snap.fiveHourUtilization)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(30)

                        PointMark(
                            x: .value("Time", snap.timestamp),
                            y: .value("7d", snap.sevenDayUtilization)
                        )
                        .foregroundStyle(.purple)
                        .symbolSize(30)
                    }
                }
            }
            .chartYScale(domain: 0...max(peakUtilization * 1.1, 10))
            .chartYAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f", v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartForegroundStyleScale([
                "5-Hour": Color.blue,
                "7-Day": Color.purple,
            ])
        )
        .overlay(alignment: .topLeading) {
            if let date = hoverDate, let snap = nearestSnapshot(to: date) {
                usageTooltip(snap: snap)
                    .padding(8)
            }
        }
    }

    // MARK: - Reset Annotation

    @ViewBuilder
    private func resetAnnotation(for date: Date, isNext: Bool) -> some View {
        if isNext {
            // Full annotation for the upcoming reset
            HStack(spacing: 4) {
                Text("7d Reset")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.purple)
                if let projected = projectedAtReset {
                    Text(String(format: "%.0f%%", projected))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.purple.opacity(0.7))
                }
                if let pattern = projection?.patternProjection, pattern.isPatternAware {
                    Text(String(format: "%.0f–%.0f%%", pattern.optimisticAtReset, pattern.pessimisticAtReset))
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(.purple.opacity(0.4))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        } else {
            // Minimal label for historical resets
            Text("7d")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.purple.opacity(0.4))
        }
    }

    private func usageTooltip(snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snap.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.caption2.weight(.semibold))
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text(String(format: "5h: %.0f%%", snap.fiveHourUtilization))
                        .font(.caption2.monospacedDigit())
                }
                HStack(spacing: 3) {
                    Circle().fill(.purple).frame(width: 6, height: 6)
                    Text(String(format: "7d: %.0f%%", snap.sevenDayUtilization))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var usageStats: some View {
        HStack(spacing: 16) {
            if !filteredSnapshots.isEmpty {
                statItem(
                    "Peak 5H",
                    value: String(format: "%.0f%%", filteredSnapshots.map(\.fiveHourUtilization).max() ?? 0),
                    color: .blue
                )
                statItem(
                    "Peak 7D",
                    value: String(format: "%.0f%%", filteredSnapshots.map(\.sevenDayUtilization).max() ?? 0),
                    color: .purple
                )
            }
        }
    }

    // MARK: - Shared Helpers

    private func statItem(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Scroll Wheel

private extension View {
    func onScrollWheel(_ handler: @escaping (CGPoint) -> Void) -> some View {
        overlay {
            ScrollWheelView(onScroll: handler)
        }
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

private class ScrollWheelNSView: NSView {
    var onScroll: ((CGPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dx) > 0.1 || abs(dy) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }
        onScroll?(CGPoint(x: dx, y: dy))
    }
}
