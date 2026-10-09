/* Identity isolation regressions. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class DriveIdentityTests: XCTestCase {
    private func drive(_ id: UInt64 = 1, serial: String? = nil, uuid: String? = nil,
                       model: String = "Same model", bsd: String = "disk1") -> DriveInfo {
        .init(registryEntryID: id, bsdName: bsd, model: model, serialNumber: serial,
              mediaUUID: uuid, firmwareRevision: "F", sizeBytes: 1_000_000,
              interconnect: "USB", location: "External", isSolidState: true, smartInterface: .ata)
    }
    func testUnknownSameModelAndCapacityAreIsolated() {
        let a = DriveIdentity.resolve(for: drive(1), session: "boot")
        let b = DriveIdentity.resolve(for: drive(2), session: "boot")
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertFalse(a.isPersistent)
        XCTAssertEqual(a.key, DriveIdentity.resolve(for: drive(1, bsd: "disk9"), session: "boot").key)
        XCTAssertNotEqual(a.key, DriveIdentity.resolve(for: drive(1), session: "next-boot").key)
    }
    func testStableSerialSurvivesRebootReplugAndBSDRename() {
        let a = DriveIdentity.resolve(for: drive(1, serial: "SN-A"), session: "boot")
        let b = DriveIdentity.resolve(for: drive(9, serial: "SN-A", bsd: "disk7"), session: "next")
        XCTAssertEqual(a.key, b.key)
        XCTAssertTrue(b.isPersistent)
        XCTAssertNotEqual(a.key, DriveIdentity.resolve(for: drive(serial: "SN-B")).key)
        XCTAssertFalse(a.key.contains("SN-A"))
    }
    func testPlaceholderSerialsNeverMergeHistory() {
        for serial in ["", "unknown", " DEFAULT ", "0000", "FFFF", "0123456789", "123456789", "N/A", "bad\u{00}serial", String(repeating: "a", count: 257)] {
            XCTAssertFalse(DriveIdentity.resolve(for: drive(serial: serial)).isPersistent, serial)
        }
    }
    func testMediaUUIDFallbackIsStableButInvalidUUIDIsNot() {
        let uuid = "cc24bd08-2cfb-4b73-b7f8-0d5af4f054bc"
        let a = DriveIdentity.resolve(for: drive(1, serial: "unknown", uuid: uuid))
        let b = DriveIdentity.resolve(for: drive(99, uuid: uuid.uppercased(), bsd: "disk7"))
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.source, .mediaUUID)
        for invalid in ["not-a-uuid", "00000000-0000-0000-0000-000000000000"] {
            XCTAssertFalse(DriveIdentity.resolve(for: drive(uuid: invalid)).isPersistent)
        }
    }
    func testSMARTSerialReplacesDiscoveryPlaceholderAndMatchesDiscoveryIdentity() {
        let reading = DriveReading.ata(.init(capturedAt: Date(),
            identify: .init(model: "Same model", serialNumber: "SN-A", firmwareRevision: "F", rotationRate: 1),
            attributes: [], overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil))
        let identity = DriveIdentity.resolve(for: drive(serial: "unknown"), reading: reading)
        XCTAssertEqual(identity.source, .smartSerial)
        XCTAssertEqual(identity.key, DriveIdentity.resolve(for: drive(serial: "SN-A")).key)
    }
    func testDuplicateStableSerialsStayIsolatedAfterOneUnplugs() throws {
        let a = drive(1, serial: "DUPLICATE"), b = drive(2, serial: "DUPLICATE")
        let original = DriveIdentity.resolve(for: a)
        let fleet = DriveIdentity.isolatedFleet([(a, original), (b, DriveIdentity.resolve(for: b))], session: "boot")
        XCTAssertNotEqual(fleet[a.id]?.key, fleet[b.id]?.key)
        XCTAssertEqual(fleet[a.id]?.source, .ambiguous)
        let remaining = DriveIdentity.isolatedFleet([(a, original)], session: "boot", knownAmbiguousKeys: [original.key])
        XCTAssertEqual(remaining[a.id], fleet[a.id])
    }
    func testLengthPrefixesPreventModelSerialDelimiterCollision() {
        let a = DriveIdentity.resolve(for: drive(serial: "B#C", model: "A"))
        let b = DriveIdentity.resolve(for: drive(serial: "C", model: "A#B"))
        XCTAssertNotEqual(a.key, b.key)
    }
    func testNotificationFollowsIdentityRatherThanReusedRegistryID() throws {
        let original = DriveIdentity.resolve(for: drive(1, serial: "SN-A"))
        let key = try XCTUnwrap(DriveIdentity.notificationKey(from: XCTUnwrap(DriveIdentity.notificationURL(forKey: original.key))))
        let replacement = DriveIdentity.resolve(for: drive(1, serial: "SN-B"))
        let reconnected = DriveIdentity.resolve(for: drive(9, serial: "SN-A"))
        XCTAssertEqual(DriveIdentity.matchingRegistryID(forKey: key, in: [(1, replacement), (9, reconnected)]), 9)
        XCTAssertNil(DriveIdentity.matchingRegistryID(forKey: key, in: [(1, replacement)]))
        XCTAssertNil(DriveIdentity.matchingRegistryID(forKey: key, in: [(1, original), (9, original)]))
    }
    func testUnknownNotificationCannotSelectNewSessionOrRepluggedDrive() {
        let old = DriveIdentity.resolve(for: drive(1), session: "before")
        XCTAssertNil(DriveIdentity.matchingRegistryID(forKey: old.key, in: [(1, DriveIdentity.resolve(for: drive(1), session: "after"))]))
        XCTAssertNil(DriveIdentity.matchingRegistryID(forKey: old.key, in: [(2, DriveIdentity.resolve(for: drive(2), session: "before"))]))
    }
    func testMalformedAndOldRegistryDeepLinksAreRejected() throws {
        for raw in ["mdrivehealth://drive/1", "https://drive?key=drive:v2:x", "mdrivehealth://drive?key=drive:v2:x&key=drive:v2:y", "mdrivehealth://other?key=drive:v2:x"] {
            XCTAssertNil(DriveIdentity.notificationKey(from: try XCTUnwrap(URL(string: raw))))
        }
    }
}
