/* Valid integer history must not crash or change value in chart tooltips. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class HistoryChartDataTests: XCTestCase {
    private func point(temperature: Int? = nil, score: Int? = nil, lifetime: Int? = nil,
                       written: UInt64? = nil, defects: UInt64? = nil) -> HistoryPoint {
        .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), temperatureC: temperature,
              healthScore: score, rating: nil, lifetimeLeftPercent: lifetime, powerOnHours: nil,
              bytesWritten: written, defectCount: defects, pendingSectors: nil)
    }

    func testMaximumUnsignedCounterHasExactTooltipAndFiniteCoordinate() throws {
        let data = try XCTUnwrap(HistoryMetric.defects.datum(for: point(defects: .max)))
        XCTAssertEqual(data.label, "18446744073709551615")
        XCTAssertTrue(data.value.isFinite)
        XCTAssertTrue(data.isApproximate)
        XCTAssertNil(Int(exactly: data.value))
        XCTAssertEqual(data.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testIntegerPrecisionBoundaryAndValuesBeyondSignedRangeRetainTheirLabels() throws {
        for (raw, expected, approximate) in [
            (UInt64(9_007_199_254_740_992), "9007199254740992", false),
            (UInt64(9_007_199_254_740_993), "9007199254740993", true),
            (UInt64(9_223_372_036_854_775_808), "9223372036854775808", false)
        ] {
            let data = try XCTUnwrap(HistoryMetric.defects.datum(for: point(defects: raw)))
            XCTAssertEqual(data.label, expected)
            XCTAssertEqual(data.isApproximate, approximate)
            XCTAssertTrue(data.value.isFinite)
        }
    }

    func testZeroRemainsARecordedValueForEveryMetric() throws {
        let input = point(temperature: 0, score: 0, lifetime: 0, written: 0, defects: 0)
        let expected = [HistoryMetric.temperature: "0°C", .score: "0/100", .lifetime: "0%", .written: "0.00 TB", .defects: "0"]
        for metric in HistoryMetric.allCases {
            let data = try XCTUnwrap(metric.datum(for: input))
            XCTAssertEqual(data.value, 0)
            XCTAssertEqual(data.label, expected[metric])
            XCTAssertFalse(data.isApproximate)
        }
    }

    func testUnknownMetricsAreOmittedInsteadOfBecomingZero() {
        for metric in HistoryMetric.allCases { XCTAssertNil(metric.datum(for: point())) }
        let input = point(defects: 42)
        XCTAssertNil(HistoryMetric.temperature.datum(for: input))
        XCTAssertEqual(HistoryMetric.defects.datum(for: input)?.label, "42")
    }

    func testSignedTemperatureBoundsDoNotRoundTripThroughDouble() throws {
        for raw in [Int.min, Int.max, -20, 37] {
            let data = try XCTUnwrap(HistoryMetric.temperature.datum(for: point(temperature: raw)))
            XCTAssertEqual(data.label, "\(raw)°C")
            XCTAssertTrue(data.value.isFinite)
        }
    }

    func testMaximumWrittenBytesUsesFiniteDecimalTerabytes() throws {
        let data = try XCTUnwrap(HistoryMetric.written.datum(for: point(written: .max)))
        XCTAssertEqual(data.label, "18446744.07 TB")
        XCTAssertEqual(data.value, 18_446_744.07370955, accuracy: 0.00001)
        XCTAssertTrue(data.value.isFinite)
    }
}
