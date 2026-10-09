/* Ring validity and identity fixtures. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class SelfTestLogSnapshotTests: XCTestCase {
    private func page(head: UInt8 = 1, slot: Int = 1, status: UInt8 = 0, revision: UInt8 = 1) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: 512); page[0] = revision; page[508] = head
        if head != 0 { page[2 + (slot - 1) * 24] = 1; page[3 + (slot - 1) * 24] = status; page[4 + (slot - 1) * 24] = 123 }
        return ATAFixtures.checksummed(page)
    }
    func testValidEmptyLogIsDistinctFromZeroChecksumFailureOrUnsupportedRevision() throws {
        let empty = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(page(head: 0)))
        XCTAssertEqual(empty.mostRecentSlot, 0); XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(Array(repeating: 0, count: 512)))
        var invalid = page(); invalid[511] ^= 1
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(invalid))
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(page(revision: 2)))
    }
    func testChronologicalIndexDoesNotReplacePhysicalRingSlot() throws {
        let first = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(page(head: 21, slot: 21)))
        let second = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(page(head: 1)))
        XCTAssertEqual(first.latest?.index, 1); XCTAssertEqual(second.latest?.index, 1)
        XCTAssertEqual(first.latest?.physicalSlot, 21); XCTAssertEqual(second.latest?.physicalSlot, 1)
        XCTAssertEqual(first.latest?.powerOnHours, second.latest?.powerOnHours)
        XCTAssertFalse(second.sameContents(as: first))
    }
    func testInvalidHeadPointerAndPointerIntoEmptyDescriptorAreUnavailable() {
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(page(head: 22)))
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(page(head: 2, slot: 1)))
        var contradictory = page(head: 0); contradictory[2] = 1
        contradictory = ATAFixtures.checksummed(contradictory)
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(contradictory))
    }
    func testCaptureTimestampAndUnrelatedVendorBytesDoNotCreateNewRecordIdentity() throws {
        let first = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(page(), capturedAt: SelfTestTrackingFixture.date(1)))
        var bytes = page(); bytes[506] = 44; bytes[511] = 0; bytes = ATAFixtures.checksummed(bytes)
        let second = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(bytes, capturedAt: SelfTestTrackingFixture.date(2)))
        XCTAssertTrue(second.sameContents(as: first))
    }
    func testSamsungPointerAndDescriptorByteQuirkRetainsSlotIdentity() throws {
        var bytes = page(head: 2, slot: 2)
        bytes.swapAt(508,509)
        for slot in 0..<21 { bytes.swapAt(2 + slot * 24,3 + slot * 24) }
        let log = try XCTUnwrap(ATAParser.parseSelfTestLogSnapshot(bytes, firmwareFixes: ["samsung"]))
        XCTAssertEqual(log.mostRecentSlot, 2); XCTAssertEqual(log.latest?.physicalSlot, 2); XCTAssertEqual(log.latest?.testType, 1)
    }
    func testSnapshotRejectsMissingDuplicateSlotBadOrderInvalidProgressAndTimestamp() throws {
        let first = ATASelfTestLogEntry(index: 1, testType: 1, statusByte: 0, powerOnHours: 1, failingLBA: nil, physicalSlot: 1)
        let missing = ATASelfTestLogEntry(index: 1, testType: 1, statusByte: 0, powerOnHours: 1, failingLBA: nil)
        XCTAssertThrowsError(try ATASelfTestLog(capturedAt: Date(), mostRecentSlot: 1, entries: [missing]))
        XCTAssertThrowsError(try ATASelfTestLog(capturedAt: Date(), mostRecentSlot: 1, entries: [first,first]))
        XCTAssertThrowsError(try ATASelfTestLog(capturedAt: Date(timeIntervalSince1970: .infinity), mostRecentSlot: 1, entries: [first]))
        XCTAssertNil(ATAParser.parseSelfTestLogSnapshot(page(status: 0xff)))
        let wrong = ATASelfTestLogEntry(index: 2, testType: 1, statusByte: 0, powerOnHours: 1, failingLBA: nil, physicalSlot: 1)
        XCTAssertThrowsError(try ATASelfTestLog(capturedAt: Date(), mostRecentSlot: 1, entries: [wrong]))
    }
}
