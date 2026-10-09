/* No hardware commands: recording dispatchers verify the real gate. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class SelfTestCommandTests: XCTestCase {
    func testBackgroundSleepingHDDDoesNotEnterAnySMARTOrLogRead() throws {
        let hdd = DriveInfo(registryEntryID: 987654321, bsdName: "disk9999", model: "Fixture", serialNumber: "S",
            firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: false, smartInterface: .ata)
        var reads = 0
        XCTAssertThrowsError(try DriveHardwareWorker.observeSelfTest(drive: hdd, avoidWakingIdle: true,
            powerState: { true }, read: { reads += 1; return try observation() })) {
            guard case HardwareWorkerError.deviceAsleep = $0 else { return XCTFail("must skip before SMART") }
        }
        XCTAssertEqual(reads, 0)
        _ = try DriveHardwareWorker.observeSelfTest(drive: hdd, avoidWakingIdle: false,
            powerState: { XCTFail("manual read should not check power"); return true }, read: { reads += 1; return try observation() })
        XCTAssertEqual(reads, 1)
    }
    func testBackgroundSSDAndUnknownPowerKeepExistingBestEffortPolicy() throws {
        var reads = 0
        _ = try DriveHardwareWorker.observeSelfTest(drive: drive, avoidWakingIdle: true,
            powerState: { XCTFail("SSD does not check power"); return true }, read: { reads += 1; return try observation() })
        let hdd = DriveInfo(registryEntryID: 987654321, bsdName: "disk9999", model: "Fixture", serialNumber: "S",
            firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: false, smartInterface: .ata)
        _ = try DriveHardwareWorker.observeSelfTest(drive: hdd, avoidWakingIdle: true,
            powerState: { nil }, read: { reads += 1; return try observation() })
        XCTAssertEqual(reads, 2)
    }
    let drive = DriveInfo(registryEntryID: 987654321, bsdName: "disk9999", model: "Fixture", serialNumber: "S",
        firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
    func observation(head: Int = 1, status: UInt8 = 0, supported: Bool? = true, serial: String = "S") throws -> SelfTestObservation {
        .init(reading: .init(capturedAt: SelfTestTrackingFixture.date(3),
            identify: .init(model: "Fixture", serialNumber: serial, firmwareRevision: "F", rotationRate: 1), attributes: [],
            overallFailurePredicted: nil, selfTest: .init(rawByte: status), driveFamily: nil, driveWarning: nil,
            selfTestSupported: supported), log: try SelfTestTrackingFixture.log(head, at: 4))
    }
    func command(kind: SelfTestRunKind = .short) throws -> SelfTestCommand {
        .init(runID: UUID(), driveKey: DriveIdentity.resolve(for: drive).key, kind: kind, baseline: try SelfTestTrackingFixture.log(1))
    }
    func testACKMatchesRunAndExactlyOneDispatcherInvocation() throws {
        for kind in [SelfTestRunKind.short, .extended] {
            let command = try command(kind: kind); var calls = 0
            let receipt = try DriveHardwareWorker.dispatchSelfTest(drive: drive, command: command, observe: { try observation() },
                dispatch: { XCTAssertEqual($0, kind == .extended); calls += 1 }, now: { SelfTestTrackingFixture.date(5) })
            XCTAssertEqual(calls, 1); XCTAssertEqual(receipt.runID, command.runID); XCTAssertEqual(receipt.acceptedAt, SelfTestTrackingFixture.date(5))
        }
    }
    func testChangedLogIdentityRunningUnsupportedUnknownAndMalformedAllPreventDispatch() throws {
        let samples = [try observation(head: 2), try observation(serial: "other"), try observation(status: 0xf5),
                       try observation(supported: false), try observation(supported: nil), try observation(status: 0xfa)]
        for sample in samples {
            var calls = 0
            XCTAssertThrowsError(try DriveHardwareWorker.dispatchSelfTest(drive: drive, command: command(), observe: { sample }, dispatch: { _ in calls += 1 })) {
                guard case SelfTestCommandError.notIssued = $0 else { return XCTFail("must prove not issued") }
            }
            XCTAssertEqual(calls, 0)
        }
    }
    func testObservationFailureAndObservedKindNeverDispatch() throws {
        var calls = 0
        for kind in [SelfTestRunKind.short, .observed] {
            XCTAssertThrowsError(try DriveHardwareWorker.dispatchSelfTest(drive: drive, command: command(kind: kind),
                observe: { throw HardwareWorkerError.selfTestUnavailable }, dispatch: { _ in calls += 1 })) {
                guard case SelfTestCommandError.notIssued = $0 else { return XCTFail("not issued") }
            }
        }
        XCTAssertEqual(calls, 0)
    }
    func testDispatcherFailuresRemainTypedAndUntypedFailureIsUncertain() throws {
        for error in [SelfTestCommandError.notIssued("session"), .uncertain("IOKit")] {
            XCTAssertThrowsError(try DriveHardwareWorker.dispatchSelfTest(drive: drive, command: command(),
                observe: { try observation() }, dispatch: { _ in throw error })) {
                XCTAssertEqual($0.localizedDescription, error.localizedDescription)
            }
        }
        XCTAssertThrowsError(try DriveHardwareWorker.dispatchSelfTest(drive: drive, command: command(),
            observe: { try observation() }, dispatch: { _ in throw HardwareWorkerError.protocolViolation })) {
            guard case SelfTestCommandError.uncertain = $0 else { return XCTFail("dispatcher may have already issued the command") }
        }
    }
    func testProtocolRejectsUnmatchedAndStaleReceipts() throws {
        let command = try command(), request = HardwareRequest(operation: .dispatchSelfTest(drive, command: command, lockToken: UUID()))
        let client = HardwareWorkerClient(executable: "/unused")
        let good = SelfTestReceipt(runID: command.runID, acceptedAt: SelfTestTrackingFixture.date(5))
        _ = try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .selfTestReceipt(good))), for: request)
        for receipt in [SelfTestReceipt(runID: UUID(), acceptedAt: good.acceptedAt),
                        .init(runID: command.runID, acceptedAt: SelfTestTrackingFixture.date(0))] {
            XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .selfTestReceipt(receipt))), for: request))
        }
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .acknowledged)), for: request))
    }
    func testProtocolFailureStageOnlyValidForDispatchAndCannotAccompanyValue() throws {
        let command = try command(), client = HardwareWorkerClient(executable: "/unused")
        let request = HardwareRequest(operation: .dispatchSelfTest(drive, command: command, lockToken: UUID()))
        for stage in [HardwareReply.SelfTestFailureKind.notIssued, .uncertain] {
            XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, failure: "fixture", selfTestFailure: stage)), for: request)) {
                XCTAssertTrue($0 is SelfTestCommandError)
            }
        }
        let other = HardwareRequest(operation: .enumerate)
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: other.id, failure: "fixture", selfTestFailure: .notIssued)), for: other))
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id,
            value: .selfTestReceipt(.init(runID: command.runID, acceptedAt: SelfTestTrackingFixture.date(5))), selfTestFailure: .uncertain)), for: request))
    }
    func testLegacyReadingCodableLeavesCapabilityUnknown() throws {
        let sample = try observation()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample.reading)) as? [String: Any])
        object.removeValue(forKey: "selfTestSupported")
        let legacy = try JSONDecoder().decode(ATASMARTReading.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.selfTestSupported)
        XCTAssertEqual(try JSONDecoder().decode(ATASMARTReading.self, from: JSONEncoder().encode(sample.reading)).selfTestSupported, true)
    }
}
