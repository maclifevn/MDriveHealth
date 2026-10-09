/* Real SQLite restart, concurrency and transaction faults.
 * MDriveHealth, GPL-3.0-or-later. */
import XCTest
import SQLite3
@testable import MDriveHealthCore

final class SelfTestJournalTests: XCTestCase {
    func testLatestCompletionIsScopedAndCorruptLatestNeverBecomesEmptyHistory() throws {
        let store = try HistoryStore(databaseURL: url), (completed, events) = try completion()
        _ = try store.commitSelfTest(completed, expectedRevision: 0, events: events)
        var state = completed
        try state.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(2, at: 11), at: SelfTestTrackingFixture.date(12))
        let id = try XCTUnwrap(state.activeRun?.id)
        try state.markCommandPending(runID: id); try state.markAccepted(runID: id, at: SelfTestTrackingFixture.date(12))
        let second = try state.observe(log: SelfTestTrackingFixture.log(3, at: 20, status: 0x70), status: .init(rawByte: 0x70))
        _ = try store.commitSelfTest(state, expectedRevision: 1, events: second)
        XCTAssertEqual(try store.latestSelfTestEvent(driveKey: state.driveKey)?.event.id, id)
        XCTAssertEqual(try store.latestSelfTestEvent(driveKey: state.driveKey)?.event.outcome, .failed)
        XCTAssertNil(try store.latestSelfTestEvent(driveKey: "another-key"))
        try execute("UPDATE self_test_events SET event=X'FFFF' WHERE id='\(id.uuidString)'")
        XCTAssertThrowsError(try store.latestSelfTestEvent(driveKey: state.driveKey))
    }
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("history.db") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("self-test-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func completion() throws -> (SelfTestTrackingState, [SelfTestCompletion]) {
        var state = try SelfTestTrackingFixture.accepted()
        let events = try state.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
        return (state,events)
    }
    private func execute(_ sql: String) throws {
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        try HistoryTestFixtures.execute(sql, db: db)
    }
    func testRealDatabaseRestartKeepsAcceptedRunAndPersistsCompletionExactlyOnce() throws {
        do {
            let store = try HistoryStore(databaseURL: url), state = try SelfTestTrackingFixture.accepted()
            let saved = try store.commitSelfTest(state, expectedRevision: 0)
            XCTAssertEqual(saved.revision, 1)
        }
        do {
            let store = try HistoryStore(databaseURL: url), restored = try XCTUnwrap(store.selfTestState(driveKey: "ata-fixture-stable"))
            var next = restored.state
            let event = try next.observe(log: SelfTestTrackingFixture.log(2, at: 10), status: .init(rawByte: 0))
            XCTAssertEqual(event.count, 1)
            _ = try store.commitSelfTest(next, expectedRevision: restored.revision, events: event)
        }
        let store = try HistoryStore(databaseURL: url), restored = try XCTUnwrap(store.selfTestState(driveKey: "ata-fixture-stable"))
        var next = restored.state
        XCTAssertTrue(try next.observe(log: SelfTestTrackingFixture.log(2, at: 20), status: .init(rawByte: 0)).isEmpty)
        XCTAssertEqual(try store.selfTestEvents().count, 1); XCTAssertEqual(try store.selfTestEvents()[0].delivery, .pending)
    }
    func testTwoConnectionsRejectStaleRevisionWithoutOverwritingStateOrEvents() throws {
        let first = try HistoryStore(databaseURL: url), second = try HistoryStore(databaseURL: url)
        let original = try SelfTestTrackingFixture.accepted(); _ = try first.commitSelfTest(original, expectedRevision: 0)
        let (finished,events) = try completion(); _ = try first.commitSelfTest(finished, expectedRevision: 1, events: events)
        XCTAssertThrowsError(try second.commitSelfTest(original, expectedRevision: 1)) { XCTAssertTrue($0 is SelfTestJournalError) }
        XCTAssertEqual(try second.selfTestState(driveKey: original.driveKey)?.state, finished)
        XCTAssertEqual(try second.selfTestEvents().map(\.event), events)
    }
    func testEventInsertionFailureRollsBackStateAndAllowsSameTransitionRetry() throws {
        let store = try HistoryStore(databaseURL: url), original = try SelfTestTrackingFixture.accepted()
        _ = try store.commitSelfTest(original, expectedRevision: 0)
        try execute("CREATE TRIGGER reject_self_test_event BEFORE INSERT ON self_test_events BEGIN SELECT RAISE(ABORT,'fixture event full'); END")
        let (finished,events) = try completion()
        XCTAssertThrowsError(try store.commitSelfTest(finished, expectedRevision: 1, events: events))
        XCTAssertEqual(try store.selfTestState(driveKey: original.driveKey)?.state, original)
        XCTAssertEqual(try store.selfTestState(driveKey: original.driveKey)?.revision, 1); XCTAssertTrue(try store.selfTestEvents().isEmpty)
        try execute("DROP TRIGGER reject_self_test_event")
        _ = try store.commitSelfTest(finished, expectedRevision: 1, events: events)
        XCTAssertEqual(try store.selfTestEvents().count, 1)
    }
    func testDuplicateEventIDIsIdempotentButDifferentPayloadIsRejectedAtomically() throws {
        let store = try HistoryStore(databaseURL: url), (state,events) = try completion()
        _ = try store.commitSelfTest(state, expectedRevision: 0, events: events)
        _ = try store.commitSelfTest(state, expectedRevision: 1, events: events)
        XCTAssertEqual(try store.selfTestEvents().count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(events[0])) as? [String:Any])
        json["createdAt"] = SelfTestTrackingFixture.date(11).timeIntervalSinceReferenceDate
        let changed = try JSONDecoder().decode(SelfTestCompletion.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try store.commitSelfTest(state, expectedRevision: 2, events: [changed]))
        XCTAssertEqual(try store.selfTestState(driveKey: state.driveKey)?.revision, 2)
    }
    func testDeliveryClaimSurvivesRestartAndRequiresExplicitUncertainReconciliation() throws {
        let (state,events) = try completion(), id = try XCTUnwrap(events.first?.id)
        do {
            let store = try HistoryStore(databaseURL: url); _ = try store.commitSelfTest(state, expectedRevision: 0, events: events)
            XCTAssertTrue(try store.transitionSelfTestEvent(id: id, from: .pending, to: .sending))
            XCTAssertFalse(try store.transitionSelfTestEvent(id: id, from: .pending, to: .sending))
        }
        let store = try HistoryStore(databaseURL: url)
        XCTAssertEqual(try store.selfTestEvents().first?.delivery, .sending)
        XCTAssertTrue(try store.transitionSelfTestEvent(id: id, from: .sending, to: .uncertain))
        XCTAssertTrue(try store.selfTestEvents(states: [.pending]).isEmpty)
        XCTAssertTrue(try store.transitionSelfTestEvent(id: id, from: .uncertain, to: .delivered))
        XCTAssertThrowsError(try store.transitionSelfTestEvent(id: id, from: .delivered, to: .pending))
    }
    func testReadOnlyAndBusyCannotConsumeAcceptedIntent() throws {
        let seed = try HistoryStore(databaseURL: url), original = try SelfTestTrackingFixture.accepted()
        _ = try seed.commitSelfTest(original, expectedRevision: 0)
        let readOnly = try HistoryStore(databaseURL: url, accessMode: .readOnly), (finished,events) = try completion()
        XCTAssertThrowsError(try readOnly.commitSelfTest(finished, expectedRevision: 1, events: events)) {
            XCTAssertEqual(($0 as? HistoryError)?.sqliteCode, SQLITE_READONLY)
        }
        let writer = try HistoryStore(databaseURL: url, busyTimeoutMilliseconds: 1), lock = try HistoryTestFixtures.open(url)
        defer { sqlite3_close(lock) }; try HistoryTestFixtures.execute("BEGIN IMMEDIATE", db: lock)
        XCTAssertThrowsError(try writer.commitSelfTest(finished, expectedRevision: 1, events: events)) {
            XCTAssertEqual(($0 as? HistoryError)?.sqliteCode, SQLITE_BUSY)
        }
        try HistoryTestFixtures.execute("ROLLBACK", db: lock)
        XCTAssertEqual(try seed.selfTestState(driveKey: original.driveKey)?.state, original)
        XCTAssertTrue(try seed.selfTestEvents().isEmpty)
    }
    func testCorruptWrongKeyOversizedAndInvalidUTF8StateNeverLoadAsEmpty() throws {
        let store = try HistoryStore(databaseURL: url), original = try SelfTestTrackingFixture.accepted()
        _ = try store.commitSelfTest(original, expectedRevision: 0)
        for expression in ["'bad json'", "'{}'", "CAST(zeroblob(65537) AS TEXT)", "CAST(X'FF' AS TEXT)"] {
            try execute("UPDATE self_test_tracking SET state=" + expression)
            XCTAssertThrowsError(try store.selfTestState(driveKey: original.driveKey))
        }
    }
    func testStoredEventTimestampAndDeliveryPayloadMismatchAreExplicitErrors() throws {
        let store = try HistoryStore(databaseURL: url), (state,events) = try completion()
        _ = try store.commitSelfTest(state, expectedRevision: 0, events: events)
        try execute("UPDATE self_test_events SET created_at=0")
        XCTAssertThrowsError(try store.selfTestEvents())
    }
    func testQueryBudgetReturnsErrorInsteadOfAnApparentlyCompletePrefix() throws {
        let store = try HistoryStore(databaseURL: url), (state,events) = try completion()
        _ = try store.commitSelfTest(state, expectedRevision: 0, events: events)
        var next = state
        try next.prepare(kind: .short, baseline: SelfTestTrackingFixture.log(2, at: 11), at: SelfTestTrackingFixture.date(12))
        let id = try XCTUnwrap(next.activeRun?.id); try next.markCommandPending(runID: id); try next.markAccepted(runID: id, at: SelfTestTrackingFixture.date(12))
        let more = try next.observe(log: SelfTestTrackingFixture.log(3, at: 20), status: .init(rawByte: 0))
        _ = try store.commitSelfTest(next, expectedRevision: 1, events: more)
        XCTAssertThrowsError(try store.selfTestEvents(limit: 1)); XCTAssertEqual(try store.selfTestEvents().count, 2)
    }
    func testFullOutboxRollsBackCompletionAndRevisionUntilCapacityIsAvailable() throws {
        let store = try HistoryStore(databaseURL: url), original = try SelfTestTrackingFixture.accepted()
        _ = try store.commitSelfTest(original, expectedRevision: 0)
        let (_, events) = try completion()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(events[0])) as? [String:Any])
        json["source"] = "external"; json.removeValue(forKey: "runID")
        var statements = "BEGIN IMMEDIATE;"
        for _ in 0..<4096 {
            let id = UUID().uuidString; json["id"] = id
            let body = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            statements += "INSERT INTO self_test_events VALUES('\(id)','ata-fixture-stable',1700000010,'\(body)','pending');"
        }
        statements += "COMMIT;"; try execute(statements)
        let (finished,newEvents) = try completion()
        XCTAssertThrowsError(try store.commitSelfTest(finished, expectedRevision: 1, events: newEvents)) { XCTAssertTrue($0 is SelfTestJournalError) }
        XCTAssertEqual(try store.selfTestState(driveKey: original.driveKey)?.state, original)
        XCTAssertEqual(try store.selfTestState(driveKey: original.driveKey)?.revision, 1)
        try execute("UPDATE self_test_events SET delivery_state='suppressed'")
        _ = try store.commitSelfTest(finished, expectedRevision: 1, events: newEvents)
        XCTAssertEqual(try store.selfTestEvents(states: [.pending]).count, 1)
    }
    func testVersion3MigrationIsAdditiveAndBackupRetainsOldSchemaAndSentinel() throws {
        do { _ = try HistoryStore(databaseURL: url) }
        try execute("DROP TABLE measurement_jobs; DROP TABLE self_test_events; DROP TABLE self_test_tracking; CREATE TABLE sentinel(value); INSERT INTO sentinel VALUES('keep'); PRAGMA user_version=3")
        let store = try HistoryStore(databaseURL: url), backup = try XCTUnwrap(store.migrationBackupURL)
        try store.serialQueue.sync {
            XCTAssertEqual(try store.scalarInt("PRAGMA user_version"), 5)
            XCTAssertEqual(try store.scalarText("SELECT value FROM sentinel"), "keep")
        }
        let old = try HistoryTestFixtures.open(backup); defer { sqlite3_close(old) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: old), "3")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT value FROM sentinel", db: old), "keep")
    }
    func testVersion3MigrationCollisionRollsBackWithoutVersionOrTableLoss() throws {
        do { _ = try HistoryStore(databaseURL: url) }
        try execute("DROP TABLE self_test_events; DROP TABLE self_test_tracking; CREATE TABLE self_test_events(foreign_value); INSERT INTO self_test_events VALUES('keep'); PRAGMA user_version=3")
        XCTAssertThrowsError(try HistoryStore(databaseURL: url))
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: db), "3")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT foreign_value FROM self_test_events", db: db), "keep")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='self_test_tracking'", db: db), "0")
    }
    func testVersion4SchemaWithoutPrimaryKeyIsRejectedWithoutRepair() throws {
        do { _ = try HistoryStore(databaseURL: url) }
        try execute("DROP TABLE measurement_jobs; DROP TABLE self_test_tracking; CREATE TABLE self_test_tracking(drive_key TEXT,revision INTEGER,state TEXT); PRAGMA user_version=4")
        XCTAssertThrowsError(try HistoryStore(databaseURL: url))
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: db), "4")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM pragma_table_info('self_test_tracking') WHERE pk>0", db: db), "0")
    }
}
