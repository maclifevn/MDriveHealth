/* Real SQLite fault and migration regressions. MDriveHealth, GPL-3.0-or-later. */
import XCTest
import SQLite3
@testable import MDriveHealthCore

enum HistoryTestFixtures {
    static func reading(at: Date = Date(), count: UInt64 = 0) -> DriveReading {
        .nvme(.init(controller: .init(model: "Test", serialNumber: "SN-A", firmwareRevision: "F", ieeeOUI: "0",
            controllerID: 0, specVersion: nil, totalCapacityBytes: 0, unallocatedCapacityBytes: 0,
            warningTempKelvin: 0, criticalTempKelvin: 0, namespaceCount: 1),
            smart: .init(capturedAt: at, criticalWarning: [], temperatureKelvin: 310,
                availableSpare: 100, availableSpareThreshold: 10, percentageUsed: 5,
                dataUnitsRead: 1, dataUnitsWritten: 2, hostReadCommands: 0, hostWriteCommands: 0,
                controllerBusyTimeMinutes: 0, powerCycles: 1, powerOnHours: count, unsafeShutdowns: 0,
                mediaErrors: count, errorLogEntries: 0, warningTempTimeMinutes: 0,
                criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])))
    }
    static func benchmark(at: Date = Date(), size: UInt64 = 1024, speed: Double = 100) -> BenchmarkResult {
        .init(capturedAt: at, volumeBSDName: "disk2s1", volumeName: "Test", mountPoint: "/Volumes/Test",
              fileSizeBytes: size, sequentialBlockBytes: 512, randomBlockBytes: 512,
              sequentialWriteBytesPerSec: speed, sequentialReadBytesPerSec: 100,
              randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    static let legacySchema = """
        CREATE TABLE drive_snapshots (id INTEGER PRIMARY KEY AUTOINCREMENT,drive_key TEXT NOT NULL,bsd_name TEXT,
          captured_at REAL NOT NULL,temperature_c INTEGER,health_score INTEGER,rating TEXT,lifetime_left INTEGER,
          power_on_hours INTEGER,bytes_written INTEGER,defect_count INTEGER,pending_sectors INTEGER);
        INSERT INTO drive_snapshots VALUES(1,'legacy','disk2',1,30,100,'good',90,10,20,-1,NULL);
        CREATE TABLE benchmark_results (id INTEGER PRIMARY KEY AUTOINCREMENT,drive_key TEXT NOT NULL,bsd_name TEXT,
          volume_name TEXT,mount_point TEXT,captured_at REAL NOT NULL,file_size INTEGER NOT NULL,
          seq_block INTEGER NOT NULL,rand_block INTEGER NOT NULL,seq_write_bps REAL NOT NULL,
          seq_read_bps REAL NOT NULL,rand_write_bps REAL,rand_read_bps REAL);
        INSERT INTO benchmark_results VALUES(1,'legacy','disk2s1','Test','/Volumes/Test',1,1024,512,512,100,200,NULL,NULL);
        """
    static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let code = sqlite3_open(url.path, &db)
        guard code == SQLITE_OK, let db else { sqlite3_close(db); throw HistoryError.invalidData("test open failed") }
        return db
    }
    static func execute(_ sql: String, db: OpaquePointer) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw HistoryError.sqlite(code: code, operation: "test SQL", message: String(cString: sqlite3_errmsg(db))) }
    }
    static func scalar(_ sql: String, db: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw HistoryError.invalidData("test prepare failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw HistoryError.invalidData("test scalar failed") }
        return String(cString: text)
    }
}

