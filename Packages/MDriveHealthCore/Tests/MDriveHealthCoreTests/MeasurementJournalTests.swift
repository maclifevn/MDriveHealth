/* Real private metadata, SQLite receipts and killed child fixtures. GPL-3.0-or-later. */
import XCTest
import Darwin
import SQLite3
@testable import MDriveHealthCore

final class MeasurementJournalTests: XCTestCase {
    private var root: URL!
    private var config: BenchmarkConfig { .init(fileSizeBytes: 16384, sequentialBlockBytes: 4096, includeRandomPhases: false) }
    private var volume: VolumeUsage { .init(bsdName: "disk999999s1", name: "Journal fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
        sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root)) }
    private var drive: DriveInfo { .init(registryEntryID: UInt64(getpid()) << 32 | 303, bsdName: "disk999999", model: "Fixture", serialNumber: "fixture", firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported) }
    private var journalURL: URL { root.appendingPathComponent("jobs") }
    private var databaseURL: URL { root.appendingPathComponent("history.db") }
    override func setUpWithError() throws {
        if let path = ProcessInfo.processInfo.environment["MDRIVE_JOURNAL_FIXTURE_ROOT"] { root = URL(fileURLWithPath: path); return }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("measurement-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["MDRIVE_JOURNAL_FIXTURE_ROOT"] != nil { return }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("outside".utf8))
        try FileManager.default.removeItem(at: root)
    }
    private func intent(operation: MeasurementOperation? = nil, id: UUID = UUID()) -> MeasurementJobIntent {
        .init(id: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000), drive: drive, driveKey: "fixture-stable-key", volume: volume, operation: operation ?? .benchmark(config))
    }
    private func result(rate: Double = 100) -> BenchmarkResult {
        .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_010), volumeBSDName: volume.bsdName, volumeName: volume.name, mountPoint: volume.mountPoint,
              fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes, randomBlockBytes: config.randomBlockBytes, queueDepth: config.queueDepth,
              sequentialWriteBytesPerSec: rate, sequentialReadBytesPerSec: 200, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    private func terminal(_ intent: MeasurementJobIntent, rate: Double = 100) -> MeasurementJobTerminal {
        .init(intent: intent, outcome: .benchmark(result(rate: rate)), completedAt: Date(timeIntervalSince1970: 1_700_000_011))
    }
    func testLiveLeaseIsActiveAndInterruptedIntentRestoresWithoutReexecution() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent()
        var lease: MeasurementJobLease? = try journal.prepare(job)
        XCTAssertEqual(try journal.scan().jobs.first?.state, .active)
        let duplicate = intent(id: job.id); XCTAssertThrowsError(try journal.prepare(duplicate))
        XCTAssertThrowsError(try journal.openJob(id: job.id))
        do {
            let inherited = try MeasurementJobLease.adopting(descriptor: lease!.delegatedFD(), ticket: lease!.ticket)
            XCTAssertEqual(inherited.intent.id, job.id)
            withExtendedLifetime(inherited) { XCTAssertEqual(try? journal.scan().jobs.first?.state, .active) }
        }
        // Drop every reference to the inherited OFD before restoration.
        lease = nil
        XCTAssertEqual(try journal.scan().jobs.first?.state, .interrupted)
        XCTAssertEqual(try journal.scan().jobs.first?.record?.id, job.id)
        _ = lease
    }
    func testTerminalIsImmutableAndReceiptCommitThenReopenPreventsDuplicates() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        var lease: MeasurementJobLease? = try journal.prepare(job)
        let final = terminal(job); try lease!.writeTerminal(final); try lease!.writeTerminal(final)
        XCTAssertThrowsError(try lease!.writeTerminal(terminal(job, rate: 101)))
        let record = try lease!.record(), first = try store.recordMeasurement(record), second = try store.recordMeasurement(record)
        XCTAssertEqual(first.recordSHA256, second.recordSHA256); XCTAssertEqual(try store.benchmarks(driveKey: job.driveKey, since: .distantPast).count, 1)
        lease = nil
        XCTAssertEqual(try journal.scan().jobs.first?.state, .completed)
        let restored = try XCTUnwrap(journal.scan().jobs.first?.record)
        XCTAssertEqual(try restored.recordSHA256, first.recordSHA256)
        try journal.discardCommitted(try store.recordMeasurement(restored))
        XCTAssertTrue(try journal.scan().jobs.isEmpty)
        XCTAssertEqual(try store.measurementRecords().first?.id, job.id)
    }
    func testFailedHistoryTransactionDoesNotGiveReceiptOrConsumeSpool() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        let lease = try journal.prepare(job); try lease.writeTerminal(terminal(job))
        try store.serialQueue.sync { try store.executeLocked("CREATE TRIGGER reject_benchmark BEFORE INSERT ON benchmark_results BEGIN SELECT RAISE(ABORT,'fixture blocked'); END") }
        XCTAssertThrowsError(try store.recordMeasurement(lease.record()))
        XCTAssertTrue(try store.measurementRecords().isEmpty)
        XCTAssertNotNil(try lease.record().terminal)
        try store.serialQueue.sync { try store.executeLocked("DROP TRIGGER reject_benchmark") }
        _ = try store.recordMeasurement(lease.record()); XCTAssertEqual(try store.measurementRecords().count, 1)
    }
    func testUUIDContentConflictAndTamperedHistoryAreRejected() throws {
        let store = try HistoryStore(databaseURL: databaseURL); defer { try? store.close() }
        let job = intent(), original = MeasurementJobRecord(intent: job, terminal: terminal(job))
        _ = try store.recordMeasurement(original)
        XCTAssertThrowsError(try store.recordMeasurement(.init(intent: job, terminal: terminal(job, rate: 300))))
        XCTAssertEqual(try store.measurementRecords().count, 1); XCTAssertEqual(try store.benchmarks(driveKey: job.driveKey, since: .distantPast).count, 1)
        try store.serialQueue.sync { try store.executeLocked("UPDATE measurement_jobs SET payload='{}'") }
        XCTAssertThrowsError(try store.measurementRecords())
    }
    func testCapacityAndInterruptedRecordsUseBoundedStableHistoryPagination() throws {
        let store = try HistoryStore(databaseURL: databaseURL); defer { try? store.close() }
        var ids: [UUID] = []
        for _ in 0..<3 {
            let config = CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true)
            let job = intent(operation: .capacity(config)); ids.append(job.id)
            let result = CapacityVerifyResult(capturedAt: Date(timeIntervalSince1970: 1_700_000_010), volumeName: volume.name, mountPoint: volume.mountPoint,
                bytesRequested: 16384, bytesWritten: 16384, bytesVerifiedOK: 16384, firstCorruptionOffset: nil, corruptedBlocks: 0, writeBytesPerSec: 20, readBytesPerSec: 30, verdict: .passedTestedRange, interruption: nil)
            _ = try store.recordMeasurement(.init(intent: job, terminal: .init(intent: job, outcome: .capacity(result))))
        }
        let first = try XCTUnwrap(store.measurementRecords(limit: 1).first)
        let remaining = try store.measurementRecords(limit: 2, before: .init(createdAt: first.intent.createdAt, id: first.id))
        XCTAssertEqual(Set([first.id] + remaining.map(\.id)), Set(ids)); XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(try store.measurementRecords(driveKey: "other").isEmpty)
        XCTAssertThrowsError(try store.measurementRecords(limit: 257))
        let unfinished = intent(); _ = try store.recordMeasurement(.init(intent: unfinished, terminal: nil))
        XCTAssertEqual(try store.measurementRecords().count, 4)
    }
    func testUnknownContentsAndWrongReceiptCannotBeDeleted() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        var lease: MeasurementJobLease? = try journal.prepare(job); try lease!.writeTerminal(terminal(job))
        let receipt = try store.recordMeasurement(lease!.record()); lease = nil
        let directory = journalURL.appendingPathComponent("job-" + job.id.uuidString), userFile = directory.appendingPathComponent("user.txt")
        try Data("keep".utf8).write(to: userFile)
        XCTAssertThrowsError(try journal.discardCommitted(receipt)); XCTAssertEqual(try Data(contentsOf: userFile), Data("keep".utf8))
        try FileManager.default.removeItem(at: userFile)
        XCTAssertThrowsError(try journal.discardCommitted(.init(id: job.id, recordSHA256: String(repeating: "a", count: 64))))
        // A familiar filename is still not permission to delete user contents.
        let spoof = directory.appendingPathComponent("cleanup.json")
        try Data("user data".utf8).write(to: spoof); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: spoof.path)
        XCTAssertThrowsError(try journal.discardCommitted(receipt)); XCTAssertEqual(try Data(contentsOf: spoof), Data("user data".utf8))
    }
    func testSymlinksHardlinksAndTornRecordsStayUnverified() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent()
        var lease: MeasurementJobLease? = try journal.prepare(job); lease = nil
        let path = journalURL.appendingPathComponent("job-" + job.id.uuidString + "/intent.json"), alias = root.appendingPathComponent("alias")
        XCTAssertEqual(link(path.path, alias.path), 0); XCTAssertEqual(try journal.scan().jobs.first?.state, .unverified)
        XCTAssertEqual(unlink(alias.path), 0)
        try Data("torn".utf8).write(to: path)
        XCTAssertEqual(try journal.scan().jobs.first?.state, .unverified)
        XCTAssertEqual(try Data(contentsOf: path), Data("torn".utf8)); _ = lease
        let linked = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: journalURL)
        XCTAssertThrowsError(try MeasurementJournal(rootURL: linked))
    }
    func testCleanupProofRequiresOriginalParentAndCompleteFreshScan() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), lease = try journal.prepare(job)
        XCTAssertFalse(try lease.cleanupConfirmed())
        let complete = try DiskWorkspaceRecovery.scanFixture(at: root)
        let clonedDrive = DriveInfo(registryEntryID: drive.id + 1, bsdName: "disk999998", model: drive.model,
            serialNumber: "cloned-filesystem", firmwareRevision: "F", sizeBytes: drive.sizeBytes,
            interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        XCTAssertThrowsError(try lease.confirmCleanup(currentOrigin: MeasurementOrigin(drive: clonedDrive), currentVolume: volume, scan: complete))
        XCTAssertFalse(try lease.cleanupConfirmed())
        XCTAssertThrowsError(try lease.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: volume, scan: .init(leftovers: [], complete: false, diagnostic: "partial", parentIdentity: complete.parentIdentity)))
        let replacement = root.appendingPathComponent("replacement"); try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let wrong = VolumeUsage(bsdName: volume.bsdName, name: volume.name, mountPoint: root.path, totalBytes: volume.totalBytes, availableBytes: volume.availableBytes,
            sharedCapacityKey: volume.sharedCapacityKey, mountIdentity: volume.mountIdentity, writeIdentity: volume.writeIdentity, writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: replacement))
        XCTAssertThrowsError(try lease.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: wrong, scan: .init(leftovers: [], complete: true, diagnostic: nil, parentIdentity: wrong.writeDirectoryIdentity)))
        try lease.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: volume, scan: complete); XCTAssertTrue(try lease.cleanupConfirmed())
    }
    func testIndependentDescriptorCannotClaimDelegatedJobOwnership() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), lease = try journal.prepare(intent())
        let separate = open(journalURL.appendingPathComponent("job-" + lease.intent.id.uuidString).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(separate, 0); defer { close(separate) }
        XCTAssertThrowsError(try MeasurementJobLease.adopting(descriptor: separate, ticket: lease.ticket))
        XCTAssertEqual(try journal.scan().jobs.first?.state, .active)
        let actual = try MeasurementJobLease.adopting(descriptor: lease.delegatedFD(), ticket: lease.ticket)
        XCTAssertEqual(actual.intent.id, lease.intent.id)
    }
    func testOmittingHistoryRequiresExplicitPolicyAndConfirmedCompletedRecord() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), archived = intent()
        var lease: MeasurementJobLease? = try journal.prepare(archived); try lease!.writeTerminal(terminal(archived))
        let archivedRecord = try lease!.record(); lease = nil
        XCTAssertThrowsError(try journal.discardOmitted(id: archived.id, recordSHA256: archivedRecord.recordSHA256))
        let omitted = MeasurementJobIntent(drive: drive, driveKey: "fixture", volume: volume, operation: .benchmark(config), historyPolicy: .omit)
        lease = try journal.prepare(omitted)
        let interrupted = try lease!.record(); lease = nil
        XCTAssertThrowsError(try journal.discardOmitted(id: omitted.id, recordSHA256: interrupted.recordSHA256))
        lease = try journal.openJob(id: omitted.id); try lease!.writeTerminal(terminal(omitted))
        let completed = try lease!.record(); lease = nil
        try journal.discardOmitted(id: omitted.id, recordSHA256: completed.recordSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.appendingPathComponent("job-" + omitted.id.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "No-history consumption never opens SQLite")
        XCTAssertEqual(try journal.scan().jobs.map(\.record?.id), [archived.id])
    }
    func testLegacyIntentRemainsReadableButCannotClaimPhysicalCleanup() throws {
        let encoded = try JSONEncoder().encode(intent())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object["version"] = 1
        object.removeValue(forKey: "origin"); object.removeValue(forKey: "historyPolicy")
        let legacy = try JSONDecoder().decode(MeasurementJobIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.origin); try legacy.validate()
        let journal = try MeasurementJournal(rootURL: journalURL), lease = try journal.prepare(legacy)
        XCTAssertEqual(try lease.record().id, legacy.id)
        XCTAssertThrowsError(try lease.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: volume, scan: DiskWorkspaceRecovery.scanFixture(at: root)))
        XCTAssertFalse(try lease.cleanupConfirmed())
    }
    func testValidChecksumsWithUnknownMetadataFieldsRemainUnverifiedAndPreserved() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent()
        var lease: MeasurementJobLease? = try journal.prepare(job); lease = nil
        let path = journalURL.appendingPathComponent("job-" + job.id.uuidString + "/intent.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let raw = try XCTUnwrap(Data(base64Encoded: envelope["payload"] as? String ?? ""))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any]); payload["userNotes"] = "preserve this future/user field"
        let changed = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        envelope["payload"] = changed.base64EncodedString(); envelope["sha256"] = MeasurementJournalCoding.hash(changed)
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) + Data([10]); try bytes.write(to: path)
        XCTAssertEqual(try journal.scan().jobs.first?.state, .unverified)
        XCTAssertThrowsError(try journal.openJob(id: job.id)); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testVersion4MigrationPreservesSelfTestDataAndTakesConsistentBackup() throws {
        do { let store = try HistoryStore(databaseURL: databaseURL); try store.close() }
        let raw = try HistoryTestFixtures.open(databaseURL)
        try HistoryTestFixtures.execute("DROP TABLE measurement_jobs; CREATE TABLE sentinel(value); INSERT INTO sentinel VALUES('keep'); PRAGMA user_version=4", db: raw); sqlite3_close(raw)
        let store = try HistoryStore(databaseURL: databaseURL); defer { try? store.close() }
        let backup = try XCTUnwrap(store.migrationBackupURL), old = try HistoryTestFixtures.open(backup); defer { sqlite3_close(old) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: old), "4")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT value FROM sentinel", db: old), "keep")
        try store.serialQueue.sync { XCTAssertEqual(try store.scalarInt("PRAGMA user_version"), 5); XCTAssertEqual(try store.scalarText("SELECT value FROM sentinel"), "keep") }
    }
    func testVersion4MeasurementTableCollisionRollsBackWithoutDataLoss() throws {
        do { let store = try HistoryStore(databaseURL: databaseURL); try store.close() }
        let raw = try HistoryTestFixtures.open(databaseURL)
        try HistoryTestFixtures.execute("DROP TABLE measurement_jobs; CREATE TABLE measurement_jobs(foreign_value); INSERT INTO measurement_jobs VALUES('keep'); PRAGMA user_version=4", db: raw); sqlite3_close(raw)
        XCTAssertThrowsError(try HistoryStore(databaseURL: databaseURL))
        let after = try HistoryTestFixtures.open(databaseURL); defer { sqlite3_close(after) }
        XCTAssertEqual(try HistoryTestFixtures.scalar("PRAGMA user_version", db: after), "4")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT foreign_value FROM measurement_jobs", db: after), "keep")
        XCTAssertEqual(try HistoryTestFixtures.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('self_test_tracking','self_test_events')", db: after), "2")
    }
    func testConcurrentConnectionsReturnOneReceiptAndOneBenchmark() async throws {
        let first = try HistoryStore(databaseURL: databaseURL), second = try HistoryStore(databaseURL: databaseURL)
        defer { try? first.close(); try? second.close() }
        let job = intent(), record = MeasurementJobRecord(intent: job, terminal: terminal(job))
        let receipts = try await withThrowingTaskGroup(of: MeasurementHistoryReceipt.self) { group in
            for i in 0..<8 { let store = i % 2 == 0 ? first : second; group.addTask { try await store.recordMeasurement(record) } }
            var values: [MeasurementHistoryReceipt] = []; for try await receipt in group { values.append(receipt) }; return values
        }
        XCTAssertEqual(receipts.count, 8); XCTAssertEqual(Set(receipts.map(\.recordSHA256)).count, 1)
        let restored = try await first.measurementRecord(id: job.id), benchmarks = try await second.benchmarks(driveKey: job.driveKey, since: .distantPast)
        XCTAssertEqual(restored?.id, job.id); XCTAssertEqual(benchmarks.count, 1)
        try await first.pruneOlderThan(Date(timeIntervalSince1970: 1_700_000_012))
        let pruned = try await second.measurementRecord(id: job.id); XCTAssertNil(pruned)
    }
    func testRejectedDelegationDoesNotLeakDuplicatedDescriptors() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), lease = try journal.prepare(intent()), original = lease.ticket
        let bad = MeasurementJobTicket(version: original.version, id: original.id, nonce: UUID(), directory: original.directory, intentSHA256: original.intentSHA256)
        let count = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<64 { XCTAssertThrowsError(try MeasurementJobLease.adopting(descriptor: lease.delegatedFD(), ticket: bad)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, count)
    }
    private func stageConsumption(lease: MeasurementJobLease, receipt: MeasurementHistoryReceipt) throws {
        let names = try WorkspaceDirectory.entries(fd: lease.descriptor, limit: MeasurementJournalFiles.maximumJobEntries)
        let files = try Dictionary(uniqueKeysWithValues: names.map { ($0, MeasurementJournalCoding.hash(try MeasurementJournalFiles.read($0, at: lease.descriptor))) })
        let marker = MeasurementConsumption(version: 1, id: receipt.id, nonce: lease.intent.nonce, directory: lease.ticket.directory,
            rootVolumeUUID: MountedFilesystemIdentity.capture(at: journalURL)?.volumeUUID, historySHA256: receipt.recordSHA256, files: files)
        let fd = Darwin.open(journalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        try MeasurementJournalFiles.publish(MeasurementJournalCoding.wrap(marker), name: "receipt-" + receipt.id.uuidString + ".json", at: fd, entryLimit: MeasurementJournal.maximumJobs + 32)
    }
    func testConsumptionReceiptResumesAfterIntentWasAlreadyUnlinked() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        var lease: MeasurementJobLease? = try journal.prepare(job); try lease!.writeTerminal(terminal(job))
        let receipt = try store.recordMeasurement(lease!.record()); try stageConsumption(lease: lease!, receipt: receipt)
        XCTAssertEqual(unlinkat(lease!.descriptor, "intent.json", 0), 0); lease = nil
        XCTAssertEqual(try journal.scan().jobs.first?.state, .acknowledged)
        try journal.collectAcknowledged(id: job.id)
        XCTAssertTrue(try journal.scan().jobs.isEmpty)
        XCTAssertEqual(try store.measurementRecords().count, 1)
    }
    func testConsumptionReceiptResumesAfterDirectoryWasAlreadyRemoved() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        var lease: MeasurementJobLease? = try journal.prepare(job); try lease!.writeTerminal(terminal(job))
        let receipt = try store.recordMeasurement(lease!.record()); try stageConsumption(lease: lease!, receipt: receipt)
        lease = nil
        try FileManager.default.removeItem(at: journalURL.appendingPathComponent("job-" + job.id.uuidString))
        XCTAssertEqual(try journal.scan().jobs.first?.state, .acknowledged)
        try journal.discardCommitted(receipt); XCTAssertTrue(try journal.scan().jobs.isEmpty)
        XCTAssertEqual(try store.measurementRecords().count, 1)
    }
    func testConsumptionReceiptCannotDeleteChangedOrUnknownContents() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        var lease: MeasurementJobLease? = try journal.prepare(job); try lease!.writeTerminal(terminal(job))
        let receipt = try store.recordMeasurement(lease!.record()); try stageConsumption(lease: lease!, receipt: receipt)
        lease = nil
        let path = journalURL.appendingPathComponent("job-" + job.id.uuidString + "/terminal.json")
        try Data("keep changed data".utf8).write(to: path)
        XCTAssertThrowsError(try journal.collectAcknowledged(id: job.id))
        XCTAssertEqual(try Data(contentsOf: path), Data("keep changed data".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.appendingPathComponent("job-" + job.id.uuidString + "/intent.json").path))
        let unknown = journalURL.appendingPathComponent("receipt-user-file")
        try Data("keep".utf8).write(to: unknown)
        XCTAssertTrue(try journal.scan().unknownEntries.contains("receipt-user-file"))
    }
    func testMetadataBudgetRejectsBeforeCreatingAnotherJob() throws {
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent()
        for i in 0..<MeasurementJournal.maximumJobs { try FileManager.default.createDirectory(at: journalURL.appendingPathComponent("foreign-\(i)"), withIntermediateDirectories: false) }
        XCTAssertThrowsError(try journal.prepare(job))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.appendingPathComponent("job-" + job.id.uuidString).path))
        XCTAssertEqual(try journal.scan().unknownEntries.count, MeasurementJournal.maximumJobs)
    }
    func testChildFixture() throws {
        guard let mode = ProcessInfo.processInfo.environment["MDRIVE_JOURNAL_FIXTURE_MODE"] else { return }
        let journal = try MeasurementJournal(rootURL: journalURL), job = intent(), lease = try journal.prepare(job)
        var workspace: DiskTestWorkspace?
        if mode == "writing" {
            workspace = try DiskTestWorkspace.fixture(at: root, sessionID: job.id)
            let fd = try workspace!.createFile("data.bin"), bytes = [UInt8](repeating: 0x71, count: 8192)
            XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, 8192); XCTAssertEqual(fsync(fd), 0); close(fd)
        } else if mode != "intent" {
            let result = try DiskBenchmarkEngine().run(in: root, volume: volume, config: config, isCancelled: { false }, progress: { _ in }, measurementID: job.id, cleanupProgress: { _ in })
            let terminal = MeasurementJobTerminal(intent: job, outcome: .benchmark(result))
            if mode == "staged" {
                let bytes = try MeasurementJournalCoding.wrap(terminal)
                let fd = openat(lease.descriptor, ".write-\(UUID().uuidString).tmp", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, bytes.count)
                XCTAssertEqual(fsync(fd), 0); close(fd)
            } else {
                try lease.writeTerminal(terminal)
                if mode == "committed" || mode.hasPrefix("gc-") {
                    let store = try HistoryStore(databaseURL: databaseURL)
                    let receipt = try store.recordMeasurement(lease.record()); try store.close()
                    if mode.hasPrefix("gc-") {
                        try stageConsumption(lease: lease, receipt: receipt)
                        if mode == "gc-intent" { XCTAssertEqual(unlinkat(lease.descriptor, "intent.json", 0), 0); XCTAssertEqual(fsync(lease.descriptor), 0) }
                        else {
                            for name in try WorkspaceDirectory.entries(fd: lease.descriptor, limit: 8) { XCTAssertEqual(unlinkat(lease.descriptor, name, 0), 0) }
                            let fd = Darwin.open(journalURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); defer { close(fd) }
                            XCTAssertEqual(unlinkat(fd, "job-" + job.id.uuidString, AT_REMOVEDIR), 0); XCTAssertEqual(fsync(fd), 0)
                        }
                    }
                }
            }
        }
        try JSONEncoder().encode(["id": job.id.uuidString, "pid": String(getpid())]).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        withExtendedLifetime((journal,lease,workspace)) { while true { Thread.sleep(forTimeInterval: 0.05) } }
    }
    private func killedChild(_ mode: String) async throws -> UUID {
        let found = try await BoundedProcess.run(ProcessCommand("/usr/bin/xcrun", ["--find","xctest"], timeout: 5, scope: "journal-fixture-runner")).requireSuccess()
        let runner = String(decoding: found, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["MDRIVE_JOURNAL_FIXTURE_ROOT=\(root.path)","MDRIVE_JOURNAL_FIXTURE_MODE=\(mode)"]
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") {
            var info = Dl_info(); if dladdr(symbol, &info) != 0, let path = info.dli_fname { arguments.append("DYLD_INSERT_LIBRARIES=\(String(cString: path))") }
        }
        arguments += [runner,"-XCTest","MDriveHealthCoreTests.MeasurementJournalTests/testChildFixture",Bundle(for: Self.self).bundlePath]
        var command = ProcessCommand("/usr/bin/env", arguments, timeout: 15, scope: "journal-crash-\(mode)")
        command.stdoutLimit = 16384; command.stderrLimit = 16384
        let process = Task { try await BoundedProcess.run(command) }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<1000 { if FileManager.default.fileExists(atPath: ready.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard FileManager.default.fileExists(atPath: ready.path) else { _ = try await process.value; throw MeasurementJournalError.invalidRecord }
        let info = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: ready)), pid = try XCTUnwrap(Int32(info["pid"] ?? "")), id = try XCTUnwrap(UUID(uuidString: info["id"] ?? ""))
        let journal = try MeasurementJournal(rootURL: journalURL); XCTAssertEqual(try journal.scan().jobs.first?.state, mode.hasPrefix("gc-") ? .acknowledged : .active)
        XCTAssertEqual(kill(pid, SIGKILL), 0); _ = try await process.value
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        return id
    }
    func testActualKilledChildBeforeIOKeepsInterruptedIntent() async throws {
        let id = try await killedChild("intent"), journal = try MeasurementJournal(rootURL: journalURL)
        let record = try XCTUnwrap(journal.scan().jobs.first?.record)
        XCTAssertEqual(record.id, id); XCTAssertNil(record.terminal)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualKilledChildAfterResultRestores() async throws {
        let id = try await killedChild("result"), journal = try MeasurementJournal(rootURL: journalURL), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        let record = try XCTUnwrap(journal.scan().jobs.first?.record); XCTAssertEqual(record.id, id)
        guard case .benchmark? = record.terminal?.outcome else { return XCTFail("complete result must survive actual SIGKILL") }
        let receipt = try await store.recordMeasurement(record); try journal.discardCommitted(receipt); XCTAssertTrue(try journal.scan().jobs.isEmpty)
    }
    func testActualKilledChildDuringWritesKeepsReviewUntilOwnedCleanup() async throws {
        let id = try await killedChild("writing"), journal = try MeasurementJournal(rootURL: journalURL), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        let record = try XCTUnwrap(journal.scan().jobs.first?.record); XCTAssertNil(record.terminal); XCTAssertEqual(record.id, id)
        let receipt = try await store.recordMeasurement(record)
        XCTAssertThrowsError(try journal.discardCommitted(receipt))
        var lease: MeasurementJobLease? = try journal.openJob(id: id)
        let scan = try DiskWorkspaceRecovery.scanFixture(at: root), owned = try XCTUnwrap(scan.leftovers.first)
        XCTAssertEqual(owned.bytes, 8192); XCTAssertThrowsError(try lease!.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: volume, scan: scan))
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: owned)
        try lease!.confirmCleanup(currentOrigin: MeasurementOrigin(drive: drive), currentVolume: volume, scan: DiskWorkspaceRecovery.scanFixture(at: root)); lease = nil
        try journal.discardCommitted(receipt); XCTAssertTrue(try journal.scan().jobs.isEmpty)
    }
    func testActualKilledChildBetweenRecordFsyncAndPublishCanRecover() async throws {
        let id = try await killedChild("staged"), journal = try MeasurementJournal(rootURL: journalURL)
        XCTAssertNil(try journal.scan().jobs.first?.record?.terminal)
        let lease = try journal.openJob(id: id); try lease.recoverStagedTerminal()
        guard case .benchmark? = try lease.record().terminal?.outcome else { return XCTFail("intact staged result must be recovered") }
    }
    func testActualKilledChildAfterSQLiteCommitRetriesExactlyOnce() async throws {
        _ = try await killedChild("committed")
        let journal = try MeasurementJournal(rootURL: journalURL), record = try XCTUnwrap(journal.scan().jobs.first?.record), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        let before = try await store.measurementRecords(); XCTAssertEqual(before.count, 1)
        let receipt = try await store.recordMeasurement(record); try journal.discardCommitted(receipt)
        let benchmarks = try await store.benchmarks(driveKey: record.intent.driveKey, since: .distantPast), after = try await store.measurementRecords()
        XCTAssertEqual(benchmarks.count, 1); XCTAssertEqual(after.count, 1)
    }
    func testActualKilledChildDuringIntentGCResumesFromRootReceipt() async throws {
        let id = try await killedChild("gc-intent"), journal = try MeasurementJournal(rootURL: journalURL), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        XCTAssertEqual(try journal.scan().jobs.first?.state, .acknowledged)
        try journal.collectAcknowledged(id: id); XCTAssertTrue(try journal.scan().jobs.isEmpty)
        let record = try await store.measurementRecord(id: id); XCTAssertNotNil(record?.terminal)
    }
    func testActualKilledChildAfterDirectoryGCResumesFromRootReceipt() async throws {
        let id = try await killedChild("gc-directory"), journal = try MeasurementJournal(rootURL: journalURL), store = try HistoryStore(databaseURL: databaseURL)
        defer { try? store.close() }
        try journal.collectAcknowledged(id: id); XCTAssertTrue(try journal.scan().jobs.isEmpty)
        let record = try await store.measurementRecord(id: id); XCTAssertNotNil(record?.terminal)
    }

}
