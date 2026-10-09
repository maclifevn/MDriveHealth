/*
 * WearTrend.swift — write-rate and SSD wear projections from history.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public struct WearTrendEstimate: Sendable, Hashable {
    /// Average host-write rate over the recent window; nil when history is
    /// too short to be meaningful.
    public let bytesWrittenPerDay: Double?
    /// Rated-lifetime consumption per day (negative slope, e.g. 0.05 %/day);
    /// nil when wear is flat or unknown.
    public let lifetimePercentPerDay: Double?
    /// Projected date the rated lifetime reaches 0 at the current rate.
    /// nil when wear is flat/unknown or the projection exceeds 20 years —
    /// beyond that the number is noise, not a forecast.
    public let estimatedExhaustionDate: Date?
}

public enum WearTrend {
    /// Window for the write-rate average.
    public static let writeRateWindow: TimeInterval = 30 * 86_400
    /// Minimum observed span before quoting a rate/projection.
    public static let minimumSpan: TimeInterval = 86_400

    /// Estimates trends from history points (ascending or unsorted OK).
    public static func estimate(from points: [HistoryPoint],
                                now: Date = Date()) -> WearTrendEstimate {
        let sorted = points.sorted { $0.capturedAt < $1.capturedAt }
        let slope = lifetimeSlope(sorted)
        return WearTrendEstimate(
            bytesWrittenPerDay: writeRate(sorted, now: now),
            lifetimePercentPerDay: slope.map { -$0 },
            estimatedExhaustionDate: exhaustionDate(sorted, slope: slope))
    }

    private static func writeRate(_ points: [HistoryPoint], now: Date) -> Double? {
        let window = points.filter {
            $0.capturedAt >= now.addingTimeInterval(-writeRateWindow)
                && $0.bytesWritten != nil
        }
        // Use the trailing monotonic run so a counter reset (firmware quirk,
        // unit change) earlier in the window cannot produce a bogus rate.
        var run: [HistoryPoint] = []
        for point in window.reversed() {
            if let last = run.last,
               point.bytesWritten! > last.bytesWritten! { break }
            run.append(point)
        }
        guard let newest = run.first, let oldest = run.last,
              newest.capturedAt.timeIntervalSince(oldest.capturedAt) >= minimumSpan,
              let newBytes = newest.bytesWritten, let oldBytes = oldest.bytesWritten,
              newBytes >= oldBytes
        else { return nil }
        let days = newest.capturedAt.timeIntervalSince(oldest.capturedAt) / 86_400
        return Double(newBytes - oldBytes) / days
    }

    /// Least-squares slope of lifetime-left percent per day (usually ≤ 0).
    private static func lifetimeSlope(_ points: [HistoryPoint]) -> Double? {
        let samples = points.compactMap { point -> (x: Double, y: Double)? in
            guard let lifetime = point.lifetimeLeftPercent else { return nil }
            return (point.capturedAt.timeIntervalSince1970 / 86_400, Double(lifetime))
        }
        guard samples.count >= 3,
              let first = samples.first, let last = samples.last,
              (last.x - first.x) * 86_400 >= minimumSpan
        else { return nil }

        let n = Double(samples.count)
        let sumX = samples.reduce(0) { $0 + $1.x }
        let sumY = samples.reduce(0) { $0 + $1.y }
        let sumXY = samples.reduce(0) { $0 + $1.x * $1.y }
        let sumXX = samples.reduce(0) { $0 + $1.x * $1.x }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        return slope < -0.000_1 ? slope : nil
    }

    private static func exhaustionDate(_ points: [HistoryPoint],
                                       slope: Double?) -> Date? {
        guard let slope,
              let latest = points.last(where: { $0.lifetimeLeftPercent != nil }),
              let lifetime = latest.lifetimeLeftPercent
        else { return nil }
        let daysLeft = Double(lifetime) / -slope
        guard daysLeft < 365 * 20 else { return nil }
        return latest.capturedAt.addingTimeInterval(daysLeft * 86_400)
    }
}