final class HistoryFaultTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("history.db") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-fault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func record(_ store: HistoryStore, at: Date = Date(), count: UInt64 = 0, key: String = "A") throws {
        let reading = HistoryTestFixtures.reading(at: at, count: count)
        try store.record(driveKey: key, bsdName: "disk2", reading: reading, health: reading.evaluateHealth())
    }
    private func expectCode(_ code: Int32, _ work: () throws -> Void) {
        XCTAssertThrowsError(try work()) { XCTAssertEqual(($0 as? HistoryError)?.sqliteCode, code, String(describing: $0)) }
    }
    func testMigrationPreservesLegacyButDoesNotTreatItAsCurrentMetrics() throws {
        let db = try HistoryTestFixtures.open(url)
        try HistoryTestFixtures.execute(HistoryTestFixtures.legacySchema, db: db)
        sqlite3_close(db)
        let store = try HistoryStore(databaseURL: url)
        XCTAssertEqual(try store.legacyCounts(), .init(snapshots: 1, benchmarks: 1))
        XCTAssertNil(try store.latest(driveKey: "legacy"))
        XCTAssertNil(try store.latestBenchmark(driveKey: "legacy"))
        try store.pruneOlderThan(Date())
        XCTAssertEqual(try store.legacyCounts().total, 2)
        try store.serialQueue.sync {
            XCTAssertEqual(try store.scalarInt("PRAGMA user_version"), 5)
            XCTAssertEqual(try store.scalarText("SELECT defect_count FROM drive_snapshots"), "-1")
            XCTAssertEqual(try store.scalarInt("SELECT queue_depth FROM benchmark_results"), 1)
        }
        let backup = try XCTUnwrap(store.migrationBackupURL)
        let backupDB = try HistoryTestFixtures.open(backup); defer { sqlite3_close(backupDB) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: backupDB), "0")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM benchmark_results", db: backupDB), "1")
    }
    func testBackupIncludesCommittedRowsStillInLiveWAL() throws {
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        try HistoryTestFixtures.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + HistoryTestFixtures.legacySchema, db: db)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0, 0)
        let store = try HistoryStore(databaseURL: url)
        let backupDB = try HistoryTestFixtures.open(XCTUnwrap(store.migrationBackupURL)); defer { sqlite3_close(backupDB) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM drive_snapshots", db: backupDB), "1")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM benchmark_results", db: backupDB), "1")
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA integrity_check", db: backupDB), "ok")
    }
    func testMigrationFailureRollsBackAlreadyRebuiltTableAndKeepsBackup() throws {
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        try HistoryTestFixtures.execute(HistoryTestFixtures.legacySchema + "ALTER TABLE benchmark_results DROP COLUMN seq_read_bps", db: db)
        XCTAssertThrowsError(try HistoryStore(databaseURL: url))
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: db), "0")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM drive_snapshots", db: db), "1")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT type FROM pragma_table_info('drive_snapshots') WHERE name='defect_count'", db: db), "INTEGER")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='_md_snapshots_v3'", db: db), "0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }.count, 1)
    }
    func testFutureSchemaRejectedWithoutChangingVersionOrJournalMode() throws {
        let db = try HistoryTestFixtures.open(url); defer { sqlite3_close(db) }
        try HistoryTestFixtures.execute("CREATE TABLE sentinel(value); INSERT INTO sentinel VALUES('keep'); PRAGMA user_version=99", db: db)
        XCTAssertThrowsError(try HistoryStore(databaseURL: url))
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: db), "99")
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA journal_mode", db: db), "delete")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT value FROM sentinel", db: db), "keep")
    }
    func testCorruptDatabaseRejectedWithoutReplacingBytes() throws {
        let bad = Data("not a SQLite database".utf8); try bad.write(to: url)
        expectCode(SQLITE_NOTADB) { _ = try HistoryStore(databaseURL: url) }
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    func testReadOnlyWriteThrowsAndExistingHistoryStillReadable() throws {
        let writer = try HistoryStore(databaseURL: url); try record(writer)
        let reader = try HistoryStore(databaseURL: url, accessMode: .readOnly)
        expectCode(SQLITE_READONLY) { try record(reader, count: 7) }
        expectCode(SQLITE_READONLY) { try reader.record(benchmark: HistoryTestFixtures.benchmark(), driveKey: "A") }
        expectCode(SQLITE_READONLY) { try reader.pruneOlderThan(Date()) }
        XCTAssertEqual(try reader.history(driveKey: "A", since: .distantPast).count, 1)
    }
    func testBusyWriteHasBoundedWaitAndRecoversAfterLockRelease() throws {
        let store = try HistoryStore(databaseURL: url, busyTimeoutMilliseconds: 20)
        let locker = try HistoryTestFixtures.open(url); defer { sqlite3_close(locker) }
        try HistoryTestFixtures.execute("BEGIN IMMEDIATE", db: locker)
        let started = Date()
        expectCode(SQLITE_BUSY) { try record(store) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(try store.latest(driveKey: "A"))
        try HistoryTestFixtures.execute("ROLLBACK", db: locker)
        try record(store)
        XCTAssertNotNil(try store.latest(driveKey: "A"))
    }
    func testFullDatabaseThrowsWithoutPartialInsertThenRecovers() throws {
        let store = try HistoryStore(databaseURL: url)
        try record(store)
        try store.serialQueue.sync { try store.executeLocked("PRAGMA max_page_count=\(store.scalarInt("PRAGMA page_count"))") }
        expectCode(SQLITE_FULL) { try record(store, count: 9, key: String(repeating: "x", count: 131_072)) }
        XCTAssertEqual(try store.history(driveKey: "A", since: .distantPast).count, 1)
        try store.serialQueue.sync { try store.executeLocked("PRAGMA max_page_count=100000") }
        try record(store, count: 9)
        XCTAssertEqual(try store.history(driveKey: "A", since: .distantPast).count, 2)
    }
    func testStepErrorAfterARowThrowsInsteadOfReturningPartialData() throws {
        let store = try HistoryStore(databaseURL: url)
        try store.serialQueue.sync {
            let statement = try store.prepare("SELECT 42"); defer { sqlite3_finalize(statement) }
            var calls = 0, decoded = 0
            expectCode(SQLITE_IOERR) {
                let _: [Int64] = try store.rows(statement, step: { p in calls += 1; return calls == 1 ? sqlite3_step(p) : SQLITE_IOERR }) {
                    decoded += 1; return sqlite3_column_int64($0, 0)
                }
            }
            XCTAssertEqual(decoded, 1)
            expectCode(SQLITE_CORRUPT) { let _: [Int] = try store.rows(statement, step: { _ in SQLITE_CORRUPT }) { _ in 0 } }
        }
    }
    func testUInt64MaxCountersAndFileSizeRoundTripLosslessly() throws {
        let store = try HistoryStore(databaseURL: url)
        try record(store, count: .max)
        let point = try XCTUnwrap(store.latest(driveKey: "A"))
        XCTAssertEqual(point.powerOnHours, UInt64.max)
        XCTAssertEqual(point.defectCount, UInt64.max)
        try store.record(benchmark: HistoryTestFixtures.benchmark(size: .max), driveKey: "A")
        XCTAssertEqual(try store.latestBenchmark(driveKey: "A")?.fileSizeBytes, UInt64.max)
    }
    func testUnknownScoreAndMissingCountersStayNULL() throws {
        let store = try HistoryStore(databaseURL: url)
        let reading = DriveReading.ata(.init(capturedAt: Date(), identify: nil, attributes: [],
            overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil))
        try store.record(driveKey: "unknown", bsdName: "disk2", reading: reading, health: reading.evaluateHealth())
        let point = try XCTUnwrap(store.latest(driveKey: "unknown"))
        XCTAssertNil(point.healthScore); XCTAssertNil(point.bytesWritten); XCTAssertNil(point.defectCount)
        XCTAssertEqual(point.rating, "unknown")
    }
    func testMalformedStoredValuesThrowInsteadOfBecomingZero() throws {
        let store = try HistoryStore(databaseURL: url)
        try record(store)
        for (column, value) in [("defect_count", "-1"), ("defect_count", "18446744073709551616"), ("defect_count", "001"), ("health_score", "bad"), ("captured_at", "bad")] {
            try store.serialQueue.sync { try store.executeLocked("UPDATE drive_snapshots SET \(column)='\(value)'") }
            XCTAssertThrowsError(try store.latest(driveKey: "A"), column)
            XCTAssertThrowsError(try store.history(driveKey: "A", since: .distantPast), column)
            try store.serialQueue.sync { try store.executeLocked("UPDATE drive_snapshots SET defect_count='0',health_score=100,captured_at=1700000000") }
        }
        try store.record(benchmark: HistoryTestFixtures.benchmark(), driveKey: "A")
        try store.serialQueue.sync { try store.executeLocked("UPDATE benchmark_results SET seq_write_bps='bad'") }
        XCTAssertThrowsError(try store.latestBenchmark(driveKey: "A"))
    }
    func testBucketUsesNewestTimestampEvenIfOlderSampleWasInsertedLater() throws {
        let store = try HistoryStore(databaseURL: url), base = Date(timeIntervalSince1970: 1_700_000_040)
        try record(store, at: base.addingTimeInterval(40), count: 40)
        try record(store, at: base.addingTimeInterval(10), count: 10)
        XCTAssertEqual(try store.history(driveKey: "A", since: base, bucketInterval: 60).map(\.defectCount), [40])
    }
    func testNonfiniteInputsAndInvalidBucketsAreRejected() throws {
        let store = try HistoryStore(databaseURL: url)
        for interval in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try store.history(driveKey: "A", since: .distantPast, bucketInterval: interval))
        }
        XCTAssertThrowsError(try record(store, at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try store.record(benchmark: HistoryTestFixtures.benchmark(speed: .nan), driveKey: "A"))
        XCTAssertThrowsError(try store.pruneOlderThan(Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try HistoryStore(databaseURL: url, busyTimeoutMilliseconds: -1))
    }
    func testNewDatabaseAndWALHavePrivatePermissions() throws {
        let store = try HistoryStore(databaseURL: url); try record(store)
        for suffix in ["", "-wal", "-shm"] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path + suffix)[.posixPermissions] as? NSNumber
            XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600, suffix)
        }
    }
    func testFailedBackupRemovesOnlyItsIncompleteFileAndKeepsExistingRecoveryCopy() throws {
        let store = try HistoryStore(databaseURL: url)
        try record(store)
        let protected = try store.serialQueue.sync { try store.makeMigrationBackup() }
        let before = try Data(contentsOf: protected)
        try store.serialQueue.sync {
            try store.executeLocked("BEGIN IMMEDIATE")
            defer { try? store.executeLocked("ROLLBACK") }
            // SQLite cannot back up a source connection inside a write transaction.
            XCTAssertThrowsError(try store.makeMigrationBackup())
        }
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
        XCTAssertEqual(backups.map { $0.resolvingSymlinksInPath() }, [protected.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: protected), before)
        XCTAssertNotNil(try store.latest(driveKey: "A"))
    }
}
