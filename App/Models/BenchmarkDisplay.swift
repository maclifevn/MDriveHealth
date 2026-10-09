/* Finite measurement values must remain safe to display. GPL-3.0-or-later. */
import Foundation

enum BenchmarkDisplay {
    enum Comparison: Equatable {
        case similar, faster(Int), slower(Int), unavailable
    }

    /// SQL and the worker accept finite nonnegative rates, including values
    /// outside Int's range. Keep those as floating point when making labels.
    static func number(_ value: Double, decimals: Int = 0, locale: Locale = .current) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000 || (value > 0 && value < 0.1) {
            return String(format: "%.2e", locale: locale, value)
        }
        if decimals == 0 {
            return String(format: "%.0f", locale: locale, value.rounded(.towardZero))
        }
        return String(format: "%.1f", locale: locale, value)
    }

    static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let megabytes = bytesPerSecond / 1e6
        // Do not turn a positive subnormal value into a claimed zero rate.
        if bytesPerSecond > 0, megabytes == 0 {
            return number(bytesPerSecond, decimals: 1, locale: locale) + " B/s"
        }
        return number(megabytes, decimals: 1, locale: locale) + " MB/s"
    }

    static func iops(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1000, value < 1_000_000_000 {
            return String(format: "%.1fk IOPS", locale: locale, value / 1000)
        }
        if value == 0 || (value >= 0.1 && value < 1000) {
            return String(format: "%.0f IOPS", locale: locale, value)
        }
        return number(value, locale: locale) + " IOPS"
    }

    static func comparison(current: Double, previous: Double?) -> Comparison? {
        guard let previous else { return nil }
        guard current.isFinite, current >= 0, previous.isFinite, previous > 0 else { return .unavailable }
        let change = (current - previous) / previous
        guard change.isFinite else { return .unavailable }
        if abs(change) < 0.02 { return .similar }
        // Int(exactly:) rejects infinity and out-of-range values without a
        // trap. An unrepresentable comparison is not a clamped percentage.
        guard let percent = Int(exactly: (abs(change) * 100).rounded()) else { return .unavailable }
        return change > 0 ? .faster(percent) : .slower(percent)
    }
}
