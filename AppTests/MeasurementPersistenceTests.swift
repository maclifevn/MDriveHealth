/* Actual worker, private 16 KiB fixtures and UUID history. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

private final class MeasurementHistoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var readOnly = false
    let database: URL
    init(database: URL, enabled: Bool) { self.database = database; self.enabled = enabled }
    func allow() { lock.lock(); enabled = true; readOnly = false; lock.unlock() }
    func allowReadsOnly() { lock.lock(); enabled = true; readOnly = true; lock.unlock() }
    func open() throws -> HistoryStore {
        lock.lock(); let allowed = enabled, readsOnly = readOnly; lock.unlock()
        guard allowed else { throw HistoryError.unavailable }
        return try HistoryStore(databaseURL: database, accessMode: readsOnly ? .readOnly : .readWrite)
    }
}
private struct PersistenceHardware: DriveHardwareServing {
    func enumerate() async throws -> [DriveInfo] { [] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { throw HardwareWorkerError.selfTestUnavailable }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
}
@MainActor private final class PersistenceDelivery: NotificationDelivering {
    func access() async -> NotificationAccess { .denied }
    func requestPermission() async throws -> Bool { false }
    func send(_ alert: DriveAlert) async throws {}
    func registeredRequestIDs() async -> Set<String> { [] }
}
final class MeasurementPersistenceTests: XCTestCase {
    private var root: URL!
    @MainActor private var stores: [DriveStore] = []
    override func setUpWithError() throws {
        if let path = ProcessInfo.processInfo.environment["MDRIVE_PERSISTENCE_FIXTURE_ROOT"] { root = URL(fileURLWithPath: path); return }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-measurement-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDown() async throws {
        if ProcessInfo.processInfo.environment["MDRIVE_PERSISTENCE_FIXTURE_ROOT"] != nil { return }
        await drain()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("keep".utf8))
        try FileManager.default.removeItem(at: root); try await super.tearDown()
    }
    @MainActor private func drain() async {
        for store in stores { store.beginShutdown(); await store.operations.waitForIdle(); await store.waitForBackgroundWork(); try? await store.history.shutdown() }
        stores.removeAll()
    }
    private var journalURL: URL { root.appendingPathComponent("journal") }
    private var config: BenchmarkConfig { .init(fileSizeBytes: 16384, sequentialBlockBytes: 4096, includeRandomPhases: false) }
    private var capacityConfig: CapacityVerifyConfig { .init(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true) }
    @MainActor private func setup(enabled: Bool = true) -> (DriveStore, DriveSnapshot, MeasurementHistoryGate) {
        let gate = MeasurementHistoryGate(database: root.appendingPathComponent("history.db"), enabled: enabled)
        let store = DriveStore(history: HistoryAccess(factory: { try gate.open() }), hardware: PersistenceHardware(),
                               measurementRecovery: SystemMeasurementRecovery(rootURL: journalURL)); stores.append(store)
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 709, bsdName: "disk999999", model: "Persistence fixture", serialNumber: "fixture",
            firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999999s1", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
            sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        return (store, .init(drive: drive, volumes: [volume]), gate)
    }
    private func worker(_ mode: String = "normal") throws -> SystemMeasurements {
        let output = try BoundedProcess.run(ProcessCommand("/usr/bin/xcrun", ["--sdk", "macosx", "--find", "xctest"], timeout: 5, scope: "persistence-test-runner")).requireSuccess()
        let executable = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let injected = ProcessInfo.processInfo.environment.keys.filter {
            $0.hasPrefix("XCTest") || $0.hasPrefix("XCInject") || $0 == "DYLD_INSERT_LIBRARIES"
        }.sorted().flatMap { ["-u", $0] }
        let arguments = ["-c", "exec 4>&1; exec \"$@\" 1>&2", "persistence-fixture", "/usr/bin/env"] + injected + [
            "MDRIVE_PERSISTENCE_FIXTURE_ROOT=\(root.path)", "MDRIVE_PERSISTENCE_FIXTURE_MODE=\(mode)", executable,
            "-XCTest", "MDriveHealthModelTests.MeasurementPersistenceTests/testPersistenceWorkerFixtureChild", Bundle(for: Self.self).bundlePath]
        return .init(client: .init(executable: "/bin/sh", arguments: arguments, idleTimeout: 3, timeout: 15, terminateGrace: 1, journalRootURL: journalURL))
    }
    func testPersistenceWorkerFixtureChild() throws {
        guard ProcessInfo.processInfo.environment["MDRIVE_PERSISTENCE_FIXTURE_ROOT"] != nil else { return }
        let mode = ProcessInfo.processInfo.environment["MDRIVE_PERSISTENCE_FIXTURE_MODE"] ?? "normal"
        let status = MeasurementWorker.serve(output: FileHandle(fileDescriptor: 4, closeOnDealloc: false), requireJournal: true) { request, cancelled, progress, capacityProgress, cleaning in
            try DriveCommandLock.validateDelegation(registryEntryID: request.drive.id, token: request.lockToken)
            if mode == "storage-failure" {
                let fd = openat(5, "terminal.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
                let bytes = Data("user-metadata".utf8)
                XCTAssertEqual(bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, bytes.count); XCTAssertEqual(fsync(fd), 0)
            }
            let result: MeasurementPayload
            switch request.operation {
            case .benchmark(let config): result = .benchmarkResult(try DiskBenchmarkEngine().run(in: self.root, volume: request.volume, config: config,
                isCancelled: cancelled, progress: progress, measurementID: request.id, cleanupProgress: cleaning))
            case .capacity(let config): result = .capacityResult(try CapacityVerifier().run(in: self.root, volume: request.volume, config: config,
                isCancelled: cancelled, progress: capacityProgress, measurementID: request.id, cleanupProgress: cleaning))
            }
            if mode == "broken-output" { close(4) }
            return result
        }
        exit(status)
    }
    @MainActor func testRealBenchmarkUsesOneUUIDTransactionThenConsumesJournal() async throws {
        let (store, snapshot, _) = setup(), runner = BenchmarkRunner(store: store, worker: try worker())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: config); await runner.waitForCompletion()
        guard case .finished(let result) = runner.state else { return XCTFail("\(runner.state)") }; XCTAssertEqual(result.fileSizeBytes, 16384)
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError); XCTAssertTrue(runner.journalCleanupIssues.isEmpty)
        let records = try await store.history.run("read") { try await $0.measurementRecords() }
        let benchmarks = try await store.history.run("benchmarks") { try await $0.benchmarks(driveKey: snapshot.identity.key, since: .distantPast) }
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.id, runner.measurementID); XCTAssertEqual(benchmarks.count, 1)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
    }
    @MainActor func testCapacitySaveFailureSurvivesResetAndRetryCommitsExactlyOnce() async throws {
        let (store, snapshot, gate) = setup(enabled: false), runner = CapacityVerifyRunner(store: store, worker: try worker())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: capacityConfig); await runner.waitForCompletion()
        guard case .finished(let result) = runner.state else { return XCTFail("\(runner.state)") }; XCTAssertEqual(result.bytesVerifiedOK, 16384)
        let id = try XCTUnwrap(runner.unsavedResults.first?.id)
        XCTAssertNotNil(runner.persistenceError); XCTAssertEqual(try MeasurementJournal(rootURL: journalURL).scan().jobs.first?.state, .completed)
        runner.reset(); XCTAssertEqual(runner.unsavedResults.first?.id, id)
        gate.allow(); await runner.retrySaving(reconnect: true); await runner.retrySaving()
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError)
        let records = try await store.history.run("read") { try await $0.measurementRecords() }
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.id, id)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
    }
    @MainActor func testBenchmarkRetryResolvesRecoveryWriteFailureForSameUUIDOnly() async throws {
        let (store, snapshot, gate) = setup()
        let seed = try HistoryStore(databaseURL: gate.database); try await seed.close(); gate.allowReadsOnly()
        let runner = BenchmarkRunner(store: store, worker: try worker())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: config); await runner.waitForCompletion()
        let id = try XCTUnwrap(runner.unsavedResults.first?.id)
        let recovery = store.measurementRecovery
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertNotNil(recovery.jobs[0].issue)
        XCTAssertTrue(store.history.isDegraded)
        store.history.report(HistoryError.invalidData("unrelated export failure"), operation: "fixture.export")
        gate.allow(); await runner.retrySaving(reconnect: true)
        await recovery.waitForCompletion()
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError)
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertFalse(recovery.hasAttention)
        XCTAssertEqual(Set(store.history.issues.keys), ["fixture.export"], "A committed UUID must resolve its recovery write failure without hiding unrelated failures")
        let records = try await store.history.run("test.confirm") { try await $0.measurementRecords() }
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
    }
    @MainActor func testCapacityRetryResolvesRecoveryWriteFailureAfterJournalGC() async throws {
        let (store, snapshot, gate) = setup()
        let seed = try HistoryStore(databaseURL: gate.database); try await seed.close(); gate.allowReadsOnly()
        let runner = CapacityVerifyRunner(store: store, worker: try worker())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: capacityConfig); await runner.waitForCompletion()
        let id = try XCTUnwrap(runner.unsavedResults.first?.id)
        let recovery = store.measurementRecovery
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertEqual(recovery.jobs.count, 1); XCTAssertNotNil(recovery.jobs[0].issue)
        gate.allow(); await runner.retrySaving(reconnect: true)
        await recovery.waitForCompletion()
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError)
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertFalse(recovery.hasAttention)
        XCTAssertFalse(store.history.isDegraded, "The removed journal must not leave an unreachable error banner")
        let records = try await store.history.run("test.confirm") { try await $0.measurementRecords() }
        XCTAssertEqual(records.map(\.id), [id])
    }
    @MainActor func testRecoveryCommitResolvesLiveRunnerWriteFailureBeforeRunnerRetry() async throws {
        let (store, snapshot, gate) = setup()
        let seed = try HistoryStore(databaseURL: gate.database); try await seed.close(); gate.allowReadsOnly()
        let runner = BenchmarkRunner(store: store, worker: try worker())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: config); await runner.waitForCompletion()
        let id = try XCTUnwrap(runner.unsavedResults.first?.id)
        XCTAssertTrue(store.history.isDegraded)
        gate.allow(); try await store.history.connect(retry: true)
        let recovery = MeasurementRecoveryController(history: store.history, service: SystemMeasurementRecovery(rootURL: journalURL))
        recovery.start(); await recovery.waitForCompletion()
        XCTAssertTrue(recovery.jobs.isEmpty); XCTAssertEqual(recovery.archivedRecords.map(\.id), [id])
        XCTAssertFalse(store.history.isDegraded, "A verified recovery commit must resolve the same UUID's live-write issue")
        await runner.retrySaving()
        XCTAssertTrue(runner.unsavedResults.isEmpty)
        let records = try await store.history.run("test.confirm") { try await $0.measurementRecords() }
        XCTAssertEqual(records.map(\.id), [id])
    }
    @MainActor func testBrokenResultIPCIsPreservedAndArchivedByRunner() async throws {
        let (store, snapshot, _) = setup(), runner = BenchmarkRunner(store: store, worker: try worker("broken-output"))
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: config); await runner.waitForCompletion()
        guard case .finished(let result) = runner.state else { return XCTFail("\(runner.state)") }; XCTAssertEqual(result.fileSizeBytes, 16384)
        XCTAssertNotNil(runner.recoveredResultMessage); XCTAssertTrue(runner.unsavedResults.isEmpty)
        let records = try await store.history.run("read") { try await $0.measurementRecords() }
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.id, runner.measurementID)
        XCTAssertTrue(try MeasurementJournal(rootURL: journalURL).scan().jobs.isEmpty)
    }
    @MainActor func testStorageFailureSavesKnownResultAndPreservesUnknownJournalContents() async throws {
        let (store, snapshot, _) = setup(), runner = BenchmarkRunner(store: store, worker: try worker("storage-failure"))
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: config); await runner.waitForCompletion()
        guard case .finished = runner.state else { return XCTFail("\(runner.state)") }
        let id = try XCTUnwrap(runner.measurementID)
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError); XCTAssertNotNil(runner.journalCleanupIssues[id])
        XCTAssertEqual(runner.journalCleanupIssues[id]?.driveKey, snapshot.identity.key)
        XCTAssertFalse(runner.requiresWorkspaceReview); XCTAssertNotNil(runner.recoveredResultMessage)
        let saved = try await store.history.run("read") { try await $0.measurementRecord(id: id) }; XCTAssertEqual(saved?.id, id)
        XCTAssertEqual(try Data(contentsOf: journalURL.appendingPathComponent("job-" + id.uuidString + "/terminal.json")), Data("user-metadata".utf8))
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    @MainActor func testQuitKeepsPendingCapacityResultUntilHistoryRetrySucceeds() async throws {
        let (store, snapshot, gate) = setup(enabled: false), capacity = CapacityVerifyRunner(store: store, worker: try worker())
        capacity.start(snapshot: snapshot, volume: snapshot.volumes[0], config: capacityConfig); await capacity.waitForCompletion()
        let suite = "capacity-persistence-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        let monitor = MonitoringController(store: store, defaults: defaults, delivery: PersistenceDelivery())
        let lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: BenchmarkRunner(store: store), capacity: capacity)
        let first = await lifecycle.prepare(.quit); XCTAssertFalse(first); XCTAssertEqual(capacity.unsavedResults.count, 1)
        gate.allow(); let retry = await lifecycle.prepare(.quit); XCTAssertTrue(retry); XCTAssertTrue(capacity.unsavedResults.isEmpty)
        let reopened = try HistoryStore(databaseURL: gate.database); defer { try? reopened.close() }
        let records = try await reopened.measurementRecords(); XCTAssertEqual(records.count, 1)
    }
}
