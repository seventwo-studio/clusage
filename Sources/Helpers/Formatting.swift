import Foundation

enum Formatting {
    /// Format a percentage value: "12%" (no decimals by default).
    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    /// Format a velocity/pace value: "12.3 pp/hr" or "12 pp/hr".
    static func pace(_ velocity: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f pp/hr", velocity)
    }

    /// Format a percentage range: "12–34%".
    static func percentRange(_ low: Double, _ high: Double) -> String {
        String(format: "%.0f–%.0f%%", low, high)
    }

    /// Format a duration as "2m 30s" or "2m".
    static func settingsDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}
