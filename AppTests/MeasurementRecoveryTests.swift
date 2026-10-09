/* Real private journal/SQLite restart recovery, no user-volume measurements. GPL-3.0-or-later. */
import XCTest
import Darwin
import Observation
@testable import MDriveHealthCore

private struct ArchiveRecoveryHardware: DriveHardwareServing {
    let root: URL
    var complete = true
    func enumerate() async throws -> [DriveInfo] { [] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { throw HardwareWorkerError.protocolViolation }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan {
        let scan = try DiskWorkspaceRecovery.scanFixture(at: root)
        return DiskWorkspaceScan(leftovers: scan.leftovers, complete: complete, diagnostic: nil, parentIdentity: scan.parentIdentity)
    }
}
private final class ArchiveHistoryGate: @unchecked Sendable {
    let database: URL
    private let lock = NSLock()
    private var enabled: Bool
    init(database: URL, enabled: Bool) { self.database = database; self.enabled = enabled }
    func allow() { lock.lock(); enabled = true; lock.unlock() }
    func open() throws -> HistoryStore {
        lock.lock(); let allowed = enabled; lock.unlock()
        guard allowed else { throw HistoryError.unavailable }; return try HistoryStore(databaseURL: database)
    }
}
private actor HeldArchiveRecovery: MeasurementRecovering {
    private(set) var scans = 0
    private var continuation: CheckedContinuation<MeasurementRecoveryScan, Never>?
    func scan() async throws -> MeasurementRecoveryScan {
        scans += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(jobs: [], unknownEntries: [])); continuation = nil }
    func restoreTerminal(_ record: MeasurementJobRecord) async throws -> Bool { throw MeasurementJournalError.changed }
    func discard(_ receipt: MeasurementHistoryReceipt) async throws { throw MeasurementJournalError.changed }
    func discardOmitted(_ record: MeasurementJobRecord) async throws { throw MeasurementJournalError.changed }
    func confirmCleanup(_ record: MeasurementJobRecord, proof: WorkspaceRecoveryProof) async throws { throw MeasurementJournalError.changed }
}

