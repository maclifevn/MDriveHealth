/* Numeric presentation across actual persisted rate boundaries. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class BenchmarkDisplayTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testMaximumAcceptedRatesRoundTripThroughSQLiteAndRenderCompactly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-display-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
        defer { try? store.close() }
        let value = Double.greatestFiniteMagnitude
        let result = BenchmarkResult(capturedAt: Date(), volumeBSDName: "disk999999s1", volumeName: "Private numeric fixture",
            mountPoint: root.path, fileSizeBytes: 16384, sequentialBlockBytes: 4096, randomBlockBytes: 4096, queueDepth: 1,
            sequentialWriteBytesPerSec: value, sequentialReadBytesPerSec: value,
            randomWriteBytesPerSec: value, randomReadBytesPerSec: value)
        try await store.record(benchmark: result, driveKey: "display-fixture")
        let saved = try await store.latestBenchmark(driveKey: "display-fixture")
        XCTAssertEqual(saved?.sequentialWriteBytesPerSec, value)
        XCTAssertEqual(saved?.sequentialReadBytesPerSec, value)
        XCTAssertEqual(saved?.randomWriteBytesPerSec, value)
        XCTAssertEqual(BenchmarkDisplay.number(try XCTUnwrap(saved).sequentialWriteBytesPerSec / 1e6, locale: english).lowercased(), "1.80e+302")
        XCTAssertEqual(BenchmarkDisplay.speed(value, locale: english).lowercased(), "1.80e+302 mb/s")
        XCTAssertLessThan(BenchmarkDisplay.iops(value, locale: english).count, 24)
    }

    func testLabelsRetainNormalUnitsAndLocaleWithoutIntegerConversion() {
        XCTAssertEqual(BenchmarkDisplay.number(800.9, locale: english), "800")
        XCTAssertEqual(BenchmarkDisplay.speed(800_000_000, locale: english), "800.0 MB/s")
        XCTAssertEqual(BenchmarkDisplay.speed(800_500_000, locale: Locale(identifier: "vi_VN")), "800,5 MB/s")
        XCTAssertEqual(BenchmarkDisplay.iops(6000, locale: english), "6.0k IOPS")
        XCTAssertEqual(BenchmarkDisplay.iops(999.6, locale: english), "1,000 IOPS")
        XCTAssertEqual(BenchmarkDisplay.speed(0, locale: english), "0.0 MB/s")
        XCTAssertTrue(BenchmarkDisplay.speed(Double.leastNonzeroMagnitude, locale: english).hasSuffix(" B/s"))
        XCTAssertFalse(BenchmarkDisplay.speed(Double.leastNonzeroMagnitude, locale: english).hasPrefix("0"))
        for value in [Double(Int.max), Double.greatestFiniteMagnitude] {
            XCTAssertLessThan(BenchmarkDisplay.number(value, locale: english).count, 16)
        }
    }

    func testInvalidRatesAreUnknownInsteadOfZeroOrInfinity() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(BenchmarkDisplay.number(value), "—")
            XCTAssertEqual(BenchmarkDisplay.speed(value), "—")
            XCTAssertEqual(BenchmarkDisplay.iops(value), "—")
        }
    }

    func testComparisonRejectsOverflowAndZeroBaselineWithoutClamping() {
        XCTAssertEqual(BenchmarkDisplay.comparison(current: .greatestFiniteMagnitude, previous: .leastNormalMagnitude), .unavailable)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 1e30, previous: 1), .unavailable)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: Double(Int.max) / 100 + 1, previous: 1), .unavailable)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 100, previous: 0), .unavailable)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: .nan, previous: 100), .unavailable)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 100, previous: .infinity), .unavailable)
        XCTAssertNil(BenchmarkDisplay.comparison(current: 100, previous: nil))
    }

    func testComparableResultsKeepDirectionToleranceAndRoundedPercentage() {
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 125, previous: 100), .faster(25))
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 74.5, previous: 100), .slower(26))
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 101, previous: 100), .similar)
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 102, previous: 100), .faster(2))
        XCTAssertEqual(BenchmarkDisplay.comparison(current: 0, previous: 100), .slower(100))
        XCTAssertEqual(BenchmarkDisplay.comparison(current: .greatestFiniteMagnitude, previous: .greatestFiniteMagnitude), .similar)
    }
}
