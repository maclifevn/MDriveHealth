/* Display the newest self-test status, including unknown fields. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class SelfTestDisplayTests: XCTestCase {
    private func reading(_ time: TimeInterval, status: UInt8?, supported: Bool?) -> ATASMARTReading {
        .init(capturedAt: Date(timeIntervalSince1970: time), identify: nil, attributes: [], overallFailurePredicted: nil,
              selfTest: status.map { .init(rawByte: $0) }, driveFamily: nil, driveWarning: nil, selfTestSupported: supported)
    }
    func testNewerSnapshotOverridesOlderValidatedLogReadingWithoutFillingUnknownFields() throws {
        let cached = reading(100, status: 0, supported: true)
        for status: UInt8? in [0xF5, nil] {
            let fresh = reading(200, status: status, supported: nil)
            let current = try XCTUnwrap(SelfTestDisplay.latestReading(snapshot: .ata(fresh), observation: cached))
            XCTAssertEqual(current.capturedAt, fresh.capturedAt)
            XCTAssertEqual(current.selfTest?.rawByte, status)
            XCTAssertNil(current.selfTestSupported)
        }
    }
    func testNewerObservationWinsAndAbsentSnapshotStillUsesObservation() throws {
        let snapshot = reading(100, status: 0xF9, supported: false)
        let observation = reading(200, status: nil, supported: nil)
        let current = try XCTUnwrap(SelfTestDisplay.latestReading(snapshot: .ata(snapshot), observation: observation))
        XCTAssertEqual(current.capturedAt, observation.capturedAt)
        XCTAssertNil(current.selfTest)
        XCTAssertNil(current.selfTestSupported)
        XCTAssertEqual(SelfTestDisplay.latestReading(snapshot: nil, observation: observation)?.capturedAt, observation.capturedAt)
        XCTAssertEqual(SelfTestDisplay.latestReading(snapshot: .ata(snapshot), observation: nil)?.capturedAt, snapshot.capturedAt)
        XCTAssertNil(SelfTestDisplay.latestReading(snapshot: nil, observation: nil))
    }
}
