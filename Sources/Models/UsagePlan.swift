import Foundation

struct DaySlot: Codable, Sendable, Equatable {
    var isActive: Bool = true
    var startHour: Int = 9
    var endHour: Int = 23

    /// Active hours in this slot.
    var activeHours: Double {
        guard isActive else { return 0 }
        guard endHour != startHour else { return 24 }
        if endHour > startHour {
            return Double(endHour - startHour)
        } else {
            // Wraps past midnight (e.g. 9 AM to 1 AM = 16h)
            return Double(24 - startHour + endHour)
        }
    }
}

struct UsagePlan: Codable, Sendable {
    /// Day boundary hour — a new "plan day" starts at this hour (default 5 AM).
    static let dayBoundaryHour = 5

    var isEnabled: Bool = false
    /// Keyed by Calendar weekday (1 = Sunday, 2 = Monday, ... 7 = Saturday).
    var slots: [Int: DaySlot] = Self.defaultSlots
    /// Date-specific overrides, keyed by plan-day date string (yyyy-MM-dd).
    /// These take priority over the weekly slot for that day.
    var overrides: [String: DaySlot] = [:]

    static let defaultSlots: [Int: DaySlot] = {
        var dict: [Int: DaySlot] = [:]
        for day in 1...7 {
            // Weekend days (1 = Sunday, 7 = Saturday) off by default
            let isWeekday = day >= 2 && day <= 6
            dict[day] = DaySlot(isActive: isWeekday, startHour: 9, endHour: 23)
        }
        return dict
    }()

    // MARK: - Day Boundary

    /// Returns the "plan weekday" for the given date. Before the day boundary hour,
    /// the date belongs to the previous plan day (e.g. 2 AM Tuesday = Monday's plan).
    static func planWeekday(for date: Date) -> Int {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        if hour < dayBoundaryHour {
            // Still part of yesterday's plan day
            let yesterday = cal.date(byAdding: .day, value: -1, to: date)!
            return cal.component(.weekday, from: yesterday)
        }
        return cal.component(.weekday, from: date)
    }

