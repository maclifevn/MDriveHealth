/* Behavioral run/log transitions. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

enum SelfTestTrackingFixture {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static func date(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }
    static func log(_ head: Int, at: TimeInterval = 1, status: UInt8 = 0, type: UInt8 = 1,
                    hours: UInt64 = 123, full: Bool = false) throws -> ATASelfTestLog {
        let slots = head == 0 ? [] : (full ? Array(0..<21) : [0])
        let entries = slots.map { back in ATASelfTestLogEntry(index: back + 1, testType: type, statusByte: status,
            powerOnHours: hours, failingLBA: status >> 4 == 7 ? 42 : nil,
            physicalSlot: (head - 1 - back + 21) % 21 + 1) }
        return try .init(capturedAt: date(at), mostRecentSlot: head, entries: entries)
    }
    static func state() throws -> SelfTestTrackingState { try .init(driveKey: "ata-fixture-stable", model: "Fixture") }
    static func accepted(_ head: Int = 1, type: SelfTestRunKind = .short, at: TimeInterval = 2, full: Bool = false) throws -> SelfTestTrackingState {
        var state = try state(); let baseline = try log(head, full: full)
        try state.prepare(kind: type, baseline: baseline, at: date(at)); let id = try XCTUnwrap(state.activeRun?.id)
        try state.markCommandPending(runID: id); try state.markAccepted(runID: id, at: date(at))
        return state
    }
}

final class SelfTestTrackingTests: XCTestCase {
    func testObservedRunCompletesWhenAnotherTestAdvancesHeadBeforeNextPoll() throws {
        var state = try SelfTestTrackingFixture.state()
        _ = try state.observe(log: SelfTestTrackingFixture.log(1, at: 1, status: 0xf5), status: .init(rawByte: 0xf5))
        let id = try XCTUnwrap(state.activeRun?.id)
        let log = try ATASelfTestLog(capturedAt: SelfTestTrackingFixture.date(10), mostRecentSlot: 2, entries: [
            .init(index: 1, testType: 1, statusByte: 0, powerOnHours: 123, failingLBA: nil, physicalSlot: 2),
            .init(index: 2, testType: 1, statusByte: 0, powerOnHours: 123, failingLBA: nil, physicalSlot: 1)])
        let events = try state.observe(log: log, status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events[0].id, id); XCTAssertEqual(events[0].outcome, .passed)
        XCTAssertEqual(events[1].source, .external); XCTAssertNil(state.activeRun)
    }
    func testExplicitClosureRequiresFreshTerminalStatusAndCreatesIndeterminateResult() throws {
        var state = try SelfTestTrackingFixture.accepted()
        let id = try XCTUnwrap(state.activeRun?.id), original = state
        for sample in [try SelfTestTrackingFixture.log(1, at: 1), try SelfTestTrackingFixture.log(1, at: 10, status: 0xf5)] {
            XCTAssertThrowsError(try state.finishWithoutResult(log: sample, status: .init(rawByte: 0)))
            XCTAssertEqual(state, original)
        }
        XCTAssertThrowsError(try state.finishWithoutResult(log: SelfTestTrackingFixture.log(1, at: 10), status: .init(rawByte: 0xf5)))
        XCTAssertEqual(state, original)
        let events = try state.finishWithoutResult(log: SelfTestTrackingFixture.log(1, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].id, id); XCTAssertEqual(events[0].outcome, .indeterminate)
        XCTAssertNil(state.activeRun); XCTAssertEqual(events[0].reason, .unknownResult)
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(1, at: 11), status: .init(rawByte: 0)).isEmpty)
    }
    func testExplicitClosurePrefersActualNewResultWhenAvailable() throws {
        var state = try SelfTestTrackingFixture.accepted()
        let events = try state.finishWithoutResult(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].outcome, .passed); XCTAssertNil(state.activeRun)
    }
    func testAcceptedShortFinishesBetweenPollsWithUnchangedTerminalByteAndHours() throws {
        var state = try SelfTestTrackingFixture.accepted()
        let id = try XCTUnwrap(state.activeRun?.id)
        let events = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].id, id); XCTAssertEqual(events[0].runID, id)
        XCTAssertEqual(events[0].outcome, .passed); XCTAssertEqual(events[0].source, .requested); XCTAssertNil(state.activeRun)
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(2, at: 20), status: .init(rawByte: 0)).isEmpty)
    }
    func testConsecutivePassAndFailureResultsEachProduceOneEvent() throws {
        for status in [UInt8(0), 0x70] {
            var state = try SelfTestTrackingFixture.accepted()
            let first = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10, status: status), status: .init(rawByte: status))
            try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(2, at: 11, status: status), at: SelfTestTrackingFixture.date(12))
            let secondID = try XCTUnwrap(state.activeRun?.id); try state.markCommandPending(runID: secondID)
            try state.markAccepted(runID: secondID, at: SelfTestTrackingFixture.date(12))
            let second = try state.observe(log: SelfTestTrackingFixture.log(3, at: 20, status: status), status: .init(rawByte: status))
            XCTAssertEqual(first.count, 1); XCTAssertEqual(second.count, 1); XCTAssertNotEqual(first[0].id, second[0].id)
            XCTAssertEqual(first[0].outcome, status == 0 ? .passed : .failed)
            XCTAssertEqual(second[0].outcome, first[0].outcome)
        }
    }
    func testAbortAndResetInterruptionAreSingleNonFailureCompletions() throws {
        for status in [UInt8(0x10),0x20] {
            var state = try SelfTestTrackingFixture.accepted()
            let result = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10, status: status), status: .init(rawByte: status))
            XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].outcome, .aborted)
            XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(2, at: 11, status: status), status: .init(rawByte: status)).isEmpty)
        }
    }
    func testRoundTripRestartRetainsAcceptedIntentAndDedupBaseline() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var restored = try decoder.decode(SelfTestTrackingState.self, from: encoder.encode(SelfTestTrackingFixture.accepted()))
        XCTAssertEqual(try restored.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0)).count, 1)
        restored = try decoder.decode(SelfTestTrackingState.self, from: encoder.encode(restored))
        XCTAssertTrue(try restored.observe(log: SelfTestTrackingFixture.log(2, at: 20), status: .init(rawByte: 0)).isEmpty)
    }
    func testFullRingIdenticalDescriptorsStillDetectsSlot21To1Advance() throws {
        var state = try SelfTestTrackingFixture.accepted(21, full: true)
        let events = try state.observe(log: SelfTestTrackingFixture.log(1, at: 10, full: true), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].entry?.physicalSlot, 1); XCTAssertEqual(events[0].outcome, .passed)
    }
    func testNoFalseCompletionFromTerminalStatusAloneOrUnchangedLog() throws {
        var state = try SelfTestTrackingFixture.accepted()
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(1, at: 10), status: .init(rawByte: 0x70)).isEmpty)
        XCTAssertNotNil(state.activeRun)
    }
    func testOldCaptureCannotCompleteRunOrReplaceNewerBaseline() throws {
        var state = try SelfTestTrackingFixture.accepted()
        let original = state
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(2, at: 0), status: .init(rawByte: 0)).isEmpty)
        XCTAssertEqual(state, original)
    }
    func testObservedProgressCompletesWhenSameSlotChangesToTerminal() throws {
        var state = try SelfTestTrackingFixture.state()
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(1, at: 1, status: 0xf5), status: .init(rawByte: 0xf5)).isEmpty)
        let id = try XCTUnwrap(state.activeRun?.id)
        let result = try state.observe(log: SelfTestTrackingFixture.log(1, at: 5), status: .init(rawByte: 0))
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].id, id); XCTAssertEqual(result[0].source, .observed)
    }
    func testBootstrapHistoryDoesNotAlertButNewExternalLogDoes() throws {
        var state = try SelfTestTrackingFixture.state()
        XCTAssertTrue(try state.observe(log: SelfTestTrackingFixture.log(1), status: .init(rawByte: 0)).isEmpty)
        let events = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].source, .external); XCTAssertNil(events[0].runID)
    }
    func testPreparedIntentDoesNotClaimExternalRunBeforeCommandDispatch() throws {
        var state = try SelfTestTrackingFixture.state()
        try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(1), at: SelfTestTrackingFixture.date(2))
        let id = try XCTUnwrap(state.activeRun?.id)
        let events = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].source, .external); XCTAssertNotEqual(events[0].id, id)
        XCTAssertEqual(state.activeRun?.phase, .prepared)
    }
    func testLostAcknowledgementKeepsCommandUnconfirmedSource() throws {
        var state = try SelfTestTrackingFixture.state()
        try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(1), at: SelfTestTrackingFixture.date(2))
        let id = try XCTUnwrap(state.activeRun?.id); try state.markCommandPending(runID: id)
        let events = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].id, id); XCTAssertEqual(events[0].source, .commandUnconfirmed)
    }
    func testEmptyLogCanAcquireFirstResultWhileResetBecomesIndeterminate() throws {
        var state = try SelfTestTrackingFixture.accepted(0)
        XCTAssertEqual(try state.observe(log: SelfTestTrackingFixture.log(1, at: 10), status: .init(rawByte: 0)).first?.outcome, .passed)
        state = try SelfTestTrackingFixture.accepted()
        let result = try state.observe(log: SelfTestTrackingFixture.log(0, at: 10), status: .init(rawByte: 0))
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].outcome, .indeterminate); XCTAssertEqual(result[0].reason, .logReset)
    }
    func testUnknownLogResultNeverBecomesPassOrDefiniteDriveFailure() throws {
        var state = try SelfTestTrackingFixture.accepted()
        let result = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10, status: 0xa0), status: nil)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].outcome, .indeterminate); XCTAssertEqual(result[0].reason, .unknownResult)
    }
    func testWrongRunIdentityInvalidTransitionsAndStatusDoNotMutateState() throws {
        var state = try SelfTestTrackingFixture.accepted(), original = state
        XCTAssertThrowsError(try state.markAccepted(runID: UUID(), at: SelfTestTrackingFixture.date(2)))
        XCTAssertThrowsError(try state.rejectNotIssued(runID: try XCTUnwrap(state.activeRun?.id)))
        XCTAssertThrowsError(try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(1), at: SelfTestTrackingFixture.date(2)))
        XCTAssertThrowsError(try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0xff)))
        XCTAssertEqual(state, original)
        original = try SelfTestTrackingFixture.state(); state = original
        XCTAssertThrowsError(try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(1), at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(state, original)
    }
    func testChangingPreflightMustBeObservedBeforePreparingAndStaleLogCannotReplaceState() throws {
        var state = try SelfTestTrackingFixture.state()
        _ = try state.observe(log: SelfTestTrackingFixture.log(1, at: 5), status: .init(rawByte: 0))
        let original = state
        XCTAssertThrowsError(try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(2, at: 6), at: SelfTestTrackingFixture.date(7)))
        XCTAssertThrowsError(try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(1, at: 1), at: SelfTestTrackingFixture.date(7)))
        XCTAssertEqual(state, original)
    }
    func testGenerationOverflowDoesNotPartiallyConsumeCompletion() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SelfTestTrackingFixture.accepted())) as? [String:Any])
        json["generation"] = NSNumber(value: UInt64.max)
        var state = try JSONDecoder().decode(SelfTestTrackingState.self, from: JSONSerialization.data(withJSONObject: json))
        let original = state
        XCTAssertThrowsError(try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0)))
        XCTAssertEqual(state, original)
    }
}
