/* Sleeping-drive read boundaries. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class HardwareInspectionTests: XCTestCase {
    private func drive(_ interface: SMARTInterfaceKind = .ata, ssd: Bool = false) -> DriveInfo {
        .init(registryEntryID: 1, bsdName: "disk1", model: "Fixture", serialNumber: "S", firmwareRevision: "F",
              sizeBytes: 1000, interconnect: "USB", location: "External", isSolidState: ssd, smartInterface: interface)
    }
    private var reading: DriveReading {
        .ata(.init(capturedAt: Date(), identify: .init(model: "Fixture", serialNumber: "S", firmwareRevision: "F", rotationRate: 7200),
                   attributes: [], overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil))
    }
    func testSleepingATAAndUnsupportedUSBDoNotReadSMARTOrFilesystemCapacity() throws {
        for interface in [SMARTInterfaceKind.ata, .unsupported] {
            var smartReads = 0, capacityReads = 0
            let result = try DriveHardwareWorker.inspect(drive: drive(interface), avoidWakingIdle: true,
                powerState: { true }, read: { smartReads += 1; return self.reading }, volumes: { capacityReads += 1; return [] })
            XCTAssertTrue(result.skippedAsleep); XCTAssertNil(result.reading); XCTAssertTrue(result.volumes.isEmpty)
            XCTAssertEqual(smartReads, 0); XCTAssertEqual(capacityReads, 0)
        }
    }
    func testManualRefreshBypassesPowerCheckAndReadsCapacity() throws {
        var powerReads = 0, smartReads = 0, capacityReads = 0
        let result = try DriveHardwareWorker.inspect(drive: drive(), avoidWakingIdle: false,
            powerState: { powerReads += 1; return true }, read: { smartReads += 1; return self.reading }, volumes: { capacityReads += 1; return [] })
        XCTAssertFalse(result.skippedAsleep); XCTAssertNotNil(result.reading)
        XCTAssertEqual(powerReads, 0); XCTAssertEqual(smartReads, 1); XCTAssertEqual(capacityReads, 1)
    }
    func testUnknownPowerAndSSDKeepReadingWhileUnsupportedTransportReadsOnlyCapacity() throws {
        for (info, power) in [(drive(), nil), (drive(ssd: true), true), (drive(.unsupported), false)] as [(DriveInfo, Bool?)] {
            var smartReads = 0, capacityReads = 0
            let result = try DriveHardwareWorker.inspect(drive: info, avoidWakingIdle: true,
                powerState: { power }, read: { smartReads += 1; return self.reading }, volumes: { capacityReads += 1; return [] })
            XCTAssertFalse(result.skippedAsleep); XCTAssertEqual(capacityReads, 1)
            XCTAssertEqual(smartReads, info.smartInterface == .unsupported ? 0 : 1)
        }
    }
    func testSleepingReplyCannotClaimFreshFilesystemCapacity() throws {
        let request = HardwareRequest(operation: .inspect(drive(), avoidWakingIdle: true))
        let volume = VolumeUsage(bsdName: "disk1s1", name: "Fixture", mountPoint: "/Volumes/Fixture", totalBytes: 1000,
                                 availableBytes: 500, sharedCapacityKey: "disk1s1")
        let bytes = try JSONEncoder().encode(HardwareReply(id: request.id, value: .inspection(.init(reading: nil, skippedAsleep: true, volumes: [volume]))))
        XCTAssertThrowsError(try HardwareWorkerClient(executable: "/bin/true").decode(bytes, for: request))
    }
}
