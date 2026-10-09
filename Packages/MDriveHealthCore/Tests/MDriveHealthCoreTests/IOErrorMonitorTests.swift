/*
 * IOErrorMonitorTests.swift — rolling window + boundary matcher.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class IOErrorMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func event(minutesAgo: Double, _ message: String) -> IOErrorEvent {
        IOErrorEvent(date: now.addingTimeInterval(-minutesAgo * 60), message: message)
    }

    // MARK: - Boundary matcher

    func testMentionsExactDeviceAndPartitions() {
        XCTAssertTrue(IOErrorEvent(date: now, message: "I/O error on disk1")
            .mentions("disk1"))
        XCTAssertTrue(IOErrorEvent(date: now, message: "write error disk1s2 failed")
            .mentions("disk1"))
    }

    func testMentionsRejectsLongerDeviceAndSubstrings() {
        // "disk1" must not match "disk10".
        XCTAssertFalse(IOErrorEvent(date: now, message: "I/O error on disk10")
            .mentions("disk1"))
        // nor "rdisk1".
        XCTAssertFalse(IOErrorEvent(date: now, message: "error on rdisk1")
            .mentions("disk1"))
        XCTAssertFalse(IOErrorEvent(date: now, message: "").mentions("disk1"))
        XCTAssertFalse(IOErrorEvent(date: now, message: "disk2 error").mentions(""))
    }

    // MARK: - Scan cadence

    func testFirstScanCoversFullWindow() {
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: nil, now: now), 24 * 60)
    }

    func testRescanTooSoonIsSkipped() {
        let recent = now.addingTimeInterval(-600) // 10 min ago < 30 min gate
        XCTAssertNil(IOErrorMonitor.scanMinutes(lastScan: recent, now: now))
    }

    func testIncrementalScanCoversGapPlusOverlap() {
        let last = now.addingTimeInterval(-3_600) // 60 min ago
        // 60 min elapsed + 5 min overlap = 65.
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: last, now: now), 65)
    }

    // MARK: - Merge

    func testMergeDropsExpiredAndDeduplicates() {
        let known = [
            event(minutesAgo: 30, "a"),
            event(minutesAgo: 23 * 60, "b"),
            event(minutesAgo: 25 * 60, "old"), // outside 24h window → dropped
        ]
        let fresh = [
            event(minutesAgo: 30, "a"),        // duplicate of known → not re-added
            event(minutesAgo: 5, "c"),         // new
        ]
        let merged = IOErrorMonitor.merge(known: known, fresh: fresh, now: now)
        XCTAssertEqual(merged.map(\.message).sorted(), ["a", "b", "c"])
    }

    // MARK: - Counts

    func testCountsUseExactDeviceMatch() {
        let events = [
            event(minutesAgo: 1, "I/O error on disk1"),
            event(minutesAgo: 2, "I/O error on disk1s3"),
            event(minutesAgo: 3, "I/O error on disk10"), // must not count for disk1
        ]
        let counts = IOErrorMonitor.counts(events: events, bsdNames: ["disk1", "disk10"])
        XCTAssertEqual(counts["disk1"], 2)
        XCTAssertEqual(counts["disk10"], 1)
    }
    func testScanWindowIsCappedAfterSleepAndRecoversFromClockRollback() {
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: now.addingTimeInterval(-3 * 86400), now: now), 1440)
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: now.addingTimeInterval(60), now: now), 1440)
        XCTAssertEqual(IOErrorMonitor.scanMinutes(lastScan: Date(timeIntervalSince1970: .nan), now: now), 1440)
    }
    func testMergeDeduplicatesFreshRowsAndDropsFutureEvents() {
        let duplicate = event(minutesAgo: 1, "same")
        let future = event(minutesAgo: -1, "future")
        XCTAssertEqual(IOErrorMonitor.merge(known: [], fresh: [duplicate, duplicate, future], now: now), [duplicate])
    }
    func testRollingWindowHasEventAndUTF8ByteBudgets() throws {
        let events = [event(minutesAgo: 1, "éé"), event(minutesAgo: 2, "old"), event(minutesAgo: 3, "older")]
        let bytes = try IOErrorMonitor.boundedMerge(known: [], fresh: events, now: now, messageByteLimit: 4)
        XCTAssertEqual(bytes.events, [events[0]]); XCTAssertEqual(bytes.discarded, 2)
        let count = try IOErrorMonitor.boundedMerge(known: events, fresh: [], now: now, eventLimit: 2)
        XCTAssertEqual(count.events, Array(events.prefix(2))); XCTAssertEqual(count.discarded, 1)
        XCTAssertThrowsError(try IOErrorMonitor.boundedMerge(known: [], fresh: [], now: now, eventLimit: 0))
    }
}
