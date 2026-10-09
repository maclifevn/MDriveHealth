/* Bounded NDJSON and timestamp regressions. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

final class IOErrorScanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_813_600) // 2026-09-07 20:40 UTC
    private func record(_ time: String, _ message: String = "I/O error disk1") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": time, "eventMessage": message])
        data.append(10); return data
    }
    private func parse(_ data: Data, bsd: String? = nil) throws -> IOErrorScan {
        try IOErrorWatcher.parseNDJSON(data, since: now.addingTimeInterval(-86400), through: now, bsdName: bsd)
    }
    func testTimestampFormatsPreserveTimezoneAndFraction() throws {
        let utc = try XCTUnwrap(IOErrorWatcher.parseTimestamp("2026-09-07 20:40:00.123456+0000"))
        XCTAssertEqual(utc.timeIntervalSince1970, now.timeIntervalSince1970 + 0.123456, accuracy: 0.000001)
        XCTAssertEqual(utc, IOErrorWatcher.parseTimestamp("2026-09-08T03:40:00.123456+07:00"))
        XCTAssertEqual(utc, IOErrorWatcher.parseTimestamp("2026-09-07T20:40:00.123456Z"))
        XCTAssertEqual(IOErrorWatcher.parseTimestamp("2026-09-07 20:40:00+0000"), now)
    }
    func testInvalidCalendarTimesAndMissingTimezoneAreRejected() {
        for value in ["garbage", "2026-02-30 12:00:00+0000", "2026-13-01 12:00:00+0000", "2026-09-07 24:00:00+0000", "2026-09-07 20:40:00", "2026-09-07 20:40:00+0099", "2026-09-07 20:40:60Z"] {
            XCTAssertNil(IOErrorWatcher.parseTimestamp(value), value)
        }
    }
    func testMalformedTimestampIsDiagnosticNeverToday() throws {
        let data = try record("broken") + record("2026-09-07 20:39:00+0000")
        let scan = try parse(data)
        XCTAssertEqual(scan.events.count, 1); XCTAssertEqual(scan.diagnostics.invalidTimestamps, 1)
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(try XCTUnwrap(scan.events.first).date, now.addingTimeInterval(-60))
    }
    func testMalformedJSONAndMissingFieldsRemainIncomplete() throws {
        var data = Data("not-json\n{}\n".utf8)
        data.append(try record("2026-09-07 20:39:00+0000"))
        let scan = try parse(data); XCTAssertEqual(scan.events.count, 1)
        XCTAssertEqual(scan.diagnostics.malformedLines, 2); XCTAssertFalse(scan.isComplete)
    }
    func testOldAndFutureEventsAreNotMovedIntoWindow() throws {
        let scan = try parse(record("2001-01-01 00:00:00Z") + record("2099-01-01 00:00:00Z"))
        XCTAssertTrue(scan.events.isEmpty); XCTAssertEqual(scan.diagnostics.outsideWindow, 2)
    }
    func testEmptySuccessfulOutputDiffersFromMalformedOutput() throws {
        XCTAssertTrue(try parse(Data()).isComplete)
        XCTAssertFalse(try parse(Data("bad\n".utf8)).isComplete)
    }
    func testEventLineAndRowLimitsThrowInsteadOfReturningCollectedPrefix() throws {
        let line = try record("2026-09-07 20:39:00Z")
        XCTAssertThrowsError(try IOErrorWatcher.parseNDJSON(line + line, since: .distantPast, through: now, maximumEvents: 1))
        XCTAssertThrowsError(try IOErrorWatcher.parseNDJSON(Data(repeating: 65, count: 17), since: .distantPast, through: now, maximumLineBytes: 16))
        XCTAssertThrowsError(try IOErrorWatcher.parseNDJSON(Data("\n\n\n".utf8), since: .distantPast, through: now, maximumRows: 2))
        let exact = try IOErrorWatcher.parseNDJSON(line, since: .distantPast, through: now, maximumRows: 1)
        XCTAssertEqual(exact.events.count, 1, "trailing newline must not create a second row")
    }
    func testExactBSDFilterExcludesPrefixAndRawDeviceSubstring() throws {
        let data = try record("2026-09-07 20:39:00Z", "error disk1s2") + record("2026-09-07 20:39:01Z", "error disk10") + record("2026-09-07 20:39:02Z", "error rdisk1")
        XCTAssertEqual(try parse(data, bsd: "disk1").events.map(\.message), ["error disk1s2"])
    }
    func testScanRequestRejectsInvalidWindowsAndPredicateInjection() throws {
        for minutes in [0, -1, 1441, Int.max] {
            XCTAssertThrowsError(try IOErrorWatcher.makeCommand(withinMinutes: minutes, bsdName: nil, timeout: 1))
        }
        XCTAssertThrowsError(try IOErrorWatcher.makeCommand(withinMinutes: 1, bsdName: "disk1\" OR true", timeout: 1))
        let command = try IOErrorWatcher.makeCommand(withinMinutes: 30, bsdName: "disk1", timeout: 1)
        XCTAssertEqual(command.executable, "/usr/bin/log"); XCTAssertEqual(command.stdoutLimit, IOErrorWatcher.maximumOutputBytes)
    }
    func testParsingHonorsCancellation() throws {
        XCTAssertThrowsError(try IOErrorWatcher.parseNDJSON(record("2026-09-07 20:39:00Z"), since: .distantPast, through: now, isCancelled: { true }))
    }
    func testLogTerminalControlRecordIsAcceptedAndItsCountValidated() throws {
        let empty = try parse(Data("{\"finished\":true,\"count\":0}\n".utf8))
        XCTAssertTrue(empty.isComplete); XCTAssertTrue(empty.events.isEmpty)
        // log show on macOS 27 uses the integer 1, rather than a JSON boolean.
        XCTAssertTrue(try parse(Data("{\"count\":0,\"finished\":1}\n".utf8)).isComplete)
        let event = try record("2026-09-07 20:39:00Z")
        XCTAssertTrue(try parse(event + Data("{\"finished\":true,\"count\":1}\n".utf8)).isComplete)
        XCTAssertFalse(try parse(event + Data("{\"finished\":true,\"count\":2}\n".utf8)).isComplete)
        for invalid in ["{\"finished\":false,\"count\":0}\n", "{\"finished\":2,\"count\":0}\n", "{\"finished\":0,\"count\":0}\n", "{\"finished\":true,\"count\":true}\n", "{\"finished\":true,\"count\":-1}\n"] {
            XCTAssertFalse(try parse(Data(invalid.utf8)).isComplete)
        }
        XCTAssertFalse(try parse(Data("{\"finished\":true,\"count\":0}\n".utf8) + event).isComplete)
    }
}
