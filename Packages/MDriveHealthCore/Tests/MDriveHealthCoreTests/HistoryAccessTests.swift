/* Observable persistence failure/retry regressions. MDriveHealth, GPL-3.0-or-later. */
import XCTest
import SQLite3
@testable import MDriveHealthCore

private final class HistoryFactoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var writable = false
    private var holdNext = false
    private let gate = DispatchSemaphore(value: 0)
    func open(_ url: URL) throws -> HistoryStore {
        lock.lock(); count += 1; let writable = writable, shouldWait = holdNext; holdNext = false; lock.unlock()
        if shouldWait { gate.wait() }
        return try HistoryStore(databaseURL: url, accessMode: writable ? .readWrite : .readOnly)
    }
    func allowWrites() { lock.lock(); writable = true; lock.unlock() }
    func holdNextOpen() { lock.lock(); holdNext = true; lock.unlock() }
    func releaseOpen() { gate.signal() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class HistoryAccessTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @MainActor func testOpeningFailureIsVisibleAndExplicitRetryRestoresAvailability() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing/history.db")
        let access = HistoryAccess(factory: { try HistoryStore(databaseURL: url) })
        let prepared = await access.prepareConnection()
        XCTAssertFalse(prepared); XCTAssertEqual(access.state, .unavailable)
        let originalMessage = try XCTUnwrap(access.firstIssue?.message)
        XCTAssertFalse(originalMessage.isEmpty)
        do { _ = try await access.run("query") { try await $0.latest(driveKey: "A") }; XCTFail("opening failure must throw") }
        catch { XCTAssertEqual(access.firstIssue?.message, originalMessage) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
        try await access.connect(retry: true)
        XCTAssertEqual(access.state, .ready); XCTAssertFalse(access.isDegraded)
        let point = try await access.run("query") { try await $0.latest(driveKey: "A") }
        XCTAssertNil(point)
    }
    @MainActor func testReadSuccessDoesNotClearFailedWriteAndRetryClearsOnlyRecoveredOperation() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), seed = try HistoryStore(databaseURL: url)
        _ = seed
        let state = HistoryFactoryState(), access = HistoryAccess(factory: { try state.open(url) })
        let result = HistoryTestFixtures.benchmark()
        do { try await access.run("benchmark.record") { try await $0.record(benchmark: result, driveKey: "A") }; XCTFail("read-only write must throw") }
        catch { XCTAssertEqual((error as? HistoryError)?.sqliteCode, SQLITE_READONLY) }
        XCTAssertEqual(access.state, .ready); XCTAssertTrue(access.isDegraded)
        access.report(HistoryError.invalidData("separate export error"), operation: "report.write")
        let values = try await access.run("benchmark.query") { try await $0.benchmarks(driveKey: "A", since: .distantPast) }
        XCTAssertTrue(values.isEmpty); XCTAssertNotNil(access.issues["benchmark.record"])
        state.allowWrites(); try await access.connect(retry: true)
        XCTAssertNotNil(access.issues["benchmark.record"], "opening successfully is not proof a failed write was saved")
        try await access.run("benchmark.record") { try await $0.record(benchmark: result, driveKey: "A") }
        XCTAssertNil(access.issues["benchmark.record"]); XCTAssertNotNil(access.issues["report.write"])
        let saved = try await access.run("benchmark.query") { try await $0.benchmarks(driveKey: "A", since: .distantPast) }
        XCTAssertEqual(saved.count, 1)
    }
    private func measurement(in directory: URL, id: UUID = UUID(), reason: String = "not started fixture") -> MeasurementJobRecord {
        let drive = DriveInfo(registryEntryID: 999_999, bsdName: "disk999999", model: "History access fixture", serialNumber: "PRIVATE-ONLY",
                              firmwareRevision: "F", sizeBytes: 1 << 30, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999999s1", name: "Private fixture", mountPoint: directory.path, totalBytes: 1 << 30, availableBytes: 1 << 30,
            sharedCapacityKey: "private-fixture", mountIdentity: MountedFilesystemIdentity.capture(at: directory),
            writeIdentity: MountedFilesystemIdentity.capture(at: directory), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: directory))
        let config = BenchmarkConfig(fileSizeBytes: 8192, sequentialBlockBytes: 4096, includeRandomPhases: false)
        let intent = MeasurementJobIntent(id: id, drive: drive, driveKey: "private-fixture", volume: volume, operation: .benchmark(config))
        return .init(intent: intent, terminal: .init(intent: intent, outcome: .notStarted(reason)))
    }
    @MainActor func testMeasurementReadCannotClearFailedCommitAndRetryKeepsOtherUUIDErrors() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), seed = try HistoryStore(databaseURL: url)
        try await seed.close()
        let state = HistoryFactoryState(), access = HistoryAccess(factory: { try state.open(url) })
        let first = measurement(in: directory), second = measurement(in: directory)
        for record in [first, second] {
            do { _ = try await access.recordMeasurement(record); XCTFail("read-only commit must fail") }
            catch { XCTAssertEqual((error as? HistoryError)?.sqliteCode, SQLITE_READONLY) }
        }
        let missing = try await access.measurementRecord(id: first.id); XCTAssertNil(missing)
        XCTAssertNotNil(access.issues["measurement.record:" + first.id.uuidString])
        access.report(HistoryError.invalidData("unrelated export failure"), operation: "report.write")
        state.allowWrites(); try await access.connect(retry: true)
        _ = try await access.recordMeasurement(first)
        XCTAssertEqual(Set(access.issues.keys), ["measurement.record:" + second.id.uuidString, "report.write"])
        _ = try await access.recordMeasurement(first) // Exact retry remains idempotent.
        _ = try await access.recordMeasurement(second)
        XCTAssertEqual(Set(access.issues.keys), ["report.write"])
        let saved = try await access.run("test.confirm") { try await $0.measurementRecords() }
        XCTAssertEqual(Set(saved.map(\.id)), [first.id, second.id])
        try await access.shutdown()
    }
    @MainActor func testMeasurementCommitRechecksItsFailedLookupWithoutClearingOtherUUID() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), access = HistoryAccess(factory: { try HistoryStore(databaseURL: url) })
        try await access.connect()
        let database = try HistoryTestFixtures.open(url); defer { sqlite3_close(database) }
        let first = measurement(in: directory), second = measurement(in: directory)
        try HistoryTestFixtures.execute("ALTER TABLE measurement_jobs RENAME TO temporarily_unavailable_jobs", db: database)
        for record in [first, second] {
            do { _ = try await access.measurementRecord(id: record.id); XCTFail("missing table must fail lookup") }
            catch { XCTAssertEqual((error as? HistoryError)?.sqliteCode, SQLITE_ERROR) }
        }
        try HistoryTestFixtures.execute("ALTER TABLE temporarily_unavailable_jobs RENAME TO measurement_jobs", db: database)
        let receipt = try await access.recordMeasurement(first)
        XCTAssertEqual(receipt.id, first.id)
        XCTAssertEqual(Set(access.issues.keys), ["measurement.lookup:" + second.id.uuidString])
        let saved = try await access.measurementRecord(id: first.id)
        XCTAssertEqual(try saved?.recordSHA256, try first.recordSHA256)
        let missing = try await access.measurementRecord(id: second.id); XCTAssertNil(missing)
        XCTAssertFalse(access.isDegraded)
        try await access.shutdown()
    }
    @MainActor func testMeasurementUUIDConflictStaysVisibleAfterSuccessfulReadUntilExactRetry() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), access = HistoryAccess(factory: { try HistoryStore(databaseURL: url) })
        let original = measurement(in: directory), foreign = measurement(in: directory, id: original.id, reason: "foreign immutable record")
        let receipt = try await access.recordMeasurement(original)
        do { _ = try await access.recordMeasurement(foreign); XCTFail("UUID conflict must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("conflict")) }
        let saved = try await access.measurementRecord(id: original.id)
        XCTAssertEqual(try saved?.recordSHA256, try original.recordSHA256)
        XCTAssertTrue(access.isDegraded, "A successful lookup cannot hide a failed commit")
        let retry = try await access.recordMeasurement(original)
        XCTAssertEqual(retry.recordSHA256, receipt.recordSHA256); XCTAssertFalse(access.isDegraded)
        let records = try await access.run("test.confirm") { try await $0.measurementRecords() }; XCTAssertEqual(records.count, 1)
        try await access.shutdown()
    }
    @MainActor func testConcurrentConnectionRequestsShareOneFactoryAndAllBecomeReady() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), state = HistoryFactoryState()
        state.allowWrites()
        let access = HistoryAccess(factory: { try state.open(url) })
        let tasks = (0..<20).map { _ in Task { @MainActor in
            try await access.run("query") { try await $0.latest(driveKey: "A") }
        } }
        for task in tasks { let point = try await task.value; XCTAssertNil(point) }
        XCTAssertEqual(state.calls, 1); XCTAssertEqual(access.state, .ready); XCTAssertFalse(access.isDegraded)
    }
    @MainActor func testMigrationNoticeExposesLegacyCountAndRecoveryCopy() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), db = try HistoryTestFixtures.open(url)
        try HistoryTestFixtures.execute(HistoryTestFixtures.legacySchema, db: db); sqlite3_close(db)
        let access = HistoryAccess(factory: { try HistoryStore(databaseURL: url) })
        try await access.connect()
        XCTAssertEqual(access.legacyCounts.total, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(access.migrationBackupURL).path))
        XCTAssertFalse(access.isDegraded)
    }
    @MainActor func testSharedOpenAndConcurrentRetriesUseTheRecoveredWritableHandle() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.db"), seed = try HistoryStore(databaseURL: url); _ = seed
        let state = HistoryFactoryState(), access = HistoryAccess(factory: { try state.open(url) })
        let initial = (0..<20).map { _ in Task { @MainActor in try await access.connect() } }
        for task in initial { try await task.value }
        XCTAssertEqual(state.calls, 1)
        state.allowWrites(); state.holdNextOpen()
        var started = 0
        let retries = (0..<20).map { _ in Task { @MainActor in
            started += 1; try await access.connect(retry: true)
        } }
        while started < 20 { await Task.yield() }
        state.releaseOpen()
        for task in retries { try await task.value }
        XCTAssertEqual(state.calls, 2)
        let benchmark = HistoryTestFixtures.benchmark(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await access.run("write") { try await $0.record(benchmark: benchmark, driveKey: "recovered") }
        let saved = try await access.run("read") { try await $0.benchmarks(driveKey: "recovered", since: .distantPast) }
        XCTAssertEqual(saved, [benchmark]); XCTAssertFalse(access.isDegraded)
    }
    func testReportWriterPropagatesFailureWithoutChangingExistingDestination() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("keep.txt"), original = Data("sentinel".utf8)
        try original.write(to: child)
        XCTAssertThrowsError(try ReportDocumentWriter.write("report", to: directory))
        XCTAssertEqual(try Data(contentsOf: child), original)
        XCTAssertThrowsError(try ReportDocumentWriter.write("report", to: directory.appendingPathComponent("missing/report.md")))
        XCTAssertThrowsError(try ReportDocumentWriter.write("report", to: XCTUnwrap(URL(string: "https://example.com/report.md"))))
        try ReportDocumentWriter.write("Báo cáo ✓", to: child)
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "Báo cáo ✓")
    }
}
