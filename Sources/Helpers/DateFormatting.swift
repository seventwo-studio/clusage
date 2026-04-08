import Foundation

@MainActor enum DateFormatting {
    static func resetCountdown(from date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "Resetting..." }

        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    static func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseISO8601(_ string: String) -> Date? {
        iso8601WithFractional.date(from: string) ?? iso8601Plain.date(from: string)
    }

    // MARK: - Cached DateFormatters

    private static let hourAmPmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f
    }()

    private static let hourSpaceAmPmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    private static let dateDashFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Format an hour as "9am", "12pm", etc.
    static func formatHourShort(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return hourAmPmFormatter.string(from: date).lowercased()
    }

    /// Format an hour as "9 AM", "12 PM", etc.
    static func formatHourAmPm(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return hourSpaceAmPmFormatter.string(from: date)
    }

    /// Format a date as "yyyy-MM-dd".
    static func formatDateDash(_ date: Date) -> String {
        dateDashFormatter.string(from: date)
    }
}
