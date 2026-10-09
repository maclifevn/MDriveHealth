/* Recovery origin must outlive attachment IDs without trusting clones. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class MeasurementOriginTests: XCTestCase {
    private func drive(_ id: UInt64 = 100, serial: String? = nil) -> DriveInfo {
        .init(registryEntryID: id, bsdName: "disk999999", model: "Fixture", serialNumber: serial,
              mediaUUID: "36A92F2E-0E1F-4F1D-8B27-F6349AC7B8CC", firmwareRevision: "F", sizeBytes: 1 << 40,
              interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
    }
    func testSerialSurvivesReattachmentButFilesystemCloneDoesNot() {
        let first = MeasurementOrigin(drive: drive(serial: "original"), bootSessionID: UUID())
        XCTAssertTrue(first.matches(.init(drive: drive(101, serial: "original"), bootSessionID: UUID())))
        XCTAssertFalse(first.matches(.init(drive: drive(101, serial: "clone"), bootSessionID: first.bootSessionID)))
        let ambiguous = DriveIdentity.sessionIdentity(for: drive(serial: "original"), ambiguous: true)
        XCTAssertFalse(first.matches(.init(drive: drive(serial: "original"), identity: ambiguous, bootSessionID: first.bootSessionID)))
    }
    func testWithoutSerialOnlyExactAttachmentWithinSameBootCanResolve() {
        let boot = UUID(), first = MeasurementOrigin(drive: drive(), bootSessionID: boot)
        XCTAssertTrue(first.matches(.init(drive: drive(), bootSessionID: boot)))
        XCTAssertFalse(first.matches(.init(drive: drive(101), bootSessionID: boot)))
        XCTAssertFalse(first.matches(.init(drive: drive(), bootSessionID: UUID())))
        XCTAssertFalse(MeasurementOrigin(drive: drive(), bootSessionID: nil).matches(.init(drive: drive(), bootSessionID: nil)))
    }
    func testDuplicateSerialCannotAuthorizeAnotherAttachment() {
        let one = drive(serial: "duplicate"), two = drive(101, serial: "duplicate"), boot = UUID()
        let fleet = DriveIdentity.isolatedFleet([(one, .resolve(for: one)), (two, .resolve(for: two))])
        let original = MeasurementOrigin(drive: one, identity: fleet[one.id], bootSessionID: boot)
        XCTAssertNil(original.serialIdentityKey)
        XCTAssertFalse(original.matches(.init(drive: two, identity: fleet[two.id], bootSessionID: boot)))
        XCTAssertTrue(original.matches(.init(drive: one, identity: fleet[one.id], bootSessionID: boot)))
    }
}