    /// Returns the plan-day date string (yyyy-MM-dd) for a given date.
    static func planDateKey(for date: Date) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let planDate = hour < dayBoundaryHour
            ? cal.date(byAdding: .day, value: -1, to: date)!
            : date
        return DateFormatting.formatDateDash(planDate)
    }

    /// Returns the slot for the current plan day, checking overrides first.
    func todaySlot(at date: Date = .now) -> DaySlot? {
        guard isEnabled else { return nil }
        let key = Self.planDateKey(for: date)
        if let override = overrides[key] {
            return override
        }
        let weekday = Self.planWeekday(for: date)
        return slots[weekday]
    }

    /// Whether the given date has an override.
    func hasOverride(for date: Date) -> Bool {
        overrides[Self.planDateKey(for: date)] != nil
    }

    /// Set a date-specific override.
    mutating func setOverride(_ slot: DaySlot, for date: Date) {
        overrides[Self.planDateKey(for: date)] = slot
    }

    /// Remove the override for a date.
    mutating func clearOverride(for date: Date) {
        overrides.removeValue(forKey: Self.planDateKey(for: date))
    }

    /// Remove overrides older than 8 days.
    mutating func pruneOldOverrides() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -8, to: .now)!
        let cutoffKey = DateFormatting.formatDateDash(cutoff)
        overrides = overrides.filter { $0.key >= cutoffKey }
    }

    /// Whether the given time falls within an active slot.
    func isActiveTime(_ date: Date) -> Bool {
        guard isEnabled else { return true }
        guard let slot = todaySlot(at: date), slot.isActive else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)

        if hour < Self.dayBoundaryHour {
            // Before day boundary — check if previous day's slot extends past midnight
            if slot.endHour <= slot.startHour {
                // Slot wraps midnight, we're in the wrap portion
                return hour < slot.endHour
            }
            return false
        }

        if slot.endHour > slot.startHour {
            return hour >= slot.startHour && hour < slot.endHour
        } else {
            // Wraps past midnight
            return hour >= slot.startHour || hour < slot.endHour
        }
    }

    /// The bedtime for the current plan day — when today's slot ends.
    func bedtime(for date: Date = .now) -> Date? {
        guard isEnabled else { return nil }
        guard let slot = todaySlot(at: date), slot.isActive else { return nil }
        let cal = Calendar.current

        // Figure out the calendar date of the plan day start
        let planDate: Date
        let hour = cal.component(.hour, from: date)
        if hour < Self.dayBoundaryHour {
            planDate = cal.date(byAdding: .day, value: -1, to: date)!
        } else {
            planDate = date
        }

        // Bedtime is endHour on the plan day (or next calendar day if wraps past midnight)
        var bedtime = cal.date(bySettingHour: slot.endHour, minute: 0, second: 0, of: planDate)!
        if slot.endHour <= slot.startHour {
            // End wraps to next calendar day
            bedtime = cal.date(byAdding: .day, value: 1, to: bedtime)!
        }

        return bedtime
    }

    /// Total active hours remaining from `now` until `deadline`, respecting per-day slots.
    func activeHoursRemaining(until deadline: Date, from now: Date = .now) -> Double {
        guard isEnabled else {
            return max(deadline.timeIntervalSince(now) / 3600, 0)
        }

        let cal = Calendar.current
        var total: Double = 0
        var cursor = now

        // Walk day by day until we pass the deadline
        while cursor < deadline {
            let key = Self.planDateKey(for: cursor)
            let weekday = Self.planWeekday(for: cursor)
            let slot = overrides[key] ?? slots[weekday]
            guard let slot, slot.isActive else {
                // Skip to next day boundary
                cursor = nextDayBoundary(after: cursor)
                continue
            }

            // Find the active window for this plan day
            let dayStart = dayBoundaryDate(for: cursor)
            let slotStart = cal.date(bySettingHour: slot.startHour, minute: 0, second: 0, of: dayStart)!
            var slotEnd = cal.date(bySettingHour: slot.endHour, minute: 0, second: 0, of: dayStart)!
            if slot.endHour <= slot.startHour {
                slotEnd = cal.date(byAdding: .day, value: 1, to: slotEnd)!
            }

            // Clamp to [now, deadline]
            let effectiveStart = max(slotStart, cursor)
            let effectiveEnd = min(slotEnd, deadline)
            if effectiveEnd > effectiveStart {
                total += effectiveEnd.timeIntervalSince(effectiveStart) / 3600
            }

            cursor = nextDayBoundary(after: cursor)
        }

        return total
    }

    // MARK: - Helpers

    /// Returns the date of the day boundary (5 AM) for the plan day containing `date`.
    private func dayBoundaryDate(for date: Date) -> Date {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        if hour < Self.dayBoundaryHour {
            let yesterday = cal.date(byAdding: .day, value: -1, to: date)!
            return cal.date(bySettingHour: Self.dayBoundaryHour, minute: 0, second: 0, of: yesterday)!
        }
        return cal.date(bySettingHour: Self.dayBoundaryHour, minute: 0, second: 0, of: date)!
    }

    /// Returns the next day boundary (5 AM) after the plan day containing `date`.
    private func nextDayBoundary(after date: Date) -> Date {
        let boundary = dayBoundaryDate(for: date)
        return Calendar.current.date(byAdding: .day, value: 1, to: boundary)!
    }

    // MARK: - Ordered Days

    /// Days of the week starting from Monday, with their Calendar weekday numbers.
    static let orderedDays: [(weekday: Int, name: String, short: String)] = [
        (2, "Monday", "Mon"),
        (3, "Tuesday", "Tue"),
        (4, "Wednesday", "Wed"),
        (5, "Thursday", "Thu"),
        (6, "Friday", "Fri"),
        (7, "Saturday", "Sat"),
        (1, "Sunday", "Sun"),
    ]
}