@MainActor final class MeasurementRecoveryTests: XCTestCase {
    private var root: URL!
    private var accesses: [HistoryAccess] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-startup-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDown() async throws {
        for access in accesses { try await access.shutdown() }
        accesses = []
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("keep".utf8))
        try FileManager.default.removeItem(at: root)
    }
    private var journalURL: URL { root.appendingPathComponent("journal") }
    private var database: URL { root.appendingPathComponent("history.db") }
    private var config: BenchmarkConfig { .init(fileSizeBytes: 8192, sequentialBlockBytes: 4096, includeRandomPhases: false) }
    private var snapshot: DriveSnapshot {
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 719, bsdName: "disk999997", model: "Offline fixture", serialNumber: "unique-startup-fixture",
            firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999997s1", name: "Private fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
            sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        return .init(drive: drive, volumes: [volume])
    }
    private func intent(id: UUID = UUID(), policy: MeasurementHistoryPolicy = .archive, operation: MeasurementOperation? = nil, createdAt: Date = Date()) -> MeasurementJobIntent {
        let snapshot = snapshot
        return .init(id: id, createdAt: createdAt, drive: snapshot.drive, driveKey: snapshot.identity.key, volume: snapshot.volumes[0], operation: operation ?? .benchmark(config),
            origin: MeasurementOrigin(drive: snapshot.drive, identity: snapshot.identity), historyPolicy: policy)
    }
    private func completed(_ intent: MeasurementJobIntent) throws -> MeasurementJobRecord {
        let outcome: MeasurementJobOutcome
        switch intent.operation {
        case .benchmark(let config): outcome = .benchmark(try DiskBenchmarkEngine().run(in: root, volume: intent.volume, config: config, isCancelled: { false }, progress: { _ in }, measurementID: intent.id, cleanupProgress: { _ in }))
        case .capacity(let config): outcome = .capacity(try CapacityVerifier().run(in: root, volume: intent.volume, config: config, isCancelled: { false }, progress: { _ in }, measurementID: intent.id, cleanupProgress: { _ in }))
        }
        return .init(intent: intent, terminal: .init(intent: intent, outcome: outcome))
    }
    private func publish(_ record: MeasurementJobRecord) throws {
        let journal = try MeasurementJournal(rootURL: journalURL), lease = try journal.prepare(record.intent)
        if let terminal = record.terminal { try lease.writeTerminal(terminal) }
    }
    private func access(_ gate: ArchiveHistoryGate? = nil) -> HistoryAccess {
        let gate = gate ?? ArchiveHistoryGate(database: database, enabled: true)
        let access = HistoryAccess(factory: { try gate.open() }); accesses.append(access); return access
    }
    private func controller(_ history: HistoryAccess? = nil) -> MeasurementRecoveryController {
        .init(history: history ?? access(), service: SystemMeasurementRecovery(rootURL: journalURL))
    }
    private func records(_ history: HistoryAccess) async throws -> [MeasurementJobRecord] {
        try await history.run("test.records") { try await $0.measurementRecords(limit: 256) }
    }
    func testFreshStartupImportsBothRealResultTypesOnceAndOfflineHistorySurvivesGC() async throws {
        let benchmark = try completed(intent())
        let capacityConfig = CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true)
        let capacity = try completed(intent(operation: .capacity(capacityConfig)))
        try publish(benchmark); try publish(capacity)
        let history = access(), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertEqual(recovery.archivedRecords.count, 2)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
        recovery.requestRefresh(); await recovery.waitForCompletion()
        let stored = try await records(history); XCTAssertEqual(stored.count, 2)
        let fresh = controller(); fresh.start(); await fresh.waitForCompletion()
        XCTAssertEqual(Set(fresh.archivedRecords.map(\.id)), [benchmark.id, capacity.id])
        XCTAssertTrue(fresh.jobs.isEmpty) // No attached fleet needed to recover results.
    }
    func testSingleStagedTerminalIsPromotedBeforeInterruptedArchive() async throws {
        let record = try completed(intent()); try publish(record)
        let directory = journalURL.appendingPathComponent("job-" + record.id.uuidString)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("terminal.json"), to: directory.appendingPathComponent(".write-recovery.tmp"))
        let recovery = controller(); recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.archivedRecords.count, 1)
        XCTAssertEqual(try recovery.archivedRecords.first?.recordSHA256, try record.recordSHA256)
        XCTAssertTrue(recovery.jobs.isEmpty)
    }
    func testActiveLeaseIsNeverImportedAndInterruptedAttemptNeedsFreshCleanupProof() async throws {
        let original = intent(), journal = try MeasurementJournal(rootURL: journalURL)
        var lease: MeasurementJobLease? = try journal.prepare(original)
        let history = access(), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.first?.state, .active)
        let activeRecords = try await records(history); XCTAssertTrue(activeRecords.isEmpty)
        XCTAssertNotNil(lease); lease = nil
        recovery.requestRefresh(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.first?.state, .interrupted)
        XCTAssertEqual(recovery.workspaceReviews.count, 1)
        let store = DriveStore(history: history, hardware: ArchiveRecoveryHardware(root: root), measurementRecovery: SystemMeasurementRecovery(rootURL: journalURL))
        store.workspaces.onCompleteScan = { recovery.reconcile($0) }
        store.workspaces.updateFleet([snapshot]); await store.workspaces.waitForCompletion(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.workspaceReviews.isEmpty); XCTAssertTrue(recovery.jobs.isEmpty)
        XCTAssertTrue(try journal.scan().jobs.isEmpty)
        let saved = try await records(history); XCTAssertEqual(saved.count, 1); XCTAssertNil(saved.first?.terminal)
        store.beginShutdown(); await store.waitForBackgroundWork()
    }
    func testPartialScanCannotCloseInterruptedRecoveryRecord() async throws {
        try publish(.init(intent: intent(), terminal: nil))
        let history = access(), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        let store = DriveStore(history: history, hardware: ArchiveRecoveryHardware(root: root, complete: false))
        store.workspaces.onCompleteScan = { recovery.reconcile($0) }
        store.workspaces.updateFleet([snapshot]); await store.workspaces.waitForCompletion(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.workspaceReviews.count, 1); XCTAssertFalse(recovery.jobs[0].cleanupConfirmed)
        XCTAssertEqual(try MeasurementJournal(rootURL: journalURL).scan().jobs.count, 1)
        store.beginShutdown(); await store.waitForBackgroundWork()
    }
    func testOmittedResultNeverEntersSQLAndExplicitDiscardRequiresExactSelection() async throws {
        let original = intent(policy: .omit), record = try completed(original); try publish(record)
        let history = access(), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertFalse(recovery.jobs[0].archived)
        let saved = try await records(history); XCTAssertTrue(saved.isEmpty)
        let changed = try completed(intent(id: original.id, policy: .omit))
        recovery.discardOmitted(changed); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1)
        recovery.discardOmitted(record); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
        let after = try await records(history); XCTAssertTrue(after.isEmpty)
    }
    func testSQLCommitWithMissingTerminalRestoresExactRecordWithoutDuplicate() async throws {
        let record = try completed(intent()); try publish(.init(intent: record.intent, terminal: nil))
        let history = access()
        _ = try await history.run("test.commit") { try await $0.recordMeasurement(record) }
        let recovery = controller(history); recovery.start(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertEqual(recovery.archivedRecords.count, 1)
        XCTAssertEqual(try recovery.archivedRecords[0].recordSHA256, try record.recordSHA256)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
        let saved = try await records(history); XCTAssertEqual(saved.count, 1)
    }
    func testMalformedTerminalPreservesBytesAndDisplaysCommittedSQLResult() async throws {
        let record = try completed(intent()); try publish(.init(intent: record.intent, terminal: nil))
        let path = journalURL.appendingPathComponent("job-" + record.id.uuidString).appendingPathComponent("terminal.json")
        let bytes = Data("foreign metadata".utf8); try bytes.write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let history = access(); _ = try await history.run("test.commit") { try await $0.recordMeasurement(record) }
        let recovery = controller(history); recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertEqual(recovery.jobs[0].state, .unverified)
        XCTAssertTrue(recovery.jobs[0].archived); XCTAssertNotNil(recovery.jobs[0].issue)
        XCTAssertEqual(try recovery.jobs[0].record?.recordSHA256, try record.recordSHA256)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testTornStagedTerminalIsPreservedAndNeverArchivedAsInterrupted() async throws {
        let original = intent(); try publish(.init(intent: original, terminal: nil))
        let path = journalURL.appendingPathComponent("job-" + original.id.uuidString).appendingPathComponent(".write-torn.tmp")
        let bytes = Data("partial".utf8); try bytes.write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let history = access(), recovery = controller(history); recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.first?.state, .unverified); XCTAssertNil(recovery.jobs.first?.journalRecord)
        let saved = try await records(history); XCTAssertTrue(saved.isEmpty); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testUUIDConflictCannotConsumeJournalOrOverwriteHistory() async throws {
        let record = try completed(intent()), other = try completed(intent(id: record.id)); try publish(record)
        let history = access(); _ = try await history.run("test.commit") { try await $0.recordMeasurement(other) }
        let recovery = controller(history); recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertNotNil(recovery.jobs[0].issue)
        XCTAssertEqual(try MeasurementJournal(rootURL: journalURL).scan().jobs.count, 1)
        let saved = try await records(history); XCTAssertEqual(saved.count, 1); XCTAssertEqual(try saved[0].recordSHA256, try other.recordSHA256)
    }
    func testHistoryUnavailableRetainsResultThenRetryImportsOnce() async throws {
        let record = try completed(intent()); try publish(record)
        let gate = ArchiveHistoryGate(database: database, enabled: false), history = access(gate), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertEqual(try recovery.jobs[0].record?.recordSHA256, try record.recordSHA256)
        XCTAssertNotNil(recovery.jobs[0].issue); XCTAssertEqual(try MeasurementJournal(rootURL: journalURL).scan().jobs.count, 1)
        gate.allow(); try await history.connect(retry: true)
        recovery.requestRefresh(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); let saved = try await records(history); XCTAssertEqual(saved.count, 1)
    }
    func testRepeatedGCFromRunnerAndRecoveryIsHarmlessButForeignJobStillBlocks() async throws {
        let record = try completed(intent()); try publish(record)
        let history = access(), receipt = try await history.run("test.commit") { try await $0.recordMeasurement(record) }
        let recovery = SystemMeasurementRecovery(rootURL: journalURL)
        try await recovery.discard(receipt); try await recovery.discard(receipt)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
        let foreign = intent(id: record.id)
        try publish(.init(intent: foreign, terminal: nil))
        do { try await recovery.discard(receipt); XCTFail("different immutable intent must be preserved") }
        catch { }
        XCTAssertEqual(try MeasurementJournal(rootURL: journalURL).scan().jobs.count, 1)
    }
    func testHistoryPaginationKeepsOnlyOneBoundedPage() async throws {
        let history = access()
        for n in 0...100 {
            let original = intent(createdAt: Date(timeIntervalSince1970: Double(n + 1)))
            let record = MeasurementJobRecord(intent: original, terminal: .init(intent: original, outcome: .notStarted("fixture")))
            _ = try await history.run("test.seed") { try await $0.recordMeasurement(record) }
        }
        let recovery = controller(history); recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.archivedRecords.count, 100); XCTAssertTrue(recovery.canLoadOlder)
        recovery.loadOlder(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.archivedRecords.count, 1); XCTAssertTrue(recovery.showingOlderPage); XCTAssertFalse(recovery.canLoadOlder)
        XCTAssertEqual(recovery.archivedRecords[0].intent.createdAt, Date(timeIntervalSince1970: 1))
        recovery.requestRefresh(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.archivedRecords.count, 100); XCTAssertFalse(recovery.showingOlderPage)
    }
    func testNonResultTerminalsArchiveWithoutInventingBenchmarkAndFailedCleanupNeedsProof() async throws {
        for outcome in [MeasurementJobOutcome.cancelled, .notStarted("Preflight fixture"), .failed("Cleanup fixture")] {
            let original = intent()
            try publish(.init(intent: original, terminal: .init(intent: original, outcome: outcome)))
        }
        let history = access(), recovery = controller(history)
        recovery.start(); await recovery.waitForCompletion()
        let saved = try await records(history); XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertEqual(recovery.workspaceReviews.count, 1)
        XCTAssertTrue(saved.allSatisfy {
            switch $0.terminal?.outcome { case .cancelled, .notStarted, .failed: return true; default: return false }
        })
        let store = DriveStore(history: history, hardware: ArchiveRecoveryHardware(root: root))
        store.workspaces.onCompleteScan = { recovery.reconcile($0) }
        store.workspaces.updateFleet([snapshot]); await store.workspaces.waitForCompletion(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
        let after = try await records(history); XCTAssertEqual(after.count, 3)
        store.beginShutdown(); await store.waitForBackgroundWork()
    }
    func testShutdownDrainsAcceptedScanAndClosesAdmissionBeforeSQL() async throws {
        let service = HeldArchiveRecovery(), history = access()
        let store = DriveStore(history: history, hardware: ArchiveRecoveryHardware(root: root), measurementRecovery: service)
        let observed = expectation(description: "Recovery busy state is observable by SwiftUI")
        withObservationTracking { _ = store.measurementRecovery.isBusy } onChange: { observed.fulfill() }
        store.measurementRecovery.start()
        await fulfillment(of: [observed], timeout: 1)
        XCTAssertTrue(store.measurementRecovery.isBusy)
        for _ in 0..<1000 { if await service.scans == 1 { break }; await Task.yield() }
        let started = await service.scans; XCTAssertEqual(started, 1)
        store.beginShutdown(); store.measurementRecovery.requestRefresh()
        var drained = false
        let task = Task { await store.waitForBackgroundWork(); drained = true; try await history.shutdown() }
        try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(drained)
        await service.release(); try await task.value
        XCTAssertTrue(drained); XCTAssertEqual(history.state, .closed)
        XCTAssertFalse(store.measurementRecovery.isBusy)
        let scans = await service.scans; XCTAssertEqual(scans, 1)
    }
}
