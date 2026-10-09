/*
 * SelfTestLogTests.swift — ATA self-test log (0x06) parsing.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class SelfTestLogTests: XCTestCase {
    /// Builds a 512-byte log with the given descriptors placed in slots 0...
    /// and the most-recent index at byte 508.
    private func log(entries: [(type: UInt8, status: UInt8, hours: UInt16, lba: UInt32)],
                     mostRecent: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 512)
        data[0] = 0x01 // revision
        for (slot, entry) in entries.enumerated() {
            let offset = 2 + slot * 24
            data[offset] = entry.type
            data[offset + 1] = entry.status
            data[offset + 2] = UInt8(entry.hours & 0xFF)
            data[offset + 3] = UInt8(entry.hours >> 8)
            for byte in 0..<4 {
                data[offset + 5 + byte] = UInt8((entry.lba >> (8 * byte)) & 0xFF)
            }
        }
        data[508] = UInt8(mostRecent)
        return ATAFixtures.checksummed(data)
    }

    func testEmptyLog() {
        XCTAssertTrue(ATAParser.parseSelfTestLog([UInt8](repeating: 0, count: 512)).isEmpty)
    }

    func testEntriesComeBackNewestFirst() {
        // Slot 0: older short test; slot 1: newer extended test (most recent).
        let data = log(entries: [
            (type: 1, status: 0x00, hours: 100, lba: 0),
            (type: 2, status: 0x00, hours: 200, lba: 0),
        ], mostRecent: 2)
        let entries = ATAParser.parseSelfTestLog(data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].powerOnHours, 200)
        XCTAssertTrue(entries[0].isExtended)
        XCTAssertTrue(entries[0].passed)
        XCTAssertEqual(entries[1].powerOnHours, 100)
        XCTAssertFalse(entries[1].isExtended)
    }

    func testReadFailureCarriesLBA() {
        let data = log(entries: [
            (type: 1, status: 0x70, hours: 500, lba: 0x00AB_CDEF),
        ], mostRecent: 1)
        let entries = ATAParser.parseSelfTestLog(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].passed)
        XCTAssertEqual(entries[0].statusCode, 7)
        XCTAssertEqual(entries[0].failingLBA, 0x00AB_CDEF)
    }

    func testPassedTestHasNoLBA() {
        let data = log(entries: [(type: 1, status: 0x00, hours: 1, lba: 123)],
                       mostRecent: 1)
        XCTAssertNil(ATAParser.parseSelfTestLog(data)[0].failingLBA)
    }

    func testAbortedStatus() {
        let data = log(entries: [(type: 2, status: 0x10, hours: 50, lba: 0)],
                       mostRecent: 1)
        let entry = ATAParser.parseSelfTestLog(data)[0]
        XCTAssertTrue(entry.wasAborted)
        XCTAssertFalse(entry.passed)
    }

    func testBogusMostRecentIndexIsRejected() {
        var data = [UInt8](repeating: 0, count: 512)
        data[508] = 200 // out of the 1...21 range
        XCTAssertTrue(ATAParser.parseSelfTestLog(data).isEmpty)
    }
}
