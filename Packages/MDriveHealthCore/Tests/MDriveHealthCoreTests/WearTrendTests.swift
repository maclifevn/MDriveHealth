/*
 * WearTrendTests.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class WearTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func point(daysAgo: Double, bytesWritten: UInt64? = nil,
                       lifetime: Int? = nil) -> HistoryPoint {
        HistoryPoint(capturedAt: now.addingTimeInterval(-daysAgo * 86_400),
                     temperatureC: 40, healthScore: 100, rating: "good",
                     lifetimeLeftPercent: lifetime, powerOnHours: 1_000,
                     bytesWritten: bytesWritten, defectCount: 0,
                     pendingSectors: nil)
    }

    func testWriteRateOverTenDays() {
        let points = [
            point(daysAgo: 10, bytesWritten: 100_000_000_000),
            point(daysAgo: 5, bytesWritten: 105_000_000_000),
            point(daysAgo: 0, bytesWritten: 110_000_000_000),
        ]
        let estimate = WearTrend.estimate(from: points, now: now)
        XCTAssertEqual(estimate.bytesWrittenPerDay ?? 0, 1_000_000_000,
                       accuracy: 1_000_000)
    }

    func testWriteRateUsesTrailingRunAfterCounterReset() {
        let points = [
            point(daysAgo: 20, bytesWritten: 900_000_000_000), // before reset
            point(daysAgo: 10, bytesWritten: 10_000_000_000),  // reset happened
            point(daysAgo: 0, bytesWritten: 30_000_000_000),
        ]
        let estimate = WearTrend.estimate(from: points, now: now)
        XCTAssertEqual(estimate.bytesWrittenPerDay ?? 0, 2_000_000_000,
                       accuracy: 1_000_000)
    }

    func testWriteRateNeedsAtLeastOneDaySpan() {
        let points = [
            point(daysAgo: 0.5, bytesWritten: 100_000_000_000),
            point(daysAgo: 0, bytesWritten: 200_000_000_000),
        ]
        XCTAssertNil(WearTrend.estimate(from: points, now: now).bytesWrittenPerDay)
    }

    func testLifetimeProjection() {
        let points = [
            point(daysAgo: 20, lifetime: 90),
            point(daysAgo: 10, lifetime: 89),
            point(daysAgo: 0, lifetime: 88),
        ]
        let estimate = WearTrend.estimate(from: points, now: now)
        XCTAssertEqual(estimate.lifetimePercentPerDay ?? 0, 0.1, accuracy: 0.01)
        let exhaustion = try? XCTUnwrap(estimate.estimatedExhaustionDate)
        // 88% left at 0.1 %/day → ~880 days from the latest point.
        XCTAssertEqual(exhaustion?.timeIntervalSince(now) ?? 0,
                       880 * 86_400, accuracy: 5 * 86_400)
    }

    func testFlatLifetimeGivesNoProjection() {
        let points = [
            point(daysAgo: 20, lifetime: 90),
            point(daysAgo: 10, lifetime: 90),
            point(daysAgo: 0, lifetime: 90),
        ]
        let estimate = WearTrend.estimate(from: points, now: now)
        XCTAssertNil(estimate.lifetimePercentPerDay)
        XCTAssertNil(estimate.estimatedExhaustionDate)
    }

    func testAbsurdlyLongProjectionIsSuppressed() {
        // 0.001 %/day → 90 000 days ≈ 246 years: not a forecast, noise.
        let points = [
            point(daysAgo: 2_000, lifetime: 92),
            point(daysAgo: 1_000, lifetime: 91),
            point(daysAgo: 0, lifetime: 90),
        ]
        XCTAssertNil(WearTrend.estimate(from: points, now: now).estimatedExhaustionDate)
    }
}
