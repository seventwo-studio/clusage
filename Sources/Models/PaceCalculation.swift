import Foundation

struct PaceCalculation: Sendable {
    let utilization: Double
    let elapsedFraction: Double

    var target: Double {
        elapsedFraction * 100
    }

    /// utilization is already 0–100 from the API.
    var delta: Double {
        utilization - target
    }

    var isOverpacing: Bool {
        delta > 0
    }

    var isUnderpacing: Bool {
        delta < 0
    }

    var description: String {
        if abs(delta) < 1 {
            return "On pace"
        } else if isOverpacing {
            return String(format: "%.0f%% ahead", delta)
        } else {
            return String(format: "%.0f%% behind", abs(delta))
        }
    }

    init(window: UsageWindow) {
        self.utilization = window.utilization
        self.elapsedFraction = window.elapsedFraction
    }
}
